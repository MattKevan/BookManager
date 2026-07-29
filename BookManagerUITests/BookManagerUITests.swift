import XCTest

final class BookManagerUITests: XCTestCase {
    func testLaunchesMainWindow() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Book Manager"].waitForExistence(timeout: 5))
    }
}
