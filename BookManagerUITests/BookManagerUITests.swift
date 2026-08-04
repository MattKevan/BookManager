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

@MainActor
final class BrowserColumnSwitchTests: XCTestCase {
    /// Regression test: clicking a sidebar category swaps the 2-column
    /// NavigationSplitView for the 3-column one (and back). The swap used to
    /// re-register the detail search item in the window toolbar, tripping
    /// NSToolbar's "duplicate com.apple.SwiftUI.search" assertion (crash on
    /// clicking into a 3-column view). `.searchable` is now attached once at
    /// the layout root, so the swap must be crash-free and the search field
    /// must stay present in both layouts.
    func testCategoryClickSwitchesColumnsWithoutCrashing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // Land in the browser via the create-library flow (hermetic: no
        // dependency on a bookmarked library).
        let create = app.buttons["Create Library"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.click()

        let panel = app.sheets["open-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "open panel did not appear")
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/com.mattkevan.BookManager/Data")
        let target = container.appending(path: "ui-test-browser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        app.typeKey("g", modifierFlags: [.command, .shift])
        let field = panel.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText(target.path)
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        sleep(1)
        let open = panel.buttons["Open"].exists ? panel.buttons["Open"] : panel.buttons["Choose"]
        XCTAssertTrue(open.exists, "no Open/Choose button in panel")
        open.click()

        // 2-column state: sidebar + detail only (no middle-column filter).
        XCTAssertTrue(app.buttons["Add Books"].waitForExistence(timeout: 10),
                      "library did not open after selecting a folder")
        let allBooks = app.staticTexts["All Books"]
        XCTAssertTrue(allBooks.waitForExistence(timeout: 5), "sidebar All Books row missing")
        XCTAssertFalse(app.textFields["Filter"].exists, "middle column visible before any category click")

        // The detail search field must still exist — it is registered once at
        // the layout root, not per split-view column.
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5),
                      "detail search field missing in 2-column layout")

        // Click Authors → 3-column state: the middle column (Filter field)
        // appears. Any crash here fails the next query.
        app.staticTexts["Authors"].click()
        XCTAssertTrue(app.textFields["Filter"].waitForExistence(timeout: 5),
                      "middle column did not appear after clicking Authors")
        XCTAssertTrue(allBooks.exists, "app no longer responsive after 2-col → 3-col switch (crash?)")
        XCTAssertTrue(app.searchFields.firstMatch.exists,
                      "detail search field missing in 3-column layout")

        // Back to All Books → 2-column again.
        allBooks.click()
        XCTAssertTrue(app.textFields["Filter"].waitForNonExistence(timeout: 5),
                      "middle column did not collapse after clicking All Books")
        XCTAssertTrue(app.staticTexts["Authors"].exists,
                      "app no longer responsive after 3-col → 2-col switch (crash?)")

        // Repeated swaps must stay stable.
        app.staticTexts["Authors"].click()
        XCTAssertTrue(app.textFields["Filter"].waitForExistence(timeout: 5),
                      "second 2-col → 3-col switch failed")
        XCTAssertTrue(app.staticTexts["All Books"].exists, "app no longer responsive (crash?)")
    }
}
