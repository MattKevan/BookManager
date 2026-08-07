import Foundation
import Hummingbird

/// The sync protocol's wire models. A client command is a `JournalCommand`
/// without the server-assigned `seq`/`ts`; the server assigns both on ingest
/// and dedupes by `id`.
public struct ClientCommand: Sendable, Codable, Equatable {
    public let id: UUID
    public let op: JournalCommand.Op

    public init(id: UUID, op: JournalCommand.Op) {
        self.id = id
        self.op = op
    }
}

/// `GET /api/identity` — server + library identity, used by manual
/// host:port connections (no Bonjour TXT to carry the id/name) to validate
/// the server and adopt its real display name.
public struct LibraryIdentity: Sendable, Codable, Equatable, ResponseEncodable {
    public let id: UUID
    public let name: String
    /// The library file format version (journal layout).
    public let version: Int

    public init(id: UUID, name: String, version: Int) {
        self.id = id
        self.name = name
        self.version = version
    }
}

/// `GET /api/sync?after=<seq>` — the pull. `seq` is the client's next cursor.
public struct SyncPullResponse: Sendable, Codable, Equatable, ResponseEncodable {
    public let seq: Int64
    public let commands: [JournalCommand]

    public init(seq: Int64, commands: [JournalCommand]) {
        self.seq = seq
        self.commands = commands
    }
}

/// `POST /api/commands` — the push.
public struct SyncPushRequest: Sendable, Codable, Equatable {
    public let commands: [ClientCommand]

    public init(commands: [ClientCommand]) {
        self.commands = commands
    }
}

public struct SyncPushResponse: Sendable, Codable, Equatable, ResponseEncodable {
    /// Seq assigned to each applied command (in push order; duplicates are
    /// skipped and contribute nothing).
    public let applied: [Int64]
    /// Per-command apply failures — never fatal.
    public let errors: [CommandError]

    public struct CommandError: Sendable, Codable, Equatable {
        public let index: Int
        public let message: String
    }

    public init(applied: [Int64], errors: [CommandError]) {
        self.applied = applied
        self.errors = errors
    }
}

/// `POST /api/stage?command=<id>&name=<stagedName>` with the raw file body —
/// the server places the bytes at `staging/<commandID>/<stagedName>` so the
/// referencing `addBook`/`setCover` command can materialize them.
public struct StageResponse: Sendable, Codable, Equatable, ResponseEncodable {
    public let stagedName: String
    public let size: Int64

    public init(stagedName: String, size: Int64) {
        self.stagedName = stagedName
        self.size = size
    }
}
