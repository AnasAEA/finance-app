import Foundation

/// Why a backup could not be written.
///
/// These messages follow the same rule the import path follows: a refusal
/// names what is wrong, never what was in the document. A backup file holds
/// the whole of a person's finances, so a diagnostic that quotes a value out
/// of it is a leak in the one direction the app is most trusted not to leak.
///
/// `verificationFailed` carries an `AppImportError` deliberately. The bytes
/// are read back through the import path, so what that path says about them is
/// already sanitized and already the right sentence.
enum AppExportError: Error, Hashable, Sendable {

    /// A store with nothing persistent behind it was asked to export: the
    /// fixed facade, or an in-memory preview. A backup is a copy of what is on
    /// this device, and there is nothing on this device to copy.
    case storeIsReadOnly

    /// The stored graph could not be read at launch, so the store is serving
    /// an empty plan. Writing *that* out would produce a valid-looking backup
    /// of nothing, which is worse than no backup at all: restoring it later
    /// would look like it worked.
    case storeUnreadable

    /// There is no account on this device. A restore needs at least one, so
    /// nothing here could produce a file that restores.
    case nothingToExport

    /// The current civil day could not be read, so the file cannot be dated.
    /// An undated backup is one a person cannot order against another.
    case currentDayUnavailable

    /// The document could not be encoded at all.
    case documentUnencodable

    /// The bytes were written and then could not be read back by this app's
    /// own import path. They are not offered as a backup.
    case verificationFailed(AppImportError)

    /// The bytes read back, but re-encoding them did not reproduce the file.
    /// Something in the document does not survive the round trip, so the file
    /// is not a faithful copy of what is on this device.
    case incompleteBackup

    /// One sentence, addressed to the person who just asked for a backup.
    var message: String {
        switch self {
        case .storeIsReadOnly:
            "This is a preview. There is nothing stored here to back up."
        case .storeUnreadable:
            "Your data could not be opened, so a backup of it would be empty. Nothing was written."
        case .nothingToExport:
            "A backup needs at least one account, and there are none yet."
        case .currentDayUnavailable:
            "Today’s date could not be read, so the backup could not be dated."
        case .documentUnencodable:
            "Your data could not be written to a file."
        case let .verificationFailed(reason):
            "The backup was checked and this app could not read it back: \(reason.message)"
        case .incompleteBackup:
            "The backup did not come back identical to what is on this device, so it was not offered."
        }
    }

    /// The line under the message, when there is more worth saying.
    var recoverySuggestion: String? {
        switch self {
        case .storeUnreadable:
            "The data on this device may still be intact. Do not reinstall the app before it can be read again."
        case .nothingToExport:
            "A backup restores accounts and the plan built around them. Add one, or import your current state, and there will be something to save."
        case .verificationFailed, .incompleteBackup:
            "Nothing on this device was changed and no file was written."
        default:
            nil
        }
    }
}

/// What a produced backup file contains, counted from the bytes themselves.
///
/// Every figure here is read back out of the encoded file, not copied from the
/// live store. A summary assembled from the input would describe a file that
/// was never written — the same reason `ImportSummary` is built by re-reading
/// the persisted store rather than echoing the preview.
struct BackupSummary: Hashable, Sendable {

    /// The interchange schema the file was written to. The encoder picks the
    /// oldest version that represents this data exactly, so this is not always
    /// the newest one this build knows.
    let schemaVersion: String
    let byteCount: Int

    let accountCount: Int
    let transactionCount: Int
    let expectedTransactionCount: Int
    let incomeSourceCount: Int
    let recurringCommitmentCount: Int
    let budgetCount: Int
    let instalmentCount: Int
    let debtCount: Int
    let goalCount: Int
    let setAsideCount: Int
    /// Provider observations kept as evidence. Not transactions: evidence is
    /// what the bank said, and it is in the file because losing it would lose
    /// the decisions already made about it.
    let bankEvidenceCount: Int

    /// What a backup deliberately does not carry.
    ///
    /// The historical archive, the local checkpoint history and the device's
    /// bank pairing live outside `FinanceDocument` on purpose, and a backup
    /// that implied otherwise would be the most expensive kind of wrong.
    static let exclusions = [
        "The historical archive, which is imported separately.",
        "Verified-month history, which belongs to this device.",
        "Bank pairing, which is a key this device never exports."
    ]

    var fileSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}

/// A verified backup: the bytes, what they are called, and what is in them.
struct FinanceBackup: Hashable, Sendable {
    let data: Data
    let fileName: String
    let summary: BackupSummary
}
