#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import GRDB
import Testing
@testable import StacksCore

@Suite
struct CalibreReaderTests {
    private func makeLibrary() throws -> URL {
        try CalibreFixture.makeLibrary(named: "fixture-\(UUID().uuidString)")
    }

    private func book(_ id: Int, from library: URL) throws -> CalibreBookRecord {
        let reader = try CalibreReader.open(libraryURL: library)
        defer { try? reader.close() }
        return try reader.books().first { $0.calibreID == id }!
    }

    @Test
    func opensAndSummarizesFixtureLibrary() throws {
        let library = try makeLibrary()
        let reader = try CalibreReader.open(libraryURL: library)
        defer { try? reader.close() }

        let summary = try reader.summary()

        #expect(summary.userVersion == 26)
        #expect(summary.libraryID == "acceptance-fixture-uuid")
        #expect(summary.bookCount == CalibreFixture.expectedBookCount)
        #expect(summary.formatCount == CalibreFixture.expectedFormatCount)
        #expect(summary.titles.count == CalibreFixture.expectedBookCount)
        #expect(summary.titles.contains("Range: Why Generalists Triumph in a Specialized World"))
    }

    @Test
    func mapsFullMetadataMatrix() throws {
        let library = try makeLibrary()
        let record = try book(1, from: library)

        #expect(record.title == "Range: Why Generalists Triumph in a Specialized World")
        #expect(record.authors == [
            CalibreAuthor(name: "David Epstein", sort: "Epstein, David"),
            CalibreAuthor(name: "Peter Brown", sort: "Brown, Peter"),
        ])
        #expect(record.series == "Studies")
        #expect(record.seriesIndex == 1.5)
        #expect(record.tags == ["Science", "Sport"])
        // Calibre's 2...10 rating scale halved to 1...5.
        #expect(record.rating == 4)
        #expect(record.publisher == "Riverhead")
        // Hand-computed julian conversion: 2019-05-28 00:00 UTC == unix 1559001600.
        #expect(record.publicationDate == Date(timeIntervalSince1970: 1_559_001_600))
        #expect(record.addedDate == Date(timeIntervalSince1970: 1_705_276_800))
        #expect(record.languages == ["eng", "fra"])
        #expect(record.identifiers["isbn"] == "978-0-7352-2129-1")
        #expect(record.identifiers["google"] == "abcd1234")
        #expect(record.identifiers["asin"] == "B07VWM1Z2B")
        #expect(record.comments == "<p>Great book</p>")
        #expect(record.rawMetadata["calibre.custom.genre"] == "science")
        #expect(record.rawMetadata["calibre.custom.shelves"] == #"["read","favorites"]"#)
        // INTEGER-storage numeric custom column decodes without trapping.
        #expect(record.rawMetadata["calibre.custom.priority"] == "3")
        #expect(record.opfPath == "metadata.opf")
    }

    @Test
    func numericCustomColumnsDecodeWithoutCrash() throws {
        // Regression: GRDB's strict `as String?` cast traps on non-string
        // storage classes. A REAL (fractional) value must decode losslessly.
        let library = try makeLibrary()
        let record = try book(3, from: library)

        #expect(record.rawMetadata["calibre.custom.priority"] == "2.5")
    }

    @Test
    func hostileStorageClassesDegradeInsteadOfTrap() throws {
        // SQLite's dynamic typing lets a hostile or corrupted database store
        // TEXT in non-PK INTEGER columns. Every typed `as Int`/`as Int64`
        // cast used to trap there; the reader must skip the offending rows
        // instead. (books.id is an INTEGER PRIMARY KEY rowid alias, which
        // SQLite itself refuses to corrupt — only non-PK columns are at risk.)
        let library = try makeLibrary()
        let dbURL = library.appending(path: "metadata.db")
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(sql: "UPDATE data SET uncompressed_size = 'not-a-number' WHERE book = 1")
            try db.execute(sql: "UPDATE data SET book = 'corrupt-book' WHERE book = 2")
        }
        try queue.close()

        let reader = try CalibreReader.open(libraryURL: library)
        defer { try? reader.close() }
        let records = try reader.books()

        // All records survive; the corrupt format rows are dropped per book.
        let book1 = try #require(records.first { $0.calibreID == 1 })
        #expect(book1.formats.isEmpty)
        let book2 = try #require(records.first { $0.calibreID == 2 })
        #expect(book2.formats.isEmpty)
        // Uncorrupted books keep their formats.
        let book3 = try #require(records.first { $0.calibreID == 3 })
        #expect(!book3.formats.isEmpty)
    }

    @Test
    func preservesUnsupportedValuesInRawPayload() throws {
        let library = try makeLibrary()
        let record = try book(1, from: library)

        #expect(record.rawMetadata["calibre.lccn"] == "2018049465")
        // Annotations and last-read positions are preserved verbatim.
        let annotations = record.rawMetadata["calibre.annotations"] ?? ""
        #expect(annotations.contains("ann-1"))
        #expect(annotations.contains("EPUB"))
        let lastRead = record.rawMetadata["calibre.lastReadPositions"] ?? ""
        #expect(lastRead.contains("kindle"))

        // Schema variant with the pages column: preserved defensively.
        let variant = try CalibreFixture.makeVariantLibrary(
            named: "variant-pages-\(UUID().uuidString)",
            userVersion: 26,
            extraColumns: true
        )
        let variantRecord = try book(1, from: variant)
        #expect(variantRecord.rawMetadata["calibre.pages"] == "320")
        #expect(variantRecord.rawMetadata["calibre.lccn"] == "2018049465")
    }

    @Test
    func resolvesFormatsAndCovers() throws {
        let library = try makeLibrary()

        let range = try book(1, from: library)
        #expect(range.formats.count == 2)
        #expect(range.formats[0].format == "EPUB")
        #expect(range.formats[0].name == "Range - David Epstein")
        #expect(range.formats[0].size == 1_000)
        #expect(FileManager.default.fileExists(atPath: range.formats[0].sourceURL.path))
        #expect(range.formats[1].format == "PDF")
        #expect(FileManager.default.fileExists(atPath: range.formats[1].sourceURL.path))
        if case .file(let url) = range.cover {
            #expect(url.lastPathComponent == "cover.jpg")
            #expect(FileManager.default.fileExists(atPath: url.path))
        } else {
            Issue.record("expected a cover.jpg file cover")
        }

        // A data row whose file is missing: reported, not thrown.
        let ghost = try book(6, from: library)
        #expect(ghost.formats.count == 1)
        #expect(ghost.formats[0].isMissing)

        // No cover when neither BLOB nor cover.jpg exists.
        let noCover = try book(3, from: library)
        #expect(noCover.cover == nil)

        // Schema variant with a cover BLOB column: blob wins.
        let variant = try CalibreFixture.makeVariantLibrary(
            named: "variant-cover-\(UUID().uuidString)",
            userVersion: 26,
            extraColumns: true
        )
        let blobBook = try book(1, from: variant)
        #expect(blobBook.cover == .blob(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])))
    }

    @Test
    func opfCrossCheckFallsBackWhenDatabaseIncomplete() throws {
        let library = try makeLibrary()
        let record = try book(5, from: library)

        // DB title and authors are empty; the book's metadata.opf fills them.
        #expect(record.title == "Fallback Title")
        #expect(record.authors == [CalibreAuthor(name: "Fallback Author", sort: "Fallback Author")])
        #expect(record.opfPath == "metadata.opf")
    }

    @Test
    func rejectsUnsupportedSchemaVersion() throws {
        let variant = try CalibreFixture.makeVariantLibrary(
            named: "variant-version-\(UUID().uuidString)",
            userVersion: 99,
            extraColumns: false
        )
        #expect(throws: CalibreReaderError.unsupportedSchemaVersion(99)) {
            _ = try CalibreReader.open(libraryURL: variant)
        }
    }

    @Test
    func doesNotModifySourceLibrary() throws {
        let library = try makeLibrary()
        let databaseURL = library.appending(path: "metadata.db")

        let beforeData = try Data(contentsOf: databaseURL)
        let beforeHash = SHA256.hash(data: beforeData).map { String(format: "%02x", $0) }.joined()
        let beforeMtime = try FileManager.default
            .attributesOfItem(atPath: databaseURL.path)[.modificationDate] as? Date

        let reader = try CalibreReader.open(libraryURL: library)
        _ = try reader.books()
        try reader.close()

        let afterData = try Data(contentsOf: databaseURL)
        let afterHash = SHA256.hash(data: afterData).map { String(format: "%02x", $0) }.joined()
        let afterMtime = try FileManager.default
            .attributesOfItem(atPath: databaseURL.path)[.modificationDate] as? Date

        #expect(beforeHash == afterHash)
        #expect(beforeMtime == afterMtime)
    }

    @Test
    func textDatesDecodeWithoutCrash() throws {
        // Regression: some tools (e.g. calibre-web) store pubdate/timestamp as
        // ISO-8601 TEXT ("2019-05-28 00:00:00+00:00") instead of Calibre's
        // Julian REALs. GRDB's strict `as Double?` cast traps on TEXT storage
        // ("could not decode Optional<Double>"), crashing the import; the
        // reader must decode either form.
        let library = try CalibreFixture.makeTextDateLibrary(named: "text-dates-\(UUID().uuidString)")
        let reader = try CalibreReader.open(libraryURL: library)
        defer { try? reader.close() }
        let records = try reader.books()

        let range = records.first { $0.calibreID == 1 }!
        // Same hand-computed dates as the julian-storage test: text storage
        // must resolve to identical instants.
        #expect(range.publicationDate == Date(timeIntervalSince1970: 1_559_001_600))
        #expect(range.addedDate == Date(timeIntervalSince1970: 1_705_276_800))
    }

    @Test
    func opensV27LibraryWithPageCounts() throws {
        // Regression: current Calibre creates user_version 27; the reader
        // pinned to 26 rejected it wholesale. v27 adds books_pages_link and
        // drops the books isbn/lccn/flags columns.
        let library = try CalibreFixture.makeVariantLibrary(
            named: "v27-\(UUID().uuidString)", userVersion: 27, extraColumns: false
        )
        let reader = try CalibreReader.open(libraryURL: library)
        defer { try? reader.close() }
        let summary = try reader.summary()
        #expect(summary.userVersion == 27)

        let records = try reader.books()
        let range = try #require(records.first { $0.calibreID == 1 })
        #expect(range.pages?.pages == 320)
        #expect(range.pages?.algorithm == 2)
    }

    @Test
    func preservesSourceIdentityAndPayload() throws {
        let library = try makeLibrary()
        let record = try book(1, from: library)

        // Source identity and sort keys surface as structured fields and as
        // namespaced raw keys (flat, backward-compatible payload).
        #expect(record.sourceUUID == "uuid-1")
        #expect(record.titleSort == "Range: Why Generalists Triumph in a Specialized World")
        #expect(record.authorSort == "Epstein, David")
        #expect(record.sourcePath == "David Epstein/Range (1)")
        #expect(record.rawMetadata["calibre.uuid"] == "uuid-1")
        #expect(record.rawMetadata["calibre.titleSort"] == "Range: Why Generalists Triumph in a Specialized World")
        #expect(record.rawMetadata["calibre.authorSort"] == "Epstein, David")
        #expect(record.rawMetadata["calibre.sourcePath"] == "David Epstein/Range (1)")
        #expect(record.rawMetadata["calibre.lastModified"] != nil)
        #expect(record.rawMetadata["calibre.originalFormats"] != nil)
        #expect(record.rawMetadata["calibre.customColumns"] != nil)
        // Multi-value link extra surfaces as a parallel key.
        #expect(record.rawMetadata["calibre.custom.shelves.extra"] != nil)
    }

    @Test
    func calibreWebSentinelDateIsNilAndTextSeriesIndexDecodes() throws {
        // calibre-web writes "0101-01-01 00:00:00+00:00" (year-101 sentinel)
        // for missing pubdates — must import as nil, not year 101 — and can
        // create TEXT-affinity series_index tables ("1.5" stored as TEXT).
        // Book 1 exercises the TEXT series_index; book 2 carries the sentinel
        // (book 1's pubdate is asserted by textDatesDecodeWithoutCrash).
        let library = try CalibreFixture.makeTextDateLibrary(named: "sentinel-\(UUID().uuidString)")
        let reader = try CalibreReader.open(libraryURL: library)
        defer { try? reader.close() }
        let records = try reader.books()

        let range = try #require(records.first { $0.calibreID == 1 })
        #expect(range.seriesIndex == 1.5)

        let talent = try #require(records.first { $0.calibreID == 2 })
        #expect(talent.publicationDate == nil)
    }

    @Test
    func opensWALLibraryInReadOnlyDirectory() throws {
        // Calibre's metadata.db is WAL journal mode. A read-only open of a WAL
        // database requires a writable -shm (or writable directory to create
        // one); on macOS 26+ a new TCC restriction additionally blocks SQLite
        // WAL locking on foreign databases, surfacing as SQLITE_AUTH
        // ("SQLite error 23: authorization denied"). The reader must snapshot
        // the database into its own writable temp directory and open the copy,
        // never the source. This test locks the fixture directory down so the
        // -shm cannot be created (the documented read-only-WAL failure mode)
        // and verifies the snapshot path both opens and sees uncheckpointed
        // WAL data.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "wal-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dbURL = root.appending(path: "metadata.db")

        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT NOT NULL DEFAULT '', sort TEXT NOT NULL DEFAULT '', author_sort TEXT NOT NULL DEFAULT '', series_index REAL NOT NULL DEFAULT 0, timestamp REAL NOT NULL DEFAULT 0, pubdate REAL NOT NULL DEFAULT 0, path TEXT NOT NULL DEFAULT '', uuid TEXT NOT NULL DEFAULT '', has_cover BOOL NOT NULL DEFAULT 0, last_modified REAL NOT NULL DEFAULT 0);
                CREATE TABLE data (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, format TEXT NOT NULL COLLATE NOCASE, uncompressed_size INTEGER NOT NULL, name TEXT NOT NULL, UNIQUE(book, format));
                CREATE TABLE library_id (uuid TEXT NOT NULL);
                """)
            try db.execute(sql: "PRAGMA user_version = 26")
            try db.execute(sql: "INSERT INTO library_id(uuid) VALUES ('wal-fixture-uuid')")
            try db.execute(sql: "INSERT INTO books(id, title) VALUES (1, 'Checkpointed Book')")
        }
        try queue.close()

        // A second live connection adds a book WITHOUT checkpointing, so
        // metadata.db-wal holds committed frames while we attempt the open.
        let writer = try DatabaseQueue(path: dbURL.path)
        try writer.write { db in
            try db.execute(sql: "INSERT INTO books(id, title) VALUES (2, 'Wal-Only Book')")
        }
        defer { try? writer.close() }

        // Lock the directory down so SQLite cannot create -shm/-wal here.
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-shm"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }

        let sourceFingerprint = try Self.fingerprint(dbURL)

        let reader = try CalibreReader.open(libraryURL: root)
        defer { try? reader.close() }
        let summary = try reader.summary()

        #expect(summary.userVersion == 26)
        #expect(summary.libraryID == "wal-fixture-uuid")
        #expect(summary.bookCount == 2)
        #expect(summary.titles.contains("Wal-Only Book"))

        let after = try Self.fingerprint(dbURL)
        #expect(after.hash == sourceFingerprint.hash)
        #expect(after.mtime == sourceFingerprint.mtime)
    }

    private static func fingerprint(_ url: URL) throws -> (hash: String, mtime: Date) {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attributes[.modificationDate] as? Date ?? .distantPast
        return (hash, mtime)
    }
}
