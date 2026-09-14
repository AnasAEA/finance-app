import Foundation
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

/// Affirmative live coverage: the window the backend proved it fetched, kept
/// separate at every step from the transactions that happened to be in it.
@Suite("Authoritative live coverage")
@MainActor
struct LiveCoveragePersistenceTests {

    private let syncedAt = Date(timeIntervalSince1970: 1_788_000_000)
    private let boundary = Day(year: 2026, month: 8, day: 19)

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func account(
        _ id: String, currency: Currency = .eur, active: Bool = true
    ) -> Account {
        Account(
            id: id, name: id, currency: currency, kind: .bank,
            supportedRails: [.cardDebit], isActive: active
        )
    }

    private func binding(
        _ id: String,
        provider: ExternalProvider,
        remote: String,
        local: String,
        active: Bool = true
    ) -> ExternalAccountBinding {
        ExternalAccountBinding(
            id: id, provider: provider, remoteOpaqueAccountID: remote,
            localAccountID: local, syncStartBoundary: boundary,
            isActive: active, createdAt: syncedAt
        )
    }

    private func remoteAccount(
        _ id: String,
        provider: ExternalProvider,
        from: Day?,
        through: Day?
    ) -> RemoteAccountSummary {
        RemoteAccountSummary(
            id: id, provider: provider, displayName: id, product: nil,
            cashAccountType: nil, currencyCode: "EUR",
            syncedFrom: from, syncedThrough: through
        )
    }

    private func connection(
        _ provider: ExternalProvider, syncedAt: Date?
    ) -> RemoteConnectionSummary {
        RemoteConnectionSummary(
            id: "conn-\(provider.rawValue)", provider: provider, institution: nil,
            status: "connected", validUntil: nil,
            lastSuccessfulSyncAt: syncedAt, lastErrorCode: nil
        )
    }

    // MARK: - A. Wire mapping

    @Test("syncedFrom survives the wire mapping alongside syncedThrough")
    func syncedFromMapsThrough() throws {
        let json = """
        {"contractVersion":1,"serverTime":"2026-09-02T08:00:00Z",
         "connections":[],
         "accounts":[{"id":"acct_1","provider":"bnp","connectionId":null,
           "displayName":"Current","product":null,"cashAccountType":"CACC",
           "usage":null,"currency":"EUR",
           "syncedFrom":"2026-06-04","syncedThrough":"2026-09-01"}],
         "balances":[],"observations":[],"pending":[],"candidates":[],
         "nextSince":null}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MobileSnapshot.self, from: json)
        #expect(decoded.accounts.first?.syncedFrom == "2026-06-04")

        let mapped = try MobileSnapshotMapper.map(decoded, bindings: [])
        let account = try #require(mapped.accounts.first)
        #expect(account.syncedFrom == Day(year: 2026, month: 6, day: 4))
        #expect(account.syncedThrough == Day(year: 2026, month: 9, day: 1))
    }

    // MARK: - B/E. Authority derivation

    @Test("A complete snapshot establishes the window the backend reported")
    func establishesWindow() throws {
        let coverage = LiveCoverageAuthority.coverage(
            accounts: [
                remoteAccount(
                    "acct_1", provider: .bnp,
                    from: Day(year: 2026, month: 6, day: 4),
                    through: Day(year: 2026, month: 9, day: 1)
                )
            ],
            connections: [connection(.bnp, syncedAt: syncedAt)],
            bindings: [binding("b1", provider: .bnp, remote: "acct_1", local: "bank")]
        )
        let established = coverage["acct_1"]
        #expect(established?.syncedFrom == Day(year: 2026, month: 6, day: 4))
        #expect(established?.syncedThrough == Day(year: 2026, month: 9, day: 1))
        #expect(established?.localAccountID == "bank")
        #expect(established?.authoritativeAt == syncedAt)
    }

    @Test("A covered window with zero observations stays affirmatively covered")
    func zeroTransactionWindowStillCovered() throws {
        // Nothing in this call mentions an observation. That is the point:
        // coverage cannot weaken because the bank had nothing to report.
        let coverage = LiveCoverageAuthority.coverage(
            accounts: [
                remoteAccount(
                    "acct_1", provider: .bnp,
                    from: Day(year: 2026, month: 8, day: 20),
                    through: Day(year: 2026, month: 9, day: 2)
                )
            ],
            connections: [connection(.bnp, syncedAt: syncedAt)],
            bindings: [binding("b1", provider: .bnp, remote: "acct_1", local: "bank")]
        )
        let interval = try? #require(coverage["acct_1"]?.interval)
        #expect(interval?.dayCount == 14)
    }

    @Test("A missing bound, a provider mismatch or no successful sync stays unknown")
    func failsClosed() throws {
        let good = binding("b1", provider: .bnp, remote: "acct_1", local: "bank")
        let from = Day(year: 2026, month: 8, day: 20)
        let through = Day(year: 2026, month: 9, day: 1)

        // Missing syncedFrom.
        #expect(
            LiveCoverageAuthority.coverage(
                accounts: [remoteAccount("acct_1", provider: .bnp, from: nil, through: through)],
                connections: [connection(.bnp, syncedAt: syncedAt)],
                bindings: [good]
            ).isEmpty
        )
        // Missing syncedThrough.
        #expect(
            LiveCoverageAuthority.coverage(
                accounts: [remoteAccount("acct_1", provider: .bnp, from: from, through: nil)],
                connections: [connection(.bnp, syncedAt: syncedAt)],
                bindings: [good]
            ).isEmpty
        )
        // Provider has never completed a sync.
        #expect(
            LiveCoverageAuthority.coverage(
                accounts: [remoteAccount("acct_1", provider: .bnp, from: from, through: through)],
                connections: [connection(.bnp, syncedAt: nil)],
                bindings: [good]
            ).isEmpty
        )
        // Directory row filed under another provider.
        #expect(
            LiveCoverageAuthority.coverage(
                accounts: [remoteAccount("acct_1", provider: .paypal, from: from, through: through)],
                connections: [connection(.bnp, syncedAt: syncedAt)],
                bindings: [good]
            ).isEmpty
        )
        // Inactive binding.
        #expect(
            LiveCoverageAuthority.coverage(
                accounts: [remoteAccount("acct_1", provider: .bnp, from: from, through: through)],
                connections: [connection(.bnp, syncedAt: syncedAt)],
                bindings: [
                    binding("b1", provider: .bnp, remote: "acct_1", local: "bank", active: false)
                ]
            ).isEmpty
        )
    }

    // MARK: - I. Independent scopes

    @Test("Establishing one provider leaves another provider's window intact")
    func scopesRemainIndependent() throws {
        let previous: [String: AuthoritativeLiveCoverage] = [
            "acct_paypal": AuthoritativeLiveCoverage(
                provider: .paypal, remoteOpaqueAccountID: "acct_paypal",
                localAccountID: "wallet",
                syncedFrom: Day(year: 2026, month: 8, day: 10),
                syncedThrough: Day(year: 2026, month: 9, day: 1),
                authoritativeAt: syncedAt
            )
        ]
        let established = LiveCoverageAuthority.coverage(
            accounts: [
                remoteAccount(
                    "acct_bnp", provider: .bnp,
                    from: Day(year: 2026, month: 6, day: 4),
                    through: Day(year: 2026, month: 9, day: 2)
                )
            ],
            connections: [connection(.bnp, syncedAt: syncedAt)],
            bindings: [binding("b1", provider: .bnp, remote: "acct_bnp", local: "bank")]
        )
        let merged = LiveCoverageAuthority.merged(
            previous: previous, established: established
        )
        #expect(merged.count == 2)
        #expect(merged["acct_paypal"]?.syncedThrough == Day(year: 2026, month: 9, day: 1))
        #expect(merged["acct_bnp"]?.syncedThrough == Day(year: 2026, month: 9, day: 2))
    }

    // MARK: - C/D. Persistence and migration

    @Test("Coverage survives a store restart")
    func survivesRestart() throws {
        let container = try container()
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account("bank")],
            balances: [],
            externalAccountBindings: [
                binding("b1", provider: .bnp, remote: "acct_1", local: "bank")
            ]
        )
        var metadata = AppPersistenceMetadata.empty
        metadata.authoritativeLiveCoverage = [
            "acct_1": AuthoritativeLiveCoverage(
                provider: .bnp, remoteOpaqueAccountID: "acct_1", localAccountID: "bank",
                syncedFrom: Day(year: 2026, month: 6, day: 4),
                syncedThrough: Day(year: 2026, month: 9, day: 1),
                authoritativeAt: syncedAt
            )
        ]
        try StoredDocumentGraph.replace(
            with: document, in: container.mainContext,
            writtenOn: Day(year: 2026, month: 9, day: 2),
            appMetadata: metadata
        )

        let restarted = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 9, day: 2))
        )
        let reloaded = try #require(restarted.authoritativeLiveCoverage["acct_1"])
        #expect(reloaded.syncedFrom == Day(year: 2026, month: 6, day: 4))
        #expect(reloaded.syncedThrough == Day(year: 2026, month: 9, day: 1))
        #expect(reloaded.authoritativeAt == syncedAt)
        #expect(reloaded.localAccountID == "bank")
    }

    @Test("A store written before this build has unknown coverage, not empty coverage")
    func legacyStoreIsUnknown() throws {
        let container = try container()
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account("bank")],
            balances: [],
            externalAccountBindings: [
                binding("b1", provider: .bnp, remote: "acct_1", local: "bank")
            ]
        )
        // No coverage metadata at all: exactly a pre-existing physical store.
        try StoredDocumentGraph.replace(
            with: document, in: container.mainContext,
            writtenOn: Day(year: 2026, month: 9, day: 2)
        )
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 9, day: 2))
        )
        #expect(store.authoritativeLiveCoverage.isEmpty)

        let resolved = store.liveCoverage()
        #expect(resolved.intervals.isEmpty)
        #expect(resolved.unknownAccountIDs == ["bank"])
        #expect(!resolved.isKnown)
    }

    @Test("An ordinary document write preserves established coverage")
    func ordinaryWritePreservesCoverage() throws {
        let (store, container) = try storeWithPriorCoverage()
        #expect(store.authoritativeLiveCoverage.count == 1)

        // Any write goes through the same purge-and-reinsert as every other
        // row, so coverage has to survive one that knows nothing about it.
        try store.saveAccount(
            AccountDraft(
                id: nil,
                name: "Second",
                kind: .bank,
                currencyCode: "EUR",
                fractionDigits: 2,
                openingBalance: Amount.zeroEUR,
                openingBalanceDay: CalendarDay(year: 2026, month: 9, day: 2),
                isActive: true
            )
        )
        #expect(store.authoritativeLiveCoverage.count == 1)

        let restarted = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 9, day: 2))
        )
        #expect(
            restarted.authoritativeLiveCoverage["acct_1"]?.syncedThrough
                == Day(year: 2026, month: 8, day: 30)
        )
    }

    // MARK: - F/G/H. Write boundary

    /// A provider whose page walk cannot terminate, decode or map must leave
    /// previously established coverage exactly as it was.
    private struct FailingProvider: BankSyncProviding {
        enum Mode { case throwsError, neverTerminates }
        let mode: Mode
        func runRemoteSync() async throws {}
        func fetchSnapshot(
            bindings: [ExternalAccountBinding], since: String?
        ) async throws -> BankSyncSnapshot {
            switch mode {
            case .throwsError:
                throw BankSyncClientError.malformedResponse
            case .neverTerminates:
                // Always another cursor: the 20-page cap is reached without a
                // terminal page.
                return BankSyncSnapshot(nextSince: "cursor")
            }
        }
    }

    private func storeWithPriorCoverage() throws -> (FinanceStore, ModelContainer) {
        let container = try container()
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account("bank")],
            balances: [],
            externalAccountBindings: [
                binding("b1", provider: .bnp, remote: "acct_1", local: "bank")
            ]
        )
        var metadata = AppPersistenceMetadata.empty
        metadata.authoritativeLiveCoverage = [
            "acct_1": AuthoritativeLiveCoverage(
                provider: .bnp, remoteOpaqueAccountID: "acct_1", localAccountID: "bank",
                syncedFrom: Day(year: 2026, month: 8, day: 1),
                syncedThrough: Day(year: 2026, month: 8, day: 30),
                authoritativeAt: syncedAt
            )
        ]
        try StoredDocumentGraph.replace(
            with: document, in: container.mainContext,
            writtenOn: Day(year: 2026, month: 9, day: 2),
            appMetadata: metadata
        )
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 9, day: 2))
        )
        return (store, container)
    }

    @Test("A failed fetch preserves previously established coverage")
    func failedFetchPreservesCoverage() async throws {
        let (store, _) = try storeWithPriorCoverage()
        await #expect(throws: (any Error).self) {
            try await store.importBankEvidence(from: FailingProvider(mode: .throwsError))
        }
        #expect(
            store.authoritativeLiveCoverage["acct_1"]?.syncedThrough
                == Day(year: 2026, month: 8, day: 30)
        )
    }

    @Test("Hitting the page cap without a terminal page preserves coverage")
    func nonTerminalWalkPreservesCoverage() async throws {
        let (store, _) = try storeWithPriorCoverage()
        await #expect(throws: (any Error).self) {
            try await store.importBankEvidence(from: FailingProvider(mode: .neverTerminates))
        }
        #expect(
            store.authoritativeLiveCoverage["acct_1"]?.syncedThrough
                == Day(year: 2026, month: 8, day: 30)
        )
    }

    @Test("A terminal walk advances coverage and it survives restart")
    func terminalWalkAdvancesCoverage() async throws {
        let (store, container) = try storeWithPriorCoverage()
        let provider = LocalBankSyncProvider(
            snapshot: BankSyncSnapshot(
                connections: [connection(.bnp, syncedAt: syncedAt)],
                accounts: [
                    remoteAccount(
                        "acct_1", provider: .bnp,
                        from: Day(year: 2026, month: 8, day: 1),
                        through: Day(year: 2026, month: 9, day: 1)
                    )
                ],
                nextSince: nil
            )
        )
        try await store.importBankEvidence(from: provider)
        #expect(
            store.authoritativeLiveCoverage["acct_1"]?.syncedThrough
                == Day(year: 2026, month: 9, day: 1)
        )

        let restarted = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 9, day: 2))
        )
        #expect(
            restarted.authoritativeLiveCoverage["acct_1"]?.syncedThrough
                == Day(year: 2026, month: 9, day: 1)
        )
    }

    // MARK: - R. Establishing coverage without a new provider fetch

    @Test("Reading an already-authoritative snapshot establishes coverage")
    func snapshotReadEstablishesCoverage() async throws {
        let container = try container()
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account("bank")],
            balances: [],
            externalAccountBindings: [
                binding("b1", provider: .bnp, remote: "acct_1", local: "bank")
            ]
        )
        try StoredDocumentGraph.replace(
            with: document, in: container.mainContext,
            writtenOn: Day(year: 2026, month: 9, day: 2)
        )
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 9, day: 2))
        )
        #expect(store.authoritativeLiveCoverage.isEmpty)

        // No runRemoteSync: this is a plain read of windows the backend had
        // already established, which is what a migrated install does first.
        try await store.importBankEvidence(
            from: LocalBankSyncProvider(
                snapshot: BankSyncSnapshot(
                    connections: [connection(.bnp, syncedAt: syncedAt)],
                    accounts: [
                        remoteAccount(
                            "acct_1", provider: .bnp,
                            from: Day(year: 2026, month: 8, day: 20),
                            through: Day(year: 2026, month: 9, day: 1)
                        )
                    ],
                    nextSince: nil
                )
            )
        )
        #expect(
            store.authoritativeLiveCoverage["acct_1"]?.syncedFrom
                == Day(year: 2026, month: 8, day: 20)
        )
    }

    // MARK: - J/K/L. Conservative intersection

    private func resolution(
        windows: [(remote: String, local: String, from: Day, through: Day)],
        relevant: [(binding: String, remote: String, local: String)],
        accounts: [Account]
    ) -> LiveCoverageResolution {
        let coverage = Dictionary(
            uniqueKeysWithValues: windows.map { window in
                (
                    window.remote,
                    AuthoritativeLiveCoverage(
                        provider: .bnp, remoteOpaqueAccountID: window.remote,
                        localAccountID: window.local,
                        syncedFrom: window.from, syncedThrough: window.through,
                        authoritativeAt: syncedAt
                    )
                )
            }
        )
        return ReviewCoverageAdapter.liveCoverage(
            coverage: coverage,
            bindings: relevant.map {
                binding($0.binding, provider: .bnp, remote: $0.remote, local: $0.local)
            },
            accounts: accounts,
            currency: .eur
        )
    }

    @Test("Two windows intersect rather than union")
    func twoWindowsIntersect() throws {
        let resolved = resolution(
            windows: [
                ("acct_1", "bank", Day(year: 2026, month: 6, day: 4), Day(year: 2026, month: 9, day: 2)),
                ("acct_2", "wallet", Day(year: 2026, month: 8, day: 10), Day(year: 2026, month: 9, day: 1)),
            ],
            relevant: [
                ("b1", "acct_1", "bank"), ("b2", "acct_2", "wallet"),
            ],
            accounts: [account("bank"), account("wallet")]
        )
        #expect(resolved.intervals.count == 1)
        #expect(resolved.intervals.first?.start == Day(year: 2026, month: 8, day: 10))
        #expect(resolved.intervals.first?.end == Day(year: 2026, month: 9, day: 1))
        #expect(resolved.isKnown)
    }

    @Test("Three windows intersect to the narrowest common span")
    func threeWindowsIntersect() throws {
        let resolved = resolution(
            windows: [
                ("acct_1", "bank", Day(year: 2026, month: 6, day: 4), Day(year: 2026, month: 9, day: 2)),
                ("acct_2", "wallet", Day(year: 2026, month: 6, day: 4), Day(year: 2026, month: 9, day: 2)),
                ("acct_3", "neo", Day(year: 2026, month: 8, day: 10), Day(year: 2026, month: 9, day: 1)),
            ],
            relevant: [
                ("b1", "acct_1", "bank"), ("b2", "acct_2", "wallet"), ("b3", "acct_3", "neo"),
            ],
            accounts: [account("bank"), account("wallet"), account("neo")]
        )
        #expect(resolved.intervals.first?.start == Day(year: 2026, month: 8, day: 10))
        #expect(resolved.intervals.first?.end == Day(year: 2026, month: 9, day: 1))
    }

    @Test("One relevant unknown account makes the whole live claim unknown")
    func oneUnknownAccountBlocksGlobalCoverage() throws {
        let resolved = resolution(
            windows: [
                ("acct_1", "bank", Day(year: 2026, month: 6, day: 4), Day(year: 2026, month: 9, day: 2)),
            ],
            relevant: [
                ("b1", "acct_1", "bank"), ("b2", "acct_2", "wallet"),
            ],
            accounts: [account("bank"), account("wallet")]
        )
        // The wide BNP window must not paper over the unknown wallet.
        #expect(resolved.intervals.isEmpty)
        #expect(resolved.unknownAccountIDs == ["wallet"])
        #expect(!resolved.isKnown)
    }

    @Test("Disjoint windows yield no global coverage")
    func disjointWindows() throws {
        let resolved = resolution(
            windows: [
                ("acct_1", "bank", Day(year: 2026, month: 6, day: 1), Day(year: 2026, month: 6, day: 30)),
                ("acct_2", "wallet", Day(year: 2026, month: 8, day: 1), Day(year: 2026, month: 8, day: 31)),
            ],
            relevant: [("b1", "acct_1", "bank"), ("b2", "acct_2", "wallet")],
            accounts: [account("bank"), account("wallet")]
        )
        #expect(resolved.intervals.isEmpty)
    }

    // MARK: - M/N. Relevant account set

    @Test("Unmapped, inactive and foreign-currency accounts leave the relevant set")
    func relevantAccountRule() throws {
        let accounts = [
            account("bank"),
            account("closed", active: false),
            account("mad", currency: Currency(code: "MAD")),
        ]
        let bindings = [
            binding("b1", provider: .bnp, remote: "acct_1", local: "bank"),
            // Deactivated binding.
            binding("b2", provider: .bnp, remote: "acct_2", local: "bank", active: false),
            // Points at a deactivated local account.
            binding("b3", provider: .bnp, remote: "acct_3", local: "closed"),
            // Cannot contribute to a euro total under the no-FX policy.
            binding("b4", provider: .revolut, remote: "acct_4", local: "mad"),
            // Points at an account the document does not have.
            binding("b5", provider: .bnp, remote: "acct_5", local: "ghost"),
        ]
        let relevant = ReviewCoverageAdapter.relevantBindings(
            bindings: bindings, accounts: accounts, currency: .eur
        )
        #expect(relevant.map(\.id) == ["b1"])
    }

    @Test("A quiet account stays relevant")
    func zeroTransactionAccountStaysRelevant() throws {
        // Nothing about transaction counts enters the rule, so an account that
        // has never moved still has to be covered before a period is complete.
        let relevant = ReviewCoverageAdapter.relevantBindings(
            bindings: [binding("b1", provider: .bnp, remote: "acct_1", local: "quiet")],
            accounts: [account("quiet")],
            currency: .eur
        )
        #expect(relevant.map(\.id) == ["b1"])
    }

    @Test("No bound account at all fails closed rather than claiming coverage")
    func noBindingsFailsClosed() throws {
        let resolved = ReviewCoverageAdapter.liveCoverage(
            coverage: [:], bindings: [], accounts: [account("bank")], currency: .eur
        )
        #expect(resolved.intervals.isEmpty)
        #expect(!resolved.isKnown)
    }

    // MARK: - O/P/Q. Archive and live composition

    private func archive(
        cutoff: Day, start: Day, end: Day, gaps: [FinanceHistorySourceGap] = []
    ) -> FinanceHistoryDocument {
        FinanceHistoryDocument(
            schemaVersion: "1.1.0", documentKind: "TEST", archiveID: "archive",
            sourceRevision: "rev", contentSHA256: "sha",
            payload: FinanceHistoryPayload(
                archiveCutoff: cutoff,
                recordCount: 0,
                dateRange: FinanceHistoryDateRange(start: start, end: end),
                accounts: [],
                sourceGaps: gaps,
                records: []
            )
        )
    }

    private func coverage(
        interval: ReviewInterval,
        input: ReviewCoverageInput
    ) throws -> ReviewCoverage {
        try ReviewEngine.review(
            ReviewRequest(
                document: FinanceDocument(
                    schemaVersion: Interchange.currentSchemaVersion, documentKind: "TEST",
                    accounts: [], balances: []
                ),
                kind: .weekly,
                interval: interval,
                asOf: interval.end,
                coverage: input
            )
        ).coverage
    }

    @Test("Archive through cutoff plus a continuous live window is complete")
    func archiveAndLiveCompose() throws {
        let cutoff = Day(year: 2026, month: 8, day: 19)
        let input = ReviewCoverageAdapter.coverageInput(
            archiveCutoff: cutoff,
            history: archive(
                cutoff: cutoff,
                start: Day(year: 2021, month: 1, day: 1),
                end: cutoff
            ),
            live: LiveCoverageResolution(
                intervals: [
                    ReviewInterval(
                        start: Day(year: 2026, month: 8, day: 20),
                        end: Day(year: 2026, month: 9, day: 2)
                    )
                ],
                unknownAccountIDs: [],
                knownAccountIDs: ["bank"]
            )
        )
        let result = try coverage(interval: ReviewInterval(
                start: Day(year: 2026, month: 8, day: 17),
                end: Day(year: 2026, month: 8, day: 23)
            ),
            input: input
        )
        #expect(result.status == .complete)
        #expect(result.usedArchive)
        #expect(result.usedLive)
    }

    @Test("A one-day hole between archive cutoff and live start stays uncovered")
    func boundaryGapStaysUncovered() throws {
        let cutoff = Day(year: 2026, month: 8, day: 19)
        // Live begins on the 21st, so the 20th is nobody's.
        let input = ReviewCoverageAdapter.coverageInput(
            archiveCutoff: cutoff,
            history: archive(
                cutoff: cutoff,
                start: Day(year: 2021, month: 1, day: 1),
                end: cutoff
            ),
            live: LiveCoverageResolution(
                intervals: [
                    ReviewInterval(
                        start: Day(year: 2026, month: 8, day: 21),
                        end: Day(year: 2026, month: 9, day: 2)
                    )
                ],
                unknownAccountIDs: [],
                knownAccountIDs: ["bank"]
            )
        )
        let result = try coverage(interval: ReviewInterval(
                start: Day(year: 2026, month: 8, day: 17),
                end: Day(year: 2026, month: 8, day: 23)
            ),
            input: input
        )
        #expect(result.status == .partial)
        #expect(result.missingIntervals.count == 1)
        #expect(result.missingIntervals.first?.start == Day(year: 2026, month: 8, day: 20))
        #expect(result.missingIntervals.first?.end == Day(year: 2026, month: 8, day: 20))
    }

    @Test("An archive source gap remains uncovered")
    func archiveGapRemainsUncovered() throws {
        let cutoff = Day(year: 2026, month: 8, day: 19)
        let input = ReviewCoverageAdapter.coverageInput(
            archiveCutoff: cutoff,
            history: archive(
                cutoff: cutoff,
                start: Day(year: 2021, month: 1, day: 1),
                end: cutoff,
                gaps: [
                    FinanceHistorySourceGap(
                        startMonth: MonthKey(year: 2026, month: 3),
                        endMonth: MonthKey(year: 2026, month: 3),
                        completeness: "PARTIAL",
                        affectedSources: ["bnp"],
                        message: "Bank records for part of this period are incomplete."
                    )
                ]
            ),
            live: LiveCoverageResolution(
                intervals: [], unknownAccountIDs: [], knownAccountIDs: []
            )
        )
        let result = try coverage(interval: ReviewInterval.month(MonthKey(year: 2026, month: 3)),
            input: input
        )
        #expect(result.status != .complete)
        #expect(result.reasons.contains { $0.kind == .sourceGap })
    }

    @Test("Unknown live coverage leaves a live-era period insufficient")
    func unknownLiveIsInsufficient() throws {
        let cutoff = Day(year: 2026, month: 8, day: 19)
        let input = ReviewCoverageAdapter.coverageInput(
            archiveCutoff: cutoff,
            history: archive(
                cutoff: cutoff, start: Day(year: 2021, month: 1, day: 1), end: cutoff
            ),
            live: LiveCoverageResolution(
                intervals: [], unknownAccountIDs: ["bank"], knownAccountIDs: []
            )
        )
        let result = try coverage(interval: ReviewInterval(
                start: Day(year: 2026, month: 8, day: 31),
                end: Day(year: 2026, month: 9, day: 6)
            ),
            input: input
        )
        #expect(result.status == .insufficient)
    }

    // MARK: - Stale provider window

    @Test("Coverage does not reach today merely because the app opened today")
    func staleWindowLeavesTodayUncovered() throws {
        let cutoff = Day(year: 2026, month: 8, day: 19)
        // The backend last proved through 1 September; today is the 2nd.
        let input = ReviewCoverageAdapter.coverageInput(
            archiveCutoff: cutoff,
            history: archive(
                cutoff: cutoff, start: Day(year: 2021, month: 1, day: 1), end: cutoff
            ),
            live: LiveCoverageResolution(
                intervals: [
                    ReviewInterval(
                        start: Day(year: 2026, month: 8, day: 20),
                        end: Day(year: 2026, month: 9, day: 1)
                    )
                ],
                unknownAccountIDs: [],
                knownAccountIDs: ["bank"]
            )
        )
        let result = try coverage(interval: ReviewInterval(
                start: Day(year: 2026, month: 8, day: 31),
                end: Day(year: 2026, month: 9, day: 6)
            ),
            input: input
        )
        #expect(result.status == .partial)
        #expect(result.missingIntervals.first?.start == Day(year: 2026, month: 9, day: 2))
    }
}
