import Foundation

/// Everything the screens read, in the shape the product speaks.
///
/// This is the line the engine does not cross. `FinanceAppSnapshot` and the
/// values it carries import Foundation and nothing else: no `Money`, no
/// `ForecastResult`, no `Transaction`, no `UUID` identity that a future core
/// might spell differently. `DomainMapper` fills it from whichever core is
/// installed, and the views cannot tell which one that was.
///
/// Identifiers are `String` throughout, because the next core numbers its
/// records that way and a facade that has to be renumbered is not a facade.
struct FinanceAppSnapshot: Hashable, Sendable {

    // MARK: Context

    var asOf: CalendarDay
    /// How far ahead the projection runs.
    var horizonDays: Int
    var scenario: PlanScenario
    /// The home currency the plan is denominated in, for empty-state figures.
    var currencyCode: String

    // MARK: Balances

    /// What could actually meet an obligation in the home currency today.
    var accountCash: Amount
    /// Notes and coins, and anything held in another currency. Never summed
    /// into `accountCash` — 200 MAD in a pocket cannot pay a French direct
    /// debit, and a total that implies otherwise is a lie.
    var physicalCash: [HoldingLine]
    /// Every account, in display order, including the ones above.
    var trackedHoldings: [HoldingLine]

    // MARK: Safe to spend

    var safeToSpend: Amount
    var safeDailySpend: Amount
    var safeToSpendReason: SafeToSpendReason
    /// The window `safeToSpend` was computed over, in days — shorter than
    /// `horizonDays`, which is the forecast's. Two horizons live on this
    /// snapshot, and a sentence that mixes them is a wrong sentence, so each
    /// figure carries the one it belongs to.
    var safeToSpendWindowDays: Int
    /// Signed headroom before it is clamped: negative when committed payments
    /// already exceed the money available, zero otherwise. `safeToSpend` is
    /// never negative, so the two coexist and say different things.
    var rawShortfall: Amount
    /// The obligations already committed inside `safeToSpendWindowDays`, as a
    /// positive figure — the amount subtracted from `accountCash` to reach
    /// `safeToSpend`.
    ///
    /// The engine has always computed it and the snapshot used to drop it,
    /// which left the headline unexplainable: Home could print the money
    /// available and the money safe to use and say nothing about the
    /// difference between them. Carried so the product can name the
    /// subtraction rather than re-derive it — relocations, withdrawals and
    /// disposals are *not* in here, and variable budget spending is not
    /// either.
    var committedOutflows: Amount

    // MARK: Risk

    var cashRunway: CashRunway
    /// The first day the projection goes below zero.
    var firstRisk: RiskPoint?
    /// The lowest point it reaches, negative or not.
    var lowestPoint: RiskPoint
    /// What it would take to keep the balance above zero throughout.
    var minimumBridgeRequired: Amount
    /// The projected balance per day, for the runway chart.
    var runwayPoints: [RunwayPoint]

    // MARK: Plan

    /// The next obligations and inflows, soonest first.
    var upcomingEvents: [PlannedEvent]
    /// One entry per month the horizon touches, current month first.
    var monthProjections: [MonthProjection]

    // MARK: Budget

    /// The month's budget: the gross ceiling, every line in effect, and what
    /// has actually been spent against them.
    var budget: BudgetOverview

    var budgetLines: [BudgetLine] { budget.lines + budget.otherCurrencyLines }
    /// The month-level figure Home leads with.
    var everydayBudget: BudgetSummary { budget.summary }

    // MARK: Lists

    var activity: [ActivityDay]
    var commitments: [CommitmentGroup]
    var instalments: [InstalmentLine]
    var income: [IncomeGroup]
    var debts: [DebtLine]

    /// User-managed identities. These include inactive records because old
    /// transactions must continue to resolve after an account or income source
    /// is retired.
    var accounts: [AccountSummary]
    var incomeSources: [IncomeSourceSummary]

    /// The categories and accounts the entry sheet offers.
    var entryOptions: EntryOptions

    // MARK: - Reconciliation

    /// Dated instances of the recurring commitments, each with its standing.
    /// Expanded per snapshot, never stored: the rule and the calendar say what
    /// they are, and a second stored copy is a second thing to disagree.
    var expectedPayments: [ExpectedPayment] = []

    /// What settles what, keyed by the recorded transaction's id, so an
    /// Activity row can say it is matched without carrying a field of its own.
    var reconciliations: [String: ReconciliationSummary] = [:]

    // MARK: - External account evidence

    /// Provider observations awaiting a decision, followed by recent resolved
    /// evidence for audit. No item here is an economic transaction by itself.
    var syncedObservations: [SyncedObservationItem] = []
    var providerAccountBindings: [ProviderAccountBinding] = []
    var providerBalanceStatuses: [ProviderBalanceStatus] = []
    var trustedRules: [TrustedRuleSummary] = []
    var providerConnections: [ProviderConnectionStatus] = []
    var mappableRemoteAccounts: [MappableRemoteAccount] = []
    var currentPendingProviderSnapshots: [CurrentPendingProviderSnapshot] = []

    // MARK: - Phase 2.7 planning

    var plannedPurchases: [PlannedPurchaseSummary] = []
    var sinkingFunds: [SinkingFundSummary] = []
}

extension FinanceAppSnapshot {
    /// Closing balance for each month the horizon touches.
    var projectedMonthEnd: [CalendarMonth: Amount] {
        Dictionary(uniqueKeysWithValues: monthProjections.map { ($0.month, $0.closing) })
    }

    var currentMonth: MonthProjection? { monthProjections.first }

    var isSolvent: Bool { firstRisk == nil }

    /// An empty plan, so a store can exist before anything is loaded.
    static func empty(asOf: CalendarDay, currencyCode: String = "EUR") -> FinanceAppSnapshot {
        let zero = Amount.zero(currencyCode)
        return FinanceAppSnapshot(
            asOf: asOf,
            horizonDays: 0,
            scenario: .base,
            currencyCode: currencyCode,
            accountCash: zero,
            physicalCash: [],
            trackedHoldings: [],
            safeToSpend: zero,
            safeDailySpend: zero,
            safeToSpendReason: .unconstrained,
            safeToSpendWindowDays: 0,
            rawShortfall: zero,
            committedOutflows: zero,
            cashRunway: .clear(horizonDays: 0),
            firstRisk: nil,
            lowestPoint: RiskPoint(date: asOf, projectedBalance: zero, triggerLabel: nil,
                                    triggerAmount: nil, kind: nil, riskAmount: nil),
            minimumBridgeRequired: zero,
            runwayPoints: [],
            upcomingEvents: [],
            monthProjections: [],
            budget: .none(currencyCode: currencyCode),
            activity: [],
            commitments: [],
            instalments: [],
            income: [],
            debts: [],
            accounts: [],
            incomeSources: [],
            entryOptions: EntryOptions(accounts: [], categories: [], defaultAccountID: nil)
        )
    }

    /// The reconciliation layer, attached after the forecast has been mapped.
    /// Kept separate because it is the only part of the snapshot that reads
    /// stored answers rather than a projection.
    func withReconciliation(
        expectedPayments: [ExpectedPayment],
        reconciliations: [String: ReconciliationSummary]
    ) -> FinanceAppSnapshot {
        var copy = self
        copy.expectedPayments = expectedPayments
        copy.reconciliations = reconciliations
        return copy
    }

    /// Expected payments still awaiting an answer, soonest first — the
    /// reconciliation to-do list.
    var unresolvedExpectedPayments: [ExpectedPayment] {
        expectedPayments.filter { !$0.isResolved }
    }

    /// Ones whose day has passed with nothing matched. Shown as questions, not
    /// as failures and not as payments.
    var overdueExpectedPayments: [ExpectedPayment] {
        expectedPayments.filter { $0.status == .overdue }
    }

    var unreviewedSyncedObservations: [SyncedObservationItem] {
        syncedObservations.filter { $0.resolution == .unreviewed }
    }

    /// Only provisional rows named by a successfully imported authoritative
    /// provider snapshot. Historical provisional evidence remains retained in
    /// `syncedObservations` but is deliberately absent here.
    var currentPendingSyncedObservations: [SyncedObservationItem] {
        let currentIDs = Set(currentPendingProviderSnapshots.flatMap(\.observationIDs))
        return syncedObservations.filter {
            currentIDs.contains($0.id)
                && $0.resolution == .provisional
                && $0.status == .pending
                && $0.isAccountBindingActive
        }
    }

    func withBanking(_ banking: DomainMapper.BankingSurface) -> FinanceAppSnapshot {
        var copy = self
        copy.syncedObservations = banking.observations
        copy.providerAccountBindings = banking.bindings
        copy.providerBalanceStatuses = banking.balances
        copy.trustedRules = banking.trustedRules
        copy.providerConnections = banking.connections
        copy.mappableRemoteAccounts = banking.remoteAccounts
        copy.currentPendingProviderSnapshots = banking.pendingSnapshots
        return copy
    }
}

// MARK: - Scenario

/// How optimistic the projection on screen is allowed to be.
enum PlanScenario: String, Hashable, Sendable, CaseIterable, Identifiable {
    case guaranteed, base, upside

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .guaranteed: "Guaranteed"
        case .base: "Base"
        case .upside: "Upside"
        }
    }

    var explanation: String {
        switch self {
        case .guaranteed: "Only money already received or committed for a named date."
        case .base: "The operating plan. Adds income that is expected but not committed."
        case .upside: "Adds what is being pursued. For analysis — never the runway."
        }
    }
}

// MARK: - Holdings

enum HoldingKind: String, Hashable, Sendable {
    case bank, wallet, cash

    var symbolName: String {
        switch self {
        case .bank: "building.columns"
        case .wallet: "creditcard"
        case .cash: "banknote"
        }
    }

    var displayName: String {
        switch self {
        case .bank: "Bank"
        case .wallet: "Wallet"
        case .cash: "Cash"
        }
    }
}

/// One account and what it holds.
struct HoldingLine: Identifiable, Hashable, Sendable {
    let id: String
    /// What the user calls it — the institution when there is one.
    let title: String
    let subtitle: String
    let kind: HoldingKind
    let balance: Amount
    /// Whether this balance can meet an obligation in the home currency.
    let isSpendableHere: Bool
    /// For a foreign holding: what acquiring it cost in the home currency.
    /// Context only, never added to `accountCash`.
    let carriedAt: Amount?
    /// Spelled-out rails, because "can this account pay that" is the point of
    /// keeping rails on the model at all.
    let railLabels: [String]
}

// MARK: - Safe to spend

/// Which constraint decided `safeToSpend`, and the line shown under it.
enum SafeToSpendReason: Hashable, Sendable {
    case shortfall(Amount)
    case liquidity
    case budget
    case unconstrained

    var explanation: String {
        switch self {
        case .shortfall:
            "Committed payments exceed the money available. Nothing is free to spend."
        case .liquidity:
            "Limited by the cash that has to last until the next money arrives."
        case .budget:
            "Limited by what is left in this month's budget."
        case .unconstrained:
            "Within both the cash projection and the budget."
        }
    }

    var isShortfall: Bool {
        if case .shortfall = self { return true }
        return false
    }

    var shortfallAmount: Amount? {
        if case .shortfall(let amount) = self { return amount }
        return nil
    }
}

// MARK: - Risk

struct RiskPoint: Hashable, Sendable {
    let date: CalendarDay
    let projectedBalance: Amount
    /// The largest obligation landing that day — the thing to name on screen.
    let triggerLabel: String?
    let triggerAmount: Amount?
    /// Which kind of risk the projection reported, when this point is one.
    ///
    /// The engine decides this and the app carries it; nothing downstream may
    /// re-derive it from a balance, because "below zero" and "below the
    /// reserve you set" are different problems with different answers, and a
    /// positive balance can be either.
    ///
    /// `nil` where there is no classification to report — the same rule
    /// `shortfall` follows. A lowest point that is not the risk day has no
    /// kind, and must not borrow one.
    let kind: CashRiskKind?
    /// The magnitude the projection reported for this risk.
    ///
    /// **Its meaning depends on `kind`, and it is not "money that is
    /// missing".** For `.hardDeficit` it is the gap itself — the unsettled
    /// remainder of the payment that could not be met, or how far below zero
    /// the pool went. For `.reserveWarning` it is `reserve − projected pool`:
    /// a distance from a line the person chose, while every obligation is
    /// still being paid.
    ///
    /// Read it through `fundingDeficit` or `reserveGap` rather than directly.
    /// It was called `shortfall`, and a caller took it at its word: a person
    /// holding 300,00 € against a 450,00 € reserve, whose projection never
    /// went near zero, was told their balance was about to fall short.
    ///
    /// It travels with `date` because a sentence that names an amount and a
    /// day must take both from the same computation over the same horizon.
    /// `nil` where there is no risk to quantify — a lowest point that never
    /// went short has none, and must not borrow one.
    let riskAmount: Amount?
}

extension RiskPoint {

    /// Money that is actually missing, and nothing else.
    ///
    /// `nil` for a reserve breach and for an unclassified risk, so a caller
    /// that needs a funding deficit cannot silently receive a distance from a
    /// reserve instead. A sentence about being short has to come from here.
    var fundingDeficit: Amount? {
        kind == .hardDeficit ? riskAmount : nil
    }

    /// How far under the reserve the plan goes, and nothing else. `nil` for a
    /// genuine deficit, where the reserve is no longer the point.
    var reserveGap: Amount? {
        kind == .reserveWarning ? riskAmount : nil
    }
}

/// Which kind of cash risk the projection found.
///
/// The engine's own distinction, carried across the boundary rather than
/// recomputed: it is the difference between money running out and a buffer
/// being spent into, and only one of them means a person has to find money.
///
/// Named for the two states the affordability surface already speaks about in
/// exactly these terms, so the app has one vocabulary for one distinction.
enum CashRiskKind: String, Hashable, Sendable {
    /// Projected spendable cash goes below zero. There is a genuine gap.
    case hardDeficit
    /// Cash stays above zero but falls under the safety reserve on the plan.
    /// Still funded; the margin is what is being consumed.
    case reserveWarning
}

/// How long the money lasts.
enum CashRunway: Hashable, Sendable {
    /// Nothing goes negative inside the horizon.
    case clear(horizonDays: Int)
    case endsIn(days: Int)

    var daysRemaining: Int? {
        if case .endsIn(let days) = self { return days }
        return nil
    }

    var isClear: Bool {
        if case .clear = self { return true }
        return false
    }
}

struct RunwayPoint: Identifiable, Hashable, Sendable {
    var id: CalendarDay { date }
    let date: CalendarDay
    let balance: Amount
}

// MARK: - Planned events

/// A dated amount that has not happened yet.
struct PlannedEvent: Identifiable, Hashable, Sendable {
    let id: String
    let date: CalendarDay
    let label: String
    /// Signed for display: negative for an obligation.
    let amount: Amount
    let isInflow: Bool
    /// Money that is committed for a named date but has not arrived. Shown
    /// differently from money already in an account, because it is not.
    let isGuaranteedButNotReceived: Bool
    /// Set when the inflow is less than certain — a procedure under way, a job
    /// being looked for. `nil` for obligations and for guaranteed money.
    let certaintyLabel: String?
    /// Clearing old arrears, kept out of everyday life.
    let isRecovery: Bool
    let hasApproximateDate: Bool
    let note: String?
}

// MARK: - Months

/// A calendar month as an identity. Carries its own first day so no screen has
/// to do calendar arithmetic to render a header.
struct CalendarMonth: Hashable, Sendable, Comparable, CustomStringConvertible {
    let year: Int
    let month: Int
    let firstDay: CalendarDay

    init(year: Int, month: Int, firstDay: CalendarDay) {
        self.year = year
        self.month = month
        self.firstDay = firstDay
    }

    static func == (a: CalendarMonth, b: CalendarMonth) -> Bool {
        a.year == b.year && a.month == b.month
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(year)
        hasher.combine(month)
    }

    static func < (a: CalendarMonth, b: CalendarMonth) -> Bool {
        (a.year, a.month) < (b.year, b.month)
    }

    var description: String {
        String(CalendarDay(year: year, month: month, day: 1).description.dropLast(3))
    }
}

/// One month of the plan.
///
/// The five money fields are one arithmetic model, taken from the one grouping
/// that provably accounts for every euro that moved:
///
/// ```
/// opening + plannedIncome − committedSpending − everydaySpending == closing
/// ```
///
/// That identity is the reason `plannedSpending` is derived rather than
/// stored: a summary whose rows do not reach its own bottom line is a summary
/// with a phase hidden behind it.
struct MonthProjection: Identifiable, Hashable, Sendable {
    var id: CalendarMonth { month }
    let month: CalendarMonth
    let opening: Amount
    /// Positive. Net: income arriving, own money moved in, shares handed on —
    /// so a pass-through that lands gross and gives most of it back
    /// contributes only the part that was kept.
    let plannedIncome: Amount
    /// Positive. Scheduled, committed charges: the payments already promised
    /// to a date.
    let committedSpending: Amount
    /// Positive. Everyday spending planned out of the budget's own envelopes,
    /// after what those envelopes have already promised to a committed
    /// payment. Never the gross envelope.
    let everydaySpending: Amount
    /// Positive. Rendered negated where the sign is wanted.
    var plannedSpending: Amount { committedSpending + everydaySpending }
    let closing: Amount
    /// What the rows on screen add up to. Equal to `closing` — see the type's
    /// own documentation for why that is not a coincidence to be checked but a
    /// property to be relied on.
    var reconciledClosing: Amount { opening + plannedIncome - plannedSpending }
    /// EUR the month needs beyond what is planned. Reported, never closed
    /// with an invented transfer. Foreign shortfalls are kept separately;
    /// neither collection is converted into the other.
    let unfundedEUR: Amount?
    /// Non-EUR settlement failures, one exact amount per currency, sorted by
    /// ISO code. Never added to the EUR headline.
    let unfundedInOtherCurrencies: [Amount]
    /// The events denominated in the plan's own currency — the ones the totals
    /// above are made of.
    let events: [PlannedEvent]
    /// Events landing in this month in some other currency.
    ///
    /// They are listed, never converted and never added in: the plan has no
    /// rate, and a projection that invents one is a projection about a number
    /// nobody committed to. Converting is its own dated event.
    let eventsInOtherCurrencies: [PlannedEvent]

    init(
        month: CalendarMonth,
        opening: Amount,
        plannedIncome: Amount,
        committedSpending: Amount,
        everydaySpending: Amount,
        closing: Amount,
        unfundedEUR: Amount?,
        unfundedInOtherCurrencies: [Amount] = [],
        events: [PlannedEvent],
        eventsInOtherCurrencies: [PlannedEvent] = []
    ) {
        self.month = month
        self.opening = opening
        self.plannedIncome = plannedIncome
        self.committedSpending = committedSpending
        self.everydaySpending = everydaySpending
        self.closing = closing
        self.unfundedEUR = unfundedEUR
        self.unfundedInOtherCurrencies = unfundedInOtherCurrencies
        self.events = events
        self.eventsInOtherCurrencies = eventsInOtherCurrencies
    }
}

// MARK: - Budget

struct BudgetLine: Identifiable, Hashable, Sendable {
    var id: String { key }
    let key: String
    let name: String
    let symbolName: String
    /// This month's target for the line.
    let limit: Amount
    /// Economic spending attributed to it, net of refunds.
    let spent: Amount
    /// Committed charges linked to this line that are still owed this month.
    let committed: Amount
    /// `limit - spent`. Signed: an overspent line says so.
    let remaining: Amount
    /// What is left once the commitments still owed are honoured.
    let remainingAfterCommitted: Amount
    /// 0...1, clamped so an overspent bar fills rather than overflows.
    let fraction: Double
    /// The same ratio unclamped, so "180% of groceries" stays sayable.
    let rawFraction: Double
    let isOverspent: Bool
    let isHousing: Bool
    /// Whether this target is still only a proposal awaiting a decision.
    let isSuggested: Bool
    /// What may still be spent per day and per week without breaching the
    /// line. `nil` outside the current month.
    let dailyPace: Amount?
    let weeklyPace: Amount?
    let spendingClass: BudgetSpendingClass
}

/// The month-level budget figure, with the comparisons already made.
struct BudgetSummary: Hashable, Sendable {
    /// The figure spending is measured against: the gross ceiling when the
    /// plan states one, otherwise the sum of the lines.
    let limit: Amount
    let spent: Amount
    /// Never negative — what is left of `limit` after spending.
    let remaining: Amount
    /// Charges already promised this month and not yet gone.
    let committed: Amount
    /// What may still be spent without breaching `limit`, commitments
    /// honoured. Budget headroom, never account liquidity.
    let safeToSpend: Amount
    let fraction: Double
    let isOverspent: Bool
    /// Past the point where the bar should start warning.
    let isNearLimit: Bool
    /// The gross ceiling, when the plan states one. `limit` falls back to the
    /// allocated total without it, and this stays nil so the screens can tell
    /// the two apart.
    let ceiling: Amount?

    static func none(currencyCode: String) -> BudgetSummary {
        let zero = Amount.zero(currencyCode)
        return BudgetSummary(
            limit: zero, spent: zero, remaining: zero, committed: zero,
            safeToSpend: zero, fraction: 0, isOverspent: false,
            isNearLimit: false, ceiling: nil
        )
    }

    var isEmpty: Bool { limit.isZero && spent.isZero }

    /// The figure the month card leads with: what is still safe to spend.
    var headlineAmount: Amount { safeToSpend }

    var headlineCaption: String { "left of \(limit.formatted()) this month" }
}

/// The whole month's budget, as the Plan screen reads it.
struct BudgetOverview: Hashable, Sendable {
    let monthLabel: String
    let summary: BudgetSummary
    /// Sum of the lines in effect this month. Distinct from the ceiling.
    let target: Amount
    /// `ceiling - target`: the part of the ceiling no line has claimed. `nil`
    /// without a ceiling.
    let unallocated: Amount?
    /// Economic spending no line claims. Counted in the total, and named here
    /// so it is never quietly dropped.
    let uncategorized: Amount
    /// Repayments of financed purchases: cash out, no new consumption. Kept
    /// out of spending and shown so the month's cash pressure stays visible.
    let financingRepayments: Amount
    let daysInMonth: Int
    let daysElapsed: Int
    let daysRemaining: Int
    let isCurrentMonth: Bool
    let lines: [BudgetLine]
    /// Lines budgeted in another currency. Shown, never summed into the euro
    /// totals above: there is no rate here to convert them with.
    let otherCurrencyLines: [BudgetLine]

    /// True when every line is still only a proposal.
    var isEntirelySuggested: Bool {
        !lines.isEmpty && lines.allSatisfy(\.isSuggested)
    }

    var hasSuggestedLines: Bool { lines.contains(where: \.isSuggested) }

    static func none(currencyCode: String, monthLabel: String = "") -> BudgetOverview {
        let zero = Amount.zero(currencyCode)
        return BudgetOverview(
            monthLabel: monthLabel,
            summary: .none(currencyCode: currencyCode),
            target: zero,
            unallocated: nil,
            uncategorized: zero,
            financingRepayments: zero,
            daysInMonth: 0,
            daysElapsed: 0,
            daysRemaining: 0,
            isCurrentMonth: false,
            lines: [],
            otherCurrencyLines: []
        )
    }
}

// MARK: - Activity

/// What a row *is*, economically — so a filter can mean something other than
/// the sign on the statement.
enum ActivityFlow: String, Hashable, Sendable {
    case spending, income, movement, neutral
}

struct ActivityRow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let symbolName: String
    /// Signed for display.
    let amount: Amount
    /// The other leg, a reversal, or a pending marker.
    let trailingNote: String?
    /// Set only when part of the amount was never the owner's: €1,000 arriving
    /// with €600 owed onward is €400 of income, and a row that prints the gross
    /// figure without saying so claims otherwise.
    let ownedPortion: Amount?
    let isReversed: Bool
    let isPending: Bool
    let flow: ActivityFlow
    let primaryAccountID: String?
    let primaryAccountLabel: String?
    let secondaryAccountID: String?
    let secondaryAccountLabel: String?
    let incomeSourceID: String?
    let incomeSourceLabel: String?
    let categoryLabel: String?
    let counterparty: String?
    let transactionTypeLabel: String
    let note: String?
    /// Everything a search should match, already joined.
    let searchText: String

    init(
        id: String,
        title: String,
        subtitle: String,
        symbolName: String,
        amount: Amount,
        trailingNote: String?,
        ownedPortion: Amount?,
        isReversed: Bool,
        isPending: Bool,
        flow: ActivityFlow,
        primaryAccountID: String? = nil,
        primaryAccountLabel: String? = nil,
        secondaryAccountID: String? = nil,
        secondaryAccountLabel: String? = nil,
        incomeSourceID: String? = nil,
        incomeSourceLabel: String? = nil,
        categoryLabel: String? = nil,
        counterparty: String? = nil,
        transactionTypeLabel: String = "Transaction",
        note: String? = nil,
        searchText: String
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.amount = amount
        self.trailingNote = trailingNote
        self.ownedPortion = ownedPortion
        self.isReversed = isReversed
        self.isPending = isPending
        self.flow = flow
        self.primaryAccountID = primaryAccountID
        self.primaryAccountLabel = primaryAccountLabel
        self.secondaryAccountID = secondaryAccountID
        self.secondaryAccountLabel = secondaryAccountLabel
        self.incomeSourceID = incomeSourceID
        self.incomeSourceLabel = incomeSourceLabel
        self.categoryLabel = categoryLabel
        self.counterparty = counterparty
        self.transactionTypeLabel = transactionTypeLabel
        self.note = note
        self.searchText = searchText
    }

    var accountIDs: Set<String> {
        Set([primaryAccountID, secondaryAccountID].compactMap { $0 })
    }

    var accountMovementLabel: String? {
        guard let primaryAccountLabel else { return nil }
        guard let secondaryAccountLabel else { return primaryAccountLabel }
        return "\(primaryAccountLabel) → \(secondaryAccountLabel)"
    }
}

struct ActivityDay: Identifiable, Hashable, Sendable {
    var id: CalendarDay { date }
    let date: CalendarDay
    /// Net movement across the day in the home currency.
    let net: Amount
    let rows: [ActivityRow]
}

// MARK: - Commitments, instalments, income, debts

struct CommitmentLine: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let amount: Amount
    let cadenceLabel: String
    /// `nil` while the commitment is simply active.
    let statusLabel: String?
    /// Whether it takes cash on its next date.
    let chargesCashNow: Bool
}

struct CommitmentGroup: Identifiable, Hashable, Sendable {
    var id: String { title }
    let title: String
    let lines: [CommitmentLine]
}

struct InstalmentLine: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let provider: String
    let remaining: Amount
    let paidCount: Int
    let totalCount: Int
    let nextDueDate: CalendarDay?
}

struct IncomeLine: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let amount: Amount
    let note: String?
    /// Its certainty is capped by something else's.
    let dependsOnAnother: Bool
}

struct IncomeGroup: Identifiable, Hashable, Sendable {
    var id: String { title }
    let title: String
    /// Why the level matters, shown so a number is never read as cash in hand.
    let explanation: String
    let lines: [IncomeLine]
}

struct DebtLine: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let creditor: String?
    let outstanding: Amount
    let monthlyRepayment: Amount
    let monthsToClear: Int?
    let note: String?
}

// MARK: - Entry

/// One user-managed account, including inactive accounts retained for history.
struct AccountSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: HoldingKind
    let currencyCode: String
    let fractionDigits: Int
    let balance: Amount
    let balanceAsOf: CalendarDay
    let isActive: Bool
    let railLabels: [String]

    var secondaryLabel: String { "\(kind.displayName) · \(currencyCode)" }
}

enum IncomeCertaintyOption: String, CaseIterable, Identifiable, Hashable, Sendable {
    case received, guaranteed, expected, target, possible

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }
}

struct IncomeSourceSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let certainty: IncomeCertaintyOption
    let recurrenceLabel: String
    let amount: Amount
    let isActive: Bool
    let preferredAccountID: String?
    let preferredAccountName: String?
    let note: String?
}

struct AccountOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: HoldingKind
    let currencyCode: String
    /// Digits in this account's minor unit — 2 for EUR, 0 for JPY, 3 for KWD.
    /// Entry reads the scale of a typed figure from here, never from a
    /// constant.
    let fractionDigits: Int

    init(
        id: String,
        name: String,
        kind: HoldingKind = .bank,
        currencyCode: String,
        fractionDigits: Int = 2
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.currencyCode = currencyCode
        self.fractionDigits = fractionDigits
    }

    var secondaryLabel: String { "\(kind.displayName) · \(currencyCode)" }
}

struct IncomeSourceOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let preferredAccountID: String?
}

struct CategoryOption: Identifiable, Hashable, Sendable {
    var id: String { key }
    let key: String
    let name: String
    let symbolName: String
    /// Offered for income rather than for spending.
    let isIncome: Bool
    /// Offered for neither — the engine assigns it.
    let isTransfer: Bool
}

/// What the entry sheet needs in order to build a draft.
struct EntryOptions: Hashable, Sendable {
    let accounts: [AccountOption]
    let incomeSources: [IncomeSourceOption]
    let categories: [CategoryOption]
    let defaultExpenseAccountID: String?
    let defaultIncomeAccountID: String?

    /// Compatibility spelling for older facade callers. New entry code uses
    /// the flow-specific defaults above.
    var defaultAccountID: String? { defaultExpenseAccountID }

    init(
        accounts: [AccountOption],
        incomeSources: [IncomeSourceOption] = [],
        categories: [CategoryOption],
        defaultAccountID: String? = nil,
        defaultExpenseAccountID: String? = nil,
        defaultIncomeAccountID: String? = nil
    ) {
        self.accounts = accounts
        self.incomeSources = incomeSources
        self.categories = categories
        self.defaultExpenseAccountID = defaultExpenseAccountID ?? defaultAccountID
        self.defaultIncomeAccountID = defaultIncomeAccountID
    }

    func account(_ id: String?) -> AccountOption? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    func incomeSource(_ id: String?) -> IncomeSourceOption? {
        guard let id else { return nil }
        return incomeSources.first { $0.id == id }
    }

    /// Where a plain transfer out of `sourceID` can actually land: another
    /// account holding the same currency. A euro balance moved into a dirham
    /// account is an exchange at some rate, and no rate has been stated, so
    /// that combination is not offered rather than offered and then refused.
    func transferDestinations(from sourceID: String?) -> [AccountOption] {
        guard let source = account(sourceID) else { return [] }
        return accounts.filter { $0.id != source.id && $0.currencyCode == source.currencyCode }
    }
}

// MARK: - Phase 2.4D: live sync surface

extension FinanceAppSnapshot {
    /// Provider connections and mappable remote accounts describe the sync
    /// service, not this person's finances, so they ride on the snapshot rather
    /// than the document and disappear when the app is offline and restarted.
    var connectedProviderCount: Int {
        providerConnections.filter { $0.state == .connected }.count
    }

    var providerConnectionsNeedingAttention: [ProviderConnectionStatus] {
        providerConnections.filter { $0.state.needsAttention }
    }

    /// Observations whose economic resolution now disagrees with what the bank
    /// currently reports. Surfaced, never auto-corrected.
    var observationsWithProviderWarning: [SyncedObservationItem] {
        syncedObservations.filter(\.hasProviderStatusWarning)
    }
}
