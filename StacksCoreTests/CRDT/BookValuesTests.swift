import XCTest
@testable import StacksCore

final class BookValuesTests: XCTestCase {
    func testEmptyEditIsEmpty() {
        XCTAssertTrue(BookEdit().isEmpty)
    }

    func testNilFieldsAndKeepAreEmpty() {
        let edit = BookEdit(
            title: nil,
            authors: nil,
            series: .keep,
            seriesIndex: .keep,
            tags: nil,
            rating: .keep,
            publisher: .keep,
            publicationDate: .keep,
            languages: nil,
            identifiers: nil,
            comments: .keep
        )
        XCTAssertTrue(edit.isEmpty)
    }

    func testAnySetFieldIsNotEmpty() {
        let titleEdit = BookEdit(title: "Renamed")
        XCTAssertFalse(titleEdit.isEmpty)

        let clearRating = BookEdit(rating: .clear)
        XCTAssertFalse(clearRating.isEmpty)

        let setSeries = BookEdit(series: .set("Dune"))
        XCTAssertFalse(setSeries.isEmpty)

        let newTags = BookEdit(tags: ["SciFi"])
        XCTAssertFalse(newTags.isEmpty)

        let newIdentifier = BookEdit(identifiers: ["isbn": "123"])
        XCTAssertFalse(newIdentifier.isEmpty)
    }

    func testDateSetIsNotEmpty() {
        let dateEdit = BookEdit(publicationDate: .set(Date(timeIntervalSince1970: 0)))
        XCTAssertFalse(dateEdit.isEmpty)
    }
}
