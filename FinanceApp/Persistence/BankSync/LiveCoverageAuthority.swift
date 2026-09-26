import FinanceCore
import Foundation

/// Turns one *complete* mobile snapshot into per-account affirmative live
/// coverage.
///
/// The backend writes `syncedFrom`/`syncedThrough` only after a transaction
/// fetch for that account succeeds, and from the window it requested rather
/// than from the rows that came back. That is what makes it usable as review
/// coverage: an account stays covered across a window in which the bank had
/// nothing to report. Nothing here reads observation dates, balance
/// `observedAt`, or the binding's `syncStartBoundary`.
///
/// Every rule below fails closed. An account this type cannot vouch for is
/// simply absent from the result, and an absent account is UNKNOWN — never a
/// zero-length window and never a borrowed one.
enum LiveCoverageAuthority {

    /// Coverage established by a terminal snapshot page, keyed by remote
    /// opaque account id.
    ///
    /// - Parameters:
    ///   - accounts: the final page's remote account directory.
    ///   - connections: the final page's connection directory, which carries
    ///     the provider `lastSuccessfulSyncAt` that authorises the window.
    ///   - bindings: the document's bindings. Only active ones participate.
    static func coverage(
        accounts: [RemoteAccountSummary],
        connections: [RemoteConnectionSummary],
        bindings: [ExternalAccountBinding]
    ) -> [String: AuthoritativeLiveCoverage] {
        // The same provider clock that authorises pending membership. A
        // provider that has never completed a sync authorises nothing, so its
        // accounts stay unknown rather than claiming today's window.
        var latestSuccessfulAtByProvider: [ExternalProvider: Date] = [:]
        for connection in connections {
            guard let timestamp = connection.lastSuccessfulSyncAt else { continue }
            latestSuccessfulAtByProvider[connection.provider] = latestSuccessfulAtByProvider[connection.provider].map { max($0, timestamp) } ?? timestamp
        }

        let accountByRemote = Dictionary(
            accounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var result: [String: AuthoritativeLiveCoverage] = [:]
        for binding in bindings where binding.isActive {
            guard let account = accountByRemote[binding.remoteOpaqueAccountID],
                  // A directory row filed under a different provider than the
                  // binding claims is a mismatch, not a window to trust.
                  account.provider == binding.provider,
                  let authoritativeAt = latestSuccessfulAtByProvider[binding.provider],
                  // Either bound missing means the backend stated no window.
                  let from = account.syncedFrom,
                  let through = account.syncedThrough,
                  from <= through
            else { continue }
            result[binding.remoteOpaqueAccountID] = AuthoritativeLiveCoverage(
                provider: binding.provider,
                remoteOpaqueAccountID: binding.remoteOpaqueAccountID,
                localAccountID: binding.localAccountID,
                syncedFrom: from,
                syncedThrough: through,
                authoritativeAt: authoritativeAt
            )
        }
        return result
    }

    /// Merges newly established windows over previously persisted ones.
    ///
    /// Per-account scopes stay independent: a snapshot that establishes BNP
    /// must not erase a PayPal window it said nothing about, exactly as a
    /// response establishing one provider's pending membership leaves another
    /// provider's authority alone.
    ///
    /// A newly reported window replaces the stored one for that account rather
    /// than being unioned with it. The backend already widens its own window
    /// with `MIN`/`MAX`, so its latest statement is the complete one, and
    /// widening it again here would invent coverage the backend never
    /// reported.
    static func merged(
        previous: [String: AuthoritativeLiveCoverage],
        established: [String: AuthoritativeLiveCoverage]
    ) -> [String: AuthoritativeLiveCoverage] {
        previous.merging(established) { old, new in
            new.authoritativeAt >= old.authoritativeAt ? new : old
        }
    }
}
