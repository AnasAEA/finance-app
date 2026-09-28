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

    /// Home's headline is now the way in to its own explanation, and the
    /// explanation reaches the Plan destination that owns the obligations
    /// rather than listing them a second time.
    func testHomeSafeToUseOpensItsExplanation() {
        launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        let headline = app.descendants(matching: .any)["home.safe"]
        XCTAssertTrue(headline.waitForExistence(timeout: 5))
        headline.tap()

        XCTAssertTrue(app.navigationBars["Safe to Use"].waitForExistence(timeout: 8))
        // The subtraction, each term separately addressable.
        XCTAssertTrue(app.descendants(matching: .any)["safe.cash"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["safe.committed"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["safe.result"].exists)
        XCTAssertTrue(app.staticTexts["How it's worked out"].exists)

        let onward = revealIdentifier("safe.see-committed", as: .any)
        onward.tap()
        XCTAssertTrue(app.navigationBars["Upcoming"].waitForExistence(timeout: 8))
        // One Upcoming, reached from Plan — not a copy owned by the drill-down.
        XCTAssertEqual(app.navigationBars.matching(identifier: "Upcoming").count, 1)
    }

    func testInsightsOpensAndOffersWeekAndMonth() {
        launch()
        // The tab identifiers are put on the bar once it exists, so wait for
        // the app to be up before addressing one — the same readiness this
        // file already waits for before touching anything else.
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        app.tabBars.buttons["tab.insights"].tap()
        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 8))
        // The default body leads with one conclusion and its coverage state.
        // Full Data Quality detail is still reachable behind Show Details.
        XCTAssertTrue(app.staticTexts["insights.summary"].waitForExistence(timeout: 5))
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

    func testInsightReviewFindingOpensOnlyItsDecisionsAndKeepsContextOnReturn() {
        launch(tab: "insights")
        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 8))
        let link = app.buttons["insights.review-items"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()

        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["From Insights"].exists)
        XCTAssertTrue(app.buttons["activity.review.show-all"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["activity.pending-section"].exists)

        let item = revealIdentifier(AutomationTokenMirror.decision("obs-streaming"), as: .any)
        item.tap()
        XCTAssertTrue(app.navigationBars["Review activity"].waitForExistence(timeout: 5))
        app.navigationBars["Review activity"].buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["From Insights"].waitForExistence(timeout: 5))

        app.buttons["activity.review.show-all"].tap()
        XCTAssertFalse(app.staticTexts["From Insights"].exists)
        _ = revealIdentifier("activity.pending-section", as: .any)
    }

    /// A breakdown line opens exactly the records behind it, a record opens
    /// its ordinary detail, and Back returns through the same list to the
    /// period that was being read.
    func testInsightBreakdownOpensItsRecordsAndReturns() {
        launch(variant: "insights", tab: "insights")
        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["insights.spent-records"].waitForExistence(timeout: 5))

        revealIdentifier(AutomationTokenMirror.insightsCategory("hci-ins-groceries"), as: .any).tap()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["insights.records-total"].exists)

        revealIdentifier(AutomationTokenMirror.insightsRecord("hci-ins-g1"), as: .any).tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 5))
        app.navigationBars["Transaction"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["insights.records-total"].exists)

        app.navigationBars["Groceries"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["insights.spent-records"].exists)
    }

    /// A finding that quotes a figure offers that figure's records, not a
    /// generic list, and a plan finding hands off to the screen that owns it.
    func testInsightFindingOpensTheRecordsItQuotes() {
        launch(variant: "insights", tab: "insights")
        XCTAssertTrue(app.navigationBars["Insights"].waitForExistence(timeout: 8))
        let link = app.descendants(matching: .any)
            .matching(identifier: "insights.finding-records").firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.descendants(matching: .any)["insights.records-total"].waitForExistence(timeout: 5))
        let budget = revealIdentifier("Open budget", as: .button)
        budget.tap()
        XCTAssertTrue(app.navigationBars["Budget"].waitForExistence(timeout: 8))
    }

    func testHomeReviewMonthOpensCanonicalVerificationDetail() {
        launch(variant: "positive")
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        let attention = app.descendants(matching: .any)["home.attention"]
        XCTAssertTrue(attention.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Review month"].waitForExistence(timeout: 5)
                || attention.label.contains("Review month")
        )
        attention.tap()
        XCTAssertTrue(app.navigationBars["What's unresolved"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Not verified yet."].waitForExistence(timeout: 5))
        XCTAssertEqual(app.navigationBars.matching(identifier: "What's unresolved").count, 1)
        XCTAssertFalse(app.staticTexts["Close checkpoint"].exists)
        XCTAssertFalse(app.staticTexts["Reverify revision"].exists)
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
        XCTAssertTrue(app.buttons["activity.search"].exists)
        XCTAssertFalse(app.searchFields.firstMatch.exists)
        app.buttons["activity.search"].tap()
        XCTAssertTrue(app.textFields["activity.search.field"].waitForExistence(timeout: 5))

        app.buttons["To Review"].tap()
        XCTAssertTrue(app.staticTexts["Needs a Decision"].waitForExistence(timeout: 5))
        app.buttons["Transactions"].tap()
        XCTAssertFalse(app.textFields["activity.search.field"].exists)
        app.buttons["To Review"].tap()
        // Scrolled to rather than assumed on screen: the queue's length is a
        // product decision, and a row that now states its own decision is
        // taller than one that stated only a merchant.
        _ = revealIdentifier("activity.pending-section", as: .any)
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

    func testSyncedBankMovementsAppearBeforeReviewInTransactions() {
        launch(tab: "activity")
        let row = revealIdentifier(AutomationTokenMirror.transaction("bank:obs-streaming"), as: .any)
        XCTAssertTrue(row.isHittable)
        row.tap()
        XCTAssertTrue(app.navigationBars["Bank transaction"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Booked")).firstMatch.exists)
        XCTAssertTrue(app.buttons["Review transaction"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Booking date")).firstMatch.exists)
    }

    func testTimelinePendingSummaryExpandsAndSearchShowsMatchingPayments() {
        launch(tab: "activity")
        let summary = app.descendants(matching: .any)["activity.bank-pending-summary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 8))
        summary.tap()
        let pending = app.descendants(matching: .any)[AutomationTokenMirror.transaction("bank:pending-snapshot")].firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["activity.search"].tap()
        let search = app.textFields["activity.search.field"]
        search.tap()
        search.typeText("Pending")
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["activity.bank-pending-summary"].exists)
    }

    func testTimelineFiltersRemainReachableAtAccessibilityXL() {
        app.launchArguments = [
            "-AppleInterfaceStyle", "Dark", "-HCIPrototype", "-HCIPrototypeVariant", "full",
            "-startTab", "activity",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"
        ]
        app.launch()
        let filters = revealIdentifier("activity.filters", as: .button)
        XCTAssertTrue(filters.isHittable)
        filters.tap()
        XCTAssertTrue(app.navigationBars["Transaction filters"].waitForExistence(timeout: 5))
    }

    func testBankExpenseOffersCategoryBeforeSaving() {
        launch(tab: "activity", section: "toReview")
        revealIdentifier(AutomationTokenMirror.decision("obs-streaming"), as: .any).tap()
        XCTAssertTrue(app.navigationBars["Review activity"].waitForExistence(timeout: 5))
        revealIdentifier("review.createExpense", as: .button).tap()
        XCTAssertTrue(app.navigationBars["Categorize payment"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["review.expense.save"].isEnabled)
        revealIdentifier("review.category.subscriptions", as: .button).tap()
        XCTAssertTrue(app.buttons["review.expense.save"].isEnabled)
        let categoryCapture = XCTAttachment(screenshot: app.screenshot())
        categoryCapture.name = "expense-categorization"
        categoryCapture.lifetime = .keepAlways
        add(categoryCapture)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Review activity"].waitForExistence(timeout: 5))
    }

    func testForeignExpenseRequiresTheAccountCurrencyChargeBeforeSaving() {
        launch(variant: "foreignExpense", tab: "activity", section: "toReview")
        revealIdentifier(AutomationTokenMirror.decision("obs-streaming"), as: .any).tap()
        XCTAssertTrue(app.navigationBars["Categorize payment"].waitForExistence(timeout: 5))
        let charge = app.textFields["review.expense.chargedAmount"]
        XCTAssertTrue(charge.exists)
        revealIdentifier("review.category.subscriptions", as: .button).tap()
        XCTAssertFalse(app.buttons["review.expense.save"].isEnabled)
        app.swipeDown()
        charge.tap()
        charge.typeText("9.25")
        XCTAssertTrue(app.buttons["review.expense.save"].isEnabled)
        app.buttons["review.expense.save"].tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Couldn’t record expense"].exists)
        XCTAssertFalse(app.buttons[AutomationTokenMirror.decision("obs-streaming")].exists)
    }

    func testEverydayFilterSelectionAppliesToTimeline() {
        launch(tab: "activity")
        app.buttons["activity.filters"].tap()
        XCTAssertTrue(app.navigationBars["Transaction filters"].waitForExistence(timeout: 5))
        let filtersCapture = XCTAttachment(screenshot: app.screenshot())
        filtersCapture.name = "everyday-filters"
        filtersCapture.lifetime = .keepAlways
        add(filtersCapture)
        app.buttons["activity.filter.category"].tap()
        XCTAssertTrue(app.navigationBars["Category"].waitForExistence(timeout: 5))
        let category = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Groceries")).firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.tap()
        XCTAssertTrue(category.isSelected, app.debugDescription)
        app.navigationBars["Category"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Transaction filters"].waitForExistence(timeout: 5))
        app.buttons["activity.filters.apply"].tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["activity.filters"].label.contains("Filters on"), app.debugDescription)

        // The applied filter survives a trip to To Review and back.
        let chip = app.buttons["activity.filter-chip.categories"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(chip.label.hasPrefix("Remove filter"), chip.label)
        app.buttons["To Review"].tap()
        XCTAssertTrue(app.staticTexts["Needs a Decision"].waitForExistence(timeout: 5))
        app.buttons["Transactions"].tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["activity.filters"].label.contains("Filters on"))

        // One tap removes it, and only it.
        chip.tap()
        XCTAssertFalse(chip.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["activity.filters"].label.contains("Filters on"))
    }

    /// A timeline row is one sentence to VoiceOver: what it is, how much, its
    /// state — not the provider's initials first.
    func testTimelineRowSaysWhatKindOfRecordItIs() {
        launch(tab: "activity")
        let row = revealIdentifier(AutomationTokenMirror.transaction("bank:obs-streaming"), as: .any)
        XCTAssertTrue(row.label.hasPrefix("Streaming Membership"), row.label)
        XCTAssertTrue(row.label.contains("bank movement"), row.label)
        XCTAssertFalse(row.label.hasPrefix("BNP"), row.label)
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

    /// The week's answer sits above the week's events, is not counted as one
    /// of them, and hands over to the Upcoming that Plan already owns.
    func testHomeWeekSummaryLeadsTheSectionAndReachesUpcoming() {
        launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))

        let summary = app.descendants(matching: .any)["home.week-low"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("Lowest projected cash"))
        // It says cash. Safe to Use is a different question on the same
        // screen and the two must not read as one number.
        XCTAssertFalse(summary.label.lowercased().contains("safe to use"))

        // It is not an event row: the approved Next 7 days density counts
        // only `home.week.<id>` and this identifier stays out of that space.
        let eventRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'home.week.'")
        )
        for index in 0..<eventRows.count {
            XCTAssertNotEqual(eventRows.element(boundBy: index).identifier, "home.week-low")
        }

        app.buttons["home.upcoming.all"].tap()
        XCTAssertTrue(app.navigationBars["Upcoming"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.navigationBars.matching(identifier: "Upcoming").count, 1)
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
        let ids = ["plan.budget", "plan.reserve", "plan.upcoming", "plan.goals", "plan.afford.open"]
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
        reveal("Nothing to decide here.")
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

    func testManualRecordedPaymentLookupDoesNotResolveAnythingOnOpen() {
        launch(variant: "exactExisting", tab: "activity", section: "toReview")
        revealIdentifier(AutomationTokenMirror.decision("obs-streaming"), as: .any).tap()
        revealIdentifier("review.findRecordedPayment", as: .button).tap()
        XCTAssertTrue(app.navigationBars["Find recorded payment"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Recorded membership")).firstMatch.exists)
        XCTAssertTrue(app.searchFields.firstMatch.exists)
        app.navigationBars["Find recorded payment"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Review activity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["review.matchExisting"].exists)
        XCTAssertFalse(resolvedState.exists)
    }

    /// The whole loop, in one pass: evidence is work, a person decides what it
    /// means, the queue goes quiet, and the row it produced can still say where
    /// it came from.
    ///
    /// Before this the relationship only pointed one way. The decision was
    /// visible from the evidence and invisible from the transaction, so the
    /// row the decision created could not explain itself — and could not
    /// explain why the app then refused to delete it.
    func testResolvingEvidenceLeavesTheTransactionAbleToExplainItself() {
        launch(variant: "exactExisting", tab: "activity", section: "toReview")
        let queueRow = app.descendants(matching: .any)[
            AutomationTokenMirror.decision("obs-streaming")
        ]
        XCTAssertTrue(queueRow.waitForExistence(timeout: 8))
        queueRow.tap()

        // Decide what it means. Creating the expense from the evidence is the
        // path that records the link, and the duplicate warning still demands
        // an explicit override on the way through.
        revealIdentifier("review.createExpense", as: .button).tap()
        let override = app.buttons.matching(
            identifier: "review.createExpenseAnyway"
        ).firstMatch
        XCTAssertTrue(override.waitForExistence(timeout: 5))
        override.tap()
        XCTAssertTrue(app.navigationBars["Categorize payment"].waitForExistence(timeout: 5))
        revealIdentifier("review.category.subscriptions", as: .button).tap()
        app.buttons["review.expense.save"].tap()

        // The decision is recorded in place: the same screen now states the
        // state it was left in and offers nothing further to decide.
        XCTAssertTrue(resolvedState.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["review.matchExisting"].exists)
        XCTAssertFalse(app.buttons["review.createExpense"].exists)

        // Back on the queue, it is quiet about it.
        app.navigationBars["Review activity"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["To Review"].waitForExistence(timeout: 8))
        XCTAssertFalse(
            app.descendants(matching: .any)[
                AutomationTokenMirror.decision("obs-streaming")
            ].exists
        )

        // The transaction it produced can now answer where it came from.
        app.buttons["Transactions"].tap()
        let transaction = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Streaming Membership")
        ).firstMatch
        XCTAssertTrue(transaction.waitForExistence(timeout: 8))
        transaction.tap()

        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 5))
        _ = revealIdentifier(AutomationTokenMirror.evidenceSection, as: .any)
        let source = revealIdentifier(
            AutomationTokenMirror.evidence("obs-streaming"), as: .button
        )
        XCTAssertTrue(source.label.contains("Bank movement"), "source read \(source.label)")

        // And it opens the evidence the app already owns, in the state the
        // decision left it — not a fresh review.
        source.tap()
        XCTAssertTrue(app.navigationBars["Review activity"].waitForExistence(timeout: 5))
        // Arriving from the transaction shows the evidence in the state the
        // decision left it. It is not a fresh review, and it offers nothing to
        // decide again.
        XCTAssertTrue(resolvedState.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["review.matchExisting"].exists)
        XCTAssertFalse(app.buttons["review.createExpense"].exists)
    }

    /// The review screen states a resolved observation through one combined
    /// label, so the assertion matches the sentence rather than half of it.
    private var resolvedState: XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Linked to transaction")
        ).firstMatch
    }

    /// A row nobody linked offers no source section to look at.
    func testATransactionWithNoEvidenceOffersNoSource() {
        launch(variant: "exactExisting", tab: "activity")
        let transaction = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Recorded membership")
        ).firstMatch
        XCTAssertTrue(transaction.waitForExistence(timeout: 8))
        transaction.tap()

        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 5))
        // Nothing is linked yet in this variant, and the app does not invent a
        // source from an observation that merely agrees about the money.
        XCTAssertFalse(
            app.descendants(matching: .any)[AutomationTokenMirror.evidenceSection].exists
        )
    }

    /// The queue warns before the decision, not after it.
    ///
    /// The duplicate conflict was stated only on the review screen, so the one
    /// thing a person needed to know before creating a second expense was the
    /// one thing they could not see until they had opened the item. The row
    /// now carries it, and the review screen still owns the full explanation.
    func testDecisionRowWarnsAboutADuplicateBeforeItIsOpened() {
        launch(variant: "exactExisting", tab: "activity", section: "toReview")
        let row = app.descendants(matching: .any)[AutomationTokenMirror.decision("obs-streaming")]
        XCTAssertTrue(row.waitForExistence(timeout: 8))

        // The row combines its children, so the warning is part of the one
        // label a person — and VoiceOver — actually receives.
        XCTAssertTrue(
            row.label.contains("May already be recorded"),
            "row read \(row.label)"
        )

        // Naming the risk resolves nothing: the item is still in the queue and
        // the review screen still demands the same explicit decision.
        row.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review.duplicate.warning"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(revealIdentifier("review.matchExisting", as: .button).exists)
    }

    /// Two pieces of evidence, two different questions, and the queue says so.
    func testDecisionRowsNameTheKindOfDecision() {
        launch(variant: "full", tab: "activity", section: "toReview")
        let atm = app.descendants(matching: .any)[AutomationTokenMirror.decision("obs-atm")]
        XCTAssertTrue(atm.waitForExistence(timeout: 8))

        // Cash out of a machine is account movement, not spending. Before
        // this, the row said only "CASH MACHINE · Card wallet · Mar 5".
        XCTAssertTrue(atm.label.contains("ATM / cash movement"), "row read \(atm.label)")

        let unresolved = app.descendants(matching: .any)[
            AutomationTokenMirror.decision("obs-paypal-unresolved")
        ]
        if unresolved.exists {
            XCTAssertFalse(
                unresolved.label.contains("ATM / cash movement"),
                "two different decisions are reading the same way"
            )
        }
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
