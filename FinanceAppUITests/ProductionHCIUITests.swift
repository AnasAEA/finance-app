import XCTest

/// Production Concept B+ chrome, driven with Debug-only synthetic stores.
/// These tests assert navigation and language, not fixture economics.
final class ProductionHCIUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testProductionHasFourCanonicalTabsAndNoGlobalAdd() {
        launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["home.cash"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["home.attention"].exists)
        XCTAssertTrue(app.buttons["home.settings"].exists)
        // Home states the primary financial problem once. The Budget and
        // Upcoming status rows restated it and are gone.
        XCTAssertFalse(app.buttons["home.budget"].exists)
        XCTAssertFalse(app.buttons["home.upcoming"].exists)

        XCTAssertEqual(app.tabBars.buttons.count, 4)
        XCTAssertTrue(app.tabBars.buttons["tab.home"].exists)
        XCTAssertTrue(app.tabBars.buttons["tab.activity"].exists)
        XCTAssertTrue(app.tabBars.buttons["tab.plan"].exists)
        // Insights ships now that the review engine is wired to it.
        XCTAssertTrue(app.tabBars.buttons["tab.insights"].exists)
        XCTAssertFalse(app.tabBars.buttons["More"].exists)
        XCTAssertFalse(app.buttons["Add transaction"].exists)
        XCTAssertFalse(app.buttons["Add a transaction"].exists)
    }

    func testInsightsOpensAndOffersWeekAndMonth() {
        launch()
        // The tab identifiers are put on the bar once it exists, so wait for
        // the app to be up before addressing one — the same readiness this
        // file already waits for before touching anything else.
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        app.tabBars.buttons["tab.insights"].tap()
        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 8))
        // The default body states records quality in one line. The full Data
        // Quality section is still reachable, behind Show Details.
        XCTAssertTrue(app.staticTexts["Records"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Data quality"].exists)
        app.buttons["Show Details"].tap()
        reveal("Data quality")

        let scope = app.segmentedControls["insights.scope"]
        XCTAssertTrue(scope.exists)
        XCTAssertTrue(scope.buttons["Week"].exists)
        XCTAssertTrue(scope.buttons["Month"].exists)
        scope.buttons["Week"].tap()
        XCTAssertTrue(app.navigationBars["Insights"].exists)
    }

    func testHomeOpensAccountsAndSettings() {
        launch()
        app.buttons["home.cash"].tap()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 5))

        launch()
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.banks"].exists)
        XCTAssertTrue(app.buttons["settings.automation"].exists)
        XCTAssertTrue(app.buttons["settings.data"].exists)
        XCTAssertTrue(app.buttons["settings.app"].exists)
    }

    func testSyncFreshnessIsACaptionAndHealthySyncIsQuiet() {
        launch()
        // Freshness states itself once, as a caption. The standalone warning
        // button is gone: any action Home offers comes from the attention card.
        XCTAssertTrue(
            app.descendants(matching: .any)["home.sync"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.buttons["home.sync"].exists)

        launch(variant: "healthySync")
        XCTAssertFalse(app.buttons["home.sync"].exists)
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Synced' OR label BEGINSWITH 'Last sync'")).firstMatch
                .waitForExistence(timeout: 5)
        )
        app.buttons["home.cash"].tap()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Not synced yet"].exists)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH 'Synced' OR label BEGINSWITH 'Last sync'")
            ).firstMatch.waitForExistence(timeout: 5)
        )
    }

    func testActivityOwnsSearchFiltersReviewAndAdd() {
        launch(tab: "activity")
        XCTAssertTrue(app.buttons["activity.add"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Transactions"].exists)
        XCTAssertTrue(app.buttons["To Review"].exists)
        XCTAssertTrue(app.buttons["activity.filters"].exists)
        XCTAssertTrue(app.searchFields.firstMatch.exists)

        app.buttons["To Review"].tap()
        XCTAssertTrue(app.staticTexts["Needs a Decision"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["activity.pending-section"].exists)
        let target = revealIdentifier(AutomationTokenMirror.pending("pending-snapshot"), as: .any)
        XCTAssertNotEqual(target.elementType, .button)
        let lastPending = app.descendants(matching: .any)[AutomationTokenMirror.pending("pending-third")]
        var pendingSwipes = 0
        while !lastPending.exists && pendingSwipes < 10 {
            app.swipeUp()
            pendingSwipes += 1
        }
        while lastPending.exists && !lastPending.isHittable && pendingSwipes < 10 {
            app.swipeUp()
            pendingSwipes += 1
        }
        XCTAssertTrue(lastPending.isHittable, "last Pending row stayed under the floating tab bar")

        app.buttons["activity.add"].tap()
        XCTAssertTrue(app.navigationBars["New Transaction"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
    }

    func testPlanHubExposesFourPushedDestinations() {
        launch(tab: "plan")
        XCTAssertTrue(app.buttons["plan.budget"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["plan.upcoming"].exists)
        XCTAssertTrue(app.buttons["plan.goals"].exists)
        XCTAssertTrue(app.buttons["plan.afford.open"].exists)
        XCTAssertFalse(app.staticTexts["CASH RUNWAY"].exists)

        app.buttons["plan.afford.open"].tap()
        XCTAssertTrue(app.navigationBars["Can I afford this?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["afford.check"].exists)
        XCTAssertFalse(app.buttons["Close"].exists)
    }

    func testGoalsAndUpcomingRetainFormerMoreDestinations() {
        launch(route: "goals")
        XCTAssertTrue(app.navigationBars["Goals & Set Aside"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["plan.goals.add"].exists)
        XCTAssertTrue(app.buttons["plan.funds.add"].exists)

        launch(route: "upcoming")
        XCTAssertTrue(app.navigationBars["Upcoming"].waitForExistence(timeout: 8))
        reveal("Expected payments")
        reveal("Recurring payments")
        reveal("Income sources")
        reveal("Instalments")
        reveal("Debts & arrears")
    }

    func testHomeWeekRowsScrollClearOfTheTabBar() {
        for variant in ["full", "healthySync", "positive"] {
            launch(variant: variant)
            XCTAssertTrue(app.buttons["home.upcoming.all"].waitForExistence(timeout: 8))
            let rows = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'home.week.'")
            )
            XCTAssertGreaterThanOrEqual(rows.count, 1, "\(variant): missing Next 7 days rows")
            // The exact cap follows whether Home is carrying the funding
            // card; ProductionIATests pins that mapping. Here the contract is
            // that Home is never denser than the approved maximum.
            let limit = 3
            XCTAssertLessThanOrEqual(rows.count, limit, "\(variant): denser than the approved Home week")
            let last = rows.element(boundBy: rows.count - 1)
            XCTAssertTrue(last.waitForExistence(timeout: 5))
            var hops = 0
            while last.exists && !last.isHittable && hops < 10 {
                app.swipeUp()
                hops += 1
            }
            XCTAssertTrue(last.isHittable, "\(variant): last Next 7 days row stayed under the tab bar")
            XCTAssertTrue(app.buttons["home.upcoming.all"].exists)
        }
    }

    func testPlanHubRowsStayReadableAtAccessibilityXL() {
        let arguments = [
            "-AppleLanguages", "(en-US)",
            "-AppleLocale", "en_US",
            "-HCIPrototype",
            "-HCIPrototypeVariant", "full",
            "-startTab", "plan",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"
        ]
        app.launchArguments = arguments
        app.launch()
        let ids = ["plan.budget", "plan.upcoming", "plan.goals", "plan.afford.open"]
        for id in ids {
            let row = app.buttons[id]
            var hops = 0
            while !row.exists && hops < 10 {
                app.swipeUp()
                hops += 1
            }
            XCTAssertTrue(row.waitForExistence(timeout: 5), "missing \(id)")
            hops = 0
            while row.exists && !row.isHittable && hops < 10 {
                app.swipeUp()
                hops += 1
            }
            XCTAssertTrue(row.isHittable, "\(id) stayed under the tab bar at Accessibility XL")
        }
    }

    func testEmptyAndPositiveVariantsUseProductionScreens() {
        launch(variant: "emptyReview", tab: "activity", section: "toReview")
        XCTAssertTrue(app.staticTexts["Nothing needs review"].waitForExistence(timeout: 8))

        launch(variant: "emptyGoals", route: "goals")
        XCTAssertTrue(app.staticTexts["Plan something you're saving for"].waitForExistence(timeout: 8))

        launch(variant: "positive")
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["home.shortfall"].exists)
    }

    func testReviewSectionEmptyStateCombinations() {
        launch(variant: "needsReviewOnly", tab: "activity", section: "toReview")
        XCTAssertTrue(app.staticTexts["Needs a Decision"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["activity.pending-section"].exists)
        XCTAssertFalse(app.staticTexts["Nothing needs review"].exists)

        launch(variant: "pendingOnly", tab: "activity", section: "toReview")
        XCTAssertTrue(
            app.descendants(matching: .any)["activity.pending-section"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertFalse(app.staticTexts["Needs a Decision"].exists)
        XCTAssertFalse(app.staticTexts["Nothing needs review"].exists)

        launch(variant: "emptyReview", tab: "activity", section: "toReview")
        XCTAssertTrue(app.staticTexts["Nothing needs review"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["activity.pending-section"].exists)
    }

    func testPendingStaysInformationalAndOutsideTransactionsAndHomeCount() {
        launch(variant: "pendingOnly", tab: "activity")
        XCTAssertFalse(app.descendants(matching: .any)["activity.pending-section"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any)[AutomationTokenMirror.pending("pending-third")].exists
        )

        app.buttons["To Review"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["activity.pending-section"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.buttons["Confirm"].exists)
        XCTAssertFalse(app.buttons["Reject"].exists)
        XCTAssertFalse(app.buttons["Create expense"].exists)
        XCTAssertFalse(app.buttons["Create rule"].exists)
        XCTAssertFalse(app.buttons["Apply rule"].exists)
        XCTAssertFalse(app.staticTexts["+€0.00"].exists)

        launch(variant: "pendingOnly")
        XCTAssertTrue(
            app.descendants(matching: .any)["home.attention"].waitForExistence(timeout: 5)
        )
    }

    /// The aggregate case is not work. One bank movement whose amount two
    /// existing records happen to sum to is stated as a limitation and offers
    /// no route at all: arithmetic is not proof of identity, and the evidence
    /// model cannot link one movement to two records.
    func testAggregateConflictIsALimitationWithNoDecisionRoute() {
        launch(variant: "aggregateConflict", tab: "activity", section: "toReview")
        let row = revealIdentifier(
            AutomationTokenMirror.limitation("obs-paypal-unresolved"), as: .any
        )
        XCTAssertNotEqual(row.elementType, .button)
        XCTAssertFalse(
            app.descendants(matching: .any)[
                AutomationTokenMirror.decision("obs-paypal-unresolved")
            ].exists
        )
        XCTAssertTrue(app.staticTexts["Nothing to decide here."].exists)
        XCTAssertFalse(app.buttons["review.matchExisting"].exists)
        XCTAssertFalse(app.buttons["review.createExpense"].exists)
        XCTAssertFalse(app.buttons["Mark no economic effect"].exists)
    }

    func testExactExistingCandidatePrefersMatchExistingAndOverrideStaysExplicit() {
        launch(variant: "exactExisting", tab: "activity", section: "toReview")
        let row = app.descendants(matching: .any)[AutomationTokenMirror.decision("obs-streaming")]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["review.duplicate.warning"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["This may already be accounted for"].exists)
        XCTAssertTrue(revealIdentifier("review.matchExisting", as: .button).exists)

        // Creating another expense over a duplicate warning still demands an
        // explicit override rather than going through quietly.
        revealIdentifier("review.createExpense", as: .button).tap()
        XCTAssertTrue(app.buttons["review.createExpenseAnyway"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This may already be recorded"].exists)
    }

    func testPendingRowsStayReadableAtAccessibilityXLInDarkMode() {
        app.launchArguments = [
            "-AppleLanguages", "(en-US)",
            "-AppleLocale", "en_US",
            "-AppleInterfaceStyle", "Dark",
            "-HCIPrototype",
            "-HCIPrototypeVariant", "pendingOnly",
            "-startTab", "activity",
            "-startSection", "toReview",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"
        ]
        app.launch()

        _ = revealIdentifier(AutomationTokenMirror.pending("pending-snapshot"), as: .any)
        let zero = app.descendants(matching: .any)[AutomationTokenMirror.pending("pending-third")]
        var swipes = 0
        while !zero.exists && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(zero.exists)
        swipes = 0
        while zero.exists && !zero.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(zero.isHittable, "last Pending row stayed under the tab bar at Accessibility XL")
        XCTAssertNotEqual(zero.elementType, .button)
    }

    private func launch(
        variant: String = "full",
        tab: String? = nil,
        section: String? = nil,
        route: String? = nil
    ) {
        var arguments = [
            "-AppleLanguages", "(en-US)",
            "-AppleLocale", "en_US",
            "-HCIPrototype",
            "-HCIPrototypeVariant", variant
        ]
        if let tab { arguments += ["-startTab", tab] }
        if let section { arguments += ["-startSection", section] }
        if let route { arguments += ["-startRoute", route] }
        app.launchArguments = arguments
        app.launch()
    }

    private func reveal(_ text: String) {
        let target = app.staticTexts[text]
        var attempts = 0
        while !target.exists && attempts < 12 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(target.waitForExistence(timeout: 4), "Never reached \(text)")
    }

    private func revealIdentifier(
        _ identifier: String,
        as type: XCUIElement.ElementType
    ) -> XCUIElement {
        let target = app.descendants(matching: type)[identifier]
        var attempts = 0
        while !target.exists && attempts < 12 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(target.waitForExistence(timeout: 4), "Never reached \(identifier)")
        return target
    }
}
