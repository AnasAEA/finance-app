import XCTest

/// Production review/confirmation screens, backed by disposable synthetic data.
final class TransactionFinancialCorrectionUITests: XCTestCase {
    private let app = XCUIApplication()

    private func openEditor() {
        continueAfterFailure = false
        app.launchArguments = ["-useFinancialCorrectionPreview", "-startTab", "activity", "-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"]
        app.launch()
        let row = app.buttons[AutomationTokenMirror.transaction("live:audit-ui-expense")]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 5))
        let correct = app.buttons["transaction.correctFinancials"]
        for _ in 0..<8 where !correct.exists || !correct.isHittable { app.swipeUp() }
        XCTAssertTrue(correct.exists)
        correct.tap()
        XCTAssertTrue(app.navigationBars["Correct financial details"].waitForExistence(timeout: 5))
    }

    private func typeAmount(_ text: String) {
        let field = app.textFields["transaction.financialAmount"]
        XCTAssertTrue(field.exists)
        field.tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }

    private func reason() {
        let field = app.descendants(matching: .any)["transaction.financialReason"]
        field.tap()
        field.typeText("SYNTHETIC corrected receipt")
    }

    private func review() {
        app.buttons["transaction.reviewFinancialCorrection"].tap()
        XCTAssertTrue(app.navigationBars["Review correction"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["transaction.confirmFinancialCorrection"].exists)
        XCTAssertFalse(app.textFields["transaction.financialAmount"].exists)
    }

    private func expectOriginalAfterCancel() {
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Financial correction history"].exists)
        app.swipeDown()
        let amount = app.staticTexts["transaction.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCTAssertTrue(amount.label.contains("1.00"))
    }

    func testReviewThenCancelLeavesOriginalDetails() {
        openEditor()
        typeAmount("20.00")
        reason()
        review()
        expectOriginalAfterCancel()
    }

    func testEditReviewKeepsFieldsAndStillRequiresConfirmation() {
        openEditor()
        typeAmount("20.00")
        reason()
        review()
        let edit = app.buttons["Edit correction"]
        for _ in 0..<8 where !edit.exists || !edit.isHittable { app.swipeUp() }
        edit.tap()
        XCTAssertTrue(app.navigationBars["Correct financial details"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["transaction.financialAmount"].value as? String, "20.00")
        XCTAssertEqual(app.descendants(matching: .any)["transaction.financialReason"].value as? String, "SYNTHETIC corrected receipt")
        expectOriginalAfterCancel()
    }

    func testConfirmedAmountAndAccountUpdateDetailAndHistory() {
        openEditor()
        app.buttons["transaction.financialAccount"].tap()
        let wallet = app.buttons["Synthetic wallet"].firstMatch
        XCTAssertTrue(wallet.waitForExistence(timeout: 5))
        wallet.tap()
        typeAmount("20.00")
        reason()
        review()
        app.buttons["transaction.confirmFinancialCorrection"].tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 5))
        let history = app.staticTexts["Financial correction history"]
        for _ in 0..<8 where !history.exists { app.swipeUp() }
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["SYNTHETIC corrected receipt"].exists)
        let after = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'After:' AND label CONTAINS 'Synthetic wallet'" )).firstMatch
        XCTAssertTrue(after.exists)
        app.swipeDown()
        let amount = app.staticTexts["transaction.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCTAssertTrue(amount.label.contains("20.00"))
    }

    func testExcessPrecisionRefusesReviewAndRetainsFields() {
        openEditor()
        typeAmount("20.001")
        reason()
        app.buttons["transaction.reviewFinancialCorrection"].tap()
        XCTAssertTrue(app.alerts["Not corrected"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.navigationBars["Correct financial details"].exists)
        XCTAssertEqual(app.textFields["transaction.financialAmount"].value as? String, "20.001")
        XCTAssertFalse(app.buttons["transaction.confirmFinancialCorrection"].exists)
    }
}
