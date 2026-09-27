import Foundation

/// Why a transaction cannot be removed, or `nil` when it can.
///
/// Removing a transaction is not the same operation as forgetting a row. Four
/// kinds of durable record in this document name a transaction by identifier,
/// and each of them means something a person decided or a bank observed:
///
/// - a settlement says *this payment is the one that settled that expected
///   occurrence*;
/// - an evidence link says *this transaction is what that bank line meant*;
/// - another transaction's link says *this is the expense I refund* or *the
///   purchase I repay*;
/// - a goal says *this transaction is the purchase I planned for*.
///
/// None of those is noise to be tidied away with the row. Two of them are
/// already refused by FinanceCore on the way to disk — a settlement or an
/// evidence link naming a transaction that is not in the document fails
/// validation — and the other two are worse, because nothing refuses them: a
/// refund whose linked expense disappears silently starts offsetting spending
/// that the reversal had already cancelled.
///
/// So the rule is refusal, never cascade. Removing one row never deletes a
/// settlement, an evidence link or a decision recorded elsewhere.
enum AppRemovalError: Error, Hashable, Sendable {

    /// A fixed preview/test store was asked to remove something.
    case storeIsReadOnly

    /// The stored graph could not be read at launch, so the store refuses to
    /// write at all. Rows it could not parse are still the only copy of
    /// themselves.
    case storeUnreadable

    /// It is not in the document any more. Reached when the row on screen has
    /// been overtaken by a change underneath it.
    case notFound

    /// It did not come from this app. Imported and reconstructed records are
    /// evidence of what happened, and the app has no way to put one back.
    case sourceEvidence

    /// A recurring payment the plan expected is recorded as settled by this
    /// transaction.
    case settlesExpectedPayment

    /// Bank evidence is linked to this transaction as what that line meant.
    case linkedToBankEvidence

    /// Another transaction — a refund, a repayment, a disposal — is recorded
    /// against this one.
    case linkedFromAnotherTransaction

    /// A goal records this transaction as the purchase it was saving for.
    case recordedAsGoalPurchase
    case hasCorrectionHistory

    /// Eligibility held and the write still failed. Nothing was changed.
    case persistenceFailed(String)

    /// One sentence, addressed to the person who just tried to remove it.
    ///
    /// Names the relationship in the words the app already uses for it on
    /// screen — "expected payment", "bank evidence", "goal" — and never a type,
    /// a field or an identifier.
    var message: String {
        switch self {
        case .storeIsReadOnly:
            "This is a preview. Nothing is removed here."
        case .storeUnreadable:
            "Your data could not be opened, so nothing can be changed."
        case .notFound:
            "This transaction is no longer here."
        case .sourceEvidence:
            "This came from imported records rather than being entered here, so it can’t be removed."
        case .settlesExpectedPayment:
            "This transaction is recorded as settling an expected payment."
        case .linkedToBankEvidence:
            "This transaction is what a piece of bank evidence was decided to mean."
        case .linkedFromAnotherTransaction:
            "Another transaction is recorded against this one."
        case .recordedAsGoalPurchase:
            "A goal records this transaction as its purchase."
        case .hasCorrectionHistory:
            "This transaction has a correction history that must be preserved."
        case let .persistenceFailed(reason):
            "It could not be removed, so nothing was changed: \(reason)"
        }
    }

    /// What the person can do about it, when there is something.
    var recoverySuggestion: String? {
        switch self {
        case .settlesExpectedPayment:
            "Remove that match first, then this can be removed."
        case .linkedToBankEvidence:
            "Bank evidence stays whatever happens to this row, so removing it here would leave that decision pointing at nothing."
        case .linkedFromAnotherTransaction:
            "Removing this one would change what that other transaction means. Remove that one first."
        case .recordedAsGoalPurchase:
            "Clear the purchase on that goal first."
        case .sourceEvidence:
            "You can correct its merchant or spending category here. Changes to the imported financial facts must be made where those records are produced."
        case .hasCorrectionHistory:
            "You can correct its merchant or category again. Removing the transaction would discard the record of those decisions."
        case .storeUnreadable:
            "The data on this device may still be intact. Do not reinstall the app before it can be read again."
        default:
            nil
        }
    }
}
