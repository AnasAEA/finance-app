import XCTest

/// The production guide on synthetic disposable, memory-only account evidence.
final class BalanceReconciliationUITests: XCTestCase {
    private let app = XCUIApplication()

    private func openAccount() {
        continueAfterFailure = false
        app.launchArguments = ["-useBalanceReviewPreview", "-startRoute", "accounts", "-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Synthetic account'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Synthetic account"].waitForExistence(timeout: 5))
    }
    private func openGuide(_ label: String) {
        let link = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        for _ in 0..<6 where !link.exists || !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.exists)
        link.tap()
        XCTAssertTrue(app.navigationBars["Review balance"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["balance.reconciliationGuide"].exists)
    }
    func testAccountRouteShowsDatedBookedComparisonAndExplicitReviewDestination() {
        openAccount()
        openGuide("Closing booked balance")
        XCTAssertTrue(app.staticTexts["Closing booked balance"].exists)
        let reference = app.descendants(matching: .any)["balance.referenceDate"]
        XCTAssertTrue(reference.exists)
        XCTAssertTrue(reference.label.contains("2026-09-26"))
        let comparison = app.descendants(matching: .any)["balance.diagnosticDifference"]
        for _ in 0..<6 where !comparison.exists || !comparison.isHittable { app.swipeUp() }
        XCTAssertTrue(comparison.exists)
        let item = app.buttons.matching(NSPredicate(format: "label CONTAINS 'SYNTHETIC bank debit'")).firstMatch
        for _ in 0..<6 where !item.exists || !item.isHittable { app.swipeUp() }
        XCTAssertTrue(item.exists)
        XCTAssertFalse(app.buttons["Confirm correction"].exists)
        item.tap()
        XCTAssertTrue(app.staticTexts["SYNTHETIC bank debit"].waitForExistence(timeout: 5))
    }
    func testExpectedBalanceIsNotPresentedAsBookedOrVerified() {
        openAccount()
        openGuide("Expected balance")
        XCTAssertTrue(app.staticTexts["Expected balance"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'not a booked statement balance'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Matches ledger"].exists)
        XCTAssertFalse(app.buttons["Mark reconciled"].exists)
        let account = app.buttons["Account details"]
        for _ in 0..<8 where !account.exists || !account.isHittable { app.swipeUp() }
        XCTAssertTrue(account.exists)
        account.tap()
        XCTAssertTrue(app.navigationBars["Synthetic account"].waitForExistence(timeout: 5))
    }
}
