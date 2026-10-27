import XCTest

final class CollectionManagerUITests: XCTestCase {
    @MainActor func testFirstLaunchOnboardingAndEmptyLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-onboarding.hasCompleted", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["Skip"].waitForExistence(timeout: 15))
        app.buttons["Skip"].tap()
        XCTAssertTrue(app.staticTexts["No collections yet"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["New collection"].exists)
    }
}
