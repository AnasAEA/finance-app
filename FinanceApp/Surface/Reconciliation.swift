import Foundation

/// Product-facing reconciliation types.
///
/// Deliberately Foundation-only, like the rest of `Surface`: the screens that
/// reconcile a payment must not learn what a `RecurringObligation` or a
/// `MatchCandidate` is. The scoring, the rules and the refusals all live in the
/// engine; what arrives here is already a decision a person can read.

/// Where one expected payment stands.
enum ExpectedPaymentStatus: Hashable, Sendable {

    /// Not due yet, not settled.
    case due

    /// Its day has passed with nothing matched to it. Deliberately not
    /// "missed" and deliberately not "paid": the app does not know, and says
    /// so rather than choosing for the person.
    case overdue

    /// Settled by a recorded transaction.
    case paid(transactionID: String)

    /// Deliberately not paid this cycle.
    case skipped

    /// The charge is not coming at all.
    case noLongerDue

    /// The short label a row shows. `nil` while there is nothing to say —
    /// an ordinary future payment needs no badge.
    var label: String? {
        switch self {
        case .due: nil
        case .overdue: "Expected"
        case .paid: "Paid"
        case .skipped: "Skipped"
        case .noLongerDue: "No longer due"
        }
    }

    var isResolved: Bool {
        switch self {
        case .due, .overdue: false
        case .paid, .skipped, .noLongerDue: true
        }
    }

    var matchedTransactionID: String? {
        if case let .paid(id) = self { return id }
        return nil
    }
}

/// One dated instance of a recurring commitment.
///
/// The *occurrence*, not the rule: "the September one", not "monthly on the
/// 26th". Resolving this leaves the rule exactly as it was.
struct ExpectedPayment: Identifiable, Hashable, Sendable {

    /// Stable across launches: the rule plus the day it is expected on.
    let id: String

    let ruleID: String
    let ruleName: String

    /// The planned or inferred day. Not evidence, and never replaced by the
    /// date a payment actually landed.
    let expectedDate: CalendarDay

    let amount: Amount
    let status: ExpectedPaymentStatus

    /// Where the rule expected the money to come from, when it says so.
    let expectedAccountLabel: String?

    var isResolved: Bool { status.isResolved }
}

/// How much the app is willing to say about a proposed match.
///
/// None of these authorise anything on their own — every link is made by a
/// person tapping it. The level only orders the list and colours the hint.
enum MatchStrength: String, Hashable, Sendable {
    case strong
    case plausible
    case weak

    var label: String {
        switch self {
        case .strong: "Very likely"
        case .plausible: "Possible"
        case .weak: "Unlikely"
        }
    }
}

/// A proposed pairing, in the terms a person can check.
struct PaymentMatch: Identifiable, Hashable, Sendable {

    let id: String

    /// The occurrence side.
    let expectedPaymentID: String
    let ruleName: String
    let expectedDate: CalendarDay
    let expectedAmount: Amount

    /// The actual side.
    let transactionID: String
    let transactionTitle: String?
    /// The observed date. Shown next to `expectedDate`, never merged with it.
    let actualDate: CalendarDay
    let actualAmount: Amount
    let accountLabel: String?

    let strength: MatchStrength

    /// True when the two amounts are not the same figure. The confirm button
    /// says so, and the link cannot be made without acknowledging it.
    let requiresAmountConfirmation: Bool

    /// Plain-language reasons, already ordered: why this is being suggested.
    let reasons: [String]

    /// The date gap, for a row that wants to show "3 days later".
    let daysApart: Int
}

/// What a transaction detail can say about its reconciliation.
struct ReconciliationSummary: Hashable, Sendable {
    let ruleName: String
    let expectedDate: CalendarDay
    let actualDate: CalendarDay
    let accountLabel: String?
    /// Set when a person accepted an amount that did not match exactly.
    let amountDifferenceAccepted: Bool
}

/// Why a reconciliation could not be made.
enum AppReconciliationError: Error, Equatable, CustomStringConvertible {
    case storeIsReadOnly
    case unknownExpectedPayment
    case unknownTransaction
    case alreadyResolved
    case transactionAlreadyMatched
    case amountDiffersWithoutConfirmation
    case refused(String)
    case persistenceFailed(String)

    var description: String { message }

    var message: String {
        switch self {
        case .storeIsReadOnly:
            "Your records could not be opened, so nothing can be changed."
        case .unknownExpectedPayment:
            "That expected payment is no longer there."
        case .unknownTransaction:
            "That transaction is no longer there."
        case .alreadyResolved:
            "This expected payment has already been settled."
        case .transactionAlreadyMatched:
            "That transaction already settles another expected payment."
        case .amountDiffersWithoutConfirmation:
            "The amounts are different, so this match has to be confirmed explicitly."
        case let .refused(reason):
            reason
        case let .persistenceFailed(reason):
            "The change could not be saved (\(reason))."
        }
    }
}
