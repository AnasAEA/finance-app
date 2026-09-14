import XCTest

/// Production Plan and affordability, driven through the real app.
///
/// Debug launch arguments only. Nothing here writes to a physical phone.
/// Axis math is pinned in `PlanningUITests`; these cases prove the screens.
final class PlanProductionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testEmptyPlanShowsIntentionalCopyAndOpensEditors() {
        launchPlan(arguments: ["-useEmptyPreview"], route: "goals")
        XCTAssertTrue(app.staticTexts["Plan something you're saving for"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Set-aside not tied to a goal appears here."].exists)
        XCTAssertTrue(app.buttons["plan.goals.add"].exists)
        XCTAssertTrue(app.buttons["plan.funds.add"].exists)

        revealHittable(app.buttons["plan.goals.add"])
        app.buttons["plan.goals.add"].tap()
        XCTAssertTrue(app.navigationBars["New goal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["goal.name"].exists)
        XCTAssertTrue(app.buttons["goal.save"].exists)
        app.buttons["Cancel"].tap()

        revealHittable(app.buttons["plan.funds.add"])
        app.buttons["plan.funds.add"].tap()
        XCTAssertTrue(app.navigationBars["New fund"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["fund.name"].exists)
        XCTAssertTrue(app.buttons["fund.save"].exists)
        app.buttons["Cancel"].tap()

        launchPlan(arguments: ["-useEmptyPreview"], route: "affordability")
        XCTAssertTrue(app.navigationBars["Can I afford this?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["afford.check"].exists)
        XCTAssertTrue(app.staticTexts["This is a check, not a decision and not a payment."].exists)
        XCTAssertFalse(app.buttons["Close"].exists)
    }

    func testGoalCRUDDoesNotReadAsATransaction() {
        launchPlan(arguments: ["-useEmptyPreview"], route: "goals")
        addGoal(name: "Laptop", amount: "900")
        XCTAssertTrue(row("Laptop").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Wishlist"].exists)

        row("Laptop").tap()
        XCTAssertTrue(app.navigationBars["Laptop"].waitForExistence(timeout: 5))
        app.buttons["Edit"].tap()
        let name = app.textFields["goal.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.clearAndType("Camera")
        XCTAssertTrue(
            ((name.value as? String) ?? "").localizedCaseInsensitiveContains("Camera"),
            "editor still reads \((name.value as? String) ?? "")"
        )
        app.buttons["goal.save"].tap()
        if app.alerts["Not saved"].waitForExistence(timeout: 1) {
            XCTFail(app.alerts["Not saved"].staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " — "))
        }
        dismissGoalEditorIfNeeded()
        popToGoals()
        XCTAssertTrue(row("Camera").waitForExistence(timeout: 5))
        XCTAssertFalse(row("Laptop").exists)

        row("Camera").tap()
        XCTAssertTrue(app.buttons["Delete goal"].waitForExistence(timeout: 5))
        app.buttons["Delete goal"].tap()
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["Plan something you're saving for"].waitForExistence(timeout: 5))
        XCTAssertFalse(row("Camera").exists)
    }

    func testVirtualFundCreateShowsSetAsideNotSpent() {
        launchPlan(arguments: ["-useEmptyPreview"], route: "goals")
        addFund(name: "Tech", target: "900", reserved: "200")
        XCTAssertTrue(row("Tech").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Set aside"].exists)
        XCTAssertTrue(
            row("Tech").label.contains("From general cash")
                || app.staticTexts["From general cash"].exists
        )
    }

    func testPreviewDistinguishesWishlistVirtualAndDedicated() {
        launchPlan(arguments: ["-usePlanningPreview"], route: "goals")
        reveal("Headphones")
        XCTAssertTrue(row("Headphones").label.contains("Wishlist"))
        reveal("Camera")
        XCTAssertTrue(row("Camera").label.contains("Saving"))
        XCTAssertTrue(row("Camera").label.localizedCaseInsensitiveContains("set aside"))
        reveal("Bike")
        XCTAssertTrue(row("Bike").label.contains("Saving"))
        row("Bike").tap()
        // Dedicated custody is told as "set aside in <account>", not as the
        // engine's "dedicated account" jargon.
        let dedicated = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS[c] 'Set aside in' OR label CONTAINS[c] 'reserved slice is not free cash' OR label CONTAINS[c] 'In a specific account'"
            )
        ).firstMatch
        XCTAssertTrue(dedicated.waitForExistence(timeout: 5))
    }

    func testSinkingFundedPurchaseShowsReleaseWithoutMutatingTheFund() {
        launchPlan(arguments: ["-usePlanningPreview"], route: "affordability")
        XCTAssertTrue(app.navigationBars["Can I afford this?"].waitForExistence(timeout: 5))
        let goalPicker = app.descendants(matching: .any)["afford.goal"]
        if goalPicker.waitForExistence(timeout: 3) {
            goalPicker.tap()
            if app.buttons["Camera"].waitForExistence(timeout: 3) {
                app.buttons["Camera"].tap()
            }
        }
        app.buttons["afford.check"].tap()
        let overall = app.descendants(matching: .any)["afford.overall"]
        XCTAssertTrue(overall.waitForExistence(timeout: 8))
        var hops = 0
        while !app.staticTexts["Sinking fund"].exists && hops < 4 {
            app.swipeUp()
            hops += 1
        }
        XCTAssertTrue(
            app.staticTexts["Sinking fund"].exists
                || app.staticTexts["Set aside now"].exists
        )
        XCTAssertTrue(app.staticTexts["Used by this purchase"].exists)
        XCTAssertTrue(app.staticTexts["Still set aside after"].exists)
        XCTAssertTrue(
            app.staticTexts["This is a simulation. The fund is not changed until you edit it yourself."].exists
        )
        XCTAssertFalse(app.staticTexts["Buy it"].exists)
        launchPlan(arguments: ["-usePlanningPreview"], route: "goals")
        XCTAssertTrue(row("Camera").exists)
        XCTAssertTrue(row("Camera").label.localizedCaseInsensitiveContains("set aside"))
    }

    func testCriticalIdentifiersArePresent() {
        launchPlan(arguments: ["-useEmptyPreview"], route: "goals")
        XCTAssertTrue(app.buttons["plan.goals.add"].exists)
        XCTAssertTrue(app.buttons["plan.funds.add"].exists)
        app.buttons["plan.goals.add"].tap()
        XCTAssertTrue(app.textFields["goal.name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["goal.save"].exists)
        app.buttons["Cancel"].tap()
        app.buttons["plan.funds.add"].tap()
        XCTAssertTrue(app.textFields["fund.name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["fund.save"].exists)
        app.buttons["Cancel"].tap()
        launchPlan(arguments: ["-useEmptyPreview"], route: "affordability")
        XCTAssertTrue(app.buttons["afford.check"].waitForExistence(timeout: 5))
    }

    func testLargeDynamicTypeStillExposesEmptyCopy() {
        app.launchArguments = [
            "-AppleLanguages", "(en-US)",
            "-AppleLocale", "en_US",
            "-startTab", "plan",
            "-useEmptyPreview",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["plan.budget"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["plan.upcoming"].exists)
        XCTAssertTrue(app.buttons["plan.goals"].exists)
        XCTAssertTrue(app.buttons["plan.afford.open"].exists)
    }

    private func launchPlan(arguments: [String], route: String? = nil) {
        var launchArguments = [
            "-AppleLanguages", "(en-US)",
            "-AppleLocale", "en_US",
            "-startTab", "plan"
        ] + arguments
        if let route { launchArguments += ["-startRoute", route] }
        app.launchArguments = launchArguments
        app.launch()
        if let route {
            let title: String = switch route {
            case "goals": "Goals & Set Aside"
            case "upcoming": "Upcoming"
            case "budget": "Budget"
            case "affordability": "Can I afford this?"
            default: "Plan"
            }
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8))
        } else {
            XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: 8)
                          || app.buttons["plan.afford.open"].waitForExistence(timeout: 8))
        }
    }

    private func dismissGoalEditorIfNeeded() {
        guard app.buttons["goal.save"].waitForExistence(timeout: 1) else { return }
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        }
    }

    private func popToGoals() {
        if app.navigationBars["Goals & Set Aside"].exists,
           !app.buttons["goal.save"].exists,
           !app.navigationBars["Laptop"].exists,
           !app.navigationBars["Camera"].exists,
           !app.navigationBars["Goal"].exists {
            return
        }
        let back = app.navigationBars.buttons["Goals & Set Aside"]
        if back.waitForExistence(timeout: 3), back.isHittable {
            back.tap()
            return
        }
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
    }

    private func reveal(_ text: String) {
        let target = app.staticTexts[text]
        var hops = 0
        while !target.exists && hops < 8 {
            app.swipeUp()
            hops += 1
        }
        XCTAssertTrue(target.waitForExistence(timeout: 4), "never found \(text)")
    }

    private func revealHittable(_ element: XCUIElement) {
        var hops = 0
        while element.exists && !element.isHittable && hops < 8 {
            app.swipeUp()
            hops += 1
        }
        XCTAssertTrue(element.waitForExistence(timeout: 4) && element.isHittable)
    }

    private func addGoal(name: String, amount: String) {
        app.buttons["plan.goals.add"].tap()
        XCTAssertTrue(app.textFields["goal.name"].waitForExistence(timeout: 5))
        app.textFields["goal.name"].tap()
        app.textFields["goal.name"].typeText(name)
        app.textFields["goal.amount"].tap()
        app.textFields["goal.amount"].typeText(amount)
        app.buttons["goal.save"].tap()
        XCTAssertTrue(row(name).waitForExistence(timeout: 5))
    }

    private func addFund(name: String, target: String, reserved: String) {
        app.buttons["plan.funds.add"].tap()
        XCTAssertTrue(app.textFields["fund.name"].waitForExistence(timeout: 5))
        app.textFields["fund.name"].tap()
        app.textFields["fund.name"].typeText(name)
        app.textFields["fund.target"].tap()
        app.textFields["fund.target"].typeText(target)
        app.textFields["fund.reserved"].tap()
        app.textFields["fund.reserved"].typeText(reserved)
        app.buttons["fund.save"].tap()
        XCTAssertTrue(row(name).waitForExistence(timeout: 5))
    }

    private func row(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        guard let current = value as? String, !current.isEmpty, current != "0" else {
            typeText(text)
            return
        }
        let delete = String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 4)
        typeText(delete)
        typeText(text)
    }
}
