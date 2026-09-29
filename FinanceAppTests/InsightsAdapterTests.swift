import Foundation
import Testing
import FinanceCore
@testable import FinanceApp

/// The review adapter and its presentation, proved on constructed state rather
/// than on the physical store.
///
/// Several tests assert the `ReviewRequest` itself rather than the words that
/// come out the far end: the request is the contract with FinanceCore, and a
/// screen can read correctly from a request that was assembled wrongly.
@Suite("Insights adapter")
@MainActor
struct InsightsAdapterTests {

    private let cutoff = Day(year: 2026, month: 8, day: 19)
    private let asOf = Day(year: 2026, month: 9, day: 2)

    // MARK: - Fixtures

    private func account(_ id: String = "bank") -> Account {
        Account(id: id, name: "Current", currency: .eur, kind: .bank, supportedRails: [.cardDebit])
    }

    private func expense(
        _ id: String, day: Day, cents: Int64, category: String? = nil
    ) -> Transaction {
        Transaction(
            id: id,
            date: day,
            kind: .expense,
            legs: [AccountLeg(accountID: "bank", amount: Money(minorUnits: -cents, currency: .eur))],
            factivity: .observed
        )
    }

    private func income(
        _ id: String, day: Day, cents: Int64, sourceID: String?
    ) -> Transaction {
        Transaction(
            id: id,
            date: day,
            kind: .income,
            legs: [AccountLeg(accountID: "bank", amount: Money(minorUnits: cents, currency: .eur))],
            incomeSourceID: sourceID,
            factivity: .observed
        )
    }

    private func incomeSource(_ id: String, name: String) -> IncomeSource {
        IncomeSource(
            id: id,
            name: name,
            amount: Money(minorUnits: 0, currency: .eur),
            certainty: .guaranteed,
            schedule: .monthly(onDay: 1, from: MonthKey(year: 2026, month: 1), through: nil)
        )
    }

    private func document(
        transactions: [Transaction] = [],
        incomeSources: [IncomeSource] = [],
        budgets: [BudgetAllocation] = [],
        balanceCents: Int64 = 50_000,
        monthlyCeilingCents: Int64? = nil,
        obligations: [RecurringObligation] = [],
        floorCents: Int64? = nil,
        extraAccounts: [Account] = [],
        extraBalances: [AccountBalance] = []
    ) -> FinanceDocument {
        FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account()] + extraAccounts,
            balances: [
                AccountBalance(
                    accountID: "bank",
                    balance: Money(minorUnits: balanceCents, currency: .eur),
                    asOf: cutoff
                )
            ] + extraBalances,
            transactions: transactions,
            incomeSources: incomeSources,
            planning: FinanceDocument.Planning(
                safetyFloor: floorCents.map { Money(minorUnits: $0, currency: .eur) },
                monthlyEconomicCeiling: monthlyCeilingCents.map {
                    Money(minorUnits: $0, currency: .eur)
                },
                budgets: budgets,
                recurringObligations: obligations
            )
        )
    }

    /// Live coverage spanning the whole post-cutoff era used by these tests.
    private func fullLive(
        from: Day = Day(year: 2026, month: 8, day: 20),
        through: Day = Day(year: 2026, month: 9, day: 2)
    ) -> LiveCoverageResolution {
        LiveCoverageResolution(
            intervals: [ReviewInterval(start: from, end: through)],
            unknownAccountIDs: [],
            knownAccountIDs: ["bank"]
        )
    }

    private func request(
        _ document: FinanceDocument,
        selection: ReviewPeriodSelection,
        live: LiveCoverageResolution,
        incomeSources: [IncomeSource] = [],
        categoryKeys: [String: String] = [:]
    ) throws -> ReviewRequest {
        try #require(ReviewRequestBuilder.makeRequest(
            document: document,
            selection: selection,
            asOf: asOf,
            categoryKeys: categoryKeys,
            incomeSources: incomeSources,
            coverage: ReviewCoverageAdapter.coverageInput(
                archiveCutoff: cutoff, history: nil, live: live
            )
        ))
    }

    private func present(
        _ document: FinanceDocument,
        selection: ReviewPeriodSelection,
        live: LiveCoverageResolution,
        incomeSources: [IncomeSource] = [],
        categoryKeys: [String: String] = [:],
        labels: ReviewPresentationMapper.Labels = .init()
    ) throws -> InsightsPresentation {
        let request = try request(
            document, selection: selection, live: live,
            incomeSources: incomeSources, categoryKeys: categoryKeys
        )
        return ReviewPresentationMapper.present(
            try ReviewEngine.review(request),
            selection: selection,
            calendarInterval: try #require(
                ReviewRequestBuilder.calendarInterval(selection, asOf: asOf)
            ),
            canGoBack: true,
            canGoForward: selection.offset < 0,
            live: live,
            labels: labels
        )
    }

    // MARK: - Period boundaries

    @Test("An unresolved finding links only when every subject is an actionable bank decision")
    func actionableFindingDestination() {
        let known: Set<String> = ["bank-a", "bank-b"]
        #expect(ReviewPresentationMapper.destination(
            kind: .unresolvedEvidenceAffectingAccuracy,
            ids: ["bank-a", "bank-b"], actionableObservationIDs: known
        ) == .reviewItems(["bank-a", "bank-b"]))
        #expect(ReviewPresentationMapper.destination(
            kind: .unresolvedEvidenceAffectingAccuracy,
            ids: ["bank-a", "ledger-c"], actionableObservationIDs: known
        ) == nil)
        #expect(ReviewPresentationMapper.destination(
            kind: .unresolvedEvidenceAffectingAccuracy,
            ids: ["missing-live-coverage"], actionableObservationIDs: known
        ) == nil)
        #expect(ReviewPresentationMapper.destination(
            kind: .budgetOverrun,
            ids: ["bank-a"], actionableObservationIDs: known
        ) == nil)
    }

    @Test("The first Insights conclusion prioritizes unresolved evidence over a change")
    func reviewFindingLeadsThePeriod() {
        let change = ReviewFindingCard(
            id: "change", tone: .info, role: .change,
            title: "Spending changed", detail: "A period change.", destination: nil
        )
        let review = ReviewFindingCard(
            id: "review", tone: .warning, role: .reviewItems,
            title: "Items still to review", detail: "One item needs review.",
            destination: .reviewItems(["bank-a"])
        )
        let zero = ReviewFigure.known(Amount(
            minorUnits: 0, currencyCode: "EUR", fractionDigits: 2
        ))
        #expect(ReviewPresentationMapper.summary(
            findings: [change, review], spending: zero, income: zero, complete: true
        ) == review.title)
        #expect(ReviewPresentationMapper.summary(
            findings: [change, review], spending: .unavailable,
            income: .unavailable, complete: false
        ) == "Totals unavailable")
    }

    @Test("An Insight focus can be cleared without leaving Activity")
    func reviewFocusNavigation() {
        let navigation = AppNavigation()
        navigation.openReviewItems(["bank-a", "bank-b"])
        #expect(navigation.selectedTab == .activity)
        #expect(navigation.activitySection == .toReview)
        #expect(navigation.activityReviewIDs == ["bank-a", "bank-b"])
        navigation.openToReview()
        #expect(navigation.activityReviewIDs == nil)
    }

    @Test("Weeks start on Monday")
    func weekStartsMonday() throws {
        // 2026-09-02 is a Wednesday; its week began Monday the 31st.
        #expect(
            ReviewRequestBuilder.startOfWeek(containing: asOf)
                == Day(year: 2026, month: 8, day: 31)
        )
        // A Monday is its own week start.
        #expect(
            ReviewRequestBuilder.startOfWeek(containing: Day(year: 2026, month: 8, day: 31))
                == Day(year: 2026, month: 8, day: 31)
        )
        // A Sunday belongs to the week that began six days earlier.
        #expect(
            ReviewRequestBuilder.startOfWeek(containing: Day(year: 2026, month: 9, day: 6))
                == Day(year: 2026, month: 8, day: 31)
        )
    }

    @Test("A current period is reviewed only as far as today")
    func currentPeriodClampsToAsOf() throws {
        let week = try #require(ReviewRequestBuilder.reviewedInterval(
            ReviewPeriodSelection(scope: .week, offset: 0), asOf: asOf
        ))
        #expect(week.start == Day(year: 2026, month: 8, day: 31))
        #expect(week.end == asOf)

        let month = try #require(ReviewRequestBuilder.reviewedInterval(
            ReviewPeriodSelection(scope: .month, offset: 0), asOf: asOf
        ))
        #expect(month.start == Day(year: 2026, month: 9, day: 1))
        #expect(month.end == asOf)

        // A finished period keeps its whole extent.
        let priorWeek = try #require(ReviewRequestBuilder.reviewedInterval(
            ReviewPeriodSelection(scope: .week, offset: -1), asOf: asOf
        ))
        #expect(priorWeek.start == Day(year: 2026, month: 8, day: 24))
        #expect(priorWeek.end == Day(year: 2026, month: 8, day: 30))
    }

    @Test("Navigation stops before the archive era")
    func navigationStopsAtArchive() throws {
        let earliest = ReviewRequestBuilder.earliestOffset(
            scope: .week, asOf: asOf, archiveCutoff: cutoff
        )
        let firstOffered = try #require(ReviewRequestBuilder.calendarInterval(
            ReviewPeriodSelection(scope: .week, offset: earliest), asOf: asOf
        ))
        // The oldest offered week lies wholly after the cutoff.
        #expect(firstOffered.start > cutoff)
        let tooFar = try #require(ReviewRequestBuilder.calendarInterval(
            ReviewPeriodSelection(scope: .week, offset: earliest - 1), asOf: asOf
        ))
        #expect(tooFar.start <= cutoff)
    }

    // MARK: - The request itself

    @Test("The request carries the period, as-of, policy and coverage verbatim")
    func requestShape() throws {
        let live = fullLive()
        let built = try request(
            document(), selection: ReviewPeriodSelection(scope: .week, offset: 0), live: live
        )
        #expect(built.kind == .weekly)
        #expect(built.interval.start == Day(year: 2026, month: 8, day: 31))
        #expect(built.interval.end == asOf)
        #expect(built.asOf == asOf)
        #expect(built.currency == .eur)
        #expect(built.comparePreviousPeriod)
        #expect(built.findingPolicy == .standard)
        #expect(built.coverage.archiveCutoff == cutoff)
        #expect(built.coverage.liveCoveredIntervals == live.intervals)
        // Exceptional nature is a judgement the ledger does not record, so the
        // adapter asserts none and an amount cannot imply one.
        #expect(built.spendingNatures.isEmpty)
        #expect(built.incomeClasses.isEmpty)
        // Not defaulted from the wall clock.
        #expect(built.resolvedForecastEnd == asOf.advanced(by: 30))
    }

    @Test("Income evidence reaches the request only through the income-source bridge")
    func requestEconomicSources() throws {
        let sources = [
            incomeSource("src-parents", name: "Parents"),
            incomeSource("src-job", name: "Bakery job"),
            incomeSource("src-mystery", name: "Transfer"),
        ]
        let built = try request(
            document(incomeSources: sources),
            selection: ReviewPeriodSelection(scope: .month, offset: 0),
            live: fullLive(),
            incomeSources: sources
        )
        // Only the stream whose own name names a canonical source classifies.
        #expect(built.economicSources["src-parents"] == "PARENTAL_SUPPORT_SELF")
        #expect(built.economicSources["src-job"] == nil)
        #expect(built.economicSources["src-mystery"] == nil)
    }

    // MARK: - A/B. Complete week and month

    @Test("A complete week states its totals")
    func completeWeek() throws {
        let review = try present(
            document(transactions: [
                expense("e1", day: Day(year: 2026, month: 9, day: 1), cents: 2_000),
                expense("e2", day: Day(year: 2026, month: 9, day: 2), cents: 1_500),
            ]),
            selection: ReviewPeriodSelection(scope: .week, offset: 0),
            live: fullLive()
        )
        #expect(review.coverage.quality == .complete)
        #expect(review.spending.amount == Amount(minorUnits: 3_500, currencyCode: "EUR"))
        #expect(review.zeroMeansZero)
    }

    @Test("A complete month states its totals")
    func completeMonth() throws {
        let review = try present(
            document(transactions: [
                expense("e1", day: Day(year: 2026, month: 9, day: 1), cents: 4_000),
            ]),
            selection: ReviewPeriodSelection(scope: .month, offset: 0),
            live: fullLive()
        )
        #expect(review.coverage.quality == .complete)
        #expect(review.spending.amount == Amount(minorUnits: 4_000, currencyCode: "EUR"))
    }

    // MARK: - C/D. Partial and insufficient

    @Test("A partial period withholds totals and says which days are missing")
    func partialCoverage() throws {
        // The provider proved only through 1 September; the review runs to the 2nd.
        let review = try present(
            document(transactions: [
                expense("e1", day: Day(year: 2026, month: 9, day: 1), cents: 4_000),
            ]),
            selection: ReviewPeriodSelection(scope: .week, offset: 0),
            live: fullLive(through: Day(year: 2026, month: 9, day: 1))
        )
        #expect(review.coverage.quality == .partial)
        #expect(review.spending == .unavailable)
        #expect(review.income == .unavailable)
        #expect(!review.zeroMeansZero)
        #expect(review.coverage.missingRanges.count == 1)
        #expect(review.coverage.missingRanges.first?.lowerBound == CalendarDay(year: 2026, month: 9, day: 2))
        // The comparison is refused rather than shown as authoritative.
        guard case let .unavailable(reason) = review.comparison else {
            Issue.record("expected refusal")
            return
        }
        #expect(reason.contains("incomplete"))
    }

    @Test("An unknown account makes the period insufficient, not empty")
    func insufficientCoverage() throws {
        let review = try present(
            document(transactions: [
                expense("e1", day: Day(year: 2026, month: 9, day: 1), cents: 4_000),
            ]),
            selection: ReviewPeriodSelection(scope: .week, offset: 0),
            live: LiveCoverageResolution(
                intervals: [], unknownAccountIDs: ["bank"], knownAccountIDs: []
            ),
            labels: ReviewPresentationMapper.Labels(accounts: ["bank": "Current"])
        )
        #expect(review.coverage.quality == .insufficient)
        #expect(review.spending == .unavailable)
        #expect(review.coverage.unknownAccountNames == ["Current"])
        #expect(review.coverage.explanation.contains("Current"))
        // Never the language of an empty period.
        #expect(!review.summary.contains("No spending"))
        #expect(review.summary == "Totals unavailable")
        #expect(review.findings.contains { $0.role == .coverage })
        #expect(!review.remainingFindings.contains { $0.role == .coverage })
    }

    // MARK: - E. True zero

    @Test("A complete period with nothing in it says so plainly")
    func completeZero() throws {
        let review = try present(
            document(),
            selection: ReviewPeriodSelection(scope: .week, offset: 0),
            live: fullLive()
        )
        #expect(review.coverage.quality == .complete)
        #expect(review.spending.amount?.isZero == true)
        #expect(review.summary.contains("No spending"))
        #expect(review.zeroMeansZero)
    }

    // MARK: - F. Cross-month week

    @Test("A week crossing a month end carries both months, never a prorated ceiling")
    func crossMonthWeek() throws {
        let budget = BudgetAllocation(
            id: "everyday",
            name: "Everyday",
            spendingClass: .flexible,
            monthlyAmount: Money(minorUnits: 70_000, currency: .eur),
            effectiveFrom: MonthKey(year: 2026, month: 1),
            confirmation: .userConfirmed,
            categoryKeys: ["groceries"]
        )
        let review = try present(
            document(
                transactions: [
                    expense("e1", day: Day(year: 2026, month: 8, day: 31), cents: 2_000),
                    expense("e2", day: Day(year: 2026, month: 9, day: 1), cents: 3_000),
                ],
                budgets: [budget],
                monthlyCeilingCents: 70_000
            ),
            selection: ReviewPeriodSelection(scope: .week, offset: 0),
            live: fullLive(),
            categoryKeys: ["e1": "groceries", "e2": "groceries"]
        )
        // Both touched months appear, each against its own monthly ceiling.
        #expect(review.monthContexts.count == 2)
        #expect(review.monthContexts.map(\.monthLabel) == [
            CalendarDay.monthTitle(year: 2026, month: 8),
            CalendarDay.monthTitle(year: 2026, month: 9),
        ])
        for context in review.monthContexts {
            #expect(context.ceiling == Amount(minorUnits: 70_000, currencyCode: "EUR"))
        }
        // The week's own economic total is the actual week, not a share.
        #expect(review.spending.amount == Amount(minorUnits: 5_000, currencyCode: "EUR"))
        // 700 x 7/30 would be 163.33; no context may carry a figure like that.
        #expect(!review.monthContexts.contains { $0.ceiling?.minorUnits == 16_333 })
    }

    // MARK: - J/K. Income and support truth

    @Test("Support, earnings and an unexplained inflow stay three different things")
    func incomeClassification() throws {
        let sources = [
            incomeSource("src-parents", name: "Parents"),
            incomeSource("src-job", name: "Bakery job"),
        ]
        let review = try present(
            document(
                transactions: [
                    income("i1", day: Day(year: 2026, month: 9, day: 1), cents: 30_000, sourceID: "src-parents"),
                    income("i2", day: Day(year: 2026, month: 9, day: 1), cents: 20_000, sourceID: "src-job"),
                    income("i3", day: Day(year: 2026, month: 9, day: 2), cents: 5_000, sourceID: "src-job"),
                ],
                incomeSources: sources
            ),
            selection: ReviewPeriodSelection(scope: .month, offset: 0),
            live: fullLive(),
            incomeSources: sources
        )
        let breakdown = review.incomeBreakdown
        // Evidence says support -> support.
        #expect(breakdown.supportOwned == Amount(minorUnits: 30_000, currencyCode: "EUR"))
        // A stream that names no canonical source is never promoted to
        // earnings to fill the screen; it stays unresolved.
        #expect(breakdown.earnedOrOther.isZero)
        #expect(breakdown.unresolved == Amount(minorUnits: 25_000, currencyCode: "EUR"))
        #expect(breakdown.hasUnresolved)
    }

    @Test("The income rows always add up to the headline total")
    func incomeRowsReconcile() throws {
        // The owned share of a pass-through is personal income but belongs to
        // no named class. Without the remainder row the screen would show a
        // total with nothing under it.
        let passThrough = Transaction(
            id: "p1",
            date: Day(year: 2026, month: 9, day: 1),
            kind: .passThrough,
            legs: [AccountLeg(accountID: "bank", amount: Money(minorUnits: 90_000, currency: .eur))],
            ownership: [
                OwnershipSplit(
                    ownerID: "self", isSelf: true,
                    amount: Money(minorUnits: 90_000, currency: .eur)
                )
            ],
            factivity: .observed
        )
        let review = try present(
            document(transactions: [passThrough]),
            selection: ReviewPeriodSelection(scope: .month, offset: 0),
            live: fullLive()
        )
        let income = review.incomeBreakdown
        var named: Int64 = income.earnedOrOther.minorUnits
        named += income.supportOwned.minorUnits
        named += income.reimbursements.minorUnits
        named += income.unresolved.minorUnits
        named += income.otherPersonal.minorUnits
        #expect(named == income.personalIncome.amount?.minorUnits)
        // A period with money in it never reports itself as empty.
        if (income.personalIncome.amount?.minorUnits ?? 0) != 0 {
            #expect(!income.isEmpty)
        }
    }

    // MARK: - M. No findings

    @Test("A quiet complete period produces no findings and says nothing stands out")
    func noFindings() throws {
        let review = try present(
            document(),
            selection: ReviewPeriodSelection(scope: .week, offset: 0),
            live: fullLive()
        )
        #expect(review.findings.isEmpty)
        #expect(review.notableChangeCount == 0)
    }

    // MARK: - N/O. Forward risk

    @Test("Outlook starts at as-of and never reports a period-end balance")
    func outlookIsForwardLooking() throws {
        let review = try present(
            document(balanceCents: 44_747),
            selection: ReviewPeriodSelection(scope: .week, offset: -1),
            live: fullLive()
        )
        // The period under review ended 30 August, but the outlook is anchored
        // on today and its liquidity is today's.
        #expect(review.outlook.asOfDay == CalendarDay(year: 2026, month: 9, day: 2))
        #expect(review.outlook.horizonEnd == CalendarDay(year: 2026, month: 10, day: 2))
        #expect(review.outlook.liquidityNow == Amount(minorUnits: 44_747, currencyCode: "EUR"))
    }

    @Test("No scheduled risk reports no risk rather than an invented one")
    func noForwardRisk() throws {
        let review = try present(
            document(balanceCents: 500_000),
            selection: ReviewPeriodSelection(scope: .month, offset: 0),
            live: fullLive()
        )
        #expect(review.outlook.firstRiskDay == nil)
        #expect(review.outlook.shortfall == nil)
        #expect(!review.outlook.hasRisk)
    }

    // MARK: - Outlook truth

    private func rent(_ cents: Int64, onDay: Int) -> RecurringObligation {
        RecurringObligation(
            id: "ob-rent",
            name: "Rent",
            amount: Money(minorUnits: cents, currency: .eur),
            spec: .monthly(
                onDay: onDay,
                from: MonthKey(year: 2026, month: 9),
                through: MonthKey(year: 2026, month: 9)
            ),
            requirement: .euroBankPayment(),
            spendingClass: .essential,
            budgetID: nil
        )
    }

    /// The physical shape that failed the canary: an anchor plus post-anchor
    /// economics, a second account, and a rent that outruns the pool.
    @Test("Available now equals canonical holdings, and the shortfall is the first risk's own")
    func availableNowAndFirstRiskArePaired() throws {
        let wallet = Account(
            id: "wallet", name: "Wallet", currency: .eur, kind: .wallet,
            supportedRails: PaymentRail.euroWalletRails
        )
        let doc = document(
            transactions: [
                expense("legs", day: Day(year: 2026, month: 8, day: 23), cents: 1_547)
            ],
            balanceCents: 38_409,
            obligations: [rent(48_000, onDay: 11)],
            extraAccounts: [wallet],
            extraBalances: [
                AccountBalance(
                    accountID: "wallet",
                    balance: Money(minorUnits: 7_885, currency: .eur),
                    asOf: cutoff
                )
            ]
        )
        let selection = ReviewPeriodSelection(scope: .month, offset: 0)
        let live = fullLive()
        let review = try present(doc, selection: selection, live: live)
        let result = try ReviewEngine.review(try request(doc, selection: selection, live: live))

        // 384.09 - 15.47 + 78.85 = 447.47, the canonical holdings figure.
        #expect(review.outlook.liquidityNow == Amount(minorUnits: 44_747, currencyCode: "EUR"))
        #expect(result.risk.asOfLedgerLiquidity.minorUnits == 44_747)
        #expect(
            CurrentHoldings.euroFinancialAccountLiquidity(in: doc, asOf: asOf).minorUnits == 44_747
        )

        guard let first = result.risk.firstRisk else {
            Issue.record("expected a first risk")
            return
        }
        #expect(review.outlook.firstRiskDay == CalendarDay(year: 2026, month: 9, day: 11))
        #expect(first.day == Day(year: 2026, month: 9, day: 11))
        // The amount beside that date is the first risk's own shortfall.
        #expect(review.outlook.shortfall?.minorUnits == first.shortfall.minorUnits)
        // And never the horizon-wide bridge, whenever the two differ.
        let bridge = result.risk.minimumBridgeRequired
        if bridge.minorUnits != first.shortfall.minorUnits {
            #expect(review.outlook.shortfall?.minorUnits != bridge.minorUnits)
        }
    }

    @Test("A same-day floor breach behind a pool deficit is not shown twice")
    func sameDayFloorIsSuppressed() throws {
        let doc = document(
            balanceCents: 12_000,
            obligations: [rent(48_000, onDay: 11)],
            floorCents: 5_000
        )
        let selection = ReviewPeriodSelection(scope: .month, offset: 0)
        let live = fullLive()
        let result = try ReviewEngine.review(try request(doc, selection: selection, live: live))
        // The engine still reports both facts.
        #expect(result.risk.firstHardCashRiskDate != nil)
        #expect(result.risk.firstFloorWarningDate == result.risk.firstHardCashRiskDate)
        #expect(result.risk.firstRisk?.kind == .poolDeficit)

        let review = try present(doc, selection: selection, live: live)
        // The screen shows the stronger one only, and never says "still
        // positive" on a day the pool is negative.
        #expect(review.outlook.floorWarningDay == nil)
        #expect(review.outlook.firstRiskKind == .poolDeficit)
        #expect(!review.forwardFindings.contains { $0.detail.contains("Still positive") })
        #expect(review.forwardFindings.filter { $0.title.contains("floor") }.isEmpty)
    }

    @Test("A floor breach with no deficit is still reported")
    func independentFloorWarningSurvives() throws {
        // Enough cash that the pool stays positive, but a floor high enough
        // that the rent takes it under the cushion.
        let doc = document(
            balanceCents: 60_000,
            obligations: [rent(48_000, onDay: 11)],
            floorCents: 30_000
        )
        let selection = ReviewPeriodSelection(scope: .month, offset: 0)
        let live = fullLive()
        let result = try ReviewEngine.review(try request(doc, selection: selection, live: live))
        #expect(result.risk.firstHardCashRiskDate == nil)
        #expect(result.risk.firstFloorWarningDate != nil)

        let review = try present(doc, selection: selection, live: live)
        #expect(review.outlook.floorWarningDay != nil)
        #expect(review.outlook.firstRiskDay == nil)
        #expect(review.forwardFindings.contains { $0.title.contains("floor") })
    }

    @Test("Forward risk appears under what to watch, never under what changed")
    func forwardFindingsArePartitioned() throws {
        let doc = document(balanceCents: 12_000, obligations: [rent(48_000, onDay: 11)])
        let selection = ReviewPeriodSelection(scope: .month, offset: 0)
        let live = fullLive()
        let review = try present(doc, selection: selection, live: live)

        // The canonical first risk is stated by the outlook summary, so the
        // duplicate card is gone; what matters is that it is in What to watch
        // and not in What changed.
        #expect(review.outlook.firstRiskDay != nil)
        #expect(review.outlook.shortfall != nil)
        // Nothing forward-looking leaks into the period section, and nothing
        // is duplicated across the two.
        let forwardIDs = Set(review.forwardFindings.map(\.id))
        let periodIDs = Set(review.findings.map(\.id))
        #expect(forwardIDs.isDisjoint(with: periodIDs))
        #expect(!review.findings.contains { $0.title.contains("runs short") })
        #expect(!review.findings.contains { $0.title.contains("floor") })
        // The headline count describes the period, not the forecast.
        #expect(review.notableChangeCount == review.findings.count)
    }

    @Test("A quiet complete period reports no changes rather than borrowing the outlook")
    func quietPeriodStaysQuiet() throws {
        let doc = document(balanceCents: 12_000, obligations: [rent(48_000, onDay: 11)])
        let review = try present(
            doc,
            selection: ReviewPeriodSelection(scope: .month, offset: 0),
            live: fullLive()
        )
        // There is a real forward risk — carried by the outlook summary — but
        // nothing happened in the period itself.
        #expect(review.outlook.hasRisk)
        #expect(review.findings.isEmpty)
        #expect(review.notableChangeCount == 0)
        #expect(!review.summary.contains("stand out"))
    }

    // MARK: - Internal identifiers never reach the screen

    /// `FirstRisk.triggerLabel` is `sourceRef ?? eventID`, so for a recurring
    /// obligation it is the obligation *id*. It reached the phone as
    /// "ob-rent on 11 Sep is the first shortfall."
    @Test("The first-risk trigger is named, never identified")
    func firstRiskUsesHumanLabel() throws {
        let doc = document(balanceCents: 12_000, obligations: [rent(48_000, onDay: 11)])
        let selection = ReviewPeriodSelection(scope: .month, offset: 0)
        let live = fullLive()
        let result = try ReviewEngine.review(try request(doc, selection: selection, live: live))

        // The engine hands over an identifier, which is exactly the trap.
        #expect(result.risk.firstRisk?.triggerLabel == "ob-rent")

        let review = try present(
            doc, selection: selection, live: live,
            labels: ReviewPresentationMapper.Labels(riskTriggers: ["ob-rent": "Rent"])
        )
        #expect(review.outlook.firstRiskLabel == "Rent")
    }

    /// The semantic boundary, not a string scrubber: presentation shows a name
    /// it was given, and shows nothing rather than a reference it cannot name.
    @Test("An unresolvable trigger yields no label instead of an identifier")
    func unresolvedTriggerLeaksNothing() throws {
        let doc = document(balanceCents: 12_000, obligations: [rent(48_000, onDay: 11)])
        let review = try present(
            doc,
            selection: ReviewPeriodSelection(scope: .month, offset: 0),
            live: fullLive(),
            labels: ReviewPresentationMapper.Labels()   // nothing resolvable
        )
        #expect(review.outlook.firstRiskLabel == nil)

        // No user-visible string anywhere on the screen carries the id.
        let visible = [review.summary, review.coverage.explanation, review.title,
                       review.rangeLabel, review.outlook.firstRiskLabel ?? ""]
            + review.findings.flatMap { [$0.title, $0.detail] }
            + review.forwardFindings.flatMap { [$0.title, $0.detail] }
            + review.monthContexts.map(\.monthLabel)
            + review.topCategories.map(\.name)
        for text in visible {
            #expect(!text.contains("ob-rent"))
            #expect(!text.contains("ob-"))
        }
    }

    // MARK: - One first risk, stated once

    @Test("The outlook summary and an identical finding are not both rendered")
    func identicalFirstRiskIsStatedOnce() throws {
        let doc = document(balanceCents: 12_000, obligations: [rent(48_000, onDay: 11)])
        let selection = ReviewPeriodSelection(scope: .month, offset: 0)
        let live = fullLive()
        let result = try ReviewEngine.review(try request(doc, selection: selection, live: live))
        // The engine still returns it; only the screen declines to repeat it.
        #expect(result.findings.contains { $0.kind == .upcomingLiquidityRisk })

        let review = try present(doc, selection: selection, live: live)
        #expect(review.outlook.firstRiskDay != nil)
        #expect(review.outlook.shortfall != nil)
        #expect(!review.forwardFindings.contains { $0.title.contains("runs short") })
    }

    @Test("A forward finding with no first-risk summary above it still shows")
    func forwardFindingSurvivesWithoutSummary() throws {
        // A goal deadline is forward-looking but is not the first risk, and
        // there is no liquidity risk here to summarise.
        let doc = document(balanceCents: 500_000)
        let review = try present(
            doc,
            selection: ReviewPeriodSelection(scope: .month, offset: 0),
            live: fullLive()
        )
        #expect(review.outlook.firstRiskDay == nil)
        // Nothing was suppressed on the way through.
        let result = try ReviewEngine.review(
            try request(doc, selection: ReviewPeriodSelection(scope: .month, offset: 0), live: fullLive())
        )
        let forwardKinds = result.findings.filter {
            ReviewPresentationMapper.isForwardLooking($0.kind)
        }
        #expect(review.forwardFindings.count == forwardKinds.count)
    }

    @Test("A floor warning that stands alone is not deduplicated away")
    func independentFloorSurvivesDeduplication() throws {
        let doc = document(
            balanceCents: 60_000,
            obligations: [rent(48_000, onDay: 11)],
            floorCents: 30_000
        )
        let review = try present(
            doc,
            selection: ReviewPeriodSelection(scope: .month, offset: 0),
            live: fullLive()
        )
        #expect(review.outlook.firstRiskDay == nil)
        #expect(review.outlook.floorWarningDay != nil)
        #expect(review.forwardFindings.contains { $0.title.contains("floor") })
    }

    // MARK: - Records behind a figure

    // A screen that says "see the transactions behind this" is only honest
    // when the list adds up to the number it was opened from. These prove the
    // lists come from the engine's own contributions, add up exactly, and are
    // withheld whenever they would not.

    private func groceries() -> BudgetAllocation {
        BudgetAllocation(
            id: "groceries",
            name: "Groceries",
            spendingClass: .flexible,
            monthlyAmount: Money(minorUnits: 30_000, currency: .eur),
            effectiveFrom: MonthKey(year: 2026, month: 1),
            confirmation: .userConfirmed,
            categoryKeys: ["groceries"]
        )
    }

    private func linkedMonth() throws -> InsightsPresentation {
        try present(
            document(
                transactions: [
                    expense("e1", day: Day(year: 2026, month: 9, day: 1), cents: 4_000),
                    expense("e2", day: Day(year: 2026, month: 9, day: 2), cents: 2_500),
                    expense("e3", day: Day(year: 2026, month: 9, day: 2), cents: 1_200),
                ],
                budgets: [groceries()],
                monthlyCeilingCents: 5_000
            ),
            selection: ReviewPeriodSelection(scope: .month, offset: 0),
            live: fullLive(),
            categoryKeys: ["e1": "groceries", "e2": "groceries"],
            labels: ReviewPresentationMapper.Labels(
                budgetLines: ["groceries": "Groceries"],
                ledgerTransactionIDs: ["e1", "e2", "e3"]
            )
        )
    }

    private func sum(_ set: ReviewRecordSet) -> Int64 {
        set.records.reduce(0) { $0 + $1.counted.minorUnits }
    }

    @Test("Spending, each category and each month open lists that add up to them")
    func recordListsAddUp() throws {
        let review = try linkedMonth()

        let spent = try #require(review.spendingRecords)
        #expect(spent.total == review.spending.amount)
        #expect(sum(spent) == spent.total.minorUnits)
        #expect(Set(spent.records.map(\.id)) == ["e1", "e2", "e3"])

        let category = try #require(review.topCategories.first { $0.id == "groceries" })
        let categoryRecords = try #require(category.records)
        #expect(categoryRecords.total == category.amount)
        #expect(Set(categoryRecords.records.map(\.id)) == ["e1", "e2"])
        #expect(categoryRecords.owner == .budget)

        let month = try #require(review.monthContexts.first)
        let monthRecords = try #require(month.records)
        #expect(monthRecords.total == month.monthSpending)
        #expect(sum(monthRecords) == month.monthSpending.minorUnits)
    }

    @Test("An over-budget month opens exactly the records behind the figure it quotes")
    func budgetOverrunOpensItsMonth() throws {
        let review = try linkedMonth()
        let overrun = try #require(review.findings.first { $0.title.contains("over budget") })
        guard case let .records(set)? = overrun.destination else {
            Issue.record("expected a record list, got \(String(describing: overrun.destination))")
            return
        }
        #expect(set.total == review.monthContexts.first?.monthSpending)
        #expect(overrun.detail.contains(set.total.formatted()))
    }

    @Test("A list is found again by its identifier, from whichever review is current")
    func recordSetsResolveByIdentifier() throws {
        let review = try linkedMonth()
        let ids = [review.spendingRecords?.id]
            + review.topCategories.map { $0.records?.id }
            + review.monthContexts.map { $0.records?.id }
        for id in ids.compactMap({ $0 }) {
            #expect(review.recordSet(id: id)?.id == id)
        }
        // A finding's list is one of those same sets, so its route resolves.
        for finding in review.findings {
            if case let .records(set)? = finding.destination {
                #expect(review.recordSet(id: set.id) == set)
            }
        }
        #expect(review.recordSet(id: "line:nobody") == nil)

        // After a record leaves the category, the same identifier yields the
        // category as it is now. Insights re-reads by identifier for exactly
        // this reason: a list kept by value would still claim the old record.
        let moved = try present(
            document(
                transactions: [
                    expense("e1", day: Day(year: 2026, month: 9, day: 1), cents: 4_000),
                    expense("e2", day: Day(year: 2026, month: 9, day: 2), cents: 2_500),
                    expense("e3", day: Day(year: 2026, month: 9, day: 2), cents: 1_200),
                ],
                budgets: [groceries()],
                monthlyCeilingCents: 5_000
            ),
            selection: ReviewPeriodSelection(scope: .month, offset: 0),
            live: fullLive(),
            categoryKeys: ["e1": "groceries"],
            labels: ReviewPresentationMapper.Labels(ledgerTransactionIDs: ["e1", "e2", "e3"])
        )
        let before = try #require(review.recordSet(id: "line:groceries"))
        let after = try #require(moved.recordSet(id: "line:groceries"))
        #expect(before.records.map(\.id).contains("e2"))
        #expect(!after.records.map(\.id).contains("e2"))
        #expect(after.total == Amount(minorUnits: 4_000, currencyCode: "EUR"))
    }

    @Test("A month list is offered only when the reviewed days cover that month")
    func monthListNeedsTheWholeMonth() throws {
        // The week of 31 August, reviewed through 2 September. August is
        // reviewed from the 31st only, so nothing proves the rest of August.
        let review = try present(
            document(
                transactions: [
                    expense("early", day: Day(year: 2026, month: 8, day: 21), cents: 900),
                    expense("e1", day: Day(year: 2026, month: 8, day: 31), cents: 2_000),
                    expense("e2", day: Day(year: 2026, month: 9, day: 1), cents: 3_000),
                ],
                budgets: [groceries()],
                monthlyCeilingCents: 70_000
            ),
            selection: ReviewPeriodSelection(scope: .week, offset: 0),
            live: fullLive(),
            categoryKeys: ["e1": "groceries", "e2": "groceries"],
            labels: ReviewPresentationMapper.Labels(ledgerTransactionIDs: ["early", "e1", "e2"])
        )
        #expect(review.coverage.quality == .complete)
        let august = try #require(review.monthContexts.first { $0.id == "2026-08" })
        #expect(august.records == nil)
        // September is reviewed from its first day through today.
        let september = try #require(review.monthContexts.first { $0.id == "2026-09" })
        #expect(september.records?.records.map(\.id) == ["e2"])
    }

    @Test("An incomplete period offers no record list at all")
    func incompletePeriodOffersNoRecords() throws {
        let review = try present(
            document(transactions: [
                expense("e1", day: Day(year: 2026, month: 9, day: 1), cents: 4_000),
            ]),
            selection: ReviewPeriodSelection(scope: .week, offset: 0),
            live: fullLive(through: Day(year: 2026, month: 9, day: 1)),
            labels: ReviewPresentationMapper.Labels(ledgerTransactionIDs: ["e1"])
        )
        #expect(review.spendingRecords == nil)
        #expect(review.topCategories.allSatisfy { $0.records == nil })
        #expect(review.monthContexts.allSatisfy { $0.records == nil })
    }

    @Test("A list that would not add up to its figure is withheld")
    func mismatchedListIsWithheld() {
        let day = Day(year: 2026, month: 9, day: 1)
        let euros = { (cents: Int64) in Money(minorUnits: cents, currency: .eur) }
        let rows = [(id: "a", day: day, amount: euros(1_000)), (id: "b", day: day, amount: euros(-200))]
        #expect(ReviewPresentationMapper.recordSet(
            id: "x", title: "X", scope: "", total: euros(800), rows: rows, owner: nil
        )?.records.count == 2)
        #expect(ReviewPresentationMapper.recordSet(
            id: "x", title: "X", scope: "", total: euros(900), rows: rows, owner: nil
        ) == nil)
        #expect(ReviewPresentationMapper.recordSet(
            id: "x", title: "X", scope: "", total: euros(0),
            rows: [(id: String, day: Day, amount: Money)](), owner: nil
        ) == nil)
        let mixed = [(id: "a", day: day, amount: Money(minorUnits: 800, currency: .usd))]
        #expect(ReviewPresentationMapper.recordSet(
            id: "x", title: "X", scope: "", total: euros(800), rows: mixed, owner: nil
        ) == nil)
    }

    @Test("Each finding leads to its exact records, its transaction, its owner, or nowhere")
    func findingDestinations() {
        let day = Day(year: 2026, month: 9, day: 1)
        let euros = { (cents: Int64) in Money(minorUnits: cents, currency: .eur) }
        func set(_ id: String, _ cents: Int64) -> ReviewRecordSet? {
            ReviewPresentationMapper.recordSet(
                id: id, title: id, scope: "", total: euros(cents),
                rows: [(id: "t-\(id)", day: day, amount: euros(cents))], owner: .budget
            )
        }
        var records = ReviewPresentationMapper.RecordSets()
        records.period = set("period", 7_700)
        records.lines["groceries"] = set("groceries", 6_500)
        records.months["2026-09"] = set("month", 7_700)
        let labels = ReviewPresentationMapper.Labels(ledgerTransactionIDs: ["big"])
        func route(_ kind: ReviewFindingKind, _ ids: [String], _ cents: Int64?) -> ReviewFindingDestination? {
            ReviewPresentationMapper.destination(
                kind: kind, ids: ids, quoted: cents.map(euros), labels: labels, records: records
            )
        }

        #expect(route(.spendingMateriallyHigherThanPrior, [], 7_700) == records.period.map(ReviewFindingDestination.records))
        #expect(route(.spendingMateriallyLowerThanPrior, [], 7_700) == records.period.map(ReviewFindingDestination.records))
        // A figure the list does not add up to gets no list.
        #expect(route(.spendingMateriallyHigherThanPrior, [], 7_600) == nil)
        #expect(route(.unusuallyHighCategory, ["groceries"], 6_500)
                == records.lines["groceries"].map(ReviewFindingDestination.records))
        #expect(route(.unusuallyHighCategory, ["unknown-line"], 6_500) == nil)
        #expect(route(.budgetOverrun, ["2026-09"], 7_700) == records.months["2026-09"].map(ReviewFindingDestination.records))
        #expect(route(.majorExceptionalPurchase, ["big"], 50_000) == .transaction("big"))
        #expect(route(.majorExceptionalPurchase, ["archive-row"], 50_000) == nil)
        #expect(route(.goalDeadlineApproaching, ["goal"], 1_000) == .owner(.goals))
        #expect(route(.upcomingLiquidityRisk, [], 2_000) == .owner(.fundingNeeded))
        #expect(route(.floorWarning, [], nil) == .owner(.safetyReserve))
        #expect(route(.supportBelowExpected, [], 30_000) == nil)
    }

    @Test("A coverage gap offers Banks & Sync only when syncing can close it")
    func coverageActionOnlyWhenActionable() throws {
        let complete = try linkedMonth()
        #expect(complete.coverage.action == nil)

        let missingDay = try present(
            document(),
            selection: ReviewPeriodSelection(scope: .week, offset: 0),
            live: fullLive(through: Day(year: 2026, month: 9, day: 1))
        )
        #expect(missingDay.coverage.action == .banksAndSync)

        let unknownAccount = try present(
            document(),
            selection: ReviewPeriodSelection(scope: .week, offset: 0),
            live: LiveCoverageResolution(intervals: [], unknownAccountIDs: ["bank"], knownAccountIDs: [])
        )
        #expect(unknownAccount.coverage.action == .banksAndSync)
    }

    // MARK: - Findings come only from the engine

    @Test("Every rendered card corresponds to an engine finding")
    func findingsMirrorEngine() throws {
        let doc = document(transactions: [
            expense("e1", day: Day(year: 2026, month: 9, day: 1), cents: 12_000),
        ])
        let selection = ReviewPeriodSelection(scope: .month, offset: 0)
        let live = fullLive()
        let result = try ReviewEngine.review(
            try request(doc, selection: selection, live: live)
        )
        let review = try present(doc, selection: selection, live: live)
        #expect(review.findings.count == result.findings.count)
        #expect(review.findings.map(\ReviewFindingCard.id) == result.findings.map(\ReviewFinding.id))
    }
}

/// Review latency on a realistic local dataset.
///
/// The review is recomputed whenever the screen reads it, so it has to be
/// cheap enough to stay off the rendering path's critical section without a
/// cache. This guards that; the bound is deliberately loose so it fails on a
/// regression in kind, not on a slow machine.
@Suite("Insights performance")
@MainActor
struct InsightsPerformanceTests {

    private func realisticStore() -> FinanceStore {
        // The shipped development fixture: accounts, obligations, budget,
        // goals and a month of transactions — the shape of the real store.
        FinanceStore.preview()
    }

    private func measure(_ selection: ReviewPeriodSelection) -> Double {
        let store = realisticStore()
        _ = store.review(selection)          // warm caches the first call fills
        let started = Date()
        for _ in 0..<10 { _ = store.review(selection) }
        return Date().timeIntervalSince(started) / 10
    }

    @Test("A week review computes well inside a frame budget")
    func weekLatency() throws {
        let seconds = measure(ReviewPeriodSelection(scope: .week, offset: 0))
        #expect(seconds < 0.5)
    }

    @Test("A month review computes well inside a frame budget")
    func monthLatency() throws {
        let seconds = measure(ReviewPeriodSelection(scope: .month, offset: 0))
        #expect(seconds < 0.5)
    }
}
