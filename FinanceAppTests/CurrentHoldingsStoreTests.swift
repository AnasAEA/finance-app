import Foundation
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

@Suite("Current holdings store boundary")
@MainActor
struct CurrentHoldingsStoreTests {
    private let anchorDay = Day(year: 2026, month: 8, day: 22)
    private let today = Day(year: 2026, month: 8, day: 31)
    private let timestamp = Date(timeIntervalSince1970: 1_777_680_000)

    @Test("Reviewing evidence does not mutate the stored anchor")
    func reviewDoesNotMutateAnchor() throws {
        let harness = try harness(withProvider: true)
        let before = try harness.store.exportDocument()
        let bnpBefore = try #require(before.balances.first { $0.accountID == "bank-main" })
        #expect(harness.store.snapshot.syncedObservations.first {
            $0.id == "obs-399"
        }?.duplicateConflict == nil)

        _ = try harness.store.createExpense(from: "obs-399", userLabel: "App Store")

        let after = try harness.store.exportDocument()
        let bnpAfter = try #require(after.balances.first { $0.accountID == "bank-main" })
        #expect(bnpAfter == bnpBefore)
        #expect(after.transactions.count == 1)
        #expect(harness.store.snapshot.accounts.first { $0.id == "bank-main" }?.balance.minorUnits == 36_862)
    }

    @Test("Reviewing later small debits leaves provider BNP current unchanged")
    func reviewLeavesProviderCurrent() throws {
        let harness = try harness(withProvider: true)
        _ = try harness.store.createExpense(from: "obs-399", userLabel: "App Store")
        _ = try harness.store.createExpense(from: "obs-799", userLabel: "iCloud")
        _ = try harness.store.createExpense(from: "obs-349", userLabel: "Music")

        #expect(try harness.store.exportDocument().balances.first { $0.accountID == "bank-main" }?.balance.minorUnits == 38_409)
        #expect(harness.store.snapshot.accounts.first { $0.id == "bank-main" }?.balance.minorUnits == 36_862)
        #expect(harness.store.snapshot.accountCash.minorUnits == 44_747)
    }

    @Test("An existing transaction with the exact bank reference is preferred over another actual")
    func exactExistingTransactionIsPreferred() throws {
        var document = ledgerDocument(withProvider: true)
        document.transactions = [
            Transaction(
                id: "existing-399",
                date: Day(year: 2026, month: 8, day: 30),
                kind: .expense,
                legs: [AccountLeg(
                    accountID: "bank-main",
                    amount: Money(minorUnits: -399, currency: .eur)
                )],
                factivity: .observed,
                lifecycle: .cleared,
                provenance: Provenance(source: "TEST-IMPORT", evidenceGrade: .userConfirmed, reference: "obs-399")
            )
        ]
        let harness = try harness(document: document)
        let item = try #require(harness.store.snapshot.syncedObservations.first {
            $0.id == "obs-399"
        })
        #expect(item.duplicateConflict?.kind == .exactExisting)
        #expect(item.suggestions.contains {
            $0.kind == .existingTransaction && $0.targetTransactionID == "existing-399"
        })
        #expect(throws: (any Error).self) {
            try harness.store.createExpense(from: "obs-399", userLabel: "Duplicate")
        }

        try harness.store.matchObservation("obs-399", toTransaction: "existing-399")
        let exported = try harness.store.exportDocument()
        #expect(exported.transactions.count == 1)
        #expect(exported.externalEvidenceLinks.count == 1)
        #expect(exported.observationResolutions.first {
            $0.observationID == "obs-399"
        }?.state == .linkedToTransaction)
    }

    @Test("An amount-only collision does not force a duplicate override, but remains manually findable")
    func amountOnlyCollisionIsNotDuplicateEvidence() throws {
        var document = ledgerDocument(withProvider: true)
        document.transactions = [Transaction(id: "unrelated-same-price", date: Day(year: 2026, month: 8, day: 30),
            kind: .expense, legs: [AccountLeg(accountID: "bank-main", amount: Money(minorUnits: -399, currency: .eur))],
            factivity: .observed, lifecycle: .cleared)]
        let harness = try harness(document: document)
        let item = try #require(harness.store.snapshot.syncedObservations.first { $0.id == "obs-399" })
        #expect(!item.suggestions.contains { $0.kind == .existingTransaction })
        #expect(item.duplicateConflict == nil)
        #expect(harness.store.recordedPaymentCandidates(for: item.id).map(\.id) == ["unrelated-same-price"])
        #expect(harness.store.recordedPaymentCandidates(for: item.id, search: "No such merchant").isEmpty)
        try harness.store.createExpense(from: item.id, userLabel: "A different purchase")
        #expect(try harness.store.exportDocument().transactions.count == 2)
    }

    @Test("An exact two-transaction aggregate is guarded and never offered as a false match")
    func aggregateExistingTransactionsRequireOverride() throws {
        var document = ledgerDocument(withProvider: true)
        document.transactions = [
            Transaction(
                id: "repayment-a",
                date: anchorDay,
                kind: .financingRepayment,
                legs: [AccountLeg(
                    accountID: "bank-main",
                    amount: Money(minorUnits: -8_122, currency: .eur)
                )],
                factivity: .observed,
                lifecycle: .cleared
            ),
            Transaction(
                id: "repayment-b",
                date: anchorDay,
                kind: .financingRepayment,
                legs: [AccountLeg(
                    accountID: "bank-main",
                    amount: Money(minorUnits: -8_122, currency: .eur)
                )],
                factivity: .observed,
                lifecycle: .cleared
            ),
        ]
        let harness = try harness(document: document)
        let item = try #require(harness.store.snapshot.syncedObservations.first {
            $0.id == "obs-16244"
        })
        #expect(item.duplicateConflict?.kind == .aggregateExisting)
        #expect(Set(item.duplicateConflict?.transactionIDs ?? []) == [
            "repayment-a", "repayment-b",
        ])
        #expect(!item.suggestions.contains { $0.kind == .existingTransaction })

        #expect(throws: (any Error).self) {
            try harness.store.createExpense(from: "obs-16244", userLabel: "Duplicate")
        }
        var exported = try harness.store.exportDocument()
        #expect(exported.transactions.count == 2)
        #expect(exported.externalEvidenceLinks.isEmpty)
        #expect(exported.observationResolutions.first {
            $0.observationID == "obs-16244"
        }?.state == .unreviewed)

        _ = try harness.store.createExpense(
            from: "obs-16244",
            userLabel: "Explicit duplicate override",
            allowingPotentialDuplicate: true
        )
        exported = try harness.store.exportDocument()
        #expect(exported.transactions.count == 3)
        #expect(exported.externalEvidenceLinks.count == 1)
    }

    @Test("A matching recurring occurrence already settled elsewhere guards a second actual")
    func settledRecurringConflictRequiresOverride() throws {
        var document = ledgerDocument(withProvider: true)
        let occurrenceDay = Day(year: 2026, month: 8, day: 26)
        document.planning.recurringObligations = [
            RecurringObligation(
                id: "synthetic-video",
                name: "Synthetic video membership",
                amount: Money(minorUnits: 799, currency: .eur),
                spec: .monthly(
                    onDay: 26,
                    from: MonthKey(year: 2026, month: 8),
                    through: nil
                ),
                requirement: .euroBankPayment(),
                spendingClass: .optional
            )
        ]
        document.transactions = [
            Transaction(
                id: "settled-video-actual",
                date: occurrenceDay,
                kind: .expense,
                legs: [AccountLeg(
                    accountID: "bank-main",
                    amount: Money(minorUnits: -799, currency: .eur)
                )],
                factivity: .observed,
                lifecycle: .cleared
            )
        ]
        document.planning.settlements = [
            .paid(
                id: "settled-video-occurrence",
                obligationID: "synthetic-video",
                expectedDay: occurrenceDay,
                actualTransactionID: "settled-video-actual"
            )
        ]
        let target = ExternalObservation(
            id: "paypal-video-evidence",
            bindingID: "binding-paypal",
            provider: .paypal,
            status: .booked,
            creditDebitIndicator: .debit,
            amount: Money(minorUnits: -799, currency: .eur),
            transactionDate: occurrenceDay,
            structuredMerchantName: "Synthetic video merchant",
            eligibleForEconomicActual: true,
            observedAt: timestamp
        )
        document.externalObservations.append(target)
        document.observationResolutions.append(
            ExternalObservationResolution(
                observationID: target.id,
                state: .unreviewed
            )
        )

        let harness = try harness(document: document)
        let item = try #require(harness.store.snapshot.syncedObservations.first {
            $0.id == target.id
        })
        #expect(item.duplicateConflict?.kind == .settledRecurring)
        #expect(item.duplicateConflict?.transactionIDs == ["settled-video-actual"])
        #expect(!item.suggestions.contains { $0.kind == .existingTransaction })
        #expect(!item.suggestions.contains { $0.kind == .recurring })
        #expect(throws: (any Error).self) {
            try harness.store.createExpense(from: target.id, userLabel: "Duplicate")
        }
        let exported = try harness.store.exportDocument()
        #expect(exported.transactions.count == 1)
        #expect(exported.externalEvidenceLinks.allSatisfy { $0.observationID != target.id })
        #expect(exported.observationResolutions.first {
            $0.observationID == target.id
        }?.state == .unreviewed)
    }

    @Test("A pre-anchor duplicate does not change fallback or provider current")
    func preAnchorDuplicateIsIgnoredByFallback() throws {
        let harness = try harness(withProvider: true)
        _ = try harness.store.createExpense(from: "obs-16244", userLabel: "PayPal collection")
        let exported = try harness.store.exportDocument()
        #expect(exported.balances.first { $0.accountID == "bank-main" }?.balance.minorUnits == 38_409)
        #expect(
            CurrentHoldings.derivedLedgerBalance(
                accountID: "bank-main", asOf: today, in: exported
            )?.minorUnits == 38_409
        )
        #expect(harness.store.snapshot.accounts.first { $0.id == "bank-main" }?.balance.minorUnits == 36_862)
    }

    @Test("Manual add after the anchor updates derived cash and not the stored figure")
    func manualAddAfterAnchorIsDerived() throws {
        let harness = try harness(withProvider: false)
        let before = try harness.store.exportDocument()
        try harness.store.add(
            TransactionDraft(
                day: CalendarDay(year: 2026, month: 8, day: 30),
                kind: .expense,
                amount: .eur(3.99),
                accountID: "bank-main",
                categoryKey: "food"
            )
        )
        let after = try harness.store.exportDocument()
        #expect(after.balances == before.balances)
        #expect(harness.store.snapshot.accounts.first { $0.id == "bank-main" }?.balance.minorUnits == 38_010)
        #expect(harness.store.snapshot.accountCash.minorUnits == 45_895)
    }

    @Test("Delete and reverse recompute derived cash without rewriting the anchor")
    func deleteRecomputesWithoutAnchorWrite() throws {
        let harness = try harness(withProvider: false)
        try harness.store.add(
            TransactionDraft(
                day: CalendarDay(year: 2026, month: 8, day: 30),
                kind: .expense,
                amount: .eur(3.99),
                accountID: "bank-main",
                categoryKey: "food"
            )
        )
        let id = try #require(harness.store.snapshot.activity.flatMap(\.rows).first?.id)
        try harness.store.deleteActivityRow(id: id)
        let exported = try harness.store.exportDocument()
        #expect(exported.balances.first { $0.accountID == "bank-main" }?.balance.minorUnits == 38_409)
        #expect(exported.balances.first { $0.accountID == "bank-main" }?.asOf == anchorDay)
        #expect(harness.store.snapshot.accounts.first { $0.id == "bank-main" }?.balance.minorUnits == 38_409)
    }

    @Test("Row values sum to Accounts total")
    func rowsSumToAccountsTotal() throws {
        let harness = try harness(withProvider: true)
        let snapshot = harness.store.snapshot
        let rowSum = snapshot.accounts
            .filter { $0.kind != .cash && $0.currencyCode == "EUR" }
            .reduce(Int64(0)) { $0 + $1.balance.minorUnits }
        #expect(snapshot.accountCash.minorUnits == rowSum)
        #expect(rowSum == 44_747)
    }

    @Test("Safe to Use consumes the same current-liquidity source")
    func safeToUseUsesSameLiquidity() throws {
        let harness = try harness(withProvider: true)
        let snapshot = harness.store.snapshot
        #expect(snapshot.accountCash.minorUnits == 44_747)
        #expect(snapshot.safeToSpend.minorUnits <= snapshot.accountCash.minorUnits)
    }

    @Test("Relaunch persistence does not change anchors")
    func relaunchDoesNotChangeAnchors() throws {
        let harness = try harness(withProvider: true)
        _ = try harness.store.createExpense(from: "obs-399", userLabel: "App Store")
        let first = try harness.store.exportDocument()
        let reopened = try FinanceStore(
            context: harness.container.mainContext,
            now: fixtureInstant(today)
        )
        let second = try reopened.exportDocument()
        #expect(second.balances == first.balances)
        #expect(second.balances.first { $0.accountID == "bank-main" }?.asOf == anchorDay)
        #expect(reopened.snapshot.accountCash.minorUnits == 44_747)
    }

    @Test("Legacy mutated cache is not double-replayed")
    func legacyMutatedCacheIsFailSafe() throws {
        var document = ledgerDocument()
        document.balances = document.balances.map { balance in
            guard balance.accountID == "bank-main" else { return balance }
            return AccountBalance(
                accountID: balance.accountID,
                balance: Money(minorUnits: 20_618, currency: .eur),
                asOf: today,
                status: .carriedForward
            )
        }
        document.transactions = [
            Transaction(
                id: "legacy-1",
                date: Day(year: 2026, month: 8, day: 27),
                kind: .expense,
                legs: [AccountLeg(accountID: "bank-main", amount: Money(minorUnits: -349, currency: .eur))],
                factivity: .observed
            )
        ]
        let harness = try harness(document: document)
        #expect(harness.store.snapshot.accounts.first { $0.id == "bank-main" }?.balance.minorUnits == 20_618)
        #expect(try harness.store.exportDocument().balances.first { $0.accountID == "bank-main" }?.asOf == today)
    }

    @Test("Manual cash without a provider stays on ledger fallback")
    func manualCashUsesLedgerFallback() throws {
        let harness = try harness(withProvider: false)
        try harness.store.add(
            TransactionDraft(
                day: CalendarDay(year: 2026, month: 8, day: 25),
                kind: .expense,
                amount: .eur(5.00),
                accountID: "cash-eur",
                categoryKey: "food"
            )
        )
        #expect(try harness.store.exportDocument().balances.first { $0.accountID == "cash-eur" }?.balance.minorUnits == 1_500)
        #expect(harness.store.snapshot.physicalCash.first { $0.id == "cash-eur" }?.balance.minorUnits == 1_000)
    }

    @Test("Multi-currency stays separate")
    func multiCurrencyStaysSeparate() throws {
        let harness = try harness(withProvider: true)
        #expect(harness.store.snapshot.accountCash.currencyCode == "EUR")
        #expect(harness.store.snapshot.accounts.first { $0.id == "cash-mad" }?.currencyCode == "MAD")
        #expect(harness.store.snapshot.accounts.first { $0.id == "cash-mad" }?.balance.minorUnits == 20_000)
    }

    @Test("Persisting stamps the current-holdings model version")
    func persistStampsModelVersion() throws {
        let harness = try harness(withProvider: false)
        try harness.store.add(
            TransactionDraft(
                day: CalendarDay(year: 2026, month: 8, day: 30),
                kind: .expense,
                amount: .eur(1.00),
                accountID: "bank-main",
                categoryKey: "food"
            )
        )
        let metadata = try StoredDocumentGraph.loadAppMetadata(from: harness.container.mainContext)
        #expect(metadata.currentHoldingsModelVersion == CurrentHoldings.modelVersion)
    }

    @Test("Foreign-currency expense requires an exact user-confirmed account charge and retains original evidence")
    func foreignCurrencyExpense() throws {
        var document = ledgerDocument(withProvider: true)
        document.externalObservations = [ExternalObservation(
            id: "foreign-purchase", bindingID: "binding-paypal", provider: .paypal,
            status: .booked, creditDebitIndicator: .debit,
            amount: Money(minorUnits: -1000, currency: Currency(code: "USD")),
            bookingDate: today, structuredMerchantName: "Patreon", eligibleForEconomicActual: true,
            observedAt: timestamp)]
        document.observationResolutions = [.init(observationID: "foreign-purchase", state: .unreviewed)]
        let h = try harness(document: document)
        let before = try h.store.exportDocument()
        let row = try #require(h.store.snapshot.syncedObservations.first)
        #expect(row.requiresChargedAmount)
        #expect(row.accountCurrencyCode == "EUR")
        #expect(throws: BankReviewError.self) {
            try h.store.createExpense(from: row.id, userLabel: "Patreon", categoryKey: "subscriptions")
        }
        #expect(try h.store.exportDocument() == before)
        let id = try h.store.createExpense(from: row.id, userLabel: "Patreon", categoryKey: "subscriptions",
                                          chargedAmount: Amount(minorUnits: 925, currencyCode: "EUR"))
        let saved = try h.store.exportDocument()
        let transaction = try #require(saved.transactions.first { $0.id == id })
        #expect(transaction.legs == [AccountLeg(accountID: "paypal-eur", amount: Money(minorUnits: -925, currency: .eur))])
        #expect(saved.externalObservations == before.externalObservations)
        #expect(saved.balances == before.balances)
        #expect(saved.externalEvidenceLinks.first?.role == .supportingEvidence)
        #expect(saved.observationResolutions.first?.state == .linkedToTransaction)
        #expect(transaction.note?.contains("explicitly confirmed") == true)
        #expect(try h.container.mainContext.fetch(FetchDescriptor<StoredTransaction>()).first { $0.identifier == id }?.appCategoryKey == "subscriptions")
        #expect(saved.trustedRules.isEmpty)
        #expect(throws: BankReviewError.self) {
            try h.store.createExpense(from: row.id, userLabel: "Patreon", categoryKey: "subscriptions",
                                      chargedAmount: Amount(minorUnits: 925, currencyCode: "EUR"))
        }
        #expect(try h.store.exportDocument() == saved)
    }

    @Test("Foreign charge validation rejects wrong currency, precision, zero and negative amounts atomically")
    func invalidForeignCurrencyCharges() throws {
        var document = ledgerDocument(withProvider: true)
        document.externalObservations[0] = ExternalObservation(
            id: "obs-399", bindingID: "binding-bnp", provider: .bnp,
            status: .booked, creditDebitIndicator: .debit,
            amount: Money(minorUnits: -1000, currency: Currency(code: "USD")),
            bookingDate: today, eligibleForEconomicActual: true, observedAt: timestamp)
        let h = try harness(document: document)
        let before = try h.store.exportDocument()
        for amount in [Amount(minorUnits: 900, currencyCode: "USD"),
                       Amount(minorUnits: 900, currencyCode: "EUR", fractionDigits: 3),
                       Amount(minorUnits: 0, currencyCode: "EUR"),
                       Amount(minorUnits: -900, currencyCode: "EUR")] {
            #expect(throws: BankReviewError.self) {
                try h.store.createExpense(from: "obs-399", userLabel: "Patreon", chargedAmount: amount)
            }
            #expect(try h.store.exportDocument() == before)
        }
        #expect(throws: BankReviewError.self) {
            try h.store.createExpense(from: "obs-799", userLabel: "Other", chargedAmount: Amount(minorUnits: 799, currencyCode: "EUR"))
        }
        #expect(try h.store.exportDocument() == before)
    }

    // MARK: - Harness

    private struct Harness {
        let container: ModelContainer
        let store: FinanceStore
    }

    private func harness(withProvider: Bool) throws -> Harness {
        try harness(document: ledgerDocument(withProvider: withProvider))
    }

    private func harness(document: FinanceDocument) throws -> Harness {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        try StoredDocumentGraph.replace(
            with: document,
            in: container.mainContext,
            writtenOn: today
        )
        return Harness(
            container: container,
            store: try FinanceStore(
                context: container.mainContext,
                now: fixtureInstant(today)
            )
        )
    }

    private func ledgerDocument(withProvider: Bool = false) -> FinanceDocument {
        var document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [
                Account(id: "bank-main", name: "BNP", currency: .eur, kind: .bank,
                        supportedRails: PaymentRail.euroBankRails, drawOrder: 0),
                Account(id: "revolut-eur", name: "Revolut", currency: .eur, kind: .wallet,
                        supportedRails: PaymentRail.euroWalletRails, drawOrder: 1),
                Account(id: "paypal-eur", name: "PayPal", currency: .eur, kind: .wallet,
                        supportedRails: PaymentRail.euroWalletRails, drawOrder: 2),
                Account(id: "cash-eur", name: "Cash EUR", currency: .eur, kind: .cash,
                        supportedRails: PaymentRail.cashOnlyRails, drawOrder: 3),
                Account(id: "cash-mad", name: "Cash MAD", currency: .mad, kind: .cash,
                        supportedRails: PaymentRail.cashOnlyRails, drawOrder: 4)
            ],
            balances: [
                AccountBalance(
                    accountID: "bank-main",
                    balance: Money(minorUnits: 38_409, currency: .eur),
                    asOf: anchorDay,
                    status: .carriedForward
                ),
                AccountBalance(
                    accountID: "revolut-eur",
                    balance: Money(minorUnits: 7_885, currency: .eur),
                    asOf: anchorDay,
                    status: .carriedForward
                ),
                AccountBalance(
                    accountID: "paypal-eur",
                    balance: Money(minorUnits: 0, currency: .eur),
                    asOf: anchorDay,
                    status: .carriedForward
                ),
                AccountBalance(
                    accountID: "cash-eur",
                    balance: Money(minorUnits: 1_500, currency: .eur),
                    asOf: anchorDay,
                    status: .observed
                ),
                AccountBalance(
                    accountID: "cash-mad",
                    balance: Money(minorUnits: 20_000, currency: .mad),
                    asOf: anchorDay,
                    status: .observed
                )
            ]
        )
        if withProvider {
            document.externalAccountBindings = [
                binding("binding-bnp", .bnp, "bank-main"),
                binding("binding-revolut", .revolut, "revolut-eur"),
                binding("binding-paypal", .paypal, "paypal-eur")
            ]
            document.providerBalanceSnapshots = [
                ProviderBalanceSnapshot(
                    id: "bnp-clbd", bindingID: "binding-bnp", provider: .bnp,
                    balanceType: "CLBD", amount: Money(minorUnits: 36_862, currency: .eur),
                    referenceDate: today, observedAt: timestamp
                ),
                ProviderBalanceSnapshot(
                    id: "bnp-xpcd", bindingID: "binding-bnp", provider: .bnp,
                    balanceType: "XPCD", amount: Money(minorUnits: 40_000, currency: .eur),
                    referenceDate: today, observedAt: timestamp
                ),
                ProviderBalanceSnapshot(
                    id: "rev-itav", bindingID: "binding-revolut", provider: .revolut,
                    balanceType: "ITAV", amount: Money(minorUnits: 7_885, currency: .eur),
                    referenceDate: today, observedAt: timestamp
                ),
                ProviderBalanceSnapshot(
                    id: "pp-xpcd", bindingID: "binding-paypal", provider: .paypal,
                    balanceType: "XPCD", amount: Money(minorUnits: 0, currency: .eur),
                    referenceDate: today, observedAt: timestamp
                )
            ]
            document.externalObservations = [
                observation("obs-399", -399, Day(year: 2026, month: 8, day: 30)),
                observation("obs-799", -799, Day(year: 2026, month: 8, day: 28)),
                observation("obs-349", -349, Day(year: 2026, month: 8, day: 27)),
                observation(
                    "obs-16244",
                    -16_244,
                    Day(year: 2026, month: 8, day: 25),
                    transaction: Day(year: 2026, month: 8, day: 22)
                )
            ]
            document.observationResolutions = document.externalObservations.map {
                ExternalObservationResolution(observationID: $0.id, state: .unreviewed)
            }
        }
        return document
    }

    private func binding(_ id: String, _ provider: ExternalProvider, _ local: String) -> ExternalAccountBinding {
        ExternalAccountBinding(
            id: id, provider: provider, remoteOpaqueAccountID: "acct-\(id)",
            localAccountID: local, syncStartBoundary: anchorDay, createdAt: timestamp
        )
    }

    private func observation(
        _ id: String,
        _ amount: Int64,
        _ booking: Day,
        transaction: Day? = nil
    ) -> ExternalObservation {
        ExternalObservation(
            id: id,
            bindingID: "binding-bnp",
            provider: .bnp,
            status: .booked,
            creditDebitIndicator: .debit,
            amount: Money(minorUnits: amount, currency: .eur),
            bookingDate: booking,
            transactionDate: transaction,
            eligibleForEconomicActual: true,
            observedAt: timestamp
        )
    }
}
