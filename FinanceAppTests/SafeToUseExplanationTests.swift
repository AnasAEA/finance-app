import FinanceCore
import Foundation
import Testing
@testable import FinanceApp

/// The Home headline can be explained, and the explanation cannot argue with
/// it.
///
/// Two halves. The store tests run a real document through the real engine and
/// the real mapper, so what they pin is the product claim — "the figure is the
/// money on your accounts less what is already committed" — and not a
/// rearrangement of constants. The surface tests then falsify the guard: a
/// snapshot whose components do not account for its headline must produce no
/// breakdown at all.
///
/// All values and identities are synthetic.
@MainActor
@Suite("Safe to Use explanation")
struct SafeToUseExplanationTests {

    private static let today = Day(year: 2026, month: 9, day: 3)

    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    // MARK: - Fixtures

    private func account(
        _ id: String = "current",
        kind: AccountKind = .bank,
        currency: Currency = .eur,
        order: Int = 0
    ) -> Account {
        Account(
            id: id, name: id.capitalized, currency: currency, kind: kind,
            supportedRails: currency == .eur && kind != .cash
                ? PaymentRail.euroBankRails
                : [PaymentRail.physicalCash],
            drawOrder: order
        )
    }

    private func obligation(
        _ id: String,
        _ amount: String,
        onDay: Int,
        month: MonthKey
    ) -> RecurringObligation {
        RecurringObligation(
            id: id, name: id, amount: euro(amount),
            spec: .monthly(onDay: onDay, from: month, through: month),
            requirement: .euroBankPayment(),
            spendingClass: .essential
        )
    }

    /// One euro current account, one committed obligation, nothing else.
    private func store(
        balance: String,
        obligations: [RecurringObligation],
        extraAccounts: [Account] = [],
        extraBalances: [AccountBalance] = []
    ) -> FinanceStore {
        let current = account()
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [current] + extraAccounts,
            balances: [
                AccountBalance(
                    accountID: current.id, balance: euro(balance),
                    asOf: Self.today
                )
            ] + extraBalances,
            planning: FinanceDocument.Planning(
                defaultScenario: .base,
                recurringObligations: obligations
            )
        )
        return FinanceStore(document: document, today: Self.today, scenario: .base)
    }

    private func breakdown(
        _ store: FinanceStore,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> SafeToUseBreakdown {
        let explanation = SafeToUseExplanation.make(
            from: store.snapshot,
            isAvailable: store.safeToUseIsAvailable
        )
        guard case let .explained(breakdown) = explanation else {
            Issue.record("expected a breakdown, got \(explanation)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        return breakdown
    }

    // MARK: - S: the real engine, the real mapper

    @Test("The figure is the money on the accounts less what is already committed")
    func fundedMonthExplainsItself() throws {
        let store = store(
            balance: "1500.00",
            obligations: [
                obligation("rent", "480.00", onDay: 11, month: MonthKey(year: 2026, month: 9))
            ]
        )
        let breakdown = try breakdown(store)

        #expect(breakdown.cash == Amount.eur(1500))
        #expect(breakdown.committed == Amount.eur(480))
        #expect(breakdown.headroom == Amount.eur(1020))
        #expect(breakdown.safeToUse == Amount.eur(1020))
        #expect(breakdown.outcome == .headroom)
        #expect(breakdown.windowDays == store.snapshot.safeToSpendWindowDays)
    }

    @Test("The breakdown restates the authoritative figure rather than recomputing it")
    func breakdownIsTheAuthoritativeFigure() throws {
        let store = store(
            balance: "1500.00",
            obligations: [
                obligation("rent", "480.00", onDay: 11, month: MonthKey(year: 2026, month: 9)),
                obligation("phone", "19.99", onDay: 20, month: MonthKey(year: 2026, month: 9)),
            ]
        )
        let snapshot = store.snapshot
        let breakdown = try breakdown(store)

        // The headline is the snapshot's own, to the cent.
        #expect(breakdown.safeToUse == snapshot.safeToSpend)
        #expect(breakdown.cash == snapshot.accountCash)
        #expect(breakdown.committed == snapshot.committedOutflows)
        // And the two terms account for it exactly.
        #expect(
            breakdown.cash.minorUnits - breakdown.committed.minorUnits
                == breakdown.headroom.minorUnits
        )
        #expect(max(breakdown.headroom.minorUnits, 0) == snapshot.safeToSpend.minorUnits)
        #expect(breakdown.committed == Amount.eur(499.99))
    }

    @Test("An obligation beyond the window is not subtracted from what is safe today")
    func obligationOutsideTheWindowIsNotCommittedYet() throws {
        let near = store(
            balance: "1000.00",
            obligations: [
                obligation("rent", "400.00", onDay: 20, month: MonthKey(year: 2026, month: 9))
            ]
        )
        let far = store(
            balance: "1000.00",
            obligations: [
                obligation("rent", "400.00", onDay: 20, month: MonthKey(year: 2026, month: 11))
            ]
        )

        let inside = try breakdown(near)
        let outside = try breakdown(far)

        #expect(inside.committed == Amount.eur(400))
        #expect(inside.safeToUse == Amount.eur(600))
        // Same money, same obligation, a later date: it has not started
        // pressing on today's figure, and the window says over how long.
        #expect(outside.committed == Amount.eur(0))
        #expect(outside.safeToUse == Amount.eur(1000))
        #expect(outside.outcome == .headroom)
    }

    @Test("Commitments outrunning the money read as short, and the headline stays at zero")
    func shortMonthIsExplainedWithoutANegativeHeadline() throws {
        let store = store(
            balance: "50.00",
            obligations: [
                obligation("rent", "100.00", onDay: 11, month: MonthKey(year: 2026, month: 9))
            ]
        )
        let breakdown = try breakdown(store)

        #expect(breakdown.cash == Amount.eur(50))
        #expect(breakdown.committed == Amount.eur(100))
        #expect(breakdown.headroom == Amount.eur(-50))
        // The clamp is what the person sees; the deficit is what the screen
        // explains. Both are true and neither replaces the other.
        #expect(breakdown.safeToUse == Amount.eur(0))
        #expect(breakdown.safeToUse == store.snapshot.safeToSpend)
        guard case .short = breakdown.outcome else {
            Issue.record("expected a shortfall outcome, got \(breakdown.outcome)")
            return
        }
    }

    @Test("Money in another currency and notes in a pocket are named, never added")
    func holdingsOutsideTheFigureAreNamedAsExcluded() throws {
        let pocket = account("pocket", kind: .cash, order: 1)
        let dirhams = account("dirhams", kind: .bank, currency: .mad, order: 2)
        let store = store(
            balance: "800.00",
            obligations: [
                obligation("rent", "300.00", onDay: 11, month: MonthKey(year: 2026, month: 9))
            ],
            extraAccounts: [pocket, dirhams],
            extraBalances: [
                AccountBalance(accountID: "pocket", balance: euro("60.00"), asOf: Self.today),
                AccountBalance(
                    accountID: "dirhams",
                    balance: Money(exactDecimal: "200.00", currency: .mad)!,
                    asOf: Self.today
                ),
            ]
        )
        let breakdown = try breakdown(store)

        // Neither holding reached the figure: 800 − 300, and the pocket euros
        // and the dirhams are outside it.
        #expect(breakdown.cash == Amount.eur(800))
        #expect(breakdown.safeToUse == Amount.eur(500))

        guard case let .notCounted(excluded)? = breakdown.notes.first(where: {
            if case .notCounted = $0 { return true }
            return false
        }) else {
            Issue.record("expected the excluded holdings to be named")
            return
        }
        #expect(Set(excluded.map(\.id)) == ["pocket", "dirhams"])
        #expect(excluded.allSatisfy { !$0.isSpendableHere })
    }

    @Test("A failed projection explains nothing, and never calls the balance safe")
    func aFailedProjectionNeverPresentsTheWholeBalance() {
        struct ForecastUnavailable: Error {}
        let current = account()
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [current],
            balances: [
                AccountBalance(accountID: current.id, balance: euro("1500.00"), asOf: Self.today)
            ],
            planning: FinanceDocument.Planning(defaultScenario: .base)
        )
        let store = FinanceStore(
            document: document, today: Self.today, scenario: .base,
            forecastRunner: { _ in throw ForecastUnavailable() }
        )

        // The holdings survive so a populated document is not mistaken for a
        // first run, but nothing is safe to use until the projection says so.
        #expect(!store.safeToUseIsAvailable)
        #expect(store.snapshot.accountCash == Amount.eur(1500))
        #expect(store.snapshot.safeToSpend == Amount.eur(0))
        #expect(
            SafeToUseExplanation.make(from: store.snapshot, isAvailable: store.safeToUseIsAvailable)
                == .unavailable(.projectionUnavailable)
        )

        // And if that gate were ever wrong, the reconciliation guard is the
        // second line: 1500 − 0 is not the headline, so the screen refuses
        // rather than presenting the whole balance as free to spend.
        #expect(
            SafeToUseExplanation.make(from: store.snapshot, isAvailable: true)
                == .unavailable(.componentsDoNotReconcile)
        )
    }

    // MARK: - P: the guard, falsified

    /// A snapshot whose figures agree, as a starting point for tampering.
    private func coherentSnapshot() -> FinanceAppSnapshot {
        var snapshot = FinanceAppSnapshot.empty(
            asOf: CalendarDay(year: 2026, month: 9, day: 3)
        )
        snapshot.accountCash = .eur(900)
        snapshot.committedOutflows = .eur(400)
        snapshot.safeToSpend = .eur(500)
        snapshot.safeToSpendWindowDays = 30
        snapshot.safeToSpendReason = .liquidity
        return snapshot
    }

    @Test("No projection means no figure to explain, whatever the snapshot still holds")
    func staleFiguresAreNotExplainedWhenTheProjectionDidNotRun() {
        let explanation = SafeToUseExplanation.make(
            from: coherentSnapshot(), isAvailable: false
        )
        #expect(explanation == .unavailable(.projectionUnavailable))
    }

    @Test("Components that do not account for the headline produce no breakdown")
    func aContradictoryBreakdownIsRefused() {
        var tampered = coherentSnapshot()
        tampered.safeToSpend = .eur(650)   // 900 − 400 is not 650

        #expect(
            SafeToUseExplanation.make(from: tampered, isAvailable: true)
                == .unavailable(.componentsDoNotReconcile)
        )

        // One cent is enough. The rule is exact, not approximate.
        var offByACent = coherentSnapshot()
        offByACent.committedOutflows = Amount(minorUnits: 40_001, currencyCode: "EUR")
        #expect(
            SafeToUseExplanation.make(from: offByACent, isAvailable: true)
                == .unavailable(.componentsDoNotReconcile)
        )
    }

    @Test("Components in different currencies are refused rather than subtracted")
    func mixedCurrencyComponentsAreRefused() {
        var mixed = coherentSnapshot()
        mixed.committedOutflows = Amount(minorUnits: 40_000, currencyCode: "MAD")
        #expect(
            SafeToUseExplanation.make(from: mixed, isAvailable: true)
                == .unavailable(.componentsDoNotReconcile)
        )
    }

    @Test("Commitments consuming exactly the balance is not a shortfall")
    func exactlyConsumedIsNotShort() throws {
        var exact = coherentSnapshot()
        exact.committedOutflows = .eur(900)
        exact.safeToSpend = .eur(0)

        guard case let .explained(breakdown) =
                SafeToUseExplanation.make(from: exact, isAvailable: true) else {
            Issue.record("expected a breakdown")
            return
        }
        #expect(breakdown.headroom == Amount.eur(0))
        #expect(breakdown.outcome == .nothingFree)
    }

    @Test("Set-aside money is a note about the figure, never a term of it")
    func setAsideDoesNotReduceWhatIsSafe() {
        let plain = coherentSnapshot()
        var reserving = plain
        reserving.sinkingFunds = [
            SinkingFundSummary(
                id: "fund-camera", name: "Camera",
                target: .eur(400), reserved: .eur(160), remaining: .eur(240),
                custody: .virtual, dedicatedAccountID: nil, dedicatedAccountName: nil,
                status: .active, goalID: nil, goalName: nil,
                contribution: nil, note: nil
            )
        ]

        guard case let .explained(without) =
                SafeToUseExplanation.make(from: plain, isAvailable: true),
              case let .explained(with) =
                SafeToUseExplanation.make(from: reserving, isAvailable: true)
        else {
            Issue.record("expected both to explain")
            return
        }

        // Every term is identical. Only the note appears.
        #expect(with.safeToUse == without.safeToUse)
        #expect(with.cash == without.cash)
        #expect(with.committed == without.committed)
        #expect(with.headroom == without.headroom)
        #expect(without.notes.isEmpty)
        #expect(with.notes == [.setAside(.eur(160))])
        // And it is the total the Plan hub already prints, not a second one.
        #expect(PlanningTotals.setAside(from: reserving) == .eur(160))
    }

    @Test("The shortfall sentence comes from the one place entitled to make it")
    func shortfallStatementIsNotASecondOpinion() {
        let short = shortSnapshot()
        guard case let .explained(breakdown) =
                SafeToUseExplanation.make(from: short, isAvailable: true) else {
            Issue.record("expected a breakdown")
            return
        }
        #expect(breakdown.outcome == .short(PlanningTotals.shortfall(from: short)))
    }

    /// Short over the window by 250, and short by a *different* 209 on the day
    /// the projection first fails. Both are true of different spans, which is
    /// exactly the pair a screen must not print side by side.
    private func shortSnapshot() -> FinanceAppSnapshot {
        var short = coherentSnapshot()
        short.accountCash = .eur(50)
        short.committedOutflows = .eur(300)
        short.safeToSpend = .eur(0)
        short.safeToSpendReason = .shortfall(.eur(250))
        short.firstRisk = RiskPoint(
            date: CalendarDay(year: 2026, month: 9, day: 14),
            projectedBalance: .eur(-209),
            triggerLabel: "Rent",
            triggerAmount: .eur(400),
            kind: .hardDeficit,
            riskAmount: .eur(209)
        )
        return short
    }

    @Test("A shortfall is stated once, as one amount")
    func onlyOneShortfallFigureReachesTheScreen() {
        let short = shortSnapshot()
        guard case let .explained(breakdown) =
                SafeToUseExplanation.make(from: short, isAvailable: true) else {
            Issue.record("expected a breakdown")
            return
        }

        // The window deficit is the figure, written as what it is short by
        // rather than as a negative number under a negative label.
        #expect(breakdown.headroom == Amount.eur(-250))
        #expect(breakdown.resultLabel == "Short by")
        #expect(breakdown.resultValue == Amount.eur(250))
        #expect(breakdown.isShort)

        // The risk day's own shortfall is a different measurement. Its day is
        // useful and is used; its amount would contradict the row above.
        // Locale decides the order of day and month; both halves are there.
        #expect(breakdown.summary.contains("September"))
        #expect(breakdown.summary.contains("14"))
        #expect(!breakdown.summary.contains(Amount.eur(209).formatted()))
        #expect(!breakdown.summary.contains(Amount.eur(250).formatted()))
        #expect(breakdown.methodFooter.contains("shown as zero"))
    }

    @Test("With no risk day the shortfall sentence names none")
    func undatedShortfallBorrowsNoDay() {
        var short = shortSnapshot()
        short.firstRisk = nil
        guard case let .explained(breakdown) =
                SafeToUseExplanation.make(from: short, isAvailable: true) else {
            Issue.record("expected a breakdown")
            return
        }
        #expect(breakdown.summary == "Committed payments come to more than the money on your accounts, so nothing is free to use.")
        #expect(breakdown.resultValue == Amount.eur(250))
    }

    @Test("A funded figure says what it is left over from, and claims no shortfall")
    func fundedCopyIsPlain() {
        guard case let .explained(breakdown) =
                SafeToUseExplanation.make(from: coherentSnapshot(), isAvailable: true) else {
            Issue.record("expected a breakdown")
            return
        }
        #expect(breakdown.resultLabel == "Safe to use")
        #expect(breakdown.resultValue == breakdown.safeToUse)
        #expect(breakdown.windowCaption == "Over the next 30 days")
        #expect(breakdown.summary.contains("the next 30 days"))
        #expect(!breakdown.isShort)
        #expect(!breakdown.methodFooter.contains("shown as zero"))
    }

    @Test("A coherent snapshot with nothing to qualify carries no notes")
    func quietFigureSaysNothingExtra() {
        guard case let .explained(breakdown) =
                SafeToUseExplanation.make(from: coherentSnapshot(), isAvailable: true) else {
            Issue.record("expected a breakdown")
            return
        }
        #expect(breakdown.notes.isEmpty)
    }

    // MARK: - N: navigation and boundary

    @Test("Home routes to the explanation and moves no money doing it")
    func openingTheExplanationChangesNothing() {
        let store = FinanceStore.preview()
        let before = store.snapshot
        let navigation = AppNavigation()

        navigation.openHome(.safeToUse)
        #expect(navigation.selectedTab == .home)
        #expect(navigation.homePath.count == 1)
        #expect(store.snapshot == before)
        #expect(store.snapshot.safeToSpend == before.safeToSpend)
        #expect(store.snapshot.committedOutflows == before.committedOutflows)

        // The route onward is the Plan destination that already owns the
        // obligations, not a second list of them.
        navigation.openPlan(.upcoming)
        #expect(navigation.selectedTab == .plan)
        #expect(store.snapshot == before)
    }

    @Test("The explanation screen holds no safe-to-use authority of its own")
    func theScreenOnlyRenders() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FinanceApp")
        let view = try String(
            contentsOf: app.appendingPathComponent("Features/Home/SafeToUseExplanationView.swift"),
            encoding: .utf8
        )
        // It may render a reconciled breakdown. It may not reach a raw
        // component, restate the clamp, or total anything for itself.
        for forbidden in [
            "safeToSpend",
            "committedOutflows",
            "accountCash",
            "rawShortfall",
            "clampedToZero",
            "PlanningTotals.setAside",
            "reduce(",
            "magnitude",
        ] {
            #expect(!view.contains(forbidden), "the screen reached \(forbidden)")
        }
        #expect(view.contains("SafeToUseExplanation.make"))
        #expect(view.contains("navigation.openPlan(.upcoming)"))

        // Home still leads with the authoritative figure, and now hands over.
        let home = try String(
            contentsOf: app.appendingPathComponent("Features/Home/HomeView.swift"),
            encoding: .utf8
        )
        #expect(home.contains("MoneyText(amount: snapshot.safeToSpend"))
        #expect(home.contains("navigation.openHome(.safeToUse)"))
    }

    @Test("Every figure on the screen is separately addressable")
    func automationIdentifiersAreDistinct() {
        #expect(Set(SafeToUseID.all).count == SafeToUseID.all.count)
        #expect(SafeToUseID.all.allSatisfy { $0.hasPrefix("safe.") })
        // None of them may be matched by, or match, Home's own headline.
        #expect(!SafeToUseID.all.contains(RouteID.homeSafeToUse))
        #expect(SafeToUseID.all.allSatisfy { !$0.hasPrefix(RouteID.homeSafeToUse) })
    }
}
