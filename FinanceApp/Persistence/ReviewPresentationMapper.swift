import FinanceCore
import Foundation

/// Translates one `ReviewResult` into the screen's own types.
///
/// Translation only. Nothing here re-derives a total, applies a threshold, or
/// decides that a change is interesting: every card corresponds to something
/// the engine returned, and the finding thresholds stay in
/// `ReviewFindingPolicy` where they are inspectable.
enum ReviewPresentationMapper {

    /// Names the engine's identifiers refer to. The engine returns ids because
    /// it does not do presentation; these are how the ids become words.
    struct Labels: Hashable, Sendable {
        var budgetLines: [String: String] = [:]
        var goals: [String: String] = [:]
        var transactions: [String: String] = [:]
        var accounts: [String: String] = [:]
        /// Names for the plan items a forecast risk can be triggered by,
        /// keyed by the reference `FirstRisk.triggerLabel` carries.
        ///
        /// That field is `sourceRef ?? eventID`, so it is an *identifier* far
        /// more often than a name — "ob-rent", not "Rent". Nothing reaches the
        /// screen through it without landing in this map first.
        var riskTriggers: [String: String] = [:]
        /// IDs present as actionable observation decisions in Activity now.
        /// An engine finding can also name ledger or archive records, so it
        /// must not route those into this queue by accident.
        var actionableObservationIDs: Set<String> = []
    }

    static func present(
        _ result: ReviewResult,
        selection: ReviewPeriodSelection,
        calendarInterval: ReviewInterval,
        canGoBack: Bool,
        canGoForward: Bool,
        live: LiveCoverageResolution,
        labels: Labels,
        verification: PeriodVerificationPresentation? = nil,
        showsHistoricalHomePointer: Bool = false
    ) -> InsightsPresentation {
        let coverage = coverageSummary(result.coverage, live: live, labels: labels)
        let complete = result.coverage.status == .complete
        let (periodFindings, forwardFindings) = partition(result.findings, risk: result.risk)
        let mappedFindings = periodFindings.map { finding($0, labels: labels) }

        // A figure is stated only when every day behind it is accounted for.
        // Otherwise the honest answer is that it is not known — never zero,
        // and never a partial sum wearing a total's label.
        let spending: ReviewFigure = complete
            ? .known(amount(result.budget.periodEconomicSpending))
            : .unavailable
        let income: ReviewFigure = complete
            ? .known(amount(result.income.personalIncome))
            : .unavailable

        return InsightsPresentation(
            scope: selection.scope,
            title: title(selection, interval: calendarInterval),
            rangeLabel: rangeLabel(result.interval, calendar: calendarInterval),
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            coverage: coverage,
            summary: summary(findings: mappedFindings, spending: spending,
                             income: income, complete: complete),
            spending: spending,
            income: income,
            notableChangeCount: periodFindings.count,
            monthContexts: result.budget.monthlyContexts.map { monthContext($0, labels: labels) },
            topCategories: topCategories(result.budget, labels: labels),
            exceptional: exceptional(result.budget, labels: labels),
            incomeBreakdown: incomeBreakdown(result.income, complete: complete),
            expectations: result.expectations.items.map(expectation),
            goals: goals(result.goals, labels: labels),
            findings: mappedFindings,
            forwardFindings: forwardFindings.map { finding($0, labels: labels) },
            outlook: outlook(result.risk, labels: labels),
            comparison: comparison(result.comparison),
            recordsQualityStatement: coverage.explanation,
            verification: verification,
            showsHistoricalHomePointer: showsHistoricalHomePointer
        )
    }

    /// Findings the engine returned that are about the reviewed period, and
    /// the ones that are about what is still ahead.
    ///
    /// Partitioned on the engine's own closed `ReviewFindingKind` vocabulary
    /// and kept in engine order within each half. Nothing is recomputed, and
    /// no finding lands in both halves — a forward risk shown twice reads as
    /// two problems.
    static func partition(
        _ findings: [ReviewFinding],
        risk: ReviewRisk
    ) -> (period: [ReviewFinding], forward: [ReviewFinding]) {
        let visible = findings.filter {
            !isRedundantFloorWarning($0, risk: risk)
                && !restatesOutlookFirstRisk($0, risk: risk)
        }
        return (
            visible.filter { !isForwardLooking($0.kind) },
            visible.filter { isForwardLooking($0.kind) }
        )
    }

    /// Whether this finding says exactly what the outlook's own first-risk
    /// summary already says.
    ///
    /// What to watch leads with the canonical first risk — its amount, its day
    /// and what triggers it. A card repeating the same kind, day and shortfall
    /// underneath is the same warning twice, which reads as two problems.
    /// Anything that differs in any of those is a separate fact and stays.
    static func restatesOutlookFirstRisk(_ finding: ReviewFinding, risk: ReviewRisk) -> Bool {
        guard finding.kind == .upcomingLiquidityRisk,
              let first = risk.firstRisk,
              // Only when the summary is actually on screen.
              risk.firstHardCashRiskDate == first.day,
              finding.dates == [first.day],
              finding.amounts == [first.shortfall]
        else { return false }
        return true
    }

    static func isForwardLooking(_ kind: ReviewFindingKind) -> Bool {
        switch kind {
        case .upcomingLiquidityRisk, .floorWarning, .goalDeadlineApproaching:
            true
        case .unresolvedEvidenceAffectingAccuracy, .budgetOverrun,
             .unusuallyHighCategory, .majorExceptionalPurchase,
             .supportBelowExpected, .spendingMateriallyHigherThanPrior,
             .spendingMateriallyLowerThanPrior:
            false
        }
    }

    /// A floor breach on the same day the pool goes negative says less than
    /// the deficit already says, and saying "still positive" on that day is
    /// simply false. Dropped rather than reworded.
    ///
    /// A floor warning on its own — the pool stays positive but dips under the
    /// cushion — is a real and separate fact and is kept.
    static func isRedundantFloorWarning(_ finding: ReviewFinding, risk: ReviewRisk) -> Bool {
        guard finding.kind == .floorWarning,
              let first = risk.firstRisk,
              first.kind == .poolDeficit,
              let floorDay = finding.dates.first
        else { return false }
        return floorDay == first.day
    }

    // MARK: - Header

    static func title(_ selection: ReviewPeriodSelection, interval: ReviewInterval) -> String {
        switch (selection.scope, selection.offset) {
        case (.week, 0): "This week"
        case (.week, -1): "Last week"
        case (.week, _): rangeText(interval)
        case (.month, 0): "This month"
        case (.month, -1): "Last month"
        case (.month, _): monthLabel(interval.start.monthKey)
        }
    }

    /// The reviewed days, and the period they sit in when those differ — a
    /// current week is reviewed only as far as today, and saying so is clearer
    /// than printing a week that has not finished.
    static func rangeLabel(_ reviewed: ReviewInterval, calendar: ReviewInterval) -> String {
        reviewed == calendar
            ? rangeText(calendar)
            : "\(rangeText(reviewed)) · so far"
    }

    /// Dates follow the person's locale, through the same formatting every
    /// other screen uses, so Insights and Activity cannot name one day two
    /// different ways.
    static func rangeText(_ interval: ReviewInterval) -> String {
        calendarDay(interval.start).formatted(through: calendarDay(interval.end))
    }

    static func dayText(_ day: Day) -> String {
        calendarDay(day).formatted(.dateTime.day().month(.abbreviated))
    }

    static func monthLabel(_ month: MonthKey) -> String {
        CalendarDay.monthTitle(year: month.year, month: month.month)
    }

    // MARK: - Coverage

    static func coverageSummary(
        _ coverage: ReviewCoverage,
        live: LiveCoverageResolution,
        labels: Labels
    ) -> ReviewCoverageSummary {
        let quality: ReviewDataQuality = switch coverage.status {
        case .complete: .complete
        case .partial: .partial
        case .insufficient: .insufficient
        }
        let unknownNames = live.unknownAccountIDs.map { labels.accounts[$0] ?? $0 }.sorted()
        let mentionsArchive = coverage.reasons.contains {
            $0.kind == .archiveHistoryAbsent || $0.kind == .missingArchiveInterval
                || $0.kind == .sourceGap
        }
        return ReviewCoverageSummary(
            quality: quality,
            explanation: explanation(
                coverage, quality: quality, unknownNames: unknownNames,
                mentionsArchive: mentionsArchive
            ),
            missingRanges: coverage.missingIntervals.map {
                calendarDay($0.start)...calendarDay($0.end)
            },
            unknownAccountNames: unknownNames,
            mentionsArchive: mentionsArchive
        )
    }

    private static func explanation(
        _ coverage: ReviewCoverage,
        quality: ReviewDataQuality,
        unknownNames: [String],
        mentionsArchive: Bool
    ) -> String {
        switch quality {
        case .complete:
            return "Bank and archive records cover this period."
        case .partial, .insufficient:
            if !unknownNames.isEmpty {
                let list = unknownNames.joined(separator: ", ")
                return quality == .insufficient
                    ? "No confirmed bank records for \(list) in this period. Totals are not available."
                    : "Some days are missing for \(list). Totals may be incomplete."
            }
            if coverage.reasons.contains(where: { $0.kind == .coverageMetadataAbsent }) {
                return "No confirmed record of which days were fetched. "
                    + "Sync to establish coverage for this period."
            }
            if mentionsArchive {
                return quality == .insufficient
                    ? "Not enough archive records to review this period reliably."
                    : "Some days are missing from the archive. Totals may be incomplete."
            }
            if quality == .insufficient {
                return "Not enough records to review this period reliably."
            }
            // A count of missing days is only quoted when it is exact. When it
            // is not, the sentence says days are missing without naming a
            // number rather than naming one the arithmetic did not produce.
            let days = coverage.missingIntervals.reduce(Int?.some(0)) { total, interval in
                guard let total, let count = interval.dayCount else { return nil }
                let (sum, overflow) = total.addingReportingOverflow(count)
                return overflow ? nil : sum
            }
            guard let days else {
                return "Some days are missing. Totals may be incomplete."
            }
            return days == 1
                ? "One day is missing. Totals may be incomplete."
                : "\(days) days are missing. Totals may be incomplete."
        }
    }

    // MARK: - Summary sentence

    /// The first useful conclusion. The selected engine finding is rendered
    /// with its explanation in the summary card, so its title is not repeated
    /// in a second section. Figures carry their own values below this line.
    static func summary(
        findings: [ReviewFindingCard],
        spending: ReviewFigure,
        income: ReviewFigure,
        complete: Bool
    ) -> String {
        guard complete else { return "Totals unavailable" }
        if let first = findings.first(where: { $0.role == .reviewItems })
            ?? findings.first(where: { $0.role == .change }) {
            return first.title
        }
        switch (spending.amount, income.amount) {
        case let (spent?, received?) where spent.isZero && received.isZero:
            return "No spending or income recorded."
        case (_?, _?):
            return "Period totals"
        default:
            return "Totals unavailable"
        }
    }

    // MARK: - Budget

    static func monthContext(
        _ context: ReviewMonthlyBudgetContext, labels: Labels
    ) -> ReviewMonthContext {
        ReviewMonthContext(
            id: context.month.isoString,
            monthLabel: monthLabel(context.month),
            periodSpendingInMonth: amount(context.periodSpendingInMonth),
            monthSpending: amount(context.monthSpending),
            ceiling: context.ceiling.map(amount),
            remaining: context.remaining.map(amount),
            overage: context.overage.map(amount),
            committed: amount(context.committed),
            uncategorized: amount(context.uncategorized),
            lines: context.lines.map {
                ReviewBudgetLineSummary(
                    id: $0.id,
                    name: labels.budgetLines[$0.id] ?? $0.name,
                    target: amount($0.target),
                    periodSpent: amount($0.periodSpent),
                    isOverspent: $0.isOverspent
                )
            }
        )
    }

    /// Where the money went, largest first. Summed across the months a period
    /// touches so a cross-month week reports one figure per line.
    static func topCategories(_ budget: ReviewBudget, labels: Labels) -> [ReviewCategoryAmount] {
        var totals: [String: (name: String, minor: Int64)] = [:]
        var currency = "EUR"
        for context in budget.monthlyContexts {
            for line in context.lines where line.periodSpent.minorUnits != 0 {
                currency = line.periodSpent.currency.code
                let name = labels.budgetLines[line.id] ?? line.name
                totals[line.id, default: (name, 0)].minor += line.periodSpent.minorUnits
            }
        }
        return totals
            .map {
                ReviewCategoryAmount(
                    id: $0.key,
                    name: $0.value.name,
                    amount: Amount(minorUnits: $0.value.minor, currencyCode: currency)
                )
            }
            .sorted {
                $0.amount.minorUnits == $1.amount.minorUnits
                    ? $0.id < $1.id
                    : $0.amount.minorUnits > $1.amount.minorUnits
            }
    }

    /// Only drivers the engine already classified as exceptional. Size alone
    /// never promotes an ordinary purchase into this list.
    static func exceptional(
        _ budget: ReviewBudget, labels: Labels
    ) -> [ReviewExceptionalPurchase] {
        budget.drivers
            .filter { $0.nature == .exceptional }
            .sorted {
                $0.amount.minorUnits == $1.amount.minorUnits
                    ? $0.id < $1.id
                    : $0.amount.minorUnits > $1.amount.minorUnits
            }
            .map {
                ReviewExceptionalPurchase(
                    id: $0.id,
                    label: labels.transactions[$0.id] ?? "One-off purchase",
                    amount: amount($0.amount),
                    day: calendarDay($0.date)
                )
            }
    }

    // MARK: - Income

    static func incomeBreakdown(_ income: ReviewIncome, complete: Bool) -> ReviewIncomeBreakdown {
        // Whatever the engine counted as personal income but did not file
        // under a named class still has to appear, or the rows contradict the
        // total above them.
        let named = income.earnedOrOther.minorUnits + income.parentalSupportOwned.minorUnits
            + income.reimbursements.minorUnits + income.unresolved.minorUnits
        let other = Money(
            minorUnits: income.personalIncome.minorUnits - named,
            currency: income.personalIncome.currency
        )
        return ReviewIncomeBreakdown(
            personalIncome: complete ? .known(amount(income.personalIncome)) : .unavailable,
            earnedOrOther: amount(income.earnedOrOther),
            supportOwned: amount(income.parentalSupportOwned),
            supportGross: amount(income.parentalSupportGross),
            reimbursements: amount(income.reimbursements),
            passThroughNotMine: amount(income.passThroughNotMine),
            internalMovement: amount(income.internalMovement),
            unresolved: amount(income.unresolved),
            otherPersonal: amount(other)
        )
    }

    // MARK: - Expected vs actual

    static func expectation(_ item: ReviewExpectation) -> ReviewExpectationRow {
        let state: ReviewExpectationState = switch item.status {
        case .expected: .expected
        case .matched: .matched
        case .missed: .missed
        case .skipped: .skipped
        case .noLongerDue: .noLongerDue
        }
        return ReviewExpectationRow(
            id: item.id,
            name: item.name,
            day: calendarDay(item.expectedDay),
            expected: amount(item.expectedAmount),
            actual: item.actualAmount.map(amount),
            state: state
        )
    }

    // MARK: - Goals

    static func goals(_ goals: ReviewGoals, labels: Labels) -> ReviewGoalsSummary {
        ReviewGoalsSummary(
            currentlySetAside: amount(goals.currentlySetAside),
            reservationChange: goals.reservationHistoryKnown
                ? goals.reservationChange.map(amount)
                : nil,
            active: goals.activePurchases.map {
                ReviewGoalRow(
                    id: $0.id,
                    name: labels.goals[$0.id] ?? $0.name,
                    target: amount($0.targetAmount),
                    reserved: amount($0.reservedAmount),
                    targetDay: $0.targetDate.map(calendarDay)
                )
            }
        )
    }

    // MARK: - Findings

    static func finding(_ finding: ReviewFinding, labels: Labels) -> ReviewFindingCard {
        let tone: ReviewFindingTone = switch finding.severity {
        case .important: .important
        case .warning: .warning
        case .info: .info
        }
        let (title, detail) = copy(for: finding, labels: labels)
        return ReviewFindingCard(
            id: finding.id, tone: tone, role: role(for: finding),
            title: title, detail: detail,
            destination: destination(
                kind: finding.kind, ids: finding.ids,
                actionableObservationIDs: labels.actionableObservationIDs
            )
        )
    }

    private static func role(for finding: ReviewFinding) -> ReviewFindingRole {
        guard finding.kind == .unresolvedEvidenceAffectingAccuracy else { return .change }
        return !finding.ids.isEmpty && finding.ids.allSatisfy {
            ReviewCoverageReasonKind(rawValue: $0) != nil
        } ? .coverage : .reviewItems
    }

    static func destination(
        kind: ReviewFindingKind,
        ids: [String],
        actionableObservationIDs: Set<String>
    ) -> ReviewFindingDestination? {
        guard kind == .unresolvedEvidenceAffectingAccuracy,
              !ids.isEmpty,
              ids.allSatisfy(actionableObservationIDs.contains)
        else { return nil }
        return .reviewItems(ids)
    }

    /// Wording for each engine finding, built only from what that finding
    /// carries. Plain and factual: no alarm, no advice, no interpretation.
    private static func copy(
        for finding: ReviewFinding, labels: Labels
    ) -> (String, String) {
        func money(_ index: Int) -> String {
            finding.amounts.indices.contains(index)
                ? amount(finding.amounts[index]).formatted()
                : "—"
        }
        func day(_ index: Int) -> String {
            finding.dates.indices.contains(index) ? dayText(finding.dates[index]) : "—"
        }

        switch finding.kind {
        case .unresolvedEvidenceAffectingAccuracy:
            // The engine emits this for two different reasons; the ids say
            // which. Coverage reasons are a closed vocabulary, review items
            // are opaque ids.
            if role(for: finding) == .coverage {
                return ("Records are incomplete",
                        "Some days in this period have no confirmed records, "
                            + "so the totals above are not shown.")
            }
            let count = finding.ids.count
            return ("Items still to review",
                    count == 1
                        ? "One bank item has not been reviewed, so it is not counted yet."
                        : "\(count) bank items have not been reviewed, so they are not counted yet.")

        case .budgetOverrun:
            let month = finding.ids.first.flatMap(MonthKey.init(isoString:)).map(monthLabel)
                ?? "The month"
            return ("\(month) went over budget",
                    "Spending reached \(money(0)) against \(money(1)) — \(money(2)) over.")

        case .unusuallyHighCategory:
            let name = finding.ids.first.flatMap { labels.budgetLines[$0] } ?? "A category"
            return ("\(name) was unusually high",
                    "\(money(0)) this period, against \(money(1)) the period before.")

        case .majorExceptionalPurchase:
            let label = finding.ids.first.flatMap { labels.transactions[$0] } ?? "A one-off purchase"
            return ("\(label) was a large one-off",
                    "\(money(0)) on \(day(0)).")

        case .supportBelowExpected:
            return ("Support was lower than expected",
                    "\(money(1)) arrived against \(money(0)) expected.")

        case .upcomingLiquidityRisk:
            return ("Money runs short on \(day(0))",
                    finding.amounts.isEmpty
                        ? "Based on what is scheduled from today."
                        : "\(money(0)) short, based on what is scheduled from today.")

        case .floorWarning:
            return ("Balance dips below your floor on \(day(0))",
                    "Still positive, but under the cushion you set.")

        case .spendingMateriallyHigherThanPrior:
            return ("Spending was higher than the period before",
                    "\(money(0)) against \(money(1)) — \(money(2)) more.")

        case .spendingMateriallyLowerThanPrior:
            return ("Spending was lower than the period before",
                    "\(money(0)) against \(money(1)) — \(money(2)) less.")

        case .goalDeadlineApproaching:
            let name = finding.ids.first.flatMap { labels.goals[$0] } ?? "A goal"
            return ("\(name) is due \(day(0))", "Target \(money(0)).")
        }
    }

    // MARK: - Outlook

    /// Forward-looking from `asOf`. `liquidityNow` is current spendable cash,
    /// which is why it is never labelled as the period's closing balance.
    static func outlook(_ risk: ReviewRisk, labels: Labels) -> ReviewOutlook {
        // The amount and the day come from `FirstRisk` together. The engine's
        // `minimumBridgeRequired` is the up-front bridge for the whole horizon
        // and is a different number about a different question, so it never
        // becomes the figure in a sentence naming this day.
        let first = risk.firstRisk
        let deficitDay = risk.firstHardCashRiskDate
        let floorDay = risk.firstFloorWarningDate
        let floorIsRedundant = first?.kind == .poolDeficit && floorDay == first?.day
        return ReviewOutlook(
            asOfDay: calendarDay(risk.asOf),
            horizonEnd: calendarDay(risk.outlookEnd),
            liquidityNow: amount(risk.asOfLedgerLiquidity),
            firstRiskDay: deficitDay.map(calendarDay),
            firstRiskKind: first.map {
                switch $0.kind {
                case .poolDeficit: .poolDeficit
                case .belowSafetyFloor: .belowSafetyFloor
                }
            },
            // Resolved to a name the person chose, or nothing at all. An
            // unresolved reference is an internal identifier, and the sentence
            // reads perfectly well as a date on its own.
            firstRiskLabel: first.flatMap { labels.riskTriggers[$0.triggerLabel] },
            shortfall: first.flatMap { $0.day == deficitDay ? amount($0.shortfall) : nil },
            floorWarningDay: floorIsRedundant ? nil : floorDay.map(calendarDay),
            upcoming: risk.upcomingObligations.prefix(5).map {
                ReviewUpcomingItem(
                    id: "\($0.obligationID)@\($0.expectedDay.isoString)",
                    name: $0.name,
                    day: calendarDay($0.expectedDay),
                    amount: amount($0.amount)
                )
            }
        )
    }

    // MARK: - Comparison

    static func comparison(_ comparison: ReviewComparison) -> ReviewComparisonState {
        switch comparison {
        case let .available(value):
            return .available(
                previousLabel: rangeText(value.priorInterval),
                spendingDelta: amount(value.spending.absolute)
            )
        case let .unavailable(refusal):
            let reason: String = switch refusal {
            case .notRequested:
                "Comparison was not requested."
            case .priorCoverageIncomplete:
                "Comparison unavailable because the previous period is incomplete."
            case .currentCoverageIncomplete:
                "Comparison unavailable because this period is incomplete."
            case .coverageNotComparable:
                "Comparison unavailable because the two periods are not comparable."
            }
            return .unavailable(reason: reason)
        }
    }

    // MARK: - Conversions

    static func amount(_ money: Money) -> Amount {
        Amount(
            minorUnits: money.minorUnits,
            currencyCode: money.currency.code,
            fractionDigits: money.currency.minorUnitDigits
        )
    }

    static func calendarDay(_ day: Day) -> CalendarDay {
        CalendarDay(year: day.year, month: day.month, day: day.day)
    }
}
