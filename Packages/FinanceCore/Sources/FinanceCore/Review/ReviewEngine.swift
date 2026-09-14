/// Pure period review. Same document + interval + as-of → same result.
///
/// Spending inclusion is `Economics` plus the monthly budget engine's refund
/// correction. This type does not invent a second classifier, does not read
/// `Date()`, and does not write `FinanceDocument`.
public enum ReviewEngine {

    /// - Throws: `ReviewError.dateArithmeticOutOfRange` when a date the
    ///   review requires cannot be expressed. Nothing here degrades: a review
    ///   that cannot compute its own period is not a review of an empty one.
    public static func review(_ request: ReviewRequest) throws -> ReviewResult {
        let currency = request.currency
        // The reviewed period's own length is required by coverage, by the
        // day walk behind it, and by the insufficiency threshold.
        guard request.interval.dayCount != nil else {
            throw ReviewError.dateArithmeticOutOfRange
        }
        let coverage = coverage(for: request)
        let facts = collectFacts(request)
        let totals = totals(facts: facts, currency: currency)
        let budget = budgetReview(request: request, facts: facts)
        let income = incomeReview(request: request, facts: facts)
        let expectations = expectationsReview(request: request, facts: facts)
        let goals = goalsReview(request)
        let risk = try riskReview(request)
        let comparison: ReviewComparison
        if request.comparePreviousPeriod {
            comparison = try comparePrevious(request: request, coverage: coverage, budget: budget, income: income)
        } else {
            comparison = .unavailable(.notRequested)
        }
        let findings = findings(
            request: request,
            coverage: coverage,
            facts: facts,
            budget: budget,
            income: income,
            goals: goals,
            risk: risk,
            comparison: comparison
        )
        return ReviewResult(
            kind: request.kind,
            interval: request.interval,
            asOf: request.asOf,
            currency: currency,
            coverage: coverage,
            totals: totals,
            budget: budget,
            income: income,
            expectations: expectations,
            goals: goals,
            risk: risk,
            comparison: comparison,
            findings: findings
        )
    }

    // MARK: - Coverage

    static func coverage(for request: ReviewRequest) -> ReviewCoverage {
        let interval = request.interval
        let input = request.coverage
        let cutoff = input.resolvedArchiveCutoff
        var reasons: [ReviewCoverageReason] = []
        var missing: [ReviewInterval] = []
        var usedArchive = false
        var usedLive = false

        if interval.isEmpty {
            return ReviewCoverage(
                status: .complete,
                reasons: [],
                missingIntervals: [],
                archiveCutoff: cutoff,
                usedArchive: false,
                usedLive: false
            )
        }

        let hasAnyEvidence = cutoff != nil
            || input.history != nil
            || !input.liveCoveredIntervals.isEmpty
            || !input.additionalSourceGaps.isEmpty

        if !hasAnyEvidence {
            return ReviewCoverage(
                status: .insufficient,
                reasons: [ReviewCoverageReason(kind: .coverageMetadataAbsent, interval: interval)],
                missingIntervals: [interval],
                archiveCutoff: nil,
                usedArchive: false,
                usedLive: false
            )
        }

        let archiveSlice: ReviewInterval?
        let liveSlice: ReviewInterval?
        if let cutoff {
            archiveSlice = interval.intersection(with: ReviewInterval(start: interval.start, end: cutoff))
            // No day follows the last representable day, so no live era
            // exists beyond it — an absent successor is a real answer here.
            liveSlice = cutoff.advanced(by: 1).flatMap { liveStart in
                liveStart <= interval.end
                    ? interval.intersection(with: ReviewInterval(start: liveStart, end: interval.end))
                    : nil
            }
        } else {
            archiveSlice = nil
            liveSlice = interval
        }

        if let archiveSlice, !archiveSlice.isEmpty {
            if let history = input.history {
                usedArchive = true
                let range = history.payload.dateRange
                if range.start > archiveSlice.start {
                    // A strictly smaller day exists, so `range.start` has a
                    // predecessor. Were it ever absent, the whole slice counts
                    // as missing: coverage is fail-closed and never narrows a
                    // hole because a date could not be computed.
                    let holeEnd = min(archiveSlice.end, range.start.advanced(by: -1) ?? archiveSlice.end)
                    let hole = ReviewInterval(start: archiveSlice.start, end: holeEnd)
                    if hole.start <= hole.end {
                        missing.append(hole)
                        reasons.append(ReviewCoverageReason(kind: .missingArchiveInterval, interval: hole))
                    }
                }
                if range.end < archiveSlice.end {
                    // Symmetrically: `range.end` has a successor because a
                    // strictly larger day exists, and an absent one widens the
                    // hole rather than narrowing it.
                    let holeStart = max(archiveSlice.start, range.end.advanced(by: 1) ?? archiveSlice.start)
                    let hole = ReviewInterval(start: holeStart, end: archiveSlice.end)
                    if hole.start <= hole.end {
                        missing.append(hole)
                        reasons.append(ReviewCoverageReason(kind: .missingArchiveInterval, interval: hole))
                    }
                }
                for gap in history.payload.sourceGaps.sorted(by: gapOrder) {
                    if let hole = monthSpan(gap.startMonth, gap.endMonth).intersection(with: archiveSlice) {
                        missing.append(hole)
                        reasons.append(
                            ReviewCoverageReason(
                                kind: .sourceGap,
                                interval: hole,
                                startMonth: gap.startMonth,
                                endMonth: gap.endMonth,
                                completeness: gap.completeness,
                                affectedSources: gap.affectedSources.sorted()
                            )
                        )
                    }
                }
            } else {
                missing.append(archiveSlice)
                reasons.append(ReviewCoverageReason(kind: .archiveHistoryAbsent, interval: archiveSlice))
                reasons.append(ReviewCoverageReason(kind: .missingArchiveInterval, interval: archiveSlice))
            }
        }

        if let liveSlice, !liveSlice.isEmpty {
            let liveCovered = mergeIntervals(input.liveCoveredIntervals)
            let uncoveredLive = subtract(liveSlice, minus: liveCovered)
            if uncoveredLive.isEmpty {
                usedLive = true
            } else {
                if uncoveredLive.count != 1 || uncoveredLive[0] != liveSlice {
                    usedLive = !liveCovered.isEmpty
                }
                missing.append(contentsOf: uncoveredLive)
                for hole in uncoveredLive {
                    reasons.append(ReviewCoverageReason(kind: .missingLiveInterval, interval: hole))
                }
            }
        }

        for gap in input.additionalSourceGaps.sorted(by: gapOrder) {
            if let hole = monthSpan(gap.startMonth, gap.endMonth).intersection(with: interval) {
                missing.append(hole)
                reasons.append(
                    ReviewCoverageReason(
                        kind: .sourceGap,
                        interval: hole,
                        startMonth: gap.startMonth,
                        endMonth: gap.endMonth,
                        completeness: gap.completeness,
                        affectedSources: gap.affectedSources.sorted()
                    )
                )
                if let cutoff, hole.start > cutoff {
                    reasons.append(ReviewCoverageReason(kind: .missingLiveInterval, interval: hole))
                } else if cutoff == nil {
                    reasons.append(ReviewCoverageReason(kind: .missingLiveInterval, interval: hole))
                } else {
                    reasons.append(ReviewCoverageReason(kind: .missingArchiveInterval, interval: hole))
                }
            }
        }

        missing = mergeIntervals(missing)
        reasons = uniqueReasons(reasons)

        let uncovered = uncoveredDayCount(interval: interval, missing: missing)
        let status: ReviewCoverageStatus
        if uncovered == 0 && reasons.isEmpty {
            status = .complete
        } else if uncovered == 0 {
            status = .partial
        } else if let total = interval.dayCount, uncovered >= total {
            status = .insufficient
        } else {
            status = .partial
        }

        return ReviewCoverage(
            status: status,
            reasons: reasons,
            missingIntervals: missing,
            archiveCutoff: cutoff,
            usedArchive: usedArchive,
            usedLive: usedLive
        )
    }

    // MARK: - Facts

    struct PeriodFacts {
        var live: [Transaction]
        var history: [FinanceHistoricalRecord]
        var attributions: [MonthlyBudgetEngine.Attribution]
        var netByID: [String: Money]
        var natureByID: [String: ReviewSpendingNature]
        var budgetByID: [String: String?]
        var dateByID: [String: Day]
        /// Each archive row classified once per PeriodFacts construction,
        /// keyed by `historicalID`.
        /// Totals, income and the unresolved-evidence finding all read this
        /// rather than reclassifying, so no two of them can disagree about what
        /// a record means.
        var historyByID: [String: HistoryClassification]
    }

    static func collectFacts(_ request: ReviewRequest) -> PeriodFacts {
        let currency = request.currency
        let interval = request.interval
        let cutoff = request.resolvedArchiveCutoff
        let ledger = ReconciliationLedger(request.document.planning.settlements)
        let transactionsByID = Dictionary(
            request.document.transactions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let live = request.document.transactions
            .filter { transaction in
                transaction.factivity == .observed
                    && interval.contains(transaction.date)
                    && (cutoff == nil || transaction.date > cutoff!)
            }
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }

        let history = (request.coverage.history?.payload.records ?? [])
            .filter { record in
                interval.contains(record.date)
                    && (cutoff == nil || record.date <= cutoff!)
            }
            .sorted { ($0.date, $0.historicalID) < ($1.date, $1.historicalID) }

        var facts = PeriodFacts(
            live: live,
            history: history,
            attributions: [],
            netByID: [:],
            natureByID: [:],
            budgetByID: [:],
            dateByID: [:],
            historyByID: [:]
        )

        let attributionByID = Dictionary(
            monthAttributions(request: request, live: live, ledger: ledger)
                .map { ($0.transactionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Output plumbing only: retain exactly the rows already consulted
        // below, without another attribution or refund computation.
        facts.attributions = attributionByID.values.sorted { $0.transactionID < $1.transactionID }

        for transaction in live {
            let effect = Economics.effect(of: transaction, currency: currency)
            let refund = refundOffsetsAnything(transaction, transactionsByID: transactionsByID)
                ? effect.refund.minorUnits : 0
            let net = effect.spending.minorUnits - refund
            facts.netByID[transaction.id] = Money(minorUnits: net, currency: currency)
            facts.dateByID[transaction.id] = transaction.date
            facts.budgetByID[transaction.id] = attributionByID[transaction.id]?.budgetID
            facts.natureByID[transaction.id] = spendingNature(
                id: transaction.id,
                transaction: transaction,
                attribution: attributionByID[transaction.id],
                request: request,
                ledger: ledger
            )
        }

        for record in history {
            let classified = classifyHistory(record, currency: currency)
            facts.historyByID[record.historicalID] = classified
            facts.netByID[record.historicalID] = classified.netSpending
            facts.dateByID[record.historicalID] = record.date
            facts.budgetByID[record.historicalID] = nil
            facts.natureByID[record.historicalID] = spendingNature(
                id: record.historicalID,
                transaction: nil,
                attribution: nil,
                request: request,
                ledger: ledger
            )
        }

        return facts
    }

    // MARK: - Totals

    /// Gross spending is the raw fold and stays exactly as it was. Net spending
    /// is **not** derived from a second raw refund fold: `collectFacts` already
    /// resolved every row's net amount — applying the refund-suppression rule a
    /// reversed original demands — and `ReviewBudget` and `MonthlyBudgetEngine`
    /// both answer from that resolution. Folding refunds again here made the
    /// totals disagree with the budget whenever suppression applied: a reversed
    /// purchase with a linked refund credit left the budget at zero while the
    /// totals reported a negative net. Net is therefore the authoritative sum,
    /// and refunds become what gross and net differ by.
    ///
    /// Net is never clamped. An unmatched refund, a refund for a prior period
    /// or refunds exceeding the period's spending legitimately make it negative.
    static func totals(facts: PeriodFacts, currency: Currency) -> ReviewTotals {
        let live = Economics.totals(for: facts.live, currency: currency)
        var spending = live.economicSpending.minorUnits
        var income = live.personalIncome.minorUnits
        var notMine = live.passThroughNotMine.minorUnits
        var repayments = live.financingRepayments.minorUnits
        var transfers = live.internalTransfers.minorUnits

        for record in facts.history {
            guard let classified = facts.historyByID[record.historicalID] else { continue }
            spending += classified.spending.minorUnits
            income += classified.personalIncome.minorUnits
            notMine += classified.passThroughNotMine.minorUnits
            repayments += classified.financing.minorUnits
            transfers += classified.internalMovement.minorUnits
        }

        let net = facts.netByID.values.reduce(Int64(0)) { $0 + $1.minorUnits }

        return ReviewTotals(
            currency: currency,
            economicSpending: Money(minorUnits: spending, currency: currency),
            refunds: Money(minorUnits: spending - net, currency: currency),
            netEconomicSpending: Money(minorUnits: net, currency: currency),
            personalIncome: Money(minorUnits: income, currency: currency),
            passThroughNotMine: Money(minorUnits: notMine, currency: currency),
            financingRepayments: Money(minorUnits: repayments, currency: currency),
            internalTransfers: Money(minorUnits: transfers, currency: currency)
        )
    }

    // MARK: - Budget

    static func budgetReview(request: ReviewRequest, facts: PeriodFacts) -> ReviewBudget {
        let currency = request.currency
        var ordinaryRecurring: Int64 = 0
        var ordinaryVariable: Int64 = 0
        var exceptional: Int64 = 0
        var unresolvedNature: Int64 = 0
        var periodNet: Int64 = 0
        var uncategorized: Int64 = 0

        for (id, net) in facts.netByID.sorted(by: { $0.key < $1.key }) {
            periodNet += net.minorUnits
            switch facts.natureByID[id] ?? .unresolved {
            case .ordinaryRecurring: ordinaryRecurring += net.minorUnits
            case .ordinaryVariable: ordinaryVariable += net.minorUnits
            case .exceptional: exceptional += net.minorUnits
            case .unresolved: unresolvedNature += net.minorUnits
            }
            if facts.live.contains(where: { $0.id == id }),
               (facts.budgetByID[id] ?? nil) == nil,
               net.minorUnits != 0 {
                uncategorized += net.minorUnits
            }
        }

        let contexts = request.interval.monthKeys.map { month in
            monthlyContext(month: month, request: request, facts: facts)
        }

        let drivers = facts.netByID
            .compactMap { id, amount -> ReviewSpendingDriver? in
                guard amount.minorUnits > 0, let date = facts.dateByID[id] else { return nil }
                return ReviewSpendingDriver(
                    id: id,
                    date: date,
                    amount: amount,
                    nature: facts.natureByID[id] ?? .unresolved,
                    budgetID: facts.budgetByID[id] ?? nil
                )
            }
            .sorted { lhs, rhs in
                if lhs.amount.minorUnits != rhs.amount.minorUnits {
                    return lhs.amount.minorUnits > rhs.amount.minorUnits
                }
                return lhs.id < rhs.id
            }

        return ReviewBudget(
            periodEconomicSpending: Money(minorUnits: periodNet, currency: currency),
            attributions: facts.attributions,
            monthlyContexts: contexts,
            uncategorized: Money(minorUnits: uncategorized, currency: currency),
            financingRepayments: totals(facts: facts, currency: currency).financingRepayments,
            drivers: drivers,
            ordinaryRecurring: Money(minorUnits: ordinaryRecurring, currency: currency),
            ordinaryVariable: Money(minorUnits: ordinaryVariable, currency: currency),
            exceptional: Money(minorUnits: exceptional, currency: currency),
            unresolvedNature: Money(minorUnits: unresolvedNature, currency: currency)
        )
    }

    static func monthlyContext(
        month: MonthKey,
        request: ReviewRequest,
        facts: PeriodFacts
    ) -> ReviewMonthlyBudgetContext {
        let currency = request.currency
        let monthInterval = ReviewInterval.month(month)
        let slice = request.interval.intersection(with: monthInterval)
            ?? ReviewInterval(start: monthInterval.start, end: monthInterval.start)
        let monthReport = MonthlyBudgetEngine.report(
            month: month,
            today: request.asOf,
            document: request.document,
            categoryKeys: request.categoryKeys,
            currency: currency
        )

        var monthRequest = request
        monthRequest.interval = monthInterval
        let monthFacts = collectFacts(monthRequest)
        let monthNet = monthFacts.netByID.values.reduce(Int64(0)) { $0 + $1.minorUnits }
        let periodNet = facts.netByID.reduce(Int64(0)) { partial, item in
            guard let date = facts.dateByID[item.key], slice.contains(date) else { return partial }
            return partial + item.value.minorUnits
        }

        var spentByLine: [String: Int64] = [:]
        var uncategorized: Int64 = 0
        let liveIDs = Set(facts.live.map(\.id))
        for (id, net) in facts.netByID {
            guard let date = facts.dateByID[id], slice.contains(date) else { continue }
            if liveIDs.contains(id) {
                if let budgetID = facts.budgetByID[id] ?? nil {
                    spentByLine[budgetID, default: 0] += net.minorUnits
                } else if net.minorUnits != 0 {
                    uncategorized += net.minorUnits
                }
            }
        }

        let lines = monthReport.lines
            .sorted { $0.id < $1.id }
            .map { line in
                let periodSpent = spentByLine[line.id] ?? 0
                return ReviewBudgetLine(
                    id: line.id,
                    name: line.name,
                    spendingClass: line.spendingClass,
                    target: line.target,
                    periodSpent: Money(minorUnits: periodSpent, currency: currency),
                    isOverspent: periodSpent > line.target.minorUnits
                )
            }

        let ceiling = monthReport.ceiling
        let remaining = ceiling.map {
            Money(minorUnits: $0.minorUnits - monthNet, currency: currency)
        }
        let overage = ceiling.map { cap -> Money in
            let extra = monthNet - cap.minorUnits
            return Money(minorUnits: extra > 0 ? extra : 0, currency: currency)
        }

        return ReviewMonthlyBudgetContext(
            month: month,
            intervalInMonth: slice,
            ceiling: ceiling,
            monthSpending: Money(minorUnits: monthNet, currency: currency),
            periodSpendingInMonth: Money(minorUnits: periodNet, currency: currency),
            committed: monthReport.committed,
            remaining: remaining,
            overage: overage,
            uncategorized: Money(minorUnits: uncategorized, currency: currency),
            lines: lines
        )
    }

    // MARK: - Income

    static func incomeReview(request: ReviewRequest, facts: PeriodFacts) -> ReviewIncome {
        let currency = request.currency
        var personal: Int64 = 0
        var supportGross: Int64 = 0
        var supportOwned: Int64 = 0
        var earned: Int64 = 0
        var reimbursements: Int64 = 0
        var passGross: Int64 = 0
        var passOwned: Int64 = 0
        var notMine: Int64 = 0
        var internalMovement: Int64 = 0
        var unresolved: Int64 = 0

        for transaction in facts.live {
            let effect = Economics.effect(of: transaction, currency: currency)
            personal += effect.income.minorUnits
            notMine += effect.passThroughNotMine.minorUnits
            if transaction.kind == .passThrough {
                passGross += effect.accountMovementIn.minorUnits
                passOwned += effect.income.minorUnits
            }
            let classified = incomeClass(of: transaction, request: request)
            switch classified {
            case .parentalSupport:
                supportGross += effect.accountMovementIn.minorUnits
                supportOwned += effect.income.minorUnits
            case .earnedOrOther:
                earned += effect.income.minorUnits
            case .reimbursement:
                reimbursements += effect.income.minorUnits
            case .passThrough:
                break
            case .internalMovement:
                internalMovement += effect.accountMovementOut.minorUnits
            case .unresolved:
                unresolved += effect.income.minorUnits
            }
        }

        for record in facts.history {
            guard let classified = facts.historyByID[record.historicalID] else { continue }
            personal += classified.personalIncome.minorUnits
            notMine += classified.passThroughNotMine.minorUnits
            internalMovement += classified.internalMovement.minorUnits
            let incomeClass = historyIncomeClass(record, request: request)
            if incomeClass == .passThrough
                || record.flags.passThrough != .none {
                passGross += classified.grossIn.minorUnits
                passOwned += classified.personalIncome.minorUnits
            }
            switch incomeClass {
            case .parentalSupport:
                supportGross += classified.grossIn.minorUnits
                supportOwned += classified.personalIncome.minorUnits
            case .earnedOrOther:
                earned += classified.personalIncome.minorUnits
            case .reimbursement:
                reimbursements += classified.personalIncome.minorUnits
            case .passThrough, .internalMovement:
                break
            case .unresolved:
                unresolved += classified.personalIncome.minorUnits
            }
        }

        return ReviewIncome(
            personalIncome: Money(minorUnits: personal, currency: currency),
            parentalSupportGross: Money(minorUnits: supportGross, currency: currency),
            parentalSupportOwned: Money(minorUnits: supportOwned, currency: currency),
            earnedOrOther: Money(minorUnits: earned, currency: currency),
            reimbursements: Money(minorUnits: reimbursements, currency: currency),
            passThroughGross: Money(minorUnits: passGross, currency: currency),
            passThroughOwned: Money(minorUnits: passOwned, currency: currency),
            passThroughNotMine: Money(minorUnits: notMine, currency: currency),
            internalMovement: Money(minorUnits: internalMovement, currency: currency),
            unresolved: Money(minorUnits: unresolved, currency: currency)
        )
    }

    // MARK: - Expected vs actual

    static func expectationsReview(request: ReviewRequest, facts: PeriodFacts) -> ReviewExpectations {
        let document = request.document
        let ledger = ReconciliationLedger(document.planning.settlements)
        let observedByID = Dictionary(
            document.transactions.filter { $0.factivity == .observed }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var items: [ReviewExpectation] = []

        let occurrences = OccurrenceExpander.occurrences(
            in: document,
            from: request.interval.start,
            to: request.interval.end,
            asOf: request.asOf,
            ledger: ledger
        )
        for occurrence in occurrences {
            let status: ReviewExpectationStatus
            var actualID: String?
            var actualAmount: Money?
            switch occurrence.status {
            case let .paid(id):
                status = .matched
                actualID = id
                if let actual = observedByID[id] {
                    actualAmount = Economics.effect(of: actual, currency: occurrence.amount.currency).spending
                }
            case .skipped:
                status = .skipped
            case .noLongerDue:
                status = .noLongerDue
            case .overdue:
                status = .missed
            case .due:
                status = .expected
            }
            items.append(
                ReviewExpectation(
                    id: occurrence.id.description,
                    name: occurrence.name,
                    expectedDay: occurrence.expectedDay,
                    expectedAmount: occurrence.amount,
                    actualAmount: actualAmount,
                    actualTransactionID: actualID,
                    status: status
                )
            )
        }

        let expectedInInterval = document.expectedTransactions
            .filter { request.interval.contains($0.date) && $0.lifecycle != .reversed }
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        for expected in expectedInInterval {
            let match = document.transactions.first { actual in
                actual.factivity == .observed
                    && actual.lifecycle != .reversed
                    && actual.linkedTransactionID == expected.id
            }
            let status: ReviewExpectationStatus
            if match != nil {
                status = .matched
            } else if expected.date < request.asOf {
                status = .missed
            } else {
                status = .expected
            }
            let expectedAmount: Money
            switch expected.kind {
            case .income, .passThrough:
                expectedAmount = Economics.effect(of: expected, currency: request.currency).income
            default:
                expectedAmount = Economics.effect(of: expected, currency: request.currency).spending
            }
            items.append(
                ReviewExpectation(
                    id: expected.id,
                    name: expected.note ?? expected.id,
                    expectedDay: expected.date,
                    expectedAmount: expectedAmount,
                    actualAmount: match.map {
                        Economics.effect(of: $0, currency: request.currency).income
                    },
                    actualTransactionID: match?.id,
                    status: status
                )
            )
        }

        for source in document.incomeSources.sorted(by: { $0.id < $1.id })
        where !source.amount.isZero && source.amount.currency == request.currency {
            for day in source.schedule.occurrences(from: request.interval.start, to: request.interval.end) {
                let actual = facts.live.first { $0.incomeSourceID == source.id }
                    ?? document.transactions.first {
                        $0.factivity == .observed
                            && $0.lifecycle != .reversed
                            && $0.incomeSourceID == source.id
                            && request.interval.contains($0.date)
                    }
                let status: ReviewExpectationStatus
                if actual != nil {
                    status = .matched
                } else if day < request.asOf {
                    status = .missed
                } else {
                    status = .expected
                }
                items.append(
                    ReviewExpectation(
                        id: "\(source.id)@\(day.isoString)",
                        name: source.name,
                        expectedDay: day,
                        expectedAmount: source.amount,
                        actualAmount: actual.map {
                            Economics.effect(of: $0, currency: request.currency).income
                        },
                        actualTransactionID: actual?.id,
                        status: status
                    )
                )
            }
        }

        items.sort { ($0.expectedDay, $0.id) < ($1.expectedDay, $1.id) }
        return ReviewExpectations(items: items)
    }

    // MARK: - Goals

    static func goalsReview(_ request: ReviewRequest) -> ReviewGoals {
        let currency = request.currency
        let positions = ReservationOverlay.positions(
            purchases: request.document.planning.plannedPurchases,
            funds: request.document.planning.sinkingFunds
        )
        let setAside = positions
            .filter { $0.amount.currency == currency }
            .reduce(Int64(0)) { $0 + $1.amount.minorUnits }

        let items = request.document.planning.plannedPurchases
            .sorted { $0.id < $1.id }
            .map { purchase in
                ReviewGoalItem(
                    id: purchase.id,
                    name: purchase.name,
                    targetAmount: purchase.targetAmount,
                    targetDate: purchase.targetDate,
                    status: purchase.status,
                    reservedAmount: purchase.ownReservation
                )
            }
        let active = items.filter { $0.status == .planned || $0.status == .reserved }
        let upcoming = active
            .filter { item in
                guard let date = item.targetDate else { return false }
                return date >= request.asOf
            }
            .sorted { lhs, rhs in
                (lhs.targetDate!, lhs.id) < (rhs.targetDate!, rhs.id)
            }

        return ReviewGoals(
            currentlySetAside: Money(minorUnits: setAside, currency: currency),
            reservationHistoryKnown: false,
            reservationChange: nil,
            activePurchases: active,
            upcomingTargetDates: upcoming
        )
    }

    // MARK: - Risk

    static func riskReview(_ request: ReviewRequest) throws -> ReviewRisk {
        let currency = request.currency
        // The outlook horizon is a required input, not a best effort: a review
        // that quietly shortened it would report a different period's risk.
        guard let outlookEnd = request.resolvedForecastEnd else {
            throw ReviewError.dateArithmeticOutOfRange
        }
        // Refuse an unanswerable outlook before occurrence expansion or
        // forecast composition can allocate work proportional to its span.
        do {
            try ForecastEngine.validateHorizon(start: request.asOf, end: outlookEnd)
        } catch {
            throw ReviewError.dateArithmeticOutOfRange
        }
        let requirement = PaymentRequirement(
            currency: currency,
            acceptableRails: PaymentRail.euroBankRails
        )
        // Effective holdings, not stored anchors. `document.balances` is an
        // inclusive-through-day carried-forward anchor, so summing it states
        // cash as of the anchor day rather than as of `asOf` — and the
        // forecast three lines below already goes through the same overlay via
        // `ForecastComposer`. Reading anchors here made one result mix two
        // liquidity models.
        let liquidity = spendablePool(
            balances: CurrentHoldings.overlayBalances(
                in: request.document, asOf: request.asOf
            ),
            accounts: request.document.accounts,
            requirement: requirement
        )
        let upcoming = OccurrenceExpander.unresolved(
            in: request.document,
            from: request.asOf,
            to: outlookEnd,
            asOf: request.asOf
        )
        // A forecast that cannot run for an ordinary reason has always left
        // the risk fields unavailable. Date arithmetic that cannot be
        // expressed is different in kind: swallowing it here would publish a
        // zero bridge and no risk dates as though the run had succeeded.
        let forecast: ForecastResult?
        do {
            forecast = try ForecastEngine.run(
                ForecastComposer.makeRequest(
                    from: request.document,
                    startDate: request.asOf,
                    endDate: outlookEnd
                )
            )
        } catch ForecastError.dateArithmeticOutOfRange {
            throw ReviewError.dateArithmeticOutOfRange
        } catch {
            forecast = nil
        }
        return ReviewRisk(
            asOf: request.asOf,
            asOfLedgerLiquidity: liquidity,
            outlookEnd: outlookEnd,
            upcomingObligations: upcoming,
            firstHardCashRiskDate: forecast?.firstNegativeDate,
            firstFloorWarningDate: forecast?.firstBelowSafetyFloorDate,
            firstRisk: forecast?.firstRisk,
            minimumBridgeRequired: forecast?.minimumBridgeRequired
                ?? Money(minorUnits: 0, currency: currency)
        )
    }

    // MARK: - Comparison

    static func comparePrevious(
        request: ReviewRequest,
        coverage: ReviewCoverage,
        budget: ReviewBudget,
        income: ReviewIncome
    ) throws -> ReviewComparison {
        if !coverage.isComplete {
            return .unavailable(.currentCoverageIncomplete)
        }
        // A comparison was asked for. A prior period that cannot be
        // constructed is a failed calculation, not a period that compares
        // equal, so it is reported rather than refused with a coverage reason.
        guard let priorInterval = request.interval.previous(kind: request.kind) else {
            throw ReviewError.dateArithmeticOutOfRange
        }
        var priorRequest = request
        priorRequest.interval = priorInterval
        priorRequest.comparePreviousPeriod = false
        let priorCoverage = Self.coverage(for: priorRequest)
        if !priorCoverage.isComplete {
            return .unavailable(.priorCoverageIncomplete)
        }
        let prior = try review(priorRequest)
        let spending = ReviewDelta(
            current: budget.periodEconomicSpending,
            prior: prior.budget.periodEconomicSpending
        )
        let utilization: ReviewDelta?
        if budget.monthlyContexts.count == 1,
           prior.budget.monthlyContexts.count == 1,
           let currentCeiling = budget.monthlyContexts[0].ceiling,
           let priorCeiling = prior.budget.monthlyContexts[0].ceiling,
           currentCeiling.minorUnits != 0, priorCeiling.minorUnits != 0 {
            utilization = ReviewDelta(
                current: budget.monthlyContexts[0].monthSpending,
                prior: prior.budget.monthlyContexts[0].monthSpending
            )
        } else {
            utilization = nil
        }
        let currentLines = spentByLine(budget, currency: request.currency)
        let priorLines = spentByLine(prior.budget, currency: request.currency)
        let lineIDs = Set(currentLines.keys).union(priorLines.keys).sorted()
        let categoryDeltas: [ReviewCategoryDelta] = lineIDs.map { id in
            let current = currentLines[id] ?? Money(minorUnits: 0, currency: request.currency)
            let previous = priorLines[id] ?? Money(minorUnits: 0, currency: request.currency)
            return ReviewCategoryDelta(id: id, delta: ReviewDelta(current: current, prior: previous))
        }
        let changed = categoryDeltas
            .filter { $0.delta.absolute.minorUnits != 0 }
            .sorted { lhs, rhs in
                let l = abs(lhs.delta.absolute.minorUnits)
                let r = abs(rhs.delta.absolute.minorUnits)
                if l != r { return l > r }
                return lhs.id < rhs.id
            }
        return .available(
            ReviewPeriodComparison(
                priorInterval: priorInterval,
                spending: spending,
                budgetUtilization: utilization,
                income: ReviewDelta(current: income.personalIncome, prior: prior.income.personalIncome),
                supportOwned: ReviewDelta(
                    current: income.parentalSupportOwned,
                    prior: prior.income.parentalSupportOwned
                ),
                categoryDeltas: categoryDeltas,
                largestChangedDrivers: Array(changed.prefix(5))
            )
        )
    }

    // MARK: - Findings

    static func findings(
        request: ReviewRequest,
        coverage: ReviewCoverage,
        facts: PeriodFacts,
        budget: ReviewBudget,
        income: ReviewIncome,
        goals: ReviewGoals,
        risk: ReviewRisk,
        comparison: ReviewComparison
    ) -> [ReviewFinding] {
        var result: [ReviewFinding] = []
        let policy = request.findingPolicy

        if !coverage.isComplete {
            result.append(
                finding(
                    .unresolvedEvidenceAffectingAccuracy,
                    severity: coverage.status == .insufficient ? .important : .warning,
                    amounts: [],
                    dates: coverage.missingIntervals.flatMap { [$0.start, $0.end] },
                    ids: coverage.reasons.map(\.kind.rawValue)
                )
            )
        }

        let unresolvedIDs = unresolvedEvidenceIDs(request: request, facts: facts)
        if !unresolvedIDs.isEmpty {
            result.append(
                finding(
                    .unresolvedEvidenceAffectingAccuracy,
                    severity: .warning,
                    amounts: [],
                    dates: [],
                    ids: unresolvedIDs
                )
            )
        }

        if coverage.isComplete {
            for context in budget.monthlyContexts {
                if let overage = context.overage, overage.minorUnits > 0,
                   let ceiling = context.ceiling {
                    result.append(
                        finding(
                            .budgetOverrun,
                            severity: .important,
                            amounts: [context.monthSpending, ceiling, overage],
                            dates: [context.intervalInMonth.end],
                            ids: [context.month.isoString]
                        )
                    )
                }
            }
        }

        for driver in budget.drivers
        where driver.nature == .exceptional
            && driver.amount.minorUnits >= policy.majorExceptionalMinorUnits {
            result.append(
                finding(
                    .majorExceptionalPurchase,
                    severity: .info,
                    amounts: [driver.amount],
                    dates: [driver.date],
                    ids: [driver.id]
                )
            )
        }

        if coverage.isComplete {
            let expectedSupport = request.document.expectedTransactions
                .filter {
                    request.interval.contains($0.date)
                        && $0.lifecycle != .reversed
                        && incomeClass(of: $0, request: request) == .parentalSupport
                }
                .reduce(Int64(0)) {
                    $0 + Economics.effect(of: $1, currency: request.currency).income.minorUnits
                }
            if expectedSupport > income.parentalSupportOwned.minorUnits && expectedSupport > 0 {
                result.append(
                    finding(
                        .supportBelowExpected,
                        severity: .warning,
                        amounts: [
                            Money(minorUnits: expectedSupport, currency: request.currency),
                            income.parentalSupportOwned,
                        ],
                        dates: [],
                        ids: []
                    )
                )
            }
        }

        if let hard = risk.firstHardCashRiskDate {
            // Amount and date come from one computation or the amount is
            // omitted. `minimumBridgeRequired` is the up-front bridge for the
            // whole horizon, so pairing it with this day states a number that
            // was never true on it — the very thing `FirstRisk.shortfall`
            // exists to prevent. It stays available on `ReviewRisk`.
            let coherent = risk.firstRisk.flatMap { $0.day == hard ? $0 : nil }
            result.append(
                finding(
                    .upcomingLiquidityRisk,
                    severity: .important,
                    amounts: [coherent?.shortfall].compactMap { $0 },
                    dates: [hard],
                    ids: [coherent?.triggerEventID].compactMap { $0 }
                )
            )
        }

        if let floor = risk.firstFloorWarningDate {
            result.append(
                finding(
                    .floorWarning,
                    severity: .warning,
                    amounts: [],
                    dates: [floor],
                    ids: risk.firstHardCashRiskDate == nil
                        ? [risk.firstRisk?.triggerEventID].compactMap { $0 }
                        : []
                )
            )
        }

        if case let .available(comparison) = comparison {
            if isMaterialSpendingIncrease(comparison.spending, policy: policy) {
                result.append(
                    finding(
                        .spendingMateriallyHigherThanPrior,
                        severity: .info,
                        amounts: [comparison.spending.current, comparison.spending.prior, comparison.spending.absolute],
                        dates: [comparison.priorInterval.start, comparison.priorInterval.end],
                        ids: []
                    )
                )
            } else if isMaterialSpendingDecrease(comparison.spending, policy: policy) {
                result.append(
                    finding(
                        .spendingMateriallyLowerThanPrior,
                        severity: .info,
                        amounts: [comparison.spending.current, comparison.spending.prior, comparison.spending.absolute],
                        dates: [comparison.priorInterval.start, comparison.priorInterval.end],
                        ids: []
                    )
                )
            }
            for category in comparison.categoryDeltas
            where isUnusuallyHighCategory(category.delta, policy: policy) {
                result.append(
                    finding(
                        .unusuallyHighCategory,
                        severity: .info,
                        amounts: [category.delta.current, category.delta.prior],
                        dates: [],
                        ids: [category.id]
                    )
                )
            }
        }

        for item in goals.activePurchases {
            guard let date = item.targetDate,
                  date >= request.asOf,
                  request.asOf.isWithin(days: 14, of: date) || request.interval.contains(date)
            else { continue }
            result.append(
                finding(
                    .goalDeadlineApproaching,
                    severity: .info,
                    amounts: [item.targetAmount],
                    dates: [date],
                    ids: [item.id]
                )
            )
        }

        return result.sorted(by: findingOrder)
    }

    static func isMaterialSpendingIncrease(_ delta: ReviewDelta, policy: ReviewFindingPolicy) -> Bool {
        delta.absolute.minorUnits > 0 && isMaterialSpending(delta, policy: policy)
    }

    static func isMaterialSpendingDecrease(_ delta: ReviewDelta, policy: ReviewFindingPolicy) -> Bool {
        delta.absolute.minorUnits < 0 && isMaterialSpending(delta, policy: policy)
    }

    static func isMaterialSpending(_ delta: ReviewDelta, policy: ReviewFindingPolicy) -> Bool {
        let absolute = abs(delta.absolute.minorUnits)
        guard absolute >= policy.materialSpendingAbsoluteMinorUnits else { return false }
        if delta.prior.minorUnits == 0 { return true }
        guard let basisPoints = delta.basisPoints else { return false }
        return abs(basisPoints) >= policy.materialSpendingBasisPoints
    }

    static func isUnusuallyHighCategory(_ delta: ReviewDelta, policy: ReviewFindingPolicy) -> Bool {
        guard delta.prior.minorUnits > 0 else { return false }
        guard delta.prior.minorUnits >= policy.unusualCategoryMinimumPriorMinorUnits else { return false }
        let multiple = Int64(max(policy.unusualCategoryMultiple, 1))
        guard delta.current.minorUnits >= delta.prior.minorUnits * multiple else { return false }
        return (delta.current.minorUnits - delta.prior.minorUnits) >= policy.unusualCategoryAbsoluteMinorUnits
    }

    // MARK: - Attribution / nature / income class

    static func monthAttributions(
        request: ReviewRequest,
        live: [Transaction],
        ledger: ReconciliationLedger
    ) -> [MonthlyBudgetEngine.Attribution] {
        let liveIDs = Set(live.map(\.id))
        var result: [MonthlyBudgetEngine.Attribution] = []
        for month in request.interval.monthKeys {
            let lines = request.document.planning.budgets.filter { $0.amount(for: month) != nil }
            let all = MonthlyBudgetEngine.attributions(
                month: month,
                document: request.document,
                lines: lines,
                ledger: ledger,
                categoryKeys: request.categoryKeys,
                currency: request.currency
            )
            result.append(contentsOf: all.filter { liveIDs.contains($0.transactionID) })
        }
        return result
    }

    static func spendingNature(
        id: String,
        transaction: Transaction?,
        attribution: MonthlyBudgetEngine.Attribution?,
        request: ReviewRequest,
        ledger: ReconciliationLedger
    ) -> ReviewSpendingNature {
        if let explicit = request.spendingNatures[id] {
            return explicit
        }
        if let transaction, ledger.settlement(forActual: transaction.id) != nil {
            return .ordinaryRecurring
        }
        if let attribution, attribution.budgetID != nil {
            return .ordinaryVariable
        }
        return .unresolved
    }

    static func incomeClass(of transaction: Transaction, request: ReviewRequest) -> ReviewIncomeClass {
        switch transaction.kind {
        case .transfer, .cashWithdrawal, .currencyConversion:
            return .internalMovement
        case .expense, .refund, .financingRepayment:
            return .unresolved
        case .passThrough, .income:
            break
        }
        if let explicit = request.incomeClasses[transaction.id] {
            return explicit
        }
        if let sourceID = transaction.incomeSourceID,
           let explicit = request.incomeClasses[sourceID] {
            return explicit
        }
        if let sourceID = transaction.incomeSourceID,
           let token = request.economicSources[sourceID],
           let mapped = ReviewEconomicSourceClass.incomeClass(for: token) {
            return mapped
        }
        if let token = request.economicSources[transaction.id],
           let mapped = ReviewEconomicSourceClass.incomeClass(for: token) {
            return mapped
        }
        if transaction.kind == .passThrough {
            return .passThrough
        }
        return .unresolved
    }

    static func historyIncomeClass(
        _ record: FinanceHistoricalRecord,
        request: ReviewRequest
    ) -> ReviewIncomeClass {
        if let explicit = request.incomeClasses[record.historicalID] {
            return explicit
        }
        if let token = request.economicSources[record.historicalID],
           let mapped = ReviewEconomicSourceClass.incomeClass(for: token) {
            return mapped
        }
        if let token = record.economicSource,
           let mapped = ReviewEconomicSourceClass.incomeClass(for: token) {
            return mapped
        }
        if record.flags.internalTransfer { return .internalMovement }
        switch record.flags.passThrough {
        case .full, .partial:
            return .passThrough
        case .none:
            break
        }
        let type = record.economicType
        if ["INTERNAL_TRANSFER", "TRANSFER", "TOPUP", "CASH_WITHDRAWAL", "CURRENCY_CONVERSION"].contains(type) {
            return .internalMovement
        }
        if type == "REFUND" { return .unresolved }
        if let mapped = ReviewEconomicSourceClass.incomeClass(for: type) {
            return mapped
        }
        if (record.personalAmountEURCents ?? 0) > 0 {
            return .unresolved
        }
        return .unresolved
    }

    struct HistoryClassification {
        var spending: Money
        var refund: Money
        var netSpending: Money
        var personalIncome: Money
        var passThroughNotMine: Money
        var financing: Money
        var internalMovement: Money
        var grossIn: Money
        /// A role this record plays needs a euro amount the archive never
        /// stated, so that role contributed nothing to the totals. The row is
        /// then declared through `unresolvedEvidenceAffectingAccuracy`: a
        /// silent zero would read as "no money here" rather than "unknown".
        var hasUnvaluedEURRole: Bool = false
        /// No supported type, source or flag established this record's
        /// economic role. Amounts may be stated, but cannot supply meaning.
        var hasUnresolvedSemanticRole: Bool = false
    }

    /// The archive's own minor units may stand in for euro cents only when the
    /// original *is* euro at the euro scale.
    ///
    /// A EUR/0 or EUR/3 original states a different scale, so its minor units
    /// are not cents — reading them as cents is the same class of defect that
    /// FinanceHistory 2.0.0 was cut to end. Nothing is rescaled here either:
    /// an archive that wanted to state a euro figure has
    /// `bookedAmountEURCents` for exactly that, and an original this method
    /// refuses is simply unvalued. No FX, no rounding.
    static func originalAsEURCents(_ amount: FinanceHistoryOriginalAmount) -> Int64? {
        guard amount.currency == "EUR", amount.currencyExponent == 2 else { return nil }
        return amount.cents
    }

    static func classifyHistory(
        _ record: FinanceHistoricalRecord,
        currency: Currency
    ) -> HistoryClassification {
        let zero = Money(minorUnits: 0, currency: currency)
        func eur(_ cents: Int64?) -> Money {
            Money(minorUnits: cents ?? 0, currency: currency)
        }
        var result = HistoryClassification(
            spending: zero, refund: zero, netSpending: zero,
            personalIncome: zero, passThroughNotMine: zero,
            financing: zero, internalMovement: zero, grossIn: zero
        )
        guard currency == .eur else { return result }

        // Authority is per role, not a precedence list. A *booked* role may
        // fall back to the original only when that original is already EUR/2;
        // an *economic* or *owned* role may not fall back at all, because
        // booked euros are not economic meaning and gross is not the part that
        // is mine. Promoting one into another is how a foreign row silently
        // acquired a euro value.
        let bookedEUR = record.bookedAmountEURCents ?? originalAsEURCents(record.originalAmount)

        if record.flags.internalTransfer {
            guard let amount = bookedEUR else {
                result.hasUnvaluedEURRole = true
                return result
            }
            result.internalMovement = eur(abs(amount))
            return result
        }
        if record.flags.financingLeg {
            guard let amount = record.economicAmountEURCents else {
                result.hasUnvaluedEURRole = true
                return result
            }
            result.financing = eur(abs(amount))
            return result
        }
        switch record.flags.passThrough {
        case .full, .partial:
            // Gross and owned are independent authorities. An unavailable
            // role contributes zero and marks the row, without erasing a
            // known value in the other role. Explicit personal zero is known.
            if bookedEUR == nil { result.hasUnvaluedEURRole = true }
            let gross = max(bookedEUR ?? 0, 0)
            if record.personalAmountEURCents == nil { result.hasUnvaluedEURRole = true }
            let owned = max(record.personalAmountEURCents ?? 0, 0)
            result.grossIn = eur(gross)
            result.personalIncome = eur(owned)
            result.passThroughNotMine = eur(max(0, gross - owned))
            return result
        case .none:
            break
        }

        let type = record.economicType.uppercased()
        if ["INTERNAL_TRANSFER", "TRANSFER", "TOPUP", "CASH_WITHDRAWAL", "CURRENCY_CONVERSION"].contains(type) {
            guard let amount = record.economicAmountEURCents else {
                result.hasUnvaluedEURRole = true
                return result
            }
            result.internalMovement = eur(abs(amount))
            return result
        }
        if ["FINANCING_REPAYMENT", "FINANCING"].contains(type) {
            guard let amount = record.economicAmountEURCents else {
                result.hasUnvaluedEURRole = true
                return result
            }
            result.financing = eur(abs(amount))
            return result
        }
        if type == "REFUND" {
            guard let economic = record.economicAmountEURCents else {
                result.hasUnvaluedEURRole = true
                return result
            }
            let amount = abs(economic)
            result.refund = eur(amount)
            result.netSpending = Money(minorUnits: -amount, currency: currency)
            return result
        }
        if let mapped = ReviewEconomicSourceClass.incomeClass(for: record.economicType)
            ?? record.economicSource.flatMap(ReviewEconomicSourceClass.incomeClass(for:)) {
            switch mapped {
            case .parentalSupport, .earnedOrOther, .reimbursement, .unresolved, .passThrough:
                // Economic EUR does not state ownership. Missing personal
                // authority leaves gross intact and declares the owned role.
                if let personal = record.personalAmountEURCents {
                    result.personalIncome = eur(personal)
                } else {
                    result.hasUnvaluedEURRole = true
                }
                if let grossEUR = bookedEUR {
                    result.grossIn = eur(max(grossEUR, 0))
                } else {
                    result.hasUnvaluedEURRole = true
                }
                return result
            case .internalMovement:
                guard let amount = record.economicAmountEURCents else {
                    result.hasUnvaluedEURRole = true
                    return result
                }
                result.internalMovement = eur(abs(amount))
                return result
            }
        }
        // Direction and valuation do not establish economic purpose.
        if type == "SPENDING" || type == "EXPENSE" {
            guard let economic = record.economicAmountEURCents else {
                result.hasUnvaluedEURRole = true
                return result
            }
            let amount = abs(economic)
            result.spending = eur(amount)
            result.netSpending = eur(amount)
            return result
        }
        if type == "INCOME" {
            // Plain income still requires personal authority even when no
            // economic source was mapped. Zero is stated; nil is unavailable.
            if let personal = record.personalAmountEURCents {
                result.personalIncome = eur(personal)
            } else {
                result.hasUnvaluedEURRole = true
            }
            if let grossEUR = bookedEUR {
                result.grossIn = eur(max(grossEUR, 0))
            } else {
                result.hasUnvaluedEURRole = true
            }
            return result
        }
        // Every recognized semantic path returns above, including known zero.
        // Open vocabulary this engine does not understand must fail closed.
        result.hasUnresolvedSemanticRole = true
        return result
    }

    static func refundOffsetsAnything(
        _ transaction: Transaction,
        transactionsByID: [String: Transaction]
    ) -> Bool {
        guard let linkedID = transaction.linkedTransactionID,
              let linked = transactionsByID[linkedID] else { return true }
        return linked.lifecycle != .reversed
    }

    static func unresolvedEvidenceIDs(request: ReviewRequest, facts: PeriodFacts) -> [String] {
        var ids: [String] = []
        for transaction in facts.live where transaction.provenance.evidenceGrade == .unresolved {
            ids.append(transaction.id)
        }
        for record in facts.history {
            // Preserve archive uncertainty independently of missing EUR
            // authority and an unrecognized semantic role. Neither kind of
            // omitted contribution may read as a confident zero.
            if record.evidence.unresolvedReason != nil
                || facts.historyByID[record.historicalID]?.hasUnvaluedEURRole == true
                || facts.historyByID[record.historicalID]?.hasUnresolvedSemanticRole == true {
                ids.append(record.historicalID)
            }
        }
        let queue = ExternalEvidenceReview.reviewQueue(in: request.document)
        for observation in queue {
            // `?? cutoverComparisonDate` used to stand here. Both properties
            // are nil under exactly one condition — all four provider dates
            // absent — so the fallback could never be reached.
            if let date = observation.economicPeriodDay, request.interval.contains(date) {
                ids.append(observation.id)
            }
        }
        // A provider-status warning belongs to the period holding the euro it
        // disputes, and to no other. Unscoped, one month's warning was
        // reported as unresolved evidence in every month reviewed.
        let warned = Set(ExternalEvidenceReview.providerStatusWarnings(in: request.document))
        for observation in request.document.externalObservations where warned.contains(observation.id) {
            if let date = observation.economicPeriodDay, request.interval.contains(date) {
                ids.append(observation.id)
            }
        }
        return Array(Set(ids)).sorted()
    }

    // MARK: - Helpers

    static func spentByLine(_ budget: ReviewBudget, currency: Currency) -> [String: Money] {
        var totals: [String: Int64] = [:]
        for context in budget.monthlyContexts {
            for line in context.lines {
                totals[line.id, default: 0] += line.periodSpent.minorUnits
            }
        }
        return totals.mapValues { Money(minorUnits: $0, currency: currency) }
    }

    /// Sums `balances` over the accounts eligible for `requirement`.
    ///
    /// Eligibility only — this decides *which* accounts count, never *what*
    /// they hold. Callers pass effective holdings from `CurrentHoldings`;
    /// handing it raw `document.balances` would reinstate a second, stale
    /// current-cash model.
    static func spendablePool(
        balances: [AccountBalance],
        accounts: [Account],
        requirement: PaymentRequirement
    ) -> Money {
        let byID = Dictionary(
            balances.map { ($0.accountID, $0.balance) },
            uniquingKeysWith: { first, _ in first }
        )
        var total: Int64 = 0
        for account in accounts.sorted(by: { $0.id < $1.id }) where account.satisfies(requirement) {
            total += (byID[account.id] ?? Money(minorUnits: 0, currency: account.currency)).minorUnits
        }
        return Money(minorUnits: total, currency: requirement.currency)
    }

    static func monthSpan(_ start: MonthKey, _ end: MonthKey) -> ReviewInterval {
        ReviewInterval(start: start.firstDay, end: end.firstDay.lastDayOfMonth)
    }

    static func gapOrder(_ lhs: FinanceHistorySourceGap, _ rhs: FinanceHistorySourceGap) -> Bool {
        (lhs.startMonth, lhs.endMonth, lhs.completeness, lhs.message)
            < (rhs.startMonth, rhs.endMonth, rhs.completeness, rhs.message)
    }

    static func mergeIntervals(_ intervals: [ReviewInterval]) -> [ReviewInterval] {
        let ordered = intervals
            .filter { $0.start <= $0.end }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        guard var current = ordered.first else { return [] }
        var result: [ReviewInterval] = []
        for next in ordered.dropFirst() {
            // Overlapping, or separated by exactly one day. A separation too
            // large to express is a gap, never an accidental adjacency.
            if next.start <= current.end || current.end.days(until: next.start) == 1 {
                let end = next.end > current.end ? next.end : current.end
                current = ReviewInterval(start: current.start, end: end)
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    static func subtract(_ interval: ReviewInterval, minus covered: [ReviewInterval]) -> [ReviewInterval] {
        var remaining = [interval]
        for hole in mergeIntervals(covered) {
            var next: [ReviewInterval] = []
            for piece in remaining {
                guard let overlap = piece.intersection(with: hole) else {
                    next.append(piece)
                    continue
                }
                // `piece.start < overlap.start` and `overlap.end < piece.end`
                // each guarantee the neighbour day exists; an absent one drops
                // the remainder piece rather than inventing its bound.
                if piece.start < overlap.start, let before = overlap.start.advanced(by: -1) {
                    next.append(ReviewInterval(start: piece.start, end: before))
                }
                if overlap.end < piece.end, let after = overlap.end.advanced(by: 1) {
                    next.append(ReviewInterval(start: after, end: piece.end))
                }
            }
            remaining = next
        }
        return remaining.filter { $0.start <= $0.end }
    }

    static func uncoveredDayCount(interval: ReviewInterval, missing: [ReviewInterval]) -> Int {
        guard interval.start <= interval.end else { return 0 }
        var count = 0
        var day = interval.start
        while day <= interval.end {
            if missing.contains(where: { $0.contains(day) }) { count += 1 }
            // The last day of the interval is counted; asking for the day
            // after it would leave the domain for no result.
            guard day < interval.end, let following = day.advanced(by: 1) else { break }
            day = following
        }
        return count
    }

    static func uniqueReasons(_ reasons: [ReviewCoverageReason]) -> [ReviewCoverageReason] {
        var seen = Set<ReviewCoverageReason>()
        var result: [ReviewCoverageReason] = []
        for reason in reasons where seen.insert(reason).inserted {
            result.append(reason)
        }
        return result
    }

    static func finding(
        _ kind: ReviewFindingKind,
        severity: ReviewFindingSeverity,
        amounts: [Money],
        dates: [Day],
        ids: [String]
    ) -> ReviewFinding {
        let id = ([kind.rawValue] + ids).joined(separator: ":")
        return ReviewFinding(
            id: id,
            kind: kind,
            severity: severity,
            amounts: amounts,
            dates: dates,
            ids: ids
        )
    }

    static func findingOrder(_ lhs: ReviewFinding, _ rhs: ReviewFinding) -> Bool {
        let ls = severityRank(lhs.severity)
        let rs = severityRank(rhs.severity)
        if ls != rs { return ls < rs }
        let lk = kindRank(lhs.kind)
        let rk = kindRank(rhs.kind)
        if lk != rk { return lk < rk }
        return (lhs.ids.first ?? "", lhs.id) < (rhs.ids.first ?? "", rhs.id)
    }

    static func severityRank(_ severity: ReviewFindingSeverity) -> Int {
        switch severity {
        case .important: return 0
        case .warning: return 1
        case .info: return 2
        }
    }

    static func kindRank(_ kind: ReviewFindingKind) -> Int {
        ReviewFindingKind.allCases.firstIndex(of: kind) ?? 99
    }
}
