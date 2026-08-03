import Foundation
import os

/// Result of running an adb command.
public struct ADBResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var ok: Bool { exitCode == 0 }
}

public enum ADBError: Error, Sendable {
    case binaryNotFound
    case launchFailed(String)
    case timedOut
    case cancelled
    case commandFailed(code: Int32, stderr: String)
}

/// Serializes access to the `adb` CLI. adb's own server can handle concurrency, but we
/// run one command at a time for predictable timeouts/cancellation and to keep output
/// parsing simple. The bundled adb is isolated on its own server port so it never fights
/// a user's own `adb` install.
public actor ADBClient {
    static let log = Logger(subsystem: "com.Ricky.Android-File-Transfer", category: "ADB")

    private let adbPath: String
    private let serverPort: Int

    /// Locate the adb binary: prefer the one bundled in the app, then common install
    /// locations (useful for `swift test` / development on machines with platform-tools).
    public static func locateADB() -> String? {
        if let bundled = Bundle.main.url(forResource: "adb", withExtension: nil)?.path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `adbPath` defaults to the located binary. `serverPort` isolates our adb server
    /// (5037 is the default that a user's adb would use).
    public init?(adbPath: String? = nil, serverPort: Int = 5577) {
        guard let path = adbPath ?? Self.locateADB() else { return nil }
        self.adbPath = path
        self.serverPort = serverPort
    }

    public nonisolated var binaryPath: String { adbPath }

    // MARK: Running commands

    /// Run `adb <args...>`, capturing stdout/stderr. `timeout == 0` means no timeout.
    @discardableResult
    public func run(_ args: [String], timeout: TimeInterval = 30) async throws -> ADBResult {
        try await runProcess(args, timeout: timeout, onStdoutLine: nil)
    }

    /// Run `adb <args...>` streaming stdout lines to `onLine` as they arrive (for progress).
    @discardableResult
    public func runStreaming(_ args: [String], timeout: TimeInterval = 0,
                             onLine: @escaping @Sendable (String) -> Void) async throws -> ADBResult {
        try await runProcess(args, timeout: timeout, onStdoutLine: onLine)
    }

    /// Convenience: `adb -s <serial> shell <command...>` returning trimmed stdout, or throw.
    public func shell(serial: String, _ command: [String], timeout: TimeInterval = 30) async throws -> String {
        let result = try await run(["-s", serial, "shell"] + command, timeout: timeout)
        guard result.ok else { throw ADBError.commandFailed(code: result.exitCode, stderr: result.stderr) }
        return result.stdout
    }

    // MARK: Process plumbing

    private func runProcess(_ args: [String], timeout: TimeInterval,
                            onStdoutLine: (@Sendable (String) -> Void)?) async throws -> ADBResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["ANDROID_ADB_SERVER_PORT"] = String(serverPort)
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector(onStdoutLine: onStdoutLine)
        // Stream stdout line-by-line; collect stderr wholesale.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            collector.appendStdout(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.appendStderr(data) }
        }

        do {
            try process.run()
        } catch {
            throw ADBError.launchFailed(error.localizedDescription)
        }

        // Timeout watchdog.
        let timeoutTask: Task<Void, Never>? = timeout > 0 ? Task {
            try? await Task.sleep(for: .seconds(timeout))
            if process.isRunning { process.terminate() }
        } : nil

        // Wait for exit off the cooperative pool, and honour task cancellation.
        await withTaskCancellationHandler {
            await waitForExit(process)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        timeoutTask?.cancel()

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // Drain anything left in the pipes.
        collector.appendStdout(outPipe.fileHandleForReading.readDataToEndOfFile())
        collector.appendStderr(errPipe.fileHandleForReading.readDataToEndOfFile())

        if Task.isCancelled { throw ADBError.cancelled }
        return ADBResult(exitCode: process.terminationStatus,
                         stdout: collector.stdoutString,
                         stderr: collector.stderrString)
    }

    private func waitForExit(_ process: Process) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in cont.resume() }
            // If it already exited before the handler was set.
            if !process.isRunning { process.terminationHandler = nil; cont.resume() }
        }
    }
}

/// Thread-safe accumulator for child-process output. Streams stdout lines to a callback.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var lineBuffer = Data()
    private let onStdoutLine: (@Sendable (String) -> Void)?

    init(onStdoutLine: (@Sendable (String) -> Void)?) { self.onStdoutLine = onStdoutLine }

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stdoutData.append(data)
        if onStdoutLine != nil {
            lineBuffer.append(data)
            // adb uses both \n and \r (progress uses \r). Split on either.
            while let idx = lineBuffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<idx)
                lineBuffer.removeSubrange(lineBuffer.startIndex...idx)
                if let s = String(data: lineData, encoding: .utf8), !s.isEmpty {
                    onStdoutLine?(s)
                }
            }
        }
        lock.unlock()
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); stderrData.append(data); lock.unlock()
    }

    var stdoutString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: stdoutData, as: UTF8.self) }
    var stderrString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: stderrData, as: UTF8.self) }
}
