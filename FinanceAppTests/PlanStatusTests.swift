import FinanceCore
import Foundation
import Testing
@testable import FinanceApp

/// The Plan tab states whether the plan holds, and routes to the screen that
/// answers it.
///
/// Every case drives a real document through the real engine and the real
/// presentation mapper, because the point of the feature is that one forecast's
/// verdict survives that journey into one sentence. Nothing here reconstructs a
/// risk from a balance, and nothing asserts on a figure the engine did not
/// produce.
///
/// All values and identities are synthetic.
@MainActor
@Suite("Plan status")
struct PlanStatusTests {

    private static let today = Day(year: 2026, month: 9, day: 3)

    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    private func obligation(_ id: String, _ amount: String, onDay: Int) -> RecurringObligation {
        RecurringObligation(
            id: id, name: id.capitalized, amount: euro(amount),
            spec: .monthly(
                onDay: onDay,
                from: MonthKey(year: 2026, month: 9),
                through: MonthKey(year: 2026, month: 9)
            ),
            requirement: .euroBankPayment(),
            spendingClass: .essential
        )
    }

    /// One euro account, an optional reserve, whatever obligations the case
    /// needs. The same shape `CashRiskKindTests` uses, so the two suites are
    /// talking about the same plans.
    private func store(
        balance: String,
        safetyFloor: String? = nil,
        obligations: [RecurringObligation] = [],
        forecastRunner: ((ForecastRequest) throws -> ForecastResult)? = nil
    ) -> FinanceStore {
        let current = Account(
            id: "current", name: "Current", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 0
        )
        var planning = FinanceDocument.Planning(
            defaultScenario: .base,
            recurringObligations: obligations
        )
        planning.safetyFloor = safetyFloor.map(euro)
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [current],
            balances: [
                AccountBalance(accountID: "current", balance: euro(balance), asOf: Self.today)
            ],
            planning: planning
        )
        if let forecastRunner {
            return FinanceStore(
                document: document, today: Self.today, scenario: .base,
                forecastRunner: forecastRunner
            )
        }
        return FinanceStore(document: document, today: Self.today, scenario: .base)
    }

    private func status(in store: FinanceStore) -> PlanStatusPresentation {
        store.currentPresentation().attention.plan
    }

    /// The day exactly as Plan writes it, and as Home writes it. Asserting on
    /// a hardcoded "6 September" pins the test machine's locale rather than
    /// the product: the same code reads "September 6" in en_US.
    private func planDayText(_ day: CalendarDay) -> String {
        day.formatted(.dateTime.day().month(.wide))
    }

    private func homeDayText(_ day: CalendarDay) -> String {
        day.formatted(.dateTime.day().month(.abbreviated))
    }

    // MARK: - The four states

    @Test("A plan nothing threatens is called funded, and offers what is coming")
    func fundedPlanSaysSo() {
        let status = status(
            in: store(balance: "5000.00", obligations: [obligation("gym", "150.00", onDay: 6)])
        )

        #expect(status.kind == .funded)
        #expect(status.headline == "Your plan is funded.")
        // Nothing is missing, so no sentence may imply that anything is.
        #expect(!status.headline.lowercased().contains("short"))
        #expect(!status.headline.lowercased().contains("gap"))
        #expect(status.triggerEventID == nil)
        #expect(status.action?.destination == .planUpcoming)
        #expect(!status.isTinted)
    }

    @Test("Money that is genuinely missing is stated with its own day and amount")
    func deficitNamesTheGap() throws {
        let store = store(
            balance: "100.00", obligations: [obligation("rent", "300.00", onDay: 6)]
        )
        let status = status(in: store)
        let risk = try #require(store.snapshot.firstRisk)

        #expect(status.kind == .fundingGap)
        #expect(status.isTinted)
        // The amount and the day come from one risk point, so the sentence can
        // be checked against that point rather than against a second sum.
        #expect(status.headline.contains(risk.riskAmount?.formatted() ?? "!"))
        #expect(status.headline.contains(planDayText(risk.date)))
        // A deficit is never described as a reserve being crossed.
        #expect(!status.headline.lowercased().contains("reserve"))
        #expect(!(status.detail ?? "").lowercased().contains("reserve"))
    }

    @Test("A reserve breach stays a funded plan, and is never called a shortfall")
    func reserveWarningIsNotADeficit() throws {
        // 500 on the account, a 400 reserve, 150 leaving: 350 remains. Funded,
        // and 50 under a line the person drew themselves.
        let store = store(
            balance: "500.00", safetyFloor: "400.00",
            obligations: [obligation("gym", "150.00", onDay: 6)]
        )
        let status = status(in: store)

        #expect(status.kind == .reserveWarning)
        #expect(status.headline.contains("stays funded"))
        #expect(status.headline.lowercased().contains("safety reserve"))
        // The old collapse of the two risks told a person holding 350,00 € that
        // they were 50,00 € short. Nothing is short here and nothing may say so.
        #expect(!status.headline.lowercased().contains("short on"))
        #expect(!status.headline.lowercased().contains("funding gap"))
        // The floor the person set is named, because "below your reserve"
        // without it leaves them guessing which reserve.
        #expect(status.detail?.contains("400,00") == true || status.detail?.contains("400.00") == true)
        #expect(status.detail?.contains("50,00") == true || status.detail?.contains("50.00") == true)
    }

    @Test("A projection that did not run claims nothing at all")
    func failedProjectionIsUnknownNotSafe() {
        struct ForecastUnavailable: Error {}
        let store = store(
            balance: "100.00",
            obligations: [obligation("rent", "300.00", onDay: 6)],
            forecastRunner: { _ in throw ForecastUnavailable() }
        )
        let status = status(in: store)

        #expect(status.kind == .unavailable)
        // Unknown is not funded, and it is not a gap either.
        #expect(!status.headline.contains("funded"))
        // Nothing to route to: there is no fact to explain.
        #expect(status.action == nil)
        #expect(status.triggerEventID == nil)
        #expect(!store.safeToUseIsAvailable)
    }

    // MARK: - The honesty rule

    @Test("A forecast that ran but did not hold together is unknown, never funded")
    func incoherentForecastIsNeverFunded() {
        // The exact trap this feature could have fallen into. `safeToUseIsAvailable`
        // is the forecast having *run*; the attention layer additionally records
        // whether its first risk held together. A run whose risk was rejected as
        // incoherent leaves no candidate behind, and reading that absence as
        // "no risk" would print "Your plan is funded" over a contradiction.
        let state = AttentionState(
            primary: nil, secondary: [], actionableCandidates: [], suppressed: [],
            outcome: .indeterminate(failedKeys: [.forecastProjection])
        )
        let presentation = AttentionPresentationMapper.present(
            state,
            snapshot: .empty(asOf: CalendarDay(year: 2026, month: 9, day: 3)),
            heroIsAvailable: true,
            planFundingIsEstablished: false
        )

        #expect(presentation.plan.kind == .unavailable)
        #expect(presentation.plan.action == nil)
    }

    @Test("No candidate plus an established forecast is the only route to funded")
    func fundedNeedsAnEstablishedForecast() {
        let state = AttentionState(
            primary: nil, secondary: [], actionableCandidates: [], suppressed: [],
            outcome: .noActionNeeded(
                AttentionQuiet(
                    horizonDays: 120,
                    horizonEnd: CalendarDay(year: 2027, month: 1, day: 1)
                )
            )
        )
        let presentation = AttentionPresentationMapper.present(
            state,
            snapshot: .empty(asOf: CalendarDay(year: 2026, month: 9, day: 3)),
            heroIsAvailable: true,
            planFundingIsEstablished: true
        )

        #expect(presentation.plan.kind == .funded)
        // The horizon is quoted from the run that established it.
        #expect(
            presentation.plan.detail?
                .contains(planDayText(CalendarDay(year: 2027, month: 1, day: 1))) == true
        )
    }

    @Test("A gap suppressed because a balance is unknown is not a funded plan")
    func aSuppressedGapNeverReadsAsSafety() {
        // A second euro payment account with no balance on file. The pool it
        // belongs to cannot be established, so `currentAccountTruth` is
        // incoherent and the funding gap is suppressed rather than shown.
        //
        // The gap leaves no candidate behind when that happens. Reading that
        // absence as "no risk found" would print "Your plan is funded" over an
        // account nobody can value — which is why the funded claim tests every
        // dependency the gap declares, not just the forecast.
        let current = Account(
            id: "current", name: "Current", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 0
        )
        let unvalued = Account(
            id: "unvalued", name: "Second", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 1
        )
        var planning = FinanceDocument.Planning(
            defaultScenario: .base,
            recurringObligations: [obligation("rent", "300.00", onDay: 6)]
        )
        planning.safetyFloor = nil
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [current, unvalued],
            balances: [
                AccountBalance(accountID: "current", balance: euro("100.00"), asOf: Self.today)
            ],
            planning: planning
        )
        let store = FinanceStore(document: document, today: Self.today, scenario: .base)
        let status = status(in: store)

        #expect(status.kind == .unavailable)
        #expect(!status.headline.contains("Your plan is funded."))
    }

    // MARK: - Where it sends people

    @Test("Each state routes to the screen that owns its answer")
    func routingIsCanonical() {
        // A deficit with a payment that could not settle: Funding Needed
        // exists to explain exactly that payment.
        let deficit = status(
            in: store(balance: "100.00", obligations: [obligation("rent", "300.00", onDay: 6)])
        )
        #expect(deficit.action?.destination == .planFundingNeeded)

        // A reserve breach: the reserve screen states the comparison and owns
        // the field that changes the floor. Funding Needed has nothing to show
        // here — nothing failed to settle.
        let reserve = status(
            in: store(
                balance: "500.00", safetyFloor: "400.00",
                obligations: [obligation("gym", "150.00", onDay: 6)]
            )
        )
        #expect(reserve.action?.destination == .planSafetyReserve)
        #expect(reserve.action?.destination != .planFundingNeeded)
    }

    @Test("The marked payment is the engine's trigger, not the largest row")
    func theMarkedEventIsTheEnginesOwn() throws {
        // Two obligations. The one that breaks the plan is the earlier, smaller
        // one; a row marked by size would mark the wrong payment.
        let store = store(
            balance: "250.00",
            obligations: [
                obligation("rent", "300.00", onDay: 6),
                obligation("tuition", "900.00", onDay: 20),
            ]
        )
        let status = status(in: store)
        let risk = try #require(store.snapshot.firstRisk)
        let marked = try #require(status.triggerEventID)

        #expect(risk.date == CalendarDay(year: 2026, month: 9, day: 6))
        // Exactly one upcoming row is marked, and it is the one the engine
        // attributed the risk to.
        let matching = store.snapshot.upcomingEvents.filter { $0.id == marked }
        #expect(matching.count == 1)
        #expect(matching.first?.date == risk.date)
    }

    @Test("Nothing is marked when there is no risk to attribute")
    func aFundedPlanMarksNoPayment() {
        let status = status(
            in: store(balance: "5000.00", obligations: [obligation("gym", "150.00", onDay: 6)])
        )
        #expect(status.triggerEventID == nil)
        #expect(store(balance: "5000.00").snapshot.upcomingEvents.allSatisfy { $0.id != status.triggerEventID })
    }

    // MARK: - One truth, two tabs

    @Test("Plan and Home describe the same risk on the same day")
    func planDoesNotContradictHome() throws {
        let store = store(
            balance: "100.00", obligations: [obligation("rent", "300.00", onDay: 6)]
        )
        let presentation = store.currentPresentation().attention
        let status = presentation.plan
        guard case let .act(card, _) = presentation.home else {
            Issue.record("expected Home to raise this risk too, got \(presentation.home)")
            return
        }
        let risk = try #require(store.snapshot.firstRisk)
        let amount = try #require(risk.fundingDeficit)

        // Different sentences, one fact: both name the same money and the same
        // day, because both read the same candidate.
        #expect(status.kind == .fundingGap)
        #expect(card.title.contains(amount.formatted()))
        #expect(status.headline.contains(amount.formatted()))
        #expect(card.title.contains(homeDayText(risk.date)))
        #expect(status.headline.contains(planDayText(risk.date)))
    }

    @Test("Plan is allowed a different destination for a reserve breach")
    func planAndHomeMayDisagreeAboutWhereToGo() throws {
        let store = store(
            balance: "500.00", safetyFloor: "400.00",
            obligations: [obligation("gym", "150.00", onDay: 6)]
        )
        let presentation = store.currentPresentation().attention
        guard case let .act(card, _) = presentation.home else {
            Issue.record("expected an attention card, got \(presentation.home)")
            return
        }

        // Home asks what needs doing and sends the person to what is coming.
        // Plan asks what to change and sends them to the floor they set. Both
        // are reading one reserve warning; neither restates the other.
        #expect(card.destination == .planUpcoming)
        #expect(presentation.plan.action?.destination == .planSafetyReserve)
        #expect(presentation.plan.kind == .reserveWarning)
    }

    // MARK: - Derived, never stored

    @Test("The status is recomputed from state, not remembered")
    func statusIsDerivedFromCurrentState() throws {
        // A reserve high enough to be crossed, then lowered until it is not.
        // Nothing records that a warning was ever shown, so the status follows
        // the document rather than a flag.
        let store = store(
            balance: "500.00", safetyFloor: "400.00",
            obligations: [obligation("gym", "150.00", onDay: 6)]
        )
        #expect(status(in: store).kind == .reserveWarning)

        try store.setSafetyReserve(Amount.eur(100))
        #expect(status(in: store).kind == .funded)

        try store.setSafetyReserve(Amount.eur(400))
        #expect(status(in: store).kind == .reserveWarning)
    }

    @Test("Stating the plan's status changes no plan figure")
    func theStatusReadsAndDecidesNothing() {
        let store = store(
            balance: "500.00", safetyFloor: "400.00",
            obligations: [obligation("gym", "150.00", onDay: 6)]
        )
        let before = store.snapshot
        _ = status(in: store)
        let after = store.snapshot

        // Safe to Use, its reason, the budget and the reserve are all exactly
        // what they were: this feature presents, it does not compute.
        #expect(before.safeToSpend == after.safeToSpend)
        #expect(before.safeToSpendReason == after.safeToSpendReason)
        #expect(before.everydayBudget == after.everydayBudget)
        #expect(before.safetyReserve == after.safetyReserve)
        #expect(before.firstRisk == after.firstRisk)
    }

    @Test("The status quotes the funding deficit, not the clamped headline")
    func theStatusIsNotASecondHeadline() throws {
        let store = store(
            balance: "100.00", obligations: [obligation("rent", "300.00", onDay: 6)]
        )
        let status = status(in: store)
        let deficit = try #require(store.snapshot.firstRisk?.fundingDeficit)

        // Safe to Use is clamped to zero here while the plan is 200,00 € short.
        // The status names the money that is actually missing; quoting the
        // clamp instead would be a second, softer answer to a question Home
        // already answers, and it would say nothing is wrong.
        #expect(store.snapshot.safeToSpend.isZero)
        #expect(!deficit.isZero)
        #expect(status.headline.contains(deficit.formatted()))
    }
}
