import Foundation
import Hummingbird
import NIOCore
import Logging
import ServiceLifecycle

/// The shared library server: the journal engine exposed over HTTP. One
/// instance per library; the owning process (macOS app or the headless CLI)
/// is the single writer — clients push commands and pull records, the server
/// serializes appends and never merges.
/// Errors thrown during server construction.
public enum ServerConfigurationError: Error, Equatable {
    /// The standalone init needs an indexes directory; the embedded init
    /// (existing repository) does not take one.
    case missingIndexesDirectory
}

public actor LibraryServer {
    private let repository: LibraryRepository
    private let configuration: ServerConfiguration

    /// The standalone path: the server opens the library itself (headless
    /// CLI, tests). Indexes must be server-owned.
    public init(configuration: ServerConfiguration) async throws {
        self.configuration = configuration
        guard let indexesDirectory = configuration.indexesDirectory else {
            throw ServerConfigurationError.missingIndexesDirectory
        }
        let root = URL(fileURLWithPath: configuration.libraryPath)
        repository = try await LibraryRepository.open(
            at: root,
            indexesDirectory: indexesDirectory,
            deviceID: UUID()
        )
    }

    /// The embedded path (macOS app's Sharing pane): serves the repository
    /// the app already has open. One repository, one journal, one writer —
    /// the app's local edits flow into the served sync stream automatically
    /// and clients' pushed commands serialize through the same journal.
    public init(repository: LibraryRepository, configuration: ServerConfiguration) async {
        self.repository = repository
        self.configuration = configuration
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

        // MARK: - OPDS (third-party readers)

        router.get("opds") { request, _ -> String in
            OPDSFeed.root(baseURL: "http://\(request.head.authority ?? "localhost")")
        }

        router.get("opds/books") { request, _ -> String in
            let page = max(1, request.uri.queryParameters.get("page").flatMap(Int.init) ?? 1)
            let books = try await repository.books()
            return OPDSFeed.booksFeed(
                title: "All Books", books: books,
                baseURL: "http://\(request.head.authority ?? "localhost")",
                page: page, pageHref: "/opds/books"
            )
        }

        router.get("opds/newest") { request, _ -> String in
            let page = max(1, request.uri.queryParameters.get("page").flatMap(Int.init) ?? 1)
            let books = try await repository.books()
                .sorted { ($0.addedMilliseconds ?? 0) > ($1.addedMilliseconds ?? 0) }
            return OPDSFeed.booksFeed(
                title: "Newest", books: books,
                baseURL: "http://\(request.head.authority ?? "localhost")",
                page: page, pageHref: "/opds/newest"
            )
        }

        router.get("opds/search") { request, _ -> String in
            guard let query = request.uri.queryParameters.get("q"), !query.isEmpty else {
                throw HTTPError(.badRequest)
            }
            let page = max(1, request.uri.queryParameters.get("page").flatMap(Int.init) ?? 1)
            let books = try await repository.search(query)
            return OPDSFeed.booksFeed(
                title: "Search: \(query)", books: books,
                baseURL: "http://\(request.head.authority ?? "localhost")",
                page: page, pageHref: "/opds/search"
            )
        }

        for (route, facetType, title) in [
            (RouterPath("opds/authors/:value"), FacetType.author, "Authors"),
            (RouterPath("opds/series/:value"), FacetType.series, "Series"),
            (RouterPath("opds/tags/:value"), FacetType.tag, "Tags"),
            (RouterPath("opds/formats/:value"), FacetType.format, "Formats"),
        ] {
            router.get(route) { request, context -> String in
                guard let raw = context.parameters.get("value"),
                      let value = raw.removingPercentEncoding else {
                    throw HTTPError(.badRequest)
                }
                let page = max(1, request.uri.queryParameters.get("page").flatMap(Int.init) ?? 1)
                let books = try await repository.books(facetType: facetType, value: value)
                return OPDSFeed.booksFeed(
                    title: "\(title): \(value)", books: books,
                    baseURL: "http://\(request.head.authority ?? "localhost")",
                    page: page, pageHref: "\(route)"
                )
            }
        }

        router.get("opds/books/:id") { request, context -> String in
            guard let id = context.parameters.get("id").flatMap(UUID.init(uuidString:)),
                  let book = try await repository.book(id: id) else {
                throw HTTPError(.notFound)
            }
            return OPDSFeed.booksFeed(
                title: book.title, books: [book],
                baseURL: "http://\(request.head.authority ?? "localhost")",
                pageHref: "/opds/books/\(book.id.uuidString)"
            )
        }

        return Application(router: router, configuration: .init(address: .hostname("0.0.0.0", port: configuration.port)))
    }

    private var advertiser: BonjourAdvertiser?
    private var serviceGroup: ServiceGroup?
    private var runTask: Task<Void, Never>?

    /// Runs the server until shutdown — the CLI's `serve` path. Advertises
    /// over Bonjour first when configured.
    public func run() async throws {
        if configuration.advertiseBonjour {
            let advertiser = BonjourAdvertiser(
                displayName: displayName, libraryID: libraryID, port: configuration.port
            )
            advertiser.start()
            self.advertiser = advertiser
        }
        let app = try makeApplication()
        try await app.runService()
        advertiser?.stop()
    }

    /// Non-blocking start for in-process embedding (the macOS app's Sharing
    /// pane). Owns the service group so `stop()` can trigger graceful
    /// shutdown; advertises over Bonjour when configured.
    public func start() async throws {
        let app = try makeApplication()
        if configuration.advertiseBonjour {
            let advertiser = BonjourAdvertiser(
                displayName: displayName, libraryID: libraryID, port: configuration.port
            )
            advertiser.start()
            self.advertiser = advertiser
        }
        let group = ServiceGroup(services: [app], logger: Logger(label: "Stacks.LibraryServer"))
        serviceGroup = group
        runTask = Task { try? await group.run() }
    }

    /// Gracefully shuts the embedded server down.
    public func stop() async {
        await serviceGroup?.triggerGracefulShutdown()
        runTask?.cancel()
        advertiser?.stop()
        advertiser = nil
        serviceGroup = nil
        runTask = nil
    }

    /// The opened library's manifest id (Bonjour TXT, diagnostics).
    public var libraryID: UUID { repository.manifest.id }
    /// The library's display name (folder name unless configured otherwise).
    public var displayName: String {
        configuration.displayName
            ?? URL(fileURLWithPath: configuration.libraryPath).lastPathComponent
    }
}
