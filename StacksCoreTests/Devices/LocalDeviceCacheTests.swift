import Foundation
import Testing
@testable import StacksCore

@Suite
struct LocalDeviceCacheTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func snapshot(key: String = "1949-9981") -> LocalDeviceSnapshot {
        LocalDeviceSnapshot(
            key: key,
            records: [
                LocalCachedBook(
                    fileName: "Book.azw3",
                    filePath: "Documents/Book.azw3",
                    fileSize: 10,
                    title: "A Real Title",
                    authors: ["A. Author"],
                    format: "AZW3",
                    isDRM: true,
                    isEnriched: true
                )
            ],
            savedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test
    func roundTripsSnapshot() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = LocalDeviceCache(directory: dir)
        try cache.save(snapshot())

        let loaded = try cache.load(key: "1949-9981")
        #expect(loaded == snapshot())
        #expect(loaded?.records.first?.title == "A Real Title")
        #expect(loaded?.records.first?.isDRM == true)
    }

    @Test
    func missingKeyReturnsNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = LocalDeviceCache(directory: dir)
        #expect(try cache.load(key: "1234-5678") == nil)
    }

    @Test
    func corruptFileReturnsNilNotThrows() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = LocalDeviceCache(directory: dir)
        // The cache reads the SANITIZED filename ("19499981.json"), so the
        // garbage must be written there to exercise the corrupt-decode path
        // rather than the missing-file guard.
        try Data("not json".utf8).write(to: dir.appending(path: "19499981.json"))
        #expect(try cache.load(key: "1949-9981") == nil)
    }

    @Test
    func deleteRemovesFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = LocalDeviceCache(directory: dir)
        try cache.save(snapshot())
        cache.delete(key: "1949-9981")
        #expect(try cache.load(key: "1949-9981") == nil)
    }

    @Test
    func sanitizesKeyForFilename() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = LocalDeviceCache(directory: dir)
        try cache.save(snapshot(key: "19/49:9981"))
        let loaded = try cache.load(key: "19/49:9981")
        #expect(loaded != nil)
        #expect(loaded?.records.first?.title == "A Real Title")
        // The key "19/49:9981" sanitizes to "19499981.json" on disk.
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "19499981.json").path))
    }

    @Test
    func overwriteReplacesPreviousSnapshot() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = LocalDeviceCache(directory: dir)
        try cache.save(snapshot())
        let second = LocalDeviceSnapshot(
            key: "1949-9981",
            records: [LocalCachedBook(
                fileName: "New.epub", filePath: "Documents/New.epub", fileSize: 20,
                title: "Newer", authors: [], format: "EPUB", isDRM: false, isEnriched: false
            )],
            savedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        try cache.save(second)

        let loaded = try cache.load(key: "1949-9981")
        #expect(loaded == second)
        #expect(loaded?.records.first?.title == "Newer")
    }
}
