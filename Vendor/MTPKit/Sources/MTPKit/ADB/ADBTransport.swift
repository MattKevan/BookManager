import Foundation

/// `DeviceTransport` backed by ADB over Wi-Fi (or a USB-debug adb connection).
///
/// Unlike MTP (opaque numeric handles), ADB addresses files by absolute path, so here
/// `FileNode.id` IS the device path (e.g. "/sdcard/DCIM") and `storageID` is the mount
/// root (e.g. "/sdcard"). Both are opaque tokens to the UI, exactly like MTP's handles.
///
/// ADB has no change-event mechanism, so live sync relies on the browser's existing
/// polling (`childIDs`), same as unreliable-event MTP devices.
public final class ADBTransport: DeviceTransport, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let kind = TransportKind.wireless
    public let changes: AsyncStream<DeviceChange>

    let client: ADBClient
    let serial: String                 // adb serial, e.g. "192.168.1.23:5555" or an mDNS name
    /// Hardware serial (ro.serialno). Identifies the physical device regardless of which
    /// adb serial form connected it — used to de-duplicate the same phone reached two ways.
    public let hardwareSerial: String
    private let changeContinuation: AsyncStream<DeviceChange>.Continuation

    private init(client: ADBClient, serial: String, model: String, hardwareSerial: String) {
        self.client = client
        self.serial = serial
        self.id = "adb-\(serial)"
        self.displayName = model
        self.hardwareSerial = hardwareSerial
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceChange.self)
        self.changes = stream
        self.changeContinuation = continuation
    }

    /// Build a transport for an already-connected adb serial (caller has run `adb connect`).
    /// Reads model + hardware serial; returns nil if the device isn't reachable.
    public static func connect(client: ADBClient, serial: String) async -> ADBTransport? {
        do {
            let model = try await client.shell(serial: serial, ["getprop", "ro.product.model"], timeout: 10)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hw = (try? await client.shell(serial: serial, ["getprop", "ro.serialno"], timeout: 10))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? serial
            let name = model.isEmpty ? serial : model
            return ADBTransport(client: client, serial: serial, model: name,
                                hardwareSerial: hw.isEmpty ? serial : hw)
        } catch {
            ADBClient.log.error("ADB connect/getprop failed for \(serial, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Storages

    public func storages() async throws -> [StorageInfo] {
        var result: [StorageInfo] = []

        // Internal shared storage is always /sdcard (a symlink to /storage/emulated/0).
        if let info = try? await storageInfo(at: "/sdcard", name: L("storage.internal")) {
            result.append(info)
        }

        // Removable volumes appear as /storage/XXXX-XXXX (skip emulated/self).
        if let listing = try? await client.shell(serial: serial, ["ls", "/storage"], timeout: 10) {
            for vol in listing.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
                let name = String(vol)
                guard name.contains("-"), name != "self", name != "emulated" else { continue }
                if let info = try? await storageInfo(at: "/storage/\(name)", name: L("storage.removable")) {
                    result.append(info)
                }
            }
        }

        // Fallback: if nothing resolved, still expose /sdcard so the user can browse.
        if result.isEmpty {
            result.append(StorageInfo(id: "/sdcard", name: L("storage.internal"),
                                      capacityBytes: 0, freeBytes: 0))
        }
        return result
    }

    /// Capacity/free via `df` (POSIX 1K blocks). Best-effort; zeros if unavailable.
    private func storageInfo(at path: String, name: String) async throws -> StorageInfo {
        // Verify the path exists/usable first.
        _ = try await client.shell(serial: serial, ["ls", "-d", path], timeout: 10)
        var capacity: Int64 = 0, free: Int64 = 0
        if let df = try? await client.shell(serial: serial, ["df", "-k", path], timeout: 10) {
            // Header line then a data line: Filesystem 1K-blocks Used Available ...
            let lines = df.split(separator: "\n")
            if lines.count >= 2 {
                let cols = lines[1].split(whereSeparator: { $0 == " " }).map(String.init)
                if cols.count >= 4 {
                    capacity = (Int64(cols[1]) ?? 0) * 1024
                    free = (Int64(cols[3]) ?? 0) * 1024
                }
            }
        }
        return StorageInfo(id: path, name: name, capacityBytes: capacity, freeBytes: free)
    }

    // MARK: Listing

    public func listChildren(of parentID: String?, in storageID: String) async throws -> [FileNode] {
        let dir = parentID ?? storageID
        // Trailing slash forces listing the *contents* even when `dir` is a symlink such
        // as /sdcard. `--full-time` works on Android's older toybox (which lacks
        // --time-style=+%s).
        let result = try await client.run(
            ["-s", serial, "shell", "ls", "-la", "--full-time", shellQuote(dir + "/")], timeout: 30)
        let entries = ADBOutputParser.parseListing(result.stdout)
        return entries.map { entry in
            Self.node(entry: entry, parentDir: dir, storageID: storageID)
        }
    }

    public func metadata(for id: String) async throws -> FileNode {
        // stat the single path; derive parent + storage from the path string.
        let parent = (id as NSString).deletingLastPathComponent
        let storage = storageRoot(for: id)
        let result = try await client.run(
            ["-s", serial, "shell", "ls", "-lad", "--full-time", shellQuote(id)], timeout: 15)
        guard let entry = ADBOutputParser.parseListing(result.stdout).first else {
            throw TransportError.notFound(id: id)
        }
        // `ls -d` prints the full path as name; normalise to the basename.
        var e = entry
        e.name = (id as NSString).lastPathComponent
        return Self.node(entry: e, parentDir: parent, storageID: storage)
    }

    public func childIDs(of parentID: String?, in storageID: String) async throws -> Set<String> {
        // Cheap: names only (`ls -1`), build full paths. Trailing slash to follow symlinks.
        let dir = parentID ?? storageID
        let result = try await client.run(["-s", serial, "shell", "ls", "-1", shellQuote(dir + "/")], timeout: 20)
        var ids = Set<String>()
        for line in result.stdout.split(separator: "\n") {
            let name = line.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name.hasPrefix("ls:") { continue }
            ids.insert(joinPath(dir, name))
        }
        return ids
    }

    // MARK: Transfers

    public func download(_ id: String, to destinationURL: URL, progress: @escaping ProgressHandler) async throws {
        let name = (id as NSString).lastPathComponent
        // Get the total up front so progress percentages map to bytes.
        let total = (try? await sizeOf(id)) ?? 0
        progress(TransferProgress(fileName: name, completedBytes: 0, totalBytes: total))

        let result = try await client.runStreaming(
            ["-s", serial, "pull", id, destinationURL.path], timeout: 0
        ) { line in
            if let pct = ADBOutputParser.parseProgressPercent(line), total > 0 {
                let done = Int64(Double(total) * Double(pct) / 100.0)
                progress(TransferProgress(fileName: name, completedBytes: done, totalBytes: total))
            }
        }
        guard result.ok else {
            throw TransportError.operationFailed(adbErrorText(result))
        }
        // Final correction to the real on-disk size.
        let actual = ((try? FileManager.default.attributesOfItem(atPath: destinationURL.path))?[.size] as? Int64) ?? total
        progress(TransferProgress(fileName: name, completedBytes: actual, totalBytes: actual))
    }

    @discardableResult
    public func upload(localURL: URL, as name: String, toParent parentID: String?, in storageID: String,
                       progress: @escaping ProgressHandler) async throws -> FileNode {
        let destDir = parentID ?? storageID
        let remotePath = joinPath(destDir, name)
        let total = ((try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.size] as? Int64) ?? 0
        progress(TransferProgress(fileName: name, completedBytes: 0, totalBytes: total))

        let result = try await client.runStreaming(
            ["-s", serial, "push", localURL.path, remotePath], timeout: 0
        ) { line in
            if let pct = ADBOutputParser.parseProgressPercent(line), total > 0 {
                let done = Int64(Double(total) * Double(pct) / 100.0)
                progress(TransferProgress(fileName: name, completedBytes: done, totalBytes: total))
            }
        }
        guard result.ok else { throw TransportError.operationFailed(adbErrorText(result)) }
        progress(TransferProgress(fileName: name, completedBytes: total, totalBytes: total))

        let node = (try? await metadata(for: remotePath))
            ?? FileNode(id: remotePath, storageID: storageID, parentID: parentID == storageID ? nil : parentID,
                        name: name, isDirectory: false, size: total)
        changeContinuation.yield(.added(node))
        return node
    }

    // MARK: Write operations

    @discardableResult
    public func createDirectory(named name: String, inParent parentID: String?, in storageID: String) async throws -> FileNode {
        let dir = parentID ?? storageID
        let path = joinPath(dir, name)
        let r = try await client.run(["-s", serial, "shell", "mkdir", "-p", shellQuote(path)], timeout: 15)
        guard r.ok, r.stderr.isEmpty else { throw TransportError.operationFailed(adbErrorText(r)) }
        let node = FileNode(id: path, storageID: storageID, parentID: parentID == storageID ? nil : parentID,
                            name: name, isDirectory: true, size: 0, modifiedDate: Date())
        changeContinuation.yield(.added(node))
        return node
    }

    public func delete(_ id: String) async throws {
        let r = try await client.run(["-s", serial, "shell", "rm", "-rf", shellQuote(id)], timeout: 30)
        guard r.ok, r.stderr.isEmpty else { throw TransportError.operationFailed(adbErrorText(r)) }
        changeContinuation.yield(.removed(id: id))
    }

    @discardableResult
    public func rename(_ id: String, to newName: String) async throws -> FileNode {
        let parent = (id as NSString).deletingLastPathComponent
        let newPath = joinPath(parent, newName)
        let r = try await client.run(
            ["-s", serial, "shell", "mv", shellQuote(id), shellQuote(newPath)], timeout: 20)
        guard r.ok, r.stderr.isEmpty else { throw TransportError.operationFailed(adbErrorText(r)) }
        let node = try await metadata(for: newPath)
        changeContinuation.yield(.removed(id: id))
        changeContinuation.yield(.added(node))
        return node
    }

    public func move(_ id: String, toParent newParentID: String?, in storageID: String) async throws {
        let dest = newParentID ?? storageID
        let newPath = joinPath(dest, (id as NSString).lastPathComponent)
        let r = try await client.run(
            ["-s", serial, "shell", "mv", shellQuote(id), shellQuote(newPath)], timeout: 30)
        guard r.ok, r.stderr.isEmpty else { throw TransportError.operationFailed(adbErrorText(r)) }
        changeContinuation.yield(.removed(id: id))
    }

    // MARK: Transfer helpers

    /// File size in bytes via `stat -c %s` (toybox). Returns 0 if unknown.
    private func sizeOf(_ path: String) async throws -> Int64 {
        let out = try await client.shell(serial: serial, ["stat", "-c", "%s", shellQuote(path)], timeout: 10)
        return Int64(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func adbErrorText(_ r: ADBResult) -> String {
        let msg = r.stderr.isEmpty ? r.stdout : r.stderr
        return msg.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func close() async {
        changeContinuation.finish()
        // Disconnect this wireless device from our isolated adb server.
        _ = try? await client.run(["disconnect", serial], timeout: 10)
    }

    // MARK: Helpers

    static func node(entry: ADBOutputParser.Entry, parentDir: String, storageID: String) -> FileNode {
        let path = joinPath(parentDir, entry.name)
        let ext: String? = entry.isDirectory ? nil : {
            let e = (entry.name as NSString).pathExtension.lowercased()
            return e.isEmpty ? nil : e
        }()
        let date = entry.modifiedEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return FileNode(
            id: path,
            storageID: storageID,
            parentID: parentDir == storageID ? nil : parentDir,
            name: entry.name,
            isDirectory: entry.isDirectory,
            size: entry.size,
            modifiedDate: date,
            fileExtension: ext
        )
    }

    private func storageRoot(for path: String) -> String {
        if path.hasPrefix("/storage/"), let third = path.split(separator: "/").dropFirst().first.map(String.init) {
            return "/storage/\(third)"
        }
        return "/sdcard"
    }
}

/// Join a directory and a child name into an absolute device path.
func joinPath(_ dir: String, _ name: String) -> String {
    if dir.hasSuffix("/") { return dir + name }
    return dir + "/" + name
}

/// Quote a path for `adb shell` (which runs through /system/bin/sh). Single-quote and
/// escape embedded single quotes.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
