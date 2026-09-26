import Foundation

/// Why a backup or finance export could not be restored.
///
/// **These messages are the only thing the import path is allowed to say about
/// the file.** The document holds a person's balances, salary, arrears and
/// counterparties, and a decoder's `debugDescription` quotes the value it
/// choked on — `"Invalid money string '960.00 EUR'"`. So nothing here carries a
/// value read out of the file: a rejection names the *field* that is wrong and
/// what is wrong with it, never what was in it. Field paths are structural
/// (`balances[2].asOf`) and safe to print, show and attach to a bug report.
enum AppImportError: Error, Hashable, Sendable {

    /// A fixed preview/test store was asked to import.
    case storeIsReadOnly

    /// Phase 2.2 restores into an empty store only. Merging an export into a
    /// history that already exists needs reconciliation that does not exist
    /// yet, and the failure mode of guessing is duplicated money.
    ///
    /// The sentences this produces say "restore", not "import", because the
    /// screen that shows them says "Restore backup" on the button directly
    /// above. A refusal that answers in different words than the action it
    /// refused reads as a refusal of something else.
    case storeNotEmpty

    /// The stored graph could not be read at launch. Importing over it would
    /// destroy the only copy of rows this build could not parse.
    case storeUnreadable

    /// The file could not be opened or read at all.
    case fileUnreadable

    /// Confirm was reached with nothing staged — no file has been previewed.
    case noDocumentStaged

    /// The bytes are not a finance export. `field` is the structural path of
    /// the first thing that did not fit, when the decoder identified one.
    case notAFinanceDocument(field: String?, reason: MalformedReason)

    /// The document is well-formed but written to a schema version this build
    /// does not implement.
    case unsupportedSchemaVersion(found: String, supported: [String])

    /// The document decoded, but says something that cannot be true.
    case inconsistentDocument(SemanticProblem)

    /// Everything validated and the write still failed. Nothing was kept.
    case persistenceFailed(String)

    /// What shape of problem the decoder hit, without the value that caused it.
    enum MalformedReason: Hashable, Sendable {
        case notJSON
        case missingField
        case wrongType
        /// A field present, of the right type, holding something unreadable —
        /// a malformed money string, a date that is not a date, an ownership
        /// split that does not add up.
        case unreadableValue
    }

    /// A contradiction inside a document that decoded cleanly.
    ///
    /// Each case names records by identifier — an id the person chose, like
    /// `bank-main` — and never by balance, because an id is what they need in
    /// order to go and fix the export.
    enum SemanticProblem: Hashable, Sendable {
        case noAccounts
        case duplicateAccount(id: String)
        case duplicateBalance(accountID: String)
        case balanceForUnknownAccount(accountID: String)
        case accountWithoutBalance(accountID: String)
        case balanceCurrencyMismatch(accountID: String)
        case duplicateRecord(kind: String, id: String)
        case transactionOnUnknownAccount(transactionID: String, accountID: String)
        case incomeSourceOnUnknownAccount(sourceID: String, accountID: String)
        case carriedValueForUnknownAccount(accountID: String)
        case invalidExternalEvidence
        case invalidPlanning
        case unrepresentableAmount
        /// A balance is dated so far from today that its age cannot be stated
        /// as a number of days. Presenting it without an age would show a
        /// figure of unknown vintage as though it were current.
        case undatableBalance(accountID: String)

        var message: String {
            switch self {
            case .noAccounts:
                "This export contains no accounts, so there is nothing to import."
            case let .duplicateAccount(id):
                "Two accounts share the identifier “\(id)”."
            case let .duplicateBalance(accountID):
                "Account “\(accountID)” has more than one balance. Only one can be kept, and choosing for you would pick a figure nobody chose."
            case let .balanceForUnknownAccount(accountID):
                "A balance refers to account “\(accountID)”, which is not in this export."
            case let .accountWithoutBalance(accountID):
                "Account “\(accountID)” has no balance. It would import and then not appear anywhere."
            case let .balanceCurrencyMismatch(accountID):
                "The balance for account “\(accountID)” is in a different currency from the account."
            case let .duplicateRecord(kind, id):
                "Two \(kind) records share the identifier “\(id)”."
            case let .transactionOnUnknownAccount(transactionID, accountID):
                "Transaction “\(transactionID)” moves money on account “\(accountID)”, which is not in this export."
            case let .incomeSourceOnUnknownAccount(sourceID, accountID):
                "Income source “\(sourceID)” arrives on account “\(accountID)”, which is not in this export."
            case let .carriedValueForUnknownAccount(accountID):
                "A carried value refers to account “\(accountID)”, which is not in this export."
            case .invalidExternalEvidence:
                "The provider-evidence graph contains a broken binding, review state, or transaction link."
            case .invalidPlanning:
                "This export's planned purchases or sinking funds are not internally consistent."
            case .unrepresentableAmount:
                "This export contains an amount too large for the app's calculations. Nothing was restored."
            case let .undatableBalance(accountID):
                "The balance for account “\(accountID)” is dated too far from today for its age to be stated."
            }
        }
    }

    /// One sentence, addressed to the person who just chose the file.
    var message: String {
        switch self {
        case .storeIsReadOnly:
            "This is a preview. Nothing is restored here."
        case .storeNotEmpty:
            "Restoring into an account history that already exists is not supported yet."
        case .storeUnreadable:
            "Your existing data could not be opened, so it will not be replaced. Nothing was restored."
        case .fileUnreadable:
            "That file could not be opened."
        case .noDocumentStaged:
            "Choose a file to restore from first."
        case let .notAFinanceDocument(field, reason):
            if let field {
                "This is not a finance export this app can read: \(reason.phrase) at \(field)."
            } else {
                "This is not a finance export this app can read: \(reason.phrase)."
            }
        case let .unsupportedSchemaVersion(found, supported):
            "This export is written to schema \(found). This app reads \(supported.joined(separator: ", "))."
        case let .inconsistentDocument(problem):
            problem.message
        case let .persistenceFailed(reason):
            "The restore could not be saved, so nothing was changed: \(reason)"
        }
    }

    /// The line under the message, when there is more worth saying.
    var recoverySuggestion: String? {
        switch self {
        case .storeNotEmpty:
            "Restoring on top of existing accounts could duplicate money. A backup restores into a fresh install — so keep the file, and add anything missing here by hand in the meantime."
        case .storeUnreadable:
            "The data on this device is intact but unreadable by this build. Do not restore over it."
        case .notAFinanceDocument, .inconsistentDocument:
            "Nothing on this device was changed. Fix the export and choose it again."
        default:
            nil
        }
    }
}

extension AppImportError.MalformedReason {
    var phrase: String {
        switch self {
        case .notJSON: "the file is not JSON"
        case .missingField: "a required field is missing"
        case .wrongType: "a field has the wrong type"
        case .unreadableValue: "a value could not be read"
        }
    }
}
