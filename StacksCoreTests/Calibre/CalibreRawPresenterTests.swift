import Foundation
import Testing
@testable import StacksCore

@Suite
struct CalibreRawPresenterTests {
    private func definitionsJSON(_ defs: [String: [String: Any]]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: defs)
        return String(decoding: data, as: UTF8.self)
    }

    @Test
    func customColumnsUseFriendlyNamesFromDefinitions() {
        let defs = definitionsJSON([
            "genre": ["name": "Genre", "datatype": "text", "display": "{}", "isMultiple": false, "editable": true, "normalized": false]
        ])
        let rows = CalibreRawPresenter.rows(from: [
            "calibre.customColumns": defs,
            "calibre.custom.genre": "science",
        ])
        #expect(rows.contains { $0.label == "Genre" && $0.value == "science" })
        #expect(!rows.contains { $0.label == "genre" })
    }

    @Test
    func multiValueCustomColumnsJoinAndPairExtras() {
        let defs = definitionsJSON([
            "shelves": ["name": "Shelves", "datatype": "text", "display": "{}", "isMultiple": true, "editable": true, "normalized": false]
        ])
        let rows = CalibreRawPresenter.rows(from: [
            "calibre.customColumns": defs,
            "calibre.custom.shelves": "[\"read\",\"favorites\"]",
            "calibre.custom.shelves.extra": "[\"0.5\",\"\"]",
        ])
        let shelf = rows.first { $0.id == "calibre.custom.shelves" }
        #expect(shelf?.label == "Shelves")
        #expect(shelf?.value.contains("read") == true)
        #expect(shelf?.value.contains("favorites") == true)
        #expect(shelf?.value.contains("0.5") == true)
    }

    @Test
    func scalarKeysRenderInFixedOrderWithPagesUnknown() {
        let rows = CalibreRawPresenter.rows(from: [
            "calibre.pages": "0",
            "calibre.uuid": "uuid-1",
            "calibre.titleSort": "Range",
            "calibre.sourcePath": "David Epstein/Range (1)",
            "calibre.conversionOptions": "[{\"format\":\"EPUB\",\"data\":\"AQID\"}]",
            "calibre.originalFormats": "[{\"format\":\"EPUB\",\"name\":\"Range - David Epstein\"},{\"format\":\"MOBI\",\"name\":\"Range - David Epstein\"}]",
        ])
        let labels = rows.map(\.label)
        #expect(labels == ["Calibre UUID", "Title Sort", "Source Path", "Pages", "Conversion Options", "Original Formats"])
        #expect(rows.first { $0.label == "Pages" }?.value == "Unknown")
        #expect(rows.first { $0.label == "Conversion Options" }?.value == "1 format")
        #expect(rows.first { $0.label == "Original Formats" }?.value == "EPUB, MOBI")
    }

    @Test
    func malformedPayloadDegradesToRawRowsWithoutThrowing() {
        let rows = CalibreRawPresenter.rows(from: [
            "calibre.customColumns": "not-json",
            "calibre.custom.genre": "science",
            "calibre.conversionOptions": "not-json",
        ])
        // Unknown definition: the label falls back to the raw key suffix.
        #expect(rows.contains { $0.label == "genre" && $0.value == "science" })
        // Malformed scalar JSON: raw value, no crash.
        #expect(rows.contains { $0.label == "Conversion Options" && $0.value == "not-json" })
    }
}
