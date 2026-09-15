import Foundation
import FinanceCore

/// The only semantic translator between the product facade and FinanceCore.
/// SwiftUI supplies `TransactionDraft` and consumes `FinanceAppSnapshot`; it
/// never constructs or reads a core transaction.
struct DomainMapper {
    enum ProjectionError: Error, Equatable {
        case invalidPlannedEventDate
    }

    struct TransactionPresentation: Hashable, Sendable {
        var categoryKey: String?
        var merchant: String?
    }

    struct MappedTransaction: Sendable {
        let transaction: Transaction
        let presentation: TransactionPresentation
    }

    struct Inputs {
        var today: Day
        var horizonDays: Int
        var document: FinanceDocument
        var forecast: ForecastResult
        var overview: LiquiditySnapshot
        var transactionPresentation: [String: TransactionPresentation] = [:]
        var incomeSourceActive: [String: Bool] = [:]
        var lastExpenseAccountID: String?
        var lastIncomeAccountID: String?
    }

    struct BankingSurface {
        let observations: [SyncedObservationItem]
        let bindings: [ProviderAccountBinding]
        let balances: [ProviderBalanceStatus]
        let trustedRules: [TrustedRuleSummary]
        var connections: [ProviderConnectionStatus] = []
        var remoteAccounts: [MappableRemoteAccount] = []
        var pendingSnapshots: [CurrentPendingProviderSnapshot] = []
    }

    /// The zone a civil date is read in at this boundary.
    ///
    /// It is the device's, not UTC. A `Day` is a civil date, and a `Date` is an
    /// instant; converting between them in UTC while the person, the picker and
    /// every formatter on screen use the local zone shifts the day by one in
    /// every zone with a non-zero offset — across a month boundary at the end
    /// of a month. FinanceCore keeps its `Day` arithmetic zone-free; this is
    /// the single place a zone is applied, and it is applied consistently in
    /// both directions.
    static func calendar(in timeZone: TimeZone = .current) -> Calendar {
        CalendarDay.calendar(in: timeZone)
    }

    // MARK: - Boundary primitives

    static func amount(_ money: Money) -> Amount {
        Amount(
            minorUnits: money.minorUnits,
            currencyCode: money.currency.code,
            fractionDigits: money.currency.minorUnitDigits
        )
    }

    static func money(_ amount: Amount) -> Money {
        Money(
            minorUnits: amount.minorUnits,
            currency: Currency(code: amount.currencyCode, minorUnitDigits: amount.fractionDigits)
        )
    }

    /// An instant that reads back as `day` in `timeZone`, so a date shown on
    /// screen and a date fed to a `DatePicker` are both the day the engine
    /// meant.
    static func date(_ day: Day, in timeZone: TimeZone = .current) -> Date? {
        civilDay(day).date(in: timeZone)
    }

    static func day(_ date: Date, in timeZone: TimeZone = .current) -> Day? {
        guard let civil = CalendarDay(date, in: timeZone) else { return nil }
        return day(civil)
    }

    /// The product-facing civil date for a domain day, and back. Pure integer
    /// components: no calendar, no zone, nothing to drift.
    static func civilDay(_ day: Day) -> CalendarDay {
        CalendarDay(year: day.year, month: day.month, day: day.day)
    }

    static func day(_ civil: CalendarDay) -> Day? {
        Day(validatingYear: civil.year, month: civil.month, day: civil.day)
    }

    static func requiredDay<E: Error>(_ civil: CalendarDay, or error: @autoclosure () -> E) throws -> Day {
        guard let day = day(civil) else { throw error() }
        return day
    }

    static func requiredDay<E: Error>(_ civil: CalendarDay?, or error: @autoclosure () -> E) throws -> Day {
        guard let civil else { throw error() }
        return try requiredDay(civil, or: error())
    }

    static func spendingClass(_ value: BudgetSpendingClass) -> SpendingClass {
        switch value {
        case .essential: .essential
        case .flexible: .flexible
        case .optional: .optional
        }
    }

    static func spendingClass(_ value: SpendingClass) -> BudgetSpendingClass {
        switch value {
        case .essential: .essential
        case .flexible: .flexible
        case .optional: .optional
        }
    }

    static func scenario(_ scenario: Scenario) -> PlanScenario {
        switch scenario {
        case .guaranteed: .guaranteed
        case .base: .base
        case .upside: .upside
        }
    }

    static func scenario(_ scenario: PlanScenario) -> Scenario {
        switch scenario {
        case .guaranteed: .guaranteed
        case .base: .base
        case .upside: .upside
        }
    }

    // MARK: - External evidence

    func bankingSurface(
        document: FinanceDocument,
        transactionPresentation: [String: TransactionPresentation],
        asOf: Day? = nil
    ) -> BankingSurface {
        let accounts = Dictionary(
            document.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let bindingsByID = Dictionary(
            document.externalAccountBindings.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let resolutions = Dictionary(
            document.observationResolutions.map { ($0.observationID, $0.state) },
            uniquingKeysWith: { first, _ in first }
        )
        let links = Dictionary(
            grouping: document.externalEvidenceLinks,
            by: \.observationID
        )
        let warnings = Set(ExternalEvidenceReview.providerStatusWarnings(in: document))

        let bindingSurface = document.externalAccountBindings.map { binding in
            ProviderAccountBinding(
                id: binding.id,
                providerName: providerName(binding.provider),
                localAccountID: binding.localAccountID,
                localAccountName: accounts[binding.localAccountID]?.name ?? "Account",
                syncStartBoundary: Self.civilDay(binding.syncStartBoundary),
                isActive: binding.isActive
            )
        }

        let observationSurface = document.externalObservations.compactMap { observation -> SyncedObservationItem? in
            guard let binding = bindingsByID[observation.bindingID],
                  let state = resolutions[observation.id],
                  state != .outsideSyncBoundary,
                  binding.isActive || state != .unreviewed else { return nil }
            let domainSuggestions = state == .unreviewed
                ? ExternalEvidenceReview.suggestions(for: observation.id, in: document)
                : []
            var surfaceSuggestions = domainSuggestions.map(observationSuggestion)
            if state == .unreviewed {
                for transactionID in safelyLinkedCrossProviderTransactionIDs(
                    for: observation,
                    in: document
                ) where !surfaceSuggestions.contains(where: {
                    $0.kind == .existingTransaction && $0.targetTransactionID == transactionID
                }) {
                    surfaceSuggestions.append(
                        ObservationSuggestion(
                            id: "linked-provider-existing-\(observation.id)-\(transactionID)",
                            title: "Matches an existing transaction through linked provider evidence",
                            kind: .existingTransaction,
                            targetTransactionID: transactionID,
                            targetExpectedPaymentID: nil,
                            relatedObservationID: nil,
                            explanation: "Another provider's account movement is already linked to this transaction.",
                            confidence: .high,
                            trustedRuleID: nil,
                            automaticResolutionEligible: false
                        )
                    )
                }
            }
            let linkedTransactionID = links[observation.id]?.first?.transactionID
            let observedMerchant = observation.observedMerchant
            let userLabel = linkedTransactionID.flatMap { transactionPresentation[$0]?.merchant }
            return SyncedObservationItem(
                id: observation.id,
                providerName: providerName(observation.provider),
                providerAccountName: accounts[binding.localAccountID]?.name ?? "Account",
                isAccountBindingActive: binding.isActive,
                amount: Self.amount(observation.amount),
                status: observationStatus(observation.status),
                resolution: observationResolution(state),
                displayMerchant: userLabel
                    ?? observedMerchant
                    ?? observation.bankTransactionCode
                    ?? providerName(observation.provider),
                observedMerchant: observedMerchant,
                rawMerchantText: observation.rawMerchantText,
                remittance: observation.remittance,
                merchantEmail: observation.merchantEmail,
                bankTransactionCode: observation.bankTransactionCode,
                dates: ObservationDates(
                    booking: observation.bookingDate.map(Self.civilDay),
                    transaction: observation.transactionDate.map(Self.civilDay),
                    value: observation.valueDate.map(Self.civilDay),
                    derivedTransaction: observation.derivedTransactionDate.map(Self.civilDay),
                    derivedProvenanceLabel: observation.derivedDateProvenance.map {
                        switch $0 {
                        case .parsedFromProviderRemittance: "Parsed from provider remittance"
                        case let .other(token): token
                        }
                    },
                    // Transported, not re-derived. FinanceCore owns the rule.
                    economicPeriod: observation.economicPeriodDay.map(Self.civilDay)
                ),
                observedAt: observation.observedAt,
                suggestions: surfaceSuggestions,
                duplicateConflict: state == .unreviewed
                    ? duplicateConflict(for: observation, in: document)
                    : nil,
                hasProviderStatusWarning: warnings.contains(observation.id)
            )
        }
        .sorted {
            if $0.inboxPriority != $1.inboxPriority { return $0.inboxPriority < $1.inboxPriority }
            return $0.observedAt > $1.observedAt
        }

        // Internal query anchor only. CurrentHoldings.derivedLedgerBalance
        // returns nil without a real balance/asOf, so this 1970 day never
        // becomes a fabricated financial observation.
        let holdingsDay = asOf
            ?? document.balances.map(\.asOf).max()
            ?? Day(year: 1970, month: 1, day: 1)
        let ledgerBalances = Dictionary(
            uniqueKeysWithValues: document.accounts.compactMap { account -> (String, Money)? in
                CurrentHoldings.derivedLedgerBalance(
                    accountID: account.id, asOf: holdingsDay, in: document
                ).map { (account.id, $0) }
            }
        )
        let balanceSurface = document.providerBalanceSnapshots.compactMap { provider -> ProviderBalanceStatus? in
            guard let binding = bindingsByID[provider.bindingID],
                  let ledger = ledgerBalances[binding.localAccountID],
                  let account = accounts[binding.localAccountID] else { return nil }
            let difference: Amount? = ledger.currency == provider.amount.currency
                ? Self.amount(provider.amount - ledger)
                : nil
            return ProviderBalanceStatus(
                id: provider.id,
                providerName: providerName(provider.provider),
                accountName: account.name,
                balanceType: provider.balanceType,
                ledgerBalance: Self.amount(ledger),
                providerBalance: Self.amount(provider.amount),
                difference: difference,
                referenceDate: provider.referenceDate.map(Self.civilDay),
                observedAt: provider.observedAt
            )
        }
        .sorted { ($0.accountName, $0.balanceType) < ($1.accountName, $1.balanceType) }

        let incomeSources = Dictionary(
            uniqueKeysWithValues: document.incomeSources.map { ($0.id, $0.name) }
        )
        let obligations = Dictionary(
            uniqueKeysWithValues: document.planning.recurringObligations.map { ($0.id, $0.name) }
        )
        let ruleAudit = Dictionary(grouping: document.trustedRuleAuditEvents, by: \.ruleID)
        let observationsByID = Dictionary(
            uniqueKeysWithValues: document.externalObservations.map { ($0.id, $0) }
        )
        let ruleSurface = document.trustedRules.map { rule in
            let preview = try? TrustedRuleEngine.preview(ruleID: rule.id, in: document)
            let automaticSafetyReasons = TrustedRuleEngine.automaticApprovalBlockers(
                for: rule, in: document
            ).map { TrustedRuleEngine.blockerExplanation($0) }
            return TrustedRuleSummary(
                id: rule.id,
                title: rule.title,
                providerName: providerName(rule.predicate.provider),
                accountName: accounts[bindingsByID[rule.predicate.bindingID]?.localAccountID ?? ""]?.name
                    ?? "Account",
                bindingReference: rule.predicate.bindingID,
                merchantEvidenceField: {
                    switch rule.predicate.merchantField {
                    case .structuredMerchantName: "Structured merchant"
                    case .merchantEmail: "Merchant email"
                    case .rawMerchantText: "Raw provider text"
                    case .remittance: "Provider remittance"
                    }
                }(),
                merchantEvidenceValue: rule.predicate.merchantValue,
                direction: rule.predicate.direction == .debit ? "Debit" : "Credit",
                currency: rule.predicate.currencyCode,
                exactAmount: rule.predicate.exactMinorUnits.map {
                    Amount(
                        minorUnits: $0,
                        currencyCode: rule.predicate.currencyCode,
                        fractionDigits: rule.predicate.currencyExponent
                    )
                },
                providerCode: rule.predicate.bankTransactionCode,
                economicKind: rule.interpretation.transactionKind.rawValue,
                category: rule.interpretation.categoryKey,
                userLabel: rule.interpretation.userLabel,
                recurringObligation: rule.interpretation.recurringObligationID.flatMap {
                    obligations[$0]
                },
                economicSource: rule.interpretation.incomeSourceID.flatMap { incomeSources[$0] },
                trust: rule.trustLevel == .suggestionOnly
                    ? "Suggestion only" : "Approved automatic",
                lifecycle: {
                    switch rule.lifecycle {
                    case .draft: "Draft"
                    case .active: "Active"
                    case .disabled: "Disabled"
                    }
                }(),
                supportCount: rule.supportingConfirmations.count,
                supportingConfirmations: rule.supportingConfirmations.sorted {
                    ($0.confirmedAt, $0.id) > ($1.confirmedAt, $1.id)
                }.map { support in
                    let observation = observationsByID[support.observationID]
                    return TrustedRuleSupportSummary(
                        id: support.id,
                        confirmedAt: support.confirmedAt,
                        economicDate: observation?.suggestedEconomicDate.map { Self.civilDay($0) },
                        amount: observation.map {
                            Amount(
                                minorUnits: $0.amount.minorUnits,
                                currencyCode: $0.amount.currency.code,
                                fractionDigits: $0.amount.currency.minorUnitDigits
                            )
                        },
                        category: support.categoryKey,
                        userLabel: support.userLabel
                    )
                },
                semanticFingerprint: rule.semanticFingerprint,
                automaticSafetyReasons: automaticSafetyReasons,
                currentMatchCount: preview?.matchedObservations.count ?? 0,
                currentAutomaticallyEligibleCount:
                    preview?.automaticallyEligibleObservations.count ?? 0,
                currentSuggestionOnlyCount: preview?.suggestionOnlyObservations.count ?? 0,
                currentSuggestionOnlyReasons: Array(Set(
                    (preview?.items ?? []).filter {
                        $0.outcome == .suggestionOnly
                    }.flatMap(\.reasons)
                )).sorted(),
                currentBlockedMatches: (preview?.blockedObservations ?? []).map {
                    TrustedRuleBlockedMatchSummary(
                        id: $0.observationID,
                        reasons: $0.reasons
                    )
                },
                approvedAt: rule.approvedAt,
                disabledAt: rule.disabledAt,
                audit: (ruleAudit[rule.id] ?? []).sorted { $0.occurredAt > $1.occurredAt }.map { event in
                    TrustedRuleAuditSummary(
                        id: event.id,
                        action: {
                            switch event.kind {
                            case .created: "Created"
                            case .approvedForSuggestions: "Approved for suggestions"
                            case .approvedForAutomaticResolution: "Approved for automatic resolution"
                            case .disabled: "Disabled"
                            case .automaticallyResolved: "Applied automatically"
                            case .reversed: "Reversed"
                            case .reapplicationAuthorized: "Reapplication re-authorized"
                            }
                        }(),
                        occurredAt: event.occurredAt,
                        explanation: event.explanation
                    )
                }
            )
        }
        .sorted { ($0.lifecycle, $0.title, $0.id) < ($1.lifecycle, $1.title, $1.id) }

        return BankingSurface(
            observations: observationSurface,
            bindings: bindingSurface,
            balances: balanceSurface,
            trustedRules: ruleSurface
        )
    }

    private func providerName(_ provider: ExternalProvider) -> String {
        switch provider {
        case .bnp: "BNP"
        case .paypal: "PayPal"
        case .revolut: "Revolut"
        default: provider.rawValue.capitalized
        }
    }

    private func observationStatus(_ status: ExternalObservationStatus) -> SyncedObservationStatus {
        switch status {
        case .booked: .booked
        case .pending: .pending
        case .rejected: .rejected
        case .other: .other
        }
    }

    private func observationResolution(_ state: ObservationResolutionState) -> SyncedObservationResolution {
        switch state {
        case .unreviewed: .unreviewed
        case .linkedToTransaction: .linked
        case .noEconomicEffect: .noEconomicEffect
        case .outsideSyncBoundary: .outsideBoundary
        case .provisional: .provisional
        case .economicallyIneligible: .ineligible
        }
    }

    private func observationSuggestion(_ suggestion: ExternalObservationSuggestion) -> ObservationSuggestion {
        ObservationSuggestion(
            id: suggestion.id,
            title: suggestion.title,
            kind: {
                switch suggestion.kind {
                case .recurringExpectation: .recurring
                case .existingTransaction: .existingTransaction
                case .crossProviderEvidence: .crossProvider
                case .likelyTransfer: .likelyTransfer
                case .atmCashMovement: .atmCashMovement
                case .refundOrReversal: .refundOrReversal
                case .merchantUnresolved: .merchantUnresolved
                case .trustedRule: .trustedRule
                }
            }(),
            targetTransactionID: suggestion.targetTransactionID,
            targetExpectedPaymentID: suggestion.targetOccurrence.map(Self.expectedPaymentID),
            relatedObservationID: suggestion.relatedObservationID,
            explanation: suggestion.explanation,
            confidence: {
                switch suggestion.confidence {
                case .low: .low
                case .medium: .medium
                case .high: .high
                }
            }(),
            trustedRuleID: suggestion.trustedRuleID,
            automaticResolutionEligible: suggestion.automaticResolutionEligible
        )
    }

    /// Strong duplicate evidence used by both the surface and the serialized
    /// store write guard. It never resolves or links an observation.
    func duplicateConflict(
        for observation: ExternalObservation,
        in document: FinanceDocument
    ) -> ObservationDuplicateConflict? {
        guard observation.eligibleForEconomicActual else { return nil }

        let directExisting = ExternalEvidenceReview.suggestions(
            for: observation.id,
            in: document
        ).compactMap { suggestion in
            suggestion.kind == .existingTransaction ? suggestion.targetTransactionID : nil
        }
        let safelyLinked = safelyLinkedCrossProviderTransactionIDs(
            for: observation,
            in: document
        )
        let existing = Array(Set(directExisting + safelyLinked)).sorted()
        if !existing.isEmpty {
            return ObservationDuplicateConflict(
                kind: .exactExisting,
                transactionIDs: existing,
                relatedObservationID: nil
            )
        }

        if let aggregate = aggregateExistingTransactionIDs(
            for: observation,
            in: document
        ) {
            return ObservationDuplicateConflict(
                kind: .aggregateExisting,
                transactionIDs: aggregate,
                relatedObservationID: nil
            )
        }

        let settled = settledRecurringTransactionIDs(
            for: observation,
            in: document
        )
        if !settled.isEmpty {
            return ObservationDuplicateConflict(
                kind: .settledRecurring,
                transactionIDs: settled,
                relatedObservationID: nil
            )
        }

        let crossProvider = document.crossProviderCandidates.first { candidate in
            candidate.bankObservationID == observation.id
                || candidate.walletObservationID == observation.id
        }
        if let crossProvider {
            let related = crossProvider.bankObservationID == observation.id
                ? crossProvider.walletObservationID
                : crossProvider.bankObservationID
            return ObservationDuplicateConflict(
                kind: .crossProvider,
                transactionIDs: [],
                relatedObservationID: related
            )
        }
        return nil
    }

    /// A unique provider pairing can safely recommend an existing transaction
    /// only when the related observation is already its exact account-movement
    /// evidence. The new observation may then add merchant/supporting evidence;
    /// no amount, account or relationship is guessed.
    private func safelyLinkedCrossProviderTransactionIDs(
        for observation: ExternalObservation,
        in document: FinanceDocument
    ) -> [String] {
        let liveTransactions = Set(
            document.transactions
                .filter { $0.lifecycle != .reversed }
                .map(\.id)
        )
        var result: Set<String> = []
        for candidate in document.crossProviderCandidates where candidate.state == .unique {
            let relatedID: String?
            if candidate.bankObservationID == observation.id {
                relatedID = candidate.walletObservationID
            } else if candidate.walletObservationID == observation.id {
                relatedID = candidate.bankObservationID
            } else {
                continue
            }
            guard let relatedID else { continue }
            for link in document.externalEvidenceLinks where
                link.observationID == relatedID
                    && link.role == .accountMovement
                    && liveTransactions.contains(link.transactionID) {
                result.insert(link.transactionID)
            }
        }
        return result.sorted()
    }

    /// Detect the known one-observation/two-actual shape without offering a
    /// false single-transaction link. Exact signed cents, the bound account and
    /// the existing five-day review window are all required. Multiple possible
    /// pairs stay unresolved rather than selecting one arbitrarily.
    private func aggregateExistingTransactionIDs(
        for observation: ExternalObservation,
        in document: FinanceDocument
    ) -> [String]? {
        guard let date = observation.suggestedEconomicDate,
              let binding = document.externalAccountBindings.first(where: {
                  $0.id == observation.bindingID
              }) else { return nil }

        let candidates: [(id: String, amount: Int64)] = document.transactions.compactMap { transaction in
            // The existing five-day review window, asked as a bounded
            // distance rather than a negated difference.
            guard transaction.lifecycle != .reversed,
                  date.isWithin(days: 5, of: transaction.date) else { return nil }
            let legs = transaction.legs.filter {
                $0.accountID == binding.localAccountID
                    && $0.amount.currency == observation.amount.currency
                    && ($0.amount.isNegative == observation.amount.isNegative)
                    && ($0.amount.isPositive == observation.amount.isPositive)
            }
            guard legs.count == 1 else { return nil }
            return (transaction.id, legs[0].amount.minorUnits)
        }

        var pairs: [[String]] = []
        for left in candidates.indices {
            for right in candidates.indices where right > left {
                let (sum, overflow) = candidates[left].amount.addingReportingOverflow(
                    candidates[right].amount
                )
                if !overflow, sum == observation.amount.minorUnits {
                    pairs.append([candidates[left].id, candidates[right].id].sorted())
                }
            }
        }
        let uniquePairs = Array(Set(pairs)).sorted {
            $0.lexicographicallyPrecedes($1)
        }
        return uniquePairs.count == 1 ? uniquePairs[0] : nil
    }

    /// A second exact charge near a recurring occurrence that is already paid
    /// is a strong duplicate signal even when it arrived from a different
    /// provider account. It is not enough to fabricate an evidence link, so the
    /// UI warns and leaves the observation unresolved.
    private func settledRecurringTransactionIDs(
        for observation: ExternalObservation,
        in document: FinanceDocument
    ) -> [String] {
        guard observation.amount.isNegative,
              let date = observation.suggestedEconomicDate else { return [] }
        let transactions = Dictionary(
            uniqueKeysWithValues: document.transactions.map { ($0.id, $0) }
        )
        // Advisory duplicate-signal expansion. A window that cannot be built
        // warns about nothing; it never resolves the observation either way.
        guard let windowStart = date.advanced(by: -5),
              let windowEnd = date.advanced(by: 5) else { return [] }
        let occurrences = OccurrenceExpander.occurrences(
            in: document,
            from: windowStart,
            to: windowEnd,
            asOf: date,
            ledger: ReconciliationLedger(document.planning.settlements)
        )
        var result: Set<String> = []
        for occurrence in occurrences where occurrence.amount == observation.amount.magnitude {
            guard case let .paid(transactionID) = occurrence.status,
                  let transaction = transactions[transactionID],
                  transaction.lifecycle != .reversed,
                  date.isWithin(days: 5, of: transaction.date),
                  transaction.legs.contains(where: { $0.amount == observation.amount })
            else { continue }
            result.insert(transactionID)
        }
        return result.sorted()
    }

    // MARK: - Reconciliation
    //
    // An expected occurrence has no stored identity — it is the rule plus the
    // day. The product id is exactly that pair, printed, so a screen can hold
    // one across a relaunch without the app materialising occurrence rows.

    static func expectedPaymentID(_ occurrence: OccurrenceID) -> String {
        "\(occurrence.obligationID)@\(occurrence.expectedDay.isoString)"
    }

    /// Reads an id back. Split on the **last** separator: a rule id is free to
    /// contain one, an ISO day never is.
    static func occurrenceID(_ id: String) -> OccurrenceID? {
        guard let separator = id.lastIndex(of: "@") else { return nil }
        let obligationID = String(id[id.startIndex..<separator])
        let dayText = String(id[id.index(after: separator)...])
        guard !obligationID.isEmpty, let day = Day(structuralISOString: dayText) else { return nil }
        return OccurrenceID(obligationID: obligationID, expectedDay: day)
    }

    /// A settlement's own stable id, derived from the occurrence it resolves,
    /// so the same occurrence never accumulates two rows.
    static func settlementID(_ occurrence: OccurrenceID) -> String {
        "settle-\(expectedPaymentID(occurrence))"
    }

    static func expectedPayment(
        _ occurrence: ExpectedOccurrence,
        accountNames: [String: String]
    ) -> ExpectedPayment {
        ExpectedPayment(
            id: expectedPaymentID(occurrence.id),
            ruleID: occurrence.obligationID,
            ruleName: occurrence.name,
            expectedDate: civilDay(occurrence.expectedDay),
            amount: amount(occurrence.amount),
            status: expectedPaymentStatus(occurrence.status),
            expectedAccountLabel: nil
        )
    }

    static func expectedPaymentStatus(_ status: OccurrenceStatus) -> ExpectedPaymentStatus {
        switch status {
        case .due: .due
        case .overdue: .overdue
        case let .paid(transactionID): .paid(transactionID: transactionID)
        case .skipped: .skipped
        case .noLongerDue: .noLongerDue
        }
    }

    static func paymentMatch(
        _ candidate: MatchCandidate,
        accountNames: [String: String]
    ) -> PaymentMatch {
        PaymentMatch(
            id: candidate.id,
            expectedPaymentID: expectedPaymentID(candidate.occurrence),
            ruleName: candidate.obligationName,
            expectedDate: civilDay(candidate.expectedDay),
            expectedAmount: amount(candidate.expectedAmount),
            transactionID: candidate.actualTransactionID,
            transactionTitle: candidate.actualTitle,
            actualDate: civilDay(candidate.actualDay),
            actualAmount: amount(candidate.actualAmount),
            accountLabel: accountNames[candidate.actualAccountID] ?? candidate.actualAccountID,
            strength: matchStrength(candidate.confidence),
            requiresAmountConfirmation: candidate.requiresAmountConfirmation,
            reasons: candidate.signals.compactMap(matchReason),
            daysApart: candidate.daysApart
        )
    }

    static func matchStrength(_ confidence: MatchConfidence) -> MatchStrength {
        switch confidence {
        case .strong: .strong
        case .plausible: .plausible
        case .weak: .weak
        }
    }

    /// One signal, said plainly. `nil` for signals a person does not need
    /// spelled out — the day gap is already on the row.
    static func matchReason(_ signal: MatchSignal) -> String? {
        switch signal {
        case .exactAmount:
            "Same amount"
        case let .amountDiffers(expected, actual):
            "Different amount: expected \(amount(expected).formatted()), paid \(amount(actual).formatted())"
        case .sameDay:
            "Paid on the expected day"
        case let .daysApart(days):
            days > 0 ? "Paid \(days) day\(days == 1 ? "" : "s") later"
                     : "Paid \(-days) day\(days == -1 ? "" : "s") earlier"
        case .titleMatch:
            "Same name"
        case .titlePartialMatch:
            "Similar name"
        case let .paidFromUnexpectedAccount(accountID):
            "Paid from a different account than planned"
                + (accountID.isEmpty ? "" : "")
        }
    }

    static func certainty(_ certainty: IncomeCertainty) -> IncomeCertaintyOption {
        switch certainty {
        case .received: .received
        case .guaranteed: .guaranteed
        case .expected: .expected
        case .target: .target
        case .possible: .possible
        }
    }

    static func certainty(_ certainty: IncomeCertaintyOption) -> IncomeCertainty {
        switch certainty {
        case .received: .received
        case .guaranteed: .guaranteed
        case .expected: .expected
        case .target: .target
        case .possible: .possible
        }
    }

    func newAccount(
        from draft: AccountDraft,
        id: String,
        drawOrder: Int
    ) throws -> (account: Account, balance: AccountBalance) {
        let code = draft.currencyCode.uppercased()
        guard code.count == 3,
              code.allSatisfy({ $0.isASCII && $0.isUppercase && $0.isLetter }),
              (0...6).contains(draft.fractionDigits) else {
            throw AppManagementError.invalidCurrency
        }
        guard draft.openingBalance.currencyCode == code,
              draft.openingBalance.fractionDigits == draft.fractionDigits else {
            throw AppManagementError.openingBalanceCurrencyMismatch
        }
        let currency = Currency(code: code, minorUnitDigits: draft.fractionDigits)
        let kind: AccountKind
        let rails: Set<PaymentRail>
        switch draft.kind {
        case .bank:
            kind = .bank
            rails = currency == .eur
                ? PaymentRail.euroBankRails
                : [.cardDebit, .electronicPayment]
        case .wallet:
            kind = .wallet
            rails = currency == .eur
                ? PaymentRail.euroWalletRails
                : [.cardDebit, .electronicPayment]
        case .cash:
            kind = .cash
            rails = PaymentRail.cashOnlyRails
        }
        let account = Account(
            id: id,
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            currency: currency,
            kind: kind,
            supportedRails: rails,
            isActive: draft.isActive,
            drawOrder: drawOrder
        )
        return (
            account,
            AccountBalance(
                accountID: id,
                balance: Self.money(draft.openingBalance),
                asOf: try Self.requiredDay(draft.openingBalanceDay, or: AppManagementError.invalidDate),
                status: .observed
            )
        )
    }

    func newIncomeSource(
        from draft: IncomeSourceDraft,
        id: String,
        today: Day,
        currency: Currency
    ) -> IncomeSource {
        IncomeSource(
            id: id,
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: Money(minorUnits: 0, currency: currency),
            certainty: Self.certainty(draft.certainty),
            schedule: .oneShot(on: today),
            arrivesOnAccount: draft.preferredAccountID,
            note: draft.note?.nilIfBlank
        )
    }

    func updating(_ source: IncomeSource, from draft: IncomeSourceDraft) -> IncomeSource {
        var updated = source
        updated.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.certainty = Self.certainty(draft.certainty)
        updated.arrivesOnAccount = draft.preferredAccountID
        updated.note = draft.note?.nilIfBlank
        return updated
    }

    // MARK: - Snapshot

    func snapshot(_ input: Inputs) throws -> FinanceAppSnapshot {
        let document = input.document
        let result = input.forecast
        let overview = input.overview
        let balances = Dictionary(
            uniqueKeysWithValues: CurrentHoldings.overlayBalances(
                in: document, asOf: input.today
            ).map { ($0.accountID, $0) }
        )
        let holdings = document.accounts
            .sorted { $0.drawOrder < $1.drawOrder }
            .compactMap { account -> HoldingLine? in
                guard let balance = balances[account.id] else { return nil }
                return HoldingLine(
                    id: account.id,
                    title: account.name,
                    subtitle: holdingSubtitle(account.kind),
                    kind: holdingKind(account.kind),
                    balance: Self.amount(balance.balance),
                    isSpendableHere: account.kind != .cash && account.currency == .eur,
                    carriedAt: document.planning.carriedEURValues[account.id].map(Self.amount),
                    railLabels: Self.railLabels(account.supportedRails)
                )
            }
        let budget = budgetOverview(
            document: document,
            today: input.today,
            presentation: input.transactionPresentation
        )
        let firstRisk = riskPoint(result.firstRisk, result: result, document: document)
        let lowestDay = result.lowestBalanceDate ?? input.today
        let eventRows = plannedEvents(input)
        let accountSummaries = document.accounts
            .sorted { $0.drawOrder < $1.drawOrder }
            .map { account in
                let balance = balances[account.id]?.balance
                    ?? Money(minorUnits: 0, currency: account.currency)
                return AccountSummary(
                    id: account.id,
                    name: account.name,
                    kind: holdingKind(account.kind),
                    currencyCode: account.currency.code,
                    fractionDigits: account.currency.minorUnitDigits,
                    balance: Self.amount(balance),
                    balanceAsOf: Self.civilDay(balances[account.id]?.asOf ?? input.today),
                    isActive: account.isActive,
                    railLabels: Self.railLabels(account.supportedRails)
                )
            }
        let sourceSummaries = incomeSourceSummaries(
            document.incomeSources,
            accounts: document.accounts,
            active: input.incomeSourceActive
        )

        return FinanceAppSnapshot(
            asOf: Self.civilDay(input.today),
            horizonDays: input.horizonDays,
            scenario: Self.scenario(result.scenario),
            currencyCode: Currency.eur.code,
            accountCash: Self.amount(overview.financialAccountLiquidity),
            physicalCash: holdings.filter { $0.kind == HoldingKind.cash },
            trackedHoldings: holdings,
            safeToSpend: Self.amount(overview.safeToSpend.amount),
            safeDailySpend: Self.amount(
                overview.safeToSpend.dailyAmount ?? Money(minorUnits: 0, currency: overview.safeToSpend.amount.currency)
            ),
            safeToSpendReason: safeReason(overview.safeToSpend),
            safeToSpendWindowDays: overview.safeToSpend.horizonDays,
            rawShortfall: Self.amount(
                overview.safeToSpend.rawHeadroom.isNegative
                    ? overview.safeToSpend.rawHeadroom
                    : Money(minorUnits: 0, currency: overview.safeToSpend.rawHeadroom.currency)
            ),
            committedOutflows: Self.amount(overview.committedOutflowsNext),
            cashRunway: result.firstNegativeDate == nil
                ? .clear(horizonDays: result.cashRunwayDays)
                : .endsIn(days: result.cashRunwayDays),
            firstRisk: firstRisk,
            lowestPoint: RiskPoint(
                date: Self.civilDay(lowestDay),
                projectedBalance: Self.amount(result.lowestBalance),
                triggerLabel: result.firstRisk?.day == lowestDay ? firstRisk?.triggerLabel : nil,
                triggerAmount: result.firstRisk?.day == lowestDay ? firstRisk?.triggerAmount : nil,
                // Only the day the risk was actually reached has a shortfall to
                // report. The lowest point of a run that stayed solvent has
                // none, and is not given one.
                shortfall: result.firstRisk?.day == lowestDay ? firstRisk?.shortfall : nil
            ),
            minimumBridgeRequired: Self.amount(overview.minimumBridge),
            runwayPoints: result.dailyBalances.map {
                RunwayPoint(date: Self.civilDay($0.day), balance: Self.amount($0.spendablePool))
            },
            upcomingEvents: eventRows,
            monthProjections: try monthProjections(input, plannedEvents: eventRows),
            budget: budget,
            activity: activity(
                document.transactions,
                accounts: document.accounts,
                incomeSources: document.incomeSources,
                installmentPlans: document.installments,
                presentation: input.transactionPresentation
            ),
            commitments: commitments(document.planning.recurringObligations),
            instalments: instalments(document.installments),
            income: income(document.incomeSources),
            debts: debts(document.debts),
            accounts: accountSummaries,
            incomeSources: sourceSummaries,
            entryOptions: entryOptions(
                document.accounts,
                incomeSources: document.incomeSources,
                sourceActive: input.incomeSourceActive,
                lastExpenseAccountID: input.lastExpenseAccountID,
                lastIncomeAccountID: input.lastIncomeAccountID
            ),
            plannedPurchases: plannedPurchases(document),
            sinkingFunds: sinkingFunds(document)
        )
    }

    /// A document-shaped shell for the narrow case where projection failed.
    ///
    /// This is not a forecast substitute: every projection-derived field
    /// stays unavailable/empty. It preserves only current holdings and account
    /// identity so a populated document can never be mistaken for first-run
    /// onboarding while the projection is unavailable.
    func snapshotWithoutProjection(
        document: FinanceDocument,
        today: Day,
        scenario: PlanScenario,
        horizonDays: Int,
        incomeSourceActive: [String: Bool],
        lastExpenseAccountID: String?,
        lastIncomeAccountID: String?
    ) -> FinanceAppSnapshot {
        let balances = Dictionary(
            uniqueKeysWithValues: CurrentHoldings.overlayBalances(
                in: document, asOf: today
            ).map { ($0.accountID, $0) }
        )
        let holdings = document.accounts
            .sorted { $0.drawOrder < $1.drawOrder }
            .compactMap { account -> HoldingLine? in
                guard let balance = balances[account.id] else { return nil }
                return HoldingLine(
                    id: account.id,
                    title: account.name,
                    subtitle: holdingSubtitle(account.kind),
                    kind: holdingKind(account.kind),
                    balance: Self.amount(balance.balance),
                    isSpendableHere: account.kind != .cash && account.currency == .eur,
                    carriedAt: document.planning.carriedEURValues[account.id].map(Self.amount),
                    railLabels: Self.railLabels(account.supportedRails)
                )
            }
        let accounts = document.accounts
            .sorted { $0.drawOrder < $1.drawOrder }
            .map { account in
                let balance = balances[account.id]?.balance
                    ?? Money(minorUnits: 0, currency: account.currency)
                return AccountSummary(
                    id: account.id,
                    name: account.name,
                    kind: holdingKind(account.kind),
                    currencyCode: account.currency.code,
                    fractionDigits: account.currency.minorUnitDigits,
                    balance: Self.amount(balance),
                    balanceAsOf: Self.civilDay(balances[account.id]?.asOf ?? today),
                    isActive: account.isActive,
                    railLabels: Self.railLabels(account.supportedRails)
                )
            }

        var shell = FinanceAppSnapshot.empty(asOf: Self.civilDay(today))
        shell.horizonDays = horizonDays
        shell.scenario = scenario
        shell.accountCash = Self.amount(
            CurrentHoldings.euroFinancialAccountLiquidity(in: document, asOf: today)
        )
        shell.physicalCash = holdings.filter { $0.kind == .cash }
        shell.trackedHoldings = holdings
        shell.accounts = accounts
        shell.incomeSources = incomeSourceSummaries(
            document.incomeSources,
            accounts: document.accounts,
            active: incomeSourceActive
        )
        shell.entryOptions = entryOptions(
            document.accounts,
            incomeSources: document.incomeSources,
            sourceActive: incomeSourceActive,
            lastExpenseAccountID: lastExpenseAccountID,
            lastIncomeAccountID: lastIncomeAccountID
        )
        shell.plannedPurchases = plannedPurchases(document)
        shell.sinkingFunds = sinkingFunds(document)
        return shell
    }

    func plannedPurchases(_ document: FinanceDocument) -> [PlannedPurchaseSummary] {
        let funds = Dictionary(uniqueKeysWithValues: document.planning.sinkingFunds.map { ($0.id, $0) })
        return document.planning.plannedPurchases
            .sorted { $0.id < $1.id }
            .map { purchase in
                let fund: SinkingFund?
                if case let .sinkingFund(id) = purchase.funding {
                    fund = funds[id]
                } else {
                    fund = nil
                }
                return PlannedPurchaseSummary(
                    id: purchase.id,
                    name: purchase.name,
                    target: Self.amount(purchase.targetAmount),
                    targetDate: purchase.targetDate.map { Self.civilDay($0) },
                    status: goalStatus(purchase.status),
                    funding: goalFunding(purchase.funding),
                    sinkingFundID: fund?.id,
                    sinkingFundName: fund?.name,
                    reserved: Self.amount(fund?.reservedAmount ?? purchase.ownReservation),
                    note: purchase.note
                )
            }
    }

    func sinkingFunds(_ document: FinanceDocument) -> [SinkingFundSummary] {
        let goals = Dictionary(uniqueKeysWithValues: document.planning.plannedPurchases.map { ($0.id, $0) })
        let accounts = Dictionary(uniqueKeysWithValues: document.accounts.map { ($0.id, $0) })
        return document.planning.sinkingFunds
            .sorted { $0.id < $1.id }
            .map { fund in
                let remainingUnits = max(fund.targetAmount.minorUnits - max(fund.reservedAmount.minorUnits, 0), 0)
                let dedicatedID: String?
                if case let .dedicatedAccount(id) = fund.custody {
                    dedicatedID = id
                } else {
                    dedicatedID = nil
                }
                return SinkingFundSummary(
                    id: fund.id,
                    name: fund.name,
                    target: Self.amount(fund.targetAmount),
                    reserved: Self.amount(fund.reservedAmount),
                    remaining: Amount(
                        minorUnits: remainingUnits,
                        currencyCode: fund.targetAmount.currency.code,
                        fractionDigits: fund.targetAmount.currency.minorUnitDigits
                    ),
                    custody: fundCustody(fund.custody),
                    dedicatedAccountID: dedicatedID,
                    dedicatedAccountName: dedicatedID.flatMap { accounts[$0]?.name },
                    status: fundStatus(fund.status),
                    goalID: fund.goalID,
                    goalName: fund.goalID.flatMap { goals[$0]?.name },
                    contribution: fund.contributionAmount.map(Self.amount),
                    note: fund.note
                )
            }
    }

    func goalStatus(_ status: PlannedPurchaseStatus) -> GoalStatus {
        switch status {
        case .planned: .wishlist
        case .reserved: .saving
        case .purchased: .bought
        case .cancelled: .cancelled
        }
    }

    func plannedPurchaseStatus(_ status: GoalStatus) -> PlannedPurchaseStatus {
        switch status {
        case .wishlist: .planned
        case .saving: .reserved
        case .bought: .purchased
        case .cancelled: .cancelled
        }
    }

    func goalFunding(_ funding: PlannedPurchaseFunding) -> GoalFundingKind {
        switch funding {
        case .cashOnPurchase: .cash
        case .sinkingFund: .sinkingFund
        case .financing: .financing
        }
    }

    func fundCustody(_ custody: SinkingFundCustody) -> FundCustodyKind {
        switch custody {
        case .virtualReservation: .virtual
        case .dedicatedAccount: .dedicated
        }
    }

    func fundStatus(_ status: SinkingFundStatus) -> FundStatusOption {
        switch status {
        case .active: .active
        case .paused: .paused
        case .completed: .completed
        case .cancelled: .cancelled
        }
    }

    func sinkingFundStatus(_ status: FundStatusOption) -> SinkingFundStatus {
        switch status {
        case .active: .active
        case .paused: .paused
        case .completed: .completed
        case .cancelled: .cancelled
        }
    }

    func paymentRequirement(currencyCode: String, fractionDigits: Int, rail: PaymentRailChoice) -> PaymentRequirement {
        PaymentRequirement(
            currency: Currency(code: currencyCode, minorUnitDigits: fractionDigits),
            acceptableRails: [paymentRail(rail)]
        )
    }

    func paymentRail(_ choice: PaymentRailChoice) -> PaymentRail {
        switch choice {
        case .card: .cardDebit
        case .transfer: .sepaCreditTransfer
        case .directDebit: .sepaDirectDebit
        case .electronic: .electronicPayment
        case .cash: .physicalCash
        }
    }

    func affordabilityPresentation(
        _ verdict: AffordabilityVerdict,
        document: FinanceDocument,
        settlementAccountID: String?
    ) -> AffordabilityPresentation {
        let accountName = settlementAccountID.flatMap { id in
            document.accounts.first { $0.id == id }?.name
        }
        let overall: AffordabilityOverallKind
        switch verdict.overall {
        case .affordable: overall = .affordable
        case .affordableConditionally: overall = .affordableConditionally
        case .notAffordable: overall = .notAffordable
        }
        let riskKind: AffordabilityRiskKind
        if verdict.timing.firstNegativeAfter != nil {
            riskKind = .hardDeficit
        } else if verdict.timing.firstBelowFloorAfter != nil {
            riskKind = .reserveWarning
        } else {
            riskKind = .none
        }
        let riskDay = verdict.timing.firstNegativeAfter ?? verdict.timing.firstBelowFloorAfter
        let income: String?
        if let certainty = verdict.funding.requiredCertainty {
            income = incomeCertaintyPhrase(certainty)
        } else {
            income = nil
        }
        let financingNote: String?
        if verdict.reasons.contains(.financingDoesNotDoubleCount) {
            financingNote = "The purchase counts once in the monthly budget. The instalments are later cash, not a second spend."
        } else {
            financingNote = nil
        }
        return AffordabilityPresentation(
            overall: overall,
            why: verdict.reasons.compactMap(affordabilityWhy),
            ledgerCash: Self.amount(verdict.cash.ledgerPool),
            reserved: Self.amount(verdict.cash.reserved),
            unreservedCash: Self.amount(verdict.cash.unreservedPool),
            cashCovers: verdict.cash.sufficient,
            budgetRemaining: verdict.budget.remaining.map(Self.amount),
            purchaseEconomic: Self.amount(verdict.economicAmount),
            budgetAfter: budgetAfter(verdict.budget),
            withinBudget: verdict.budget.withinCeiling,
            countsAsSpending: verdict.budget.countsAsSpending,
            settlementCovers: verdict.settlement.wouldSettle,
            settlementAvailable: Self.amount(verdict.settlement.settlementAvailable),
            poolUnreserved: Self.amount(verdict.settlement.poolUnreserved),
            settlementAccountName: accountName,
            firstRiskKind: riskKind,
            firstRiskDate: riskDay.map { Self.civilDay($0) },
            firstRiskLabel: humanRiskLabel(verdict.timing.firstRiskAfter, document: document),
            requiredIncome: income,
            sinkingReservedBefore: verdict.sinkingFundConsumption.map { Self.amount($0.reservedBefore) },
            sinkingConsumed: verdict.sinkingFundConsumption.map { Self.amount($0.consumed) },
            sinkingReservedAfter: verdict.sinkingFundConsumption.map { Self.amount($0.reservedAfter) },
            financingNote: financingNote
        )
    }

    private func budgetAfter(_ budget: AffordabilityBudgetAssessment) -> Amount? {
        guard let remaining = budget.remaining else { return nil }
        return Self.amount(
            Money(
                minorUnits: remaining.minorUnits - budget.economicAmount.minorUnits,
                currency: remaining.currency
            )
        )
    }

    private func humanRiskLabel(_ risk: ForecastResult.FirstRisk?, document: FinanceDocument) -> String? {
        guard let risk else { return nil }
        let key = risk.triggerLabel
        if let obligation = document.planning.recurringObligations.first(where: { $0.id == key }) {
            return obligation.name
        }
        if let income = document.incomeSources.first(where: { $0.id == key }) {
            return income.name
        }
        if key == "opening-balance" || risk.triggerEventID == "opening-balance" {
            return "Opening cash"
        }
        return key
    }

    static func planningValidationMessage(_ error: PlanningValidationError) -> String {
        switch error {
        case .duplicatePlannedPurchaseID:
            "A planned purchase with this identity already exists."
        case .duplicateSinkingFundID:
            "A sinking fund with this identity already exists."
        case .purchaseReferencesMissingFund:
            "That sinking fund is no longer available. Choose another, or pay with cash on the day."
        case .dedicatedFundReferencesMissingAccount:
            "Dedicated custody needs an existing account."
        case .dedicatedFundAccountCurrencyMismatch:
            "Dedicated custody needs an account in the same currency as the fund. Nothing is converted."
        case .negativeReservedAmount:
            "The amount set aside cannot be negative."
        case .reservedCurrencyMismatch:
            "The amount set aside must use the same currency as the target."
        case .sinkingFundedPurchaseCarriesOwnReservation:
            "A sinking fund already holds the reservation. This goal does not copy it."
        case .purchaseReferencesMissingInstallmentPlan:
            "That financing plan is no longer available."
        case .purchaseReferencesMissingBudget:
            "That budget line is no longer available."
        case .fundReferencesMissingGoal:
            "That linked goal is no longer available."
        case .installmentPlanOnNonFinancedPurchase:
            "A financing plan can only be attached when the goal is paid with financing."
        case .schemaVersionTooOldForPlanningState:
            "This document cannot hold goals or funds until it is saved as a current plan."
        }
    }

    static func affordabilityErrorMessage(_ error: AffordabilityError) -> String {
        switch error {
        case .emptyHorizon:
            "The plan window is empty, so this check cannot run."
        case .candidateDateOutsideHorizon:
            "Pick a date inside the current plan window."
        case .candidateAmountNotPositive:
            "Enter an amount greater than zero."
        case .financingProposalRequired:
            "Choose an existing financing plan. This check does not invent one."
        case .financingCurrencyMismatch:
            "The financing plan is in a different currency. Nothing is converted."
        case .duplicatePlannedPurchaseID, .duplicateSinkingFundID:
            "The plan data for this check is not valid."
        }
    }

    private func incomeCertaintyPhrase(_ certainty: IncomeCertainty) -> String {
        switch certainty {
        case .possible: "income that is only possible (not applied for or decided)"
        case .target: "income that is intended but not secured"
        case .expected: "income that is planned but not guaranteed"
        case .guaranteed: "guaranteed future income"
        case .received: "income already received"
        }
    }

    func affordabilityWhy(_ reason: AffordabilityReason) -> String? {
        switch reason {
        case .ineligibleCurrencyOrRail:
            "This payment cannot settle in that currency on that rail. Nothing is converted to cover it."
        case .foreignCurrencyNotConverted:
            "Foreign cash is not turned into euros to make this payment."
        case .candidateWouldFailToSettle, .settlementAccountInsufficient:
            nil
        case .poolWouldCoverButSettlementWouldNot:
            "You have enough cash overall, but this account does not have enough to make the payment."
        case .newPoolDeficit:
            "This would leave you short of cash."
        case .firstRiskMovedEarlier:
            "Cash would run out sooner."
        case .deepenedPoolDeficit:
            "An existing cash shortfall would get worse."
        case .overBudget:
            "This would go over this month's spending budget."
        case .withinBudget:
            "This stays within this month's spending budget."
        case .notEconomicSpending:
            "Setting money aside is not spending."
        case .sufficientUnreservedCash:
            "Unreserved cash covers this."
        case .firstRiskUnchanged:
            nil
        case .reservedMoneyIsNotSpent:
            "Money set aside is not treated as already spent."
        case .accountBalanceIsNotSafeToSpend:
            "An account balance is not the same as money that is free to use."
        case .financingDoesNotDoubleCount, .sinkingFundConsumed:
            nil
        case .insufficientUnreservedCash:
            "Unreserved cash does not cover this."
        case .newFloorBreach:
            "Cash would dip below the safety reserve, without going negative."
        case .dependsOnExcludedIncome:
            "This only works if income that is not in the normal plan actually arrives."
        case .sinkingFundDoesNotFullyCover:
            "The fund does not cover the whole amount; the rest would come from unreserved cash."
        }
    }

    private func holdingKind(_ kind: AccountKind) -> HoldingKind {
        switch kind {
        case .bank: .bank
        case .wallet: .wallet
        case .cash: .cash
        }
    }

    private func holdingSubtitle(_ kind: AccountKind) -> String {
        switch kind {
        case .bank: "Bank account"
        case .wallet: "Wallet"
        case .cash: "Cash in hand"
        }
    }

    static func railLabels(_ rails: Set<PaymentRail>) -> [String] {
        rails.sorted { $0.id < $1.id }.map {
            switch $0.id {
            case PaymentRail.sepaCreditTransfer.id: "Transfer"
            case PaymentRail.sepaDirectDebit.id: "Direct debit"
            case PaymentRail.cardDebit.id: "Card"
            case PaymentRail.electronicPayment.id: "Electronic payment"
            case PaymentRail.physicalCash.id: "Cash in hand"
            default: $0.summary
            }
        }
    }

    private func safeReason(_ safe: LiquiditySnapshot.SafeToSpendResult) -> SafeToSpendReason {
        if safe.isDeficit { return .shortfall(Self.amount(safe.rawHeadroom.magnitude)) }
        if safe.amount.isZero { return .unconstrained }
        return .liquidity
    }

    // MARK: - Risk and forecast events

    private func riskPoint(
        _ risk: ForecastResult.FirstRisk?,
        result: ForecastResult,
        document: FinanceDocument
    ) -> RiskPoint? {
        guard let risk else { return nil }
        let trigger = result.appliedEvents.first { $0.id == risk.triggerEventID }
        let dayBalance = result.dailyBalances.first { $0.day == risk.day }?.spendablePool
        let balance = result.lowestBalanceDate == risk.day ? result.lowestBalance : dayBalance
        return RiskPoint(
            date: Self.civilDay(risk.day),
            projectedBalance: Self.amount(balance ?? result.lowestBalance),
            triggerLabel: trigger.map { label(for: $0, document: document) } ?? risk.triggerLabel,
            triggerAmount: trigger.flatMap(eventMoney).map { Self.amount($0.magnitude) },
            // Straight from the risk the engine reported, alongside its day.
            // Not recomputed here from a headroom, a pool gap or a different
            // horizon: the amount and the date are one fact about one moment.
            shortfall: Self.amount(risk.shortfall.magnitude)
        )
    }

    private func plannedEvents(_ input: Inputs) -> [PlannedEvent] {
        input.overview.upcoming.compactMap { event in
            // The normal UI shows obligations and economic inflows. Deposits,
            // internal transfers and the dependent disposal remain rail movements,
            // not misleading spending/income rows.
            guard event.phase == .scheduledDebit || event.phase == .credit else { return nil }
            guard let rawAmount = eventMoney(event) else { return nil }
            let amount = personalAmount(for: event, rawAmount: rawAmount, document: input.document)
            let isInflow = !event.isOutflow
            return PlannedEvent(
                id: event.id,
                date: Self.civilDay(event.day),
                label: label(for: event, document: input.document),
                amount: isInflow ? Self.amount(amount) : Self.amount(amount.magnitude).negated,
                isInflow: isInflow,
                isGuaranteedButNotReceived: isInflow && event.certainty == .guaranteed,
                certaintyLabel: isInflow && event.certainty != nil && event.certainty! < .guaranteed
                    ? event.certainty!.label.capitalized
                    : nil,
                isRecovery: event.sourceRef.flatMap { id in input.document.debts.first { $0.id == id } } != nil,
                hasApproximateDate: input.document.expectedTransactions
                    .first { $0.id == event.sourceRef }?.datePrecision == .estimated,
                note: note(for: event, document: input.document)
            )
        }
    }

    private func eventMoney(_ event: ForecastEvent) -> Money? {
        switch event.effect {
        case let .credit(amount, _): amount
        case let .debit(amount, _): amount
        case let .directedDebit(amount, _): amount
        }
    }

    /// A pass-through arrival moves the gross account amount, but the planned
    /// resource shown to the person is only the explicitly owned share.
    private func personalAmount(
        for event: ForecastEvent,
        rawAmount: Money,
        document: FinanceDocument
    ) -> Money {
        guard let id = event.sourceRef,
              let transaction = document.expectedTransactions.first(where: { $0.id == id }),
              transaction.kind == .passThrough,
              transaction.legs.contains(where: \.isInflow) else { return rawAmount }
        return Economics.ownedShare(of: transaction, currency: rawAmount.currency)
    }

    private func label(for event: ForecastEvent, document: FinanceDocument) -> String {
        guard let reference = event.sourceRef else { return event.id }
        if let obligation = document.planning.recurringObligations.first(where: { $0.id == reference }) {
            return obligation.name
        }
        if let income = document.incomeSources.first(where: { $0.id == reference }) {
            return income.name
        }
        if let plan = document.installments.first(where: { $0.id == reference }) {
            return DisplayDescriptor.instalmentTitle(
                purchaseDescription: plan.purchaseDescription,
                provider: plan.provider
            )
        }
        if let debt = document.debts.first(where: { $0.id == reference }) {
            return debt.name
        }
        if let transaction = document.expectedTransactions.first(where: { $0.id == reference }) {
            if let sourceID = transaction.incomeSourceID,
               let source = document.incomeSources.first(where: { $0.id == sourceID }) {
                return source.name
            }
            return transactionKindLabel(transaction.kind)
        }
        return reference
    }

    private func note(for event: ForecastEvent, document: FinanceDocument) -> String? {
        guard let reference = event.sourceRef else { return nil }
        if let item = document.planning.recurringObligations.first(where: { $0.id == reference }) { return item.note }
        if let item = document.incomeSources.first(where: { $0.id == reference }) { return item.note }
        if let item = document.installments.first(where: { $0.id == reference }) { return item.note }
        if let item = document.debts.first(where: { $0.id == reference }) { return item.note }
        return document.expectedTransactions.first { $0.id == reference }?.note
    }

    // MARK: - Months

    func monthProjections(
        _ input: Inputs,
        plannedEvents: [PlannedEvent]
    ) throws -> [MonthProjection] {
        var eventsByMonth: [MonthKey: [PlannedEvent]] = [:]
        for event in plannedEvents {
            guard let key = Self.day(event.date)?.monthKey else {
                throw ProjectionError.invalidPlannedEventDate
            }
            eventsByMonth[key, default: []].append(event)
        }

        // The figures come from the forecast's own month ledger, never from
        // adding up the amounts written on the events. Two reasons, and both
        // have already produced a wrong screen:
        //
        // 1. A summary must use one arithmetic model. Summing event amounts for
        //    income and spending while taking `closing` from the balance chain
        //    is two, and they disagree — by the whole of a pass-through's gross
        //    arrival and by both legs of every internal transfer.
        // 2. What an event is *written* for is not what it *moves*. A payment
        //    that partly fails, a charge against an account outside the
        //    spendable pool, a credit landing in a cash pocket: each moves a
        //    different amount than it names. The ledger measures the pool.
        //
        // The ledger's four groups partition every movement of the pool, so
        // these rows reach `closing` exactly, and no phase can hide behind
        // them.
        let ledgers = input.forecast.monthLedgers.sorted { $0.key < $1.key }
        return ledgers.map { month, ledger in
            let all = eventsByMonth[month] ?? []
            // Product policy: the month headline is denominated in the plan's
            // own currency. A dirham obligation is real, but no rate has been
            // recorded for it, so it is listed rather than added — and never
            // summed into a euro total, which would either invent a rate or
            // trap on the currency mismatch. The ledger is denominated in the
            // pool's currency for the same reason, so a foreign charge already
            // contributes nothing to it.
            let events = all.filter { $0.amount.currencyCode == Currency.eur.code }
            let foreign = all.filter { $0.amount.currencyCode != Currency.eur.code }
            let unfunded = input.forecast.unfundedByMonth[month]
            let unfundedEUR = unfunded?.currencies.contains(.eur) == true
                ? Self.amount(input.forecast.unfunded(in: .eur, month: month))
                : nil
            let unfundedInOtherCurrencies = unfunded.map { bag in
                bag.currencies
                    .filter { $0 != .eur }
                    .map { Self.amount(bag.amount(in: $0)) }
            } ?? []
            return MonthProjection(
                month: CalendarMonth(
                    year: month.year,
                    month: month.month,
                    firstDay: Self.civilDay(month.firstDay)
                ),
                opening: Self.amount(ledger.opening),
                plannedIncome: Self.amount(ledger.income),
                committedSpending: Self.amount(ledger.committed),
                everydaySpending: Self.amount(ledger.everyday),
                closing: Self.amount(ledger.closing),
                unfundedEUR: unfundedEUR,
                unfundedInOtherCurrencies: unfundedInOtherCurrencies,
                events: events,
                eventsInOtherCurrencies: foreign
            )
        }
    }

    // MARK: - Budgets

    /// The month's budget, computed by `MonthlyBudgetEngine` rather than here.
    ///
    /// This method's whole job is translation: hand the engine the category
    /// key each transaction carries in the app's own vocabulary, and turn the
    /// report it returns into display types. No spending rule is re-decided on
    /// this side of the boundary.
    private func budgetOverview(
        document: FinanceDocument,
        today: Day,
        presentation: [String: TransactionPresentation]
    ) -> BudgetOverview {
        let report = MonthlyBudgetEngine.report(
            month: today.monthKey,
            today: today,
            document: document,
            categoryKeys: presentation.compactMapValues(\.categoryKey),
            currency: .eur
        )
        func line(_ line: BudgetLineProgress) -> BudgetLine {
            BudgetLine(
                key: line.id,
                name: line.name,
                symbolName: symbol(for: line.spendingClass),
                limit: Self.amount(line.target),
                spent: Self.amount(line.spent),
                committed: Self.amount(line.committed),
                remaining: Self.amount(line.remaining),
                remainingAfterCommitted: Self.amount(line.remainingAfterCommitted),
                fraction: line.fraction,
                rawFraction: line.rawFraction,
                isOverspent: line.isOverspent,
                isHousing: line.name.localizedCaseInsensitiveContains("rent")
                    || line.name.localizedCaseInsensitiveContains("housing"),
                isSuggested: line.confirmation == .suggested,
                dailyPace: line.dailyPace.map(Self.amount),
                weeklyPace: line.weeklyPace.map(Self.amount),
                spendingClass: Self.spendingClass(line.spendingClass)
            )
        }
        return BudgetOverview(
            monthLabel: monthLabel(report.month),
            summary: summary(report),
            target: Self.amount(report.target),
            unallocated: report.unallocated.map(Self.amount),
            uncategorized: Self.amount(report.uncategorized),
            financingRepayments: Self.amount(report.financingRepayments),
            daysInMonth: report.daysInMonth,
            daysElapsed: report.daysElapsed,
            daysRemaining: report.daysRemaining,
            isCurrentMonth: report.isCurrentMonth,
            lines: report.lines.map(line),
            otherCurrencyLines: report.otherCurrencyLines.map(line)
        )
    }

    private func summary(_ report: MonthlyBudgetReport) -> BudgetSummary {
        // Spending is measured against the gross ceiling when the plan states
        // one. Without a ceiling the allocated total is the only honest
        // comparison available, and `ceiling` stays nil so the screens can say
        // which of the two they are showing.
        let limit = Self.amount(report.ceiling ?? report.target)
        let spent = Self.amount(report.spent)
        let fraction = limit.minorUnits > 0
            ? min(max(Double(spent.minorUnits) / Double(limit.minorUnits), 0), 1)
            : 0
        return BudgetSummary(
            limit: limit,
            spent: spent,
            remaining: (limit - spent).clampedToZero,
            committed: Self.amount(report.committed),
            safeToSpend: Self.amount(report.safeToSpendBudget).clampedToZero,
            fraction: fraction,
            isOverspent: spent.minorUnits > limit.minorUnits,
            isNearLimit: fraction > 0.85,
            ceiling: report.ceiling.map(Self.amount)
        )
    }

    private func monthLabel(_ month: MonthKey) -> String {
        var components = DateComponents()
        components.year = month.year
        components.month = month.month
        components.day = 1
        guard let date = Calendar(identifier: .gregorian).date(from: components) else {
            return month.isoString
        }
        return date.formatted(.dateTime.month(.wide).year())
    }

    // MARK: - Activity

    private func activity(
        _ transactions: [Transaction],
        accounts: [Account],
        incomeSources: [IncomeSource],
        installmentPlans: [InstallmentPlan],
        presentation: [String: TransactionPresentation]
    ) -> [ActivityDay] {
        let names = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        let planNames = Dictionary(
            uniqueKeysWithValues: installmentPlans.map {
                ($0.id, DisplayDescriptor.instalmentTitle(
                    purchaseDescription: $0.purchaseDescription, provider: $0.provider
                ))
            }
        )
        let sourceNames = Dictionary(
            uniqueKeysWithValues: incomeSources.map { ($0.id, $0.name) }
        )
        return Dictionary(grouping: transactions, by: \.date)
            .map { day, values in
                let effects = values.map { Economics.effect(of: $0, currency: .eur) }
                let net = Money.sum(effects.map(\.netPersonalFlow), currency: .eur)
                return ActivityDay(
                    date: Self.civilDay(day),
                    net: Self.amount(net),
                    rows: values
                        .sorted { $0.id < $1.id }
                        .map {
                            activityRow(
                                $0,
                                accountNames: names,
                                incomeSourceNames: sourceNames,
                                installmentPlanNames: planNames,
                                metadata: presentation[$0.id]
                            )
                        }
                )
            }
            .sorted { $0.date > $1.date }
    }

    private func activityRow(
        _ transaction: Transaction,
        accountNames: [String: String],
        incomeSourceNames: [String: String],
        installmentPlanNames: [String: String],
        metadata: TransactionPresentation?
    ) -> ActivityRow {
        let effect = Economics.effect(of: transaction, currency: .eur)
        let displayMoney: Money = {
            switch transaction.kind {
            case .expense: return effect.spending.negated
            case .income: return effect.income
            case .refund: return effect.refund
            case .financingRepayment: return effect.financingRepayment.negated
            case .passThrough:
                if effect.accountMovementIn.isPositive { return effect.accountMovementIn }
                return effect.accountMovementOut.negated
            case .transfer, .cashWithdrawal, .currencyConversion:
                return transaction.legs.first(where: { $0.amount.currency == .eur })?.amount
                    ?? transaction.legs.first!.amount
            }
        }()
        let category = categoryDefinition(metadata?.categoryKey)
        let primaryLeg = transaction.legs.first(where: \.isOutflow)
            ?? transaction.legs.first
        let secondaryLeg = transaction.legs.first {
            $0.accountID != primaryLeg?.accountID && $0.isInflow
        }
        let primaryAccount = primaryLeg.map { accountNames[$0.accountID] ?? $0.accountID }
        let secondaryAccount = secondaryLeg.map { accountNames[$0.accountID] ?? $0.accountID }
        let incomeSource = transaction.incomeSourceID.flatMap { incomeSourceNames[$0] }
        let typeLabel = transactionKindLabel(transaction.kind)
        let title = metadata?.merchant?.nilIfBlank
            ?? ((transaction.kind == .income || transaction.kind == .passThrough) ? incomeSource : nil)
            ?? defaultActivityTitle(transaction, installmentPlanNames: installmentPlanNames)
        let trailing: String? = {
            switch transaction.lifecycle {
            case .pending: "Pending"
            case .reconciled: "Reconciled"
            case .reversed: "Reversed"
            case .cleared: nil
            }
        }()
        let owned: Amount? = transaction.kind == .passThrough && effect.passThroughNotMine.isPositive
            ? Self.amount(Economics.ownedShare(of: transaction, currency: .eur))
            : nil
        let flow: ActivityFlow = {
            switch effect.role {
            case .spending: .spending
            case .income: .income
            case .accountMovement: .movement
            case .passThrough: effect.income.isPositive ? .income : .movement
            case .refund, .financingRepayment, .none: .neutral
            }
        }()
        let categoryLabel: String? = {
            switch transaction.kind {
            case .income:
                return incomeSource ?? "Income"
            case .passThrough:
                return transaction.legs.contains(where: \.isInflow) ? (incomeSource ?? "Income") : category.name
            case .financingRepayment:
                return "Financing"
            case .transfer, .cashWithdrawal, .currencyConversion:
                return nil
            default:
                return category.name
            }
        }()
        let subtitle: String = {
            switch transaction.kind {
            case .transfer, .cashWithdrawal, .currencyConversion:
                return [primaryAccount, secondaryAccount].compactMap { $0 }.joined(separator: " → ")
            case .income:
                return [incomeSource ?? "Income", primaryAccount].compactMap { $0 }.joined(separator: " · ")
            case .passThrough:
                if transaction.legs.contains(where: \.isInflow) {
                    return [incomeSource ?? "Income", primaryAccount].compactMap { $0 }.joined(separator: " · ")
                }
                return [categoryLabel, primaryAccount].compactMap { $0 }.joined(separator: " · ")
            default:
                return [categoryLabel, primaryAccount].compactMap { $0 }.joined(separator: " · ")
            }
        }()
        return ActivityRow(
            id: transaction.id,
            title: title,
            subtitle: subtitle,
            symbolName: category.symbol,
            amount: Self.amount(displayMoney),
            trailingNote: trailing,
            ownedPortion: owned,
            isReversed: transaction.lifecycle == .reversed,
            isPending: transaction.lifecycle == .pending,
            flow: flow,
            primaryAccountID: primaryLeg?.accountID,
            primaryAccountLabel: primaryAccount,
            secondaryAccountID: secondaryLeg?.accountID,
            secondaryAccountLabel: secondaryAccount,
            incomeSourceID: transaction.incomeSourceID,
            incomeSourceLabel: incomeSource,
            categoryLabel: categoryLabel,
            counterparty: metadata?.merchant?.nilIfBlank,
            transactionTypeLabel: typeLabel,
            note: transaction.note,
            searchText: [title, subtitle, transaction.note, typeLabel].compactMap { $0 }.joined(separator: " ")
        )
    }

    private func defaultActivityTitle(
        _ transaction: Transaction,
        installmentPlanNames: [String: String]
    ) -> String {
        if let planID = transaction.installmentPlanID {
            return installmentPlanNames[planID] ?? "Financing repayment"
        }
        return transactionKindLabel(transaction.kind)
    }

    // MARK: - Lists

    private func commitments(_ obligations: [RecurringObligation]) -> [CommitmentGroup] {
        SpendingClass.allCases.compactMap { spendingClass in
            let lines = obligations.filter { $0.spendingClass == spendingClass }.map {
                CommitmentLine(
                    id: $0.id,
                    name: $0.name,
                    amount: Self.amount($0.amount),
                    cadenceLabel: recurrenceLabel($0.spec),
                    statusLabel: $0.commitmentStatus == .hypothetical ? "Hypothetical" : nil,
                    chargesCashNow: $0.commitmentStatus == .committed
                )
            }
            return lines.isEmpty ? nil : CommitmentGroup(title: spendingClassLabel(spendingClass), lines: lines)
        }
    }

    private func instalments(_ plans: [InstallmentPlan]) -> [InstalmentLine] {
        plans.filter { $0.status == .active }.map { plan in
            let scheduled = plan.installments.filter { $0.status == .scheduled }
            return InstalmentLine(
                id: plan.id,
                title: DisplayDescriptor.instalmentTitle(
                    purchaseDescription: plan.purchaseDescription, provider: plan.provider
                ),
                provider: plan.provider,
                remaining: Self.amount(plan.remainingAmount),
                paidCount: plan.installments.filter { $0.status == .paid }.count,
                totalCount: plan.installments.count,
                nextDueDate: scheduled.min { $0.dueDate < $1.dueDate }.map { Self.civilDay($0.dueDate) }
            )
        }
    }

    private func income(_ sources: [IncomeSource]) -> [IncomeGroup] {
        IncomeCertainty.allCases.reversed().compactMap { certainty in
            let lines = sources.filter { $0.effectiveCertainty(in: sources) == certainty }.map {
                IncomeLine(
                    id: $0.id,
                    name: $0.name,
                    amount: Self.amount($0.amount),
                    note: $0.note,
                    dependsOnAnother: !$0.dependsOn.isEmpty
                )
            }
            guard !lines.isEmpty else { return nil }
            return IncomeGroup(
                title: certainty.label.capitalized,
                explanation: certaintyExplanation(certainty),
                lines: lines
            )
        }
    }

    private func debts(_ debts: [Debt]) -> [DebtLine] {
        debts.map { debt in
            let paid = Money.sum(
                debt.paymentSchedule.filter { $0.status == .paid }.map(\.amount),
                currency: debt.originalAmount.currency
            )
            let scheduled = debt.paymentSchedule.filter { $0.status == .scheduled }
            let monthly = scheduled.first?.amount
                ?? Money(minorUnits: 0, currency: debt.originalAmount.currency)
            return DebtLine(
                id: debt.id,
                name: debt.name,
                creditor: nil,
                outstanding: Self.amount(debt.originalAmount - paid),
                monthlyRepayment: Self.amount(monthly),
                monthsToClear: scheduled.isEmpty ? nil : scheduled.count,
                note: debt.note
            )
        }
    }

    private func incomeSourceSummaries(
        _ sources: [IncomeSource],
        accounts: [Account],
        active: [String: Bool]
    ) -> [IncomeSourceSummary] {
        let accountNames = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        return sources.map { source in
            IncomeSourceSummary(
                id: source.id,
                name: source.name,
                certainty: Self.certainty(source.certainty),
                recurrenceLabel: recurrenceLabel(source.schedule),
                amount: Self.amount(source.amount),
                isActive: active[source.id] ?? true,
                preferredAccountID: source.arrivesOnAccount,
                preferredAccountName: source.arrivesOnAccount.flatMap { accountNames[$0] },
                note: source.note
            )
        }
    }

    // MARK: - Entry

    private func entryOptions(
        _ accounts: [Account],
        incomeSources: [IncomeSource],
        sourceActive: [String: Bool],
        lastExpenseAccountID: String?,
        lastIncomeAccountID: String?
    ) -> EntryOptions {
        let active = accounts.filter(\.isActive).sorted { $0.drawOrder < $1.drawOrder }
        let fallback = active.first { $0.kind == .wallet && $0.currency == .eur }
            ?? active.first { $0.currency == .eur && $0.kind != .cash }
            ?? active.first
        let activeIDs = Set(active.map(\.id))
        let expenseDefault = lastExpenseAccountID.flatMap { activeIDs.contains($0) ? $0 : nil }
            ?? fallback?.id
        let incomeDefault = lastIncomeAccountID.flatMap { activeIDs.contains($0) ? $0 : nil }
            ?? active.first { $0.currency == .eur && $0.kind == .bank }?.id
            ?? fallback?.id
        return EntryOptions(
            accounts: active.map {
                AccountOption(
                    id: $0.id,
                    name: $0.name,
                    kind: holdingKind($0.kind),
                    currencyCode: $0.currency.code,
                    fractionDigits: $0.currency.minorUnitDigits
                )
            },
            incomeSources: incomeSources
                .filter { sourceActive[$0.id] ?? true }
                .map {
                    IncomeSourceOption(
                        id: $0.id,
                        name: $0.name,
                        preferredAccountID: $0.arrivesOnAccount.flatMap {
                            activeIDs.contains($0) ? $0 : nil
                        }
                    )
                },
            categories: Self.categories.map {
                CategoryOption(
                    key: $0.key,
                    name: $0.name,
                    symbolName: $0.symbol,
                    isIncome: $0.isIncome,
                    isTransfer: $0.isTransfer
                )
            },
            defaultExpenseAccountID: expenseDefault,
            defaultIncomeAccountID: incomeDefault
        )
    }

    /// Turns a draft into a domain transaction, or throws saying why it is not
    /// one. Every rejection is named: nothing about an entry is dropped, and
    /// nothing unsupported is approximated into something that would persist as
    /// a different financial fact.
    func transaction(
        from draft: TransactionDraft,
        accounts: [Account],
        incomeSources: [IncomeSource],
        incomeSourceActive: [String: Bool]
    ) throws -> MappedTransaction {
        guard let account = accounts.first(where: { $0.id == draft.accountID }) else {
            throw AppEntryError.unknownAccount(id: draft.accountID)
        }
        guard account.isActive else { throw AppEntryError.inactiveAccount(id: account.id) }
        guard account.currency.code == draft.amount.currencyCode else {
            throw AppEntryError.amountCurrencyMismatch(
                amountCurrency: draft.amount.currencyCode,
                accountCurrency: account.currency.code
            )
        }
        guard draft.amount.isPositive else { throw AppEntryError.invalidAmount }
        let amount = Self.money(draft.amount).magnitude
        var kind: TransactionKind
        var legs: [AccountLeg]
        var ownership: [OwnershipSplit]?

        switch draft.kind {
        case .expense:
            // FinanceCore has no partial-consumption model, so an expense share
            // cannot be honoured. Refusing it keeps the app from storing a
            // full-price expense while the sheet implied a half one.
            guard draft.ownShare == nil else { throw AppEntryError.sharedExpenseNotSupported }
            kind = .expense
            legs = [AccountLeg(accountID: account.id, amount: amount.negated)]
            ownership = nil
        case .income:
            guard let sourceID = draft.incomeSourceID else {
                throw AppEntryError.missingIncomeSource
            }
            guard incomeSources.contains(where: { $0.id == sourceID }) else {
                throw AppEntryError.unknownIncomeSource(id: sourceID)
            }
            guard incomeSourceActive[sourceID] ?? true else {
                throw AppEntryError.inactiveIncomeSource(id: sourceID)
            }
            legs = [AccountLeg(accountID: account.id, amount: amount)]
            if let ownShare = draft.ownShare.map(Self.money) {
                guard ownShare.isPositive,
                      ownShare.currency == amount.currency,
                      ownShare.minorUnits <= amount.minorUnits else {
                    throw AppEntryError.invalidOwnShare
                }
                if ownShare.minorUnits == amount.minorUnits {
                    // The whole arrival is the owner's: ordinary income, not a
                    // pass-through with a single self-share.
                    kind = .income
                    ownership = nil
                } else {
                    kind = .passThrough
                    ownership = [
                        OwnershipSplit(ownerID: "self", isSelf: true, amount: ownShare),
                        OwnershipSplit(ownerID: "pass-through-owner", isSelf: false, amount: amount - ownShare)
                    ]
                }
            } else {
                kind = .income
                ownership = nil
            }
        case .transfer:
            guard draft.ownShare == nil else { throw AppEntryError.invalidOwnShare }
            guard let counterID = draft.counterAccountID else {
                throw AppEntryError.missingCounterAccount
            }
            guard counterID != account.id else { throw AppEntryError.counterAccountIsSource }
            guard let counter = accounts.first(where: { $0.id == counterID }) else {
                throw AppEntryError.unknownCounterAccount(id: counterID)
            }
            guard counter.isActive else {
                throw AppEntryError.inactiveCounterAccount(id: counter.id)
            }
            guard counter.currency == account.currency else {
                throw AppEntryError.transferCurrencyMismatch(
                    from: account.currency.code,
                    to: counter.currency.code
                )
            }
            kind = counter.kind == .cash ? .cashWithdrawal : .transfer
            legs = [
                AccountLeg(accountID: account.id, amount: amount.negated),
                AccountLeg(accountID: counter.id, amount: amount)
            ]
            ownership = nil
        }

        let transaction = Transaction(
            id: "manual-\(UUID().uuidString.lowercased())",
            date: try Self.requiredDay(draft.day, or: AppEntryError.invalidDate),
            kind: kind,
            legs: legs,
            ownership: ownership,
            incomeSourceID: draft.kind == .income ? draft.incomeSourceID : nil,
            factivity: .observed,
            lifecycle: .pending,
            datePrecision: .exact,
            note: draft.notes,
            provenance: Provenance(source: "MANUAL-ENTRY", evidenceGrade: .userConfirmed)
        )
        return MappedTransaction(
            transaction: transaction,
            presentation: TransactionPresentation(categoryKey: draft.categoryKey, merchant: draft.merchant)
        )
    }

    /// Kept for boundary-focused tests and non-income callers. Income entry is
    /// intentionally refused without the catalog passed by the store.
    func transaction(from draft: TransactionDraft, accounts: [Account]) throws -> MappedTransaction {
        try transaction(
            from: draft,
            accounts: accounts,
            incomeSources: [],
            incomeSourceActive: [:]
        )
    }

    // MARK: - Display vocabulary owned by the app

    private struct CategoryDefinition {
        let key: String
        let name: String
        let symbol: String
        var isIncome = false
        var isTransfer = false
    }

    private static let categories: [CategoryDefinition] = [
        .init(key: "housing", name: "Housing", symbol: "house"),
        .init(key: "bills", name: "Bills", symbol: "bolt"),
        .init(key: "food", name: "Groceries", symbol: "fork.knife"),
        .init(key: "campus-meals", name: "Campus meals", symbol: "graduationcap.circle"),
        .init(key: "eating-out", name: "Eating out", symbol: "takeoutbag.and.cup.and.straw"),
        .init(key: "transport", name: "Transport", symbol: "tram"),
        .init(key: "subscriptions", name: "Subscriptions", symbol: "repeat"),
        .init(key: "household", name: "Household & personal", symbol: "basket"),
        .init(key: "shopping", name: "Shopping", symbol: "bag"),
        .init(key: "health", name: "Health", symbol: "cross.case"),
        .init(key: "entertainment", name: "Entertainment", symbol: "theatermasks"),
        .init(key: "education", name: "Education", symbol: "graduationcap"),
        .init(key: "income", name: "Income", symbol: "arrow.down.circle", isIncome: true),
        .init(key: "transfers", name: "Transfers", symbol: "arrow.left.arrow.right", isTransfer: true),
        .init(key: "other", name: "Other", symbol: "ellipsis.circle")
    ]

    private func categoryDefinition(_ key: String?) -> CategoryDefinition {
        Self.categories.first { $0.key == key } ?? Self.categories.last!
    }

    private func transactionKindLabel(_ kind: TransactionKind) -> String {
        switch kind {
        case .expense: "Expense"
        case .income: "Income"
        case .transfer: "Transfer"
        case .refund: "Refund"
        case .financingRepayment: "Financing repayment"
        case .passThrough: "Pass-through"
        case .cashWithdrawal: "Cash withdrawal"
        case .currencyConversion: "Currency conversion"
        }
    }

    private func recurrenceLabel(_ spec: RecurrenceSpec) -> String {
        switch spec {
        case let .oneShot(on): "Once · \(on.isoString)"
        case let .monthly(day, _, _): "Monthly · day \(day)"
        case let .monthlyWindow(earliest, latest, _, _): "Monthly · days \(earliest)–\(latest)"
        }
    }

    private func spendingClassLabel(_ value: SpendingClass) -> String {
        switch value {
        case .essential: "Essential"
        case .flexible: "Flexible"
        case .optional: "Optional"
        }
    }

    private func symbol(for value: SpendingClass) -> String {
        switch value {
        case .essential: "basket"
        case .flexible: "slider.horizontal.3"
        case .optional: "sparkles"
        }
    }

    private func certaintyExplanation(_ value: IncomeCertainty) -> String {
        switch value {
        case .received: "Already received and part of account truth."
        case .guaranteed: "Committed for a named date, but not received yet."
        case .expected: "Dated and realistic, but not secured."
        case .target: "Being pursued; included only in upside planning."
        case .possible: "Contingent and excluded unless explicitly selected."
        }
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

// MARK: - Live sync directory

extension DomainMapper {
    /// Maps the backend's view of connections and accounts into screen values.
    ///
    /// The remote account id survives here because mapping needs a handle to
    /// bind, but nothing else does: `ProviderAccountBinding` — what the rest of
    /// the app sees — omits it entirely.
    func syncDirectory(
        connections: [RemoteConnectionSummary],
        remoteAccounts: [RemoteAccountSummary],
        document: FinanceDocument
    ) -> (connections: [ProviderConnectionStatus], accounts: [MappableRemoteAccount]) {
        let accountNames = Dictionary(
            document.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }
        )
        let bindingByRemote = Dictionary(
            document.externalAccountBindings.filter(\.isActive)
                .map { ($0.remoteOpaqueAccountID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return (
            connections.map { connection in
                ProviderConnectionStatus(
                    id: connection.id,
                    providerName: Self.providerDisplayName(connection.provider),
                    institution: connection.institution,
                    state: Self.connectionState(connection.status),
                    consentExpires: connection.validUntil.map(Self.civilDay),
                    lastSyncedAt: connection.lastSuccessfulSyncAt,
                    // A backend error code is operational detail. The person is
                    // told that something failed, never what the provider said.
                    lastErrorMessage: connection.lastErrorCode == nil
                        ? nil
                        : "The last sync of this connection did not complete."
                )
            },
            remoteAccounts.map { account in
                let binding = bindingByRemote[account.id]
                return MappableRemoteAccount(
                    id: account.id,
                    providerName: Self.providerDisplayName(account.provider),
                    displayName: account.displayName
                        ?? account.product
                        ?? Self.providerDisplayName(account.provider),
                    currencyCode: account.currencyCode,
                    mappedLocalAccountID: binding?.localAccountID,
                    mappedLocalAccountName: binding.flatMap { accountNames[$0.localAccountID] },
                    syncStartBoundary: binding.map { Self.civilDay($0.syncStartBoundary) }
                )
            }
        )
    }

    static func providerDisplayName(_ provider: ExternalProvider) -> String {
        switch provider {
        case .bnp: "BNP"
        case .paypal: "PayPal"
        case .revolut: "Revolut"
        default: provider.rawValue.capitalized
        }
    }

    /// Unknown states become `.unknown` rather than being read as connected.
    /// Guessing "fine" about consent is the failure that silently stops sync.
    static func connectionState(_ token: String) -> ProviderConnectionState {
        switch token {
        case "connected": .connected
        case "expiringSoon": .expiringSoon
        case "reauthorizationRequired": .reauthorizationRequired
        case "revoked": .revoked
        default: .unknown
        }
    }
}
