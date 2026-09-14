import Foundation

/// Turns proposals into one answer to "is there anything I should do?".
///
/// ## Ownership
///
/// The coordinator decides **validity, then priority** — in that order, never
/// blended. It has no weighted score, no threshold, no arithmetic over money,
/// and no knowledge of what any candidate means beyond its declared kind,
/// dependencies and ordering keys. Every figure it hands on was produced by
/// the engine that owns it.
///
/// It is a pure function: the same proposals and the same source availability
/// always produce the same state, including the same ordering.
enum AttentionCoordinator {

    /// - Parameters:
    ///   - proposals: candidate proposals from the fact adapters, in any order.
    ///   - availability: per-key source outcomes, domain-scoped.
    ///   - quiet: what may be said when nothing needs doing. Supply
    ///     `.unquantified` unless a successful forecast established a horizon.
    static func evaluate(
        proposals: [AttentionCandidateProposal],
        availability: AttentionSourceAvailability,
        quiet: AttentionQuiet = .unquantified
    ) -> AttentionState {

        // 0. One candidate per identity. Two proposals sharing a kind and an
        //    identity are the same task described twice; keeping both would
        //    give two candidates the same `id`, and the later one would
        //    silently overwrite the earlier one's verdict. The survivor is
        //    chosen by identity order so the choice is deterministic rather
        //    than dependent on the order the adapters happened to run.
        var seen: Set<String> = []
        let proposals = proposals
            .sorted { identity(of: $0) < identity(of: $1) }
            .filter { seen.insert(identity(of: $0)).inserted }

        // 1. Validity, per proposal, against nothing but its own declarations
        //    and the source outcomes.
        var eligibility = proposals.reduce(into: [String: AttentionEligibility]()) { result, proposal in
            result[identity(of: proposal)] = baseEligibility(of: proposal, availability: availability)
        }

        // 2. Integrity. A key is compromised when any proposal reports it, and
        //    that report is *credible* only when the reporting proposal could
        //    itself become primary — otherwise nobody is going to tell the
        //    person why the number beneath them moved.
        var compromised: Set<AttentionDependencyKey> = []
        var credibleReporter: [AttentionDependencyKey: Bool] = [:]
        for proposal in proposals where !proposal.compromisedDependencies.isEmpty {
            let reporterIsPrimaryEligible =
                eligibility[identity(of: proposal)]?.canBePrimary ?? false
            for key in proposal.compromisedDependencies {
                compromised.insert(key)
                credibleReporter[key] = (credibleReporter[key] ?? false) || reporterIsPrimaryEligible
            }
        }

        // 3. Demote or suppress whatever rests on a compromised key. A
        //    proposal never gates itself: the reporter of a compromise is not
        //    demoted by its own report.
        for proposal in proposals {
            let key = identity(of: proposal)
            guard eligibility[key] == .eligible else { continue }
            let blockedBy = proposal.dependencies
                .subtracting(proposal.compromisedDependencies)
                .intersection(compromised)
                .sorted()
            guard let first = blockedBy.first else { continue }
            eligibility[key] = credibleReporter[first] == true
                ? .secondaryOnlyBecauseDependencyCompromised(first)
                : .suppressedBecauseSourceIncoherent(first)
        }

        // 4. Priority, only now.
        let candidates = proposals
            .map { AttentionCandidate(proposal: $0, eligibility: eligibility[identity(of: $0)] ?? .eligible) }
            .sorted(by: order)

        let primary = candidates.first { $0.eligibility.canBePrimary }
        let secondary = Array(
            candidates
                .filter { $0.eligibility.canBeSecondary && $0.id != primary?.id }
                .prefix(3)
        )
        let actionableCandidates = candidates.filter(\.eligibility.canBeSecondary)
        let suppressed = candidates.filter(\.eligibility.isSuppressed)

        return AttentionState(
            primary: primary,
            secondary: secondary,
            actionableCandidates: actionableCandidates,
            suppressed: suppressed,
            outcome: outcome(
                hasVisibleCandidate: primary != nil || !secondary.isEmpty,
                availability: availability,
                quiet: quiet
            )
        )
    }

    // MARK: - Outcome

    /// `noActionNeeded` is not a candidate and not a fallback. It is a claim
    /// that the question was fully answered, which requires every source the
    /// **current-attention** domain needs — and only those. An unavailable
    /// checkpoint baseline, or any other source outside that set, cannot make
    /// today's answer indeterminate. That is refinement A.
    private static func outcome(
        hasVisibleCandidate: Bool,
        availability: AttentionSourceAvailability,
        quiet: AttentionQuiet
    ) -> AttentionOutcome {
        if hasVisibleCandidate { return .actionsAvailable }
        let failed = availability.failedKeys(for: .currentAttention)
        guard failed.isEmpty else { return .indeterminate(failedKeys: failed) }
        return .noActionNeeded(quiet)
    }

    // MARK: - Validity

    private static func baseEligibility(
        of proposal: AttentionCandidateProposal,
        availability: AttentionSourceAvailability
    ) -> AttentionEligibility {
        // Source failures outrank everything: a candidate built on a source
        // that did not produce a result is not a quiet candidate, it is not a
        // candidate. Sorted so the reported key is deterministic when several
        // failed.
        for key in proposal.dependencies.sorted() {
            switch availability.status(key) {
            case .available:
                continue
            case .unavailable:
                return .suppressedBecauseSourceUnavailable(key)
            case .incoherent:
                return .suppressedBecauseSourceIncoherent(key)
            }
        }
        if proposal.conditionResolved { return .suppressedBecauseConditionResolved }
        if let representedBy = proposal.representedBy {
            return .suppressedBecauseRepresentedBy(representedBy)
        }
        if !proposal.isActionable { return .suppressedBecauseNotActionable }
        return .eligible
    }

    // MARK: - Ordering

    /// Total order. Every pair either differs on one of these keys or is the
    /// same candidate, so no ordering is left to a hash seed.
    ///
    /// Eligibility first, because a demoted candidate must never sit above the
    /// one that demoted it. Then nominal precedence, then the deterministic
    /// within-kind tie-breakers: soonest day, then largest amount, then
    /// identity.
    private static func order(_ lhs: AttentionCandidate, _ rhs: AttentionCandidate) -> Bool {
        let leftRank = rank(lhs.eligibility)
        let rightRank = rank(rhs.eligibility)
        if leftRank != rightRank { return leftRank < rightRank }

        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }

        switch (lhs.proposal.orderingDay, rhs.proposal.orderingDay) {
        case let (left?, right?) where left != right: return left < right
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }

        let leftAmount = abs(lhs.proposal.orderingMinorUnits)
        let rightAmount = abs(rhs.proposal.orderingMinorUnits)
        if leftAmount != rightAmount { return leftAmount > rightAmount }

        return lhs.id < rhs.id
    }

    private static func rank(_ eligibility: AttentionEligibility) -> Int {
        switch eligibility {
        case .eligible: 0
        case .secondaryOnlyBecauseDependencyCompromised: 1
        case .suppressedBecauseSourceUnavailable: 2
        case .suppressedBecauseSourceIncoherent: 3
        case .suppressedBecauseConditionResolved: 4
        case .suppressedBecauseNotActionable: 5
        case .suppressedBecauseRepresentedBy: 6
        }
    }

    private static func identity(of proposal: AttentionCandidateProposal) -> String {
        "\(proposal.kind.rawValue):\(proposal.identity)"
    }
}
