import XCTest

/// The identifier hygiene a physical automation depends on, pinned on the
/// simulator against the Debug synthetic store.
///
/// The paired-iPhone canary is the acceptance; this is the regression that
/// stops the defects it found from coming back silently.
final class DeviceAccessibilityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - Tabs

    func testEachTabResolvesExactlyOnceAndSurvivesRelaunch() {
        launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))

        let tabs = ["tab.home", "tab.activity", "tab.plan", "tab.insights"]
        for identifier in tabs {
            assertResolvesExactlyOnce(identifier)
        }

        // The identity is the tab's own, not the word or the symbol printed on
        // it: both of those were what the platform invented in their absence.
        for identifier in tabs {
            XCTAssertTrue(app.tabBars.buttons[identifier].exists, "\(identifier) is not on the tab bar")
        }

        app.tabBars.buttons["tab.insights"].tap()
        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 5))
        app.tabBars.buttons["tab.plan"].tap()
        XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: 5))
        app.tabBars.buttons["tab.activity"].tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
        app.tabBars.buttons["tab.home"].tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))

        app.terminate()
        launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        for identifier in tabs {
            assertResolvesExactlyOnce(identifier)
        }
    }

    // MARK: - Funding Needed

    /// `healthySync` is the variant whose primary attention is the funding gap
    /// rather than the bank connection, so Funding Needed has something to
    /// explain. The route opens it directly: which card is primary on a given
    /// day is a product decision, not an automation entry point.
    func testFundingNeededExposesItsSemanticRegions() {
        launch(variant: "healthySync", route: "fundingNeeded")
        XCTAssertTrue(app.navigationBars["Funding Needed"].waitForExistence(timeout: 8))

        for identifier in ["funding.trigger", "funding.date", "funding.due",
                           "funding.covered", "funding.still-needed",
                           "funding.payment-account"] {
            assertResolvesExactlyOnce(identifier)
        }
        // The explanation sits below the fold on this phone.
        revealIdentifier("funding.explanation")
        assertResolvesExactlyOnce("funding.explanation")

        // Roles, not readings: no figure, day or account name is spelled into
        // an identifier on this screen.
        for identifier in ["funding.trigger", "funding.date", "funding.due",
                           "funding.covered", "funding.still-needed",
                           "funding.payment-account", "funding.explanation"] {
            XCTAssertFalse(identifier.contains("€"))
            XCTAssertEqual(identifier, identifier.lowercased())
        }
    }

    // MARK: - Insights

    func testInsightsControlsCarryStableIdentifiers() {
        launch(tab: "insights")
        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 8))

        for identifier in ["insights.scope", "insights.scope.week", "insights.scope.month",
                           "insights.previous", "insights.next", "insights.summary",
                           "insights.show-details"] {
            assertResolvesExactlyOnce(identifier)
        }

        // The scope options select, and the screen stays where it is.
        app.descendants(matching: .any)["insights.scope.week"].tap()
        XCTAssertTrue(app.navigationBars["Insights"].exists)
        app.descendants(matching: .any)["insights.scope.month"].tap()
        XCTAssertTrue(app.navigationBars["Insights"].exists)

        // Data Quality lives behind Show Details, and keeps one identity there.
        app.buttons["insights.show-details"].tap()
        revealIdentifier("insights.coverage")
        assertResolvesExactlyOnce("insights.coverage")
    }

    /// Verification belongs to an ended period, so the current one does not
    /// carry it and the identifiers must not appear before they mean something.
    func testInsightsVerificationIsNamedOnceOnAnEndedPeriod() {
        launch(tab: "insights")
        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 8))
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "insights.verification").count, 0
        )

        app.buttons["insights.previous"].tap()
        let verification = app.descendants(matching: .any)["insights.verification"]
        XCTAssertTrue(verification.waitForExistence(timeout: 5))
        assertResolvesExactlyOnce("insights.verification")
        assertResolvesExactlyOnce("insights.unresolved")
    }

    // MARK: - Activity row identity

    func testActivityRowIdentitiesAreOpaqueAndUnique() {
        launch(tab: "activity")
        XCTAssertTrue(app.buttons["activity.add"].waitForExistence(timeout: 8))
        assertRowIdentitiesAreOpaque()

        app.buttons["To Review"].tap()
        XCTAssertTrue(app.staticTexts["Needs a Decision"].waitForExistence(timeout: 5))
        assertRowIdentitiesAreOpaque()

        // The section header is outside the row namespace, so it never answers
        // a search for a pending row.
        XCTAssertTrue(app.descendants(matching: .any)["activity.pending-section"].exists)
    }

    func testActivityFiltersResolvesExactlyOnce() {
        launch(tab: "activity")
        XCTAssertTrue(app.buttons["activity.add"].waitForExistence(timeout: 8))
        assertResolvesExactlyOnce("activity.filters")
        assertResolvesExactlyOnce("activity.add")
        assertResolvesExactlyOnce("activity.section")
    }

    func testHomeSafeToUseResolvesExactlyOnce() {
        launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        assertResolvesExactlyOnce("home.safe")
        assertResolvesExactlyOnce("home.cash")
        assertResolvesExactlyOnce("home.attention")
    }

    func testAutomationTokenMirrorMatchesTheApp() {
        for vector in AutomationTokenVectors.cases {
            XCTAssertEqual(
                AutomationTokenMirror.opaque(vector.identity), vector.token,
                "the UI-test copy of the token drifted from the app's"
            )
        }
    }

    // MARK: - Helpers

    private func assertRowIdentitiesAreOpaque() {
        var found = 0
        var seen = Set<String>()
        for prefix in AutomationTokenMirror.rowPrefixes {
            let rows = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", prefix)
            )
            for index in 0..<rows.count {
                let identifier = rows.element(boundBy: index).identifier
                let token = String(identifier.dropFirst(prefix.count))
                XCTAssertEqual(token.count, 16, "\(identifier) is not an opaque token")
                XCTAssertTrue(
                    token.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                    "\(identifier) is not an opaque token"
                )
                XCTAssertTrue(seen.insert(identifier).inserted, "\(identifier) is not unique")
                found += 1
            }
        }
        XCTAssertGreaterThan(found, 0, "no addressable rows on screen")
    }

    private func assertResolvesExactlyOnce(
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matches = app.descendants(matching: .any).matching(identifier: identifier)
        XCTAssertEqual(
            matches.count, 1,
            "\(identifier) resolved \(matches.count) times",
            file: file, line: line
        )
    }

    @discardableResult
    private func revealIdentifier(_ identifier: String) -> XCUIElement {
        let target = app.descendants(matching: .any)[identifier]
        var attempts = 0
        while !target.exists && attempts < 12 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(target.waitForExistence(timeout: 4), "Never reached \(identifier)")
        return target
    }

    private func launch(variant: String = "full", tab: String? = nil, route: String? = nil) {
        var arguments = [
            "-AppleLanguages", "(en-US)",
            "-AppleLocale", "en_US",
            "-HCIPrototype",
            "-HCIPrototypeVariant", variant,
        ]
        if let tab { arguments += ["-startTab", tab] }
        if let route { arguments += ["-startRoute", route] }
        app.launchArguments = arguments
        app.launch()
    }
}
