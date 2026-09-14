/// Pure `PeriodCheckpointRequest` → `PeriodCheckpointReadiness`.
///
/// The evaluator computes no economics. It reads an already-successful
/// `ReviewResult` for coverage and re-derives nothing the review engine
/// already decided; it takes the caller's typed exceptions as facts and only
/// works out what they cost. No clock, no store, no SwiftData, no UI state.
public enum PeriodCheckpointEvaluator {

    public static func evaluate(_ request: PeriodCheckpointRequest) -> PeriodCheckpointReadiness {

        let exceptions = request.exceptions.sorted(by: exceptionOrder)
        let quality: PeriodCheckpointQuality = exceptions.isEmpty ? .clean : .withExceptions

        let blockers = self.blockers(for: request)

        // Authority belongs to exact confirmed subjects, never their IDs.
        // Duplicate identities and stale/foreign subjects independently refuse
        // the entire application; a valid subset must not partially replay.
        let authorityInvalid = blockers.contains {
            $0.kind == .duplicateExceptionIdentity
                || $0.kind == .confirmedAcknowledgmentSubjectMismatch
        }
        let confirmedSubjects: Set<PeriodCheckpointException> = authorityInvalid
            ? [] : request.confirmedAcknowledgments.confirmedExceptions
        let acknowledged = exceptions.filter { confirmedSubjects.contains($0) }
        let undecided = exceptions.filter { !confirmedSubjects.contains($0) }

        let disposition: PeriodCheckpointDisposition
        if !blockers.isEmpty {
            disposition = .blocked
        } else if !undecided.isEmpty {
            disposition = .needsDecisions
        } else if exceptions.isEmpty {
            disposition = .readyClean
        } else {
            disposition = .readyWithAcknowledgedExceptions
        }

        // Safe claims come from the exceptions the period actually carries,
        // never from the disposition. An acknowledged exception costs exactly
        // what an unacknowledged one costs: acknowledgment changes no
        // underlying financial fact.
        let safeClaims = blockers.isEmpty
            ? PeriodCheckpointSafeClaims.surviving(exceptions)
            : .blocked

        return PeriodCheckpointReadiness(
            period: SemanticInterval(request.period),
            kind: request.kind,
            disposition: disposition,
            quality: quality,
            blockers: blockers,
            exceptions: exceptions,
            acknowledgedExceptions: acknowledged,
            undecidedExceptions: undecided,
            safeClaims: safeClaims,
            baselineComparison: request.baselineComparison,
            projection: request.projection
        )
    }

    // MARK: - Blockers

    private static func blockers(for request: PeriodCheckpointRequest) -> [PeriodCheckpointBlocker] {
        var found: [PeriodCheckpointBlocker] = []

        // Checked first and on every path: identity uniqueness is a property of
        // the exception set alone, independently of exact subject binding.
        // It is a blocker rather than a silent de-duplication
        // because "two exceptions, one identifier" is not a state anyone
        // decided on — first-one-wins, dropping one, or acknowledging both
        // would each invent an answer the caller never gave.
        if !identifiersAreUnique(request.exceptions) {
            found.append(PeriodCheckpointBlocker(kind: .duplicateExceptionIdentity))
        }

        // Subset membership, not whole-request binding: unrelated new
        // exceptions do not invalidate a decision on an unchanged subject.
        // Count exact occurrences so every confirmed value is carried once.
        if !request.confirmedAcknowledgments.confirmedExceptions.allSatisfy({ subject in
            request.exceptions.filter { $0 == subject }.count == 1
        }) {
            found.append(PeriodCheckpointBlocker(kind: .confirmedAcknowledgmentSubjectMismatch))
        }

        guard request.period.start <= request.period.end else {
            // Nothing else can be said about a non-period, and saying more
            // would mean interpreting an interval that does not exist.
            found.append(PeriodCheckpointBlocker(kind: .invalidPeriod,
                                                 interval: SemanticInterval(request.period)))
            return found.uniquedAndSorted()
        }

        if request.asOf < request.period.end {
            found.append(PeriodCheckpointBlocker(kind: .periodNotEnded,
                                                 interval: SemanticInterval(request.period)))
        }

        guard let review = request.review else {
            found.append(PeriodCheckpointBlocker(kind: .reviewUnavailable))
            found.append(contentsOf: projectionBlocker(for: request))
            return found.uniquedAndSorted()
        }

        if review.interval != request.period || review.kind != request.kind {
            found.append(PeriodCheckpointBlocker(kind: .reviewPeriodMismatch,
                                                 interval: SemanticInterval(review.interval)))
            // A review of a different period cannot speak for this one, so its
            // coverage is not consulted at all.
            found.append(contentsOf: projectionBlocker(for: request))
            return found.uniquedAndSorted()
        }

        found.append(contentsOf: coverageBlockers(review.coverage))
        found.append(contentsOf: projectionBlocker(for: request))
        return found.uniquedAndSorted()
    }

    /// Coverage blockers map one-to-one onto the review engine's own reasons.
    /// The checkpoint invents no coverage rule of its own and re-reads no
    /// archive: `ReviewCoverage` is authoritative and already fail-closed.
    private static func coverageBlockers(_ coverage: ReviewCoverage) -> [PeriodCheckpointBlocker] {
        guard coverage.status != .complete else { return [] }

        var found = coverage.reasons.map { reason in
            PeriodCheckpointBlocker(
                kind: blockerKind(for: reason.kind),
                interval: reason.interval.map(SemanticInterval.init),
                affectedSources: reason.affectedSources
            )
        }
        // Incomplete coverage with no stated reason is still incomplete. It
        // must not read as complete because the engine did not enumerate why.
        if found.isEmpty {
            found.append(PeriodCheckpointBlocker(kind: .coverageMetadataAbsent))
        }
        return found
    }

    private static func blockerKind(
        for reason: ReviewCoverageReasonKind
    ) -> PeriodCheckpointBlockerKind {
        switch reason {
        case .coverageMetadataAbsent: .coverageMetadataAbsent
        case .archiveHistoryAbsent: .archiveHistoryAbsent
        case .missingArchiveInterval: .missingArchiveInterval
        case .missingLiveInterval: .missingLiveInterval
        case .sourceGap: .sourceGap
        }
    }

    private static func projectionBlocker(
        for request: PeriodCheckpointRequest
    ) -> [PeriodCheckpointBlocker] {
        guard request.requiresSemanticProjection, request.projection == nil else { return [] }
        return [PeriodCheckpointBlocker(kind: .semanticProjectionUnavailable,
                                        interval: SemanticInterval(request.period))]
    }

    // MARK: - Ordering

    /// Total order: kind, then identity. Two exceptions that compare equal here
    /// share both, which `.duplicateExceptionIdentity` blocks before any
    /// acknowledgment is joined — so among evaluable inputs no pair is left to
    /// a hash seed or to the caller's array order.
    private static func exceptionOrder(
        _ lhs: PeriodCheckpointException,
        _ rhs: PeriodCheckpointException
    ) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id < rhs.id
    }

    /// Whether every carried exception names a distinct identifier.
    private static func identifiersAreUnique(_ exceptions: [PeriodCheckpointException]) -> Bool {
        Set(exceptions.map(\.id)).count == exceptions.count
    }
}

private extension Array where Element == PeriodCheckpointBlocker {
    func uniquedAndSorted() -> [PeriodCheckpointBlocker] {
        Array(Set(self)).sorted()
    }
}
