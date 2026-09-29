/// Closed vocabularies and ephemeral request/result types for a period review.
///
/// These are **not** persisted. They are not `FinanceDocument` fields. Same
/// request → same result; the engine never reads the wall clock.

// MARK: - Failure

/// Why a period review could not be produced.
///
/// Deliberately one case. A review either states the period's economics
/// truthfully or reports that it could not compute them; it never returns a
/// clean, zero, or shortened result standing in for a calculation that did
/// not happen.
public enum ReviewError: Error, Hashable, Sendable {
    /// A date the review required — the interval's length, the previous
    /// comparable period, or the outlook horizon — lies outside the range an
    /// `Int` day ordinal can express.
    case dateArithmeticOutOfRange
}

// MARK: - Period

public enum ReviewPeriodKind: String, Sendable, Hashable, Codable {
    case weekly
    case monthly
}

/// Inclusive civil-day interval. Callers supply the dates; the engine never
/// asks `Date()`.
public struct ReviewInterval: Hashable, Sendable {

    public let start: Day
    public let end: Day

    public init(start: Day, end: Day) {
        self.start = start
        self.end = end
    }

    /// True when the interval covers no days at all. Exact at every structural
    /// year: it is an ordering question, never an arithmetic one.
    public var isEmpty: Bool { start > end }

    /// Inclusive day count, or nil when the span is wider than `Int` can
    /// express. An empty interval counts 0 rather than failing.
    public var dayCount: Int? {
        guard start <= end else { return 0 }
        guard let distance = start.days(until: end) else { return nil }
        let (count, overflow) = distance.addingReportingOverflow(1)
        return overflow ? nil : count
    }

    public func contains(_ day: Day) -> Bool {
        day >= start && day <= end
    }

    public static func month(_ month: MonthKey) -> ReviewInterval {
        ReviewInterval(start: month.firstDay, end: month.firstDay.lastDayOfMonth)
    }

    /// Seven inclusive days starting on `start`. The caller chooses the week
    /// origin (Monday, Sunday, …); FinanceCore does not.
    ///
    /// Nil when fewer than seven days remain in the structural domain: a
    /// six-day "week" would be a different period than the one asked for.
    public static func weekStarting(_ start: Day) -> ReviewInterval? {
        guard let end = start.advanced(by: 6) else { return nil }
        return ReviewInterval(start: start, end: end)
    }

    /// Calendar months touched by this interval, ascending.
    public var monthKeys: [MonthKey] {
        guard start <= end else { return [] }
        var month = start.monthKey
        var result: [MonthKey] = []
        while month <= end.monthKey {
            result.append(month)
            // The final requested month is complete; advancing past it would
            // ask for a month that need not exist.
            guard month < end.monthKey, let following = month.next else { break }
            month = following
        }
        return result
    }

    /// The immediately previous comparable interval: prior calendar month for
    /// a full-month monthly review, otherwise the same length ending the day
    /// before `start`.
    ///
    /// Nil when that period lies outside the structural day domain, or when
    /// this interval's own length cannot be expressed. A comparison against a
    /// period that cannot be constructed is unavailable, never a shorter one.
    public func previous(kind: ReviewPeriodKind) -> ReviewInterval? {
        switch kind {
        case .monthly where start == start.monthKey.firstDay && end == start.lastDayOfMonth:
            return start.monthKey.previous.map(ReviewInterval.month)
        case .weekly, .monthly:
            guard let count = dayCount else { return nil }
            let length = max(count, 1)
            guard let newEnd = start.advanced(by: -1),
                  let newStart = newEnd.advanced(by: 1 - length)
            else { return nil }
            return ReviewInterval(start: newStart, end: newEnd)
        }
    }

    func intersection(with other: ReviewInterval) -> ReviewInterval? {
        let lo = start > other.start ? start : other.start
        let hi = end < other.end ? end : other.end
        guard lo <= hi else { return nil }
        return ReviewInterval(start: lo, end: hi)
    }
}

// MARK: - Coverage input

/// Affirmative evidence about whether the requested interval is covered.
///
/// Completeness is fail-closed. Omitting history, cutoff, gaps, or live
/// coverage is **not** evidence that the interval is complete. `complete`
/// requires an affirmative source for every day.
public struct ReviewCoverageInput: Hashable, Sendable {

    /// Inclusive archive/live boundary. When nil, the history document's
    /// `archiveCutoff` is used if history is present; otherwise the engine
    /// cannot split archive from live.
    public var archiveCutoff: Day?

    /// Historical archive. Required for any archive-era day to be complete.
    public var history: FinanceHistoryDocument?

    /// Days the **live** ledger is known to cover. Empty means no affirmative
    /// live coverage. These ranges never complete archive-era days.
    public var liveCoveredIntervals: [ReviewInterval]

    /// Extra source gaps. Missing periods are never treated as zero activity.
    public var additionalSourceGaps: [FinanceHistorySourceGap]

    public init(
        archiveCutoff: Day? = nil,
        history: FinanceHistoryDocument? = nil,
        liveCoveredIntervals: [ReviewInterval] = [],
        additionalSourceGaps: [FinanceHistorySourceGap] = []
    ) {
        self.archiveCutoff = archiveCutoff
        self.history = history
        self.liveCoveredIntervals = liveCoveredIntervals
        self.additionalSourceGaps = additionalSourceGaps
    }

    /// No coverage evidence at all. Named `absent` so it cannot be written as
    /// `.none` and collide with `Optional.none`.
    public static var absent: ReviewCoverageInput { ReviewCoverageInput() }

    public static func liveCovered(
        _ intervals: [ReviewInterval],
        cutoff: Day? = nil,
        history: FinanceHistoryDocument? = nil,
        additionalSourceGaps: [FinanceHistorySourceGap] = []
    ) -> ReviewCoverageInput {
        ReviewCoverageInput(
            archiveCutoff: cutoff,
            history: history,
            liveCoveredIntervals: intervals,
            additionalSourceGaps: additionalSourceGaps
        )
    }

    public var resolvedArchiveCutoff: Day? {
        archiveCutoff ?? history?.payload.archiveCutoff
    }
}

// MARK: - Finding policy

/// Inspectable thresholds for *named* findings. Raw deltas are always
/// returned; these rules only gate findings that claim significance.
///
/// Amounts are integer minor units of the review currency. The standard
/// policy is calibrated for euro cents (`2500` = €25.00).
public struct ReviewFindingPolicy: Hashable, Sendable {

    /// Minimum |Δ| for `spendingMateriallyHigher/LowerThanPrior`.
    public let materialSpendingAbsoluteMinorUnits: Int64
    /// Minimum |basis points| for that finding when a prior amount exists.
    /// Both the absolute and relative tests must pass. Ignored when prior is 0.
    public let materialSpendingBasisPoints: Int
    /// Minimum prior line amount before `unusuallyHighCategory` may fire.
    public let unusualCategoryMinimumPriorMinorUnits: Int64
    /// Current must be at least this integer multiple of prior.
    public let unusualCategoryMultiple: Int
    /// Minimum absolute increase for `unusuallyHighCategory`.
    public let unusualCategoryAbsoluteMinorUnits: Int64
    /// Minimum amount for `majorExceptionalPurchase`. Smaller exceptional
    /// purchases stay in the budget breakdown without that finding.
    public let majorExceptionalMinorUnits: Int64

    public init(
        materialSpendingAbsoluteMinorUnits: Int64,
        materialSpendingBasisPoints: Int,
        unusualCategoryMinimumPriorMinorUnits: Int64,
        unusualCategoryMultiple: Int,
        unusualCategoryAbsoluteMinorUnits: Int64,
        majorExceptionalMinorUnits: Int64
    ) {
        self.materialSpendingAbsoluteMinorUnits = materialSpendingAbsoluteMinorUnits
        self.materialSpendingBasisPoints = materialSpendingBasisPoints
        self.unusualCategoryMinimumPriorMinorUnits = unusualCategoryMinimumPriorMinorUnits
        self.unusualCategoryMultiple = unusualCategoryMultiple
        self.unusualCategoryAbsoluteMinorUnits = unusualCategoryAbsoluteMinorUnits
        self.majorExceptionalMinorUnits = majorExceptionalMinorUnits
    }

    /// Standard euro-cent policy. Documented in DOMAIN.md §11.
    ///
    /// - material spending: |Δ| ≥ €25 **and** |Δ| ≥ 20% of prior (absolute
    ///   only when prior is 0)
    /// - unusually high category: prior ≥ €20, current ≥ 2× prior, |Δ| ≥ €25
    /// - major exceptional purchase: amount ≥ €100
    public static let standard = ReviewFindingPolicy(
        materialSpendingAbsoluteMinorUnits: 2_500,
        materialSpendingBasisPoints: 2_000,
        unusualCategoryMinimumPriorMinorUnits: 2_000,
        unusualCategoryMultiple: 2,
        unusualCategoryAbsoluteMinorUnits: 2_500,
        majorExceptionalMinorUnits: 10_000
    )
}

// MARK: - Request

/// Ephemeral review input. Not stored on `FinanceDocument`.
public struct ReviewRequest: Hashable, Sendable {

    public var document: FinanceDocument
    public var kind: ReviewPeriodKind
    public var interval: ReviewInterval

    /// As-of day for due/overdue, forecast, and "today" in the monthly budget
    /// engine. Never defaulted from the wall clock. Independent of `interval`:
    /// a June close read in August uses June as the period and August as the
    /// outlook.
    public var asOf: Day

    public var currency: Currency
    public var categoryKeys: [String: String]
    public var comparePreviousPeriod: Bool
    public var coverage: ReviewCoverageInput

    /// Explicit spending nature keyed by transaction or historical id.
    /// Exceptional is **only** assigned from this map; amount never infers it.
    public var spendingNatures: [String: ReviewSpendingNature]

    /// Explicit income class keyed by transaction id **or** `incomeSourceID`.
    public var incomeClasses: [String: ReviewIncomeClass]

    /// Canonical `economicSource` tokens keyed by transaction id or
    /// `incomeSourceID`. Vocabulary is the history/incoming-resource ledger
    /// (`PARENTAL_SUPPORT_SELF`, `EARNED_EMPLOYMENT`, …). Unknown tokens do
    /// not classify.
    public var economicSources: [String: String]

    public var findingPolicy: ReviewFindingPolicy

    /// Forecast horizon end. nil → `asOf + 30` days.
    public var forecastHorizonEnd: Day?

    public init(
        document: FinanceDocument,
        kind: ReviewPeriodKind,
        interval: ReviewInterval,
        asOf: Day,
        currency: Currency = .eur,
        categoryKeys: [String: String] = [:],
        comparePreviousPeriod: Bool = false,
        coverage: ReviewCoverageInput = .absent,
        spendingNatures: [String: ReviewSpendingNature] = [:],
        incomeClasses: [String: ReviewIncomeClass] = [:],
        economicSources: [String: String] = [:],
        findingPolicy: ReviewFindingPolicy = .standard,
        forecastHorizonEnd: Day? = nil
    ) {
        self.document = document
        self.kind = kind
        self.interval = interval
        self.asOf = asOf
        self.currency = currency
        self.categoryKeys = categoryKeys
        self.comparePreviousPeriod = comparePreviousPeriod
        self.coverage = coverage
        self.spendingNatures = spendingNatures
        self.incomeClasses = incomeClasses
        self.economicSources = economicSources
        self.findingPolicy = findingPolicy
        self.forecastHorizonEnd = forecastHorizonEnd
    }

    public var resolvedArchiveCutoff: Day? { coverage.resolvedArchiveCutoff }

    /// The outlook horizon this review runs to.
    ///
    /// Nil when no explicit end was supplied and the default 30-day horizon
    /// leaves the structural day domain. A shortened horizon would be a
    /// different question than the one asked.
    public var resolvedForecastEnd: Day? {
        guard let requested = forecastHorizonEnd ?? asOf.advanced(by: 30) else { return nil }
        return requested < asOf ? asOf : requested
    }
}

// MARK: - Coverage result

public enum ReviewCoverageStatus: String, Sendable, Hashable, Codable {
    case complete
    case partial
    case insufficient
}

public enum ReviewCoverageReasonKind: String, Sendable, Hashable, Codable {
    case coverageMetadataAbsent
    case archiveHistoryAbsent
    case missingArchiveInterval
    case missingLiveInterval
    case sourceGap
}

public struct ReviewCoverageReason: Hashable, Sendable {
    public let kind: ReviewCoverageReasonKind
    public let interval: ReviewInterval?
    public let startMonth: MonthKey?
    public let endMonth: MonthKey?
    public let completeness: String?
    public let affectedSources: [String]

    public init(
        kind: ReviewCoverageReasonKind,
        interval: ReviewInterval? = nil,
        startMonth: MonthKey? = nil,
        endMonth: MonthKey? = nil,
        completeness: String? = nil,
        affectedSources: [String] = []
    ) {
        self.kind = kind
        self.interval = interval
        self.startMonth = startMonth
        self.endMonth = endMonth
        self.completeness = completeness
        self.affectedSources = affectedSources
    }
}

public struct ReviewCoverage: Hashable, Sendable {
    public let status: ReviewCoverageStatus
    public let reasons: [ReviewCoverageReason]
    public let missingIntervals: [ReviewInterval]
    public let archiveCutoff: Day?
    public let usedArchive: Bool
    public let usedLive: Bool

    public var isComplete: Bool { status == .complete }
}

// MARK: - Spending / income classes

public enum ReviewSpendingNature: String, Sendable, Hashable, Codable {
    case ordinaryRecurring
    case ordinaryVariable
    case exceptional
    case unresolved
}

public enum ReviewIncomeClass: String, Sendable, Hashable, Codable {
    case parentalSupport
    case earnedOrOther
    case reimbursement
    case passThrough
    case internalMovement
    case unresolved
}

/// Maps the canonical incoming-resource / history `economicSource` vocabulary
/// onto review income classes. Tokens not in this table do not classify.
public enum ReviewEconomicSourceClass {

    public static func incomeClass(for token: String) -> ReviewIncomeClass? {
        switch token {
        case "PARENTAL_SUPPORT_SELF", "PARTNER_SUPPORT":
            return .parentalSupport
        case "PARENTAL_SUPPORT_OTHER_PERSON_PASSTHROUGH", "PASS_THROUGH_OTHER":
            return .passThrough
        case "EARNED_EMPLOYMENT", "EARNED_INTERNSHIP", "EARNED_FREELANCING":
            return .earnedOrOther
        case "SHARED_EXPENSE_REIMBURSEMENT", "OTHER_REIMBURSEMENT":
            return .reimbursement
        case "INTERNAL_TRANSFER", "CASH_REDEPOSIT":
            return .internalMovement
        case "UNRESOLVED_INCOMING":
            return .unresolved
        default:
            return nil
        }
    }
}

public struct ReviewTotals: Hashable, Sendable {
    public let currency: Currency
    public let economicSpending: Money
    public let refunds: Money
    public let netEconomicSpending: Money
    public let personalIncome: Money
    public let passThroughNotMine: Money
    public let financingRepayments: Money
    public let internalTransfers: Money

    public init(
        currency: Currency,
        economicSpending: Money,
        refunds: Money,
        netEconomicSpending: Money,
        personalIncome: Money,
        passThroughNotMine: Money,
        financingRepayments: Money,
        internalTransfers: Money
    ) {
        self.currency = currency
        self.economicSpending = economicSpending
        self.refunds = refunds
        self.netEconomicSpending = netEconomicSpending
        self.personalIncome = personalIncome
        self.passThroughNotMine = passThroughNotMine
        self.financingRepayments = financingRepayments
        self.internalTransfers = internalTransfers
    }
}

public struct ReviewSpendingDriver: Identifiable, Hashable, Sendable {
    public let id: String
    public let date: Day
    public let amount: Money
    public let nature: ReviewSpendingNature
    public let budgetID: String?
}

public struct ReviewBudgetLine: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let spendingClass: SpendingClass
    public let target: Money
    public let periodSpent: Money
    public let isOverspent: Bool
}

/// One calendar month's budget, as it applies inside a review interval.
///
/// `periodSpendingInMonth` is only the review-interval days that fall in
/// this month. `monthSpending` / `remaining` / `overage` are the **month**
/// against its ceiling — never a prorated weekly ceiling.
public struct ReviewMonthlyBudgetContext: Hashable, Sendable {
    public let month: MonthKey
    public let intervalInMonth: ReviewInterval
    public let ceiling: Money?
    public let monthSpending: Money
    public let periodSpendingInMonth: Money
    public let committed: Money
    public let remaining: Money?
    public let overage: Money?
    public let uncategorized: Money
    public let lines: [ReviewBudgetLine]
    /// The records behind `monthSpending` — the whole calendar month, not
    /// only the reviewed slice — each with the net amount it contributed.
    /// Rows that contributed nothing are omitted, so the amounts sum exactly
    /// to `monthSpending`.
    public let contributions: [ReviewSpendingDriver]
}

public struct ReviewBudget: Hashable, Sendable {
    public let periodEconomicSpending: Money
    /// The existing monthly engine's resolved live-period rows, including
    /// refund inheritance/suppression and settlement precedence. Exposed for
    /// semantic consumers; never reconstructed from display drivers (which
    /// intentionally omit refunds and zero effects).
    public let attributions: [MonthlyBudgetEngine.Attribution]
    public let monthlyContexts: [ReviewMonthlyBudgetContext]
    public let uncategorized: Money
    public let financingRepayments: Money
    public let drivers: [ReviewSpendingDriver]
    /// Every record the review counted, each with the exact net amount it
    /// contributed, in date order. Unlike `drivers`, refund-reduced and
    /// negative rows are included, because they move the totals too; rows
    /// that contributed nothing are omitted.
    ///
    /// The amounts sum to `periodEconomicSpending`, and the rows attributed
    /// to a budget line inside a month's slice sum to that line's
    /// `periodSpent`. Output plumbing only: read from the same per-row
    /// resolution the totals use, never computed a second way.
    public let contributions: [ReviewSpendingDriver]
    public let ordinaryRecurring: Money
    public let ordinaryVariable: Money
    public let exceptional: Money
    public let unresolvedNature: Money
}

public struct ReviewIncome: Hashable, Sendable {
    public let personalIncome: Money
    public let parentalSupportGross: Money
    public let parentalSupportOwned: Money
    public let earnedOrOther: Money
    public let reimbursements: Money
    public let passThroughGross: Money
    public let passThroughOwned: Money
    public let passThroughNotMine: Money
    public let internalMovement: Money
    public let unresolved: Money
}

// MARK: - Expected vs actual

public enum ReviewExpectationStatus: String, Sendable, Hashable, Codable {
    case expected
    case matched
    case missed
    case skipped
    case noLongerDue
}

public struct ReviewExpectation: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let expectedDay: Day
    public let expectedAmount: Money
    public let actualAmount: Money?
    public let actualTransactionID: String?
    public let status: ReviewExpectationStatus
}

public struct ReviewExpectations: Hashable, Sendable {
    public let items: [ReviewExpectation]
}

// MARK: - Goals

public struct ReviewGoalItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let targetAmount: Money
    public let targetDate: Day?
    public let status: PlannedPurchaseStatus
    public let reservedAmount: Money
}

public struct ReviewGoals: Hashable, Sendable {
    public let currentlySetAside: Money
    /// Historical reservation movement is not reconstructable from a current
    /// snapshot. When this is false, `reservationChange` is nil.
    public let reservationHistoryKnown: Bool
    public let reservationChange: Money?
    public let activePurchases: [ReviewGoalItem]
    public let upcomingTargetDates: [ReviewGoalItem]
}

// MARK: - Risk

/// Forward-looking outlook generated from `request.asOf`. None of these
/// fields is Home `safeToSpend`, and none is a reconstructed period-end
/// balance for `interval`.
public struct ReviewRisk: Hashable, Sendable {
    /// The outlook origin. Equal to `request.asOf`.
    public let asOf: Day
    /// Spendable-pool liquidity at `asOf`. Not the review period's ending cash.
    public let asOfLedgerLiquidity: Money
    public let outlookEnd: Day
    public let upcomingObligations: [ExpectedOccurrence]
    public let firstHardCashRiskDate: Day?
    public let firstFloorWarningDate: Day?
    public let firstRisk: ForecastResult.FirstRisk?
    public let minimumBridgeRequired: Money
}

// MARK: - Comparison

public struct ReviewDelta: Hashable, Sendable {
    public let current: Money
    public let prior: Money
    public let absolute: Money
    /// `(current − prior) × 10_000 / prior`. nil when prior is zero so a
    /// percentage is not invented.
    public let basisPoints: Int?

    public init(current: Money, prior: Money) {
        precondition(current.currency == prior.currency)
        self.current = current
        self.prior = prior
        self.absolute = Money(
            minorUnits: current.minorUnits - prior.minorUnits,
            currency: current.currency
        )
        if prior.minorUnits == 0 {
            self.basisPoints = nil
        } else {
            self.basisPoints = Int(
                (current.minorUnits - prior.minorUnits) * 10_000 / prior.minorUnits
            )
        }
    }
}

public struct ReviewCategoryDelta: Identifiable, Hashable, Sendable {
    public let id: String
    public let delta: ReviewDelta
}

public struct ReviewPeriodComparison: Hashable, Sendable {
    public let priorInterval: ReviewInterval
    public let spending: ReviewDelta
    public let budgetUtilization: ReviewDelta?
    public let income: ReviewDelta
    public let supportOwned: ReviewDelta
    public let categoryDeltas: [ReviewCategoryDelta]
    public let largestChangedDrivers: [ReviewCategoryDelta]
}

public enum ReviewComparisonRefusal: String, Sendable, Hashable, Codable {
    case notRequested
    case priorCoverageIncomplete
    case currentCoverageIncomplete
    case coverageNotComparable
}

public enum ReviewComparison: Hashable, Sendable {
    case available(ReviewPeriodComparison)
    case unavailable(ReviewComparisonRefusal)
}

// MARK: - Findings

public enum ReviewFindingKind: String, Sendable, Hashable, Codable, CaseIterable {
    case unresolvedEvidenceAffectingAccuracy
    case budgetOverrun
    case unusuallyHighCategory
    case majorExceptionalPurchase
    case supportBelowExpected
    case upcomingLiquidityRisk
    case floorWarning
    case spendingMateriallyHigherThanPrior
    case spendingMateriallyLowerThanPrior
    case goalDeadlineApproaching
}

public enum ReviewFindingSeverity: String, Sendable, Hashable, Codable {
    case important
    case warning
    case info
}

public struct ReviewFinding: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: ReviewFindingKind
    public let severity: ReviewFindingSeverity
    public let amounts: [Money]
    public let dates: [Day]
    public let ids: [String]
}

// MARK: - Result

/// Ephemeral review output. Not stored on `FinanceDocument`.
public struct ReviewResult: Hashable, Sendable {
    public let kind: ReviewPeriodKind
    public let interval: ReviewInterval
    public let asOf: Day
    public let currency: Currency
    public let coverage: ReviewCoverage
    public let totals: ReviewTotals
    public let budget: ReviewBudget
    public let income: ReviewIncome
    public let expectations: ReviewExpectations
    public let goals: ReviewGoals
    public let risk: ReviewRisk
    public let comparison: ReviewComparison
    public let findings: [ReviewFinding]
}
