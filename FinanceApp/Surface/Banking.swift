import Foundation

/// App-facing binding deliberately omits the backend account id. Screens know
/// only the local account and a provider label.
struct ProviderAccountBinding: Identifiable, Hashable, Sendable {
    let id: String
    let providerName: String
    let localAccountID: String
    let localAccountName: String
    let syncStartBoundary: CalendarDay
    let isActive: Bool
}

/// App-local authority for which retained provisional observations are still
/// current. Provider absence means authority has not yet been established;
/// presence with no identifiers is an authoritative empty snapshot.
struct CurrentPendingProviderSnapshot: Identifiable, Hashable, Sendable {
    let id: String
    let providerName: String
    let authoritativeAt: Date
    let observationIDs: Set<String>
}

enum SyncedObservationStatus: String, Hashable, Sendable {
    case booked, pending, rejected, other

    var displayName: String {
        switch self {
        case .booked: "Booked"
        case .pending: "Pending"
        case .rejected: "Rejected"
        case .other: "Other"
        }
    }
}

enum SyncedObservationResolution: String, Hashable, Sendable {
    case unreviewed, linked, noEconomicEffect, outsideBoundary, provisional, ineligible

    var isResolved: Bool { self == .linked || self == .noEconomicEffect }
}

enum ObservationSuggestionKind: String, Hashable, Sendable {
    case recurring, existingTransaction, crossProvider, likelyTransfer
    case atmCashMovement, refundOrReversal, merchantUnresolved, trustedRule
}

enum ObservationSuggestionConfidence: String, Hashable, Sendable {
    case low, medium, high
}

struct ObservationSuggestion: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let kind: ObservationSuggestionKind
    let targetTransactionID: String?
    let targetExpectedPaymentID: String?
    let relatedObservationID: String?
    let explanation: String?
    let confidence: ObservationSuggestionConfidence
    let trustedRuleID: String?
    let automaticResolutionEligible: Bool
}

enum ObservationInboxPriority: Int, Hashable, Sendable, Comparable {
    case risky = 0
    case highConfidenceSuggestion = 1
    case needsHumanJudgment = 2
    case provisionalEvidence = 3
    case reviewed = 4

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct ObservationDates: Hashable, Sendable {
    let booking: CalendarDay?
    let transaction: CalendarDay?
    let value: CalendarDay?
    let derivedTransaction: CalendarDay?
    let derivedProvenanceLabel: String?

    /// The period this observation's economics belong to, carried verbatim
    /// from `ExternalObservation.economicPeriodDay`.
    ///
    /// The four fields above stay separate provider evidence and are shown as
    /// such. This is the domain's own answer, transported — never a fallback
    /// chain re-derived up here. Nil only when the provider supplied no date
    /// at all, which is also when the domain has no answer.
    let economicPeriod: CalendarDay?
}

/// A strong reason not to create another economic actual casually.
///
/// This is presentation and write-guard context, not a resolution state. In
/// particular, an aggregate conflict remains unreviewed because the current
/// evidence schema cannot truthfully attach one observation to two actuals.
struct ObservationDuplicateConflict: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case exactExisting
        case aggregateExisting
        case settledRecurring
        case crossProvider
    }

    let kind: Kind
    let transactionIDs: [String]
    let relatedObservationID: String?

    var context: String {
        switch kind {
        case .exactExisting:
            "An existing transaction matches this provider activity."
        case .aggregateExisting:
            "Two existing transactions together equal this provider activity. They cannot be linked as one record."
        case .settledRecurring:
            "A matching recurring payment is already settled by an existing transaction."
        case .crossProvider:
            "Provider evidence suggests this may be another view of activity already recorded."
        }
    }

    var warning: String {
        switch kind {
        case .exactExisting:
            "This already matches an existing transaction. Creating a new expense can record it twice."
        case .aggregateExisting:
            "This amount is already represented by multiple existing transactions. Creating a new expense can record it twice."
        case .settledRecurring:
            "A matching recurring payment is already settled. Creating a new expense can record it twice."
        case .crossProvider:
            "Cross-provider evidence suggests the same activity may already be recorded. Creating a new expense can record it twice."
        }
    }
}

struct SyncedObservationItem: Identifiable, Hashable, Sendable {
    /// Opaque backend observation identity. This is not a raw provider account
    /// identifier or secret, and is never rendered to the person.
    let id: String
    let providerName: String
    let providerAccountName: String
    let isAccountBindingActive: Bool
    let amount: Amount
    let status: SyncedObservationStatus
    let resolution: SyncedObservationResolution
    let displayMerchant: String
    let observedMerchant: String?
    let rawMerchantText: String?
    let remittance: String?
    let merchantEmail: String?
    let bankTransactionCode: String?
    let dates: ObservationDates
    let observedAt: Date
    let suggestions: [ObservationSuggestion]
    let duplicateConflict: ObservationDuplicateConflict?

    /// The provider has since withdrawn or downgraded a row this person
    /// already resolved. Their decision stands; this only says the two records
    /// disagree and a human should look.
    let hasProviderStatusWarning: Bool

    var primarySuggestion: ObservationSuggestion? { suggestions.first }

    var trustedAutomationReviewReason: String? {
        let automaticMatches = suggestions.filter {
            $0.kind == .trustedRule && $0.automaticResolutionEligible
        }
        return automaticMatches.count > 1 ? "Multiple trusted rules match" : nil
    }

    /// Creating a new actual is still allowed, but these signals mean the
    /// observation may already be represented. The UI must warn before create.
    var duplicateCreationWarning: String? {
        if let duplicateConflict { return duplicateConflict.warning }
        if suggestions.contains(where: { $0.kind == .existingTransaction }) {
            return "This already matches an existing transaction. Creating a new expense can record it twice."
        }
        if suggestions.contains(where: { $0.kind == .crossProvider && $0.relatedObservationID != nil }) {
            return "A unique cross-provider match exists. Creating a new expense can record the same movement twice."
        }
        if suggestions.contains(where: { $0.kind == .merchantUnresolved }) {
            return "Cross-provider evidence is unresolved. Creating a new expense may record the same movement twice."
        }
        return nil
    }

    var inboxPriority: ObservationInboxPriority {
        if hasProviderStatusWarning { return .risky }
        guard resolution == .unreviewed else {
            return resolution.isResolved ? .reviewed : .provisionalEvidence
        }
        if suggestions.contains(where: { suggestion in
            switch suggestion.kind {
            case .crossProvider, .likelyTransfer, .atmCashMovement,
                 .refundOrReversal, .merchantUnresolved:
                true
            case .recurring, .existingTransaction, .trustedRule:
                false
            }
        }) { return .risky }
        if amount.isPositive && !suggestions.contains(where: {
            $0.kind == .trustedRule && $0.automaticResolutionEligible
        }) { return .risky }
        if suggestions.contains(where: { $0.confidence == .high }) {
            return .highConfidenceSuggestion
        }
        return .needsHumanJudgment
    }
}

struct TrustedRuleAuditSummary: Identifiable, Hashable, Sendable {
    let id: String
    let action: String
    let occurredAt: Date
    let explanation: String
}

struct TrustedRuleSupportSummary: Identifiable, Hashable, Sendable {
    let id: String
    let confirmedAt: Date
    let economicDate: CalendarDay?
    let amount: Amount?
    let category: String?
    let userLabel: String?
}

struct TrustedRuleBlockedMatchSummary: Identifiable, Hashable, Sendable {
    let id: String
    let reasons: [String]
}

struct TrustedRuleSummary: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let providerName: String
    let accountName: String
    let bindingReference: String
    let merchantEvidenceField: String
    let merchantEvidenceValue: String
    let direction: String
    let currency: String
    let exactAmount: Amount?
    let providerCode: String?
    let economicKind: String
    let category: String?
    let userLabel: String?
    let recurringObligation: String?
    let economicSource: String?
    let trust: String
    let lifecycle: String
    let supportCount: Int
    let supportingConfirmations: [TrustedRuleSupportSummary]
    let semanticFingerprint: String
    let automaticSafetyReasons: [String]
    let currentMatchCount: Int
    let currentAutomaticallyEligibleCount: Int
    let currentSuggestionOnlyCount: Int
    let currentSuggestionOnlyReasons: [String]
    let currentBlockedMatches: [TrustedRuleBlockedMatchSummary]
    let approvedAt: Date?
    let disabledAt: Date?
    let audit: [TrustedRuleAuditSummary]

    var canDisable: Bool { lifecycle == "Active" }
    var canApproveSuggestionOnly: Bool { lifecycle == "Draft" }
    var canApproveAutomatic: Bool {
        lifecycle != "Disabled" && trust != "Approved automatic"
            && automaticSafetyReasons.isEmpty
            && currentSuggestionOnlyCount == 0
            && currentBlockedMatches.isEmpty
    }

    var safetyExplanation: String {
        automaticSafetyReasons.isEmpty
            ? "Eligible for automatic approval under the Phase 2.6 expense-debit policy. Each application must also carry explicit provider purchase semantics. Approval will not apply existing matches."
            : automaticSafetyReasons.joined(separator: " ")
    }
}

struct ProviderBalanceStatus: Identifiable, Hashable, Sendable {
    let id: String
    let providerName: String
    let accountName: String
    let balanceType: String
    let ledgerBalance: Amount
    let providerBalance: Amount
    let difference: Amount?
    let referenceDate: CalendarDay?
    let observedAt: Date

    var differsFromLedger: Bool { difference?.isZero == false }
}

enum BankReviewError: Error, Hashable, Sendable {
    case storeIsReadOnly
    case unknownObservation
    case unknownAccount
    case unknownRule
    case invalidAction(String)
    case persistenceFailed(String)

    var message: String {
        switch self {
        case .storeIsReadOnly: "This store is read-only."
        case .unknownObservation: "That synced item is no longer available."
        case .unknownAccount: "The linked account is no longer available."
        case .unknownRule: "That trusted rule is no longer available."
        case let .invalidAction(reason): reason
        case .persistenceFailed: "The review decision could not be saved. Nothing was changed."
        }
    }
}

// MARK: - Phase 2.4D: live sync surface

/// What Connected Accounts shows for one provider connection.
///
/// A code from the service becomes a state here; the wording belongs to the
/// app, so a raw provider or API error is never put in front of a person.
enum ProviderConnectionState: String, Hashable, Sendable {
    case connected
    case expiringSoon
    case reauthorizationRequired
    case revoked
    case unknown

    var displayName: String {
        switch self {
        case .connected: "Connected"
        case .expiringSoon: "Renew soon"
        case .reauthorizationRequired: "Reconnect required"
        case .revoked: "Disconnected"
        case .unknown: "Unknown"
        }
    }

    /// True when the person has to do something. Consent is never renewed
    /// silently: reauthorization means talking to the bank, in person.
    var needsAttention: Bool { self == .reauthorizationRequired || self == .revoked }
}

struct ProviderConnectionStatus: Identifiable, Hashable, Sendable {
    let id: String
    let providerName: String
    let institution: String?
    let state: ProviderConnectionState
    let consentExpires: CalendarDay?
    let lastSyncedAt: Date?
    /// Present when the last attempt failed. Already sanitized.
    let lastErrorMessage: String?
}

/// A remote account the person may map to a local one.
struct MappableRemoteAccount: Identifiable, Hashable, Sendable {
    let id: String
    let providerName: String
    let displayName: String
    let currencyCode: String?
    /// The local account it is bound to, when it has been mapped.
    let mappedLocalAccountID: String?
    let mappedLocalAccountName: String?
    /// The cutover this mapping uses. Shown before it is agreed to, never
    /// silently chosen.
    let syncStartBoundary: CalendarDay?

    var isMapped: Bool { mappedLocalAccountID != nil }
}

/// Where a sync is in its life. `failed` carries a message a person can act on.
enum BankSyncActivity: Hashable, Sendable {
    case idle
    case syncing
    case succeeded(at: Date)
    case failed(String)

    var isSyncing: Bool { self == .syncing }
}

enum BankPairingState: Hashable, Sendable {
    case notConfigured
    case unpaired
    case paired
    /// The backend no longer recognises this device; the person pairs again.
    case revoked
}
