import XCTest

/// Whether the Trusted Automation switch is on screen, read off the running app.
///
/// The unit suite proves the predicate and the sentences. What only a running
/// app can show is whether a toggle a person could actually press is present,
/// because a SwiftUI view's controls cannot be enumerated from a unit test.
///
/// Two ends are covered here: a build with no sync service, where the switch
/// must not exist, and a paired one, where it must still work. The middle
/// states — unpaired and revoked — keep the switch for the same reason paired
/// does, and are covered by render and behaviour tests in
/// `TrustedAutomationCapabilityTests`.
final class TrustedAutomationCapabilityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// The contradiction this slice closes: a switch over bank evidence on a
    /// build that can never receive any.
    func testUnconfiguredBuildOffersNoAutomationToggle() {
        launch(arguments: ["-useEmptyPreview"], route: "automation")
        XCTAssertTrue(app.navigationBars["Automation"].waitForExistence(timeout: 8))

        XCTAssertTrue(app.descendants(matching: .any)["automation.unavailable"].exists)
        XCTAssertTrue(app.staticTexts["Automation unavailable"].exists)
        // No control, of any kind, that claims to turn it on.
        assertNoSwitchAnywhere()
    }

    /// The row a person taps to get there says the same thing, so they are not
    /// invited in under a promise the screen cannot keep.
    func testSettingsAutomationRowAgreesWithBanksRow() {
        launch(arguments: ["-useEmptyPreview"], route: "settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))

        let automation = app.descendants(matching: .any)["settings.automation"]
        XCTAssertTrue(automation.waitForExistence(timeout: 5))
        XCTAssertTrue(automation.label.contains("Not available on this build"))
        XCTAssertFalse(automation.label.contains("trusted rule"))

        // The two rows describe one build and must not disagree about it.
        let banks = app.descendants(matching: .any)["settings.banks"]
        XCTAssertTrue(banks.exists)
        XCTAssertTrue(banks.label.contains("Not available on this build"))
    }

    /// Unchanged where the capability exists.
    func testPairedBuildStillOffersTheAutomationToggle() {
        launch(arguments: ["-useBankInboxPreview"], route: "automation")
        XCTAssertTrue(app.navigationBars["Automation"].waitForExistence(timeout: 8))

        let toggle = app.switches["Trusted Automation"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Automation unavailable"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["automation.unavailable"].exists)

        // It is a real control, not a disabled ornament.
        XCTAssertTrue(toggle.isEnabled)
        toggle.tap()
        XCTAssertTrue(app.navigationBars["Automation"].exists)
    }

    /// Banks & Sync on a build with no sync service states that fact once. The
    /// automation section is omitted there rather than repeating it under a
    /// second heading.
    func testUnconfiguredBanksScreenDoesNotRepeatTheAutomationControl() {
        launch(arguments: ["-useEmptyPreview"], route: "banks")
        XCTAssertTrue(app.navigationBars["Banks & Sync"].waitForExistence(timeout: 8))

        XCTAssertTrue(app.staticTexts["Bank sync is not configured"].exists)
        assertNoSwitchAnywhere()
    }

    /// And keeps it where the capability exists.
    ///
    /// The paired screen carries sync, connections, accounts and the device
    /// section above this one, so the control starts below the fold and a
    /// SwiftUI `List` has not built the row yet. Scrolling to it is the
    /// difference between "absent" and "not yet on screen", and asserting
    /// without doing so would have read as the former.
    func testPairedBanksScreenKeepsTheAutomationControl() {
        launch(arguments: ["-useBankInboxPreview", "-visualScreen", "bankSyncConnected"])
        XCTAssertTrue(app.navigationBars["Banks & Sync"].waitForExistence(timeout: 8))

        XCTAssertTrue(revealSwitch("Trusted Automation").exists)
    }

    /// Proves a switch is absent from the *whole* screen, not merely from the
    /// part of it currently visible.
    ///
    /// A SwiftUI `List` builds rows lazily, so a control restored at the bottom
    /// of a long screen is not in the tree until something scrolls to it — and
    /// a bare `XCTAssertEqual(app.switches.count, 0)` would then pass while the
    /// regression it exists to catch sat one swipe away.
    private func assertNoSwitchAnywhere(
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for _ in 0..<6 {
            XCTAssertEqual(app.switches.count, 0, "a switch is reachable", file: file, line: line)
            app.swipeUp()
        }
        XCTAssertEqual(app.switches.count, 0, "a switch is reachable", file: file, line: line)
    }

    /// Swipes until the named switch exists, or gives up and returns it absent
    /// so the assertion reports the real state rather than timing out.
    private func revealSwitch(_ label: String) -> XCUIElement {
        let target = app.switches[label]
        var attempts = 0
        while !target.exists && attempts < 12 {
            app.swipeUp()
            attempts += 1
        }
        return target
    }

    private func launch(arguments: [String], route: String? = nil) {
        var all = ["-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"] + arguments
        if let route { all += ["-startRoute", route] }
        app.launchArguments = all
        app.launch()
    }
}
