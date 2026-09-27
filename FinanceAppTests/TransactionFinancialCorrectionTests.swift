import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

@MainActor
@Suite("Previewed financial corrections")
struct TransactionFinancialCorrectionTests {
    private func harness(kind: TransactionDraft.Kind = .expense, currency: Currency = .eur) throws -> EntryFixtures.Harness {
        var document = EntryFixtures.document()
        document.balances = document.balances.map {
            .init(accountID: $0.accountID, balance: $0.balance, asOf: EntryFixtures.today.monthKey.firstDay)
        }
        let h = try EntryFixtures.Harness(document)
        try h.store.add(EntryFixtures.draft(kind: kind,
            amount: Amount(minorUnits: 1234, currencyCode: currency.code, fractionDigits: currency.minorUnitDigits),
            accountID: currency == .kwd ? EntryFixtures.walletKWD.id : EntryFixtures.bank.id,
            incomeSourceID: kind == .income ? EntryFixtures.parents.id : nil, merchant: "SYNTHETIC ORIGINAL"))
        return h
    }

    private func edit(_ store: FinanceStore) throws -> TransactionFinancialDraft {
        let id = try #require(try store.exportDocument().transactions.first?.id)
        var draft = try store.financialCorrectionDraft(forTransaction: id)
        draft.corrected.amount = .init(minorUnits: 2000, currencyCode: draft.original.amount.currencyCode,
                                      fractionDigits: draft.original.amount.fractionDigits)
        draft.reason = "SYNTHETIC statement correction"
        return draft
    }

    @Test func previewIsReadOnlyAndConfirmationPreservesEventLegMetadataAndAnchors() throws {
        let h = try harness()
        let before = try h.store.exportDocument()
        let backup = try h.store.exportBackup().data
        let row = try #require(try h.container.mainContext.fetch(FetchDescriptor<StoredTransaction>()).first)
        let rowID = row.persistentModelID
        let legID = row.legs[0].persistentModelID
        var draft = try edit(h.store)
        draft.corrected.accountID = EntryFixtures.wallet.id
        let preview = try h.store.previewFinancialCorrection(draft)
        #expect(try h.store.exportBackup().data == backup)
        #expect(!h.container.mainContext.hasChanges && h.store.financialCorrectionHistory(forTransaction: draft.transactionID).isEmpty)
        let bank = try #require(preview.accountImpacts.first { $0.id == EntryFixtures.bank.id })
        let wallet = try #require(preview.accountImpacts.first { $0.id == EntryFixtures.wallet.id })
        #expect(bank.before == .eur(487.66) && bank.after == .eur(500))
        #expect(wallet.before == .eur(500) && wallet.after == .eur(480))
        try h.store.confirmFinancialCorrection(preview)
        let after = try h.store.exportDocument()
        #expect(after.transactions.count == 1 && after.transactions[0].id == before.transactions[0].id)
        #expect(after.transactions[0].provenance == before.transactions[0].provenance)
        #expect(after.transactions[0].note == before.transactions[0].note && after.transactions[0].lifecycle == before.transactions[0].lifecycle)
        #expect(after.balances == before.balances && after.providerBalanceSnapshots == before.providerBalanceSnapshots)
        #expect(row.persistentModelID == rowID && row.legs[0].persistentModelID == legID)
        #expect(row.appMerchant == "SYNTHETIC ORIGINAL" && row.appCategoryKey == "food")
        let history = h.store.financialCorrectionHistory(forTransaction: draft.transactionID)
        #expect(history.count == 1 && history[0].before == draft.original && history[0].after == draft.corrected)
        #expect(history[0].reason == draft.reason && history[0].beforeAccountName == EntryFixtures.bank.name)
        #expect(h.store.removalBlocker(forTransaction: draft.transactionID) == .hasCorrectionHistory)
        let reopened = try FinanceStore(context: ModelContext(h.container), now: fixtureInstant(EntryFixtures.today))
        #expect(reopened.financialCorrectionHistory(forTransaction: draft.transactionID) == history)
        #expect(try reopened.exportDocument() == after)
    }

    @Test func dateCorrectionCrossesMonthAndInclusiveAnchorWithoutRewritingBalance() throws {
        let h = try harness()
        var draft = try edit(h.store)
        draft.corrected.amount = draft.original.amount
        draft.corrected.day = .init(year: 2026, month: 8, day: 31)
        let anchor = try h.store.exportDocument().balances
        let preview = try h.store.previewFinancialCorrection(draft)
        #expect(preview.affectedMonths == ["2026-08", "2026-09"])
        #expect(preview.accountImpacts.first?.before == .eur(487.66) && preview.accountImpacts.first?.after == .eur(500))
        try h.store.confirmFinancialCorrection(preview)
        #expect(try h.store.exportDocument().balances == anchor)
        #expect(try h.store.exportDocument().transactions[0].date == Day(year: 2026, month: 8, day: 31))
        #expect(h.store.snapshot.everydayBudget.spent == .zeroEUR)
    }

    @Test func amountCorrectionRecomputesBudgetAndIncomeKeepsItsSource() throws {
        let expense = try harness()
        try expense.store.saveBudgetLine(.init(name: "Synthetic groceries", monthlyTarget: .eur(100), categoryKeys: ["food"]))
        try expense.store.confirmFinancialCorrection(expense.store.previewFinancialCorrection(edit(expense.store)))
        #expect(expense.store.snapshot.budget.lines.first { $0.name == "Synthetic groceries" }?.spent == .eur(20))
        let income = try harness(kind: .income)
        let original = try income.store.exportDocument().transactions[0]
        let draft = try edit(income.store)
        try income.store.confirmFinancialCorrection(income.store.previewFinancialCorrection(draft))
        let corrected = try income.store.exportDocument().transactions[0]
        #expect(corrected.kind == .income && corrected.incomeSourceID == original.incomeSourceID)
        #expect(corrected.legs[0].amount.minorUnits == 2000 && corrected.certainty == original.certainty)
    }

    @Test func metadataAndFinancialCorrectionsHaveIndependentDurableChains() throws {
        let h = try harness()
        var financial = try edit(h.store)
        let stalePreview = try h.store.previewFinancialCorrection(financial)
        var metadata = try h.store.correctionDraft(forTransaction: financial.transactionID)
        metadata.corrected.categoryKey = "transport"
        try h.store.correctTransactionMetadata(metadata)
        #expect(throws: AppFinancialCorrectionError.staleDraft) { try h.store.confirmFinancialCorrection(stalePreview) }
        financial = try edit(h.store)
        try h.store.confirmFinancialCorrection(h.store.previewFinancialCorrection(financial))
        #expect(h.store.correctionHistory(forTransaction: financial.transactionID).count == 1)
        #expect(h.store.financialCorrectionHistory(forTransaction: financial.transactionID).count == 1)
        metadata = try h.store.correctionDraft(forTransaction: financial.transactionID)
        metadata.corrected.merchant = "SYNTHETIC SECOND LABEL"
        try h.store.correctTransactionMetadata(metadata)
        try h.store.saveBudgetLine(.init(name: "Synthetic transport", monthlyTarget: .eur(100), categoryKeys: ["transport"]))
        #expect(h.store.snapshot.budget.lines.first { $0.name == "Synthetic transport" }?.spent == .eur(20))
        #expect(h.store.financialCorrectionHistory(forTransaction: financial.transactionID).count == 1)
        let reopened = try FinanceStore(context: ModelContext(h.container), now: fixtureInstant(EntryFixtures.today))
        #expect(!reopened.storeIsUnreadable)
        #expect(reopened.correctionHistory(forTransaction: financial.transactionID).count == 2)
    }

    @Test func staleContextReopensWithCurrentHistoryAndCannotReplayPreview() throws {
        let h = try harness()
        let other = try FinanceStore(context: ModelContext(h.container), now: fixtureInstant(EntryFixtures.today))
        let stale = try other.previewFinancialCorrection(edit(other))
        let accepted = try h.store.previewFinancialCorrection(edit(h.store))
        try h.store.confirmFinancialCorrection(accepted)
        let backup = try h.store.exportBackup().data
        #expect(throws: AppFinancialCorrectionError.staleDraft) { try other.confirmFinancialCorrection(stale) }
        #expect(other.financialCorrectionHistory(forTransaction: accepted.draft.transactionID).count == 1)
        #expect(try other.financialCorrectionDraft(forTransaction: accepted.draft.transactionID).original.amount == .eur(20))
        #expect(throws: AppFinancialCorrectionError.staleDraft) { try h.store.confirmFinancialCorrection(accepted) }
        #expect(try h.store.exportBackup().data == backup)
    }

    @Test func invalidDraftsAndForgedPreviewCannotWrite() throws {
        let h = try harness()
        let valid = try edit(h.store)
        let backup = try h.store.exportBackup().data
        let changes: [(inout TransactionFinancialDraft) -> Void] = [
            { $0.corrected.amount = .zeroEUR },
            { $0.corrected.amount = .init(minorUnits: Int64.max, currencyCode: "EUR") },
            { $0.corrected.amount = .init(minorUnits: 1234, currencyCode: "EUR", fractionDigits: 3) },
            { $0.corrected.accountID = "synthetic-missing" },
            { $0.corrected.accountID = EntryFixtures.cashMAD.id },
            { $0.corrected.day = .init(year: 2026, month: 2, day: 30) },
            { $0.corrected.day = .init(year: 2026, month: 9, day: 17) },
            { $0.reason = "   " },
            { $0.reason = String(repeating: "X", count: 501) },
            { $0.corrected = $0.original }
        ]
        for change in changes {
            var draft = valid
            change(&draft)
            #expect(throws: AppFinancialCorrectionError.self) { try h.store.previewFinancialCorrection(draft) }
        }
        let forged = TransactionFinancialPreview(draft: valid, asOf: DomainMapper.civilDay(EntryFixtures.today),
            accountImpacts: [], affectedMonths: [])
        #expect(throws: AppFinancialCorrectionError.staleDraft) { try h.store.confirmFinancialCorrection(forged) }
        #expect(try h.store.exportBackup().data == backup && !h.container.mainContext.hasChanges)
    }

    @Test func correctionLeavesHeadroomForForecastArithmetic() throws {
        let h = try harness()
        try h.store.saveBudgetLine(.init(name: "Synthetic groceries", monthlyTarget: .eur(100), categoryKeys: ["food"]))
        var draft = try edit(h.store)
        draft.corrected.amount = .init(minorUnits: Int64.max - 150000, currencyCode: "EUR")
        let backup = try h.store.exportBackup().data
        #expect(throws: AppFinancialCorrectionError.invalidAmount) { try h.store.previewFinancialCorrection(draft) }
        #expect(try h.store.exportBackup().data == backup)
    }

    @Test func threeDecimalCurrencyIsPreservedWithoutRounding() throws {
        let h = try harness(currency: .kwd)
        var draft = try edit(h.store)
        draft.corrected.amount = try Amount.parse("2.345", currencyCode: "KWD", fractionDigits: 3)
        try h.store.confirmFinancialCorrection(h.store.previewFinancialCorrection(draft))
        #expect(try h.store.exportDocument().transactions[0].legs[0].amount == Money(minorUnits: -2345, currency: .kwd))
        #expect(throws: Amount.ParseFailure.self) { try Amount.parse("2.3456", currencyCode: "KWD", fractionDigits: 3) }
    }

    @Test func failureAfterStagingRollsBackLegDateAuditAndRevision() throws {
        enum Failure: Error { case synthetic }
        let h = try harness()
        let backup = try h.store.exportBackup().data
        let writer = DocumentWriter({ _, _, _, _, _ in throw Failure.synthetic }, correctFinancials: { correction, context, _, _ in
            let row = try #require(try context.fetch(FetchDescriptor<StoredTransaction>()).first)
            row.valueDay = try PersistenceCoding.ordinal(correction.after.date)
            row.legs[0].amountMinor = correction.after.legs[0].amount.minorUnits
            context.insert(try StoredTransactionFinancialCorrection(correction))
            let root = try #require(try context.fetch(FetchDescriptor<StoredDocumentMeta>()).first)
            root.documentRevision = "SYNTHETIC STAGED"
            throw Failure.synthetic
        })
        let store = try FinanceStore(context: h.container.mainContext, now: fixtureInstant(EntryFixtures.today), writer: writer)
        let preview = try store.previewFinancialCorrection(edit(store))
        #expect(throws: AppFinancialCorrectionError.saveFailed) { try store.confirmFinancialCorrection(preview) }
        #expect(try store.exportBackup().data == backup && !h.container.mainContext.hasChanges)
        #expect(store.financialCorrectionHistory(forTransaction: preview.draft.transactionID).isEmpty)
        #expect(try h.container.mainContext.fetchCount(FetchDescriptor<StoredTransactionFinancialCorrection>()) == 0)
    }

    @Test func dirtyContextRefusalPreservesOtherStagedWork() throws {
        let h = try harness()
        let preview = try h.store.previewFinancialCorrection(edit(h.store))
        let account = try #require(try h.container.mainContext.fetch(FetchDescriptor<StoredAccount>()).first)
        account.name = "SYNTHETIC STAGED"
        #expect(throws: AppFinancialCorrectionError.saveFailed) { try h.store.confirmFinancialCorrection(preview) }
        #expect(account.name == "SYNTHETIC STAGED" && h.container.mainContext.hasChanges)
        #expect(try h.container.mainContext.fetchCount(FetchDescriptor<StoredTransactionFinancialCorrection>()) == 0)
        h.container.mainContext.rollback()
    }

    @Test func unsupportedTransactionsAndRelationshipsAreNamedRefusals() throws {
        let h = try harness()
        let transaction = try h.store.exportDocument().transactions[0]
        var document = try h.store.exportDocument()
        document.externalEvidenceLinks = [.init(id: "synthetic-link", observationID: "synthetic-observation", transactionID: transaction.id, role: .accountMovement)]
        #expect(FinanceStore.financialCorrectionBlocker(transaction.id, in: document) == .bankEvidence)
        document.externalEvidenceLinks = []
        document.transactions.append(.init(id: "synthetic-refund", date: transaction.date, kind: .refund,
            legs: [.init(accountID: EntryFixtures.bank.id, amount: Money(minorUnits: 100, currency: .eur))],
            linkedTransactionID: transaction.id, factivity: .observed))
        #expect(FinanceStore.financialCorrectionBlocker(transaction.id, in: document) == .linkedRecord)
        document.transactions.removeLast()
        document.expectedTransactions = [.init(id: "synthetic-expected", date: transaction.date, kind: .refund,
            legs: [.init(accountID: EntryFixtures.bank.id, amount: Money(minorUnits: 100, currency: .eur))],
            linkedTransactionID: transaction.id, factivity: .expected)]
        #expect(FinanceStore.financialCorrectionBlocker(transaction.id, in: document) == .linkedRecord)
        let transfer = try EntryFixtures.Harness()
        try transfer.store.add(EntryFixtures.draft(kind: .transfer, counterAccountID: EntryFixtures.wallet.id))
        #expect(throws: AppFinancialCorrectionError.unsupported) { try edit(transfer.store) }
        let shared = try EntryFixtures.Harness()
        try shared.store.add(EntryFixtures.draft(kind: .income, incomeSourceID: EntryFixtures.parents.id, ownShare: .eur(5)))
        #expect(throws: AppFinancialCorrectionError.unsupported) { try edit(shared.store) }
        let source = Transaction(id: "synthetic-imported", date: transaction.date, kind: .expense, legs: transaction.legs,
            factivity: .observed, provenance: .init(source: "SYNTHETIC BANK", evidenceGrade: .primarySource))
        document.transactions = [source]
        #expect(FinanceStore.financialCorrectionBlocker(source.id, in: document) == .sourceEvidence)
        #expect(FinanceStore.preview().financialCorrectionBlocker(forTransaction: transaction.id) == .readOnly)
    }

    @Test func recoveryRoundTripPreservesBothChainsAndOlderEnvelopesRefuseFinancialHistory() throws {
        let h = try harness()
        let financial = try edit(h.store)
        try h.store.confirmFinancialCorrection(h.store.previewFinancialCorrection(financial))
        var metadata = try h.store.correctionDraft(forTransaction: financial.transactionID)
        metadata.corrected.merchant = "SYNTHETIC CORRECTED"
        try h.store.correctTransactionMetadata(metadata)
        let backup = try h.store.exportBackup()
        #expect(backup.summary.transactionCorrectionCount == 2)
        let document = try DocumentImporter.decode(backup.data)
        var envelope = try AppBackupMetadata.read(from: backup.data, document: document)
        #expect(envelope.version == 4)
        let container = try ModelContainer(for: Schema(FinanceSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let restored = try FinanceStore(context: container.mainContext, now: fixtureInstant(EntryFixtures.today))
        #expect(try restored.prepareImport(from: backup.data).transactionCorrectionCount == 2)
        #expect(try restored.confirmImport().transactionCorrectionCount == 2)
        #expect(try restored.exportBackup().data == backup.data)
        #expect(restored.financialCorrectionHistory(forTransaction: financial.transactionID) == h.store.financialCorrectionHistory(forTransaction: financial.transactionID))
        for version in [1, 2, 3] {
            envelope.version = version
            #expect(throws: AppImportError.invalidBackupMetadata) { try AppBackupMetadata.read(from: envelope.encoding(document), document: document) }
        }
    }

    @Test func ordinaryWritesCannotEraseOrRewriteFinancialHistory() throws {
        let h = try harness()
        let preview = try h.store.previewFinancialCorrection(edit(h.store))
        try h.store.confirmFinancialCorrection(preview)
        var document = try h.store.exportDocument()
        document.transactions = []
        #expect(throws: AppImportError.self) { try StoredDocumentGraph.replace(with: document, in: h.container.mainContext, writtenOn: EntryFixtures.today) }
        #expect(try h.container.mainContext.fetchCount(FetchDescriptor<StoredTransactionFinancialCorrection>()) == 1)
        let row = try #require(try h.container.mainContext.fetch(FetchDescriptor<StoredTransactionFinancialCorrection>()).first)
        row.revision = 7
        try h.container.mainContext.save()
        let reopened = try FinanceStore(context: ModelContext(h.container), now: fixtureInstant(EntryFixtures.today))
        #expect(reopened.storeIsUnreadable)
        #expect(reopened.financialCorrectionBlocker(forTransaction: preview.draft.transactionID) == .unreadable)
    }
}
