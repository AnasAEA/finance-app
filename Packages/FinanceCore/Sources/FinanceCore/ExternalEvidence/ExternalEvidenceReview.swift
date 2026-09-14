import Foundation

public enum ExternalEvidenceError: Error, Hashable, Sendable, CustomStringConvertible {
    case duplicateIdentifier(kind: String, id: String)
    case unknownBinding(String)
    case providerBindingMismatch(observationID: String)
    case balanceProviderBindingMismatch(String)
    case invalidDerivedDateProvenance(String)
    case unknownLocalAccount(String)
    case inactiveBinding(String)
    case accountCurrencyMismatch(observationID: String, accountID: String)
    case unknownObservation(String)
    case unknownTransaction(String)
    case missingResolution(String)
    case duplicateResolution(String)
    case observationNotReviewable(String)
    case observationAlreadyResolved(String)
    case linkConflictsWithResolution(String)
    case observationLinkedToMultipleTransactions(String)
    case duplicateAccountMovementLink(String)
    case accountMovementDoesNotMatchLeg(observationID: String, transactionID: String)
    case invalidCandidate(String)
    case invalidRecurringSettlement(String)
    case invalidTrustedRule(String)

    public var description: String {
        switch self {
        case let .duplicateIdentifier(kind, id): "duplicate \(kind) identifier '\(id)'"
        case let .unknownBinding(id): "unknown external account binding '\(id)'"
        case let .providerBindingMismatch(id): "observation '\(id)' does not match its binding provider"
        case let .balanceProviderBindingMismatch(id):
            "provider balance '\(id)' does not match its binding provider"
        case let .invalidDerivedDateProvenance(id):
            "observation '\(id)' must keep a derived date and its provenance together"
        case let .unknownLocalAccount(id): "external binding points to unknown local account '\(id)'"
        case let .inactiveBinding(id): "external account binding '\(id)' is inactive"
        case let .accountCurrencyMismatch(observationID, accountID):
            "observation '\(observationID)' currency does not match local account '\(accountID)'"
        case let .unknownObservation(id): "unknown external observation '\(id)'"
        case let .unknownTransaction(id): "unknown economic transaction '\(id)'"
        case let .missingResolution(id): "observation '\(id)' has no explicit resolution state"
        case let .duplicateResolution(id): "observation '\(id)' has more than one resolution state"
        case let .observationNotReviewable(id): "observation '\(id)' is not eligible for economic review"
        case let .observationAlreadyResolved(id): "observation '\(id)' is already resolved"
        case let .linkConflictsWithResolution(id): "observation '\(id)' links and resolution state disagree"
        case let .observationLinkedToMultipleTransactions(id):
            "observation '\(id)' cannot support more than one economic transaction in this schema"
        case let .duplicateAccountMovementLink(id):
            "observation '\(id)' cannot be account-movement evidence twice"
        case let .accountMovementDoesNotMatchLeg(observationID, transactionID):
            "observation '\(observationID)' does not match an account leg of '\(transactionID)'"
        case let .invalidCandidate(id): "cross-provider candidate '\(id)' is not structurally valid"
        case let .invalidRecurringSettlement(reason): "recurring settlement is invalid: \(reason)"
        case let .invalidTrustedRule(reason): "trusted rule is invalid: \(reason)"
        }
    }
}

public struct ExternalEvidenceAssignment: Hashable, Sendable {
    public let observationID: String
    public let role: ExternalEvidenceRole

    public init(observationID: String, role: ExternalEvidenceRole) {
        self.observationID = observationID
        self.role = role
    }
}

public enum ExternalSuggestionKind: String, Hashable, Sendable {
    case recurringExpectation
    case existingTransaction
    case crossProviderEvidence
    case likelyTransfer
    case atmCashMovement
    case refundOrReversal
    case merchantUnresolved
    case trustedRule
}

public enum ExternalSuggestionConfidence: String, Hashable, Sendable, Comparable {
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// A proposal only. No suggestion method mutates a document.
public struct ExternalObservationSuggestion: Identifiable, Hashable, Sendable {
    public let id: String
    public let observationID: String
    public let kind: ExternalSuggestionKind
    public let title: String
    public let targetTransactionID: String?
    public let targetOccurrence: OccurrenceID?
    public let relatedObservationID: String?
    public let explanation: String?
    public let confidence: ExternalSuggestionConfidence
    public let trustedRuleID: String?
    public let automaticResolutionEligible: Bool

    public init(
        id: String,
        observationID: String,
        kind: ExternalSuggestionKind,
        title: String,
        targetTransactionID: String? = nil,
        targetOccurrence: OccurrenceID? = nil,
        relatedObservationID: String? = nil,
        explanation: String? = nil,
        confidence: ExternalSuggestionConfidence = .medium,
        trustedRuleID: String? = nil,
        automaticResolutionEligible: Bool = false
    ) {
        self.id = id
        self.observationID = observationID
        self.kind = kind
        self.title = title
        self.targetTransactionID = targetTransactionID
        self.targetOccurrence = targetOccurrence
        self.relatedObservationID = relatedObservationID
        self.explanation = explanation
        self.confidence = confidence
        self.trustedRuleID = trustedRuleID
        self.automaticResolutionEligible = automaticResolutionEligible
    }
}

/// Import, validation and explicit resolution of provider evidence.
public enum ExternalEvidenceReview {

    /// Idempotently imports one local/provider feed. It never creates a
    /// transaction and never updates a ledger balance.
    public static func importBatch(_ batch: ExternalEvidenceBatch, into document: inout FinanceDocument) throws {
        var candidate = document
        let bindings = Dictionary(
            candidate.externalAccountBindings.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for observation in batch.observations {
            guard let binding = bindings[observation.bindingID] else {
                throw ExternalEvidenceError.unknownBinding(observation.bindingID)
            }
            guard binding.provider == observation.provider else {
                throw ExternalEvidenceError.providerBindingMismatch(observationID: observation.id)
            }

            if let index = candidate.externalObservations.firstIndex(where: { $0.id == observation.id }) {
                let existing = candidate.externalObservations[index]
                guard existing.bindingID == observation.bindingID else {
                    throw ExternalEvidenceError.duplicateIdentifier(kind: "observation", id: observation.id)
                }
                // Repeated syncs are an upsert of the same backend identity. A
                // person's decision is never undone by a later sync.
                if observation.observedAt >= existing.observedAt {
                    candidate.externalObservations[index] = observation
                    reclassifyIfUnresolved(
                        observation,
                        binding: binding,
                        in: &candidate
                    )
                }
            } else {
                candidate.externalObservations.append(observation)
                candidate.observationResolutions.append(
                    ExternalObservationResolution(
                        observationID: observation.id,
                        state: initialResolution(for: observation, binding: binding)
                    )
                )
            }
        }

        for balance in batch.balances {
            guard let binding = bindings[balance.bindingID] else {
                throw ExternalEvidenceError.unknownBinding(balance.bindingID)
            }
            guard binding.provider == balance.provider else {
                throw ExternalEvidenceError.balanceProviderBindingMismatch(balance.id)
            }
            if let index = candidate.providerBalanceSnapshots.firstIndex(where: { $0.id == balance.id }) {
                candidate.providerBalanceSnapshots[index] = balance
            } else {
                candidate.providerBalanceSnapshots.append(balance)
            }
        }

        for crossProvider in batch.candidates {
            if let index = candidate.crossProviderCandidates.firstIndex(where: { $0.id == crossProvider.id }) {
                candidate.crossProviderCandidates[index] = crossProvider
            } else {
                candidate.crossProviderCandidates.append(crossProvider)
            }
        }

        try validate(candidate)
        document = candidate
    }

    /// A provider may withdraw a row it previously reported as booked.
    ///
    /// The two cases are not symmetrical. An observation nobody has acted on
    /// yet should simply leave the queue — leaving it in New offers actions
    /// that are guaranteed to fail. An observation someone already resolved
    /// keeps its resolution: the person saw real money move and recorded what
    /// it meant, and a later provider status change is new evidence about the
    /// bank's bookkeeping, not grounds for the app to silently retract their
    /// decision or delete their transaction. That case surfaces as a warning
    /// instead — see `providerStatusWarnings(in:)`.
    private static func reclassifyIfUnresolved(
        _ observation: ExternalObservation,
        binding: ExternalAccountBinding,
        in document: inout FinanceDocument
    ) {
        guard let index = document.observationResolutions.firstIndex(where: {
                  $0.observationID == observation.id
              }),
              document.observationResolutions[index].state != .linkedToTransaction,
              document.observationResolutions[index].state != .noEconomicEffect
        else { return }
        document.observationResolutions[index].state = initialResolution(
            for: observation,
            binding: binding
        )
        document.observationResolutions[index].resolvedAt = nil
    }

    /// Observations whose economic resolution now disagrees with what the
    /// provider currently reports.
    ///
    /// Read-only and derived. Nothing is unlinked, no transaction is removed,
    /// and no resolution is rewritten; this only tells a person where their
    /// record and the bank's have diverged, which is the one place a human
    /// needs to look.
    public static func providerStatusWarnings(in document: FinanceDocument) -> [String] {
        let resolved = Set(
            document.observationResolutions
                .filter { $0.state == .linkedToTransaction || $0.state == .noEconomicEffect }
                .map(\.observationID)
        )
        return document.externalObservations
            .filter { resolved.contains($0.id) && !$0.eligibleForEconomicActual }
            .map(\.id)
            .sorted()
    }

    /// Strictly later than the binding boundary is reviewable. Booking date is
    /// used first because the opening ledger balance is an account balance.
    public static func initialResolution(
        for observation: ExternalObservation,
        binding: ExternalAccountBinding
    ) -> ObservationResolutionState {
        if observation.identity == .provisionalSnapshot || observation.status == .pending {
            return .provisional
        }
        guard observation.eligibleForEconomicActual else {
            return .economicallyIneligible
        }
        guard let date = observation.cutoverComparisonDate,
              date > binding.syncStartBoundary else {
            return .outsideSyncBoundary
        }
        return .unreviewed
    }

    public static func reviewQueue(in document: FinanceDocument) -> [ExternalObservation] {
        let state = Dictionary(
            document.observationResolutions.map { ($0.observationID, $0.state) },
            uniquingKeysWith: { first, _ in first }
        )
        let activeBindings = Set(document.externalAccountBindings.filter(\.isActive).map(\.id))
        return document.externalObservations
            .filter {
                state[$0.id] == .unreviewed
                    && $0.eligibleForEconomicActual
                    && activeBindings.contains($0.bindingID)
            }
            .sorted {
                ($0.cutoverComparisonDate ?? Day(year: 1, month: 1, day: 1), $0.id)
                    > ($1.cutoverComparisonDate ?? Day(year: 1, month: 1, day: 1), $1.id)
            }
    }

    /// Links one or many observations to an existing transaction. This cannot
    /// create a duplicate actual because no transaction is appended.
    public static func linkExistingTransaction(
        transactionID: String,
        evidence: [ExternalEvidenceAssignment],
        resolvedAt: Date,
        in document: inout FinanceDocument
    ) throws {
        var candidate = document
        guard let transaction = candidate.transactions.first(where: { $0.id == transactionID }) else {
            throw ExternalEvidenceError.unknownTransaction(transactionID)
        }
        try appendLinks(evidence, transaction: transaction, resolvedAt: resolvedAt, to: &candidate)
        try validate(candidate)
        document = candidate
    }

    /// Creates exactly one economic transaction and attaches all explicitly
    /// confirmed evidence to it. An optional occurrence is settled in the same
    /// mutation, so an actual can never be created while its recurring payment
    /// is accidentally left due.
    public static func createTransaction(
        _ transaction: Transaction,
        evidence: [ExternalEvidenceAssignment],
        settling occurrence: OccurrenceID? = nil,
        resolvedAt: Date,
        in document: inout FinanceDocument
    ) throws {
        var candidate = document
        guard !candidate.transactions.contains(where: { $0.id == transaction.id }) else {
            throw ExternalEvidenceError.duplicateIdentifier(kind: "transaction", id: transaction.id)
        }
        guard transaction.factivity == .observed, transaction.lifecycle != .pending else {
            throw ExternalEvidenceError.observationNotReviewable(evidence.first?.observationID ?? "")
        }
        candidate.transactions.append(transaction)
        try appendLinks(evidence, transaction: transaction, resolvedAt: resolvedAt, to: &candidate)

        if let occurrence {
            candidate.planning.settlements.append(
                .paid(
                    id: "settle-\(occurrence.description)",
                    obligationID: occurrence.obligationID,
                    expectedDay: occurrence.expectedDay,
                    actualTransactionID: transaction.id,
                    provenance: Provenance(
                        source: "EXTERNAL-EVIDENCE-REVIEW",
                        evidenceGrade: .userConfirmed
                    )
                )
            )
            do {
                try ReconciliationLedger.validate(candidate.planning.settlements, against: candidate)
            } catch let error as ReconciliationError {
                throw ExternalEvidenceError.invalidRecurringSettlement(error.description)
            }
        }

        try validate(candidate)
        document = candidate
    }

    /// The single eligibility path used before either a manual or an automatic
    /// evidence assignment. Callers may impose stricter policy, but neither is
    /// allowed to weaken these evidence invariants.
    public static func validateResolutionEligibility(
        _ assignment: ExternalEvidenceAssignment,
        transaction: Transaction,
        in document: FinanceDocument
    ) throws {
        guard let observation = document.externalObservations.first(where: {
            $0.id == assignment.observationID
        }) else {
            throw ExternalEvidenceError.unknownObservation(assignment.observationID)
        }
        guard observation.eligibleForEconomicActual else {
            throw ExternalEvidenceError.observationNotReviewable(observation.id)
        }
        guard let resolution = document.observationResolutions.first(where: {
            $0.observationID == observation.id
        }) else {
            throw ExternalEvidenceError.missingResolution(observation.id)
        }
        guard resolution.state == .unreviewed else {
            throw ExternalEvidenceError.observationAlreadyResolved(observation.id)
        }
        guard let binding = document.externalAccountBindings.first(where: {
            $0.id == observation.bindingID
        }) else {
            throw ExternalEvidenceError.unknownBinding(observation.bindingID)
        }
        guard binding.provider == observation.provider else {
            throw ExternalEvidenceError.providerBindingMismatch(observationID: observation.id)
        }
        guard binding.isActive else {
            throw ExternalEvidenceError.inactiveBinding(binding.id)
        }
        guard initialResolution(for: observation, binding: binding) == .unreviewed else {
            throw ExternalEvidenceError.observationNotReviewable(observation.id)
        }

        if assignment.role == .accountMovement {
            guard !document.externalEvidenceLinks.contains(where: {
                $0.observationID == observation.id && $0.role == .accountMovement
            }) else {
                throw ExternalEvidenceError.duplicateAccountMovementLink(observation.id)
            }
            guard let account = document.accounts.first(where: { $0.id == binding.localAccountID }) else {
                throw ExternalEvidenceError.unknownLocalAccount(binding.localAccountID)
            }
            guard account.currency == observation.amount.currency else {
                throw ExternalEvidenceError.accountCurrencyMismatch(
                    observationID: observation.id,
                    accountID: account.id
                )
            }
            guard transaction.legs.contains(where: {
                $0.accountID == binding.localAccountID && $0.amount == observation.amount
            }) else {
                throw ExternalEvidenceError.accountMovementDoesNotMatchLeg(
                    observationID: observation.id,
                    transactionID: transaction.id
                )
            }
        }
    }

    public static func markNoEconomicEffect(
        observationID: String,
        resolvedAt: Date,
        in document: inout FinanceDocument
    ) throws {
        var candidate = document
        guard candidate.externalObservations.contains(where: { $0.id == observationID }) else {
            throw ExternalEvidenceError.unknownObservation(observationID)
        }
        guard let index = candidate.observationResolutions.firstIndex(where: { $0.observationID == observationID }) else {
            throw ExternalEvidenceError.missingResolution(observationID)
        }
        guard candidate.observationResolutions[index].state == .unreviewed else {
            throw ExternalEvidenceError.observationAlreadyResolved(observationID)
        }
        candidate.observationResolutions[index].state = .noEconomicEffect
        candidate.observationResolutions[index].resolvedAt = resolvedAt
        try validate(candidate)
        document = candidate
    }

    /// Role to offer when attaching an observation to an existing transaction.
    /// Exact account movement gets the stronger role; supplemental providers
    /// can enrich the same transaction without adding a second account leg.
    public static func suggestedRole(
        observation: ExternalObservation,
        transaction: Transaction,
        in document: FinanceDocument
    ) -> ExternalEvidenceRole {
        guard let binding = document.externalAccountBindings.first(where: { $0.id == observation.bindingID }) else {
            return .supportingEvidence
        }
        if transaction.legs.contains(where: {
            $0.accountID == binding.localAccountID && $0.amount == observation.amount
        }) {
            return .accountMovement
        }
        return observation.structuredMerchantName == nil ? .supportingEvidence : .merchantEnrichment
    }

    /// Suggestions are read-only and deterministic. A high-quality result is
    /// still a proposal the caller must explicitly confirm through a resolver.
    public static func suggestions(
        for observationID: String,
        in document: FinanceDocument
    ) -> [ExternalObservationSuggestion] {
        guard let observation = document.externalObservations.first(where: { $0.id == observationID }),
              let binding = document.externalAccountBindings.first(where: { $0.id == observation.bindingID })
        else { return [] }

        var result: [ExternalObservationSuggestion] = []
        let date = observation.suggestedEconomicDate

        if observation.amount.isNegative, let date {
            let ledger = ReconciliationLedger(document.planning.settlements)
            // Advisory five-day expansion. A window that cannot be built
            // proposes no recurring-expectation suggestion; it never asserts
            // that an expectation does not exist.
            let occurrences = date.advanced(by: -5).flatMap { windowStart in
                date.advanced(by: 5).map { windowEnd in
                    OccurrenceExpander.occurrences(
                        in: document,
                        from: windowStart,
                        to: windowEnd,
                        asOf: date,
                        ledger: ledger
                    )
                }
            } ?? []
            for occurrence in occurrences where
                occurrence.amount.currency == observation.amount.currency
                    && occurrence.amount.minorUnits == observation.amount.magnitude.minorUnits
                    && !occurrence.status.isResolved {
                result.append(
                    ExternalObservationSuggestion(
                        id: "recurring-\(observation.id)-\(occurrence.id.description)",
                        observationID: observation.id,
                        kind: .recurringExpectation,
                        title: "Matches expected \(occurrence.name)",
                        targetOccurrence: occurrence.id
                    )
                )
            }
        }

        for transaction in document.transactions where transaction.lifecycle != .reversed {
            guard transaction.legs.contains(where: {
                $0.accountID == binding.localAccountID && $0.amount == observation.amount
            }) else { continue }
            // Finite five-day review window, asked as a bounded distance.
            if let date, !date.isWithin(days: 5, of: transaction.date) { continue }
            result.append(
                ExternalObservationSuggestion(
                    id: "existing-\(observation.id)-\(transaction.id)",
                    observationID: observation.id,
                    kind: .existingTransaction,
                    title: "Matches an existing transaction",
                    targetTransactionID: transaction.id
                )
            )
        }

        for candidate in document.crossProviderCandidates where
            candidate.bankObservationID == observation.id || candidate.walletObservationID == observation.id {
            switch candidate.state {
            case .unique:
                let related = candidate.bankObservationID == observation.id
                    ? candidate.walletObservationID : candidate.bankObservationID
                if let related {
                    result.append(
                        ExternalObservationSuggestion(
                            id: "cross-provider-\(candidate.id)-\(observation.id)",
                            observationID: observation.id,
                            kind: .crossProviderEvidence,
                            title: "Possible merchant evidence from another provider",
                            relatedObservationID: related
                        )
                    )
                }
            case .ambiguous, .unresolved, .other:
                result.append(
                    ExternalObservationSuggestion(
                        id: "merchant-unresolved-\(candidate.id)-\(observation.id)",
                        observationID: observation.id,
                        kind: .merchantUnresolved,
                        title: "PayPal merchant unresolved"
                    )
                )
            }
        }

        let code = [observation.bankTransactionCode, observation.bankTransactionSubCode]
            .compactMap { $0?.uppercased() }
            .joined(separator: "_")
        if code.contains("ATM") {
            result.append(
                ExternalObservationSuggestion(
                    id: "atm-\(observation.id)", observationID: observation.id,
                    kind: .atmCashMovement, title: "ATM / cash movement"
                )
            )
        } else if ["TRANSFER", "TOPUP", "EXCHANGE"].contains(where: code.contains) {
            result.append(
                ExternalObservationSuggestion(
                    id: "transfer-\(observation.id)", observationID: observation.id,
                    kind: .likelyTransfer, title: "Likely transfer"
                )
            )
        }
        if ["REFUND", "REVERSAL", "CARD_REFUND"].contains(where: code.contains) {
            result.append(
                ExternalObservationSuggestion(
                    id: "refund-\(observation.id)", observationID: observation.id,
                    kind: .refundOrReversal, title: "Possible refund or reversal"
                )
            )
        }

        for decision in TrustedRuleEngine.decisions(for: observation.id, in: document) {
            result.append(
                ExternalObservationSuggestion(
                    id: decision.id,
                    observationID: observation.id,
                    kind: .trustedRule,
                    title: "Trusted rule: \(decision.interpretation.userLabel ?? decision.interpretation.transactionKind.rawValue.capitalized)",
                    explanation: decision.explanation,
                    confidence: decision.mode == .blocked
                        ? .medium
                        : (decision.confidence == .high ? .high : .medium),
                    trustedRuleID: decision.ruleID,
                    automaticResolutionEligible: decision.mode == .automaticResolution
                )
            )
        }

        return result.sorted {
            let lhsRisk = isRiskSuggestion($0.kind)
            let rhsRisk = isRiskSuggestion($1.kind)
            if lhsRisk != rhsRisk { return lhsRisk }
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.id < $1.id
        }
    }

    private static func isRiskSuggestion(_ kind: ExternalSuggestionKind) -> Bool {
        switch kind {
        case .likelyTransfer, .atmCashMovement, .refundOrReversal, .merchantUnresolved,
             .crossProviderEvidence:
            true
        case .recurringExpectation, .existingTransaction, .trustedRule:
            false
        }
    }

    /// Whole-document external-evidence invariants.
    public static func validate(_ document: FinanceDocument) throws {
        try unique(document.externalAccountBindings.map(\.id), kind: "binding")
        try unique(document.externalObservations.map(\.id), kind: "observation")
        try unique(document.providerBalanceSnapshots.map(\.id), kind: "provider balance")
        try unique(document.externalEvidenceLinks.map(\.id), kind: "evidence link")
        try unique(document.crossProviderCandidates.map(\.id), kind: "candidate")

        let accountIDs = Set(document.accounts.map(\.id))
        let bindings = Dictionary(uniqueKeysWithValues: document.externalAccountBindings.map { ($0.id, $0) })
        for binding in document.externalAccountBindings where !accountIDs.contains(binding.localAccountID) {
            throw ExternalEvidenceError.unknownLocalAccount(binding.localAccountID)
        }

        let observations = Dictionary(uniqueKeysWithValues: document.externalObservations.map { ($0.id, $0) })
        for observation in document.externalObservations {
            guard let binding = bindings[observation.bindingID] else {
                throw ExternalEvidenceError.unknownBinding(observation.bindingID)
            }
            guard binding.provider == observation.provider else {
                throw ExternalEvidenceError.providerBindingMismatch(observationID: observation.id)
            }
            guard (observation.derivedTransactionDate == nil)
                    == (observation.derivedDateProvenance == nil) else {
                throw ExternalEvidenceError.invalidDerivedDateProvenance(observation.id)
            }
        }
        for balance in document.providerBalanceSnapshots {
            guard let binding = bindings[balance.bindingID] else {
                throw ExternalEvidenceError.unknownBinding(balance.bindingID)
            }
            guard binding.provider == balance.provider else {
                throw ExternalEvidenceError.balanceProviderBindingMismatch(balance.id)
            }
        }

        var resolutions: [String: ExternalObservationResolution] = [:]
        for resolution in document.observationResolutions {
            guard observations[resolution.observationID] != nil else {
                throw ExternalEvidenceError.unknownObservation(resolution.observationID)
            }
            guard resolutions.updateValue(resolution, forKey: resolution.observationID) == nil else {
                throw ExternalEvidenceError.duplicateResolution(resolution.observationID)
            }
        }
        for observation in document.externalObservations where resolutions[observation.id] == nil {
            throw ExternalEvidenceError.missingResolution(observation.id)
        }

        let transactions = Dictionary(uniqueKeysWithValues: document.transactions.map { ($0.id, $0) })
        let linksByObservation = Dictionary(grouping: document.externalEvidenceLinks, by: \.observationID)
        for link in document.externalEvidenceLinks {
            guard observations[link.observationID] != nil else {
                throw ExternalEvidenceError.unknownObservation(link.observationID)
            }
            guard transactions[link.transactionID] != nil else {
                throw ExternalEvidenceError.unknownTransaction(link.transactionID)
            }
        }

        for observation in document.externalObservations {
            let links = linksByObservation[observation.id] ?? []
            let transactionIDs = Set(links.map(\.transactionID))
            if transactionIDs.count > 1 {
                throw ExternalEvidenceError.observationLinkedToMultipleTransactions(observation.id)
            }
            if links.filter({ $0.role == .accountMovement }).count > 1 {
                throw ExternalEvidenceError.duplicateAccountMovementLink(observation.id)
            }
            let state = resolutions[observation.id]!.state
            if (state == .linkedToTransaction) != !links.isEmpty {
                throw ExternalEvidenceError.linkConflictsWithResolution(observation.id)
            }
            for link in links where link.role == .accountMovement {
                let transaction = transactions[link.transactionID]!
                let binding = bindings[observation.bindingID]!
                guard transaction.legs.contains(where: {
                    $0.accountID == binding.localAccountID && $0.amount == observation.amount
                }) else {
                    throw ExternalEvidenceError.accountMovementDoesNotMatchLeg(
                        observationID: observation.id, transactionID: transaction.id
                    )
                }
            }
        }

        for candidate in document.crossProviderCandidates {
            guard observations[candidate.bankObservationID] != nil else {
                throw ExternalEvidenceError.invalidCandidate(candidate.id)
            }
            switch candidate.state {
            case .unique:
                guard let wallet = candidate.walletObservationID, observations[wallet] != nil else {
                    throw ExternalEvidenceError.invalidCandidate(candidate.id)
                }
            case .ambiguous, .unresolved:
                guard candidate.walletObservationID == nil else {
                    throw ExternalEvidenceError.invalidCandidate(candidate.id)
                }
            case .other:
                break
            }
        }
        do {
            try TrustedRuleEngine.validate(document)
        } catch let problem as TrustedRuleError {
            throw ExternalEvidenceError.invalidTrustedRule(problem.description)
        }
    }

    private static func appendLinks(
        _ evidence: [ExternalEvidenceAssignment],
        transaction: Transaction,
        resolvedAt: Date,
        to document: inout FinanceDocument
    ) throws {
        var seen: Set<String> = []
        for assignment in evidence {
            guard seen.insert(assignment.observationID).inserted else {
                throw ExternalEvidenceError.duplicateIdentifier(
                    kind: "evidence assignment", id: assignment.observationID
                )
            }
            try validateResolutionEligibility(assignment, transaction: transaction, in: document)
            let observation = document.externalObservations.first {
                $0.id == assignment.observationID
            }!
            let resolutionIndex = document.observationResolutions.firstIndex {
                $0.observationID == observation.id
            }!

            document.externalEvidenceLinks.append(
                ExternalEvidenceLink(
                    id: "evidence-\(observation.id)-\(assignment.role.rawValue)",
                    observationID: observation.id,
                    transactionID: transaction.id,
                    role: assignment.role
                )
            )
            document.observationResolutions[resolutionIndex].state = .linkedToTransaction
            document.observationResolutions[resolutionIndex].resolvedAt = resolvedAt
        }
    }

    private static func unique(_ ids: [String], kind: String) throws {
        var seen: Set<String> = []
        for id in ids where !seen.insert(id).inserted {
            throw ExternalEvidenceError.duplicateIdentifier(kind: kind, id: id)
        }
    }
}
