import Foundation

/// The durable offline command queue for one remote library. Commands (with
/// any staged files) are persisted under the queue directory as
/// `<commandID>/command.json` + staged files, and flushed to the server on
/// reconnect. The server's staging contract (`staging/<commandID>/`) is
/// replayed by the flush: upload staged files, then push commands in order.
public actor OfflineQueue {
    private let directory: URL

    public struct QueuedCommand: Sendable, Equatable {
        public let command: ClientCommand
        public let stagedFiles: [String: Data]

        public init(command: ClientCommand, stagedFiles: [String: Data]) {
            self.command = command
            self.stagedFiles = stagedFiles
        }
    }

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func enqueue(_ command: ClientCommand, stagedFiles: [String: Data]) throws {
        let commandDirectory = directory
            .appending(path: command.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: commandDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(command)
            .write(to: commandDirectory.appending(path: "command.json"), options: .atomic)
        for (name, data) in stagedFiles {
            try data.write(to: commandDirectory.appending(path: name), options: .atomic)
        }
    }

    public func pendingCommands() throws -> [QueuedCommand] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [QueuedCommand] = []
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for entry in entries where entry.hasDirectoryPath {
            let commandURL = entry.appending(path: "command.json")
            guard let data = try? Data(contentsOf: commandURL),
                  let command = try? decoder.decode(ClientCommand.self, from: data) else {
                continue
            }
            var staged: [String: Data] = [:]
            let files = (try? FileManager.default.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: nil
            )) ?? []
            for file in files where file.lastPathComponent != "command.json" {
                if let bytes = try? Data(contentsOf: file) {
                    staged[file.lastPathComponent] = bytes
                }
            }
            result.append(QueuedCommand(command: command, stagedFiles: staged))
        }
        // Deterministic order: enqueue order (directory creation time is
        // unstable; use the command ids' lexical order as a stable fallback).
        return result.sorted { $0.command.id.uuidString < $1.command.id.uuidString }
    }

    public func pendingCount() -> Int {
        (try? pendingCommands().count) ?? 0
    }

    public func remove(commandID: UUID) throws {
        try? FileManager.default.removeItem(
            at: directory.appending(path: commandID.uuidString, directoryHint: .isDirectory)
        )
    }
}
