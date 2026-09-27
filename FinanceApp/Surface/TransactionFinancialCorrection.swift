import Foundation

struct TransactionFinancialValues: Codable, Hashable, Sendable {
    var day: CalendarDay
    var amount: Amount
    var accountID: String
}

struct TransactionFinancialDraft: Hashable, Sendable, Identifiable {
    let transactionID: String
    let documentRevision: String
    let original: TransactionFinancialValues
    let kindLabel: String
    let accounts: [AccountOption]
    var corrected: TransactionFinancialValues
    var reason = ""
    var id: String { transactionID }
}

struct FinancialAccountImpact: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let before: Amount?
    let after: Amount?
}

struct TransactionFinancialPreview: Hashable, Sendable {
    let draft: TransactionFinancialDraft
    let asOf: CalendarDay
    let accountImpacts: [FinancialAccountImpact]
    let affectedMonths: [String]
}

struct TransactionFinancialHistory: Identifiable, Hashable, Sendable {
    let id: String
    let recordedAt: Date
    let reason: String
    let before: TransactionFinancialValues
    let after: TransactionFinancialValues
    let beforeAccountName: String
    let afterAccountName: String
}

// Safe, product-facing refusals. No persistence diagnostics or financial data.
enum AppFinancialCorrectionError: Error, Hashable, Sendable {
    case readOnly, unreadable, notFound, staleDraft, unsupported
    case sourceEvidence, bankEvidence, paymentMatch, linkedRecord, goalPurchase
    case invalidAmount, invalidDate, invalidAccount, currencyMismatch, reasonRequired, noChanges, saveFailed

    var message: String {
        switch self {
        case .readOnly: "This view cannot change recorded financial details."
        case .unreadable: "Your data could not be opened. Nothing can be changed."
        case .notFound: "This transaction is no longer here."
        case .staleDraft: "Your records changed during editing. Close and reopen this sheet to review the latest values."
        case .unsupported: "This release supports plain pending or cleared expenses and income. Transfers, shared ownership and other transaction types need separate correction handling."
        case .sourceEvidence: "These financial facts came from an external source. Correct them at their source; you can still change your merchant label or category here."
        case .bankEvidence: "This transaction is linked to bank evidence. Financial changes need the evidence link to be reviewed first."
        case .paymentMatch: "This transaction matches an expected payment. Financial changes need the payment match to be reviewed first."
        case .linkedRecord: "Another financial record depends on this transaction. Its relationship needs to be reviewed first."
        case .goalPurchase: "A goal records this transaction as its purchase. Review that purchase before changing financial details."
        case .invalidAmount: "Enter a positive amount within the supported range, using the account's currency precision."
        case .invalidDate: "Choose a valid date on or before today."
        case .invalidAccount: "Choose an active account offered for this correction."
        case .currencyMismatch: "The account must use the transaction's existing currency and precision. A correction does not convert money."
        case .reasonRequired: "Explain the correction in 1–500 characters."
        case .noChanges: "There are no financial changes to review."
        case .saveFailed: "The correction could not be saved. Nothing changed; your edits are still here."
        }
    }
}
