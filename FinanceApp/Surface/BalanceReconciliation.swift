import Foundation

/// A diagnostic review, never a reconciliation acceptance or balance adjustment.
struct BalanceReconciliation: Hashable, Sendable {
    enum Blocker: String, Hashable, Sendable {
        case missingCurrentDay, missingDate, invalidDate, futureDate, identityMismatch, missingAnchor, beforeAnchor, currencyMismatch
        case inactiveBinding, unsupportedType, unsafeArithmetic

        var message: String {
            switch self {
            case .missingCurrentDay: "The current civil day could not be read. Bank evidence remains visible, but its dated comparison is unavailable."
            case .missingDate: "The bank supplied no balance reference date. Observation time does not establish the date of the money."
            case .invalidDate: "The bank reference date is invalid. No dated comparison is available."
            case .identityMismatch: "The retained balance does not belong to this provider mapping. Review the bank connection before comparing it."
            case .futureDate: "The bank reference date is in the future. A current ledger comparison is unavailable."
            case .missingAnchor: "No opening balance is recorded for this account. A missing balance is not zero."
            case .beforeAnchor: "The bank reference date precedes the opening balance. Earlier cash cannot be reconstructed from that anchor."
            case .currencyMismatch: "The bank and account currencies or precision differ. No conversion or difference is inferred."
            case .inactiveBinding: "This bank mapping is inactive. Retained evidence does not establish current account cash."
            case .unsupportedType: "This balance type has no supported meaning here. Its amount remains evidence, without a ledger comparison."
            case .unsafeArithmetic: "These values exceed the supported calculation range. No balance or difference is approximated."
            }
        }
    }

    let accountID: String
    let balanceMeaning: String
    let balanceExplanation: String
    let openingAmount: Amount?
    let openingDay: CalendarDay?
    let movementNet: Amount?
    let movementIDs: [String]
    let pendingMovementCount: Int
    let unreviewedObservationIDs: [String]
    let currentPendingObservationIDs: [String]
    let blocker: Blocker?

    var comparisonCaution: String {
        "A numerical difference is a diagnostic, not proof of missing spending or income. Recorded pending entries, booking dates, holds and incomplete evidence can differ from the bank's balance. An equal amount does not verify the account."
    }
}
