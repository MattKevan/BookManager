import XCTest

final class BookManagerUITests: XCTestCase {
    func testWelcomeScreenExposesLibraryActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        XCTAssertTrue(app.buttons["Create Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open Library"].exists)
        XCTAssertTrue(app.staticTexts["Your books, in a library you control."].exists)
    }
}
