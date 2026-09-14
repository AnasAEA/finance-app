import FinanceCore
import Foundation

/// What the app can affirmatively say about live bank coverage for a review.
///
/// `unknownAccountIDs` is not a diagnostic afterthought: whenever it is
/// non-empty `intervals` is empty, because a global claim that a period is
/// covered has to hold for every account that could have contributed to it.
struct LiveCoverageResolution: Hashable, Sendable {
    /// Days every relevant account affirmatively covers. Empty means no global
    /// claim can be made.
    let intervals: [ReviewInterval]
    /// Local account ids that are relevant but have no authoritative window.
    let unknownAccountIDs: [String]
    /// Local account ids that carry an authoritative window.
    let knownAccountIDs: [String]

    var isKnown: Bool { unknownAccountIDs.isEmpty && !knownAccountIDs.isEmpty }
}

/// Builds `ReviewCoverageInput` out of what the app actually knows.
///
/// Two rules govern everything here.
///
/// **Only affirmative provider-fetch metadata counts.** Not observation dates,
/// not `syncStartBoundary`, not balance `observedAt`, not a connection's
/// `lastSuccessfulSyncAt` on its own. A day is live-covered because the
/// backend said it fetched that day for that account and succeeded.
///
/// **A global claim needs every relevant account.** `ReviewCoverageInput`
/// carries one set of live intervals rather than per-source coverage
/// (`additionalSourceGaps` is month-granular and subtractive, too coarse to
/// express a per-account day window), so the honest global window is the
/// **intersection** across relevant accounts, never their union. One account
/// with a wider window must not hide a narrower or unknown one.
enum ReviewCoverageAdapter {

    /// Accounts whose bank activity can contribute economic history to a
    /// review in `currency`.
    ///
    /// Included: every active binding onto an active local account held in the
    /// review currency. Zero transactions is **not** an exclusion — an account
    /// that was quiet still has to be covered for "no spending" to be true.
    ///
    /// Excluded: inactive or unmapped bindings, bindings pointing at an
    /// account the document no longer has, and accounts in another currency,
    /// which cannot contribute to a euro-only total under the no-FX policy.
    static func relevantBindings(
        bindings: [ExternalAccountBinding],
        accounts: [Account],
        currency: Currency
    ) -> [ExternalAccountBinding] {
        let accountByID = Dictionary(
            accounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return bindings
            .filter { binding in
                guard binding.isActive,
                      let account = accountByID[binding.localAccountID],
                      account.isActive,
                      account.currency == currency
                else { return false }
                return true
            }
            .sorted { $0.id < $1.id }
    }

    /// The conservative global live window.
    ///
    /// Intersection, not union. Any relevant account without an authoritative
    /// window makes the whole live claim unknown, which leaves live-era days
    /// uncovered and the review honestly partial or insufficient.
    static func liveCoverage(
        coverage: [String: AuthoritativeLiveCoverage],
        bindings: [ExternalAccountBinding],
        accounts: [Account],
        currency: Currency
    ) -> LiveCoverageResolution {
        let relevant = relevantBindings(
            bindings: bindings, accounts: accounts, currency: currency
        )
        guard !relevant.isEmpty else {
            // No bank account can contribute, so no provider fetch can vouch
            // for these days. Fail closed rather than calling the period
            // covered by default.
            return LiveCoverageResolution(
                intervals: [], unknownAccountIDs: [], knownAccountIDs: []
            )
        }

        var known: [String] = []
        var unknown: [String] = []
        var windows: [ReviewInterval] = []
        for binding in relevant {
            guard let window = coverage[binding.remoteOpaqueAccountID]?.interval else {
                unknown.append(binding.localAccountID)
                continue
            }
            known.append(binding.localAccountID)
            windows.append(window)
        }

        guard unknown.isEmpty, !windows.isEmpty else {
            return LiveCoverageResolution(
                intervals: [],
                unknownAccountIDs: unknown.sorted(),
                knownAccountIDs: known.sorted()
            )
        }

        let start = windows.map(\.start).max()!
        let end = windows.map(\.end).min()!
        return LiveCoverageResolution(
            intervals: start <= end ? [ReviewInterval(start: start, end: end)] : [],
            unknownAccountIDs: [],
            knownAccountIDs: known.sorted()
        )
    }

    /// Composes archive and live coverage across the exact existing boundary.
    ///
    /// The archive owns days through `archiveCutoff` inclusive and the live
    /// ledger owns days after it, which is `HistoryArchiveBoundary`'s rule.
    /// Nothing widens one side to cover the other: if the live window starts
    /// later than `archiveCutoff + 1`, the days in between stay uncovered and
    /// the engine reports them.
    ///
    /// - Parameters:
    ///   - archiveCutoff: the installed archive's cutoff, or nil when no
    ///     archive is installed.
    ///   - history: the reconstructed archive document. Required for any
    ///     archive-era day to be complete; passing nil leaves those days
    ///     reported as `archiveHistoryAbsent` rather than silently zero.
    ///   - live: the resolved conservative live window.
    static func coverageInput(
        archiveCutoff: Day?,
        history: FinanceHistoryDocument?,
        live: LiveCoverageResolution
    ) -> ReviewCoverageInput {
        ReviewCoverageInput(
            archiveCutoff: archiveCutoff,
            history: history,
            liveCoveredIntervals: live.intervals,
            additionalSourceGaps: []
        )
    }
}
