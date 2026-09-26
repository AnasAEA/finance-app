import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

@MainActor
@Suite("Full encrypted recovery")
struct FullRecoveryTests {
    private func empty(writer: DocumentWriter? = nil) throws -> (ModelContainer, FinanceStore) {
        let container = try ModelContainer(for: Schema(FinanceSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try FinanceStore(context: container.mainContext, now: fixtureInstant(EntryFixtures.today), writer: writer ?? .live)
        return (container, store)
    }
    private func source() throws -> EntryFixtures.Harness {
        let h = try EntryFixtures.Harness()
        try h.store.add(EntryFixtures.draft(merchant: "SYNTHETIC RECOVERY SHOP"))
        _ = try HistoryArchivePersistence.replace(with: HistoryArchiveFixture.document(), in: h.container.mainContext, importedAt: CheckpointFixtures.closedAt)
        let first = try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions)
        _ = try h.store.checkpoints.store(first)
        let second = try CheckpointFixtures.revision(revisionNumber: 2, predecessorID: first.id, exceptions: CheckpointFixtures.exceptions)
        _ = try h.store.checkpoints.store(second)
        return h
    }
    private func changing(_ backup: FinanceBackup, _ edit: (inout FullRecoveryState) -> Void) throws -> Data {
        let document = try DocumentImporter.decode(backup.data)
        var metadata = try AppBackupMetadata.read(from: backup.data, document: document)
        var recovery = try #require(metadata.fullRecovery)
        edit(&recovery)
        recovery.contentSHA256 = try recovery.integrityDigest()
        metadata.fullRecovery = recovery
        return try metadata.encoding(document)
    }
    private func assertEmpty(_ container: ModelContainer) throws {
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredAccount>()) == 0)
        #expect(try FullRecoveryState.destinationIsEmpty(container.mainContext))
    }

    @Test func encryptedRoundTripPreservesArchivesRevisionLineageAndLedger() async throws {
        let h = try source()
        let originalDocument = try h.store.exportDocument()
        let originalState = try FullRecoveryState.capture(from: h.container.mainContext)
        let backup = try h.store.exportBackup()
        #expect(backup.summary.hasFullRecovery)
        #expect(backup.summary.historicalTransactionCount == 4)
        #expect(backup.summary.checkpointRevisionCount == 2)
        let encrypted = try await backup.encrypted(password: "synthetic full recovery password")
        #expect(String(data: encrypted, encoding: .utf8)?.contains("SYNTHETIC RECOVERY SHOP") == false)
        let (container, restored) = try empty()
        let preview = try await restored.prepareEncryptedImport(from: encrypted, password: "synthetic full recovery password")
        #expect(preview.historicalTransactionCount == 4 && preview.checkpointRevisionCount == 2)
        let summary = try restored.confirmImport()
        #expect(summary.hasFullRecovery && summary.checkpointRevisionCount == 2)
        #expect(try restored.exportDocument() == originalDocument)
        #expect(try FullRecoveryState.capture(from: container.mainContext) == originalState)
        #expect(try restored.exportBackup().data == backup.data)
        let reopened = try FinanceStore(context: ModelContext(container), now: fixtureInstant(EntryFixtures.today))
        #expect(try reopened.history.page(limit: 10).transactions.count == 4)
        #expect(reopened.checkpoints.occupancy() == .holdsCheckpointHistory)
        #expect(reopened.pairingState != .paired)
        #expect(!reopened.trustedAutomationEnabled)
        #expect(try reopened.exportBackup().data == backup.data)
    }

    @Test func malformedHistoryRefusesBeforeAnyDestinationWrite() throws {
        let backup = try source().store.exportBackup()
        let corruptions: [(inout FullRecoveryState) -> Void] = [
            { $0.archives[0].recordCount += 1 },
            { $0.historicalTransactions[0].archiveIdentifier = "synthetic-orphan" },
            { $0.historicalTransactions[0].currencyExponent = -1 },
            { $0.historicalTransactions[0].amountMinor = .min },
            { $0.historicalTransactions[0].valueDay = .max },
            { $0.historicalTransactions.append($0.historicalTransactions[0]) },
            { $0.historyGaps[0].startDay = $0.historyGaps[0].endDay + 1 },
            { $0.historicalTransactions[0].normalizedSearchText = "SYNTHETIC BAD INDEX" }
        ]
        for edit in corruptions {
            let (container, restored) = try empty()
            #expect(throws: AppImportError.invalidBackupMetadata) { _ = try restored.prepareImport(from: changing(backup, edit)) }
            try assertEmpty(container)
        }
    }

    @Test func checkpointTamperingAndBrokenLineageRefuseAtomically() throws {
        let backup = try source().store.exportBackup()
        let corruptions: [(inout FullRecoveryState) -> Void] = [
            { $0.checkpointRevisions[0].projectionDigest = Data(repeating: 0, count: 32) },
            { $0.checkpointRevisions[0].canonicalProjection.append(0) },
            { $0.checkpointRevisions[0].datasetIdentifier = UUID().uuidString },
            { $0.checkpointRevisions.removeAll { $0.revisionNumber == 1 } },
            { $0.checkpointAcknowledgments[0].amountMinor = 999 },
            { $0.checkpointAcknowledgments.removeFirst() },
            { $0.checkpointRevisions.append($0.checkpointRevisions[0]) }
        ]
        for edit in corruptions {
            let (container, restored) = try empty()
            #expect(throws: AppImportError.invalidBackupMetadata) { _ = try restored.prepareImport(from: changing(backup, edit)) }
            try assertEmpty(container)
        }
    }

    @Test func failedSaveRollsBackLedgerArchiveAndCheckpointsTogether() throws {
        enum Failure: Error { case injected }
        let writer = DocumentWriter({ _,_,_,_,_ in throw Failure.injected }, recover: { document, context, day, presentation, metadata, recovery in
            try StoredDocumentGraph.replace(with: document, in: context, writtenOn: day, presentation: presentation, appMetadata: metadata,
                beforeSave: { context in
                    recovery.insert(in: context)
                    #expect(try context.fetchCount(FetchDescriptor<StoredHistoricalTransaction>()) == 4)
                    #expect(try context.fetchCount(FetchDescriptor<StoredPeriodCheckpointRevision>()) == 2)
                    throw Failure.injected
                })
        })
        let backup = try source().store.exportBackup()
        let (container, restored) = try empty(writer: writer)
        _ = try restored.prepareImport(from: backup.data)
        #expect(throws: (any Error).self) { _ = try restored.confirmImport() }
        try assertEmpty(container)
        #expect(restored.isEmpty)
        let fresh = ModelContext(container)
        #expect(try fresh.fetchCount(FetchDescriptor<StoredHistoricalTransaction>()) == 0)
        #expect(PeriodCheckpointRepository(context: fresh).occupancy() == .empty)
    }

    @Test func fullRestoreRefusesExistingArchiveAndRechecksAtConfirmation() throws {
        let backup = try source().store.exportBackup()
        let (container, restored) = try empty()
        _ = try restored.prepareImport(from: backup.data)
        _ = try HistoryArchivePersistence.replace(with: HistoryArchiveFixture.document(), in: container.mainContext, importedAt: CheckpointFixtures.closedAt)
        #expect(throws: AppImportError.storeNotEmpty) { _ = try restored.confirmImport() }
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredAccount>()) == 0)
        #expect(try restored.history.page(limit: 10).transactions.count == 4)
        #expect(throws: AppImportError.storeNotEmpty) { _ = try restored.prepareImport(from: backup.data) }
    }

    @Test func legacyBackupsKeepTheirDocumentOnlyScope() throws {
        let metadata = AppBackupMetadata(transactionPresentation: [:], incomeSourceActive: [:])
        let data = try metadata.encoding(EntryFixtures.document())
        let (container, restored) = try empty()
        #expect(try restored.prepareImport(from: data).hasFullRecovery == false)
        #expect(try restored.confirmImport().hasFullRecovery == false)
        #expect(try FullRecoveryState.destinationIsEmpty(container.mainContext))
    }

    @Test func unknownRecoveryVersionAndOrphanArchiveRefuse() throws {
        let backup = try source().store.exportBackup()
        for edit: (inout FullRecoveryState) -> Void in [{ $0.version = 99 }, { $0.archives = [] }] {
            let (container, restored) = try empty()
            #expect(throws: AppImportError.invalidBackupMetadata) { _ = try restored.prepareImport(from: changing(backup, edit)) }
            try assertEmpty(container)
        }
    }
    @Test func pendingAuthorityAndCoverageSurviveWithoutTransportCredentials() throws {
        var document = EntryFixtures.document()
        let day = EntryFixtures.today
        let now = fixtureInstant(day)
        let binding = ExternalAccountBinding(id: "recovery-binding", provider: .bnp, remoteOpaqueAccountID: "recovery-remote", localAccountID: EntryFixtures.bank.id, syncStartBoundary: day, createdAt: now)
        document.externalAccountBindings = [binding]
        let observations = ["pending-a", "pending-b"].map { id in
            ExternalObservation(id: id, bindingID: binding.id, provider: .bnp, status: .pending,
                creditDebitIndicator: .debit, amount: Money(minorUnits: -100, currency: .eur),
                bookingDate: day, eligibleForEconomicActual: false, observedAt: now)
        }
        try ExternalEvidenceReview.importBatch(.init(observations: observations), into: &document)
        let metadata = AppPersistenceMetadata(
            trustedAutomationEnabled: true,
            authoritativePendingSnapshots: [.bnp: .init(authoritativeAt: now, observationIDs: Set(observations.map(\.id)))],
            authoritativeLiveCoverage: [binding.remoteOpaqueAccountID: .init(provider: .bnp, remoteOpaqueAccountID: binding.remoteOpaqueAccountID,
                localAccountID: binding.localAccountID, syncedFrom: day, syncedThrough: day, authoritativeAt: now)],
            currentHoldingsModelVersion: CurrentHoldings.modelVersion,
            bankEvidenceCursor: "SYNTHETIC PRIVATE TRANSPORT CURSOR", bankEvidenceCursorDeviceID: "SYNTHETIC DEVICE ID"
        )
        let (container, _) = try empty()
        try StoredDocumentGraph.replace(with: document, in: container.mainContext, writtenOn: day, appMetadata: metadata)
        let source = try FinanceStore(context: container.mainContext, now: now)
        let backup = try source.exportBackup()
        #expect(String(data: backup.data, encoding: .utf8)?.contains("SYNTHETIC PRIVATE TRANSPORT CURSOR") == false)
        #expect(String(data: backup.data, encoding: .utf8)?.contains("SYNTHETIC DEVICE ID") == false)
        let (destination, restored) = try empty()
        _ = try restored.prepareImport(from: backup.data)
        _ = try restored.confirmImport()
        let read = try StoredDocumentGraph.loadAppMetadata(from: destination.mainContext)
        #expect(read.authoritativePendingSnapshots == metadata.authoritativePendingSnapshots)
        #expect(read.authoritativeLiveCoverage == metadata.authoritativeLiveCoverage)
        #expect(read.bankEvidenceCursor == nil && read.bankEvidenceCursorDeviceID == nil)
        #expect(!read.trustedAutomationEnabled)
        #expect(try restored.exportBackup().data == backup.data)
    }

    @Test func damagedSourceHistoryCannotProduceAValidLookingBackup() throws {
        let h = try source()
        let row = try #require(try h.container.mainContext.fetch(FetchDescriptor<StoredPeriodCheckpointRevision>()).first)
        row.projectionDigest = Data(repeating: 0, count: 32)
        try h.container.mainContext.save()
        #expect(throws: AppExportError.storeUnreadable) { _ = try h.store.exportBackup() }
    }

    private func restoreOnDisk(_ data: Data, at url: URL) throws {
        let c = try ModelContainer(for: Schema(FinanceSchema.models), configurations: ModelConfiguration(url: url))
        let store = try FinanceStore(context: c.mainContext, now: fixtureInstant(EntryFixtures.today))
        _ = try store.prepareImport(from: data)
        _ = try store.confirmImport()
    }

    @Test func recoverySurvivesClosingAndReopeningASQLiteContainer() throws {
        let h = try source()
        let backup = try h.store.exportBackup()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.store")
        try restoreOnDisk(backup.data, at: url)
        let reopened = try ModelContainer(for: Schema(FinanceSchema.models), configurations: ModelConfiguration(url: url))
        let store = try FinanceStore(context: reopened.mainContext, now: fixtureInstant(EntryFixtures.today))
        #expect(try store.exportBackup().data == backup.data)
        #expect(try store.history.page(limit: 10).transactions.count == 4)
        #expect(store.checkpoints.occupancy() == .holdsCheckpointHistory)
    }

    @Test func failedNewPasswordDoesNotLeaveAnOlderDocumentStaged() async throws {
        let h = try source()
        let backup = try h.store.exportBackup()
        let encrypted = try await backup.encrypted(password: "synthetic recovery password")
        let (container, store) = try empty()
        _ = try store.prepareImport(from: backup.data)
        await #expect(throws: AppImportError.backupPasswordInvalid) {
            _ = try await store.prepareEncryptedImport(from: encrypted, password: "wrong password")
        }
        #expect(throws: AppImportError.noDocumentStaged) { _ = try store.confirmImport() }
        try assertEmpty(container)
    }

    @Test func expectedTransactionLabelsComeFromDiskAndSurviveRecovery() throws {
        let h = try EntryFixtures.Harness(CurrentStateExport.document())
        let row = try #require(try h.container.mainContext.fetch(FetchDescriptor<StoredTransaction>()).first { $0.factivityRaw == "expected" })
        row.appCategoryKey = "food"
        row.appMerchant = "SYNTHETIC EXPECTED LABEL"
        try h.container.mainContext.save()
        let backup = try h.store.exportBackup()
        let (container, store) = try empty()
        _ = try store.prepareImport(from: backup.data)
        _ = try store.confirmImport()
        let expected = try #require(try container.mainContext.fetch(FetchDescriptor<StoredTransaction>()).first { $0.identifier == row.identifier })
        #expect(expected.appCategoryKey == row.appCategoryKey)
        #expect(expected.appMerchant == row.appMerchant)
        #expect(try store.exportBackup().data == backup.data)
    }

    @Test func accountlessPlanningIsNotAnEmptyRecoveryDestination() throws {
        let (container, _) = try empty()
        let document = FinanceDocument(schemaVersion: Interchange.currentSchemaVersion, documentKind: "SYNTHETIC ACCOUNTLESS PLAN",
            accounts: [], balances: [], planning: .init(safetyFloor: Money(minorUnits: 0, currency: .eur)))
        try StoredDocumentGraph.replace(with: document, in: container.mainContext, writtenOn: EntryFixtures.today)
        let store = try FinanceStore(context: container.mainContext, now: fixtureInstant(EntryFixtures.today))
        #expect(store.importBlocker == .storeNotEmpty)
    }

    @Test func modifiedArchiveCannotKeepTheOriginalRecoveryDigest() throws {
        let h = try source()
        let backup = try h.store.exportBackup()
        let document = try DocumentImporter.decode(backup.data)
        var metadata = try AppBackupMetadata.read(from: backup.data, document: document)
        metadata.fullRecovery?.historicalTransactions[0].amountMinor -= 1
        metadata.fullRecovery?.historicalTransactions[0].absoluteAmountMinor += 1
        let data = try metadata.encoding(document)
        let (container, store) = try empty()
        #expect(throws: AppImportError.invalidBackupMetadata) { _ = try store.prepareImport(from: data) }
        try assertEmpty(container)
    }

}
