import Foundation
import SwiftData
import FinanceCore

/// How a document reaches disk.
///
/// One closure with one implementation in production. It exists as a seam
/// because "the import is atomic" is otherwise an untestable claim: a real
/// `context.save()` cannot be made to fail on demand, so without a stand-in
/// there is no way to prove that a write failing *after* the old graph has
/// been torn down leaves the old graph intact. A test supplies a writer that
/// fails exactly there; production supplies `.live`.
@MainActor
struct DocumentWriter {
    let write: (
        _ document: FinanceDocument,
        _ context: ModelContext,
        _ writtenOn: Day,
        _ presentation: [String: DomainMapper.TransactionPresentation],
        _ appMetadata: AppPersistenceMetadata
    ) throws -> Void
    let writeImported: (
        _ document: FinanceDocument,
        _ context: ModelContext,
        _ writtenOn: Day,
        _ presentation: [String: DomainMapper.TransactionPresentation],
        _ appMetadata: AppPersistenceMetadata
    ) throws -> Void

    let writeRecovered: ((FinanceDocument, ModelContext, Day,
                          [String: DomainMapper.TransactionPresentation],
                          AppPersistenceMetadata, FullRecoveryState) throws -> Void)?

    /// Optional narrow append for the common manual-entry path. A test writer
    /// has only `write`, so injected write failures still exercise rollback.
    let appendUserTransaction: ((_ document: FinanceDocument,
                                 _ transaction: Transaction,
                                 _ context: ModelContext,
                                 _ writtenOn: Day,
                                 _ presentation: DomainMapper.TransactionPresentation,
                                 _ appMetadata: AppPersistenceMetadata) throws -> Void)?

    /// Small operational update when provider evidence content is unchanged.
    let updateBankMetadata: ((_ context: ModelContext,
                              _ appMetadata: AppPersistenceMetadata) throws -> Void)?
    let archivesPendingHistory: Bool
    let correctTransactionMetadata: ((TransactionMetadataCorrection, ModelContext, Day) throws -> Void)?

    init(_ write: @escaping (FinanceDocument, ModelContext, Day,
                             [String: DomainMapper.TransactionPresentation],
                             AppPersistenceMetadata) throws -> Void,
         recover: ((FinanceDocument, ModelContext, Day, [String: DomainMapper.TransactionPresentation],
                    AppPersistenceMetadata, FullRecoveryState) throws -> Void)? = nil,
         correctMetadata: ((TransactionMetadataCorrection, ModelContext, Day) throws -> Void)? = nil) {
        self.write = write
        self.writeImported = write
        self.writeRecovered = recover ?? { document, context, day, presentation, metadata, recovery in
            guard recovery.archives.isEmpty, recovery.historicalTransactions.isEmpty, recovery.historyGaps.isEmpty,
                  recovery.checkpointDatasets.isEmpty, recovery.checkpointRevisions.isEmpty,
                  recovery.checkpointAcknowledgments.isEmpty,
                  recovery.transactionCorrections?.isEmpty ?? true else { throw AppImportError.invalidBackupMetadata }
            try write(document, context, day, presentation, metadata)
        }
        self.appendUserTransaction = nil
        self.updateBankMetadata = nil
        self.archivesPendingHistory = false
        self.correctTransactionMetadata = correctMetadata
    }

    private init(
        write: @escaping (FinanceDocument, ModelContext, Day,
                          [String: DomainMapper.TransactionPresentation],
                          AppPersistenceMetadata) throws -> Void,
        writeImported: @escaping (FinanceDocument, ModelContext, Day,
                                  [String: DomainMapper.TransactionPresentation],
                                  AppPersistenceMetadata) throws -> Void,
        appendUserTransaction: @escaping (FinanceDocument, Transaction, ModelContext, Day,
                                          DomainMapper.TransactionPresentation,
                                          AppPersistenceMetadata) throws -> Void,
        updateBankMetadata: @escaping (ModelContext, AppPersistenceMetadata) throws -> Void,
        writeRecovered: @escaping (FinanceDocument, ModelContext, Day,
                                    [String: DomainMapper.TransactionPresentation],
                                    AppPersistenceMetadata, FullRecoveryState) throws -> Void,
        correctTransactionMetadata: @escaping (TransactionMetadataCorrection, ModelContext, Day) throws -> Void
    ) {
        self.write = write
        self.writeImported = writeImported
        self.writeRecovered = writeRecovered
        self.appendUserTransaction = appendUserTransaction
        self.updateBankMetadata = updateBankMetadata
        self.archivesPendingHistory = true
        self.correctTransactionMetadata = correctTransactionMetadata
    }

    static let live = DocumentWriter(
        write: { document, context, writtenOn, presentation, appMetadata in
            try StoredDocumentGraph.replace(
                with: document, in: context, writtenOn: writtenOn,
                presentation: presentation, appMetadata: appMetadata
            )
        },
        writeImported: { document, context, writtenOn, presentation, appMetadata in
            try StoredDocumentGraph.replace(
                with: document, in: context, writtenOn: writtenOn,
                presentation: presentation, appMetadata: appMetadata,
                replaceArchivedHistory: true
            )
        },
        appendUserTransaction: { document, transaction, context, writtenOn, presentation, appMetadata in
            try StoredDocumentGraph.appendUserTransaction(
                transaction, in: document, context: context, writtenOn: writtenOn,
                presentation: presentation, appMetadata: appMetadata
            )
        },
        updateBankMetadata: { context, appMetadata in
            try StoredDocumentGraph.updateBankMetadata(appMetadata, in: context)
        },
        writeRecovered: { document, context, writtenOn, presentation, appMetadata, recovery in
            try recovery.validate(document: document)
            try StoredTransactionCorrection.validate(recovery.transactionCorrections ?? [],
                document: document, presentation: presentation)
            guard try FullRecoveryState.destinationIsEmpty(context) else { throw AppImportError.storeNotEmpty }
            try StoredDocumentGraph.replace(with: document, in: context, writtenOn: writtenOn,
                presentation: presentation, appMetadata: appMetadata, replaceArchivedHistory: true,
                beforeSave: { recovery.insert(in: $0) })
        },
        correctTransactionMetadata: { correction, context, day in
            try StoredTransactionCorrection.append(correction, in: context, writtenOn: day)
        }
    )
}
