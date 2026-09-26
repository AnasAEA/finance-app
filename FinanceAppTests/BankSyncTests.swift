import Foundation
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

/// What arriving bank data is and is not allowed to do.
///
/// Every fixture here is synthetic. The shapes reproduce what the three real
/// providers report — a PayPal wallet row beside the bank row that settles it,
/// a pending row with no durable identity, dormant non-EUR pockets — without
/// reproducing any real account, merchant or amount.
// Serialized: each test drives a whole store through several sync passes, and
// running them concurrently contends for the shared Keychain service and the
// SwiftData stores behind them.
@Suite("Live bank sync", .serialized)
@MainActor
struct BankSyncTests {
    private let boundary = Day(year: 2026, month: 8, day: 22)
    private let observedAt = Date(timeIntervalSince1970: 1_777_680_000)

    // MARK: - Fixtures

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// A ledger with the five local accounts this app actually has.
    private func localDocument() -> FinanceDocument {
        let accounts = [
            Account(id: "bnp", name: "BNP", currency: .eur, kind: .bank, supportedRails: [.cardDebit]),
            Account(id: "revolut", name: "Revolut", currency: .eur, kind: .wallet, supportedRails: [.cardDebit]),
            Account(id: "paypal", name: "PayPal", currency: .eur, kind: .wallet, supportedRails: [.electronicPayment]),
            Account(id: "cash-eur", name: "Cash EUR", currency: .eur, kind: .cash, supportedRails: [.physicalCash]),
            Account(id: "cash-mad", name: "Cash MAD", currency: .mad, kind: .cash, supportedRails: [.physicalCash]),
        ]
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: accounts,
            balances: accounts.map {
                AccountBalance(
                    accountID: $0.id,
                    balance: Money(minorUnits: $0.id == "bnp" ? 30_000 : 1_000, currency: $0.currency),
                    asOf: boundary
                )
            }
        )
    }

    /// A store and the container behind it.
    ///
    /// Both, deliberately: a `ModelContext` does not keep its `ModelContainer`
    /// alive, and a helper that returns only the store leaves every test
    /// working against a deallocated container, which traps on the first write.
    private struct Harness {
        let container: ModelContainer
        let store: FinanceStore
    }

    private func harness(
        _ document: FinanceDocument? = nil,
        writer: DocumentWriter? = nil,
        forecastRunner: ((ForecastRequest) throws -> ForecastResult)? = nil
    ) throws -> Harness {
        let container = try container()
        try StoredDocumentGraph.replace(
            with: document ?? localDocument(),
            in: container.mainContext,
            writtenOn: boundary
        )
        return Harness(
            container: container,
            store: try FinanceStore(
                context: container.mainContext,
                clock: { fixtureInstant(Day(year: 2026, month: 8, day: 28)) },
                forecastRunner: forecastRunner ?? ForecastEngine.run,
                writer: writer ?? .live,
                identityStore: DeviceIdentityStore(service: "test.banksync.\(UUID().uuidString)")
            )
        )
    }

    /// The remote side: three usable accounts plus four dormant Revolut pockets.
    private func remoteSnapshot(
        observationDay: Int = 26,
        bankStatus: String = "BOOK",
        bankEligible: Bool = true,
        includePending: Bool = true
    ) -> MobileSnapshot {
        let day = String(format: "2026-08-%02d", observationDay)
        return MobileSnapshot(
            contractVersion: 1,
            serverTime: "2026-08-28T12:00:00.000Z",
            connections: [
                .init(id: "conn_bnp", provider: "bnp", institution: "Test Bank",
                      status: "connected", validUntil: "2027-02-24T00:00:00.000Z",
                      lastSuccessfulSyncAt: "2026-08-28T11:00:00.000Z", lastErrorCode: nil),
                .init(id: "conn_paypal", provider: "paypal", institution: "Test Wallet",
                      status: "expiringSoon", validUntil: "2026-09-05T00:00:00.000Z",
                      lastSuccessfulSyncAt: "2026-08-28T11:00:00.000Z", lastErrorCode: nil),
                .init(id: "conn_revolut", provider: "revolut", institution: "Test Neobank",
                      status: "reauthorizationRequired", validUntil: "2026-08-20T00:00:00.000Z",
                      lastSuccessfulSyncAt: nil, lastErrorCode: "SESSION_EXPIRED"),
            ],
            accounts: [
                .init(id: "acct_bnp", provider: "bnp", connectionId: "conn_bnp",
                      displayName: "Current account", product: "Compte", cashAccountType: "CACC",
                      usage: "PRIV", currency: "EUR", syncedFrom: nil, syncedThrough: nil),
                .init(id: "acct_rev_eur", provider: "revolut", connectionId: "conn_revolut",
                      displayName: "Revolut EUR", product: nil, cashAccountType: "CACC",
                      usage: "PRIV", currency: "EUR", syncedFrom: nil, syncedThrough: nil),
                .init(id: "acct_paypal", provider: "paypal", connectionId: "conn_paypal",
                      displayName: "PayPal balance", product: nil, cashAccountType: nil,
                      usage: nil, currency: "EUR", syncedFrom: nil, syncedThrough: nil),
                // Dormant pockets. Nothing may be created for these.
                .init(id: "acct_rev_mad", provider: "revolut", connectionId: "conn_revolut",
                      displayName: "Revolut MAD", product: nil, cashAccountType: nil,
                      usage: nil, currency: "MAD", syncedFrom: nil, syncedThrough: nil),
                .init(id: "acct_rev_chf", provider: "revolut", connectionId: "conn_revolut",
                      displayName: "Revolut CHF", product: nil, cashAccountType: nil,
                      usage: nil, currency: "CHF", syncedFrom: nil, syncedThrough: nil),
                .init(id: "acct_rev_try", provider: "revolut", connectionId: "conn_revolut",
                      displayName: "Revolut TRY", product: nil, cashAccountType: nil,
                      usage: nil, currency: "TRY", syncedFrom: nil, syncedThrough: nil),
                .init(id: "acct_rev_kzt", provider: "revolut", connectionId: "conn_revolut",
                      displayName: "Revolut KZT", product: nil, cashAccountType: nil,
                      usage: nil, currency: "KZT", syncedFrom: nil, syncedThrough: nil),
            ],
            balances: [
                .init(accountId: "acct_bnp", type: "CLBD", name: nil, amount: "364.56",
                      currency: "EUR", referenceDate: "2026-08-28",
                      observedAt: "2026-08-28T12:00:00.000Z"),
                .init(accountId: "acct_rev_mad", type: "CLBD", name: nil, amount: "500.00",
                      currency: "MAD", referenceDate: "2026-08-28",
                      observedAt: "2026-08-28T12:00:00.000Z"),
            ],
            observations: [
                .init(id: "obs_bank", accountId: "acct_bnp", provider: "bnp",
                      status: bankStatus, creditDebitIndicator: "DBIT", amount: "-7.99",
                      currency: "EUR", bookingDate: day, transactionDate: nil, valueDate: nil,
                      derivedTransactionDate: nil, derivedDateProvenance: nil,
                      rawMerchantText: "SYNTHETIC WALLET EUROPE", structuredMerchantName: nil,
                      merchantEmail: nil, bankTransactionCode: nil, bankTransactionSubCode: nil,
                      eligibleForEconomicActual: bankEligible,
                      observedAt: "2026-08-28T12:00:00.000Z"),
                .init(id: "obs_wallet", accountId: "acct_paypal", provider: "paypal",
                      status: "BOOK", creditDebitIndicator: "DBIT", amount: "-7.99",
                      currency: "EUR", bookingDate: nil, transactionDate: day, valueDate: nil,
                      derivedTransactionDate: nil, derivedDateProvenance: nil,
                      rawMerchantText: nil, structuredMerchantName: "Synthetic Merchant Ireland",
                      merchantEmail: nil, bankTransactionCode: nil, bankTransactionSubCode: nil,
                      eligibleForEconomicActual: true,
                      observedAt: "2026-08-28T12:00:00.000Z"),
                // Belongs to a pocket nobody mapped.
                .init(id: "obs_dormant", accountId: "acct_rev_mad", provider: "revolut",
                      status: "BOOK", creditDebitIndicator: "DBIT", amount: "-40.00",
                      currency: "MAD", bookingDate: day, transactionDate: nil, valueDate: nil,
                      derivedTransactionDate: nil, derivedDateProvenance: nil,
                      rawMerchantText: "SYNTHETIC POCKET", structuredMerchantName: nil,
                      merchantEmail: nil, bankTransactionCode: nil, bankTransactionSubCode: nil,
                      eligibleForEconomicActual: true,
                      observedAt: "2026-08-28T12:00:00.000Z"),
            ],
            pending: includePending ? [
                .init(id: "pend_1", accountId: "acct_bnp", status: "PDNG",
                      creditDebitIndicator: "DBIT", amount: "-12.00", currency: "EUR",
                      bookingDate: nil, transactionDate: nil, valueDate: nil,
                      rawMerchantText: "SYNTHETIC PENDING", observedAt: "2026-08-28T12:00:00.000Z",
                      durableIdentity: false, eligibleForEconomicActual: false),
            ] : [],
            candidates: [
                .init(bankObservationId: "obs_bank", walletObservationId: "obs_wallet",
                      state: "unique", candidateCount: 1, amount: "7.99", currency: "EUR",
                      dayOffset: 0, rule: "synthetic_rule", computedAt: "2026-08-28T12:00:00.000Z"),
            ],
            nextSince: nil
        )
    }

    private func provider(_ snapshot: MobileSnapshot) -> any BankSyncProviding {
        LocalBankSyncProviderFromWire(snapshot: snapshot)
    }

    @Test("An older overlapping bank read cannot replace the newer pending set")
    func overlappingReadsKeepNewerResult() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        try mapRealAccounts(store)

        let gate = SnapshotGate()
        let old = replacing(remoteSnapshot(includePending: false), pending: [pendingRow("pending-old")])
        let new = replacing(remoteSnapshot(includePending: false), pending: [pendingRow("pending-new")])
        let olderTask = Task {
            try await store.importBankEvidence(from: DelayedBankSyncProvider(snapshot: old, gate: gate))
        }
        await gate.waitForStart()
        try await store.importBankEvidence(from: provider(new))
        await gate.release()
        try await olderTask.value
        #expect(store.snapshot.currentPendingSyncedObservations.map(\.id) == ["pending-new"])
    }

    @Test("A successful empty directory clears old remote accounts")
    func emptyDirectoryClearsReadThroughRows() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        #expect(!store.snapshot.mappableRemoteAccounts.isEmpty)
        let empty = MobileSnapshot(
            contractVersion: 1, serverTime: "2026-08-29T12:00:00.000Z",
            connections: [], accounts: [], balances: [], observations: [], pending: [],
            candidates: [], nextSince: nil
        )
        try await store.importBankEvidence(from: provider(empty))
        #expect(store.snapshot.mappableRemoteAccounts.isEmpty)
        #expect(store.snapshot.providerConnections.isEmpty)
    }

    private func pendingRow(
        _ id: String,
        accountID: String = "acct_bnp",
        amount: String = "3.99",
        direction: String = "DBIT"
    ) -> MobileSnapshot.Pending {
        MobileSnapshot.Pending(
            id: id,
            accountId: accountID,
            status: "PDNG",
            creditDebitIndicator: direction,
            amount: amount,
            currency: "EUR",
            bookingDate: "2026-08-31",
            transactionDate: nil,
            valueDate: nil,
            rawMerchantText: nil,
            observedAt: "2026-08-31T11:00:00.000Z",
            durableIdentity: false,
            eligibleForEconomicActual: false
        )
    }

    private func replacing(
        _ snapshot: MobileSnapshot,
        pending: [MobileSnapshot.Pending],
        connections: [MobileSnapshot.Connection]? = nil,
        observations: [MobileSnapshot.Observation]? = nil,
        candidates: [MobileSnapshot.Candidate]? = nil,
        nextSince: String? = nil,
        highWater: String? = nil
    ) -> MobileSnapshot {
        var result = MobileSnapshot(
            contractVersion: snapshot.contractVersion,
            serverTime: snapshot.serverTime,
            connections: connections ?? snapshot.connections,
            accounts: snapshot.accounts,
            balances: snapshot.balances,
            observations: observations ?? snapshot.observations,
            pending: pending,
            candidates: candidates ?? snapshot.candidates,
            nextSince: nextSince
        )
        result.highWater = highWater
        return result
    }

    private func pageSnapshot(
        ids: [String],
        pending: [MobileSnapshot.Pending] = [],
        nextSince: String?,
        highWater: String? = nil
    ) -> MobileSnapshot {
        let base = remoteSnapshot(includePending: false)
        let observations = ids.map { id in
            MobileSnapshot.Observation(
                id: id, accountId: "acct_paypal", provider: "paypal",
                status: "BOOK", creditDebitIndicator: "DBIT", amount: "-7.99",
                currency: "EUR", bookingDate: nil, transactionDate: "2026-08-26", valueDate: nil,
                derivedTransactionDate: nil, derivedDateProvenance: nil,
                rawMerchantText: nil, structuredMerchantName: nil,
                merchantEmail: nil, bankTransactionCode: nil, bankTransactionSubCode: nil,
                eligibleForEconomicActual: true,
                observedAt: "2026-08-31T11:29:05.626Z"
            )
        }
        var result = MobileSnapshot(
            contractVersion: base.contractVersion,
            serverTime: base.serverTime,
            connections: base.connections,
            accounts: base.accounts,
            balances: base.balances,
            observations: observations,
            pending: pending,
            candidates: [],
            nextSince: nextSince
        )
        result.highWater = highWater
        return result
    }

    /// Maps the three accounts this ledger actually tracks, leaving the dormant
    /// Revolut pockets alone.
    private func mapRealAccounts(_ store: FinanceStore) throws {
        try store.mapRemoteAccount("acct_bnp", toLocalAccount: "bnp")
        try store.mapRemoteAccount("acct_rev_eur", toLocalAccount: "revolut")
        try store.mapRemoteAccount("acct_paypal", toLocalAccount: "paypal")
    }

    // MARK: - Mapping

    @Test("Each remote account maps to its own local account")
    func mappingBindsRemoteToLocal() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))

        try mapRealAccounts(store)

        let bindings = store.snapshot.providerAccountBindings
        #expect(bindings.count == 3)
        #expect(bindings.first { $0.providerName == "BNP" }?.localAccountID == "bnp")
        #expect(bindings.first { $0.providerName == "Revolut" }?.localAccountID == "revolut")
        #expect(bindings.first { $0.providerName == "PayPal" }?.localAccountID == "paypal")
    }

    @Test("Unmapped pockets produce no Bank Inbox work and no local account")
    func dormantPocketsAreIgnored() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try mapRealAccounts(store)

        try await store.importBankEvidence(from: provider(remoteSnapshot()))

        // The dormant observation and its balance arrived in the payload and
        // were discarded: nothing was created for an account nobody mapped.
        #expect(!store.snapshot.syncedObservations.contains { $0.id == "obs_dormant" })
        #expect(store.snapshot.providerBalanceStatuses.allSatisfy { $0.accountName != "Cash MAD" })
        #expect(store.snapshot.accounts.count == 5)
        #expect(store.snapshot.mappableRemoteAccounts.filter(\.isMapped).count == 3)
        #expect(store.snapshot.mappableRemoteAccounts.filter { !$0.isMapped }.count == 4)
    }

    @Test("The cutover defaults to the local account's opening-balance date")
    func cutoverDefaultsToOpeningBalance() throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        #expect(store.defaultBoundary(for: "bnp") == boundary)
    }

    @Test("Activity on or before the cutover never enters review")
    func preCutoverObservationsExcluded() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try mapRealAccounts(store)

        // Booked on the boundary day itself: already inside the opening figure.
        try await store.importBankEvidence(from: provider(remoteSnapshot(observationDay: 22)))

        #expect(store.snapshot.unreviewedSyncedObservations.isEmpty)
        #expect(store.snapshot.activity.flatMap(\.rows).isEmpty)
    }

    @Test("Activity after the cutover arrives for review")
    func postCutoverObservationAppears() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try mapRealAccounts(store)

        try await store.importBankEvidence(from: provider(remoteSnapshot()))

        let unreviewed = store.snapshot.unreviewedSyncedObservations
        #expect(unreviewed.contains { $0.id == "obs_bank" })
        #expect(unreviewed.contains { $0.id == "obs_wallet" })
    }

    // MARK: - Idempotency

    @Test("Identical evidence avoids another document write")
    func identicalEvidenceSkipsPersistence() async throws {
        var writeCount = 0
        let writer = DocumentWriter { document, context, day, presentation, metadata in
            writeCount += 1
            try StoredDocumentGraph.replace(
                with: document, in: context, writtenOn: day,
                presentation: presentation, appMetadata: metadata
            )
        }
        let harness = try harness(writer: writer)
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        let snapshot = remoteSnapshot(includePending: false)
        try await store.importBankEvidence(from: provider(snapshot))
        try mapRealAccounts(store)

        let beforeEvidence = writeCount
        try await store.importBankEvidence(from: provider(snapshot))
        #expect(writeCount == beforeEvidence + 1)
        try await store.importBankEvidence(from: provider(snapshot))
        #expect(writeCount == beforeEvidence + 1)
    }

    @Test("Fresh provider clock and cursor save without replacing the ledger graph")
    func quietPullWritesOnlyBankMetadata() async throws {
        var forecastRuns = 0
        let harness = try harness(forecastRunner: { request in
            forecastRuns += 1
            return try ForecastEngine.run(request)
        })
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        let base = remoteSnapshot(includePending: false)
        try await store.importBankEvidence(from: provider(base))
        try mapRealAccounts(store)
        try await store.importBankEvidence(from: provider(base))
        let context = harness.container.mainContext
        let revision = try #require(context.fetch(FetchDescriptor<StoredDocumentMeta>()).first?.documentRevision)
        let before = try #require(
            StoredDocumentGraph.loadAppMetadata(from: context)
                .authoritativePendingSnapshots[.bnp]?.authoritativeAt
        )
        let forecastRunsBefore = forecastRuns

        let laterConnections = base.connections.map { connection in
            connection.provider == "bnp"
                ? MobileSnapshot.Connection(
                    id: connection.id, provider: connection.provider,
                    institution: connection.institution, status: connection.status,
                    validUntil: connection.validUntil,
                    lastSuccessfulSyncAt: "2026-08-29T11:00:00.000Z",
                    lastErrorCode: connection.lastErrorCode
                )
                : connection
        }
        var later = replacing(base, pending: [], connections: laterConnections)
        later.highWater = "2026-08-29T11:00:00.000Z\tobs_wallet"
        try await store.importBankEvidence(from: provider(later))

        let after = try #require(
            StoredDocumentGraph.loadAppMetadata(from: context)
                .authoritativePendingSnapshots[.bnp]?.authoritativeAt
        )
        #expect(after > before)
        #expect(forecastRuns == forecastRunsBefore)
        #expect(try context.fetch(FetchDescriptor<StoredDocumentMeta>()).first?.documentRevision == revision)
        #expect(try StoredDocumentGraph.loadAppMetadata(from: context).bankEvidenceCursor == later.highWater)
    }

    @Test("Syncing twice changes nothing the second time")
    func syncIsIdempotent() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try mapRealAccounts(store)
        try await store.importBankEvidence(from: provider(remoteSnapshot()))

        let first = store.snapshot
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        let second = store.snapshot

        #expect(first.syncedObservations.count == second.syncedObservations.count)
        #expect(first.providerBalanceStatuses.count == second.providerBalanceStatuses.count)
        #expect(second.activity.flatMap(\.rows).isEmpty)
        let exported = try store.exportDocument()
        // Two booked rows plus the provisional pending one — each stored once,
        // however many times the sync runs.
        #expect(exported.externalObservations.count == 3)
        #expect(exported.observationResolutions.count == 3)
        #expect(exported.crossProviderCandidates.count == 1)
        #expect(exported.providerBalanceSnapshots.count == 1)
        #expect(exported.transactions.isEmpty)
    }

    @Test("Paged snapshots accumulate every cursor page and stay idempotent")
    func pagedSnapshotAccumulatesWithoutLoss() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        try mapRealAccounts(store)

        let cursor = "2026-08-31T11:29:05.626Z\tobs_0200"
        let paging = PagingBankSyncProvider(pages: [
            pageSnapshot(ids: (1...200).map { String(format: "obs_%04d", $0) }, nextSince: cursor),
            pageSnapshot(ids: ["obs_0200", "obs_0201"], nextSince: nil),
        ])
        try await store.importBankEvidence(from: paging)

        #expect(paging.receivedSince == [nil, cursor])
        let exported = try store.exportDocument()
        let paypalIDs = Set(exported.externalObservations.filter { $0.provider == .paypal }.map(\.id))
        #expect((1...201).allSatisfy { paypalIDs.contains(String(format: "obs_%04d", $0)) })
        #expect(exported.transactions.isEmpty)
    }

    @Test("The terminal booked cursor survives a relaunch with a safe overlap")
    func bookedCursorPersistsAfterCompleteImport() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        try mapRealAccounts(store)

        let firstCursor = "2026-08-31T11:29:05.626Z\tobs_cursor_a"
        let finalCursor = "2026-08-31T11:29:05.626Z\tobs_cursor_b"
        let pages = PagingBankSyncProvider(pages: [
            pageSnapshot(ids: ["obs_cursor_a"], nextSince: firstCursor, highWater: firstCursor),
            pageSnapshot(ids: ["obs_cursor_b"], nextSince: nil, highWater: finalCursor),
        ])
        try await store.importBankEvidence(from: pages)
        #expect(pages.receivedSince == [nil, firstCursor])

        let reopened = try FinanceStore(
            context: harness.container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 28)),
            identityStore: DeviceIdentityStore(service: "test.banksync.reopened.\(UUID().uuidString)")
        )
        let empty = PagingBankSyncProvider(pages: [
            pageSnapshot(ids: [], nextSince: nil, highWater: finalCursor),
        ])
        try await reopened.importBankEvidence(from: empty)
        #expect(empty.receivedSince == ["2026-08-30T11:29:05.626Z"])
        let exported = try reopened.exportDocument()
        #expect(exported.externalObservations.contains { $0.id == "obs_cursor_a" })
        #expect(exported.externalObservations.contains { $0.id == "obs_cursor_b" })
    }

    @Test("Mapping another account restarts the booked walk")
    func bookedCursorResetsForNewBinding() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        try store.mapRemoteAccount("acct_bnp", toLocalAccount: "bnp")
        let cursor = "2026-08-31T11:29:05.626Z\tobs_new_wallet"
        let page = pageSnapshot(ids: ["obs_new_wallet"], nextSince: nil, highWater: cursor)
        try await store.importBankEvidence(from: PagingBankSyncProvider(pages: [page]))
        #expect(!(try store.exportDocument()).externalObservations.contains { $0.id == "obs_new_wallet" })

        try store.mapRemoteAccount("acct_paypal", toLocalAccount: "paypal")
        let refreshed = PagingBankSyncProvider(pages: [page])
        try await store.importBankEvidence(from: refreshed)
        #expect(refreshed.receivedSince == [nil])
        #expect((try store.exportDocument()).externalObservations.contains { $0.id == "obs_new_wallet" })
    }

    @Test("A candidate resolves observations on different booked pages")
    func candidateAcrossPages() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        let base = remoteSnapshot(includePending: false)
        try await store.importBankEvidence(from: provider(base))
        try mapRealAccounts(store)
        let bank = try #require(base.observations.first { $0.id == "obs_bank" })
        let wallet = try #require(base.observations.first { $0.id == "obs_wallet" })
        let pages = PagingBankSyncProvider(pages: [
            replacing(base, pending: [], observations: [bank], nextSince: "cursor-a"),
            replacing(base, pending: [], observations: [wallet], nextSince: nil),
        ])
        try await store.importBankEvidence(from: pages)
        let candidate = try #require(try store.exportDocument().crossProviderCandidates.first)
        #expect(candidate.state == .unique)
        #expect(candidate.walletObservationID == "obs_wallet")
    }

    @Test("A later page failure does not import a partial snapshot")
    func pagedSnapshotFailureDoesNotPartialImport() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        try mapRealAccounts(store)
        let before = try store.exportDocument().externalObservations.count

        let paging = PagingBankSyncProvider(
            pages: [
                pageSnapshot(ids: ["obs_page1"], nextSince: "2026-08-31T00:00:00.000Z\tobs_page1"),
            ],
            failOnPage: 2
        )
        do {
            try await store.importBankEvidence(from: paging)
            Issue.record("page failure should throw")
        } catch {
            // Expected: the walk aborts before import.
        }
        #expect(try store.exportDocument().externalObservations.count == before)
    }

    @Test("Malformed booked evidence for a mapped account fails the whole pull")
    func mappedBookedConversionFailureDoesNotCommit() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        let base = remoteSnapshot(includePending: false)
        try await store.importBankEvidence(from: provider(base))
        try mapRealAccounts(store)
        let booked = try #require(base.observations.first { $0.id == "obs_bank" })
        let invalid = MobileSnapshot.Observation(
            id: "obs-invalid", accountId: booked.accountId, provider: booked.provider,
            status: booked.status, creditDebitIndicator: booked.creditDebitIndicator,
            amount: "invalid", currency: booked.currency, bookingDate: booked.bookingDate,
            transactionDate: booked.transactionDate, valueDate: booked.valueDate,
            derivedTransactionDate: booked.derivedTransactionDate,
            derivedDateProvenance: booked.derivedDateProvenance,
            rawMerchantText: booked.rawMerchantText,
            structuredMerchantName: booked.structuredMerchantName,
            merchantEmail: booked.merchantEmail,
            bankTransactionCode: booked.bankTransactionCode,
            bankTransactionSubCode: booked.bankTransactionSubCode,
            eligibleForEconomicActual: booked.eligibleForEconomicActual,
            observedAt: booked.observedAt
        )
        let incoming = replacing(base, pending: [], observations: [invalid], candidates: [])
        await #expect(throws: BankSyncClientError.malformedResponse) {
            try await store.importBankEvidence(from: provider(incoming))
        }
        #expect(!(try store.exportDocument()).externalObservations.contains { $0.id == "obs-invalid" })
    }

    @Test("Provider failure remains visible after the evidence pull succeeds")
    func remoteProviderFailureIsNotReportedAsSuccess() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        await store.syncNow(using: OutcomeBankSyncProvider(
            snapshot: remoteSnapshot(includePending: false),
            outcomes: [
                MobileSyncRun(provider: "bnp", outcome: "success", errorCode: nil),
                MobileSyncRun(provider: "paypal", outcome: "skipped_rate_limited", errorCode: "ASPSP_RATE_LIMIT_EXCEEDED")
            ]
        ))
        guard case let .failed(message) = store.bankSyncActivity else {
            Issue.record("a rate-limited provider must not report success")
            return
        }
        #expect(message.contains("PayPal"))
        #expect(!store.snapshot.mappableRemoteAccounts.isEmpty)
    }

    @Test("An overlapping provider run is named after the evidence pull")
    func overlappingProviderRunIsVisible() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        await store.syncNow(using: OutcomeBankSyncProvider(
            snapshot: remoteSnapshot(includePending: false),
            outcomes: [
                MobileSyncRun(provider: "bnp", outcome: "skipped_in_progress", errorCode: nil)
            ]
        ))
        guard case let .failed(message) = store.bankSyncActivity else {
            Issue.record("an overlapping provider run must not report a completed sync")
            return
        }
        #expect(message.contains("BNP sync is already in progress"))
        #expect(!store.snapshot.mappableRemoteAccounts.isEmpty)
    }

    @Test("An accepted asynchronous job shows terminal provider results after evidence is saved")
    func asynchronousJobCompletesWithProviderStatus() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        let job = MobileSyncJob(
            jobId: "job_0123", createdAt: "2026-08-28T00:00:00.000Z", complete: true,
            runs: [
                MobileSyncRun(provider: "bnp", outcome: "success", errorCode: nil, state: "finished"),
                MobileSyncRun(provider: "paypal", outcome: "skipped_rate_limited",
                              errorCode: "ASPSP_RATE_LIMIT_EXCEEDED", state: "finished"),
                MobileSyncRun(provider: "revolut", outcome: "success", errorCode: nil, state: "finished")
            ]
        )
        await store.syncNow(using: AsyncOutcomeBankSyncProvider(
            snapshot: remoteSnapshot(includePending: false), job: job
        ))
        #expect(store.bankSyncRuns.count == 3)
        #expect(store.bankSyncRuns[1].outcome == "skipped_rate_limited")
        guard case let .failed(message) = store.bankSyncActivity else {
            Issue.record("a rate-limited bank must remain visible after the asynchronous pull")
            return
        }
        #expect(message.contains("PayPal"))
        #expect(!store.snapshot.mappableRemoteAccounts.isEmpty)
    }

    @Test("Revocation releases the asynchronous job slot for a subsequent identity")
    func revokedAsynchronousJobDoesNotLeaveAnOccupiedSlot() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        let rejected = MobileSyncJob(
            jobId: "job_old_identity", createdAt: "2026-08-28T00:00:00.000Z", complete: true,
            runs: [MobileSyncRun(provider: "bnp", outcome: "success", errorCode: nil, state: "finished")]
        )
        await store.syncNow(using: AsyncOutcomeBankSyncProvider(
            snapshot: remoteSnapshot(includePending: false), job: rejected, fetchError: .deviceRevoked))
        #expect(store.pairingState == .revoked)
        let subsequent = MobileSyncJob(jobId: "job_new_identity", createdAt: rejected.createdAt, complete: true, runs: rejected.runs)
        await store.syncNow(using: AsyncOutcomeBankSyncProvider(
            snapshot: remoteSnapshot(includePending: false), job: subsequent))
        guard case .succeeded = store.bankSyncActivity else {
            Issue.record("the old identity's polling slot must be released")
            return
        }
    }

    @Test("Unpairing invalidates an in-flight evidence pull")
    func unpairInvalidatesInFlightPull() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        let gate = SnapshotGate()
        let task = Task {
            try await store.importBankEvidence(from: DelayedBankSyncProvider(
                snapshot: remoteSnapshot(includePending: false), gate: gate
            ))
        }
        await gate.waitForStart()
        try store.unpairDevice()
        await gate.release()
        try await task.value
        #expect(store.snapshot.mappableRemoteAccounts.isEmpty)
        #expect((try store.exportDocument()).externalObservations.isEmpty)
    }

    @Test("The final page supplies current pending membership")
    func finalPagePendingMembershipWins() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        try mapRealAccounts(store)

        let first = [pendingRow("pending-page-a")]
        let final = [pendingRow("pending-page-b"), pendingRow("pending-page-c", amount: "0.00")]
        let paging = PagingBankSyncProvider(pages: [
            pageSnapshot(ids: ["booked-page-a"], pending: first, nextSince: "cursor-a"),
            pageSnapshot(ids: ["booked-page-b"], pending: final, nextSince: nil),
        ])
        try await store.importBankEvidence(from: paging)

        #expect(Set(store.snapshot.currentPendingSyncedObservations.map(\.id)) == [
            "pending-page-b", "pending-page-c",
        ])
        let exported = try store.exportDocument()
        // Current state repeats per page, so only terminal provisional rows
        // enter the document.
        #expect(!exported.externalObservations.contains { $0.id == "pending-page-a" })
    }

    @Test("The page safety cap is incomplete and preserves prior authority")
    func pageCapDoesNotReplacePendingMembership() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        try mapRealAccounts(store)
        let established = replacing(
            remoteSnapshot(includePending: false),
            pending: [pendingRow("pending-established")]
        )
        try await store.importBankEvidence(from: provider(established))

        let pages = (0..<20).map { index in
            pageSnapshot(
                ids: ["booked-cap-\(index)"],
                pending: [pendingRow("pending-uncommitted-\(index)")],
                nextSince: "cursor-\(index)"
            )
        }
        do {
            try await store.importBankEvidence(from: PagingBankSyncProvider(pages: pages))
            Issue.record("a non-terminal twentieth page must fail closed")
        } catch {
            // Expected: neither evidence nor membership is committed.
        }

        #expect(store.snapshot.currentPendingSyncedObservations.map(\.id) == ["pending-established"])
        #expect(!(try store.exportDocument()).externalObservations.contains {
            $0.id.hasPrefix("booked-cap-")
        })
    }

    @Test("Four current rows become an authoritative provider snapshot")
    func authoritativePendingMembershipIsExact() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        try mapRealAccounts(store)
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        let economicBefore = store.snapshot
        let ids = (1...4).map { "pending-current-\($0)" }
        let wire = replacing(
            remoteSnapshot(includePending: false),
            pending: ids.enumerated().map {
                pendingRow($0.element, amount: $0.offset == 2 ? "3.99" : "0.00")
            }
        )

        try await store.importBankEvidence(from: provider(wire))

        #expect(Set(store.snapshot.currentPendingSyncedObservations.map(\.id)) == Set(ids))
        let authority = try #require(
            store.snapshot.currentPendingProviderSnapshots.first { $0.id == "bnp" }
        )
        #expect(authority.observationIDs == Set(ids))
        // Provider freshness, not local HTTP completion or serverTime.
        let authoritativeAt = try MobileSnapshotMapper.requiredTimestamp("2026-08-28T11:00:00.000Z")
        #expect(authority.authoritativeAt == authoritativeAt)
        let exported = try store.exportDocument()
        #expect(exported.transactions.isEmpty)
        #expect(exported.externalEvidenceLinks.isEmpty)
        #expect(exported.trustedRules.isEmpty)
        #expect(exported.trustedRuleAuditEvents.isEmpty)
        #expect(store.snapshot.safeToSpend == economicBefore.safeToSpend)
        #expect(store.snapshot.budget == economicBefore.budget)
        #expect(store.snapshot.runwayPoints == economicBefore.runwayPoints)
        #expect(!store.trustedAutomationEnabled)
    }

    @Test("An unmapped pending account does not invalidate mapped provider authority")
    func unmappedPendingAccountIsIgnoredSafely() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        try mapRealAccounts(store)
        let wire = replacing(
            remoteSnapshot(includePending: false),
            pending: [
                pendingRow("pending-mapped"),
                pendingRow("pending-unmapped", accountID: "acct_rev_mad"),
            ]
        )

        try await store.importBankEvidence(from: provider(wire))

        #expect(store.snapshot.currentPendingSyncedObservations.map(\.id) == ["pending-mapped"])
        #expect(!(try store.exportDocument()).externalObservations.contains {
            $0.id == "pending-unmapped"
        })
    }

    @Test("An authoritative empty snapshot hides but retains old provisional evidence")
    func authoritativeZeroPendingRetainsHistory() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        try mapRealAccounts(store)
        let withPending = replacing(
            remoteSnapshot(includePending: false),
            pending: (1...4).map { pendingRow("pending-old-\($0)") }
        )
        try await store.importBankEvidence(from: provider(withPending))

        try await store.importBankEvidence(
            from: provider(remoteSnapshot(includePending: false))
        )

        let bnp = try #require(
            store.snapshot.currentPendingProviderSnapshots.first { $0.id == "bnp" }
        )
        #expect(bnp.observationIDs.isEmpty)
        #expect(store.snapshot.currentPendingSyncedObservations.isEmpty)
        let exported = try store.exportDocument()
        #expect((1...4).allSatisfy { id in
            exported.externalObservations.contains { $0.id == "pending-old-\(id)" }
        })
        let loaded = try StoredDocumentGraph.load(from: harness.container.mainContext)
        let live = try #require(loaded)
        #expect((1...4).allSatisfy { id in
            !live.externalObservations.contains { $0.id == "pending-old-\(id)" }
        })
        let archived = try harness.container.mainContext.fetch(
            FetchDescriptor<StoredPendingEvidenceArchive>()
        )
        #expect(archived.reduce(0) { $0 + $1.observationCount } == 4)
        let reopened = try FinanceStore(
            context: harness.container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 28))
        )
        #expect((try reopened.exportDocument()).externalObservations.contains {
            $0.id == "pending-old-1"
        })
    }

    @Test("Replacing the document replaces its cold pending archive")
    func importReplacesPendingArchive() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try mapRealAccounts(store)
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        #expect((try store.exportDocument()).externalObservations.contains { $0.id == "pend_1" })

        var replacement = try store.exportDocument()
        replacement.externalObservations.removeAll { $0.id == "pend_1" }
        replacement.observationResolutions.removeAll { $0.observationID == "pend_1" }
        try store.importDocument(replacement)

        #expect(!(try store.exportDocument()).externalObservations.contains { $0.id == "pend_1" })
        #expect(try harness.container.mainContext.fetch(
            FetchDescriptor<StoredPendingEvidenceArchive>()
        ).isEmpty)
    }

    @Test("Transport and decoding failures preserve current pending authority")
    func failedFetchesPreservePendingMembership() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        try mapRealAccounts(store)
        let established = replacing(
            remoteSnapshot(includePending: false),
            pending: [pendingRow("pending-established")]
        )
        try await store.importBankEvidence(from: provider(established))

        for failure in [BankSyncClientError.offline, .malformedResponse] {
            do {
                try await store.importBankEvidence(from: ThrowingBankSyncProvider(error: failure))
                Issue.record("the provider should have thrown")
            } catch {
                // Expected.
            }
            #expect(
                store.snapshot.currentPendingSyncedObservations.map(\.id)
                    == ["pending-established"]
            )
        }
    }

    @Test("Persistence failure rolls evidence and pending authority back together")
    func pendingMembershipPersistenceFailureIsAtomic() async throws {
        let harness = try harness()
        let good = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await good.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        try mapRealAccounts(good)
        try await good.importBankEvidence(
            from: provider(replacing(
                remoteSnapshot(includePending: false),
                pending: [pendingRow("pending-established")]
            ))
        )
        let beforeCount = try good.exportDocument().externalObservations.count

        let failing = try FinanceStore(
            context: harness.container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 28)),
            writer: DocumentWriter { _, _, _, _, _ in throw SyntheticWriteFailure.refused }
        )
        do {
            try await failing.importBankEvidence(
                from: provider(replacing(
                    remoteSnapshot(includePending: false),
                    pending: [pendingRow("pending-not-committed")]
                ))
            )
            Issue.record("the persistence write should fail")
        } catch {
            // Expected.
        }

        #expect(failing.snapshot.currentPendingSyncedObservations.map(\.id) == ["pending-established"])
        #expect(try failing.exportDocument().externalObservations.count == beforeCount)
    }

    @Test("Provider-scoped updates preserve an omitted provider")
    func providerScopesDoNotClearEachOther() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        try mapRealAccounts(store)
        let first = replacing(
            remoteSnapshot(includePending: false),
            pending: [
                pendingRow("pending-bnp-a"),
                pendingRow("pending-paypal-a", accountID: "acct_paypal"),
            ]
        )
        try await store.importBankEvidence(from: provider(first))

        let bnpOnlyConnections = remoteSnapshot().connections.filter { $0.provider == "bnp" }
        let second = replacing(
            remoteSnapshot(includePending: false),
            pending: [pendingRow("pending-bnp-b")],
            connections: bnpOnlyConnections
        )
        try await store.importBankEvidence(from: provider(second))

        #expect(Set(store.snapshot.currentPendingSyncedObservations.map(\.id)) == [
            "pending-bnp-b", "pending-paypal-a",
        ])
    }

    @Test("Current membership survives relaunch and repeated identical snapshots")
    func currentPendingPersistsAndIsIdempotent() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        try mapRealAccounts(store)
        let current = replacing(
            remoteSnapshot(includePending: false),
            pending: [pendingRow("pending-current")]
        )
        try await store.importBankEvidence(from: provider(current))
        try await store.importBankEvidence(from: provider(current))

        let reopened = try FinanceStore(
            context: harness.container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 28))
        )
        #expect(reopened.snapshot.currentPendingSyncedObservations.map(\.id) == ["pending-current"])
        #expect((try reopened.exportDocument()).externalObservations.filter {
            $0.id == "pending-current"
        }.count == 1)
    }

    @Test("New snapshot IDs do not make older provisional evidence current")
    func replacedSnapshotIDsRemainHistorical() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        try mapRealAccounts(store)
        try await store.importBankEvidence(
            from: provider(replacing(
                remoteSnapshot(includePending: false),
                pending: [pendingRow("pending-old")]
            ))
        )
        try await store.importBankEvidence(
            from: provider(replacing(
                remoteSnapshot(includePending: false),
                pending: [pendingRow("pending-new")]
            ))
        )

        #expect(store.snapshot.currentPendingSyncedObservations.map(\.id) == ["pending-new"])
        let exported = try store.exportDocument()
        #expect(exported.externalObservations.contains { $0.id == "pending-old" })
        #expect(exported.observationResolutions.first {
            $0.observationID == "pending-old"
        }?.state == .provisional)
        let loaded = try StoredDocumentGraph.load(from: harness.container.mainContext)
        let live = try #require(loaded)
        #expect(!live.externalObservations.contains { $0.id == "pending-old" })
        #expect(live.externalObservations.contains { $0.id == "pending-new" })
    }

    @Test("Repeated pending checks keep the operational graph bounded while exports retain each run")
    func repeatedPendingChecksArchiveHistory() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        try mapRealAccounts(store)
        for index in 1...8 {
            try await store.importBankEvidence(from: provider(replacing(
                remoteSnapshot(includePending: false),
                pending: [pendingRow("pending-run-\(index)")]
            )))
        }

        let loaded = try StoredDocumentGraph.load(from: harness.container.mainContext)
        let live = try #require(loaded)
        #expect(live.externalObservations.filter { $0.identity == .provisionalSnapshot }
            .map(\.id) == ["pending-run-8"])
        let exported = try store.exportDocument()
        #expect((1...8).allSatisfy { index in
            exported.externalObservations.contains { $0.id == "pending-run-\(index)" }
        })
        let archived = try harness.container.mainContext.fetch(
            FetchDescriptor<StoredPendingEvidenceArchive>()
        )
        #expect(archived.reduce(0) { $0 + $1.observationCount } == 7)
    }

    @Test("A malformed pending row for an active mapping fails closed")
    func mappedPendingConversionFailureDoesNotAdvanceAuthority() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))
        try mapRealAccounts(store)
        try await store.importBankEvidence(
            from: provider(replacing(
                remoteSnapshot(includePending: false),
                pending: [pendingRow("pending-established")]
            ))
        )
        let invalid = MobileSnapshot.Pending(
            id: "pending-invalid", accountId: "acct_bnp", status: "PDNG",
            creditDebitIndicator: "DBIT", amount: "not-a-decimal", currency: "EUR",
            bookingDate: nil, transactionDate: nil, valueDate: nil,
            rawMerchantText: nil, observedAt: "2026-08-31T11:00:00.000Z",
            durableIdentity: false, eligibleForEconomicActual: false
        )

        do {
            try await store.importBankEvidence(
                from: provider(replacing(remoteSnapshot(includePending: false), pending: [invalid]))
            )
            Issue.record("mapped conversion failure should refuse authority")
        } catch {
            // Expected.
        }
        #expect(store.snapshot.currentPendingSyncedObservations.map(\.id) == ["pending-established"])
        #expect(!(try store.exportDocument()).externalObservations.contains { $0.id == "pending-invalid" })
    }

    @Test("A legacy store keeps provisional evidence but starts with unknown authority")
    func legacyStoreMigrationFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-membership-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("FinanceCore-1.1.store")

        var legacyDocument = localDocument()
        let binding = ExternalAccountBinding(
            id: "binding-bnp",
            provider: .bnp,
            remoteOpaqueAccountID: "acct_bnp",
            localAccountID: "bnp",
            syncStartBoundary: boundary,
            createdAt: observedAt
        )
        legacyDocument.externalAccountBindings = [binding]
        let historical = ExternalObservation(
            id: "legacy-provisional",
            bindingID: binding.id,
            provider: .bnp,
            identity: .provisionalSnapshot,
            status: .pending,
            creditDebitIndicator: .debit,
            amount: Money(minorUnits: -399, currency: .eur),
            bookingDate: Day(year: 2026, month: 8, day: 28),
            rawMerchantText: nil,
            eligibleForEconomicActual: false,
            observedAt: observedAt
        )
        try ExternalEvidenceReview.importBatch(
            .init(observations: [historical]),
            into: &legacyDocument
        )

        let legacyModels = FinanceSchema.models.filter {
            ObjectIdentifier($0) != ObjectIdentifier(StoredAuthoritativePendingSnapshot.self)
        }
        do {
            let legacy = try ModelContainer(
                for: Schema(legacyModels),
                configurations: ModelConfiguration(url: url)
            )
            legacy.mainContext.insert(
                try StoredDocumentMeta(document: legacyDocument, writtenOn: boundary)
            )
            legacyDocument.accounts.enumerated().forEach {
                legacy.mainContext.insert(StoredAccount($0.element, sequence: $0.offset))
            }
            for (index, balance) in legacyDocument.balances.enumerated() {
                legacy.mainContext.insert(try StoredAccountBalance(balance, sequence: index))
            }
            for (index, binding) in legacyDocument.externalAccountBindings.enumerated() {
                legacy.mainContext.insert(try StoredExternalAccountBinding(binding, sequence: index))
            }
            for (index, observation) in legacyDocument.externalObservations.enumerated() {
                legacy.mainContext.insert(try StoredExternalObservation(observation, sequence: index))
            }
            legacyDocument.observationResolutions.enumerated().forEach {
                legacy.mainContext.insert(StoredObservationResolution($0.element, sequence: $0.offset))
            }
            legacy.mainContext.insert(
                StoredEntryPreferences(lastExpenseAccountIdentifier: nil, lastIncomeAccountIdentifier: nil)
            )
            try legacy.mainContext.save()
        }

        let current = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(url: url)
        )
        let migrated = try FinanceStore(
            context: current.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 31))
        )
        let exported = try migrated.exportDocument()

        #expect(exported.externalObservations.contains { $0.id == "legacy-provisional" })
        #expect(exported.observationResolutions.first {
            $0.observationID == "legacy-provisional"
        }?.state == .provisional)
        #expect(migrated.snapshot.currentPendingProviderSnapshots.isEmpty)
        #expect(migrated.snapshot.currentPendingSyncedObservations.isEmpty)
    }

    @Test("A resync preserves a review decision and its evidence link")
    func resyncPreservesReviewState() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try mapRealAccounts(store)
        try await store.importBankEvidence(from: provider(remoteSnapshot()))

        let transactionID = try store.createExpense(
            from: "obs_bank", userLabel: "A subscription", including: "obs_wallet",
            allowingPotentialDuplicate: true
        )

        try await store.importBankEvidence(from: provider(remoteSnapshot()))

        let exported = try store.exportDocument()
        #expect(exported.transactions.count == 1)
        #expect(exported.transactions[0].id == transactionID)
        #expect(exported.externalEvidenceLinks.count == 2)
        #expect(store.snapshot.unreviewedSyncedObservations.isEmpty)
    }

    // MARK: - Economics

    @Test("Review saves a selected category with the expense and learns an exact merchant proposal")
    func reviewedExpenseCategory() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try mapRealAccounts(store)
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        let id = try store.createExpense(from: "obs_bank", userLabel: "A subscription",
                                         categoryKey: "subscriptions", allowingPotentialDuplicate: true)
        #expect(store.snapshot.activity.flatMap(\.rows).first { $0.id == id }?.categoryLabel == "Subscriptions")
        #expect(store.suggestedExpenseCategory(merchant: " a SUBSCRIPTION ", currency: "EUR") == "subscriptions")
        #expect(store.suggestedExpenseCategory(merchant: "A subscription", currency: "USD") == nil)
        #expect(store.suggestedExpenseCategory(merchant: "A similar subscription", currency: "EUR") == nil)
        let reopened = try FinanceStore(context: harness.container.mainContext,
                                       now: fixtureInstant(Day(year: 2026, month: 8, day: 28)),
                                       identityStore: DeviceIdentityStore(service: "test.banksync.category.\(UUID().uuidString)"))
        #expect(reopened.snapshot.activity.flatMap(\.rows).first { $0.id == id }?.categoryLabel == "Subscriptions")
        try store.createExpense(from: "obs_wallet", userLabel: "A subscription",
                                categoryKey: "shopping", allowingPotentialDuplicate: true)
        #expect(store.suggestedExpenseCategory(merchant: "A subscription", currency: "EUR") == nil)
    }

    @Test("Unavailable or income categories refuse expense review without changing evidence")
    func invalidReviewCategoryIsAtomic() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try mapRealAccounts(store)
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        let before = try store.exportDocument()
        for category in ["missing-category", "income", "transfers"] {
            #expect(throws: BankReviewError.self) {
                try store.createExpense(from: "obs_bank", userLabel: "A subscription",
                                         categoryKey: category, allowingPotentialDuplicate: true)
            }
        }
        let after = try store.exportDocument()
        #expect(after.transactions == before.transactions)
        #expect(after.observationResolutions == before.observationResolutions)
        #expect(after.externalEvidenceLinks == before.externalEvidenceLinks)
    }

    @Test("A synced debit does not become an expense on its own")
    func noAutomaticEconomics() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try mapRealAccounts(store)
        try await store.importBankEvidence(from: provider(remoteSnapshot()))

        // Evidence arrived; nothing was interpreted.
        #expect(store.snapshot.syncedObservations.count >= 2)
        #expect(store.snapshot.activity.flatMap(\.rows).isEmpty)
        #expect(try store.exportDocument().transactions.isEmpty)
        // Stored anchor is unchanged. Displayed current uses provider CLBD.
        #expect(try store.exportDocument().balances.first { $0.accountID == "bnp" }?.balance.minorUnits == 30_000)
        #expect(store.snapshot.accounts.first { $0.id == "bnp" }?.balance.minorUnits == 36_456)
    }

    @Test("A provider balance is shown beside the ledger, never written over it")
    func providerBalanceDoesNotOverwriteLedger() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try mapRealAccounts(store)
        try await store.importBankEvidence(from: provider(remoteSnapshot()))

        let status = try #require(store.snapshot.providerBalanceStatuses.first { $0.accountName == "BNP" && $0.balanceType == "CLBD" })
        #expect(status.ledgerBalance.minorUnits == 30_000)
        #expect(status.providerBalance.minorUnits == 36_456)
        #expect(status.difference?.minorUnits == 6_456)  // 36_456 provider − 30_000 ledger
        #expect(status.differsFromLedger)
        #expect(try store.exportDocument().balances.first { $0.accountID == "bnp" }?.balance.minorUnits == 30_000)
        #expect(store.snapshot.accounts.first { $0.id == "bnp" }?.balance.minorUnits == 36_456)
    }

    @Test("A unique cross-provider candidate is a suggestion, not a second transaction")
    func uniqueCandidateStaysSuggestion() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try mapRealAccounts(store)
        try await store.importBankEvidence(from: provider(remoteSnapshot()))

        let bank = try #require(store.snapshot.syncedObservations.first { $0.id == "obs_bank" })
        #expect(bank.suggestions.contains { $0.kind == .crossProvider })
        #expect(bank.duplicateCreationWarning != nil)
        #expect(try store.exportDocument().transactions.isEmpty)

        // Confirming it creates exactly one transaction with two pieces of
        // evidence, never one transaction per provider.
        #expect(throws: (any Error).self) {
            try store.createExpense(
                from: "obs_bank", userLabel: "A subscription", including: "obs_wallet"
            )
        }
        #expect(try store.exportDocument().transactions.isEmpty)
        try store.createExpense(
            from: "obs_bank", userLabel: "A subscription", including: "obs_wallet",
            allowingPotentialDuplicate: true
        )
        let exported = try store.exportDocument()
        #expect(exported.transactions.count == 1)
        #expect(exported.externalEvidenceLinks.count == 2)
        // The provider's own merchant text survives the person's label.
        #expect(store.snapshot.syncedObservations.first { $0.id == "obs_wallet" }?
            .observedMerchant == "Synthetic Merchant Ireland")
    }

    @Test("A unique paired observation prefers the transaction already backed by account movement")
    func linkedCrossProviderMovementOffersSafeExistingMatch() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try mapRealAccounts(store)
        try await store.importBankEvidence(from: provider(remoteSnapshot()))

        let transactionID = try store.createExpense(
            from: "obs_bank",
            userLabel: "A subscription",
            allowingPotentialDuplicate: true
        )
        let wallet = try #require(store.snapshot.syncedObservations.first {
            $0.id == "obs_wallet"
        })
        #expect(wallet.resolution == .unreviewed)
        #expect(wallet.suggestions.contains {
            $0.kind == .existingTransaction
                && $0.targetTransactionID == transactionID
                && $0.confidence == .high
        })
        #expect(wallet.duplicateConflict?.kind == .exactExisting)

        try store.matchObservation("obs_wallet", toTransaction: transactionID)
        let exported = try store.exportDocument()
        #expect(exported.transactions.count == 1)
        #expect(exported.externalEvidenceLinks.count == 2)
        #expect(exported.externalEvidenceLinks.contains {
            $0.observationID == "obs_bank" && $0.role == .accountMovement
        })
        #expect(exported.externalEvidenceLinks.contains {
            $0.observationID == "obs_wallet" && $0.role == .merchantEnrichment
        })
    }

    @Test("An ambiguous candidate never links anything")
    func ambiguousCandidateStaysUnresolved() async throws {
        var wire = remoteSnapshot()
        wire = MobileSnapshot(
            contractVersion: wire.contractVersion, serverTime: wire.serverTime,
            connections: wire.connections, accounts: wire.accounts, balances: wire.balances,
            observations: wire.observations, pending: wire.pending,
            candidates: [
                .init(bankObservationId: "obs_bank", walletObservationId: nil,
                      state: "ambiguous", candidateCount: 2, amount: "7.99", currency: "EUR",
                      dayOffset: nil, rule: "synthetic_rule",
                      computedAt: "2026-08-28T12:00:00.000Z"),
            ],
            nextSince: nil
        )
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(wire))
        try mapRealAccounts(store)
        try await store.importBankEvidence(from: provider(wire))

        let bank = try #require(store.snapshot.syncedObservations.first { $0.id == "obs_bank" })
        #expect(bank.suggestions.contains { $0.kind == .merchantUnresolved })
        #expect(!bank.suggestions.contains { $0.kind == .crossProvider })
        #expect(try store.exportDocument().externalEvidenceLinks.isEmpty)
    }

    @Test("A pending row is provisional evidence and cannot become an actual")
    func pendingStaysProvisional() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try mapRealAccounts(store)
        try await store.importBankEvidence(from: provider(remoteSnapshot()))

        let pending = try #require(store.snapshot.syncedObservations.first { $0.id == "pend_1" })
        #expect(pending.resolution == .provisional)
        #expect(!store.snapshot.unreviewedSyncedObservations.contains { $0.id == "pend_1" })
        #expect(throws: (any Error).self) {
            try store.createExpense(from: "pend_1", userLabel: "Should not work")
        }
        #expect(try store.exportDocument().transactions.isEmpty)
    }

    @Test("A booked row replacing a pending one is a new observation, not a match")
    func pendingBecomesBookedWithoutInventedLinkage() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try mapRealAccounts(store)
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        #expect(store.snapshot.syncedObservations.contains { $0.id == "pend_1" })

        // The next run no longer reports the pending row; the booked row that
        // replaced it has its own durable id. No fingerprint is invented.
        try await store.importBankEvidence(from: provider(remoteSnapshot(includePending: false)))

        #expect(!store.snapshot.syncedObservations.contains { $0.id == "pend_1" })
        let exported = try store.exportDocument()
        #expect(exported.externalObservations.contains { $0.id == "pend_1" })
        #expect(exported.observationResolutions.contains {
            $0.observationID == "pend_1" && $0.state == .provisional
        })
        #expect(exported.transactions.isEmpty)
    }

    // MARK: - Status regression

    @Test("An unreviewed row the bank withdraws leaves the queue by itself")
    func unreviewedRegressionLeavesQueue() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try mapRealAccounts(store)
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        #expect(store.snapshot.unreviewedSyncedObservations.contains { $0.id == "obs_bank" })

        try await store.importBankEvidence(
            from: provider(remoteSnapshot(bankStatus: "RJCT", bankEligible: false))
        )

        #expect(!store.snapshot.unreviewedSyncedObservations.contains { $0.id == "obs_bank" })
        let row = try #require(store.snapshot.syncedObservations.first { $0.id == "obs_bank" })
        #expect(row.resolution == .ineligible)
        #expect(!row.hasProviderStatusWarning)
    }

    @Test("A resolved row the bank withdraws keeps its decision and raises a warning")
    func resolvedRegressionKeepsDecision() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try mapRealAccounts(store)
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        let transactionID = try store.createExpense(
            from: "obs_bank", userLabel: "A subscription",
            allowingPotentialDuplicate: true
        )

        try await store.importBankEvidence(
            from: provider(remoteSnapshot(bankStatus: "RJCT", bankEligible: false))
        )

        let exported = try store.exportDocument()
        // The person's record of money that moved is not retracted by the app.
        #expect(exported.transactions.map(\.id) == [transactionID])
        #expect(exported.externalEvidenceLinks.count == 1)
        let row = try #require(store.snapshot.syncedObservations.first { $0.id == "obs_bank" })
        #expect(row.resolution == .linked)
        #expect(row.hasProviderStatusWarning)
        #expect(store.snapshot.observationsWithProviderWarning.map(\.id) == ["obs_bank"])
    }

    // MARK: - Connections and offline

    @Test("Consent state is represented, including when attention is needed")
    func consentStatesAreRepresented() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))

        let connections = store.snapshot.providerConnections
        #expect(connections.first { $0.providerName == "BNP" }?.state == .connected)
        #expect(connections.first { $0.providerName == "PayPal" }?.state == .expiringSoon)
        let revolut = try #require(connections.first { $0.providerName == "Revolut" })
        #expect(revolut.state == .reauthorizationRequired)
        #expect(revolut.state.needsAttention)
        #expect(store.snapshot.providerConnectionsNeedingAttention.count == 1)
        // The backend's error code never reaches the person verbatim.
        #expect(revolut.lastErrorMessage?.contains("SESSION_EXPIRED") == false)
    }

    @Test("Sync failure changes nothing and reports a sanitized message")
    func syncFailureIsContained() async throws {
        let harness = try harness()
        let store = harness.store
        defer { withExtendedLifetime(harness) {} }
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        try mapRealAccounts(store)
        try await store.importBankEvidence(from: provider(remoteSnapshot()))
        let observationsBefore = store.snapshot.syncedObservations.count
        let balanceBefore = store.snapshot.accounts.first { $0.id == "bnp" }?.balance

        do {
            try await store.importBankEvidence(from: FailingBankSyncProvider())
            #expect(Bool(false), "the provider should have thrown")
        } catch {
            // Expected.
        }

        // Everything local is untouched: balances, evidence, accounts, plan.
        #expect(store.snapshot.syncedObservations.count == observationsBefore)
        #expect(store.snapshot.accounts.first { $0.id == "bnp" }?.balance == balanceBefore)
        #expect(store.snapshot.accounts.count == 5)
        // And manual entry still works with no network at all.
        try store.add(
            TransactionDraft(
                day: CalendarDay(year: 2026, month: 8, day: 28),
                kind: .expense,
                amount: Amount(minorUnits: 450, currencyCode: "EUR"),
                accountID: "cash-eur"
            )
        )
        #expect(store.snapshot.activity.flatMap(\.rows).count == 1)
    }
}

// MARK: - Test doubles

/// Feeds a wire snapshot through the real mapper, so these tests exercise the
/// production translation rather than a hand-built domain batch.
private struct LocalBankSyncProviderFromWire: BankSyncProviding {
    let snapshot: MobileSnapshot

    func runRemoteSync() async throws {}

    func fetchSnapshot(
        bindings: [ExternalAccountBinding], since: String?
    ) async throws -> BankSyncSnapshot {
        try MobileSnapshotMapper.map(snapshot, bindings: bindings)
    }
}

private actor SnapshotGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func hold() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private struct DelayedBankSyncProvider: BankSyncProviding {
    let snapshot: MobileSnapshot
    let gate: SnapshotGate

    func runRemoteSync() async throws {}
    func fetchSnapshot(bindings: [ExternalAccountBinding], since: String?) async throws -> BankSyncSnapshot {
        await gate.hold()
        return try MobileSnapshotMapper.map(snapshot, bindings: bindings)
    }
}

private struct OutcomeBankSyncProvider: BankSyncProviding {
    let snapshot: MobileSnapshot
    let outcomes: [MobileSyncRun]

    func runRemoteSync() async throws {}
    func runRemoteSyncWithOutcomes() async throws -> [MobileSyncRun]? { outcomes }
    func fetchSnapshot(bindings: [ExternalAccountBinding], since: String?) async throws -> BankSyncSnapshot {
        try MobileSnapshotMapper.map(snapshot, bindings: bindings)
    }
}

private struct AsyncOutcomeBankSyncProvider: BankSyncProviding {
    let snapshot: MobileSnapshot
    let job: MobileSyncJob
    var fetchError: BankSyncClientError? = nil

    func runRemoteSync() async throws {}
    func startRemoteSync() async throws -> MobileSyncJob? { job }
    func fetchSnapshot(bindings: [ExternalAccountBinding], since: String?) async throws -> BankSyncSnapshot {
        if let fetchError { throw fetchError }
        return try MobileSnapshotMapper.map(snapshot, bindings: bindings)
    }
}

private struct FailingBankSyncProvider: BankSyncProviding {
    func runRemoteSync() async throws { throw BankSyncClientError.offline }
    func fetchSnapshot(
        bindings: [ExternalAccountBinding], since: String?
    ) async throws -> BankSyncSnapshot {
        throw BankSyncClientError.offline
    }
}

private struct ThrowingBankSyncProvider: BankSyncProviding {
    let error: BankSyncClientError

    func runRemoteSync() async throws { throw error }
    func fetchSnapshot(
        bindings: [ExternalAccountBinding], since: String?
    ) async throws -> BankSyncSnapshot {
        throw error
    }
}

private enum SyntheticWriteFailure: Error {
    case refused
}

/// Walks `since` exactly as `FinanceStore.readAllEvidence` does.
private final class PagingBankSyncProvider: BankSyncProviding, @unchecked Sendable {
    let pages: [MobileSnapshot]
    let failOnPage: Int?
    private(set) var receivedSince: [String?] = []

    init(pages: [MobileSnapshot], failOnPage: Int? = nil) {
        self.pages = pages
        self.failOnPage = failOnPage
    }

    func runRemoteSync() async throws {}

    func fetchSnapshot(
        bindings: [ExternalAccountBinding], since: String?
    ) async throws -> BankSyncSnapshot {
        receivedSince.append(since)
        if let failOnPage, receivedSince.count == failOnPage {
            throw BankSyncClientError.offline
        }
        let index = receivedSince.count - 1
        guard pages.indices.contains(index) else {
            return try MobileSnapshotMapper.map(pages[pages.count - 1], bindings: bindings)
        }
        return try MobileSnapshotMapper.map(pages[index], bindings: bindings)
    }
}
