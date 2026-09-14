import Foundation

/// Product-facing period review. No `FinanceCore` type crosses this boundary:
/// the screens render what `ReviewEngine` decided, and decide nothing.

// MARK: - Period

enum ReviewPeriodScope: String, CaseIterable, Hashable, Sendable, Identifiable {
    case week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        }
    }
}

// MARK: - A figure that may not be knowable

/// The distinction Phase 7 turns on: a real zero and an unknown are different
/// answers, and a total built from an empty collection is not evidence of
/// either. Rendering `.unavailable` as `€0` is the bug this type exists to
/// make impossible.
enum ReviewFigure: Hashable, Sendable {
    case known(Amount)
    case unavailable

    var amount: Amount? {
        if case let .known(value) = self { return value }
        return nil
    }

    var isKnown: Bool { amount != nil }
}

// MARK: - Data quality

enum ReviewDataQuality: String, Hashable, Sendable {
    case complete, partial, insufficient

    /// Deliberately unreassuring above `complete`. A period that is only
    /// partly covered does not get calm green language.
    var title: String {
        switch self {
        case .complete: "Complete"
        case .partial: "Partial"
        case .insufficient: "Insufficient"
        }
    }
}

struct ReviewCoverageSummary: Hashable, Sendable {
    let quality: ReviewDataQuality
    /// One plain sentence. Never claims more than the engine established.
    let explanation: String
    /// Uncovered day ranges, already merged by the engine.
    let missingRanges: [ClosedRange<CalendarDay>]
    /// Local accounts with no authoritative provider window.
    let unknownAccountNames: [String]
    /// Archive-era days the installed archive does not reach.
    let mentionsArchive: Bool
}

// MARK: - Budget

struct ReviewBudgetLineSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let target: Amount
    let periodSpent: Amount
    let isOverspent: Bool
}

/// One calendar month's budget as it applies inside the reviewed period.
///
/// `periodSpendingInMonth` is only the reviewed days that fall in this month.
/// `monthSpending` and `ceiling` are the whole month against its own ceiling —
/// a week is never given a prorated share of a monthly allowance.
struct ReviewMonthContext: Identifiable, Hashable, Sendable {
    let id: String
    let monthLabel: String
    let periodSpendingInMonth: Amount
    let monthSpending: Amount
    let ceiling: Amount?
    let remaining: Amount?
    let overage: Amount?
    let committed: Amount
    let uncategorized: Amount
    let lines: [ReviewBudgetLineSummary]
}

// MARK: - Spending

struct ReviewCategoryAmount: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let amount: Amount
}

struct ReviewExceptionalPurchase: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let amount: Amount
    let day: CalendarDay
}

// MARK: - Income

/// Kept as separate concepts on purpose. Collapsing these into one "income"
/// figure is the misreading the archive's economic-source dimension exists to
/// prevent: a reimbursement is not earnings, and somebody else's share passing
/// through an account was never the owner's money.
struct ReviewIncomeBreakdown: Hashable, Sendable {
    let personalIncome: ReviewFigure
    let earnedOrOther: Amount
    let supportOwned: Amount
    let supportGross: Amount
    let reimbursements: Amount
    let passThroughNotMine: Amount
    let internalMovement: Amount
    let unresolved: Amount
    /// Personal income the engine did not place in a named class above —
    /// chiefly the owned share of money that arrived as pass-through.
    ///
    /// It exists so the rows always add up to `personalIncome`. Without it a
    /// period could show a headline total with nothing beneath it, which reads
    /// as a contradiction rather than as a breakdown.
    let otherPersonal: Amount

    var hasUnresolved: Bool { !unresolved.isZero }

    /// True only when nothing at all came in — not merely when no *named*
    /// class did.
    var isEmpty: Bool {
        (personalIncome.amount?.isZero ?? true) && earnedOrOther.isZero
            && supportOwned.isZero && reimbursements.isZero && unresolved.isZero
            && otherPersonal.isZero
    }
    /// True when support arrived partly on someone else's behalf.
    var supportHasOnwardShare: Bool { supportGross != supportOwned }
}

// MARK: - Expected vs actual

enum ReviewExpectationState: String, Hashable, Sendable {
    case expected, matched, missed, skipped, noLongerDue
}

struct ReviewExpectationRow: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let day: CalendarDay
    let expected: Amount
    let actual: Amount?
    let state: ReviewExpectationState
}

// MARK: - Goals

struct ReviewGoalRow: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let target: Amount
    let reserved: Amount
    let targetDay: CalendarDay?
}

struct ReviewGoalsSummary: Hashable, Sendable {
    let currentlySetAside: Amount
    /// A current snapshot cannot say how reservations moved during a past
    /// period, so the change is stated only when the engine knows it.
    let reservationChange: Amount?
    let active: [ReviewGoalRow]
}

// MARK: - Findings

enum ReviewFindingTone: String, Hashable, Sendable {
    case important, warning, info
}

/// One engine finding, rendered. The UI never decides that something is
/// interesting: every card here corresponds to a `ReviewFinding` the engine
/// returned, in the engine's own order.
struct ReviewFindingCard: Identifiable, Hashable, Sendable {
    let id: String
    let tone: ReviewFindingTone
    let title: String
    let detail: String
}

// MARK: - Outlook

/// Which line the projection crossed first.
enum ReviewRiskKind: String, Hashable, Sendable {
    /// The spendable pool went below zero.
    case poolDeficit
    /// The pool stayed positive but fell under the safety floor.
    case belowSafetyFloor
}

/// Forward-looking from the review's as-of day. Never a reconstructed
/// period-end balance.
struct ReviewOutlook: Hashable, Sendable {
    let asOfDay: CalendarDay
    let horizonEnd: CalendarDay
    let liquidityNow: Amount
    let firstRiskDay: CalendarDay?
    let firstRiskKind: ReviewRiskKind?
    let firstRiskLabel: String?
    /// The gap at the moment the first risk is reached — taken from the same
    /// object as `firstRiskDay`, never from a horizon-wide bridge figure.
    let shortfall: Amount?
    /// nil when a same-day pool deficit already says something stronger.
    let floorWarningDay: CalendarDay?
    let upcoming: [ReviewUpcomingItem]

    var hasRisk: Bool { firstRiskDay != nil || floorWarningDay != nil }
}

struct ReviewUpcomingItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let day: CalendarDay
    let amount: Amount
}

// MARK: - Comparison

enum ReviewComparisonState: Hashable, Sendable {
    case available(previousLabel: String, spendingDelta: Amount)
    /// The engine refused a comparison, and the reason is shown rather than an
    /// authoritative-looking number.
    case unavailable(reason: String)
}

// MARK: - The screen

struct InsightsPresentation: Hashable, Sendable {
    let scope: ReviewPeriodScope
    /// "This week", "Last week", "September 2026".
    let title: String
    /// "31 Aug – 6 Sep". Real week boundaries, including across a month end.
    let rangeLabel: String
    let canGoBack: Bool
    let canGoForward: Bool

    let coverage: ReviewCoverageSummary
    let summary: String
    let spending: ReviewFigure
    let income: ReviewFigure
    let notableChangeCount: Int

    let monthContexts: [ReviewMonthContext]
    let topCategories: [ReviewCategoryAmount]
    let exceptional: [ReviewExceptionalPurchase]
    let incomeBreakdown: ReviewIncomeBreakdown
    let expectations: [ReviewExpectationRow]
    let goals: ReviewGoalsSummary
    /// Findings about the reviewed period itself. What changed.
    let findings: [ReviewFindingCard]
    /// Findings about what is still ahead. What to watch. Partitioned by
    /// engine finding kind, never recomputed, and never shown in both places.
    let forwardFindings: [ReviewFindingCard]
    let outlook: ReviewOutlook
    let comparison: ReviewComparisonState
    /// One default-body sentence about the records behind this period.
    let recordsQualityStatement: String
    /// Read-only ended-period preview. Nil for a period that has not ended.
    let verification: PeriodVerificationPresentation?
    /// Past periods may point to Home without repeating any current amount or date.
    let showsHistoricalHomePointer: Bool

    /// True when the period is covered well enough that an empty collection
    /// means "nothing happened" rather than "nothing is known".
    var zeroMeansZero: Bool { coverage.quality == .complete }
}

/// What the stored checkpoint history says about an ended period, as the
/// screens state it.
///
/// Presentation semantics only. It carries no revision, no identifier, no
/// closing time and no repository reference, and it decides nothing: it is the
/// product's reading of one `PeriodCheckpointBaselineComparison`, mapped once
/// by `PeriodVerificationMapper`.
///
/// `verified` is the only claim that asserts current state matches what was
/// accepted, so every comparison that cannot prove that — a period never
/// closed, one whose comparison is indeterminate, one whose stored format this
/// build cannot compare, and a baseline that could not be read at all — lands
/// somewhere else. There is no state for "probably verified".
enum CheckpointVerificationState: String, Hashable, Sendable, CaseIterable {

    /// The checkpoint history was read and holds nothing for this period.
    case notVerified

    /// A stored checkpoint exists and current state equals what it accepted.
    case verified

    /// A stored checkpoint exists and current state has moved away from it.
    case changedSinceVerification

    /// No safe claim is available: the comparison is indeterminate, the stored
    /// format cannot be compared, or the baseline could not be established.
    case unavailable

    /// The one place this vocabulary becomes words.
    var headline: String {
        switch self {
        case .notVerified: "Not verified yet."
        case .verified: "Verified."
        case .changedSinceVerification: "Changes since verification."
        case .unavailable: "Verification status unavailable."
        }
    }
}

struct PeriodVerificationPresentation: Hashable, Sendable {
    let periodLabel: String

    /// What the stored checkpoint history says, already mapped to product
    /// vocabulary. Never inferred from a revision count or a local flag.
    let verificationState: CheckpointVerificationState
    let decisionCount: Int
    let limitationCount: Int
    let totalsStatement: String
    let categoryStatement: String?
    let auditStatement: String?
    let decisions: [PeriodVerificationIssue]
    let limitations: [PeriodVerificationIssue]
}

struct PeriodVerificationIssue: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let amount: Amount?
    let destination: PeriodVerificationDestination?
}

enum PeriodVerificationDestination: Hashable, Sendable {
    case observationReview(String)
    case expectedPayment(ExpectedPayment)
}
