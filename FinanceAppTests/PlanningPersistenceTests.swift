import Foundation
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

@MainActor
@Suite("Phase 2.7 planning persistence")
struct PlanningPersistenceAppTests {
    private let today = Day(year: 2026, month: 9, day: 1)
    private let todayDate = fixtureInstant(Day(year: 2026, month: 9, day: 1))

    private func euro(_ minor: Int64) -> Money { Money(minorUnits: minor, currency: .eur) }

    private func account() -> Account {
        Account(
            id: "bnp", name: "Bank", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails
        )
    }

    private func savings() -> Account {
        Account(
            id: "savings", name: "Savings", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 5
        )
    }

    private func baseDocument(version: String = "1.5.0") -> FinanceDocument {
        FinanceDocument(
            schemaVersion: version,
            documentKind: "TEST",
            accounts: [account()],
            balances: [
                AccountBalance(accountID: "bnp", balance: euro(100_000), asOf: today)
            ],
            transactions: [
                Transaction(
                    id: "tx-food", date: today, kind: .expense,
                    legs: [AccountLeg(accountID: "bnp", amount: euro(-1_000))],
                    factivity: .observed
                )
            ],
            planning: FinanceDocument.Planning(
                defaultScenario: .base,
                monthlyEconomicCeiling: euro(70_000),
                recurringObligations: [
                    RecurringObligation(
                        id: "ob-rent", name: "Rent",
                        amount: euro(48_000),
                        spec: .monthly(onDay: 11, from: today.monthKey, through: nil),
                        requirement: PaymentRequirement(currency: .eur, acceptableRails: [.sepaDirectDebit]),
                        spendingClass: .essential
                    )
                ]
            )
        )
    }

    private func purchase(id: String = "goal-1", fundID: String? = nil) -> PlannedPurchase {
        PlannedPurchase(
            id: id,
            name: "Laptop",
            targetAmount: euro(90_000),
            status: fundID == nil ? .planned : .reserved,
            funding: fundID.map { .sinkingFund(id: $0) } ?? .cashOnPurchase,
            requirement: .euroBankPayment()
        )
    }

    private func fund(id: String = "sf-1", reserved: Int64 = 20_000, accountID: String? = nil) -> SinkingFund {
        SinkingFund(
            id: id,
            name: "Tech",
            targetAmount: euro(90_000),
            reservedAmount: euro(reserved),
            custody: accountID.map { .dedicatedAccount(accountID: $0) } ?? .virtualReservation
        )
    }

    private func container(models: [any PersistentModel.Type] = FinanceSchema.models) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func persist(_ document: FinanceDocument, in context: ModelContext) throws {
        try StoredDocumentGraph.replace(with: document, in: context, writtenOn: today)
    }

    private func store(in container: ModelContainer, writer: DocumentWriter? = nil) throws -> FinanceStore {
        try FinanceStore(
            context: container.mainContext,
            now: todayDate,
            writer: writer
        )
    }

    private func failingWriter() -> DocumentWriter {
        DocumentWriter { _, context, _, _, _ in
            try context.fetch(FetchDescriptor<StoredAccount>()).forEach(context.delete)
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    @Test("A 1.5 document with empty planning tables stays 1.5")
    func fifteenDocumentWithoutPlanningStaysFifteen() throws {
        let container = try container()
        try persist(baseDocument(version: "1.5.0"), in: container.mainContext)
        let store = try store(in: container)
        let exported = try store.exportDocument()
        #expect(exported.schemaVersion == "1.5.0")
        #expect(exported.planning.plannedPurchases.isEmpty)
        #expect(exported.planning.sinkingFunds.isEmpty)
    }

    @Test("Saving the first sinking fund upgrades the document to 1.6")
    func firstSinkingFundUpgradesSchema() throws {
        let container = try container()
        try persist(baseDocument(version: "1.5.0"), in: container.mainContext)
        let store = try store(in: container)
        try store.saveSinkingFund(fund())
        let exported = try store.exportDocument()
        #expect(exported.schemaVersion == "1.6.0")
        #expect(exported.planning.sinkingFunds.map(\.id) == ["sf-1"])
        #expect(exported.transactions.count == 1)
        #expect(exported.planning.recurringObligations.map(\.id) == ["ob-rent"])
    }

    @Test("Saving the first planned purchase upgrades the document to 1.6")
    func firstPlannedPurchaseUpgradesSchema() throws {
        let container = try container()
        try persist(baseDocument(version: "1.5.0"), in: container.mainContext)
        let store = try store(in: container)
        try store.savePlannedPurchase(purchase())
        let exported = try store.exportDocument()
        #expect(exported.schemaVersion == "1.6.0")
        #expect(exported.planning.plannedPurchases.map(\.id) == ["goal-1"])
        #expect(exported.planning.plannedPurchases.first?.status == .planned)
    }

    @Test("A failed save leaves the old version and state")
    func failedSaveLeavesFifteenUntouched() throws {
        let container = try container()
        try persist(baseDocument(version: "1.5.0"), in: container.mainContext)
        let store = try store(in: container, writer: failingWriter())
        let before = try store.exportDocument()
        #expect(throws: AppManagementError.self) {
            try store.saveSinkingFund(fund())
        }
        let after = try store.exportDocument()
        #expect(after.schemaVersion == "1.5.0")
        #expect(after.planning.sinkingFunds.isEmpty)
        #expect(after.balances == before.balances)
        #expect(after.transactions == before.transactions)
        let reopened = try FinanceStore(context: container.mainContext, now: todayDate)
        #expect(try reopened.exportDocument().schemaVersion == "1.5.0")
        #expect(try reopened.exportDocument().planning.sinkingFunds.isEmpty)
    }

    @Test("1.6 planning state survives export and reload")
    func sixteenDataSurvivesReload() throws {
        let container = try container()
        try persist(baseDocument(version: "1.5.0"), in: container.mainContext)
        let store = try store(in: container)
        try store.saveSinkingFund(fund())
        try store.savePlannedPurchase(purchase(fundID: "sf-1"))
        let exported = try store.exportDocument()
        let reopened = try FinanceStore(context: container.mainContext, now: todayDate)
        let loaded = try reopened.exportDocument()
        #expect(loaded.schemaVersion == "1.6.0")
        #expect(loaded.planning.sinkingFunds == exported.planning.sinkingFunds)
        #expect(loaded.planning.plannedPurchases == exported.planning.plannedPurchases)
        #expect(try Interchange.encode(loaded) == Interchange.encode(exported))
    }

    @Test("Persisting a reservation does not spend, forecast, or change safe-to-spend")
    func persistenceHasNoEconomicEffect() throws {
        let container = try container()
        try persist(baseDocument(version: "1.5.0"), in: container.mainContext)
        let store = try store(in: container)
        let beforeSnap = store.snapshot
        let beforeDoc = try store.exportDocument()
        try store.saveSinkingFund(fund())
        try store.savePlannedPurchase(purchase(fundID: "sf-1"))
        let afterSnap = store.snapshot
        let afterDoc = try store.exportDocument()

        #expect(afterDoc.balances == beforeDoc.balances)
        #expect(afterDoc.transactions == beforeDoc.transactions)
        #expect(afterDoc.expectedTransactions == beforeDoc.expectedTransactions)
        #expect(afterDoc.planning.recurringObligations == beforeDoc.planning.recurringObligations)
        #expect(afterSnap.safeToSpend == beforeSnap.safeToSpend)
        #expect(afterSnap.rawShortfall == beforeSnap.rawShortfall)
        #expect(afterSnap.accountCash == beforeSnap.accountCash)
        #expect(afterSnap.budget.summary.spent == beforeSnap.budget.summary.spent)
        #expect(afterSnap.budget.summary.committed == beforeSnap.budget.summary.committed)
        #expect(afterSnap.firstRisk == beforeSnap.firstRisk)
        #expect(afterSnap.syncedObservations == beforeSnap.syncedObservations)
        #expect(afterDoc.externalObservations == beforeDoc.externalObservations)
        #expect(afterDoc.observationResolutions == beforeDoc.observationResolutions)
    }

    @Test("Deleting a referenced sinking fund fails closed")
    func deletingReferencedFundFailsClosed() throws {
        let container = try container()
        try persist(baseDocument(), in: container.mainContext)
        let store = try store(in: container)
        try store.saveSinkingFund(fund())
        try store.savePlannedPurchase(purchase(fundID: "sf-1"))
        #expect(throws: AppManagementError.sinkingFundStillReferenced) {
            try store.deleteSinkingFund(id: "sf-1")
        }
        #expect(try store.exportDocument().planning.sinkingFunds.map(\.id) == ["sf-1"])
        try store.deletePlannedPurchase(id: "goal-1")
        try store.deleteSinkingFund(id: "sf-1")
        #expect(try store.exportDocument().planning.sinkingFunds.isEmpty)
        #expect(try store.exportDocument().transactions.count == 1)
    }

    @Test("A pre-1.6 store with Phase 2.6 evidence migrates with empty planning tables")
    func phase26StoreMigratesWithoutPlanning() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("planning-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("FinanceCore-1.1.store")
        let excluded = Set([
            ObjectIdentifier(StoredPlannedPurchase.self),
            ObjectIdentifier(StoredSinkingFund.self)
        ])
        let legacyModels = FinanceSchema.models.filter { !excluded.contains(ObjectIdentifier($0)) }

        var source = try phase26Document()
        source.schemaVersion = "1.5.0"
        do {
            let legacy = try ModelContainer(
                for: Schema(legacyModels),
                configurations: ModelConfiguration(url: url)
            )
            try StoredDocumentGraph.replace(
                with: source,
                in: legacy.mainContext,
                writtenOn: today,
                appMetadata: AppPersistenceMetadata(trustedAutomationEnabled: false)
            )
        }

        let current = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(url: url)
        )
        let loaded = try #require(try StoredDocumentGraph.load(from: current.mainContext))
        #expect(loaded.schemaVersion == "1.5.0")
        #expect(loaded.planning.plannedPurchases.isEmpty)
        #expect(loaded.planning.sinkingFunds.isEmpty)
        #expect(loaded.trustedRules.map(\.id) == source.trustedRules.map(\.id))
        #expect(loaded.trustedRuleAuditEvents.map(\.id) == source.trustedRuleAuditEvents.map(\.id))
        #expect(loaded.externalObservations.map(\.id) == source.externalObservations.map(\.id))
        #expect(loaded.observationResolutions.map(\.observationID) == source.observationResolutions.map(\.observationID))
        #expect(loaded.transactions == source.transactions)
        #expect(loaded.balances == source.balances)

        let store = try FinanceStore(
            context: current.mainContext,
            now: todayDate
        )
        #expect(!store.trustedAutomationEnabled)
        let before = store.snapshot
        try store.saveSinkingFund(fund())
        let after = try store.exportDocument()
        #expect(after.schemaVersion == "1.6.0")
        #expect(after.planning.sinkingFunds.map(\.id) == ["sf-1"])
        #expect(after.trustedRules.map(\.id) == source.trustedRules.map(\.id))
        #expect(after.transactions == source.transactions)
        #expect(after.balances == source.balances)
        #expect(store.snapshot.safeToSpend == before.safeToSpend)
        #expect(store.trustedAutomationEnabled == false)
    }

    @Test("Shuffled persisted purchases encode identically")
    func shuffledPersistenceEncodesIdentically() throws {
        let container = try container()
        var document = baseDocument(version: "1.6.0")
        document.planning.plannedPurchases = [purchase(id: "z"), purchase(id: "a")]
        document.planning.sinkingFunds = [fund(id: "z-sf", reserved: 1_000), fund(id: "a-sf", reserved: 2_000)]
        try persist(document, in: container.mainContext)
        let loaded = try #require(try StoredDocumentGraph.load(from: container.mainContext))
        var reversed = document
        reversed.planning.plannedPurchases.reverse()
        reversed.planning.sinkingFunds.reverse()
        #expect(try Interchange.encode(loaded) == Interchange.encode(reversed))
    }

    private func phase26Document() throws -> FinanceDocument {
        let timestamp = Date(timeIntervalSince1970: 1_777_680_000)
        let boundary = Day(year: 2026, month: 8, day: 22)
        let account = account()
        let binding = ExternalAccountBinding(
            id: "binding", provider: .bnp,
            remoteOpaqueAccountID: "acct_00000000000000000000000000000001",
            localAccountID: account.id, syncStartBoundary: boundary, createdAt: timestamp
        )
        let observation = ExternalObservation(
            id: "obs_00000000000000000000000000000001",
            bindingID: binding.id,
            provider: .bnp,
            status: .booked,
            creditDebitIndicator: .debit,
            amount: euro(-349),
            bookingDate: Day(year: 2026, month: 8, day: 23),
            derivedTransactionDate: Day(year: 2026, month: 8, day: 21),
            derivedDateProvenance: .parsedFromProviderRemittance,
            rawMerchantText: "SYNTHETIC PROVIDER TEXT",
            eligibleForEconomicActual: true,
            observedAt: timestamp
        )
        var document = baseDocument(version: "1.5.0")
        document.externalAccountBindings = [binding]
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(
                observations: [observation],
                balances: [
                    ProviderBalanceSnapshot(
                        id: "balance", bindingID: binding.id, provider: .bnp,
                        balanceType: "CLBD", amount: euro(99_000),
                        referenceDate: Day(year: 2026, month: 8, day: 23), observedAt: timestamp
                    )
                ],
                candidates: []
            ),
            into: &document
        )
        let transaction = Transaction(
            id: "economic", date: Day(year: 2026, month: 8, day: 23), kind: .expense,
            legs: [AccountLeg(accountID: account.id, amount: euro(-349))],
            factivity: .observed,
            provenance: Provenance(source: "TEST", evidenceGrade: .userConfirmed)
        )
        try ExternalEvidenceReview.createTransaction(
            transaction,
            evidence: [.init(observationID: observation.id, role: .accountMovement)],
            resolvedAt: timestamp,
            in: &document
        )
        let rule = TrustedRule(
            id: "rule",
            title: "Synthetic suggestion rule",
            predicate: TrustedRulePredicate(
                provider: .bnp,
                bindingID: binding.id,
                merchantField: .rawMerchantText,
                merchantValue: "SYNTHETIC PROVIDER TEXT",
                direction: .debit,
                currencyCode: "EUR",
                currencyExponent: 2,
                exactMinorUnits: -349
            ),
            interpretation: TrustedRuleInterpretation(transactionKind: .expense),
            supportingConfirmations: [TrustedRuleSupport(
                observationID: observation.id,
                transactionID: transaction.id,
                confirmedAt: timestamp
            )],
            createdAt: timestamp.addingTimeInterval(1)
        )
        try TrustedRuleEngine.addDraft(rule, auditEventID: "rule-created", in: &document)
        try TrustedRuleEngine.approve(
            ruleID: rule.id,
            trustLevel: .suggestionOnly,
            at: timestamp.addingTimeInterval(2),
            auditEventID: "rule-approved",
            in: &document
        )
        return document
    }
}
