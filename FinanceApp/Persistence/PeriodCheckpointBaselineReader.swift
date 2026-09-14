import FinanceCore
import Foundation

/// The one production path from stored checkpoint history to a baseline
/// comparison.
///
/// ## Why this exists as a single type
///
/// Two conversions have to happen for a period to know where it stands against
/// its own last close, and both are easy to get subtly wrong in a way no
/// screen would reveal:
///
/// 1. *persistence → domain* — a `PeriodCheckpointStoredRead` is four distinct
///    facts, and three of them are not "there is no baseline". Collapsing them
///    is how "history exists but cannot be trusted" turns into "this period was
///    never closed".
/// 2. *(baseline, current) → comparison* — which is `PeriodCheckpointBaselineComparator`'s
///    job and no one else's.
///
/// Keeping both here means there is exactly one answer to "has this period
/// changed since it was closed?" in the product. Views, surface mappers and the
/// attention composition read the comparison; none of them sees a
/// `StoredPeriodCheckpointRevision`, a `PeriodCheckpointStoredRead` or a
/// canonical payload.
///
/// ## What this file does not do
///
/// It writes nothing. There is no `store`, no `compareAndAppend`, no close and
/// no re-verify: reading where a period stands is not authority to change it.
/// It replays nothing either — a stored revision is historical authority and
/// arrives already rehydrated by the repository, and the current side arrives
/// as an already-evaluated `PeriodCheckpointReadiness`. No `ReviewEngine`, no
/// `ReviewTotals`, no second projection.
enum PeriodCheckpointBaselineReader {

    // MARK: - Persistence → domain

    /// The baseline for one **exact** period, read once.
    ///
    /// The history key is start day + end day + kind, which is what
    /// `latestRevision` takes. Store-wide occupancy is deliberately not
    /// consulted: it answers a global import-safety question, and a corrupt
    /// March must not stop September being compared to its own close.
    @MainActor
    static func source(
        from repository: PeriodCheckpointRepository,
        period: SemanticInterval,
        kind: ReviewPeriodKind
    ) -> PeriodCheckpointBaselineSource {
        source(for: repository.latestRevision(inPeriod: period, kind: kind))
    }

    /// One stored read as the comparator consumes it.
    ///
    /// The four states stay four states:
    ///
    /// - `.empty` — read successfully, nothing stored. `.noRevision`, which the
    ///   comparator turns into the established fact `.notPreviouslyClosed`.
    ///   Never `.unavailable`: the first close is an ordinary close.
    /// - `.supported` — the revision this build wrote and validated.
    /// - `.unsupportedFormat` — readable header, a projection format written by
    ///   a later build. A baseline that exists and needs re-verification, **not**
    ///   corruption, and its payload is never parsed.
    /// - `.corrupt` — history exists and cannot be trusted. Baseline
    ///   unavailable, which is a different statement from "never closed" and
    ///   must stay one.
    static func source(for read: PeriodCheckpointStoredRead) -> PeriodCheckpointBaselineSource {
        switch read {
        case .empty:
            .noRevision
        case let .supported(revision):
            .latest(PeriodCheckpointBaseline(revision))
        case let .unsupportedFormat(header):
            unreadableFormat(header)
        case .corrupt:
            // Includes every fetch failure: the repository maps a subgraph it
            // cannot query onto `.corrupt(.storeUnreadable)`, so no exception
            // can escape into a false emptiness here.
            .unavailable(.baselineProjectionUnreadable)
        }
    }

    /// A stored baseline whose format this build cannot compare in.
    ///
    /// Period, kind, recorded quality and the raw token carry through
    /// unchanged; no bytes do. The throw is unreachable — the repository
    /// returns `.unsupportedFormat` exactly when `SemanticPeriodProjectionFormat`
    /// refuses the token, which is the same condition this initializer
    /// requires — and it fails closed rather than being force-unwrapped,
    /// because a disagreement between the reader and the comparator about what
    /// this build supports is a reason to distrust the baseline, not to crash
    /// on a person's history.
    private static func unreadableFormat(
        _ header: PeriodCheckpointStoredHeader
    ) -> PeriodCheckpointBaselineSource {
        do {
            return .latest(
                try PeriodCheckpointBaseline(
                    period: header.period,
                    periodKind: header.periodKind,
                    previousQuality: header.previousQuality,
                    unreadableFormatToken: header.formatToken
                )
            )
        } catch {
            return .unavailable(.baselineProjectionUnreadable)
        }
    }

    // MARK: - Comparison

    /// Where the period stands, against the baseline the source holds.
    ///
    /// The current side is built from `PeriodCheckpointReadiness` and from
    /// nothing else. That is the authoritative path and the low-level
    /// `PeriodCheckpointCurrentState(_ payload:)` primitive is deliberately not
    /// used here: it trusts the caller's claim that the projection is
    /// comparable, and reaching past readiness would let a period whose own
    /// coverage or evidence is insufficient report `.changedSinceClose` where
    /// the truth is `.indeterminate`.
    ///
    /// Every comparison rule — format incompatibility outranking current
    /// comparability, digest equality, change classification — belongs to
    /// `PeriodCheckpointBaselineComparator` and is not restated.
    ///
    /// - Returns: the comparator's answer. A thrown comparison error means the
    ///   request or the classifier failed an invariant, never that the period
    ///   moved, so it becomes an unreadable baseline rather than a claim.
    static func comparison(
        baseline: PeriodCheckpointBaselineSource,
        current readiness: PeriodCheckpointReadiness
    ) -> PeriodCheckpointBaselineComparison {
        do {
            return try PeriodCheckpointBaselineComparator.compare(
                baseline: baseline,
                current: PeriodCheckpointCurrentState(readiness)
            )
        } catch {
            // `periodMismatch` and `periodKindMismatch` are unreachable while
            // the caller reads by the readiness's own exact period and kind;
            // `unclassifiedChange` means the classifier could not name a
            // difference it found. All three say the baseline cannot be
            // trusted for this period — never that it is absent, and never
            // that the period is unchanged.
            return .unavailable(.baselineProjectionUnreadable)
        }
    }
}
