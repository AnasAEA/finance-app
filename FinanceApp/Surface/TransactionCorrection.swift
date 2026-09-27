import Foundation

/// App-owned descriptions, separate from the immutable recorded economic fact.
struct TransactionMetadata: Codable, Hashable, Sendable {
    var merchant: String?
    var categoryKey: String?

    static func normalizedMerchant(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

struct TransactionCorrectionDraft: Hashable, Sendable, Identifiable {
    let transactionID: String
    let revision: Int
    let original: TransactionMetadata
    let categories: [CategoryOption]
    var corrected: TransactionMetadata
    var id: String { transactionID }
}

/// Sequence, rather than clock order, defines the append-only chain.
struct TransactionMetadataCorrection: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let transactionID: String
    let revision: Int
    let recordedAt: Date
    let before: TransactionMetadata
    let after: TransactionMetadata
}

enum AppCorrectionError: Error, Hashable, Sendable {
    case storeIsReadOnly, storeUnreadable, notFound, staleDraft
    case invalidCategory, merchantTooLong, noChanges, currentDayUnavailable
    case persistenceFailed

    var message: String {
        switch self {
        case .storeIsReadOnly: "This is a preview. Nothing can be corrected here."
        case .storeUnreadable: "Your data could not be opened, so nothing can be changed."
        case .notFound: "This transaction is no longer here."
        case .staleDraft: "This transaction changed while you were editing. Close this sheet and reopen it to review the current values."
        case .invalidCategory: "Choose a spending category offered for this transaction."
        case .merchantTooLong: "Keep the merchant name within 200 characters."
        case .noChanges: "There are no changes to save."
        case .currentDayUnavailable: "The current date could not be read. Nothing was changed."
        case .persistenceFailed: "The correction could not be saved. Nothing was changed; your edits are still here."
        }
    }
}
