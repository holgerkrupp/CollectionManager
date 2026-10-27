import XCTest
#if os(iOS)
import UIKit
#endif

final class CollectionManagerUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func launch(onboarding: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "-onboarding.hasCompleted", onboarding ? "NO" : "YES",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"
        ]
        // The app derives the path inside its own temporary container, which
        // differs from the runner's container on iOS. The name survives relaunch.
        app.launchEnvironment["CM_TEST_STORE_NAME"] = UUID().uuidString
        app.launch()
        return app
    }

    @MainActor
    func testFirstLaunchOnboardingAndEmptyLibrary() throws {
        let app = launch(onboarding: true)
        defer { finish(app) }
        XCTAssertTrue(app.buttons["Skip"].waitForExistence(timeout: 15))
        app.buttons["Skip"].tap()
        #if os(iOS)
        // Compact NavigationSplitView starts on its sidebar; the empty detail
        // placeholder is intentionally not visible until a collection opens.
        XCTAssertTrue(app.staticTexts["Your collections"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["UI smoke collection"].exists)
        #else
        XCTAssertTrue(app.staticTexts["No collections yet"].waitForExistence(timeout: 10))
        #endif
        XCTAssertTrue(app.buttons["New collection"].exists)
    }

    @MainActor
    func testCreateCollectionAddEditSearchAndDeleteItem() throws {
        let app = launch(onboarding: false)
        defer { finish(app) }
        try createCollection(in: app, name: "UI smoke collection")

        let add = app.buttons["Add item"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let title = app.textFields["Title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("UI smoke item")
        app.buttons["Save"].firstMatch.tap()

        let saved = app.staticTexts["UI smoke item"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        saved.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        replace(title, with: "UI edited item")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["UI edited item"].firstMatch.waitForExistence(timeout: 10))

        let search = app.searchFields.firstMatch
        if !search.exists, app.buttons["Search"].firstMatch.exists { app.buttons["Search"].firstMatch.tap() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("No matching item")
        XCTAssertTrue(app.staticTexts["UI edited item"].firstMatch.waitForNonExistence(timeout: 5))
        replace(search, with: "UI edited")
        XCTAssertTrue(app.staticTexts["UI edited item"].firstMatch.waitForExistence(timeout: 5))
        replace(search, with: "")

        app.staticTexts["UI edited item"].firstMatch.tap()
        let delete = app.buttons["Delete item"].firstMatch
        #if os(iOS)
        // Form lazily creates rows beyond the viewport. Reach the explicit
        // destructive action by scrolling the presented editor, not its card.
        for _ in 0..<5 where !delete.exists {
            app.collectionViews.element(boundBy: app.collectionViews.count - 1).swipeUp()
        }
        #endif
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(app.staticTexts["UI edited item"].firstMatch.waitForNonExistence(timeout: 10))
    }

    #if os(iOS)
    @MainActor
    func testTableDraftSurvivesRepresentationAndRotationOnIPad() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "Table layout requires regular width")
        let app = launch(onboarding: false)
        defer { XCUIDevice.shared.orientation = .portrait; finish(app) }
        try createCollection(in: app, name: "Adaptive drafts")
        app.buttons["Table"].firstMatch.tap()
        let input = app.textFields["Add item…"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText("Uncommitted draft")
        app.segmentedControls.buttons["square.grid.2x2"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Unsaved table edits"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Uncommitted draft"].exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 10), .completed)
        app.buttons["Table"].firstMatch.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, "Uncommitted draft")
        app.segmentedControls.buttons["square.grid.2x2"].firstMatch.tap()
        app.buttons["Revert"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Unsaved table edits"].waitForNonExistence(timeout: 5))
        app.buttons["Table"].firstMatch.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertNotEqual(input.value as? String, "Uncommitted draft")
    }
    #endif

    #if os(macOS)
    @MainActor
    func testCollectionSettingsAndItemSurviveRelaunch() throws {
        let app = launch(onboarding: false)
        defer { finish(app) }
        try createCollection(in: app, name: "UI durable collection")
        app.buttons["Add item"].firstMatch.tap()
        let title = app.textFields["Title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("UI durable item")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["UI durable item"].firstMatch.waitForExistence(timeout: 10))

        let more = app.menuButtons["More"].firstMatch
        if more.exists { more.tap() } else { app.buttons["More"].firstMatch.tap() }
        app.menuItems["Collection settings…"].firstMatch.tap()
        let adding = app.staticTexts["Adding"].firstMatch
        XCTAssertTrue(adding.waitForExistence(timeout: 5))
        adding.tap()
        let requireBarcode = app.checkBoxes["Require barcode"].firstMatch
        XCTAssertTrue(requireBarcode.waitForExistence(timeout: 5))
        requireBarcode.tap()
        app.buttons["Save"].firstMatch.tap()
        XCTAssertEqual(requireBarcode.value as? String, "1")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["UI durable collection"].firstMatch.waitForExistence(timeout: 15))
        app.staticTexts["UI durable collection"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["UI durable item"].firstMatch.waitForExistence(timeout: 10))
        let reopenedMore = app.menuButtons["More"].firstMatch
        if reopenedMore.exists { reopenedMore.tap() } else { app.buttons["More"].firstMatch.tap() }
        app.menuItems["Collection settings…"].firstMatch.tap()
        app.staticTexts["Adding"].firstMatch.tap()
        XCTAssertEqual(app.checkBoxes["Require barcode"].firstMatch.value as? String, "1")
    }
    #endif

    @MainActor
    private func finish(_ app: XCUIApplication) {
        if (testRun?.failureCount ?? 0) > 0 {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Isolated UI hierarchy at failure"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app.terminate()
    }

    @MainActor
    private func createCollection(in app: XCUIApplication, name: String) throws {
        let create = app.buttons["New collection"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        create.tap()
        let nameField = app.textFields["Collection name"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(name)
        app.buttons["Create"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        #if os(macOS)
        field.typeKey("a", modifierFlags: .command)
        #else
        field.press(forDuration: 1)
        let selectAll = XCUIApplication().menuItems["Select All"]
        if selectAll.exists { selectAll.tap() }
        #endif
        field.typeText(text.isEmpty ? XCUIKeyboardKey.delete.rawValue : text)
    }
}
