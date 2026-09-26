import Foundation
import Testing
@testable import FinanceApp

@Suite("Quick categorization safety")
struct QuickCategorizationTests {
    private func item(status: SyncedObservationStatus = .booked,
                      resolution: SyncedObservationResolution = .unreviewed,
                      active: Bool = true, amount: Int64 = -500,
                      warning: Bool = false, kind: ObservationSuggestionKind? = nil) -> SyncedObservationItem {
        SyncedObservationItem(id: "test", providerName: "Test Bank", providerAccountName: "Test account",
            isAccountBindingActive: active, amount: Amount(minorUnits: amount, currencyCode: "EUR"),
            status: status, resolution: resolution, displayMerchant: "Test purchase", observedMerchant: nil,
            rawMerchantText: nil, remittance: nil, merchantEmail: nil, bankTransactionCode: nil,
            dates: ObservationDates(booking: nil, transaction: nil, value: nil, derivedTransaction: nil,
                                    derivedProvenanceLabel: nil, economicPeriod: nil),
            observedAt: Date(timeIntervalSince1970: 0),
            suggestions: kind.map { [ObservationSuggestion(id: "suggestion", title: "Test suggestion", kind: $0,
                targetTransactionID: "existing", targetExpectedPaymentID: "expected", relatedObservationID: "related",
                explanation: nil, confidence: .high, trustedRuleID: nil, automaticResolutionEligible: false)] } ?? [],
            duplicateConflict: nil, hasProviderStatusWarning: warning)
    }

    @Test("A purchase shortcut never bypasses duplicate, transfer, cash, refund or recurring review")
    func riskyEvidenceKeepsFullReview() {
        #expect(item().canQuicklyCategorize)
        for kind: ObservationSuggestionKind in [.existingTransaction, .crossProvider, .merchantUnresolved,
                                                .likelyTransfer, .atmCashMovement, .refundOrReversal, .recurring] {
            #expect(!item(kind: kind).canQuicklyCategorize)
        }
    }

    @Test("Pending, resolved, inactive, positive and provider-warning evidence never offers the shortcut")
    func unavailableEvidenceCannotQuicklyCategorize() {
        #expect(!item(status: .pending).canQuicklyCategorize)
        #expect(!item(resolution: .linked).canQuicklyCategorize)
        #expect(!item(active: false).canQuicklyCategorize)
        #expect(!item(amount: 500).canQuicklyCategorize)
        #expect(!item(amount: 0).canQuicklyCategorize)
        #expect(!item(warning: true).canQuicklyCategorize)
    }
}
