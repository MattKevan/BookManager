import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct CalibreMetadataCacheTests {
    /// A `metadata.calibre`-shaped document (Calibre's JSON array of book
    /// objects) with an unknown field on one entry to prove round-trip
    /// preservation.
    private func sampleJSON() -> Data {
        Data("""
        [
          {"lpath": "documents/Alpha - One.mobi", "size": 100, "title": "Alpha One", "authors": ["A Author"], "mime": "application/x-mobipocket-ebook", "pages": -3, "comments": "keep me"},
          {"lpath": "documents/Beta.epub", "size": 200, "title": "Beta", "authors": ["B Author"], "mime": "application/epub+zip"}
        ]
        """.utf8)
    }

    @Test
    func parsesArrayAndMatchesByLowercasedPathAndExactSize() {
        let cache = CalibreCache(jsonData: sampleJSON())

        #expect(cache.entries.count == 2)

        // Case-insensitive path match + exact size → hit with cached fields.
        let hit = DeviceFile(name: "Alpha - One.mobi", path: "Documents/Alpha - One.mobi", size: 100)
        let entry = cache.entry(matching: hit)
        #expect(entry?.title == "Alpha One")
        #expect(entry?.authors == ["A Author"])
        #expect(entry?.isDRM == true)

        // Same path, different size → miss (size is the freshness key).
        let wrongSize = DeviceFile(name: "Alpha - One.mobi", path: "Documents/Alpha - One.mobi", size: 101)
        #expect(cache.entry(matching: wrongSize) == nil)

        // Unknown path → miss.
        let unknown = DeviceFile(name: "Gamma.mobi", path: "Documents/Gamma.mobi", size: 100)
        #expect(cache.entry(matching: unknown) == nil)
    }

    @Test
    func mergedDataPatchesInPlacePreservingUnknownFieldsAndUntouchedBooks() throws {
        let cache = CalibreCache(jsonData: sampleJSON())

        let update = CalibreCacheEntry(
            lpath: "documents/alpha - one.mobi", size: 150, title: "Alpha One Revised",
            authors: ["A Author", "Second Author"], mime: "application/x-mobipocket-ebook", pages: nil
        )
        let addition = CalibreCacheEntry(
            lpath: "documents/New.mobi", size: 300, title: "New Book",
            authors: [], mime: nil, pages: -3
        )

        let data = cache.mergedData(updating: [update], adding: [addition])
        let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        #expect(objects.count == 3)

        // Updated entry: patched fields replaced, unknown field preserved,
        // nil pages removed the key.
        let alpha = try #require(objects.first { ($0["lpath"] as? String)?.lowercased() == "documents/alpha - one.mobi" })
        #expect(alpha["title"] as? String == "Alpha One Revised")
        #expect(alpha["authors"] as? [String] == ["A Author", "Second Author"])
        #expect((alpha["size"] as? NSNumber)?.int64Value == 150)
        #expect(alpha["comments"] as? String == "keep me")
        #expect(alpha["pages"] == nil)

        // Untouched book: byte-content unchanged in the values that matter.
        let beta = try #require(objects.first { ($0["lpath"] as? String) == "documents/Beta.epub" })
        #expect(beta["title"] as? String == "Beta")
        #expect(beta["mime"] as? String == "application/epub+zip")
        #expect(beta["pages"] == nil)

        // Appended addition carries its fields.
        let added = try #require(objects.first { ($0["lpath"] as? String) == "documents/New.mobi" })
        #expect(added["title"] as? String == "New Book")
        #expect((added["pages"] as? NSNumber)?.intValue == -3)
    }

    @Test
    func malformedDocumentYieldsEmptyCache() {
        let cache = CalibreCache(jsonData: Data("not json at all".utf8))
        #expect(cache.entries.isEmpty)
    }

    @Test
    func entryWithoutLpathIsSkipped() {
        let cache = CalibreCache(jsonData: Data("""
        [{"size": 5, "title": "No Path"}, {"lpath": "documents/ok.mobi", "size": 9, "title": "Ok"}]
        """.utf8))
        #expect(cache.entries.count == 1)
        #expect(cache.entries.first?.lpath == "documents/ok.mobi")
    }
}
