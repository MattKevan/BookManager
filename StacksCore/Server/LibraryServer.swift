import Foundation
import Hummingbird
import NIOCore

/// The shared library server: the journal engine exposed over HTTP. One
/// instance per library; the owning process (macOS app or the headless CLI)
/// is the single writer — clients push commands and pull records, the server
/// serializes appends and never merges.
public actor LibraryServer {
    private let repository: LibraryRepository
    private let configuration: ServerConfiguration

    public init(configuration: ServerConfiguration) async throws {
        self.configuration = configuration
        let root = URL(fileURLWithPath: configuration.libraryPath)
        repository = try await LibraryRepository.open(
            at: root,
            indexesDirectory: configuration.indexesDirectory,
            deviceID: UUID()
        )
    }

    /// Builds the Hummingbird application (testable in-process via
    /// HummingbirdTesting; the CLI runs it with `run()`).
    public func makeApplication() throws -> some ApplicationProtocol {
        let router = Router()
        router.middlewares.add(BasicAuthMiddleware(
            username: configuration.username, password: configuration.password
        ))
        let repository = self.repository

        // MARK: - Sync protocol

        router.get("api/sync") { request, _ -> SyncPullResponse in
            let after = request.uri.queryParameters.get("after").flatMap(Int64.init) ?? 0
            let seq = await repository.journalSeq()
            let commands = try await repository.journalRecords(after: after)
            return SyncPullResponse(seq: seq, commands: commands)
        }

        router.post("api/commands") { request, context -> SyncPushResponse in
            // The context decoder (ISO-8601 dates) matches the response
            // encoder — the push and pull use the same date representation.
            let payload = try await request.decode(as: SyncPushRequest.self, context: context)
            var applied: [Int64] = []
            var errors: [SyncPushResponse.CommandError] = []
            for (index, command) in payload.commands.enumerated() {
                let journalCommand = JournalCommand(id: command.id, seq: 0, ts: .now, op: command.op)
                do {
                    if let seq = try await repository.ingest(journalCommand) {
                        applied.append(seq)
                    }
                } catch {
                    errors.append(SyncPushResponse.CommandError(
                        index: index, message: error.localizedDescription
                    ))
                }
            }
            return SyncPushResponse(applied: applied, errors: errors)
        }

        router.post("api/stage") { request, _ -> StageResponse in
            guard let commandID = request.uri.queryParameters.get("command").flatMap(UUID.init(uuidString:)),
                  let stagedName = request.uri.queryParameters.get("name"),
                  !stagedName.isEmpty else {
                throw HTTPError(.badRequest, message: "command and name query parameters are required")
            }
            var request = request
            let buffer = try await request.collectBody(upTo: 2 << 30)
            let data = Data(buffer: buffer)
            try await repository.stageUploadedFile(data, commandID: commandID, stagedName: stagedName)
            return StageResponse(stagedName: stagedName, size: Int64(data.count))
        }

        // MARK: - Files

        router.get("api/books/:id/download") { request, context -> Response in
            guard let id = context.parameters.get("id").flatMap(UUID.init(uuidString:)) else {
                throw HTTPError(.badRequest)
            }
            let format = request.uri.queryParameters.get("format")
            guard let book = try await repository.book(id: id) else {
                throw HTTPError(.notFound)
            }
            let root = LibraryLayout(root: repository.root).root
            let url: URL
            if let format, let match = book.formats.first(where: {
                $0.kind.lowercased() == format.lowercased()
            }) {
                url = root
                    .appending(path: book.relativePath, directoryHint: .isDirectory)
                    .appending(path: match.filename)
            } else if let format = book.formats.first {
                url = root
                    .appending(path: book.relativePath, directoryHint: .isDirectory)
                    .appending(path: format.filename)
            } else {
                throw HTTPError(.notFound)
            }
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else {
                throw HTTPError(.notFound)
            }
            var response = Response(status: .ok, body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
            response.headers[.contentType] = "application/octet-stream"
            return response
        }

        router.get("api/books/:id/cover") { request, context -> Response in
            guard let id = context.parameters.get("id").flatMap(UUID.init(uuidString:)),
                  let book = try await repository.book(id: id),
                  book.coverHash != nil else {
                throw HTTPError(.notFound)
            }
            let root = LibraryLayout(root: repository.root).root
            let coverURL = root
                .appending(path: book.relativePath, directoryHint: .isDirectory)
                .appending(path: "cover.jpg")
            guard FileManager.default.fileExists(atPath: coverURL.path),
                  let data = try? Data(contentsOf: coverURL) else {
                throw HTTPError(.notFound)
            }
            var response = Response(status: .ok, body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
            response.headers[.contentType] = "image/jpeg"
            return response
        }

        return Application(router: router, configuration: .init(address: .hostname("0.0.0.0", port: configuration.port)))
    }

    /// Runs the server until shutdown — the CLI's `serve` path.
    public func run() async throws {
        let app = try makeApplication()
        try await app.runService()
    }

    /// The opened library's manifest id (Bonjour TXT, diagnostics).
    public var libraryID: UUID { repository.manifest.id }
    /// The library's display name (folder name unless configured otherwise).
    public var displayName: String {
        configuration.displayName
            ?? URL(fileURLWithPath: configuration.libraryPath).lastPathComponent
    }
}
