#if os(iOS)
import XCTest

/// Uses test-only local stores. CloudKit is unavailable in this launch mode;
/// opening its recovery UI is not evidence of signed invitation delivery.
final class ReleaseFlowsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testBarcodeRulePersistsAndValidationPreservesDraft() {
        let app = launch()
        defer { app.terminate() }
        createCollection(in: app, name: "Barcode rule fixture")
        openCollectionRules(in: app)
        let rule = app.switches["Require barcode"].firstMatch
        reveal(rule, in: app)
        XCTAssertTrue(rule.exists)
        rule.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: rule)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        finishCollectionRules(in: app)

        app.terminate()
        app.launch()
        if !app.buttons["Add item"].firstMatch.waitForExistence(timeout: 5) {
            let collection = app.cells.containing(.staticText, identifier: "Barcode rule fixture").firstMatch
            XCTAssertTrue(collection.waitForExistence(timeout: 10))
            collection.tap()
        }
        openCollectionRules(in: app)
        reveal(rule, in: app)
        XCTAssertEqual(rule.value as? String, "1")
        finishCollectionRules(in: app)

        app.buttons["Add item"].firstMatch.tap()
        let title = app.textFields["Title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Validated barcode item")
        app.buttons["Save"].firstMatch.tap()
        let explanation = app.staticTexts["A barcode is required for this collection. Add a valid barcode before saving the item."].firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        if app.alerts.buttons["OK"].exists { app.alerts.buttons["OK"].tap() }
        reveal(title, in: app)
        XCTAssertEqual(title.value as? String, "Validated barcode item")
        let barcode = app.textFields["Barcode"].firstMatch
        reveal(barcode, in: app, upward: false)
        XCTAssertTrue(barcode.exists)
        barcode.tap()
        barcode.typeText("036000291452")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Validated barcode item"].firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    func testStatusFilterTitleSortAndOfflineSharingRecovery() {
        let app = launch()
        defer { app.terminate() }
        createCollection(in: app, name: "Filter fixture")
        addItem(in: app, title: "Zebra release fixture")
        addItem(in: app, title: "Alpha release fixture", status: "Consumed")

        app.buttons["Want to Try"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Zebra release fixture"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Alpha release fixture"].exists)
        app.buttons["All"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Alpha release fixture"].firstMatch.waitForExistence(timeout: 5))

        let sort = app.buttons["Recently updated"].firstMatch
        for _ in 0..<6 where !sort.isHittable {
            // Card layout has a vertical content scroller and a horizontal
            // filter bar; scroll the bar to reveal its sort control.
            app.scrollViews.element(boundBy: 1).swipeLeft()
        }
        XCTAssertTrue(sort.isHittable)
        sort.tap()
        app.buttons["Title"].firstMatch.tap()
        let alpha = app.staticTexts["Alpha release fixture"].firstMatch
        let zebra = app.staticTexts["Zebra release fixture"].firstMatch
        XCTAssertTrue(alpha.exists && zebra.exists)
        XCTAssertLessThan(alpha.frame.minY, zebra.frame.minY)

        openMore(in: app)
        app.buttons["Share collection"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Sharing is not ready"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Invite people"].exists)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(alpha.waitForExistence(timeout: 5))
        XCTAssertTrue(zebra.exists)
    }

    @MainActor
    func testCredentialSettingsAndRealCSVReviewImport() {
        let app = launch(csvFixture: true)
        defer { app.terminate() }
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        let key = app.secureTextFields["API key"].firstMatch
        reveal(key, in: app)
        XCTAssertTrue(key.exists)
        XCTAssertFalse(app.buttons["Save API key"].firstMatch.isEnabled)
        let disclosure = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Games EAN lookup requires your own API key.")).firstMatch
        reveal(disclosure, in: app)
        XCTAssertTrue(disclosure.exists)
        // Do not read, replace or remove a saved credential to test the empty
        // input state. Missing-key request behavior has injected unit tests.
        // Start the next local flow from the library rather than depending on
        // platform-specific sheet drag distances or changing any credential.
        app.terminate()
        app.launch()

        createCollection(in: app, name: "CSV review fixture")
        openMore(in: app)
        app.buttons["Import CSV"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Import CSV"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["CSV fixture item"].firstMatch.exists)
        let review = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Review ")).firstMatch
        XCTAssertTrue(review.isEnabled)
        review.tap()
        XCTAssertTrue(app.navigationBars["Review import"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["CSV fixture item"].firstMatch.exists)
        app.buttons["Import 1"].firstMatch.tap()
        let imported = app.staticTexts["CSV fixture item"].firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 10))
        imported.tap()
        XCTAssertTrue(app.textFields["Title"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["Title"].firstMatch.value as? String, "CSV fixture item")
        XCTAssertEqual(app.textFields["Brand"].firstMatch.value as? String, "Example")
        XCTAssertTrue(app.steppers["Quantity: 2"].exists)
    }

    @MainActor
    private func launch(csvFixture: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-onboarding.hasCompleted", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CM_TEST_STORE_NAME"] = UUID().uuidString
        if csvFixture { app.launchEnvironment["CM_TEST_CSV_FIXTURE"] = "basic" }
        app.launch()
        return app
    }

    @MainActor
    private func createCollection(in app: XCUIApplication, name: String) {
        XCTAssertTrue(app.buttons["New collection"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["New collection"].firstMatch.tap()
        let field = app.textFields["Collection name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.buttons["Create"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Add item"].firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    private func openMore(in app: XCUIApplication) { app.buttons["More"].firstMatch.tap() }

    @MainActor
    private func openCollectionRules(in app: XCUIApplication) {
        openMore(in: app)
        app.buttons["Edit collection"].firstMatch.tap()
        let customize = app.buttons["Customize statuses and metadata"].firstMatch
        reveal(customize, in: app)
        XCTAssertTrue(customize.exists)
        customize.tap()
    }

    @MainActor
    private func finishCollectionRules(in app: XCUIApplication) {
        let done = app.buttons["Done"].firstMatch
        for _ in 0..<8 where !done.exists { app.collectionViews.element(boundBy: app.collectionViews.count - 1).swipeDown() }
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.buttons["Save"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Add item"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func addItem(in app: XCUIApplication, title: String, status: String? = nil) {
        app.buttons["Add item"].firstMatch.tap()
        let field = app.textFields["Title"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(title)
        if let status {
            let statusPicker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Status,")).firstMatch
            reveal(statusPicker, in: app)
            statusPicker.tap()
            app.buttons[status].firstMatch.tap()
        }
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        for _ in 0..<7 where !element.isHittable {
            let form = app.collectionViews.element(boundBy: max(0, app.collectionViews.count - 1))
            if upward { form.swipeUp() } else { form.swipeDown() }
        }
    }
}
#endif
