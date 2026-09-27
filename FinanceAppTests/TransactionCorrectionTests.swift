import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

@MainActor
@Suite("Identity-preserving transaction corrections")
struct TransactionCorrectionTests {
    private func harness() throws -> EntryFixtures.Harness {
        let h = try EntryFixtures.Harness()
        try h.store.add(EntryFixtures.draft(merchant: "SYNTHETIC ORIGINAL"))
        return h
    }

    private func draft(_ store: FinanceStore) throws -> TransactionCorrectionDraft {
        let id = try #require(store.snapshot.activity.flatMap(\.rows).first?.id)
        return try store.correctionDraft(forTransaction: id)
    }

    @Test func correctionPreservesEconomicGraphAndStoredIdentities() throws {
        let h = try harness()
        let before = try h.store.exportDocument()
        let rows = try h.container.mainContext.fetch(FetchDescriptor<StoredTransaction>())
        let row = try #require(rows.first)
        let persistentID = row.persistentModelID
        let legIDs = row.legs.map(\.persistentModelID)
        let balance = h.store.snapshot.accounts
        var edit = try draft(h.store)
        edit.corrected = .init(merchant: "  SYNTHETIC CORRECTED  ", categoryKey: "transport")
        try h.store.correctTransactionMetadata(edit)
        #expect(try h.store.exportDocument() == before)
        #expect(h.store.snapshot.accounts == balance)
        #expect(row.persistentModelID == persistentID && row.legs.map(\.persistentModelID) == legIDs)
        #expect(row.appMerchant == "SYNTHETIC CORRECTED" && row.appCategoryKey == "transport")
        #expect(h.store.snapshot.activity.flatMap(\.rows).first?.title == "SYNTHETIC CORRECTED")
        let history = h.store.correctionHistory(forTransaction: edit.transactionID)
        #expect(history.count == 1 && history[0].revision == 1)
        #expect(history[0].before == edit.original && history[0].after.merchant == "SYNTHETIC CORRECTED")
        #expect(h.store.removalBlocker(forTransaction: edit.transactionID) == .hasCorrectionHistory)
        #expect(throws: AppRemovalError.hasCorrectionHistory) { try h.store.deleteActivityRow(id: edit.transactionID) }
        let reopened = try FinanceStore(context: ModelContext(h.container), now: fixtureInstant(EntryFixtures.today))
        #expect(reopened.correctionHistory(forTransaction: edit.transactionID) == history)
        #expect(try reopened.correctionDraft(forTransaction: edit.transactionID).original == history[0].after)
    }

    @Test func staleDraftRefusedEvenWhenMetadataReturnsToOriginalValues() throws {
        let h = try harness()
        var stale = try draft(h.store)
        var first = stale
        first.corrected.merchant = "SYNTHETIC SECOND"
        try h.store.correctTransactionMetadata(first)
        var second = try draft(h.store)
        second.corrected = stale.original
        try h.store.correctTransactionMetadata(second)
        let backup = try h.store.exportBackup().data
        stale.corrected.merchant = "SYNTHETIC STALE"
        #expect(throws: AppCorrectionError.staleDraft) { try h.store.correctTransactionMetadata(stale) }
        #expect(try h.store.exportBackup().data == backup)
        #expect(h.store.correctionHistory(forTransaction: stale.transactionID).map(\.revision) == [1, 2])
    }

    @Test func staleEditorInAnotherContextCannotAppendOverAcceptedHistory() throws {
        let h = try harness()
        let other = try FinanceStore(context: ModelContext(h.container), now: fixtureInstant(EntryFixtures.today))
        var stale = try draft(other)
        var accepted = try draft(h.store)
        accepted.corrected.merchant = "SYNTHETIC ACCEPTED"
        try h.store.correctTransactionMetadata(accepted)
        stale.corrected.merchant = "SYNTHETIC STALE"
        #expect(throws: AppCorrectionError.staleDraft) { try other.correctTransactionMetadata(stale) }
        #expect(try StoredTransactionCorrection.load(from: h.container.mainContext).count == 1)
        #expect(try h.store.correctionDraft(forTransaction: accepted.transactionID).original.merchant == "SYNTHETIC ACCEPTED")
    }

    @Test func linkedBankEvidenceAndExpectedPaymentStayIntact() throws {
        var document = EntryFixtures.document()
        document.planning.recurringObligations = [.init(id: "synthetic-obligation", name: "Synthetic payment",
            amount: Money(minorUnits: 1234, currency: .eur), spec: .oneShot(on: EntryFixtures.today),
            requirement: .euroBankPayment(), spendingClass: .flexible)]
        document.externalAccountBindings = [.init(id: "synthetic-binding", provider: .bnp,
            remoteOpaqueAccountID: "synthetic-remote", localAccountID: EntryFixtures.bank.id,
            syncStartBoundary: EntryFixtures.today.monthKey.firstDay, createdAt: fixtureInstant(EntryFixtures.today))]
        document.externalObservations = [.init(id: "synthetic-observation", bindingID: "synthetic-binding", provider: .bnp,
            identity: .durable, status: .booked, creditDebitIndicator: .debit,
            amount: Money(minorUnits: -1234, currency: .eur), bookingDate: EntryFixtures.today,
            structuredMerchantName: "SYNTHETIC BANK TEXT", eligibleForEconomicActual: true, observedAt: fixtureInstant(EntryFixtures.today))]
        document.observationResolutions = [.init(observationID: "synthetic-observation", state: .unreviewed)]
        let h = try EntryFixtures.Harness(document)
        try h.store.add(EntryFixtures.draft(merchant: "SYNTHETIC USER LABEL"))
        var edit = try draft(h.store)
        try h.store.matchObservation("synthetic-observation", toTransaction: edit.transactionID)
        let match = try #require(h.store.matches(forTransaction: edit.transactionID).first)
        try h.store.matchPayment(expectedPaymentID: match.expectedPaymentID, transactionID: edit.transactionID)
        let before = try h.store.exportDocument()
        let evidence = h.store.linkedEvidence(forTransaction: edit.transactionID)
        let reconciliation = h.store.snapshot.reconciliations[edit.transactionID]
        edit.corrected = .init(merchant: "SYNTHETIC CORRECTED LABEL", categoryKey: "transport")
        try h.store.correctTransactionMetadata(edit)
        #expect(try h.store.exportDocument() == before)
        #expect(h.store.linkedEvidence(forTransaction: edit.transactionID) == evidence)
        #expect(evidence.first?.title == "SYNTHETIC BANK TEXT")
        #expect(h.store.snapshot.reconciliations[edit.transactionID] == reconciliation)
    }

    @Test func categoryChangesReallocateBudgetWithoutChangingTotalSpend() throws {
        let h = try harness()
        try h.store.saveBudgetLine(.init(name: "Synthetic groceries", monthlyTarget: .eur(100), categoryKeys: ["food"]))
        try h.store.saveBudgetLine(.init(name: "Synthetic transport", monthlyTarget: .eur(100), categoryKeys: ["transport"]))
        let total = h.store.snapshot.everydayBudget.spent
        #expect(h.store.snapshot.budget.lines.first { $0.name == "Synthetic groceries" }?.spent == .eur(12.34))
        var edit = try draft(h.store)
        edit.corrected.categoryKey = "transport"
        try h.store.correctTransactionMetadata(edit)
        #expect(h.store.snapshot.budget.lines.first { $0.name == "Synthetic groceries" }?.spent == .zeroEUR)
        #expect(h.store.snapshot.budget.lines.first { $0.name == "Synthetic transport" }?.spent == .eur(12.34))
        #expect(h.store.snapshot.everydayBudget.spent == total)
    }

    @Test func categoryCorrectionInvalidatesCurrentComparisonWithoutRewritingAcceptedCheckpoint() throws {
        let august = Day(year: 2026, month: 8, day: 5)
        var document = EntryFixtures.document()
        document.externalAccountBindings = [.init(id: "synthetic-binding", provider: .bnp,
            remoteOpaqueAccountID: "synthetic-remote", localAccountID: EntryFixtures.bank.id,
            syncStartBoundary: august.monthKey.firstDay, createdAt: fixtureInstant(august))]
        // A single bound account gives the ended month affirmative coverage.
        document.accounts = [EntryFixtures.bank]
        document.balances = [.init(accountID: EntryFixtures.bank.id, balance: Money(minorUnits: 50000, currency: .eur), asOf: august.monthKey.firstDay)]
        document.planning.budgets = [
            .init(id: "synthetic-food", name: "Synthetic groceries", spendingClass: .flexible,
                monthlyAmount: Money(minorUnits: 10000, currency: .eur), effectiveFrom: august.monthKey,
                confirmation: .userConfirmed, categoryKeys: ["food"]),
            .init(id: "synthetic-transport", name: "Synthetic transport", spendingClass: .flexible,
                monthlyAmount: Money(minorUnits: 10000, currency: .eur), effectiveFrom: august.monthKey,
                confirmation: .userConfirmed, categoryKeys: ["transport"])
        ]
        var metadata = AppPersistenceMetadata.empty
        metadata.authoritativeLiveCoverage = ["synthetic-remote": .init(provider: .bnp, remoteOpaqueAccountID: "synthetic-remote",
            localAccountID: EntryFixtures.bank.id, syncedFrom: august.monthKey.firstDay, syncedThrough: EntryFixtures.today,
            authoritativeAt: fixtureInstant(EntryFixtures.today))]
        let container = try ModelContainer(for: Schema(FinanceSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        try StoredDocumentGraph.replace(with: document, in: container.mainContext, writtenOn: EntryFixtures.today, appMetadata: metadata)
        let store = try FinanceStore(context: container.mainContext, now: fixtureInstant(EntryFixtures.today))
        var entry = EntryFixtures.draft(merchant: "SYNTHETIC AUGUST")
        entry.day = DomainMapper.civilDay(august)
        try store.add(entry)
        let selection = ReviewPeriodSelection(offset: -1)
        let close = store.writeEndedMonthCheckpoint(selection)
        guard case let .storedFirstClose(first) = close else {
            Issue.record("Expected a clean first close for the synthetic covered month: \(close)")
            return
        }
        let accepted = try FullRecoveryState.capture(from: container.mainContext).checkpointRevisions
        var edit = try draft(store)
        edit.corrected.merchant = "SYNTHETIC NEW NAME"
        try store.correctTransactionMetadata(edit)
        #expect(store.endedMonthVerification(selection)?.readiness.baselineComparison == .unchangedSinceClose(previousQuality: first.quality))
        edit = try draft(store)
        edit.corrected.categoryKey = "transport"
        try store.correctTransactionMetadata(edit)
        guard case .changedSinceClose = store.endedMonthVerification(selection)?.readiness.baselineComparison else {
            Issue.record("A category correction must mark the accepted month changed")
            return
        }
        #expect(try FullRecoveryState.capture(from: container.mainContext).checkpointRevisions == accepted)
    }

    @Test func invalidAndEmptyEditsWriteNothing() throws {
        let h = try harness()
        let backup = try h.store.exportBackup().data
        let original = try draft(h.store)
        #expect(throws: AppCorrectionError.noChanges) { try h.store.correctTransactionMetadata(original) }
        var invalid = original
        invalid.corrected.categoryKey = "income"
        #expect(throws: AppCorrectionError.invalidCategory) { try h.store.correctTransactionMetadata(invalid) }
        invalid.corrected.categoryKey = "unknown-synthetic-category"
        #expect(throws: AppCorrectionError.invalidCategory) { try h.store.correctTransactionMetadata(invalid) }
        invalid.corrected = .init(merchant: String(repeating: "X", count: 201), categoryKey: original.original.categoryKey)
        #expect(throws: AppCorrectionError.merchantTooLong) { try h.store.correctTransactionMetadata(invalid) }
        #expect(try h.store.exportBackup().data == backup)
    }

    @Test func movementCategoriesCannotBeReinterpretedAsSpending() throws {
        let h = try EntryFixtures.Harness()
        try h.store.add(EntryFixtures.draft(kind: .transfer, counterAccountID: EntryFixtures.wallet.id))
        var edit = try draft(h.store)
        #expect(edit.categories.isEmpty)
        edit.corrected.categoryKey = "food"
        #expect(throws: AppCorrectionError.invalidCategory) { try h.store.correctTransactionMetadata(edit) }
        edit.corrected.categoryKey = edit.original.categoryKey
        edit.corrected.merchant = "SYNTHETIC MOVEMENT LABEL"
        let document = try h.store.exportDocument()
        try h.store.correctTransactionMetadata(edit)
        #expect(try h.store.exportDocument() == document)
    }

    @Test func failureAfterStagingMetadataAndAuditRollsBackBoth() throws {
        enum Failure: Error { case synthetic }
        let h = try harness()
        let before = try h.store.exportBackup().data
        let failing = DocumentWriter({ _, _, _, _, _ in throw Failure.synthetic }, correctMetadata: { correction, context, _ in
            let row = try #require(try context.fetch(FetchDescriptor<StoredTransaction>()).first)
            row.appMerchant = correction.after.merchant
            context.insert(StoredTransactionCorrection(correction))
            throw Failure.synthetic
        })
        let store = try FinanceStore(context: h.container.mainContext, now: fixtureInstant(EntryFixtures.today), writer: failing)
        var edit = try draft(store)
        edit.corrected.merchant = "SYNTHETIC FAILED"
        #expect(throws: AppCorrectionError.persistenceFailed) { try store.correctTransactionMetadata(edit) }
        #expect(try store.exportBackup().data == before)
        #expect(store.correctionHistory(forTransaction: edit.transactionID).isEmpty)
        #expect(try h.container.mainContext.fetchCount(FetchDescriptor<StoredTransactionCorrection>()) == 0)
        try h.store.correctTransactionMetadata(edit)
        #expect(h.store.correctionHistory(forTransaction: edit.transactionID).count == 1)
    }

    @Test func refusalDoesNotDiscardUnrelatedStagedChanges() throws {
        let h = try harness()
        var edit = try draft(h.store)
        edit.corrected.merchant = "SYNTHETIC FIX"
        let account = try #require(try h.container.mainContext.fetch(FetchDescriptor<StoredAccount>()).first)
        account.name = "SYNTHETIC STAGED NAME"
        #expect(throws: AppCorrectionError.persistenceFailed) { try h.store.correctTransactionMetadata(edit) }
        #expect(account.name == "SYNTHETIC STAGED NAME" && h.container.mainContext.hasChanges)
        #expect(try h.container.mainContext.fetchCount(FetchDescriptor<StoredTransactionCorrection>()) == 0)
        h.container.mainContext.rollback()
    }

    @Test func failedRecoveryRollsBackCorrectionHistoryAndLedgerTogether() throws {
        enum Failure: Error { case synthetic }
        let h = try harness()
        var edit = try draft(h.store)
        edit.corrected.merchant = "SYNTHETIC FIX"
        try h.store.correctTransactionMetadata(edit)
        let backup = try h.store.exportBackup()
        let writer = DocumentWriter({ _, _, _, _, _ in throw Failure.synthetic }, recover: { document, context, day, presentation, metadata, recovery in
            try StoredDocumentGraph.replace(with: document, in: context, writtenOn: day,
                presentation: presentation, appMetadata: metadata, beforeSave: {
                    recovery.insert(in: $0)
                    throw Failure.synthetic
                })
        })
        let container = try ModelContainer(for: Schema(FinanceSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try FinanceStore(context: container.mainContext, now: fixtureInstant(EntryFixtures.today), writer: writer)
        _ = try store.prepareImport(from: backup.data)
        #expect(throws: AppImportError.self) { try store.confirmImport() }
        #expect(try FullRecoveryState.destinationIsEmpty(container.mainContext))
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredTransaction>()) == 0)
        #expect(store.correctionHistory(forTransaction: edit.transactionID).isEmpty)
    }

    @Test func ordinaryGraphWritesPreserveAuditAndCannotEraseCorrectedMetadata() throws {
        let h = try harness()
        var edit = try draft(h.store)
        edit.corrected.merchant = "SYNTHETIC FIX"
        try h.store.correctTransactionMetadata(edit)
        let history = h.store.correctionHistory(forTransaction: edit.transactionID)
        try h.store.saveBudgetLine(.init(name: "Synthetic groceries", monthlyTarget: .eur(100), categoryKeys: ["food"]))
        #expect(try StoredTransactionCorrection.load(from: h.container.mainContext) == history)
        let backup = try h.store.exportBackup().data
        #expect(throws: AppImportError.invalidBackupMetadata) {
            try StoredDocumentGraph.replace(with: h.store.exportDocument(), in: h.container.mainContext, writtenOn: EntryFixtures.today)
        }
        #expect(try h.store.exportBackup().data == backup)
    }

    @Test func readOnlyUnreadableAndMissingTransactionsAreRefused() throws {
        let h = try harness()
        var edit = try draft(h.store)
        edit.corrected.merchant = "SYNTHETIC FIX"
        let fixed = FinanceStore(snapshot: .empty(asOf: DomainMapper.civilDay(EntryFixtures.today)))
        #expect(throws: AppCorrectionError.storeIsReadOnly) { try fixed.correctTransactionMetadata(edit) }
        let unreadable = try FinanceStore(context: nil, now: fixtureInstant(EntryFixtures.today), unavailableReason: "Synthetic failure")
        #expect(throws: AppCorrectionError.storeUnreadable) { try unreadable.correctTransactionMetadata(edit) }
        #expect(throws: AppCorrectionError.notFound) { try h.store.correctionDraft(forTransaction: "synthetic-missing") }
    }

    @Test func fullRecoveryRoundTripIncludesHistoryAndRefusesSemanticTampering() throws {
        let h = try harness()
        var edit = try draft(h.store)
        edit.corrected = .init(merchant: nil, categoryKey: nil)
        try h.store.correctTransactionMetadata(edit)
        let backup = try h.store.exportBackup()
        #expect(backup.summary.transactionCorrectionCount == 1)
        let document = try DocumentImporter.decode(backup.data)
        let metadata = try AppBackupMetadata.read(from: backup.data, document: document)
        #expect(metadata.version == 3)
        let destination = try ModelContainer(for: Schema(FinanceSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let restored = try FinanceStore(context: destination.mainContext, now: fixtureInstant(EntryFixtures.today))
        let preview = try restored.prepareImport(from: backup.data)
        #expect(preview.transactionCorrectionCount == 1)
        #expect(try restored.confirmImport().transactionCorrectionCount == 1)
        #expect(try restored.exportBackup().data == backup.data)
        #expect(restored.correctionHistory(forTransaction: edit.transactionID) == h.store.correctionHistory(forTransaction: edit.transactionID))

        let changes: [(inout FullRecoveryState) -> Void] = [
            { $0.transactionCorrections![0] = .init(id: UUID().uuidString, transactionID: "missing", revision: 1,
                recordedAt: Date(), before: edit.original, after: edit.corrected) },
            { $0.transactionCorrections!.append($0.transactionCorrections![0]) },
            { let old = $0.transactionCorrections![0]; $0.transactionCorrections![0] = .init(id: old.id, transactionID: old.transactionID,
                revision: 2, recordedAt: old.recordedAt, before: old.before, after: old.after) },
            { let old = $0.transactionCorrections![0]; $0.transactionCorrections![0] = .init(id: old.id, transactionID: old.transactionID,
                revision: 1, recordedAt: old.recordedAt, before: old.before, after: .init(merchant: "MISMATCH", categoryKey: nil)) }
        ]
        for change in changes {
            var corrupt = metadata
            var recovery = try #require(corrupt.fullRecovery)
            change(&recovery)
            recovery.contentSHA256 = try recovery.integrityDigest()
            corrupt.fullRecovery = recovery
            let empty = try ModelContainer(for: Schema(FinanceSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let target = try FinanceStore(context: empty.mainContext, now: fixtureInstant(EntryFixtures.today))
            #expect(throws: AppImportError.invalidBackupMetadata) { try target.prepareImport(from: corrupt.encoding(document)) }
            #expect(try FullRecoveryState.destinationIsEmpty(empty.mainContext))
        }
        var downgraded = metadata
        downgraded.version = 2
        #expect(throws: AppImportError.invalidBackupMetadata) { try AppBackupMetadata.read(from: downgraded.encoding(document), document: document) }
    }

    @Test func corruptStoredCorrectionMakesStoreReadOnly() throws {
        let h = try harness()
        var edit = try draft(h.store)
        edit.corrected.merchant = "SYNTHETIC FIX"
        try h.store.correctTransactionMetadata(edit)
        let audit = try #require(try h.container.mainContext.fetch(FetchDescriptor<StoredTransactionCorrection>()).first)
        audit.revision = 4
        try h.container.mainContext.save()
        let reopened = try FinanceStore(context: ModelContext(h.container), now: fixtureInstant(EntryFixtures.today))
        #expect(reopened.storeIsUnreadable)
        #expect(throws: AppCorrectionError.storeUnreadable) { try reopened.correctionDraft(forTransaction: edit.transactionID) }
    }

    @Test func orphanHistoryIsUnreadableRatherThanAnEmptyImportDestination() throws {
        let h = try harness()
        var edit = try draft(h.store)
        edit.corrected.merchant = "SYNTHETIC FIX"
        try h.store.correctTransactionMetadata(edit)
        try h.container.mainContext.fetch(FetchDescriptor<StoredDocumentMeta>()).forEach(h.container.mainContext.delete)
        try h.container.mainContext.save()
        let reopened = try FinanceStore(context: ModelContext(h.container), now: fixtureInstant(EntryFixtures.today))
        #expect(reopened.storeIsUnreadable && reopened.importBlocker == .storeUnreadable)
        #expect(try h.container.mainContext.fetchCount(FetchDescriptor<StoredTransactionCorrection>()) == 1)
    }

    @Test func previousDiskSchemaMigratesAdditivelyAndCorrectionsSurviveReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.store")
        let baseline = Schema(FinanceSchema.models.filter { ObjectIdentifier($0) != ObjectIdentifier(StoredTransactionCorrection.self) })
        func seed() throws -> FinanceDocument {
            let container = try ModelContainer(for: baseline, configurations: ModelConfiguration(schema: baseline, url: url))
            var legacy = EntryFixtures.document()
            let transaction = Transaction(id: "synthetic-legacy", date: EntryFixtures.today, kind: .expense,
                legs: [.init(accountID: EntryFixtures.bank.id, amount: Money(minorUnits: -100, currency: .eur))], factivity: .observed)
            legacy.transactions = [transaction]
            container.mainContext.insert(try StoredDocumentMeta(document: legacy, writtenOn: EntryFixtures.today))
            legacy.accounts.enumerated().map { StoredAccount($0.element, sequence: $0.offset) }.forEach(container.mainContext.insert)
            try legacy.balances.enumerated().map { try StoredAccountBalance($0.element, sequence: $0.offset) }.forEach(container.mainContext.insert)
            try legacy.incomeSources.enumerated().map { try StoredIncomeSource($0.element, sequence: $0.offset, appIsActive: true) }.forEach(container.mainContext.insert)
            let stored = try StoredTransaction(transaction, sequence: 0)
            container.mainContext.insert(stored)
            try container.mainContext.save()
            return legacy
        }
        let legacy = try seed()
        let schema = Schema(FinanceSchema.models)
        let current = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let store = try FinanceStore(context: current.mainContext, now: fixtureInstant(EntryFixtures.today))
        #expect(!store.storeIsUnreadable)
        #expect(try store.exportDocument() == legacy)
        // Migration may remap SwiftData object IDs. Logical transaction identity
        // and the complete economic graph must survive unchanged, as above.
        var edit = try store.correctionDraft(forTransaction: "synthetic-legacy")
        edit.corrected.merchant = "SYNTHETIC MIGRATED"
        try store.correctTransactionMetadata(edit)
        let reopened = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let fresh = try FinanceStore(context: reopened.mainContext, now: fixtureInstant(EntryFixtures.today))
        #expect(!fresh.storeIsUnreadable)
        #expect(try fresh.exportDocument() == legacy)
        #expect(fresh.correctionHistory(forTransaction: "synthetic-legacy").count == 1)
        #expect(try fresh.correctionDraft(forTransaction: "synthetic-legacy").original.merchant == "SYNTHETIC MIGRATED")
    }
}
