import XCTest

/// Repeatable visual specimens plus reachability checks. All writes are to
/// explicit in-memory previews; screenshots are test attachments, not fixtures.
final class VisualExperienceUITests: XCTestCase {
    private let app = XCUIApplication()

    private func launch(_ arguments: [String]) {
        app.launchArguments = arguments + ["-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTransactionStoryAndReserveWarning() {
        continueAfterFailure = false
        launch(["-useAuditRecoveryPreview", "-startTab", "activity"])
        let transaction = app.buttons[AutomationTokenMirror.transaction("live:audit-ui-expense")]
        XCTAssertTrue(transaction.waitForExistence(timeout: 8))
        transaction.tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 8))
        capture("transaction-detail")
        app.swipeUp()
        capture("transaction-actions")

        launch(["-HCIPrototype", "-HCIPrototypeVariant", "positive", "-startRoute", "reserve"])
        let field = app.textFields["reserve.amount"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("3000")
        app.buttons["reserve.save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["reserve.saved"].waitForExistence(timeout: 5))
        capture("reserve-saved")
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["tab.home"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home.safe"].waitForExistence(timeout: 8))
        capture("home-reserve-warning")
        app.tabBars.buttons["tab.plan"].tap()
        capture("plan-reserve-warning")
    }
}
