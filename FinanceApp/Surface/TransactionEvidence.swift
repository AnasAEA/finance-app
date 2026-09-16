import Foundation

/// Where a transaction came from, when bank or other external evidence is
/// recorded as the reason it exists.
///
/// ## Why the relationship only pointed one way
///
/// Reviewing a piece of provider evidence and deciding what it meant produces
/// an `ExternalEvidenceLink`. From the evidence side that decision is visible:
/// the observation says it is linked. From the transaction side it was
/// invisible, so a person looking at the row the decision produced had no way
/// back to the evidence behind it — and no explanation for why the app then
/// refused to remove that row.
///
/// ## This is a link, never a resemblance
///
/// Every value here comes from a persisted `ExternalEvidenceLink` and the
/// observation it names. Nothing is matched on amount, date, merchant text,
/// provider or identifier shape. A transaction with no link produces an empty
/// array, which is the whole answer: the app does not guess where a row came
/// from, and two records happening to agree about money on a day is not
/// provenance.
///
/// ## What the document already guarantees
///
/// `ExternalEvidenceReview.validate` holds these, so nothing here re-checks
/// them and nothing downstream may assume less:
///
/// - a link names a real observation **and** a real transaction, so a dangling
///   link cannot exist in a valid document;
/// - an observation links to **at most one** transaction;
/// - a transaction may be named by **many** observations, which is why this is
///   an array and why no caller may take the first and call it the source;
/// - an observation carries links **exactly when** its resolution is
///   `linkedToTransaction`, so evidence reachable from here has already been
///   decided and is not waiting for review.
struct TransactionEvidenceSummary: Identifiable, Hashable, Sendable {

    /// The observation's own identity. Opaque: it addresses the canonical
    /// evidence screen and is never rendered to a person.
    let id: String

    /// `SyncedObservationItem.displayMerchant`, carried verbatim.
    let title: String

    /// Which provider account this was seen on, in the words the evidence
    /// screens already use.
    let providerLabel: String

    let amount: Amount

    /// The day the domain says this evidence's economics belong to
    /// (`ObservationDates.economicPeriod`), not a fallback chain assembled
    /// here. `nil` when the provider supplied no date at all, which is also
    /// when the domain has no answer.
    let day: CalendarDay?

    let role: TransactionEvidenceRole
}

/// What a piece of evidence was recorded as being *for*.
///
/// A translation of `ExternalEvidenceRole`, which is a closed vocabulary the
/// domain already owns. The distinction is worth surfacing because the roles
/// are not interchangeable: an account movement is the bank's record of the
/// money itself, and the others describe or support it.
enum TransactionEvidenceRole: String, Hashable, Sendable {
    case bankMovement
    case merchantDetail
    case supporting

    var label: String {
        switch self {
        case .bankMovement: "Bank movement"
        case .merchantDetail: "Merchant detail"
        case .supporting: "Supporting evidence"
        }
    }

    /// Ordering weight, so a list of evidence is deterministic and leads with
    /// the record of the money rather than with something describing it.
    var precedence: Int {
        switch self {
        case .bankMovement: 0
        case .merchantDetail: 1
        case .supporting: 2
        }
    }
}

extension TransactionEvidenceSummary {

    static let sectionTitle = "Source"

    /// Why this section exists, in one line under the rows.
    ///
    /// It says what the link *is* — a decision a person made about evidence —
    /// without claiming the bank verified the transaction, which is not what a
    /// link means. It also does not restate the removal blocker sitting under
    /// it: that section explains what deleting this row would do, and this one
    /// explains that looking is safe.
    static let footer =
        "Bank evidence you already decided the meaning of. It stays exactly as it was recorded, and opening it changes nothing."

    /// The row's second line: role, day and provider account, in that order.
    /// The amount is shown beside it rather than repeated here.
    var detailLine: String {
        var parts = [role.label]
        if let day { parts.append(day.formatted(.dateTime.day().month(.abbreviated))) }
        parts.append(providerLabel)
        return parts.joined(separator: " · ")
    }

    var accessibilityLabel: String {
        var parts = [title, role.label]
        if let day { parts.append(day.formatted(.dateTime.day().month(.wide))) }
        parts.append(providerLabel)
        parts.append(amount.magnitude.accessibleDescription())
        return parts.joined(separator: ", ")
    }
}
