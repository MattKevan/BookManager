import Foundation

/// The client half of the sync protocol: connects to a `LibraryServer`,
/// pulls journal commands, replays them into a browsable state with the same
/// `CommandReplay` the server's rebuild uses, and pushes edits. Edits to an
/// unreachable server go into a durable `OfflineQueue` and flush on
/// reconnect. The client is thin — the server serializes appends, the CRDT is
/// gone.
public actor RemoteLibrary {
    public struct Credential: Sendable {
        public let username: String
        public let password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    public struct Configuration: Sendable {
        public let baseURL: URL
        /// Optional basic auth — sent on every request when set.
        public let credential: Credential?
        /// Durable location for the offline command queue.
        public let queueDirectory: URL

        public init(baseURL: URL, credential: Credential? = nil, queueDirectory: URL) {
            self.baseURL = baseURL
            self.credential = credential
            self.queueDirectory = queueDirectory
        }
    }

    public enum PushOutcome: Sendable, Equatable {
        case applied([Int64])
        case queued
    }

    public enum RemoteError: Error, Equatable {
        case unreachable
        case serverError(Int)
    }

    private let baseURL: URL
    private let authorization: String?
    private let queue: OfflineQueue
    private var state: [UUID: IndexedBook] = [:]
    private var cursor: Int64 = 0
    /// The server's latest seq — the next pull cursor.
    public private(set) var serverSeq: Int64 = 0

    public init(configuration: Configuration) throws {
        baseURL = configuration.baseURL
        if let credential = configuration.credential {
            authorization = "Basic "
                + Data("\(credential.username):\(credential.password)".utf8).base64EncodedString()
        } else {
            authorization = nil
        }
        queue = try OfflineQueue(directory: configuration.queueDirectory)
    }

    // MARK: - Sync

    /// Pulls every command after the cursor and replays it into the browsable
    /// state. Throws `RemoteError.unreachable` on network failure,
    /// `RemoteError.serverError` on an HTTP error (e.g. 401).
    /// Fetches the server's identity (library id + display name). Used by
    /// manual host:port connections to validate the server and adopt its
    /// real name; 401 surfaces as `RemoteError.serverError(401)` like every
    /// other gated endpoint.
    public func fetchIdentity() async throws -> LibraryIdentity {
        var components = URLComponents(url: baseURL.appending(path: "api/identity"), resolvingAgainstBaseURL: false)!
        let (data, status) = try await request(method: "GET", components: components)
        guard status == 200 else { throw RemoteError.serverError(status) }
        return try JSONDecoder.bookManager.decode(LibraryIdentity.self, from: data)
    }

    public func pull() async throws {
        var components = URLComponents(url: baseURL.appending(path: "api/sync"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "after", value: "\(cursor)")]
        let (data, status) = try await request(method: "GET", components: components)
        guard status == 200 else { throw RemoteError.serverError(status) }
        let response = try JSONDecoder.bookManager.decode(SyncPullResponse.self, from: data)
        for command in response.commands {
            try CommandReplay.apply(command, to: &state)
        }
        cursor = response.seq
        serverSeq = response.seq
    }

    /// Pushes one command (with any staged files). Reachable server → stage
    /// files + push, returning the applied seqs. Network failure → enqueue to
    /// the offline queue. A server error (401, 4xx/5xx) is thrown, never
    /// queued.
    @discardableResult
    public func push(
        _ command: ClientCommand,
        stagedFiles: [String: Data] = [:]
    ) async throws -> PushOutcome {
        do {
            for (name, bytes) in stagedFiles {
                var components = URLComponents(url: baseURL.appending(path: "api/stage"), resolvingAgainstBaseURL: false)!
                components.queryItems = [
                    URLQueryItem(name: "command", value: command.id.uuidString),
                    URLQueryItem(name: "name", value: name),
                ]
                let (_, status) = try await request(method: "POST", components: components, body: bytes)
                guard status == 200 else { throw RemoteError.serverError(status) }
            }
            var components = URLComponents(url: baseURL.appending(path: "api/commands"), resolvingAgainstBaseURL: false)!
            let body = try JSONEncoder.bookManager.encode(SyncPushRequest(commands: [command]))
            let (data, status) = try await request(method: "POST", components: components, body: body)
            guard status == 200 else { throw RemoteError.serverError(status) }
            let result = try JSONDecoder.bookManager.decode(SyncPushResponse.self, from: data)
            return .applied(result.applied)
        } catch let error as RemoteError {
            switch error {
            case .unreachable:
                try? await queue.enqueue(command, stagedFiles: stagedFiles)
                return .queued
            case .serverError:
                throw error
            }
        } catch {
            try? await queue.enqueue(command, stagedFiles: stagedFiles)
            return .queued
        }
    }

    /// Flushes the offline queue: uploads staged files and pushes commands in
    /// order until empty or the server is unreachable again.
    public func flushOffline() async throws {
        for queued in try await queue.pendingCommands() {
            let outcome = try await push(queued.command, stagedFiles: queued.stagedFiles)
            switch outcome {
            case .applied:
                try await queue.remove(commandID: queued.command.id)
            case .queued:
                return
            }
        }
    }

    public func pendingOfflineCount() async -> Int { await queue.pendingCount() }

    // MARK: - Browse state

    public func books() -> [IndexedBook] {
        state.values.filter { !$0.isDeleted }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func deletedBooks() -> [IndexedBook] {
        state.values.filter(\.isDeleted)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func book(id: UUID) -> IndexedBook? {
        state[id]
    }

    // MARK: - Files

    /// Downloads a book's cover bytes (nil when the book has none).
    public func downloadCover(id: UUID) async throws -> Data? {
        var components = URLComponents(url: baseURL.appending(path: "api/books/\(id.uuidString)/cover"), resolvingAgainstBaseURL: false)!
        let (data, status) = try await request(method: "GET", components: components)
        guard status == 200 else { return nil }
        return data
    }

    /// Downloads a book's format file to a temp location and returns it.
    public func downloadFormat(id: UUID, format: String) async throws -> URL {
        var components = URLComponents(url: baseURL.appending(path: "api/books/\(id.uuidString)/download"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "format", value: format)]
        let (data, status) = try await request(method: "GET", components: components)
        guard status == 200 else { throw RemoteError.serverError(status) }
        let destination = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = destination.appending(path: "book.\(format)")
        try data.write(to: file)
        return file
    }

    // MARK: - Private

    private func request(
        method: String,
        components: URLComponents,
        body: Data? = nil
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RemoteError.unreachable
        }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
