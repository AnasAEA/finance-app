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
    /// Where the limitation can be worked on, when this app can do anything
    /// about it. Nil means it cannot be resolved from here, and the screen
    /// says so rather than offering a button that fixes nothing.
    let action: ReviewOwnerDestination?
}

// MARK: - Records behind a figure

/// One record a review counted, with exactly what it added to a figure.
///
/// `counted` is the review's own resolved amount for this record — net of a
/// refund applied against it, and negative for a refund that reduced
/// spending — so a list of these adds up to the figure it explains.
struct ReviewRecordRow: Identifiable, Hashable, Sendable {
    /// The ledger transaction's identifier.
    let id: String
    let day: CalendarDay
    let counted: Amount
}

/// The exact records behind one figure on the review.
///
/// Built only from the engine's own contributions, and only when they add
/// up to the figure being explained: `total` is that figure and the rows sum
/// to it. A figure whose records cannot be accounted for gets no set at all,
/// so nothing opens a list that disagrees with the number above it.
struct ReviewRecordSet: Identifiable, Hashable, Sendable {
    let id: String
    /// What the records are: a category, "Spending", or a month.
    let title: String
    /// The days the records were taken from.
    let scopeLabel: String
    let total: Amount
    let records: [ReviewRecordRow]
    /// Where the plan behind this figure can be changed, when it has one.
    let owner: ReviewOwnerDestination?
}

/// A screen elsewhere in the app that owns what a finding is about. Insights
/// explains; changing a budget, a goal or a bank connection happens there.
enum ReviewOwnerDestination: Hashable, Sendable {
    case budget, goals, fundingNeeded, safetyReserve, banksAndSync
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
    /// The records behind `monthSpending`, the whole month.
    let records: ReviewRecordSet?
}

// MARK: - Spending

struct ReviewCategoryAmount: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let amount: Amount
    /// The records behind `amount`.
    let records: ReviewRecordSet?
}

struct ReviewExceptionalPurchase: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let amount: Amount
    let day: CalendarDay
    /// The ledger transaction to open, when the purchase is one.
    let transactionID: String?
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
    /// The ledger transaction that settled it, when one did.
    let transactionID: String?
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

enum ReviewFindingRole: Hashable, Sendable {
    case coverage, reviewItems, change
}

/// One engine finding, rendered. The UI never decides that something is
/// interesting: every card here corresponds to a `ReviewFinding` the engine
/// returned, in the engine's own order.
struct ReviewFindingCard: Identifiable, Hashable, Sendable {
    let id: String
    let tone: ReviewFindingTone
    let role: ReviewFindingRole
    let title: String
    let detail: String
    let destination: ReviewFindingDestination?
}

/// A route exists only when the adapter can account for every subject the
/// engine named. An explanation with mixed or unavailable subjects stays
/// informational rather than opening a misleading subset.
enum ReviewFindingDestination: Hashable, Sendable {
    /// Bank items still waiting for a decision, exactly those.
    case reviewItems([String])
    /// The records whose amounts make up the figure the finding quotes.
    case records(ReviewRecordSet)
    /// The one ledger transaction the finding names.
    case transaction(String)
    /// The screen that owns what the finding is about.
    case owner(ReviewOwnerDestination)
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
    /// The records behind `spending`, when it is known.
    let spendingRecords: ReviewRecordSet?
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

    /// One engine finding leads the review. Coverage is stated separately;
    /// an unresolved bank item takes priority over a numeric change because
    /// it may change what can be counted after the user reviews it.
    var primaryFinding: ReviewFindingCard? {
        findings.first(where: { $0.role == .reviewItems })
            ?? findings.first(where: { $0.role == .change })
    }

    var remainingFindings: [ReviewFindingCard] {
        findings.filter { $0.role != .coverage && $0.id != primaryFinding?.id }
    }
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

/// A semantic axis the stored checkpoint comparison named as having moved.
///
/// Product vocabulary, not a canonical field name. The mapper is the only
/// thing that produces these, from the comparison's change classes; a screen
/// that invented one from a raw payload would be classifying the period
/// itself.
enum VerificationChangeDimension: String, Hashable, Sendable, CaseIterable {
    case coverage
    case economics
    case budgetAttribution
    case evidence
    case providerState
    case aggregateRelationship
    case expectation

    /// The one place a dimension becomes a sentence.
    ///
    /// Each sentence states that this projected meaning differs. None of them
    /// claims a cause, a euro amount, or that a particular row is the one
    /// that moved.
    var statement: String {
        switch self {
        case .coverage:
            "The records covering this month have changed."
        case .economics:
            "The month's recorded spending or income is different."
        case .budgetAttribution:
            "How spending is assigned has changed."
        case .evidence:
            "The month's available evidence has changed."
        case .providerState:
            "The bank's status for a recorded movement has changed."
        case .aggregateRelationship:
            "How a bank movement relates to existing records has changed."
        case .expectation:
            "A scheduled payment's standing has changed."
        }
    }
}

/// Why a previously verified month is no longer current, as the product can
/// safely say it.
///
/// `dimensions` are the comparison's named axes and are never empty: a
/// changed comparison that could not name a dimension is unsayable. Occupancy
/// sentences are extra, and only present when they are proved: a clean close
/// followed by current exceptions, a close that carried exceptions followed
/// by none, or — when issues remain on both sides — unique appeared and
/// disappeared subjects established by exact correspondence. Matched
/// surviving subjects are not announced; they remain in the ordinary
/// current list. Ambiguous subjects produce no occupancy sentence.
///
/// Nil on the presentation is the only representation of "nothing changed"
/// or "we cannot say". There is no empty summary.
struct VerificationChangeSummary: Hashable, Sendable {
    let dimensions: [VerificationChangeDimension]
    let occupancyStatements: [String]

    /// What a screen may render, occupancy first. Never a revision, digest,
    /// identifier or canonical field name.
    var statements: [String] { occupancyStatements + dimensions.map(\.statement) }
}

/// Kind buckets for uniquely appeared or disappeared exception subjects.
///
/// Counts only. A screen never sees an exception, an identifier or a
/// matcher result. Zero in every field means nothing unique was proved.
struct VerificationExceptionKindCounts: Hashable, Sendable {
    var bankMovements: Int
    var scheduledPayments: Int
    var otherLimitations: Int

    var isEmpty: Bool {
        bankMovements == 0 && scheduledPayments == 0 && otherLimitations == 0
    }
}

/// Unique exception correspondence for a changed month that still carries
/// issues, as the product may say it.
///
/// Appeared subjects are current and unmatched. Disappeared subjects were
/// acknowledged on the previous close and are no longer carried. There is
/// no field for a matched survivor: those stay in Decisions and Limitations
/// and are not re-announced.
struct VerificationExceptionCorrespondence: Hashable, Sendable {
    let appeared: VerificationExceptionKindCounts
    let disappeared: VerificationExceptionKindCounts

    var isEmpty: Bool { appeared.isEmpty && disappeared.isEmpty }
}

struct PeriodVerificationPresentation: Hashable, Sendable {
    let periodLabel: String

    /// What the stored checkpoint history says, already mapped to product
    /// vocabulary. Never inferred from a revision count or a local flag.
    let verificationState: CheckpointVerificationState

    /// Why the month moved, when the comparison proved it did. Nil for every
    /// other verification state, including verified — unchanged months stay
    /// quiet.
    let changeSummary: VerificationChangeSummary?
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
