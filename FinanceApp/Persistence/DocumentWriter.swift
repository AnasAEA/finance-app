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

    static let live = DocumentWriter { document, context, writtenOn, presentation, appMetadata in
        try StoredDocumentGraph.replace(
            with: document,
            in: context,
            writtenOn: writtenOn,
            presentation: presentation,
            appMetadata: appMetadata
        )
    }
}
