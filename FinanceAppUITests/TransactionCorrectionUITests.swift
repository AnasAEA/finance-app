import XCTest

/// Exercises the production editor with a disposable, synthetic memory store.
final class TransactionCorrectionUITests: XCTestCase {
    private let app = XCUIApplication()

    private func openTransaction() {
        continueAfterFailure = false
        app.launchArguments = ["-useAuditRecoveryPreview", "-startTab", "activity", "-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"]
        app.launch()
        let row = app.buttons[AutomationTokenMirror.transaction("live:audit-ui-expense")]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 5))
        app.swipeUp()
        let correct = app.buttons["transaction.correctMetadata"]
        XCTAssertTrue(correct.waitForExistence(timeout: 5))
        correct.tap()
        XCTAssertTrue(app.navigationBars["Correct transaction"].waitForExistence(timeout: 5))
    }

    func testSaveUpdatesDetailAndShowsHistory() {
        openTransaction()
        let field = app.textFields["transaction.correctionMerchant"]
        field.tap()
        field.typeText("SYNTHETIC CORRECTED SHOP")
        app.buttons["transaction.saveCorrection"].tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Correction history"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Merchant: No custom name → SYNTHETIC CORRECTED SHOP"].exists)
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["SYNTHETIC CORRECTED SHOP"].exists)
    }

    func testCancelLeavesDetailAndHistoryUnchanged() {
        openTransaction()
        let field = app.textFields["transaction.correctionMerchant"]
        field.tap()
        field.typeText("SYNTHETIC CANCELLED")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Correction history"].exists)
        app.swipeDown()
        XCTAssertFalse(app.staticTexts["SYNTHETIC CANCELLED"].exists)
    }

    func testCategoryPickerUpdatesDetailAndShowsHistory() {
        openTransaction()
        app.buttons["transaction.correctionCategory"].tap()
        let transport = app.buttons["Transport"].firstMatch
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        transport.tap()
        app.buttons["transaction.saveCorrection"].tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Category: Uncategorized → Transport"].waitForExistence(timeout: 5))
        app.swipeDown()
        let category = app.descendants(matching: .any)["transaction.category"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        XCTAssertTrue(category.label.contains("Transport"))
    }

    func testRefusedSaveKeepsTheEnteredName() {
        openTransaction()
        let field = app.textFields["transaction.correctionMerchant"]
        field.tap()
        let text = String(repeating: "X", count: 201)
        field.typeText(text)
        app.buttons["transaction.saveCorrection"].tap()
        XCTAssertTrue(app.alerts["Not corrected"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.navigationBars["Correct transaction"].exists)
        XCTAssertEqual(field.value as? String, text)
    }
}
