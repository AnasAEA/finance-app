import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

@MainActor
@Suite("Financial correction safety and recovery")
struct TransactionFinancialRecoveryTests {
    private func setup() throws -> EntryFixtures.Harness {
        let h = try EntryFixtures.Harness()
        try h.store.add(EntryFixtures.draft(merchant: "SYNTHETIC ORIGINAL"))
        return h
    }
    private func preview(_ store: FinanceStore) throws -> TransactionFinancialPreview {
        let id = try #require(try store.exportDocument().transactions.first?.id)
        var draft = try store.financialCorrectionDraft(forTransaction: id)
        draft.corrected.amount = .eur(20)
        draft.reason = "SYNTHETIC correction"
        return try store.previewFinancialCorrection(draft)
    }

    @Test func civilDayRolloverInvalidatesReviewedPreview() throws {
        let h = try setup()
        var instant = fixtureInstant(EntryFixtures.today)
        let store = try FinanceStore(context: h.container.mainContext, clock: { instant })
        let reviewed = try preview(store)
        instant = fixtureInstant(Day(year: 2026, month: 9, day: 17))
        #expect(throws: AppFinancialCorrectionError.staleDraft) { try store.confirmFinancialCorrection(reviewed) }
        #expect(try h.container.mainContext.fetchCount(FetchDescriptor<StoredTransactionFinancialCorrection>()) == 0)
    }

    @Test func newlyAddedRelationshipInvalidatesConfirmationAndNarrowWriterRechecksIt() throws {
        let h = try setup()
        let reviewed = try preview(h.store)
        let id = reviewed.draft.transactionID
        let other = try FinanceStore(context: ModelContext(h.container), now: fixtureInstant(EntryFixtures.today))
        try other.savePlannedPurchase(PlannedPurchase(id: "synthetic-purchase", name: "Synthetic purchase",
            targetAmount: Money(minorUnits: 1234, currency: .eur), status: .purchased,
            purchasedTransactionID: id, requirement: .euroBankPayment()))
        #expect(throws: AppFinancialCorrectionError.staleDraft) { try h.store.confirmFinancialCorrection(reviewed) }
        #expect(h.store.financialCorrectionBlocker(forTransaction: id) == .goalPurchase)
        let before = try other.exportDocument().transactions[0]
        let after = TransactionFinancialCorrection.replacing(before, day: before.date,
            leg: .init(accountID: before.legs[0].accountID, amount: Money(minorUnits: -2000, currency: .eur)))
        let audit = TransactionFinancialCorrection(id: UUID().uuidString, revision: 1,
            recordedAt: fixtureInstant(EntryFixtures.today), reason: "SYNTHETIC correction",
            before: before, after: after, beforeAccountName: "Synthetic account", afterAccountName: "Synthetic account")
        let revision = try #require(try h.container.mainContext.fetch(FetchDescriptor<StoredDocumentMeta>()).first?.documentRevision)
        #expect(throws: AppFinancialCorrectionError.goalPurchase) {
            try StoredTransactionFinancialCorrection.append(audit, in: h.container.mainContext,
                writtenOn: EntryFixtures.today, expectedRevision: revision)
        }
        #expect(try h.container.mainContext.fetchCount(FetchDescriptor<StoredTransactionFinancialCorrection>()) == 0)
    }

    @Test func paymentAndGoalRelationsAreNamedWithoutReinterpretation() throws {
        let h = try setup()
        var document = try h.store.exportDocument()
        let transaction = document.transactions[0]
        document.planning.settlements = [.init(id: "synthetic-paid", obligationID: "synthetic-obligation",
            expectedDay: transaction.date, resolution: .paid, actualTransactionID: transaction.id)]
        #expect(FinanceStore.financialCorrectionBlocker(transaction.id, in: document) == .paymentMatch)
        document.planning.settlements = []
        document.planning.plannedPurchases = [.init(id: "synthetic-goal", name: "Synthetic purchase", targetAmount: Money(minorUnits: 1234, currency: .eur),
            status: .purchased, purchasedTransactionID: transaction.id, requirement: .euroBankPayment())]
        #expect(FinanceStore.financialCorrectionBlocker(transaction.id, in: document) == .goalPurchase)
    }

    @Test func secondCorrectionCanReturnToOriginalValuesWithoutErasingFirstAssertion() throws {
        let h = try setup()
        let first = try preview(h.store)
        try h.store.confirmFinancialCorrection(first)
        var draft = try h.store.financialCorrectionDraft(forTransaction: first.draft.transactionID)
        draft.corrected = first.draft.original
        draft.reason = "SYNTHETIC second review"
        try h.store.confirmFinancialCorrection(h.store.previewFinancialCorrection(draft))
        let history = try StoredTransactionFinancialCorrection.load(from: h.container.mainContext)
        #expect(history.map(\.revision) == [1, 2])
        #expect(history[1].before == history[0].after && history[1].after == history[0].before)
        #expect(try h.store.exportDocument().transactions[0] == history[0].before)
        #expect(throws: AppFinancialCorrectionError.staleDraft) { try h.store.confirmFinancialCorrection(first) }
    }

    @Test func tamperingIsRefusedEvenWhenRecoveryDigestIsRecomputed() throws {
        let h = try setup()
        try h.store.confirmFinancialCorrection(preview(h.store))
        let backup = try h.store.exportBackup()
        let document = try DocumentImporter.decode(backup.data)
        let metadata = try AppBackupMetadata.read(from: backup.data, document: document)
        let base = try #require(metadata.fullRecovery?.transactionFinancialCorrections?.first)
        func replaced(after: Transaction? = nil, revision: Int = 1, reason: String = "SYNTHETIC correction") -> TransactionFinancialCorrection {
            .init(id: base.id, revision: revision, recordedAt: base.recordedAt, reason: reason,
                  before: base.before, after: after ?? base.after,
                  beforeAccountName: base.beforeAccountName, afterAccountName: base.afterAccountName)
        }
        let alteredNote = Transaction(id: base.after.id, date: base.after.date, kind: base.after.kind,
            legs: base.after.legs, factivity: base.after.factivity, lifecycle: base.after.lifecycle,
            note: "SYNTHETIC ALTERED", provenance: base.after.provenance)
        let alteredCurrency = TransactionFinancialCorrection.replacing(base.before, day: base.after.date,
            leg: .init(accountID: base.after.legs[0].accountID, amount: Money(minorUnits: -2000, currency: .kwd)))
        let endpoint = TransactionFinancialCorrection.replacing(base.before, day: base.after.date,
            leg: .init(accountID: base.after.legs[0].accountID, amount: Money(minorUnits: -2001, currency: .eur)))
        var unknownFormat = base
        unknownFormat.formatVersion = 2
        for records in [[base, base], [unknownFormat], [replaced(revision: 2)], [replaced(reason: " ")],
                        [replaced(after: alteredNote)], [replaced(after: alteredCurrency)], [replaced(after: endpoint)]] {
            var envelope = metadata
            var recovery = try #require(envelope.fullRecovery)
            recovery.transactionFinancialCorrections = records
            recovery.contentSHA256 = try recovery.integrityDigest()
            envelope.fullRecovery = recovery
            let container = try ModelContainer(for: Schema(FinanceSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let target = try FinanceStore(context: container.mainContext, now: fixtureInstant(EntryFixtures.today))
            #expect(throws: AppImportError.invalidBackupMetadata) { try target.prepareImport(from: envelope.encoding(document)) }
            #expect(try FullRecoveryState.destinationIsEmpty(container.mainContext))
        }
    }

    @Test func failedRecoveryRollsBackFinancialHistoryAndTheEntireLedger() throws {
        enum Failure: Error { case synthetic }
        let h = try setup()
        try h.store.confirmFinancialCorrection(preview(h.store))
        let backup = try h.store.exportBackup()
        let writer = DocumentWriter({ _, _, _, _, _ in throw Failure.synthetic }, recover: { document, context, day, presentation, metadata, recovery in
            try StoredDocumentGraph.replace(with: document, in: context, writtenOn: day,
                presentation: presentation, appMetadata: metadata, beforeSave: {
                    try recovery.insert(in: $0)
                    throw Failure.synthetic
                })
        })
        let container = try ModelContainer(for: Schema(FinanceSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let target = try FinanceStore(context: container.mainContext, now: fixtureInstant(EntryFixtures.today), writer: writer)
        _ = try target.prepareImport(from: backup.data)
        #expect(throws: AppImportError.self) { try target.confirmImport() }
        #expect(try FullRecoveryState.destinationIsEmpty(container.mainContext) && !container.mainContext.hasChanges)
        #expect(target.financialCorrectionHistory(forTransaction: "missing").isEmpty)
    }

    @Test func previousDiskSchemaAndMetadataHistoryMigrateAndFinancialHistoryReopens() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.store")
        let baseline = Schema(FinanceSchema.models.filter { ObjectIdentifier($0) != ObjectIdentifier(StoredTransactionFinancialCorrection.self) })
        func seed() throws -> FinanceDocument {
            let container = try ModelContainer(for: baseline, configurations: ModelConfiguration(schema: baseline, url: url))
            var document = EntryFixtures.document()
            let transaction = Transaction(id: "synthetic-legacy", date: EntryFixtures.today, kind: .expense,
                legs: [.init(accountID: EntryFixtures.bank.id, amount: Money(minorUnits: -1234, currency: .eur))],
                factivity: .observed, provenance: .init(source: "SYNTHETIC", evidenceGrade: .userConfirmed))
            document.transactions = [transaction]
            container.mainContext.insert(try StoredDocumentMeta(document: document, writtenOn: EntryFixtures.today))
            document.accounts.enumerated().map { StoredAccount($0.element, sequence: $0.offset) }.forEach(container.mainContext.insert)
            try document.balances.enumerated().map { try StoredAccountBalance($0.element, sequence: $0.offset) }.forEach(container.mainContext.insert)
            try document.incomeSources.enumerated().map { try StoredIncomeSource($0.element, sequence: $0.offset, appIsActive: true) }.forEach(container.mainContext.insert)
            container.mainContext.insert(try StoredTransaction(transaction, sequence: 0, merchant: "SYNTHETIC LEGACY"))
            container.mainContext.insert(StoredTransactionCorrection(.init(id: UUID().uuidString, transactionID: transaction.id,
                revision: 1, recordedAt: fixtureInstant(EntryFixtures.today), before: .init(merchant: nil, categoryKey: nil),
                after: .init(merchant: "SYNTHETIC LEGACY", categoryKey: nil))))
            try container.mainContext.save()
            return document
        }
        let document = try seed()
        let schema = Schema(FinanceSchema.models)
        let current = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let store = try FinanceStore(context: current.mainContext, now: fixtureInstant(EntryFixtures.today))
        #expect(!store.storeIsUnreadable)
        #expect(try store.exportDocument() == document)
        #expect(store.correctionHistory(forTransaction: "synthetic-legacy").count == 1)
        try store.confirmFinancialCorrection(preview(store))
        let reopenedContainer = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let reopened = try FinanceStore(context: reopenedContainer.mainContext, now: fixtureInstant(EntryFixtures.today))
        #expect(!reopened.storeIsUnreadable)
        #expect(reopened.financialCorrectionHistory(forTransaction: "synthetic-legacy").count == 1)
        #expect(reopened.correctionHistory(forTransaction: "synthetic-legacy").count == 1)
        #expect(try reopened.exportBackup().data == store.exportBackup().data)
    }

    @Test func crossMonthCorrectionChangesComparisonWithoutRewritingAcceptedCheckpoint() throws {
        let august = Day(year: 2026, month: 8, day: 16)
        var document = EntryFixtures.document()
        document.accounts = [EntryFixtures.bank]
        document.balances = [.init(accountID: EntryFixtures.bank.id, balance: Money(minorUnits: 50000, currency: .eur), asOf: august.monthKey.firstDay)]
        document.externalAccountBindings = [.init(id: "synthetic-binding", provider: .bnp,
            remoteOpaqueAccountID: "synthetic-remote", localAccountID: EntryFixtures.bank.id,
            syncStartBoundary: august.monthKey.firstDay, createdAt: fixtureInstant(august))]
        document.planning.budgets = [.init(id: "synthetic-food", name: "Synthetic groceries", spendingClass: .flexible,
            monthlyAmount: Money(minorUnits: 10000, currency: .eur), effectiveFrom: august.monthKey,
            confirmation: .userConfirmed, categoryKeys: ["food"])]
        var metadata = AppPersistenceMetadata.empty
        metadata.authoritativeLiveCoverage = ["synthetic-remote": .init(provider: .bnp, remoteOpaqueAccountID: "synthetic-remote",
            localAccountID: EntryFixtures.bank.id, syncedFrom: august.monthKey.firstDay, syncedThrough: EntryFixtures.today,
            authoritativeAt: fixtureInstant(EntryFixtures.today))]
        let container = try ModelContainer(for: Schema(FinanceSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        try StoredDocumentGraph.replace(with: document, in: container.mainContext, writtenOn: EntryFixtures.today, appMetadata: metadata)
        let store = try FinanceStore(context: container.mainContext, now: fixtureInstant(EntryFixtures.today))
        var entry = EntryFixtures.draft()
        entry.day = DomainMapper.civilDay(august)
        try store.add(entry)
        let selection = ReviewPeriodSelection(offset: -1)
        guard case .storedFirstClose = store.writeEndedMonthCheckpoint(selection) else {
            Issue.record("Expected a clean synthetic month close")
            return
        }
        let accepted = try FullRecoveryState.capture(from: container.mainContext).checkpointRevisions
        let id = try #require(try store.exportDocument().transactions.first?.id)
        var draft = try store.financialCorrectionDraft(forTransaction: id)
        draft.corrected.day = .init(year: 2026, month: 9, day: 1)
        draft.corrected.amount = .eur(20)
        draft.reason = "SYNTHETIC corrected month and amount"
        let reviewed = try store.previewFinancialCorrection(draft)
        #expect(reviewed.affectedMonths == ["2026-08", "2026-09"])
        try store.confirmFinancialCorrection(reviewed)
        guard case .changedSinceClose = store.endedMonthVerification(selection)?.readiness.baselineComparison else {
            Issue.record("Moving an expense out of a verified month must expose changed financial meaning")
            return
        }
        #expect(try FullRecoveryState.capture(from: container.mainContext).checkpointRevisions == accepted)
        #expect(store.snapshot.budget.lines.first { $0.name == "Synthetic groceries" }?.spent == .eur(20))
    }

    @Test func missingBalancePreviewStaysUnavailable() throws {
        var document = EntryFixtures.document()
        document.balances = []
        let h = try EntryFixtures.Harness(document)
        try h.store.add(EntryFixtures.draft())
        let reviewed = try preview(h.store)
        #expect(reviewed.accountImpacts.count == 1)
        #expect(reviewed.accountImpacts[0].before == nil && reviewed.accountImpacts[0].after == nil)
    }


    @Test func retiredUnreferencedPendingEvidenceDoesNotPermanentlyInvalidateEditor() throws {
        var document = EntryFixtures.document()
        document.externalAccountBindings = [.init(id: "synthetic-binding", provider: .bnp,
            remoteOpaqueAccountID: "synthetic-remote", localAccountID: EntryFixtures.bank.id,
            syncStartBoundary: EntryFixtures.today.monthKey.firstDay, createdAt: fixtureInstant(EntryFixtures.today))]
        let h = try EntryFixtures.Harness(document)
        try h.store.add(EntryFixtures.draft())
        let observation = ExternalObservation(id: "synthetic-retired", bindingID: "synthetic-binding", provider: .bnp,
            identity: .provisionalSnapshot, status: .pending, creditDebitIndicator: .debit,
            amount: Money(minorUnits: -100, currency: .eur), bookingDate: EntryFixtures.today,
            structuredMerchantName: "SYNTHETIC OLD HOLD", eligibleForEconomicActual: false,
            observedAt: fixtureInstant(EntryFixtures.today))
        h.container.mainContext.insert(try StoredPendingEvidenceArchive(.init(observations: [observation],
            resolutions: [.init(observationID: observation.id, state: .provisional)])))
        try h.container.mainContext.save()
        let exported = try h.store.exportDocument()
        #expect(exported.externalObservations.count == 1)
        #expect(try StoredDocumentGraph.load(from: h.container.mainContext)?.externalObservations.isEmpty == true)
        try h.store.confirmFinancialCorrection(preview(h.store))
        #expect(try h.store.exportDocument().externalObservations == exported.externalObservations)
        #expect(try h.container.mainContext.fetchCount(FetchDescriptor<StoredPendingEvidenceArchive>()) == 1)
        #expect(try h.store.exportBackup().summary.transactionCorrectionCount == 1)
    }

}
