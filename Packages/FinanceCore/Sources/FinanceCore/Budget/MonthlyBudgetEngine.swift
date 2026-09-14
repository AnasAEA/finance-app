import Foundation

/// What one budget line did over one month.
public struct BudgetLineProgress: Identifiable, Hashable, Sendable {

    public let id: String
    public let name: String
    public let spendingClass: SpendingClass
    public let confirmation: BudgetConfirmation

    /// The month's target for this line.
    public let target: Money

    /// Economic spending already attributed to it, net of refunds. May exceed
    /// `target`; may be negative when refunds outweigh the month's spending.
    public let spent: Money

    /// Committed obligations linked to this line that are still unsettled in
    /// the rest of the month. Money already promised, not yet gone.
    public let committed: Money

    /// `target - spent`. Signed: an overspent line says so.
    public let remaining: Money

    /// What is left once the still-owed commitments are honoured.
    public let remainingAfterCommitted: Money

    /// `spent / target`, clamped to 0...1 so a bar fills rather than overflows.
    public let fraction: Double

    /// The same ratio unclamped, so "180% of groceries" stays sayable.
    public let rawFraction: Double

    public let isOverspent: Bool

    /// What may still be spent per remaining day without breaching the line.
    /// `nil` outside the current month, where a pace means nothing.
    public let dailyPace: Money?
    public let weeklyPace: Money?

    public init(
        id: String,
        name: String,
        spendingClass: SpendingClass,
        confirmation: BudgetConfirmation,
        target: Money,
        spent: Money,
        committed: Money,
        remaining: Money,
        remainingAfterCommitted: Money,
        fraction: Double,
        rawFraction: Double,
        isOverspent: Bool,
        dailyPace: Money?,
        weeklyPace: Money?
    ) {
        self.id = id
        self.name = name
        self.spendingClass = spendingClass
        self.confirmation = confirmation
        self.target = target
        self.spent = spent
        self.committed = committed
        self.remaining = remaining
        self.remainingAfterCommitted = remainingAfterCommitted
        self.fraction = fraction
        self.rawFraction = rawFraction
        self.isOverspent = isOverspent
        self.dailyPace = dailyPace
        self.weeklyPace = weeklyPace
    }
}

/// What one month did against the whole plan.
public struct MonthlyBudgetReport: Hashable, Sendable {

    public let month: MonthKey
    public let currency: Currency

    /// The gross economic-spending ceiling for the month, when the plan states
    /// one. Housing included; assistance never subtracted.
    public let ceiling: Money?

    /// The sum of every line's target for this month.
    public let target: Money

    /// Every euro of economic spending in the month, net of refunds —
    /// including spending no line claims.
    public let spent: Money

    /// Committed obligations still unsettled in the rest of the month, whether
    /// or not they are linked to a line.
    public let committed: Money

    /// `target - spent`.
    public let remaining: Money

    /// What is left of the target once commitments are honoured.
    public let remainingAfterCommitted: Money

    /// `ceiling - target`: the part of the ceiling no line has claimed.
    /// `nil` without a ceiling.
    public let unallocated: Money?

    /// What may still be spent this month without breaching the ceiling (or,
    /// with no ceiling, the total target): budget headroom, never liquidity.
    public let safeToSpendBudget: Money

    /// Economic spending that matched no line. Counted in `spent`, and named
    /// here so it is never quietly dropped.
    public let uncategorized: Money

    /// Repayments of financed purchases: cash out, zero new consumption. Kept
    /// out of `spent` and reported so the month's cash pressure stays visible.
    public let financingRepayments: Money

    public let daysInMonth: Int
    public let daysElapsed: Int
    public let daysRemaining: Int
    public let isCurrentMonth: Bool

    public let lines: [BudgetLineProgress]

    /// Lines whose target is in another currency. Reported so they stay
    /// visible, kept out of every total above: converting them would need a
    /// rate this engine has no business inventing.
    public let otherCurrencyLines: [BudgetLineProgress]

    public init(
        month: MonthKey,
        currency: Currency,
        ceiling: Money?,
        target: Money,
        spent: Money,
        committed: Money,
        remaining: Money,
        remainingAfterCommitted: Money,
        unallocated: Money?,
        safeToSpendBudget: Money,
        uncategorized: Money,
        financingRepayments: Money,
        daysInMonth: Int,
        daysElapsed: Int,
        daysRemaining: Int,
        isCurrentMonth: Bool,
        lines: [BudgetLineProgress],
        otherCurrencyLines: [BudgetLineProgress] = []
    ) {
        self.month = month
        self.currency = currency
        self.ceiling = ceiling
        self.target = target
        self.spent = spent
        self.committed = committed
        self.remaining = remaining
        self.remainingAfterCommitted = remainingAfterCommitted
        self.unallocated = unallocated
        self.safeToSpendBudget = safeToSpendBudget
        self.uncategorized = uncategorized
        self.financingRepayments = financingRepayments
        self.daysInMonth = daysInMonth
        self.daysElapsed = daysElapsed
        self.daysRemaining = daysRemaining
        self.isCurrentMonth = isCurrentMonth
        self.lines = lines
        self.otherCurrencyLines = otherCurrencyLines
    }

    /// True when no line has ever been agreed to. A screen showing only
    /// proposals must say so.
    public var isEntirelySuggested: Bool {
        !lines.isEmpty && lines.allSatisfy { $0.confirmation == .suggested }
    }

    public var isOverCeiling: Bool {
        guard let ceiling, ceiling.currency == spent.currency else { return false }
        return spent.minorUnits > ceiling.minorUnits
    }
}

/// Monthly budget control, as a pure function of the plan and the facts.
///
/// Two rules drive everything here:
///
/// 1. **Only economic spending counts.** Transfers, cash withdrawals,
///    pass-through disposals and financing repayments move money without
///    consuming anything, and `Economics` already says so per transaction.
///    This engine never re-derives that judgement from a sign or a category.
///
/// 2. **Nothing is counted twice.** A recurring charge is either an
///    expectation still owed (`committed`) or a settled actual (`spent`) —
///    the reconciliation ledger decides which, and the two totals are disjoint
///    by construction.
public enum MonthlyBudgetEngine {

    /// Where a transaction's spending was attributed, and why.
    public enum AttributionBasis: Hashable, Sendable, Codable {
        /// The transaction settles an obligation committed to this line.
        case settledObligation(obligationID: String)
        /// The transaction's category is claimed by this line.
        case category(String)
        /// A refund inherits the line of the expense it reverses.
        case refundOfLinkedTransaction(String)
        /// Economic spending no line claims.
        case unattributed
    }

    public struct Attribution: Hashable, Sendable {
        public let transactionID: String
        public let budgetID: String?
        public let basis: AttributionBasis
        /// Economic spending net of refunds, in the report currency.
        public let amount: Money

        public init(
            transactionID: String,
            budgetID: String?,
            basis: AttributionBasis,
            amount: Money
        ) {
            self.transactionID = transactionID
            self.budgetID = budgetID
            self.basis = basis
            self.amount = amount
        }
    }

    /// The month report for `month`.
    ///
    /// `categoryKeys` maps a transaction id to the app's category vocabulary.
    /// The engine owns no category names of its own: a key absent from every
    /// line's `categoryKeys` leaves that spending uncategorised on purpose.
    public static func report(
        month: MonthKey,
        today: Day,
        document: FinanceDocument,
        categoryKeys: [String: String] = [:],
        currency: Currency = .eur
    ) -> MonthlyBudgetReport {
        let planning = document.planning
        let ledger = ReconciliationLedger(planning.settlements)
        let calendar = monthCalendar(month: month, today: today)

        let inEffect = planning.budgets
            .compactMap { budget -> (BudgetAllocation, Money)? in
                guard let amount = budget.amount(for: month) else { return nil }
                return (budget, amount)
            }
            .sorted { $0.0.id < $1.0.id }
        let lines = inEffect.filter { $0.1.currency == currency }

        let counted = count(
            month: month, today: today, document: document, ledger: ledger,
            lines: lines, categoryKeys: categoryKeys, currency: currency
        )
        let spent = counted.spentByLine.values.reduce(0, +) + counted.uncategorized

        let progress = lines.map { budget, amount in
            lineProgress(
                budget, target: amount,
                spent: counted.spentByLine[budget.id] ?? 0,
                committed: counted.committedByLine[budget.id] ?? 0,
                calendar: calendar
            )
        }

        // Foreign lines get the same treatment inside their own currency.
        var foreign: [BudgetLineProgress] = []
        for otherCurrency in Set(inEffect.map { $0.1.currency })
            .subtracting([currency])
            .sorted(by: { $0.code < $1.code }) {
            let group = inEffect.filter { $0.1.currency == otherCurrency }
            let tally = count(
                month: month, today: today, document: document, ledger: ledger,
                lines: group, categoryKeys: categoryKeys, currency: otherCurrency
            )
            foreign.append(
                contentsOf: group.map { budget, amount in
                    lineProgress(
                        budget, target: amount,
                        spent: tally.spentByLine[budget.id] ?? 0,
                        committed: tally.committedByLine[budget.id] ?? 0,
                        calendar: calendar
                    )
                }
            )
        }

        let financing = financingRepayments(
            month: month, transactions: document.transactions, currency: currency
        )
        let target = lines.reduce(Int64(0)) { $0 + $1.1.minorUnits }
        let ceiling = planning.monthlyEconomicCeiling?.currency == currency
            ? planning.monthlyEconomicCeiling
            : nil
        let headroomBasis = ceiling?.minorUnits ?? target

        return MonthlyBudgetReport(
            month: month,
            currency: currency,
            ceiling: ceiling,
            target: Money(minorUnits: target, currency: currency),
            spent: Money(minorUnits: spent, currency: currency),
            committed: Money(minorUnits: counted.committedTotal, currency: currency),
            remaining: Money(minorUnits: target - spent, currency: currency),
            remainingAfterCommitted: Money(
                minorUnits: target - spent - counted.committedTotal, currency: currency
            ),
            unallocated: ceiling.map { Money(minorUnits: $0.minorUnits - target, currency: currency) },
            safeToSpendBudget: Money(
                minorUnits: headroomBasis - spent - counted.committedTotal, currency: currency
            ),
            uncategorized: Money(minorUnits: counted.uncategorized, currency: currency),
            financingRepayments: financing,
            daysInMonth: calendar.daysInMonth,
            daysElapsed: calendar.daysElapsed,
            daysRemaining: calendar.daysRemaining,
            isCurrentMonth: calendar.isCurrentMonth,
            lines: progress,
            otherCurrencyLines: foreign
        )
    }

    /// What one currency's lines spent and still owe this month.
    private struct Tally {
        var spentByLine: [String: Int64] = [:]
        var committedByLine: [String: Int64] = [:]
        var uncategorized: Int64 = 0
        var committedTotal: Int64 = 0
    }

    private static func count(
        month: MonthKey,
        today: Day,
        document: FinanceDocument,
        ledger: ReconciliationLedger,
        lines: [(BudgetAllocation, Money)],
        categoryKeys: [String: String],
        currency: Currency
    ) -> Tally {
        var tally = Tally()
        for attribution in attributions(
            month: month, document: document, lines: lines.map(\.0),
            ledger: ledger, categoryKeys: categoryKeys, currency: currency
        ) {
            if let budgetID = attribution.budgetID {
                tally.spentByLine[budgetID, default: 0] += attribution.amount.minorUnits
            } else {
                tally.uncategorized += attribution.amount.minorUnits
            }
        }

        // Commitments come from `BudgetCommitmentAttribution` and nowhere else,
        // so the forecast nets exactly what this report calls committed. That
        // list is built from `unresolved`, so a settled charge cannot be both an
        // expectation here and an actual above.
        for commitment in BudgetCommitmentAttribution.commitments(
            in: document,
            from: month.firstDay,
            to: month.firstDay.lastDayOfMonth,
            asOf: today,
            ledger: ledger
        ) where commitment.amount.currency == currency {
            tally.committedTotal += commitment.amount.minorUnits
            if let budgetID = commitment.budgetID {
                tally.committedByLine[budgetID, default: 0] += commitment.amount.minorUnits
            }
        }
        return tally
    }

    private static func lineProgress(
        _ budget: BudgetAllocation,
        target: Money,
        spent: Int64,
        committed: Int64,
        calendar: MonthCalendar
    ) -> BudgetLineProgress {
        let currency = target.currency
        let remaining = target.minorUnits - spent
        let afterCommitted = remaining - committed
        let ratio = target.minorUnits > 0 ? Double(spent) / Double(target.minorUnits) : 0
        return BudgetLineProgress(
            id: budget.id,
            name: budget.name,
            spendingClass: budget.spendingClass,
            confirmation: budget.confirmation,
            target: target,
            spent: Money(minorUnits: spent, currency: currency),
            committed: Money(minorUnits: committed, currency: currency),
            remaining: Money(minorUnits: remaining, currency: currency),
            remainingAfterCommitted: Money(minorUnits: afterCommitted, currency: currency),
            fraction: min(max(ratio, 0), 1),
            rawFraction: max(ratio, 0),
            isOverspent: spent > target.minorUnits,
            dailyPace: pace(afterCommitted, over: calendar.daysRemaining, days: 1, currency: currency),
            weeklyPace: pace(afterCommitted, over: calendar.daysRemaining, days: 7, currency: currency)
        )
    }

    // MARK: - Attribution

    /// Every observed transaction in the month that moved economic spending,
    /// with the line it belongs to.
    ///
    /// Exposed because attribution is the part a person will want to audit:
    /// "why is this in groceries" has to have an answer.
    public static func attributions(
        month: MonthKey,
        document: FinanceDocument,
        lines: [BudgetAllocation],
        ledger: ReconciliationLedger,
        categoryKeys: [String: String],
        currency: Currency = .eur
    ) -> [Attribution] {
        var lineForCategory: [String: String] = [:]
        for line in lines.sorted(by: { $0.id < $1.id }) {
            for key in line.categoryKeys where lineForCategory[key] == nil {
                lineForCategory[key] = line.id
            }
        }
        let lineIDs = Set(lines.map(\.id))
        let obligations = Dictionary(
            document.planning.recurringObligations.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let transactionsByID = Dictionary(
            document.transactions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        /// The line a transaction belongs to, independent of when it happened,
        /// so a refund can ask about the expense it reverses.
        func line(for transaction: Transaction) -> (String?, AttributionBasis) {
            if let settlement = ledger.settlement(forActual: transaction.id),
               let budgetID = obligations[settlement.occurrence.obligationID]?.budgetID,
               lineIDs.contains(budgetID) {
                return (budgetID, .settledObligation(obligationID: settlement.occurrence.obligationID))
            }
            if let key = categoryKeys[transaction.id], let budgetID = lineForCategory[key] {
                return (budgetID, .category(key))
            }
            return (nil, .unattributed)
        }

        /// A refund only gives back spending that was actually counted.
        ///
        /// A reversed debit never economically happened, so `Economics` already
        /// scores it zero. When the bank then models the reversal as a separate
        /// credit — as a contested direct debit is — subtracting that credit as
        /// well would turn a charge that was cancelled into *negative*
        /// consumption, and a month with nothing spent in it would report more
        /// headroom than its own ceiling.
        func refundOffsetsAnything(_ transaction: Transaction) -> Bool {
            guard let linkedID = transaction.linkedTransactionID,
                  let linked = transactionsByID[linkedID] else { return true }
            return linked.lifecycle != .reversed
        }

        var result: [Attribution] = []
        for transaction in document.transactions
        where transaction.factivity == .observed && month.contains(transaction.date) {
            let effect = Economics.effect(of: transaction, currency: currency)
            let refund = refundOffsetsAnything(transaction) ? effect.refund.minorUnits : 0
            let net = effect.spending.minorUnits - refund
            guard net != 0 else { continue }

            var resolved = line(for: transaction)
            // A refund corrects the spending it reverses, so it belongs to
            // that expense's line even when the credit itself is uncategorised.
            if resolved.0 == nil,
               refund > 0,
               let linkedID = transaction.linkedTransactionID,
               let linked = transactionsByID[linkedID] {
                let linkedLine = line(for: linked)
                if let budgetID = linkedLine.0 {
                    resolved = (budgetID, .refundOfLinkedTransaction(linkedID))
                }
            }

            result.append(
                Attribution(
                    transactionID: transaction.id,
                    budgetID: resolved.0,
                    basis: resolved.1,
                    amount: Money(minorUnits: net, currency: currency)
                )
            )
        }
        return result.sorted { $0.transactionID < $1.transactionID }
    }

    // MARK: - Helpers

    private static func financingRepayments(
        month: MonthKey,
        transactions: [Transaction],
        currency: Currency
    ) -> Money {
        var total: Int64 = 0
        for transaction in transactions
        where transaction.factivity == .observed && month.contains(transaction.date) {
            total += Economics.effect(of: transaction, currency: currency)
                .financingRepayment.minorUnits
        }
        return Money(minorUnits: total, currency: currency)
    }

    fileprivate struct MonthCalendar {
        let daysInMonth: Int
        let daysElapsed: Int
        let daysRemaining: Int
        let isCurrentMonth: Bool
    }

    private static func monthCalendar(month: MonthKey, today: Day) -> MonthCalendar {
        let daysInMonth = Day.daysInMonth(year: month.year, month: month.month)
        if month == today.monthKey {
            // Today is still spendable, so it counts as remaining rather than
            // elapsed.
            return MonthCalendar(
                daysInMonth: daysInMonth,
                daysElapsed: today.day - 1,
                daysRemaining: daysInMonth - today.day + 1,
                isCurrentMonth: true
            )
        }
        if month < today.monthKey {
            return MonthCalendar(
                daysInMonth: daysInMonth,
                daysElapsed: daysInMonth,
                daysRemaining: 0,
                isCurrentMonth: false
            )
        }
        return MonthCalendar(
            daysInMonth: daysInMonth,
            daysElapsed: 0,
            daysRemaining: daysInMonth,
            isCurrentMonth: false
        )
    }

    /// A pace only exists while there are days left to spend over, and only
    /// while there is something left to spend. An overspent line paces at
    /// zero rather than at a negative number a person cannot act on.
    private static func pace(
        _ remainingMinorUnits: Int64,
        over daysRemaining: Int,
        days: Int,
        currency: Currency
    ) -> Money? {
        guard daysRemaining > 0 else { return nil }
        guard remainingMinorUnits > 0 else { return Money(minorUnits: 0, currency: currency) }
        let span = Int64(min(days, daysRemaining))
        let value = remainingMinorUnits * span / Int64(daysRemaining)
        return Money(minorUnits: value, currency: currency)
    }
}
