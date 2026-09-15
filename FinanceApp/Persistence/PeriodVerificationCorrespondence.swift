import FinanceCore
import Foundation

/// Read-only explanation of which current exceptions uniquely appeared, and
/// which previously acknowledged exceptions uniquely disappeared, since the
/// last supported close.
///
/// This is the one production caller of `PeriodCheckpointAcknowledgmentMatcher`.
/// A match is correspondence, not a decision: nothing here selects a row,
/// confirms a subject, builds confirmed acknowledgments, or changes readiness.
/// Ambiguous and incomplete subjects are dropped, not guessed. Identifiers
/// are never the match key.
enum PeriodVerificationCorrespondence {

    /// Occupancy the mixed case may add to the change summary.
    ///
    /// Nil when this path does not apply — a clean previous close, a current
    /// month with no exceptions, an unsupported or unreadable tip, a month
    /// whose current projection cannot be compared — or when the matcher
    /// proved no unique appeared or disappeared subject. An empty claim is
    /// not a claim.
    static func explain(
        previous: PeriodCheckpointStoredRead,
        current readiness: PeriodCheckpointReadiness
    ) -> VerificationExceptionCorrespondence? {
        guard case let .changedSinceClose(quality, _) = readiness.baselineComparison,
              quality == .withExceptions,
              !readiness.exceptions.isEmpty,
              case let .supported(revision) = previous,
              revision.quality == .withExceptions,
              let projection = readiness.projection,
              let canonical = try? CanonicalSemanticPeriodProjection(projection)
        else { return nil }

        let result = PeriodCheckpointAcknowledgmentMatcher.match(
            previousRevision: revision,
            currentExceptions: readiness.exceptions,
            currentProjection: canonical
        )
        // A single unmatchable subject poisons item-level claims: unique
        // neighbours would look precise next to a guess we refused to make.
        guard result.previousUnmatchable.isEmpty, result.currentUnmatchable.isEmpty else {
            return nil
        }
        let correspondence = VerificationExceptionCorrespondence(
            appeared: counts(result.currentUnmatched),
            disappeared: counts(result.previousDisappeared.map(\.exception))
        )
        return correspondence.isEmpty ? nil : correspondence
    }

    static func counts(
        _ exceptions: [PeriodCheckpointException]
    ) -> VerificationExceptionKindCounts {
        var bankMovements = 0
        var scheduledPayments = 0
        var otherLimitations = 0
        for exception in exceptions {
            switch exception.kind {
            case .unknownBookedEconomics:
                bankMovements += 1
            case .overdueExpectedOccurrence:
                scheduledPayments += 1
            case .uncategorizedEconomicSpending,
                 .aggregateEvidenceModelLimitation,
                 .providerStatusConflict,
                 .unresolvedEvidenceLinkage,
                 .unresolvedEconomicClassification,
                 .unresolvedIncomeClassificationOrOwnership,
                 .acceptedReconciliationAmountDifference:
                otherLimitations += 1
            }
        }
        return VerificationExceptionKindCounts(
            bankMovements: bankMovements,
            scheduledPayments: scheduledPayments,
            otherLimitations: otherLimitations
        )
    }
}
