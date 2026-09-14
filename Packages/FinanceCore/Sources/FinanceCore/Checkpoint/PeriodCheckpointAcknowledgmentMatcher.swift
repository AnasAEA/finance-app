/// Pure reconstruction of which current checkpoint exceptions represent the
/// exact same semantic issue as acknowledgments on the immediately previous
/// supported revision.
///
/// ## Candidates, not confirmations
///
/// A match means: this current issue exactly matches something previously
/// acknowledged. It does **not** mean the user acknowledged it in this
/// revision.
///
/// Conceptual states, which this type keeps distinct:
///
/// - `carryForwardCandidates` — derived, advisory, pure. The `matched` pairs,
///   and `carryForwardCandidateIDs` derived from them.
/// - `confirmedAcknowledgmentIDs` — an explicit current-revision user
///   decision. This matcher does not produce that state.
///
/// Only `PeriodCheckpointConfirmedAcknowledgments`, produced by explicit user
/// confirmation, carries acknowledgment authority into a request. Carry-forward
/// candidate identifiers cannot be auto-applied: the request has no raw
/// identifier input to receive them, and confirmation re-checks the whole
/// semantic subject rather than the identifier. Matcher output never
/// establishes readiness, mutates a request, writes a revision, or decides
/// close / reverify eligibility.
///
/// ## Totality
///
/// Every previous acknowledgment ends in exactly one of: `matched.previous`,
/// `previousDisappeared`, `previousUnmatchable`.
/// Every current exception ends in exactly one of: `matched.current`,
/// `currentUnmatched`, `currentUnmatchable`.
///
/// Previous unmatchable is not previous disappeared. A subject that cannot
/// be uniquely reconstructed is not an issue that went away.
///
/// ## Matching
///
/// Match iff all of: same exception kind; exactly one semantic subject on
/// the previous side; exactly one semantic subject on the current side;
/// complete canonical subjects compare value-equal; the pairing is
/// one-to-one. Anything else is not a carry. No fuzzy matching, name
/// similarity, tolerance, heuristic, historical index, or change-class gate.
///
/// Both sides read `CanonicalSemanticPeriodProjection.projection` after the
/// canonical encode/decode normalization that type already applies. This
/// file does not invent a second canonicalization. Historical projection
/// comes only from `previousRevision.canonicalProjection`.
///
/// When a future exception constructor is introduced, that change owes a
/// semantic subject and a matcher case. Unreachable kinds never carry.

public struct PeriodCheckpointAcknowledgmentMatchResult: Sendable, Equatable {

    /// One exact-subject pairing. Advisory only; not a current-revision
    /// acknowledgment.
    public struct Match: Sendable, Equatable {
        public let previous: AcknowledgedExceptionRecord
        public let current: PeriodCheckpointException

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.previous.exception == rhs.previous.exception && lhs.current == rhs.current
        }
    }

    public let matched: [Match]
    public let currentUnmatched: [PeriodCheckpointException]
    public let previousDisappeared: [AcknowledgedExceptionRecord]
    public let previousUnmatchable: [AcknowledgedExceptionRecord]
    public let currentUnmatchable: [PeriodCheckpointException]

    /// Current exception identifiers from `matched`, in matcher output order.
    ///
    /// Carry-forward candidates only: advisory diagnostics, never authority.
    /// They cannot be auto-applied, because acknowledgment authority is
    /// `PeriodCheckpointConfirmedAcknowledgments` and the only producer of one
    /// re-checks each candidate's whole semantic subject. Derived, advisory,
    /// and never a readiness input by themselves. This property is not a
    /// confirmed-acknowledgment set.
    public var carryForwardCandidateIDs: [String] {
        matched.map(\.current.id)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.matched == rhs.matched
            && lhs.currentUnmatched == rhs.currentUnmatched
            && lhs.previousDisappeared.map(\.exception) == rhs.previousDisappeared.map(\.exception)
            && lhs.previousUnmatchable.map(\.exception) == rhs.previousUnmatchable.map(\.exception)
            && lhs.currentUnmatchable == rhs.currentUnmatchable
    }
}

public enum PeriodCheckpointAcknowledgmentMatcher {

    /// Reconstruct carry-forward candidates from one previous supported
    /// revision and the current exception/projection pair.
    ///
    /// Absence of a previous revision is not an empty revision: the caller
    /// does not invoke this function. This function does not acknowledge,
    /// does not call the evaluator, and does not take a request or readiness
    /// value of any kind.
    public static func match(
        previousRevision: PeriodCheckpointRevision,
        currentExceptions: [PeriodCheckpointException],
        currentProjection: CanonicalSemanticPeriodProjection
    ) -> PeriodCheckpointAcknowledgmentMatchResult {
        let previousProjection = previousRevision.canonicalProjection.projection
        let currentFacts = currentProjection.projection

        var previousUnmatchable: [AcknowledgedExceptionRecord] = []
        var currentUnmatchable: [PeriodCheckpointException] = []
        var previousResolved: [(record: AcknowledgedExceptionRecord, subject: Subject)] = []
        var currentResolved: [(exception: PeriodCheckpointException, subject: Subject)] = []

        for record in previousRevision.acknowledgedExceptions {
            switch resolve(record.exception, in: previousProjection) {
            case .unmatchable:
                previousUnmatchable.append(record)
            case let .unique(subject):
                previousResolved.append((record, subject))
            }
        }
        for exception in currentExceptions {
            switch resolve(exception, in: currentFacts) {
            case .unmatchable:
                currentUnmatchable.append(exception)
            case let .unique(subject):
                currentResolved.append((exception, subject))
            }
        }

        var matched: [PeriodCheckpointAcknowledgmentMatchResult.Match] = []
        var previousDisappeared: [AcknowledgedExceptionRecord] = []
        var pairedCurrent: [Bool] = Array(repeating: false, count: currentResolved.count)

        for previous in previousResolved {
            let previousCount = previousResolved.reduce(into: 0) { count, item in
                if item.subject == previous.subject { count += 1 }
            }
            var currentIndex: Int?
            var currentCount = 0
            for (index, item) in currentResolved.enumerated() {
                guard item.subject == previous.subject else { continue }
                currentCount += 1
                currentIndex = index
            }

            if previousCount == 1, currentCount == 1, let currentIndex {
                matched.append(
                    PeriodCheckpointAcknowledgmentMatchResult.Match(
                        previous: previous.record,
                        current: currentResolved[currentIndex].exception
                    )
                )
                pairedCurrent[currentIndex] = true
            } else if previousCount == 1, currentCount == 0 {
                previousDisappeared.append(previous.record)
            } else {
                previousUnmatchable.append(previous.record)
            }
        }

        var currentUnmatched: [PeriodCheckpointException] = []
        for (index, current) in currentResolved.enumerated() {
            if pairedCurrent[index] { continue }
            let previousCount = previousResolved.reduce(into: 0) { count, item in
                if item.subject == current.subject { count += 1 }
            }
            let currentCount = currentResolved.reduce(into: 0) { count, item in
                if item.subject == current.subject { count += 1 }
            }
            if previousCount == 0, currentCount == 1 {
                currentUnmatched.append(current.exception)
            } else {
                currentUnmatchable.append(current.exception)
            }
        }

        matched.sort { lhs, rhs in
            if lhs.current != rhs.current {
                return exceptionOrder(lhs.current, rhs.current)
            }
            return exceptionOrder(lhs.previous.exception, rhs.previous.exception)
        }
        currentUnmatched.sort(by: exceptionOrder)
        currentUnmatchable.sort(by: exceptionOrder)
        previousDisappeared.sort { exceptionOrder($0.exception, $1.exception) }
        previousUnmatchable.sort { exceptionOrder($0.exception, $1.exception) }

        return PeriodCheckpointAcknowledgmentMatchResult(
            matched: matched,
            currentUnmatched: currentUnmatched,
            previousDisappeared: previousDisappeared,
            previousUnmatchable: previousUnmatchable,
            currentUnmatchable: currentUnmatchable
        )
    }

    // MARK: - Subject resolution

    private enum Resolution {
        case unmatchable
        case unique(Subject)
    }

    /// Complete canonical semantic subject. Value equality is the match
    /// authority; Hashable is not used.
    private enum Subject: Equatable {
        case observation(PeriodCheckpointExceptionKind, SemanticObservationFact)
        case aggregate(PeriodCheckpointExceptionKind, AggregateEvidenceBasis, SemanticObservationFact)
        case expectation(PeriodCheckpointExceptionKind, SemanticExpectationFact)
        case uncategorized(
            PeriodCheckpointExceptionKind,
            SemanticInterval,
            Money,
            [UncategorizedAttributionSubject]
        )
    }

    private struct UncategorizedAttributionSubject: Equatable {
        let transactionID: String
        let basis: MonthlyBudgetEngine.AttributionBasis
        let amount: Money
    }

    private static func resolve(
        _ exception: PeriodCheckpointException,
        in projection: SemanticPeriodProjection
    ) -> Resolution {
        switch exception.kind {
        case .unresolvedEvidenceLinkage,
             .unresolvedEconomicClassification,
             .unresolvedIncomeClassificationOrOwnership,
             .acceptedReconciliationAmountDifference:
            return .unmatchable

        case .unknownBookedEconomics, .providerStatusConflict:
            switch uniqueObservation(id: exception.id, in: projection) {
            case .none, .many:
                return .unmatchable
            case let .one(fact):
                return .unique(.observation(exception.kind, fact))
            }

        case .aggregateEvidenceModelLimitation:
            guard let basis = exception.aggregateBasis else { return .unmatchable }
            switch uniqueObservation(id: exception.id, in: projection) {
            case .none, .many:
                return .unmatchable
            case let .one(fact):
                return .unique(.aggregate(exception.kind, basis, fact))
            }

        case .overdueExpectedOccurrence:
            switch uniqueExpectation(exceptionID: exception.id, in: projection) {
            case .none, .many:
                return .unmatchable
            case let .one(fact):
                return .unique(.expectation(exception.kind, fact))
            }

        case .uncategorizedEconomicSpending:
            let rows = projection.budget.attributions.compactMap { attribution -> UncategorizedAttributionSubject? in
                guard attribution.budgetID == nil else { return nil }
                return UncategorizedAttributionSubject(
                    transactionID: attribution.transactionID,
                    basis: attribution.basis,
                    amount: attribution.amount
                )
            }
            return .unique(
                .uncategorized(
                    exception.kind,
                    projection.period,
                    projection.budget.uncategorized,
                    rows
                )
            )
        }
    }

    private enum Unique<T> {
        case none
        case one(T)
        case many
    }

    private static func uniqueObservation(
        id: String,
        in projection: SemanticPeriodProjection
    ) -> Unique<SemanticObservationFact> {
        var found: SemanticObservationFact?
        for fact in projection.observations {
            guard fact.id == id else { continue }
            if found != nil { return .many }
            found = fact
        }
        return found.map { .one($0) } ?? .none
    }

    /// Join by constructing `OccurrenceID.description`. Never parse `exception.id`.
    private static func uniqueExpectation(
        exceptionID: String,
        in projection: SemanticPeriodProjection
    ) -> Unique<SemanticExpectationFact> {
        var found: SemanticExpectationFact?
        for fact in projection.expectations {
            let occurrence = OccurrenceID(obligationID: fact.obligationID, expectedDay: fact.expectedDay)
            guard occurrence.description == exceptionID else { continue }
            if found != nil { return .many }
            found = fact
        }
        return found.map { .one($0) } ?? .none
    }

    /// Total lexicographic order over the exception snapshot. `(kind, id)` is
    /// not enough: unequal values may share those fields, and Swift's sort
    /// is not stable. Fully equal values may remain in either order.
    private static func exceptionOrder(
        _ lhs: PeriodCheckpointException,
        _ rhs: PeriodCheckpointException
    ) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        switch (lhs.aggregateBasis, rhs.aggregateBasis) {
        case (nil, nil): break
        case (nil, _?): return true
        case (_?, nil): return false
        case let (left?, right?) where left != right: return left.rawValue < right.rawValue
        default: break
        }
        switch (lhs.day, rhs.day) {
        case (nil, nil): break
        case (nil, _?): return true
        case (_?, nil): return false
        case let (left?, right?) where left != right: return dayOrder(left, right)
        default: break
        }
        switch (lhs.amount, rhs.amount) {
        case (nil, nil): break
        case (nil, _?): return true
        case (_?, nil): return false
        case let (left?, right?) where left != right: return moneyOrder(left, right)
        default: break
        }
        return false
    }

    /// Day permits every Int year; its ordinal comparison can overflow.
    /// Compare validated civil components directly without calculating an index.
    private static func dayOrder(_ lhs: Day, _ rhs: Day) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }

    private static func moneyOrder(_ lhs: Money, _ rhs: Money) -> Bool {
        if lhs.minorUnits != rhs.minorUnits { return lhs.minorUnits < rhs.minorUnits }
        if lhs.currency.code != rhs.currency.code { return lhs.currency.code < rhs.currency.code }
        return lhs.currency.minorUnitDigits < rhs.currency.minorUnitDigits
    }
}
