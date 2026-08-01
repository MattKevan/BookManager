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

@MainActor
final class LibraryCreationFlowTests: XCTestCase {
    /// Regression test: clicking "Create Library" must present the folder picker,
    /// and completing a folder selection must transition the app into the
    /// browser (the importer's onCompletion used to read a purpose that the
    /// isPresented binding had already cleared — nothing happened).
    func testCreateLibraryTransitionsToBrowser() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let create = app.buttons["Create Library"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.click()

        let panel = app.sheets["open-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "open panel did not appear")

        // Choose a writable folder inside the app's sandbox container.
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/com.mattkevan.BookManager/Data")
        let target = container.appending(path: "ui-test-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        // Cmd+Shift+G opens the "Go to folder" field in the open panel.
        app.typeKey("g", modifierFlags: [.command, .shift])
        let field = panel.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText(target.path)
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        sleep(1)

        let open = panel.buttons["Open"].exists ? panel.buttons["Open"] : panel.buttons["Choose"]
        XCTAssertTrue(open.exists, "no Open/Choose button in panel")
        open.click()

        // The browser (loaded state) exposes the "Add Books" toolbar button.
        XCTAssertTrue(app.buttons["Add Books"].waitForExistence(timeout: 10),
                      "library did not open after selecting a folder")
    }
}
