import FinanceCore
import Foundation

/// One remote account the backend knows about, as the app is allowed to see it.
///
/// `id` is the backend's opaque `acct_…` handle. It is not an IBAN, a provider
/// account uid or an identification hash, and it never reaches a SwiftUI file:
/// screens work in terms of `ProviderAccountBinding`, which omits it.
struct RemoteAccountSummary: Identifiable, Hashable, Sendable {
    let id: String
    let provider: ExternalProvider
    let displayName: String?
    let product: String?
    let cashAccountType: String?
    let currencyCode: String?

    /// The affirmative provider-fetch window the backend reports for this
    /// account: it asked the bank for `syncedFrom ... syncedThrough` and the
    /// fetch succeeded. Both bounds are **inclusive** civil days.
    ///
    /// This is not derived from the observations returned. An account can be
    /// covered for a window in which the bank had nothing to report, which is
    /// exactly why review coverage reads this and never transaction dates.
    /// Either bound being nil means the backend stated no window, which stays
    /// UNKNOWN rather than becoming an empty or assumed one.
    let syncedFrom: Day?
    let syncedThrough: Day?
}

struct RemoteConnectionSummary: Identifiable, Hashable, Sendable {
    let id: String
    let provider: ExternalProvider
    let institution: String?
    let status: String
    let validUntil: Day?
    let lastSuccessfulSyncAt: Date?
    let lastErrorCode: String?
}

/// Whether one page can authoritatively replace app-local current-pending
/// membership. The backend returns complete pending state on every booked
/// observation page; evidence-only test providers may omit this contract.
enum PendingSnapshotAuthority: Sendable {
    case unavailable
    case authoritative([ExternalProvider: AuthoritativePendingSnapshot])
    case invalid
}

/// What one sync pass produced: the evidence, plus everything needed to show
/// Connected Accounts and offer account mapping.
struct BankSyncSnapshot: Sendable {
    var connections: [RemoteConnectionSummary] = []
    var accounts: [RemoteAccountSummary] = []
    var batch: ExternalEvidenceBatch = .init()
    var pendingAuthority: PendingSnapshotAuthority = .unavailable
    /// Cursor for the next page, when the backend had more observations than
    /// one response could carry.
    var nextSince: String?
    var highWater: String? = nil
    /// The complete candidate statement on this wire page. Resolve it after
    /// the booked page walk, when references on other pages are known.
    var wireCandidates: [MobileSnapshot.Candidate]? = nil
}

/// Phase 2.4D transport seam.
///
/// `readEvidence` from 2.4C is now `fetchSnapshot`, because a network call is
/// asynchronous and because mapping needs the remote account list that a bare
/// evidence batch never carried.
protocol BankSyncProviding: Sendable {
    /// Asks the backend to talk to the banks now, with a user present.
    func runRemoteSync() async throws
    func runRemoteSyncWithOutcomes() async throws -> [MobileSyncRun]?
    func startRemoteSync() async throws -> MobileSyncJob?
    func remoteSyncStatus(jobId: String) async throws -> MobileSyncJob

    /// Reads normalized evidence. `bindings` decides which remote accounts are
    /// mapped; evidence for anything else is discarded rather than imported,
    /// so an unmapped Revolut pocket creates no Bank Inbox work.
    func fetchSnapshot(
        bindings: [ExternalAccountBinding],
        since: String?
    ) async throws -> BankSyncSnapshot
}

extension BankSyncProviding {
    func startRemoteSync() async throws -> MobileSyncJob? { nil }
    func remoteSyncStatus(jobId: String) async throws -> MobileSyncJob {
        throw BankSyncClientError.malformedResponse
    }
    func runRemoteSyncWithOutcomes() async throws -> [MobileSyncRun]? {
        try await runRemoteSync()
        return nil
    }
}

/// Safe production default when no endpoint is configured.
struct UnconfiguredBankSyncProvider: BankSyncProviding {
    func runRemoteSync() async throws { throw BankSyncClientError.notConfigured }
    func fetchSnapshot(
        bindings: [ExternalAccountBinding], since: String?
    ) async throws -> BankSyncSnapshot {
        throw BankSyncClientError.notConfigured
    }
}

/// In-memory feed for domain, persistence and product tests.
struct LocalBankSyncProvider: BankSyncProviding {
    var snapshot: BankSyncSnapshot

    init(snapshot: BankSyncSnapshot) { self.snapshot = snapshot }
    init(batch: ExternalEvidenceBatch) { self.snapshot = BankSyncSnapshot(batch: batch) }

    func runRemoteSync() async throws {}
    func fetchSnapshot(
        bindings: [ExternalAccountBinding], since: String?
    ) async throws -> BankSyncSnapshot {
        snapshot
    }
}

/// The live provider: network in, FinanceCore evidence out.
struct LiveBankSyncProvider: BankSyncProviding {
    let client: BankSyncClient

    func runRemoteSync() async throws {
        _ = try await client.startSync()
    }

    func runRemoteSyncWithOutcomes() async throws -> [MobileSyncRun]? {
        try await client.startSync().runs
    }

    func startRemoteSync() async throws -> MobileSyncJob? {
        try await client.startSync()
    }

    func remoteSyncStatus(jobId: String) async throws -> MobileSyncJob {
        try await client.syncStatus(jobId: jobId)
    }

    func fetchSnapshot(
        bindings: [ExternalAccountBinding],
        since: String?
    ) async throws -> BankSyncSnapshot {
        try MobileSnapshotMapper.map(
            try await client.snapshot(since: since),
            bindings: bindings
        )
    }
}

/// Translates the wire contract into domain values.
///
/// Every conversion here is conservative. Evidence for an unmapped account is
/// ignored; malformed evidence for an active mapping fails the whole pull so
/// the device never commits a partial provider statement or guesses money.
enum MobileSnapshotMapper {
    static func map(
        _ snapshot: MobileSnapshot,
        bindings: [ExternalAccountBinding]
    ) throws -> BankSyncSnapshot {
        // Only active bindings receive evidence. A deactivated binding keeps
        // its history readable without accruing new work.
        let bindingByRemote = Dictionary(
            bindings.filter(\.isActive).map { ($0.remoteOpaqueAccountID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let accountProviderByRemote = Dictionary(
            snapshot.accounts.map { ($0.id, ExternalProvider(rawValue: $0.provider)) },
            uniquingKeysWith: { first, _ in first }
        )

        var latestSuccessfulAtByProvider: [ExternalProvider: Date] = [:]
        for connection in snapshot.connections {
            guard let raw = connection.lastSuccessfulSyncAt else { continue }
            let timestamp = try requiredTimestamp(raw)
            let provider = ExternalProvider(rawValue: connection.provider)
            latestSuccessfulAtByProvider[provider] = latestSuccessfulAtByProvider[provider].map { max($0, timestamp) } ?? timestamp
        }

        let relevantProviders = Set(bindingByRemote.values.map(\.provider))
        var invalidPendingProviders: Set<ExternalProvider> = []
        for binding in bindingByRemote.values {
            guard accountProviderByRemote[binding.remoteOpaqueAccountID] == binding.provider else {
                invalidPendingProviders.insert(binding.provider)
                continue
            }
        }
        var currentPendingIDsByProvider: [ExternalProvider: Set<String>] = [:]

        var batch = ExternalEvidenceBatch()
        var keptObservationIDs: Set<String> = []

        for row in snapshot.observations {
            guard let binding = bindingByRemote[row.accountId] else { continue }
            guard accountProviderByRemote[row.accountId] == binding.provider,
                  ExternalProvider(rawValue: row.provider) == binding.provider,
                  let amount = signedMoney(row.amount, row.currency, row.creditDebitIndicator)
            else { throw BankSyncClientError.malformedResponse }
            let derivedDate = try optionalDay(row.derivedTransactionDate)
            // Provenance and derived date exist together or not at all; a date
            // without its audit trail is refused by FinanceCore anyway.
            let provenance = derivedDate == nil
                ? nil
                : row.derivedDateProvenance.map(DerivedExternalDateProvenance.init(providerToken:))
            keptObservationIDs.insert(row.id)
            batch.observations.append(
                ExternalObservation(
                    id: row.id,
                    bindingID: binding.id,
                    provider: binding.provider,
                    identity: .durable,
                    status: ExternalObservationStatus(providerToken: row.status),
                    creditDebitIndicator: ExternalCreditDebitIndicator(
                        providerToken: row.creditDebitIndicator
                    ),
                    amount: amount,
                    bookingDate: try optionalDay(row.bookingDate),
                    transactionDate: try optionalDay(row.transactionDate),
                    valueDate: try optionalDay(row.valueDate),
                    derivedTransactionDate: derivedDate == nil ? nil : derivedDate,
                    derivedDateProvenance: provenance,
                    rawMerchantText: row.rawMerchantText,
                    structuredMerchantName: row.structuredMerchantName,
                    merchantEmail: row.merchantEmail,
                    remittance: row.rawMerchantText,
                    bankTransactionCode: row.bankTransactionCode,
                    bankTransactionSubCode: row.bankTransactionSubCode,
                    eligibleForEconomicActual: row.eligibleForEconomicActual,
                    observedAt: try requiredTimestamp(row.observedAt)
                )
            )
        }

        for row in snapshot.pending {
            // An intentionally unmapped or inactive account is outside the
            // local product surface. It does not make the provider snapshot
            // unsafe and its row is deliberately ignored.
            guard let binding = bindingByRemote[row.accountId] else { continue }
            guard accountProviderByRemote[row.accountId] == binding.provider,
                  latestSuccessfulAtByProvider[binding.provider] != nil,
                  let amount = signedMoney(row.amount, row.currency, row.creditDebitIndicator)
            else {
                // A row that should map but cannot be represented must not let
                // current membership advance past the evidence actually saved.
                invalidPendingProviders.insert(binding.provider)
                continue
            }
            keptObservationIDs.insert(row.id)
            currentPendingIDsByProvider[binding.provider, default: []].insert(row.id)
            batch.observations.append(
                ExternalObservation(
                    id: row.id,
                    bindingID: binding.id,
                    provider: binding.provider,
                    // The backend states this rather than implying it: a pending
                    // row has no durable identity, so it is never fingerprinted
                    // onto the booked row that may later replace it.
                    identity: row.durableIdentity ? .durable : .provisionalSnapshot,
                    status: ExternalObservationStatus(providerToken: row.status),
                    creditDebitIndicator: ExternalCreditDebitIndicator(
                        providerToken: row.creditDebitIndicator ?? ""
                    ),
                    amount: amount,
                    bookingDate: try optionalDay(row.bookingDate),
                    transactionDate: try optionalDay(row.transactionDate),
                    valueDate: try optionalDay(row.valueDate),
                    rawMerchantText: row.rawMerchantText,
                    remittance: row.rawMerchantText,
                    eligibleForEconomicActual: row.eligibleForEconomicActual,
                    observedAt: try requiredTimestamp(row.observedAt)
                )
            )
        }

        let pendingAuthority: PendingSnapshotAuthority
        if invalidPendingProviders.isEmpty {
            var snapshots: [ExternalProvider: AuthoritativePendingSnapshot] = [:]
            for provider in relevantProviders {
                guard let authoritativeAt = latestSuccessfulAtByProvider[provider] else {
                    // No completed provider sync means unknown, not an
                    // authoritative empty snapshot.
                    continue
                }
                snapshots[provider] = AuthoritativePendingSnapshot(
                    authoritativeAt: authoritativeAt,
                    observationIDs: currentPendingIDsByProvider[provider] ?? []
                )
            }
            pendingAuthority = .authoritative(snapshots)
        } else {
            pendingAuthority = .invalid
        }

        for row in snapshot.balances {
            guard let binding = bindingByRemote[row.accountId] else { continue }
            guard accountProviderByRemote[row.accountId] == binding.provider,
                  let currency = row.currency.map({ Currency(code: $0) }),
                  let amount = Money(exactDecimal: row.amount, currency: currency)
            else { throw BankSyncClientError.malformedResponse }
            batch.balances.append(
                ProviderBalanceSnapshot(
                    // One durable row per (account, balance type): re-syncing
                    // updates the snapshot instead of stacking duplicates.
                    id: "balance-\(row.accountId)-\(row.type)",
                    bindingID: binding.id,
                    provider: binding.provider,
                    balanceType: row.type,
                    name: row.name,
                    amount: amount,
                    referenceDate: try optionalDay(row.referenceDate),
                    observedAt: try requiredTimestamp(row.observedAt)
                )
            )
        }

        batch.candidates = try mapCandidates(snapshot.candidates, knownObservationIDs: keptObservationIDs)

        return BankSyncSnapshot(
            connections: try snapshot.connections.map { row in
                RemoteConnectionSummary(
                    id: row.id,
                    provider: ExternalProvider(rawValue: row.provider),
                    institution: row.institution,
                    status: row.status,
                    validUntil: try optionalConsentDay(row.validUntil),
                    lastSuccessfulSyncAt: try optionalTimestamp(row.lastSuccessfulSyncAt),
                    lastErrorCode: row.lastErrorCode
                )
            },
            accounts: try snapshot.accounts.map { row in
                RemoteAccountSummary(
                    id: row.id,
                    provider: ExternalProvider(rawValue: row.provider),
                    displayName: row.displayName,
                    product: row.product,
                    cashAccountType: row.cashAccountType,
                    currencyCode: row.currency,
                    syncedFrom: try optionalDay(row.syncedFrom),
                    syncedThrough: try optionalDay(row.syncedThrough)
                )
            },
            batch: batch,
            pendingAuthority: pendingAuthority,
            nextSince: snapshot.nextSince,
            highWater: snapshot.highWater,
            wireCandidates: snapshot.candidates
        )
    }

    static func mapCandidates(
        _ rows: [MobileSnapshot.Candidate],
        knownObservationIDs: Set<String>
    ) throws -> [CrossProviderCandidate] {
        var result: [CrossProviderCandidate] = []
        for row in rows {
            // A candidate that points at evidence this device did not keep
            // would fail whole-document validation, and it has nothing to
            // suggest anyway.
            guard knownObservationIDs.contains(row.bankObservationId) else { continue }
            let state = CrossProviderCandidateState(providerToken: row.state)
            let wallet = row.walletObservationId.flatMap {
                knownObservationIDs.contains($0) ? $0 : nil
            }
            // `unique` means "one wallet row explains this". Without that row
            // present it is not unique here, whatever the backend concluded
            // across accounts this device has not mapped.
            let resolvedState: CrossProviderCandidateState =
                (state == .unique && wallet == nil) ? .unresolved : state
            guard let code = row.currency,
                  let amount = Money(exactDecimal: row.amount, currency: Currency(code: code))
            else { throw BankSyncClientError.malformedResponse }
            result.append(
                CrossProviderCandidate(
                    id: "candidate-\(row.bankObservationId)",
                    bankObservationID: row.bankObservationId,
                    walletObservationID: resolvedState == .unique ? wallet : nil,
                    state: resolvedState,
                    candidateCount: row.candidateCount,
                    amount: amount,
                    dayOffset: row.dayOffset,
                    rule: row.rule,
                    computedAt: try requiredTimestamp(row.computedAt)
                )
            )
        }
        return result
    }

    /// Applies direction to magnitude.
    ///
    /// The backend reports a signed amount already, but a provider that ever
    /// sent a positive figure with `DBIT` would otherwise turn a debit into a
    /// credit. The indicator is the authority on direction.
    static func signedMoney(_ decimal: String, _ code: String?, _ indicator: String?) -> Money? {
        guard let code, let money = Money(exactDecimal: decimal, currency: Currency(code: code))
        else { return nil }
        switch ExternalCreditDebitIndicator(providerToken: indicator ?? "") {
        case .debit: return money.isPositive ? money.negated : money
        case .credit: return money.isNegative ? money.negated : money
        case .other: return money
        }
    }

    static func requiredTimestamp(_ iso: String) throws -> Date {
        guard let date = parsedDate(iso) else { throw BankSyncClientError.malformedResponse }
        return date
    }

    static func optionalTimestamp(_ iso: String?) throws -> Date? {
        guard let iso else { return nil }
        return try requiredTimestamp(iso)
    }

    static func optionalDay(_ iso: String?) throws -> Day? {
        guard let iso else { return nil }
        guard let day = Day(isoString: iso) else { throw BankSyncClientError.malformedResponse }
        return day
    }

    static func optionalConsentDay(_ raw: String?) throws -> Day? {
        guard let raw else { return nil }
        if let day = Day(isoString: raw) { return day }
        _ = try requiredTimestamp(raw)
        return try optionalDay(String(raw.prefix(10)))
    }

    static func parsedDate(_ iso: String) -> Date? {
        // Foundation's parser may accept trailing junk or normalize invalid
        // components. Validate the complete supplied timestamp first.
        let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]+)?(?:[Zz]|[+-](?:[01][0-9]|2[0-3]):?[0-5][0-9])$"#
        guard iso.range(of: pattern, options: .regularExpression) != nil,
              Day(isoString: String(iso.prefix(10))) != nil else { return nil }
        return ISO8601DateFormatter.bankSyncFractional.date(from: iso)
            ?? ISO8601DateFormatter.bankSyncPlain.date(from: iso)
    }
}

extension ISO8601DateFormatter {
    static let bankSyncFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let bankSyncPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
