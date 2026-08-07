import ArgumentParser
import Foundation
import StacksCore

/// The headless library server CLI — `bookmanager create|serve|status`.
@main
struct BookManagerCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bookmanager",
        abstract: "Create, serve, and inspect Stacks libraries.",
        subcommands: [Create.self, Serve.self, Status.self]
    )
}

/// The server's disposable index directory. macOS: Application Support.
/// Linux (Plan 3): a sibling `.stacks-server-indexes` directory next to the
/// library (Application Support may be unavailable or unwritable).
func serverIndexesDirectory(libraryPath: String? = nil) throws -> URL {
    if let support = try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    ) {
        return support.appending(path: "StacksServer", directoryHint: .isDirectory)
    }
    if let libraryPath {
        return URL(fileURLWithPath: libraryPath)
            .deletingLastPathComponent()
            .appending(path: ".stacks-server-indexes", directoryHint: .isDirectory)
    }
    return URL(fileURLWithPath: ".stacks-server-indexes")
}

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a new library at the given path."
    )

    @Argument(help: "Directory for the new library")
    var path: String

    func run() async throws {
        let root = URL(fileURLWithPath: path)
        let indexes = try serverIndexesDirectory()
        let repository = try await LibraryRepository.create(
            at: root, indexesDirectory: indexes, deviceID: UUID()
        )
        print("Created library at \(root.path)")
        print("Library ID: \(repository.manifest.id)")
        print("Format version: \(repository.manifest.formatVersion)")
    }
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Serve a library over HTTP (sync protocol + OPDS) with Bonjour advertisement."
    )

    @Argument(help: "Path to the library directory")
    var path: String

    @Option(name: .shortAndLong, help: "Port to listen on")
    var port: Int = 8080

    @Option(name: .long, help: "Require this username (with --password)")
    var user: String?

    @Option(name: .long, help: "Password for --user")
    var password: String?

    @Option(name: .long, help: "Indexes directory (default: Application Support/StacksServer)")
    var indexes: String?

    @Flag(name: .customLong("no-bonjour"), help: "Do not advertise over Bonjour")
    var noBonjour = false

    @Option(name: .shortAndLong, help: "Display name for Bonjour")
    var name: String?

    func run() async throws {
        let indexesDirectory: URL
        if let indexes {
            indexesDirectory = URL(fileURLWithPath: indexes)
        } else {
            indexesDirectory = try serverIndexesDirectory(libraryPath: path)
        }
        let configuration = ServerConfiguration(
            port: port,
            libraryPath: path,
            indexesDirectory: indexesDirectory,
            username: user,
            password: password,
            advertiseBonjour: !noBonjour,
            displayName: name
        )
        let server = try await LibraryServer(configuration: configuration)
        let displayName = await server.displayName
        print("Serving '\(displayName)' on port \(port)"
            + (user != nil ? " (auth required)" : " (anonymous)"))
        try await server.run()
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show a library's identity and journal state."
    )

    @Argument(help: "Path to the library directory")
    var path: String

    func run() async throws {
        let root = URL(fileURLWithPath: path)
        let indexes = try serverIndexesDirectory()
        let repository = try await LibraryRepository.open(
            at: root, indexesDirectory: indexes, deviceID: UUID()
        )
        print("Library: \(root.path)")
        print("ID: \(repository.manifest.id)")
        print("Format version: \(repository.manifest.formatVersion)")
        print("Journal seq: \(await repository.journalSeq())")
        let books = try await repository.books()
        let deleted = try await repository.deletedBooks()
        print("Books: \(books.count) (+ \(deleted.count) deleted)")
    }
}
