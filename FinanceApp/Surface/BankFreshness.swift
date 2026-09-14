import Foundation

/// Whether the money on screen is as current as the bank last said it was.
///
/// One question — "is my bank data current?" — answered from what the sync
/// layer already reports, with no network call and no engine involvement.
/// Healthy infrastructure is deliberately quiet: a connection that synced an
/// hour ago produces one short caption and nothing to tap. Only a state that
/// needs a decision becomes an exception worth surfacing on Home.
enum BankFreshness: Equatable, Sendable {
    /// No provider connection at all. Entering transactions by hand is a way
    /// to use this app, not a fault, so this state says nothing.
    case notConnected
    /// Paired, but no successful sync has landed yet.
    case neverSynced
    /// Synced, recently enough to trust. The date is the oldest successful
    /// provider `lastSyncedAt` among connections that do not need attention.
    case updated(Date)
    /// Synced, but long enough ago that the balances may have moved since.
    case stale(Date)
    /// A connection is revoked, expired, or the last sync failed. Needs a
    /// person, and says so.
    case needsAttention

    /// Two days. Long enough that a weekend without a sync is not an alarm,
    /// short enough that a silently dead connection surfaces within a day of
    /// mattering.
    static let staleAfter: TimeInterval = 48 * 60 * 60

    /// Canonical product input. Home, Accounts and Settings all call the
    /// store's one summary, which reaches this overload with the same snapshot.
    ///
    /// `CurrentPendingProviderSnapshot.authoritativeAt` is useful here because
    /// it is imported directly from provider `lastSuccessfulSyncAt` even when
    /// the successful snapshot contains zero pending rows. It is not a pending
    /// row timestamp, a balance `observedAt`, or a local HTTP completion clock.
    /// Keeping it app-local also lets freshness survive a relaunch, while the
    /// full remote connection directory remains deliberately read-through.
    static func evaluate(
        snapshot: FinanceAppSnapshot,
        activity: BankSyncActivity,
        pairing: BankPairingState,
        reference: Date
    ) -> BankFreshness {
        let relevantProviders = Set(
            snapshot.providerAccountBindings
                .filter(\.isActive)
                .map(\.providerName)
        )
        let successfulSyncs = Dictionary(
            snapshot.currentPendingProviderSnapshots.map {
                ($0.providerName, $0.authoritativeAt)
            },
            uniquingKeysWith: min
        )
        return evaluate(
            connections: snapshot.providerConnections,
            relevantProviderNames: relevantProviders,
            providerSuccessfulSyncAt: successfulSyncs,
            activity: activity,
            pairing: pairing,
            reference: reference
        )
    }

    static func evaluate(
        connections: [ProviderConnectionStatus],
        relevantProviderNames: Set<String> = [],
        providerSuccessfulSyncAt: [String: Date] = [:],
        activity: BankSyncActivity,
        pairing: BankPairingState,
        reference: Date
    ) -> BankFreshness {
        let providers = relevantProviderNames.isEmpty
            ? Set(connections.map(\.providerName))
            : relevantProviderNames
        let relevantConnections = providers.isEmpty
            ? connections
            : connections.filter { providers.contains($0.providerName) }

        if relevantConnections.contains(where: \.state.needsAttention) { return .needsAttention }
        if relevantConnections.contains(where: { $0.state == .expiringSoon }) { return .needsAttention }
        if relevantConnections.contains(where: { $0.lastErrorMessage != nil }) { return .needsAttention }
        if pairing == .revoked { return .needsAttention }
        if case .failed = activity { return .needsAttention }

        // Healthy "all banks current as of X" is only as current as the
        // stalest successful provider fetch. A local HTTP-200 timestamp is
        // not that: it fires after snapshot import even when a provider
        // was skipped, and it fires on pairing/snapshot-only with no
        // user-present bank round-trip.
        //
        // `activity.succeeded` is ignored here on purpose. Banks & Sync can
        // still say this button press finished; Home talks about provider
        // state imported from the snapshot.
        var stamps: [Date?] = []
        if providers.isEmpty {
            stamps = relevantConnections.map(\.lastSyncedAt)
        } else {
            for provider in providers.sorted() {
                let live = relevantConnections.filter { $0.providerName == provider }
                if live.isEmpty {
                    stamps.append(providerSuccessfulSyncAt[provider])
                } else {
                    // A currently imported connection row outranks the
                    // relaunch fallback. A missing timestamp therefore stays
                    // never-synced rather than borrowing an older success.
                    stamps.append(contentsOf: live.map(\.lastSyncedAt))
                }
            }
        }
        if !stamps.isEmpty, stamps.contains(where: { $0 == nil }) {
            return .neverSynced
        }
        let lastSync = stamps.compactMap { $0 }.min()

        guard let lastSync else {
            // Nothing has ever arrived. Distinguish "not set up" from "set up
            // and silent": only the second one is worth a caption.
            if providers.isEmpty && relevantConnections.isEmpty
                && (pairing == .notConfigured || pairing == .unpaired) {
                return .notConnected
            }
            return .neverSynced
        }

        if reference.timeIntervalSince(lastSync) > staleAfter { return .stale(lastSync) }
        return .updated(lastSync)
    }

    /// True when the state is an exception a person should be able to tap
    /// straight through to. Everything else stays chrome.
    var requiresAction: Bool {
        switch self {
        case .neverSynced, .needsAttention, .stale: true
        case .notConnected, .updated: false
        }
    }

    /// The sentence shown under the cash figure. `nil` means say nothing.
    func caption(relativeTo reference: Date) -> String? {
        switch self {
        case .notConnected:
            Optional<String>.none
        case .neverSynced:
            "Not synced yet"
        case .updated(let date):
            Self.syncedCaption(of: date, relativeTo: reference)
        case .stale(let date):
            "Last sync \(Self.age(of: date, relativeTo: reference)) · check sync"
        case .needsAttention:
            "Bank sync needs attention"
        }
    }

    /// "Synced" names the operation we know occurred. "Updated" would claim
    /// the ledger changed, which a successful fetch of already-known rows does
    /// not.
    static func syncedCaption(of date: Date, relativeTo reference: Date) -> String {
        let age = age(of: date, relativeTo: reference)
        return age == "just now" ? "Synced just now" : "Last sync \(age)"
    }

    /// Written out rather than handed to `RelativeDateTimeFormatter` so the
    /// wording is the same in a test, a screenshot and a fixture whose clock is
    /// not this machine's.
    static func age(of date: Date, relativeTo reference: Date) -> String {
        let minutes = Int(reference.timeIntervalSince(date) / 60)
        if minutes < 2 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
        let days = hours / 24
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }
}

extension FinanceAppSnapshot {
    /// Freshness is elapsed instant time. A structural financial as-of day
    /// does not supply a clock; callers inject the actual reference instant.
    func freshnessReference(now: Date = .now) -> Date {
        now
    }
}

/// A coherent answer for one rendering/composition operation.
struct BankFreshnessEvaluation {
    let state: BankFreshness
    let reference: Date
    var caption: String? { state.caption(relativeTo: reference) }
}
