import Foundation

/// A trusted rule starts as a suggestion. Automatic resolution is a separate,
/// explicit trust level and is never the initializer default.
public enum TrustedRuleTrustLevel: String, Hashable, Sendable, Codable, CaseIterable {
    case suggestionOnly
    case approvedAutomatic
}

/// Lifecycle is independent of trust. Disabling a rule leaves its definition
/// and audit history intact while preventing every future match.
public enum TrustedRuleLifecycle: String, Hashable, Sendable, Codable, CaseIterable {
    case draft
    case active
    case disabled
}

/// The provider evidence field used as an exact merchant identity predicate.
/// These values remain evidence; they never become a category, user label,
/// counterparty, economic source, or ownership assertion.
public enum TrustedMerchantEvidenceField: String, Hashable, Sendable, Codable, CaseIterable {
    case structuredMerchantName
    case merchantEmail
    case rawMerchantText
    case remittance
}

public enum TrustedRuleDirection: String, Hashable, Sendable, Codable, CaseIterable {
    case debit
    case credit
}

/// A deliberately narrow, inspectable conjunction. There are no fuzzy or
/// substring predicates: every populated field must match exactly after the
/// stable whitespace/case normalization defined by `TrustedRuleEngine`.
public struct TrustedRulePredicate: Hashable, Sendable, Codable {
    public let provider: ExternalProvider
    public let bindingID: String
    public let merchantField: TrustedMerchantEvidenceField
    public let merchantValue: String
    public let direction: TrustedRuleDirection
    public let currencyCode: String
    public let currencyExponent: Int
    public let exactMinorUnits: Int64?
    public let bankTransactionCode: String?

    public init(
        provider: ExternalProvider,
        bindingID: String,
        merchantField: TrustedMerchantEvidenceField,
        merchantValue: String,
        direction: TrustedRuleDirection,
        currencyCode: String,
        currencyExponent: Int,
        exactMinorUnits: Int64? = nil,
        bankTransactionCode: String? = nil
    ) {
        self.provider = provider
        self.bindingID = bindingID
        self.merchantField = merchantField
        self.merchantValue = merchantValue
        self.direction = direction
        self.currencyCode = currencyCode.uppercased()
        self.currencyExponent = currencyExponent
        self.exactMinorUnits = exactMinorUnits
        self.bankTransactionCode = bankTransactionCode
    }
}

/// Economic interpretation is kept dimensional. In particular, an income
/// source is not a category, and a user label is not provider merchant text.
/// Ownership is intentionally absent: it always requires human judgment.
public struct TrustedRuleInterpretation: Hashable, Sendable, Codable {
    public let transactionKind: TransactionKind
    public let categoryKey: String?
    public let userLabel: String?
    public let recurringObligationID: String?
    public let incomeSourceID: String?

    public init(
        transactionKind: TransactionKind,
        categoryKey: String? = nil,
        userLabel: String? = nil,
        recurringObligationID: String? = nil,
        incomeSourceID: String? = nil
    ) {
        self.transactionKind = transactionKind
        self.categoryKey = categoryKey
        self.userLabel = userLabel
        self.recurringObligationID = recurringObligationID
        self.incomeSourceID = incomeSourceID
    }
}

/// One prior explicit confirmation supporting a rule. Category and label are
/// snapshotted because they live in the app presentation boundary rather than
/// on FinanceCore's economic transaction.
public struct TrustedRuleSupport: Identifiable, Hashable, Sendable, Codable {
    public var id: String { "\(observationID)->\(transactionID)" }
    public let observationID: String
    public let transactionID: String
    public let confirmedAt: Date
    public let categoryKey: String?
    public let userLabel: String?

    public init(
        observationID: String,
        transactionID: String,
        confirmedAt: Date,
        categoryKey: String? = nil,
        userLabel: String? = nil
    ) {
        self.observationID = observationID
        self.transactionID = transactionID
        self.confirmedAt = confirmedAt
        self.categoryKey = categoryKey
        self.userLabel = userLabel
    }
}

/// App-owned presentation attached to one explicitly confirmed economic
/// transaction. Candidate detection receives this separately because category
/// and user label are presentation semantics, not provider evidence.
public struct TrustedRuleConfirmationMetadata: Hashable, Sendable {
    public let transactionID: String
    public let categoryKey: String?
    public let userLabel: String?

    public init(
        transactionID: String,
        categoryKey: String? = nil,
        userLabel: String? = nil
    ) {
        self.transactionID = transactionID
        self.categoryKey = categoryKey
        self.userLabel = userLabel
    }
}

/// A safe, inactive proposal assembled only from prior explicit user
/// confirmations. The app supplies identifiers and the creation timestamp when
/// it persists the draft and its audit event.
public struct TrustedRuleProposal: Hashable, Sendable {
    public let title: String
    public let predicate: TrustedRulePredicate
    public let interpretation: TrustedRuleInterpretation
    public let supportingConfirmations: [TrustedRuleSupport]

    public func makeRule(id: String, createdAt: Date) -> TrustedRule {
        TrustedRule(
            id: id,
            title: title,
            predicate: predicate,
            interpretation: interpretation,
            supportingConfirmations: supportingConfirmations,
            createdAt: createdAt
        )
    }
}

private struct TrustedRuleProposalAccumulator {
    let title: String
    let predicate: TrustedRulePredicate
    let interpretation: TrustedRuleInterpretation
    var supports: [TrustedRuleSupport]
}

public struct TrustedRule: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public var title: String
    public let predicate: TrustedRulePredicate
    public let interpretation: TrustedRuleInterpretation
    public var trustLevel: TrustedRuleTrustLevel
    public var lifecycle: TrustedRuleLifecycle
    public let createdAt: Date
    public var approvedAt: Date?
    public var disabledAt: Date?
    public let supportingConfirmations: [TrustedRuleSupport]

    /// Stable semantic identity. Display title, lifecycle, trust, timestamps,
    /// and support ordering are deliberately excluded.
    public var semanticFingerprint: String {
        TrustedRuleEngine.semanticFingerprint(
            predicate: predicate,
            interpretation: interpretation
        )
    }

    public init(
        id: String,
        title: String,
        predicate: TrustedRulePredicate,
        interpretation: TrustedRuleInterpretation,
        supportingConfirmations: [TrustedRuleSupport],
        createdAt: Date,
        trustLevel: TrustedRuleTrustLevel = .suggestionOnly,
        lifecycle: TrustedRuleLifecycle = .draft,
        approvedAt: Date? = nil,
        disabledAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.predicate = predicate
        self.interpretation = interpretation
        self.trustLevel = trustLevel
        self.lifecycle = lifecycle
        self.createdAt = createdAt
        self.approvedAt = approvedAt
        self.disabledAt = disabledAt
        self.supportingConfirmations = supportingConfirmations
    }
}

public enum TrustedRuleAuditKind: String, Hashable, Sendable, Codable, CaseIterable {
    case created
    case approvedForSuggestions
    case approvedForAutomaticResolution
    case disabled
    case automaticallyResolved
    case reversed
    case reapplicationAuthorized
}

/// Append-only lifecycle and application history. A reversal points to the
/// application it reverses; neither disabling nor reversal erases an event.
public struct TrustedRuleAuditEvent: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let ruleID: String
    public let ruleSemanticFingerprint: String
    public let kind: TrustedRuleAuditKind
    public let occurredAt: Date
    public let observationID: String?
    public let transactionID: String?
    public let sourceAuditEventID: String?
    public let explanation: String

    public init(
        id: String,
        ruleID: String,
        ruleSemanticFingerprint: String,
        kind: TrustedRuleAuditKind,
        occurredAt: Date,
        observationID: String? = nil,
        transactionID: String? = nil,
        sourceAuditEventID: String? = nil,
        explanation: String
    ) {
        self.id = id
        self.ruleID = ruleID
        self.ruleSemanticFingerprint = ruleSemanticFingerprint
        self.kind = kind
        self.occurredAt = occurredAt
        self.observationID = observationID
        self.transactionID = transactionID
        self.sourceAuditEventID = sourceAuditEventID
        self.explanation = explanation
    }
}

/// A user's reversal is an explicit veto over one rule/observation pair. The
/// suppression survives imports and restarts and can only be cleared by a
/// later audited user action.
public struct TrustedRuleObservationSuppression: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let ruleID: String
    public let observationID: String
    public let applicationAuditEventID: String
    public let reversalAuditEventID: String
    public let createdAt: Date
    public var clearedAt: Date?
    public var clearAuditEventID: String?

    public init(
        id: String,
        ruleID: String,
        observationID: String,
        applicationAuditEventID: String,
        reversalAuditEventID: String,
        createdAt: Date,
        clearedAt: Date? = nil,
        clearAuditEventID: String? = nil
    ) {
        self.id = id
        self.ruleID = ruleID
        self.observationID = observationID
        self.applicationAuditEventID = applicationAuditEventID
        self.reversalAuditEventID = reversalAuditEventID
        self.createdAt = createdAt
        self.clearedAt = clearedAt
        self.clearAuditEventID = clearAuditEventID
    }

    public var isActive: Bool { clearedAt == nil }
}

public enum TrustedRuleDecisionMode: String, Hashable, Sendable, Codable {
    case suggestion
    case automaticResolution
    case blocked
}

public enum TrustedRuleConfidence: String, Hashable, Sendable, Codable, Comparable {
    case medium
    case high

    private var rank: Int { self == .high ? 2 : 1 }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public enum TrustedRuleAutomaticBlocker: String, Hashable, Sendable, Codable, CaseIterable {
    case ruleIsNotActive
    case automaticTrustNotApproved
    case insufficientConfirmedSupport
    case providerEvidenceIsNotDurableAndBooked
    case structuredMerchantIdentityRequired
    case phase26ExpenseDebitOnly
    case crossProviderEvidenceRequiresJudgment
    case atmOrCashRequiresJudgment
    case transferRequiresJudgment
    case financingRequiresJudgment
    case foreignExchangeRequiresJudgment
    case refundOrReversalRequiresJudgment
    case unusualCreditRequiresJudgment
    case unresolvedEconomicsRequiresJudgment
    case recurringSettlementRequiresJudgment
    case evidenceResolutionIneligible
    case userReversalSuppression
}

public enum TrustedRulePreviewOutcome: String, Hashable, Sendable, Codable {
    case automaticEligible
    case suggestionOnly
    case blocked
}

public struct TrustedRulePreviewItem: Identifiable, Hashable, Sendable {
    public var id: String { observationID }
    public let observationID: String
    public let outcome: TrustedRulePreviewOutcome
    public let reasons: [String]
}

/// A pure, current-Inbox evaluation. Resolved historical supports are excluded;
/// no document field is mutated while producing this report.
public struct TrustedRulePreview: Hashable, Sendable {
    public let ruleID: String
    public let matchedObservations: [String]
    public let automaticallyEligibleObservations: [String]
    public let suggestionOnlyObservations: [String]
    public let blockedObservations: [TrustedRulePreviewItem]
    public let items: [TrustedRulePreviewItem]
}

public struct TrustedRuleDecision: Identifiable, Hashable, Sendable {
    public var id: String { "trusted-rule-\(ruleID)-\(observationID)" }
    public let ruleID: String
    public let observationID: String
    public let mode: TrustedRuleDecisionMode
    public let confidence: TrustedRuleConfidence
    public let explanation: String
    public let automaticBlockers: [TrustedRuleAutomaticBlocker]
    public let interpretation: TrustedRuleInterpretation
}

public struct TrustedRuleApplication: Hashable, Sendable {
    public let transaction: Transaction
    public let categoryKey: String?
    public let userLabel: String?
    public let auditEvent: TrustedRuleAuditEvent
}

public enum TrustedRuleError: Error, Hashable, Sendable, CustomStringConvertible {
    case duplicateIdentifier(kind: String, id: String)
    case unknownRule(String)
    case invalidRule(id: String, reason: String)
    case invalidSupport(ruleID: String, observationID: String)
    case invalidAuditEvent(String)
    case ruleDoesNotMatchObservation(ruleID: String, observationID: String)
    case automaticResolutionNotAllowed(ruleID: String, blockers: [TrustedRuleAutomaticBlocker])
    case unknownApplication(String)
    case applicationAlreadyReversed(String)
    case evidenceResolutionNotAllowed(ruleID: String, observationID: String, reason: String)
    case unknownSuppression(ruleID: String, observationID: String)

    public var description: String {
        switch self {
        case let .duplicateIdentifier(kind, id): "duplicate \(kind) identifier '\(id)'"
        case let .unknownRule(id): "unknown trusted rule '\(id)'"
        case let .invalidRule(id, reason): "trusted rule '\(id)' is invalid: \(reason)"
        case let .invalidSupport(ruleID, observationID):
            "trusted rule '\(ruleID)' has invalid support from observation '\(observationID)'"
        case let .invalidAuditEvent(id): "trusted rule audit event '\(id)' is invalid"
        case let .ruleDoesNotMatchObservation(ruleID, observationID):
            "trusted rule '\(ruleID)' does not match observation '\(observationID)'"
        case let .automaticResolutionNotAllowed(ruleID, blockers):
            "trusted rule '\(ruleID)' cannot resolve automatically (\(blockers.map(\.rawValue).joined(separator: ", ")))"
        case let .unknownApplication(id): "unknown trusted rule application '\(id)'"
        case let .applicationAlreadyReversed(id): "trusted rule application '\(id)' is already reversed"
        case let .evidenceResolutionNotAllowed(ruleID, observationID, reason):
            "trusted rule '\(ruleID)' cannot resolve observation '\(observationID)': \(reason)"
        case let .unknownSuppression(ruleID, observationID):
            "trusted rule '\(ruleID)' has no active reversal suppression for observation '\(observationID)'"
        }
    }
}

/// Pure matching, trust gating and audited synthetic application. The app does
/// not invoke `applyAutomatically` during bank import in the first Phase 2.6
/// slice; real-data activation remains a separate, explicit stop point.
public enum TrustedRuleEngine {
    public static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    /// Canonical semantic identity, encoded directly rather than through a
    /// process-random or implementation-dependent hash. Each component is
    /// length-prefixed before stable base64url encoding, so delimiters inside a
    /// merchant value or label cannot create collisions.
    public static func semanticFingerprint(
        predicate: TrustedRulePredicate,
        interpretation: TrustedRuleInterpretation
    ) -> String {
        let components: [String?] = [
            "trusted-rule-semantics-v1",
            predicate.provider.rawValue,
            predicate.bindingID,
            predicate.merchantField.rawValue,
            normalized(predicate.merchantValue),
            predicate.direction.rawValue,
            predicate.currencyCode.uppercased(),
            String(predicate.currencyExponent),
            predicate.exactMinorUnits.map(String.init),
            predicate.bankTransactionCode.map(normalized),
            interpretation.transactionKind.rawValue,
            interpretation.categoryKey,
            interpretation.userLabel,
            interpretation.recurringObligationID,
            interpretation.incomeSourceID
        ]
        let canonical = components.map { value -> String in
            guard let value else { return "n" }
            return "s\(value.utf8.count):\(value)"
        }.joined()
        return "trfp1_" + Data(canonical.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func canonicalIdentifier(_ components: [String]) -> String {
        let canonical = components.map { "s\($0.utf8.count):\($0)" }.joined()
        return Data(canonical.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func merchantEvidence(
        _ field: TrustedMerchantEvidenceField,
        from observation: ExternalObservation
    ) -> String? {
        switch field {
        case .structuredMerchantName: observation.structuredMerchantName
        case .merchantEmail: observation.merchantEmail
        case .rawMerchantText: observation.rawMerchantText
        case .remittance: observation.remittance
        }
    }

    public static func matches(_ rule: TrustedRule, observation: ExternalObservation) -> Bool {
        rule.lifecycle == .active && matchesSemantics(rule, observation: observation)
    }

    public static func matchesSemantics(
        _ rule: TrustedRule,
        observation: ExternalObservation
    ) -> Bool {
        let predicate = rule.predicate
        guard observation.provider == predicate.provider,
              observation.bindingID == predicate.bindingID,
              observation.amount.currency.code == predicate.currencyCode,
              observation.amount.currency.minorUnitDigits == predicate.currencyExponent,
              normalized(merchantEvidence(predicate.merchantField, from: observation) ?? "")
                == normalized(predicate.merchantValue),
              normalized(predicate.merchantValue).isEmpty == false
        else { return false }

        switch predicate.direction {
        case .debit:
            guard observation.amount.isNegative,
                  observation.creditDebitIndicator == .debit else { return false }
        case .credit:
            guard observation.amount.isPositive,
                  observation.creditDebitIndicator == .credit else { return false }
        }
        if let exact = predicate.exactMinorUnits, observation.amount.minorUnits != exact { return false }
        if let expectedCode = predicate.bankTransactionCode,
           normalized(observation.bankTransactionCode ?? "") != normalized(expectedCode) { return false }
        return true
    }

    /// Definition-level Phase 2.6 boundary. Passing this gate makes the
    /// automatic-approval control available; observation-specific evidence is
    /// still checked independently on every evaluation/application.
    public static func automaticApprovalBlockers(
        for rule: TrustedRule,
        in document: FinanceDocument
    ) -> [TrustedRuleAutomaticBlocker] {
        var blockers: [TrustedRuleAutomaticBlocker] = []
        func add(_ blocker: TrustedRuleAutomaticBlocker) {
            if !blockers.contains(blocker) { blockers.append(blocker) }
        }

        if independentConfirmedSupportCount(for: rule, in: document) < 2 {
            add(.insufficientConfirmedSupport)
        }
        if rule.predicate.merchantField != .structuredMerchantName {
            add(.structuredMerchantIdentityRequired)
        }
        if rule.predicate.direction != .debit
            || rule.interpretation.transactionKind != .expense
            || (rule.predicate.exactMinorUnits.map { $0 >= 0 } ?? false) {
            add(.phase26ExpenseDebitOnly)
        }
        if rule.interpretation.recurringObligationID != nil {
            add(.recurringSettlementRequiresJudgment)
        }
        if rule.interpretation.incomeSourceID != nil {
            add(.unusualCreditRequiresJudgment)
        }
        if let binding = document.externalAccountBindings.first(where: {
            $0.id == rule.predicate.bindingID
        }), let account = document.accounts.first(where: {
            $0.id == binding.localAccountID
        }) {
            if !binding.isActive
                || account.currency.code != rule.predicate.currencyCode
                || account.currency.minorUnitDigits != rule.predicate.currencyExponent {
                add(.evidenceResolutionIneligible)
            }
        } else {
            add(.evidenceResolutionIneligible)
        }
        addCodeBlockers(rule.predicate.bankTransactionCode ?? "", to: &blockers)
        if let code = rule.predicate.bankTransactionCode,
           !code.uppercased().contains("PURCHASE") {
            add(.unresolvedEconomicsRequiresJudgment)
        }
        return blockers
    }

    private static func observationPolicyBlockers(
        for observation: ExternalObservation,
        in document: FinanceDocument
    ) -> [TrustedRuleAutomaticBlocker] {
        var blockers: [TrustedRuleAutomaticBlocker] = []
        if document.crossProviderCandidates.contains(where: {
            $0.bankObservationID == observation.id || $0.walletObservationID == observation.id
        }) {
            blockers.append(.crossProviderEvidenceRequiresJudgment)
        }
        let code = [observation.bankTransactionCode, observation.bankTransactionSubCode]
            .compactMap { $0 }.joined(separator: "_")
        addCodeBlockers(code, to: &blockers)
        if !code.uppercased().contains("PURCHASE") {
            blockers.append(.unresolvedEconomicsRequiresJudgment)
        }
        return blockers
    }

    private static func addCodeBlockers(
        _ rawCode: String,
        to blockers: inout [TrustedRuleAutomaticBlocker]
    ) {
        let code = rawCode.uppercased()
        func add(_ blocker: TrustedRuleAutomaticBlocker) {
            if !blockers.contains(blocker) { blockers.append(blocker) }
        }
        if ["ATM", "CASH"].contains(where: code.contains) { add(.atmOrCashRequiresJudgment) }
        if ["TRANSFER", "TOPUP", "TOP_UP"].contains(where: code.contains) {
            add(.transferRequiresJudgment)
        }
        if ["FINANC", "INSTALLMENT", "INSTALMENT"].contains(where: code.contains) {
            add(.financingRequiresJudgment)
        }
        if ["EXCHANGE", "FX", "CURRENCY"].contains(where: code.contains) {
            add(.foreignExchangeRequiresJudgment)
        }
        if ["REFUND", "REVERSAL", "CARD_REFUND"].contains(where: code.contains) {
            add(.refundOrReversalRequiresJudgment)
        }
    }

    private static func automaticTransaction(
        for rule: TrustedRule,
        observation: ExternalObservation,
        binding: ExternalAccountBinding,
        id: String
    ) -> Transaction? {
        guard let economicDate = observation.suggestedEconomicDate else { return nil }
        return Transaction(
            id: id,
            date: economicDate,
            kind: rule.interpretation.transactionKind,
            legs: [AccountLeg(accountID: binding.localAccountID, amount: observation.amount)],
            incomeSourceID: rule.interpretation.incomeSourceID,
            factivity: .observed,
            lifecycle: .cleared,
            bookedDate: observation.bookingDate,
            datePrecision: .exact,
            provenance: Provenance(
                source: "TRUSTED-RULE",
                evidenceGrade: .derived,
                reference: rule.id
            )
        )
    }

    private static func sharedEligibilityError(
        rule: TrustedRule,
        observation: ExternalObservation,
        in document: FinanceDocument
    ) -> ExternalEvidenceError? {
        guard let binding = document.externalAccountBindings.first(where: {
            $0.id == observation.bindingID
        }) else { return .unknownBinding(observation.bindingID) }
        guard let transaction = automaticTransaction(
            for: rule,
            observation: observation,
            binding: binding,
            id: "trusted-rule-preview"
        ) else { return .observationNotReviewable(observation.id) }
        do {
            try ExternalEvidenceReview.validateResolutionEligibility(
                ExternalEvidenceAssignment(
                    observationID: observation.id,
                    role: .accountMovement
                ),
                transaction: transaction,
                in: document
            )
            return nil
        } catch let error as ExternalEvidenceError {
            return error
        } catch {
            return .observationNotReviewable(observation.id)
        }
    }

    private static func activeSuppression(
        ruleID: String,
        observationID: String,
        in document: FinanceDocument
    ) -> TrustedRuleObservationSuppression? {
        document.trustedRuleObservationSuppressions.first {
            $0.ruleID == ruleID && $0.observationID == observationID && $0.isActive
        }
    }

    public static func decision(
        for observationID: String,
        rule: TrustedRule,
        in document: FinanceDocument
    ) -> TrustedRuleDecision? {
        guard let observation = document.externalObservations.first(where: { $0.id == observationID }),
              document.observationResolutions.first(where: {
                  $0.observationID == observationID
              })?.state == .unreviewed,
              matches(rule, observation: observation) else { return nil }

        let blockers = automaticBlockers(for: rule, observation: observation, in: document)
        let isSuppressed = activeSuppression(
            ruleID: rule.id, observationID: observation.id, in: document
        ) != nil
        let evidenceBlocked = sharedEligibilityError(
            rule: rule, observation: observation, in: document
        ) != nil
        let automatic = rule.trustLevel == .approvedAutomatic && blockers.isEmpty
        let independentSupports = independentConfirmedSupportCount(for: rule, in: document)
        let confidence: TrustedRuleConfidence = independentSupports >= 2
            && rule.predicate.merchantField == .structuredMerchantName
            ? .high : .medium
        let base = "Exact \(rule.predicate.merchantField.rawValue) match; supported by \(independentSupports) prior explicit confirmation(s)."
        let mode: TrustedRuleDecisionMode = isSuppressed || evidenceBlocked
            ? .blocked : (automatic ? .automaticResolution : .suggestion)
        let explanation: String
        switch mode {
        case .automaticResolution:
            explanation = base + " This rule was explicitly approved and passes the Phase 2.6 expense-debit gate."
        case .suggestion:
            explanation = base + " Human confirmation remains required."
        case .blocked:
            explanation = base + (isSuppressed
                ? " A prior user reversal suppresses reapplication until explicitly re-authorized."
                : " Existing evidence-resolution invariants block application.")
        }
        return TrustedRuleDecision(
            ruleID: rule.id,
            observationID: observation.id,
            mode: mode,
            confidence: confidence,
            explanation: explanation,
            automaticBlockers: blockers,
            interpretation: rule.interpretation
        )
    }

    public static func decisions(
        for observationID: String,
        in document: FinanceDocument
    ) -> [TrustedRuleDecision] {
        document.trustedRules.compactMap { decision(for: observationID, rule: $0, in: document) }
            .sorted {
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                if $0.mode != $1.mode { return $0.mode == .automaticResolution }
                return $0.ruleID < $1.ruleID
            }
    }

    public static func automaticBlockers(
        for rule: TrustedRule,
        observation: ExternalObservation,
        in document: FinanceDocument
    ) -> [TrustedRuleAutomaticBlocker] {
        var blockers: [TrustedRuleAutomaticBlocker] = []
        func add(_ blocker: TrustedRuleAutomaticBlocker) {
            if !blockers.contains(blocker) { blockers.append(blocker) }
        }

        if rule.lifecycle != .active { add(.ruleIsNotActive) }
        if rule.trustLevel != .approvedAutomatic || rule.approvedAt == nil {
            add(.automaticTrustNotApproved)
        }
        for blocker in automaticApprovalBlockers(for: rule, in: document) { add(blocker) }
        if !observation.eligibleForEconomicActual || observation.suggestedEconomicDate == nil {
            add(.providerEvidenceIsNotDurableAndBooked)
        }
        for blocker in observationPolicyBlockers(for: observation, in: document) { add(blocker) }
        if sharedEligibilityError(rule: rule, observation: observation, in: document) != nil {
            add(.evidenceResolutionIneligible)
        }
        if activeSuppression(ruleID: rule.id, observationID: observation.id, in: document) != nil {
            add(.userReversalSuppression)
        }
        return blockers
    }

    public static func preview(
        ruleID: String,
        in document: FinanceDocument
    ) throws -> TrustedRulePreview {
        guard let rule = document.trustedRules.first(where: { $0.id == ruleID }) else {
            throw TrustedRuleError.unknownRule(ruleID)
        }
        let states = Dictionary(
            document.observationResolutions.map { ($0.observationID, $0.state) },
            uniquingKeysWith: { first, _ in first }
        )
        let observations = document.externalObservations.filter { observation in
            guard matchesSemantics(rule, observation: observation) else { return false }
            guard let state = states[observation.id] else { return true }
            return state != .linkedToTransaction && state != .noEconomicEffect
        }
        .sorted { $0.id < $1.id }

        let items = observations.map { observation -> TrustedRulePreviewItem in
            if let suppression = activeSuppression(
                ruleID: rule.id, observationID: observation.id, in: document
            ) {
                return TrustedRulePreviewItem(
                    observationID: observation.id,
                    outcome: .blocked,
                    reasons: ["A prior explicit reversal suppresses this rule for the observation."]
                )
            }
            if let error = sharedEligibilityError(
                rule: rule, observation: observation, in: document
            ) {
                return TrustedRulePreviewItem(
                    observationID: observation.id,
                    outcome: .blocked,
                    reasons: [error.description]
                )
            }
            var blockers = automaticApprovalBlockers(for: rule, in: document)
            for blocker in observationPolicyBlockers(for: observation, in: document)
                where !blockers.contains(blocker) {
                blockers.append(blocker)
            }
            return TrustedRulePreviewItem(
                observationID: observation.id,
                outcome: blockers.isEmpty ? .automaticEligible : .suggestionOnly,
                reasons: blockers.isEmpty
                    ? ["Booked durable expense debit with structured merchant identity, explicit provider purchase semantics, and confirmed support."]
                    : blockers.map(blockerExplanation)
            )
        }
        return TrustedRulePreview(
            ruleID: rule.id,
            matchedObservations: items.map(\.observationID),
            automaticallyEligibleObservations: items.filter {
                $0.outcome == .automaticEligible
            }.map(\.observationID),
            suggestionOnlyObservations: items.filter {
                $0.outcome == .suggestionOnly
            }.map(\.observationID),
            blockedObservations: items.filter { $0.outcome == .blocked },
            items: items
        )
    }

    public static func blockerExplanation(_ blocker: TrustedRuleAutomaticBlocker) -> String {
        switch blocker {
        case .ruleIsNotActive: "The rule is not active."
        case .automaticTrustNotApproved: "Automatic handling has not been explicitly approved."
        case .insufficientConfirmedSupport: "At least two prior explicit confirmations are required."
        case .providerEvidenceIsNotDurableAndBooked: "Provider evidence is not booked and durable."
        case .structuredMerchantIdentityRequired: "Phase 2.6 automatic handling requires structured merchant identity."
        case .phase26ExpenseDebitOnly: "Phase 2.6 automatic handling is limited to expense debits."
        case .crossProviderEvidenceRequiresJudgment: "Cross-provider evidence requires human judgment."
        case .atmOrCashRequiresJudgment: "ATM and cash movements require human judgment."
        case .transferRequiresJudgment: "Transfers and top-ups require human judgment."
        case .financingRequiresJudgment: "Financing and installments require human judgment."
        case .foreignExchangeRequiresJudgment: "Foreign exchange requires human judgment."
        case .refundOrReversalRequiresJudgment: "Refunds and reversals require human judgment."
        case .unusualCreditRequiresJudgment: "Incoming credits and income remain suggestion-only."
        case .unresolvedEconomicsRequiresJudgment: "Unresolved economic meaning requires human judgment."
        case .recurringSettlementRequiresJudgment: "Recurring-obligation settlement remains suggestion-only."
        case .evidenceResolutionIneligible: "Existing evidence-resolution invariants block application."
        case .userReversalSuppression: "A prior user reversal suppresses automatic reapplication."
        }
    }

    /// Detects only first-release automatic-capable merchant expense proposals.
    /// Repeated merchant text is insufficient: every support must be a distinct
    /// durable account movement linked to a distinct user-confirmed economic
    /// transaction with the same structured identity and interpretation.
    public static func proposalCandidates(
        in document: FinanceDocument,
        confirmationMetadata: [TrustedRuleConfirmationMetadata]
    ) -> [TrustedRuleProposal] {
        let metadata = Dictionary(
            confirmationMetadata.map { ($0.transactionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let observations = Dictionary(
            document.externalObservations.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let transactions = Dictionary(
            document.transactions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let resolutions = Dictionary(
            document.observationResolutions.map { ($0.observationID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let bindings = Dictionary(
            document.externalAccountBindings.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let accounts = Dictionary(
            document.accounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let settledTransactions = Set(
            document.planning.settlements.compactMap(\.actualTransactionID)
        )

        var groups: [String: TrustedRuleProposalAccumulator] = [:]
        for link in document.externalEvidenceLinks where link.role == .accountMovement {
            guard let observation = observations[link.observationID],
                  observation.identity == .durable,
                  observation.status == .booked,
                  observation.eligibleForEconomicActual,
                  observation.suggestedEconomicDate != nil,
                  observation.creditDebitIndicator == .debit,
                  observation.amount.isNegative,
                  let merchant = observation.structuredMerchantName?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ), !merchant.isEmpty,
                  let providerCode = observation.bankTransactionCode?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ), !providerCode.isEmpty,
                  let resolution = resolutions[observation.id],
                  resolution.state == .linkedToTransaction,
                  let confirmedAt = resolution.resolvedAt,
                  let transaction = transactions[link.transactionID],
                  transaction.kind == .expense,
                  transaction.factivity == .observed,
                  transaction.lifecycle != .reversed,
                  transaction.provenance.evidenceGrade == .userConfirmed,
                  transaction.ownership?.isEmpty != false,
                  transaction.incomeSourceID == nil,
                  !settledTransactions.contains(transaction.id),
                  let presentation = metadata[transaction.id],
                  let binding = bindings[observation.bindingID],
                  binding.isActive,
                  binding.provider == observation.provider,
                  let account = accounts[binding.localAccountID],
                  account.currency == observation.amount.currency,
                  transaction.legs.count == 1,
                  transaction.legs.contains(where: {
                      $0.accountID == binding.localAccountID
                          && $0.amount == observation.amount
                  }) else { continue }

            let category = normalizedOptional(presentation.categoryKey)
            let label = normalizedOptional(presentation.userLabel)
            let predicate = TrustedRulePredicate(
                provider: observation.provider,
                bindingID: observation.bindingID,
                merchantField: .structuredMerchantName,
                merchantValue: merchant,
                direction: .debit,
                currencyCode: observation.amount.currency.code,
                currencyExponent: observation.amount.currency.minorUnitDigits,
                bankTransactionCode: providerCode
            )
            let interpretation = TrustedRuleInterpretation(
                transactionKind: .expense,
                categoryKey: category,
                userLabel: label
            )
            let fingerprint = semanticFingerprint(
                predicate: predicate,
                interpretation: interpretation
            )
            let support = TrustedRuleSupport(
                observationID: observation.id,
                transactionID: transaction.id,
                confirmedAt: confirmedAt,
                categoryKey: category,
                userLabel: label
            )
            if groups[fingerprint] == nil {
                groups[fingerprint] = TrustedRuleProposalAccumulator(
                    title: label ?? merchant,
                    predicate: predicate,
                    interpretation: interpretation,
                    supports: []
                )
            }
            groups[fingerprint]?.supports.append(support)
        }

        return groups.keys.sorted().compactMap { fingerprint in
            guard var group = groups[fingerprint] else { return nil }
            group.supports.sort {
                ($0.confirmedAt, $0.observationID, $0.transactionID)
                    < ($1.confirmedAt, $1.observationID, $1.transactionID)
            }
            var observations: Set<String> = []
            var transactions: Set<String> = []
            group.supports = group.supports.filter {
                observations.insert($0.observationID).inserted
                    && transactions.insert($0.transactionID).inserted
            }
            let evaluation = TrustedRule(
                id: "proposal-evaluation",
                title: group.title,
                predicate: group.predicate,
                interpretation: group.interpretation,
                supportingConfirmations: group.supports,
                createdAt: group.supports.map(\.confirmedAt).max() ?? .distantPast
            )
            guard independentConfirmedSupportCount(for: evaluation, in: document) >= 2,
                  automaticApprovalBlockers(for: evaluation, in: document).isEmpty else {
                return nil
            }
            return TrustedRuleProposal(
                title: group.title,
                predicate: group.predicate,
                interpretation: group.interpretation,
                supportingConfirmations: group.supports
            )
        }
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    @discardableResult
    public static func addDraft(
        _ rule: TrustedRule,
        auditEventID: String,
        in document: inout FinanceDocument
    ) throws -> TrustedRule {
        guard rule.lifecycle == .draft,
              rule.trustLevel == .suggestionOnly,
              rule.approvedAt == nil,
              rule.disabledAt == nil else {
            throw TrustedRuleError.invalidRule(
                id: rule.id, reason: "new rules must begin as unapproved suggestion-only drafts"
            )
        }
        if let existing = document.trustedRules.first(where: {
            $0.semanticFingerprint == rule.semanticFingerprint
        }) {
            return existing
        }
        var candidate = document
        candidate.trustedRules.append(rule)
        candidate.trustedRuleAuditEvents.append(
            TrustedRuleAuditEvent(
                id: auditEventID,
                ruleID: rule.id,
                ruleSemanticFingerprint: rule.semanticFingerprint,
                kind: .created,
                occurredAt: rule.createdAt,
                explanation: "Drafted from explicit prior confirmations; not active."
            )
        )
        try validate(candidate)
        document = candidate
        return rule
    }

    public static func approve(
        ruleID: String,
        trustLevel: TrustedRuleTrustLevel,
        at date: Date,
        auditEventID: String,
        in document: inout FinanceDocument
    ) throws {
        guard let index = document.trustedRules.firstIndex(where: { $0.id == ruleID }) else {
            throw TrustedRuleError.unknownRule(ruleID)
        }
        guard document.trustedRules[index].lifecycle != .disabled else {
            throw TrustedRuleError.invalidRule(
                id: ruleID,
                reason: "disabled semantics are immutable; create a replacement draft"
            )
        }
        if trustLevel == .approvedAutomatic {
            let blockers = automaticApprovalBlockers(
                for: document.trustedRules[index], in: document
            )
            guard blockers.isEmpty else {
                throw TrustedRuleError.automaticResolutionNotAllowed(
                    ruleID: ruleID, blockers: blockers
                )
            }
        }
        var candidate = document
        candidate.trustedRules[index].trustLevel = trustLevel
        candidate.trustedRules[index].lifecycle = .active
        candidate.trustedRules[index].approvedAt = date
        candidate.trustedRules[index].disabledAt = nil
        candidate.trustedRuleAuditEvents.append(
            TrustedRuleAuditEvent(
                id: auditEventID,
                ruleID: ruleID,
                ruleSemanticFingerprint: candidate.trustedRules[index].semanticFingerprint,
                kind: trustLevel == .approvedAutomatic
                    ? .approvedForAutomaticResolution : .approvedForSuggestions,
                occurredAt: date,
                explanation: trustLevel == .approvedAutomatic
                    ? "User explicitly approved automatic resolution."
                    : "User explicitly approved suggestion-only matching."
            )
        )
        try validate(candidate)
        document = candidate
    }

    public static func disable(
        ruleID: String,
        at date: Date,
        auditEventID: String,
        in document: inout FinanceDocument
    ) throws {
        guard let index = document.trustedRules.firstIndex(where: { $0.id == ruleID }) else {
            throw TrustedRuleError.unknownRule(ruleID)
        }
        var candidate = document
        candidate.trustedRules[index].lifecycle = .disabled
        candidate.trustedRules[index].disabledAt = date
        candidate.trustedRuleAuditEvents.append(
            TrustedRuleAuditEvent(
                id: auditEventID,
                ruleID: ruleID,
                ruleSemanticFingerprint: candidate.trustedRules[index].semanticFingerprint,
                kind: .disabled,
                occurredAt: date,
                explanation: "User disabled the rule; prior reviews were left unchanged."
            )
        )
        try validate(candidate)
        document = candidate
    }

    /// Applies only a decision already proven eligible for automatic
    /// resolution. This pure domain operation is exercised with synthetic test
    /// documents but is not called by real bank import in this phase slice.
    public static func applyAutomatically(
        ruleID: String,
        observationID: String,
        at date: Date,
        in document: inout FinanceDocument
    ) throws -> TrustedRuleApplication {
        guard let rule = document.trustedRules.first(where: { $0.id == ruleID }) else {
            throw TrustedRuleError.unknownRule(ruleID)
        }
        if let existingEvent = document.trustedRuleAuditEvents.first(where: { event in
            event.ruleID == ruleID
                && event.observationID == observationID
                && event.kind == .automaticallyResolved
                && !document.trustedRuleAuditEvents.contains(where: {
                    $0.kind == .reversed && $0.sourceAuditEventID == event.id
                })
        }) {
            guard let transactionID = existingEvent.transactionID,
                  let transaction = document.transactions.first(where: {
                      $0.id == transactionID
                  }),
                  transaction.lifecycle != .reversed,
                  document.externalEvidenceLinks.filter({
                      $0.observationID == observationID
                          && $0.transactionID == transactionID
                          && $0.role == .accountMovement
                  }).count == 1,
                  document.observationResolutions.first(where: {
                      $0.observationID == observationID
                  })?.state == .linkedToTransaction else {
                throw TrustedRuleError.invalidAuditEvent(existingEvent.id)
            }
            return TrustedRuleApplication(
                transaction: transaction,
                categoryKey: rule.interpretation.categoryKey,
                userLabel: rule.interpretation.userLabel,
                auditEvent: existingEvent
            )
        }
        guard let observation = document.externalObservations.first(where: { $0.id == observationID }),
              matches(rule, observation: observation) else {
            throw TrustedRuleError.ruleDoesNotMatchObservation(ruleID: ruleID, observationID: observationID)
        }
        if let error = sharedEligibilityError(
            rule: rule, observation: observation, in: document
        ) {
            throw TrustedRuleError.evidenceResolutionNotAllowed(
                ruleID: ruleID,
                observationID: observationID,
                reason: error.description
            )
        }
        guard let decision = decision(for: observationID, rule: rule, in: document) else {
            throw TrustedRuleError.ruleDoesNotMatchObservation(
                ruleID: ruleID, observationID: observationID
            )
        }
        guard decision.mode == .automaticResolution else {
            throw TrustedRuleError.automaticResolutionNotAllowed(
                ruleID: ruleID, blockers: decision.automaticBlockers
            )
        }
        guard let binding = document.externalAccountBindings.first(where: { $0.id == observation.bindingID }) else {
            throw TrustedRuleError.invalidRule(id: ruleID, reason: "unknown binding")
        }
        let attempt = document.trustedRuleAuditEvents.filter {
            $0.ruleID == ruleID
                && $0.observationID == observationID
                && $0.kind == .automaticallyResolved
        }.count + 1
        let applicationIdentity = canonicalIdentifier([
            rule.semanticFingerprint, observation.id, String(attempt)
        ])
        guard let transaction = automaticTransaction(
            for: rule,
            observation: observation,
            binding: binding,
            id: "trusted-rule-transaction-\(applicationIdentity)"
        ) else {
            throw TrustedRuleError.invalidRule(id: ruleID, reason: "automatic resolution requires an evidence-backed date")
        }
        var candidate = document
        try ExternalEvidenceReview.createTransaction(
            transaction,
            evidence: [ExternalEvidenceAssignment(
                observationID: observation.id, role: .accountMovement
            )],
            resolvedAt: date,
            in: &candidate
        )
        let event = TrustedRuleAuditEvent(
            id: "trusted-rule-application-\(applicationIdentity)",
            ruleID: rule.id,
            ruleSemanticFingerprint: rule.semanticFingerprint,
            kind: .automaticallyResolved,
            occurredAt: date,
            observationID: observation.id,
            transactionID: transaction.id,
            explanation: decision.explanation
        )
        candidate.trustedRuleAuditEvents.append(event)
        try validate(candidate)
        document = candidate
        return TrustedRuleApplication(
            transaction: transaction,
            categoryKey: rule.interpretation.categoryKey,
            userLabel: rule.interpretation.userLabel,
            auditEvent: event
        )
    }

    /// Explicit reversal keeps the transaction as a `.reversed` historical
    /// record, removes its evidence link, returns the observation to review,
    /// and appends a reversal event. Nothing is silently rewritten.
    public static func reverseApplication(
        auditEventID applicationID: String,
        reversalEventID: String,
        at date: Date,
        in document: inout FinanceDocument
    ) throws -> Transaction {
        guard let application = document.trustedRuleAuditEvents.first(where: {
            $0.id == applicationID && $0.kind == .automaticallyResolved
        }), let transactionID = application.transactionID,
              let observationID = application.observationID else {
            throw TrustedRuleError.unknownApplication(applicationID)
        }
        guard !document.trustedRuleAuditEvents.contains(where: {
            $0.kind == .reversed && $0.sourceAuditEventID == applicationID
        }) else { throw TrustedRuleError.applicationAlreadyReversed(applicationID) }
        guard let transactionIndex = document.transactions.firstIndex(where: { $0.id == transactionID }),
              let resolutionIndex = document.observationResolutions.firstIndex(where: {
                  $0.observationID == observationID
              }) else { throw TrustedRuleError.unknownApplication(applicationID) }

        var candidate = document
        let previous = candidate.transactions[transactionIndex]
        candidate.transactions[transactionIndex] = Transaction(
            id: previous.id,
            date: previous.date,
            kind: previous.kind,
            legs: previous.legs,
            ownership: previous.ownership,
            linkedTransactionID: previous.linkedTransactionID,
            incomeSourceID: previous.incomeSourceID,
            installmentPlanID: previous.installmentPlanID,
            factivity: previous.factivity,
            lifecycle: .reversed,
            bookedDate: previous.bookedDate,
            datePrecision: previous.datePrecision,
            certainty: previous.certainty,
            note: previous.note,
            provenance: previous.provenance
        )
        candidate.externalEvidenceLinks.removeAll {
            $0.transactionID == transactionID && $0.observationID == observationID
        }
        candidate.observationResolutions[resolutionIndex].state = .unreviewed
        candidate.observationResolutions[resolutionIndex].resolvedAt = nil
        candidate.trustedRuleAuditEvents.append(
            TrustedRuleAuditEvent(
                id: reversalEventID,
                ruleID: application.ruleID,
                ruleSemanticFingerprint: application.ruleSemanticFingerprint,
                kind: .reversed,
                occurredAt: date,
                observationID: observationID,
                transactionID: transactionID,
                sourceAuditEventID: applicationID,
                explanation: "User reversed the automatic resolution; the observation returned to review and this rule is suppressed for it."
            )
        )
        let suppressionID = "trusted-rule-suppression-" + canonicalIdentifier([
            application.ruleID, observationID, reversalEventID
        ])
        candidate.trustedRuleObservationSuppressions.append(
            TrustedRuleObservationSuppression(
                id: suppressionID,
                ruleID: application.ruleID,
                observationID: observationID,
                applicationAuditEventID: applicationID,
                reversalAuditEventID: reversalEventID,
                createdAt: date
            )
        )
        try ExternalEvidenceReview.validate(candidate)
        document = candidate
        return previous
    }

    /// Explicitly lifts one active per-observation reversal veto. This does not
    /// apply the rule; it only makes a later separately authorized evaluation
    /// possible and records that choice in the append-only audit.
    public static func clearReapplicationSuppression(
        ruleID: String,
        observationID: String,
        at date: Date,
        auditEventID: String,
        in document: inout FinanceDocument
    ) throws {
        guard let index = document.trustedRuleObservationSuppressions.firstIndex(where: {
            $0.ruleID == ruleID && $0.observationID == observationID && $0.isActive
        }) else {
            throw TrustedRuleError.unknownSuppression(
                ruleID: ruleID, observationID: observationID
            )
        }
        guard let rule = document.trustedRules.first(where: { $0.id == ruleID }) else {
            throw TrustedRuleError.unknownRule(ruleID)
        }
        var candidate = document
        let suppression = candidate.trustedRuleObservationSuppressions[index]
        candidate.trustedRuleObservationSuppressions[index].clearedAt = date
        candidate.trustedRuleObservationSuppressions[index].clearAuditEventID = auditEventID
        candidate.trustedRuleAuditEvents.append(
            TrustedRuleAuditEvent(
                id: auditEventID,
                ruleID: ruleID,
                ruleSemanticFingerprint: rule.semanticFingerprint,
                kind: .reapplicationAuthorized,
                occurredAt: date,
                observationID: observationID,
                sourceAuditEventID: suppression.reversalAuditEventID,
                explanation: "User explicitly cleared the prior reversal suppression; nothing was applied."
            )
        )
        try ExternalEvidenceReview.validate(candidate)
        document = candidate
    }

    public static func validate(_ document: FinanceDocument) throws {
        try unique(document.trustedRules.map(\.id), kind: "trusted rule")
        try unique(
            document.trustedRules.map(\.semanticFingerprint),
            kind: "trusted rule semantic fingerprint"
        )
        try unique(document.trustedRuleAuditEvents.map(\.id), kind: "trusted rule audit event")
        try unique(
            document.trustedRuleObservationSuppressions.map(\.id),
            kind: "trusted rule observation suppression"
        )
        let rules = Dictionary(uniqueKeysWithValues: document.trustedRules.map { ($0.id, $0) })

        for rule in document.trustedRules {
            guard !normalized(rule.title).isEmpty,
                  !normalized(rule.predicate.merchantValue).isEmpty,
                  document.externalAccountBindings.contains(where: {
                      $0.id == rule.predicate.bindingID && $0.provider == rule.predicate.provider
                  }) else {
                throw TrustedRuleError.invalidRule(id: rule.id, reason: "title, merchant identity, and binding are required")
            }
            if rule.lifecycle == .draft {
                guard rule.approvedAt == nil, rule.disabledAt == nil else {
                    throw TrustedRuleError.invalidRule(id: rule.id, reason: "a draft cannot carry approval or disablement")
                }
            } else if rule.lifecycle == .active {
                guard rule.approvedAt != nil, rule.disabledAt == nil else {
                    throw TrustedRuleError.invalidRule(id: rule.id, reason: "an active rule requires explicit approval")
                }
            } else if rule.disabledAt == nil {
                throw TrustedRuleError.invalidRule(id: rule.id, reason: "a disabled rule requires a disablement time")
            }
            if rule.interpretation.transactionKind == .income {
                guard let sourceID = rule.interpretation.incomeSourceID,
                      document.incomeSources.contains(where: { $0.id == sourceID }) else {
                    throw TrustedRuleError.invalidRule(id: rule.id, reason: "income requires an existing economic source")
                }
            } else if rule.interpretation.incomeSourceID != nil {
                throw TrustedRuleError.invalidRule(id: rule.id, reason: "economic source is valid only for income")
            }
            if let obligationID = rule.interpretation.recurringObligationID,
               !document.planning.recurringObligations.contains(where: { $0.id == obligationID }) {
                throw TrustedRuleError.invalidRule(id: rule.id, reason: "unknown recurring obligation")
            }

            var seenSupport: Set<String> = []
            var seenAccountMovements: Set<String> = []
            var seenEconomicEvents: Set<String> = []
            for support in rule.supportingConfirmations {
                guard seenSupport.insert(support.id).inserted,
                      seenAccountMovements.insert(support.observationID).inserted,
                      seenEconomicEvents.insert(support.transactionID).inserted,
                      support.confirmedAt <= rule.createdAt,
                      let observation = document.externalObservations.first(where: {
                          $0.id == support.observationID
                      }),
                      observation.identity == .durable,
                      let transaction = document.transactions.first(where: {
                          $0.id == support.transactionID
                      }),
                      matchesIgnoringLifecycle(rule, observation: observation),
                      transaction.kind == rule.interpretation.transactionKind,
                      transaction.lifecycle != .reversed,
                      transaction.provenance.evidenceGrade == .userConfirmed,
                      transaction.ownership?.isEmpty != false,
                      transaction.incomeSourceID == rule.interpretation.incomeSourceID,
                      support.categoryKey == rule.interpretation.categoryKey,
                      support.userLabel == rule.interpretation.userLabel,
                      document.externalEvidenceLinks.contains(where: {
                          $0.observationID == support.observationID
                              && $0.transactionID == support.transactionID
                              && $0.role == .accountMovement
                      }) else {
                    throw TrustedRuleError.invalidSupport(
                        ruleID: rule.id, observationID: support.observationID
                    )
                }
            }
            if rule.supportingConfirmations.isEmpty {
                throw TrustedRuleError.invalidRule(id: rule.id, reason: "a rule requires prior confirmations")
            }
            if rule.trustLevel == .approvedAutomatic && rule.lifecycle == .active {
                let semanticBlockers = automaticApprovalBlockers(
                    for: rule, in: document
                ).filter { $0 != .evidenceResolutionIneligible }
                guard semanticBlockers.isEmpty else {
                    throw TrustedRuleError.invalidRule(
                        id: rule.id,
                        reason: "automatic trust violates Phase 2.6 policy: \(semanticBlockers.map(\.rawValue).joined(separator: ", "))"
                    )
                }
            }
        }

        for event in document.trustedRuleAuditEvents {
            guard let auditedRule = rules[event.ruleID],
                  event.ruleSemanticFingerprint == auditedRule.semanticFingerprint else {
                throw TrustedRuleError.invalidAuditEvent(event.id)
            }
            switch event.kind {
            case .automaticallyResolved:
                guard let observationID = event.observationID,
                      let transactionID = event.transactionID,
                      document.externalObservations.contains(where: { $0.id == observationID }),
                      document.transactions.contains(where: { $0.id == transactionID }) else {
                    throw TrustedRuleError.invalidAuditEvent(event.id)
                }
            case .reversed:
                guard let source = event.sourceAuditEventID,
                      document.trustedRuleAuditEvents.contains(where: {
                          $0.id == source && $0.kind == .automaticallyResolved
                      }) else { throw TrustedRuleError.invalidAuditEvent(event.id) }
            case .reapplicationAuthorized:
                guard let observationID = event.observationID,
                      let source = event.sourceAuditEventID,
                      document.trustedRuleAuditEvents.contains(where: {
                          $0.id == source && $0.kind == .reversed
                      }),
                      document.externalObservations.contains(where: {
                          $0.id == observationID
                      }) else { throw TrustedRuleError.invalidAuditEvent(event.id) }
            case .created, .approvedForSuggestions, .approvedForAutomaticResolution, .disabled:
                break
            }
        }

        for suppression in document.trustedRuleObservationSuppressions {
            guard rules[suppression.ruleID] != nil,
                  document.externalObservations.contains(where: {
                      $0.id == suppression.observationID
                  }),
                  let application = document.trustedRuleAuditEvents.first(where: {
                      $0.id == suppression.applicationAuditEventID
                          && $0.kind == .automaticallyResolved
                          && $0.ruleID == suppression.ruleID
                          && $0.observationID == suppression.observationID
                  }),
                  document.trustedRuleAuditEvents.contains(where: {
                      $0.id == suppression.reversalAuditEventID
                          && $0.kind == .reversed
                          && $0.sourceAuditEventID == application.id
                  }),
                  (suppression.clearedAt == nil) == (suppression.clearAuditEventID == nil)
            else { throw TrustedRuleError.invalidAuditEvent(suppression.id) }
            if let clearID = suppression.clearAuditEventID {
                guard document.trustedRuleAuditEvents.contains(where: {
                    $0.id == clearID
                        && $0.kind == .reapplicationAuthorized
                        && $0.ruleID == suppression.ruleID
                        && $0.observationID == suppression.observationID
                        && $0.sourceAuditEventID == suppression.reversalAuditEventID
                        && $0.occurredAt == suppression.clearedAt
                }) else { throw TrustedRuleError.invalidAuditEvent(suppression.id) }
            }
        }
        try unique(
            document.trustedRuleObservationSuppressions.filter(\.isActive).map {
                "\($0.ruleID)->\($0.observationID)"
            },
            kind: "active trusted rule observation suppression"
        )

        for reversal in document.trustedRuleAuditEvents where reversal.kind == .reversed {
            guard document.trustedRuleObservationSuppressions.filter({
                $0.reversalAuditEventID == reversal.id
            }).count == 1 else { throw TrustedRuleError.invalidAuditEvent(reversal.id) }
        }

        let automaticEvents = document.trustedRuleAuditEvents.filter {
            $0.kind == .automaticallyResolved
        }
        for event in automaticEvents {
            let reversed = document.trustedRuleAuditEvents.contains {
                $0.kind == .reversed && $0.sourceAuditEventID == event.id
            }
            guard let transactionID = event.transactionID,
                  let transaction = document.transactions.first(where: {
                      $0.id == transactionID
                  }),
                  transaction.provenance.evidenceGrade == .derived,
                  transaction.provenance.reference == event.ruleID
            else { throw TrustedRuleError.invalidAuditEvent(event.id) }
            if reversed {
                guard transaction.lifecycle == .reversed else {
                    throw TrustedRuleError.invalidAuditEvent(event.id)
                }
            } else {
                guard let observationID = event.observationID,
                      transaction.lifecycle != .reversed,
                      document.externalEvidenceLinks.filter({
                          $0.observationID == observationID
                              && $0.transactionID == transactionID
                              && $0.role == .accountMovement
                      }).count == 1 else {
                    throw TrustedRuleError.invalidAuditEvent(event.id)
                }
            }
        }
        let activeApplicationKeys = automaticEvents.filter { event in
            !document.trustedRuleAuditEvents.contains {
                $0.kind == .reversed && $0.sourceAuditEventID == event.id
            }
        }.map { "\($0.ruleID)->\($0.observationID ?? "")" }
        try unique(activeApplicationKeys, kind: "active trusted rule application")

        for rule in document.trustedRules {
            guard document.trustedRuleAuditEvents.filter({
                $0.ruleID == rule.id && $0.kind == .created && $0.occurredAt == rule.createdAt
            }).count == 1 else {
                throw TrustedRuleError.invalidRule(id: rule.id, reason: "exactly one creation audit event is required")
            }
            if rule.lifecycle == .active {
                let expected: TrustedRuleAuditKind = rule.trustLevel == .approvedAutomatic
                    ? .approvedForAutomaticResolution : .approvedForSuggestions
                guard document.trustedRuleAuditEvents.contains(where: {
                    $0.ruleID == rule.id && $0.kind == expected && $0.occurredAt == rule.approvedAt
                }) else {
                    throw TrustedRuleError.invalidRule(id: rule.id, reason: "approval audit does not match active trust")
                }
            }
            if rule.lifecycle == .disabled {
                guard document.trustedRuleAuditEvents.contains(where: {
                    $0.ruleID == rule.id && $0.kind == .disabled && $0.occurredAt == rule.disabledAt
                }) else {
                    throw TrustedRuleError.invalidRule(id: rule.id, reason: "disablement audit is required")
                }
            }
        }
    }

    /// One independent confirmation is one durable account-movement observation
    /// linked as `accountMovement` to one user-confirmed economic transaction.
    /// Support *rows* are not independence: two evidence rows of the same
    /// transaction, or two confirmations of the same observation, count as one.
    static func independentConfirmedSupportCount(
        for rule: TrustedRule,
        in document: FinanceDocument
    ) -> Int {
        var accountMovements: Set<String> = []
        var economicEvents: Set<String> = []
        for support in rule.supportingConfirmations {
            guard let observation = document.externalObservations.first(where: {
                $0.id == support.observationID
            }), observation.identity == .durable,
                  let transaction = document.transactions.first(where: {
                      $0.id == support.transactionID
                  }),
                  transaction.lifecycle != .reversed,
                  transaction.provenance.evidenceGrade == .userConfirmed,
                  document.externalEvidenceLinks.contains(where: {
                      $0.observationID == support.observationID
                          && $0.transactionID == support.transactionID
                          && $0.role == .accountMovement
                  }) else { continue }
            accountMovements.insert(observation.id)
            economicEvents.insert(transaction.id)
        }
        return min(accountMovements.count, economicEvents.count)
    }

    private static func matchesIgnoringLifecycle(
        _ rule: TrustedRule,
        observation: ExternalObservation
    ) -> Bool {
        matchesSemantics(rule, observation: observation)
    }

    private static func unique(_ ids: [String], kind: String) throws {
        var seen: Set<String> = []
        for id in ids where !seen.insert(id).inserted {
            throw TrustedRuleError.duplicateIdentifier(kind: kind, id: id)
        }
    }
}
