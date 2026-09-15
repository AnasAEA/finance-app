import Foundation
import FinanceCore

/// Writes the stored document out as a backup file, and refuses to call it a
/// backup until it has read it back.
///
/// The import path has three gates before anything is written. This is the
/// mirror: three gates before anything is *offered*, and the same three, run
/// against the produced bytes rather than against a chosen file.
///
/// 1. **encode** — turn the document into the interchange format;
/// 2. **read back** — decode and schema-check the bytes that were produced,
///    through `DocumentImporter`, so the file is proved readable by the exact
///    code that would restore it;
/// 3. **re-encode** — encode what came back and require identical bytes.
///
/// Gate 3 is what makes this a backup rather than a file. A document that
/// decodes but does not re-encode to the same bytes has lost or reinterpreted
/// something on the way through, and the loss would only be discovered on the
/// day somebody needed the file. Comparing bytes rather than documents keeps
/// the check honest about ordering and representation, because both sides go
/// through the same deterministic encoder.
///
/// Nothing here writes to the store, and nothing here keeps a copy: the bytes
/// are handed to the caller and this type retains none of them.
enum DocumentExporter {

    /// A verified backup of `document`, dated `day`.
    ///
    /// Throws `AppExportError` — never a decoder's own description, which
    /// quotes the value it choked on and would put a person's money into an
    /// alert.
    static func backup(of document: FinanceDocument, on day: Day) throws -> FinanceBackup {
        // Gate 1. `Interchange.encode` picks the oldest wire format that
        // represents this data exactly and validates planning on the way out,
        // so an unrepresentable document fails here rather than silently
        // losing a field.
        let data: Data
        do {
            data = try Interchange.encode(document)
        } catch {
            throw AppExportError.documentUnencodable
        }

        // Gate 2. The same decode and schema check a restore would run. Its
        // errors are already sanitized, so they are the right sentence and are
        // carried through rather than reworded.
        let reread: FinanceDocument
        do {
            reread = try DocumentImporter.decode(data)
            try DocumentImporter.semanticValidate(reread)
        } catch let error as AppImportError {
            throw AppExportError.verificationFailed(error)
        } catch {
            throw AppExportError.verificationFailed(.fileUnreadable)
        }

        // Gate 3. A faithful file is a fixed point of this encoder.
        guard let again = try? Interchange.encode(reread), again == data else {
            throw AppExportError.incompleteBackup
        }

        return FinanceBackup(
            data: data,
            fileName: fileName(on: day),
            summary: summary(of: reread, byteCount: data.count)
        )
    }

    /// `Finance Backup 2026-09-15.json`. Dated, so two backups sort and read
    /// in the order they were taken.
    static func fileName(on day: Day) -> String {
        "Finance Backup \(day.isoString).json"
    }

    /// What the produced file holds, counted from the document that was read
    /// back out of it.
    private static func summary(of document: FinanceDocument, byteCount: Int) -> BackupSummary {
        BackupSummary(
            schemaVersion: document.schemaVersion,
            byteCount: byteCount,
            accountCount: document.accounts.count,
            transactionCount: document.transactions.count,
            expectedTransactionCount: document.expectedTransactions.count,
            incomeSourceCount: document.incomeSources.count,
            recurringCommitmentCount: document.planning.recurringObligations.count,
            budgetCount: document.planning.budgets.count,
            instalmentCount: document.installments.count,
            debtCount: document.debts.count,
            goalCount: document.planning.plannedPurchases.count,
            setAsideCount: document.planning.sinkingFunds.count,
            bankEvidenceCount: document.externalObservations.count
        )
    }
}
