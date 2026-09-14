/// The conceptual projection of one period: everything that decides what the
/// period *means*, and nothing that merely records when a machine looked.
///
/// Phase 2.9A implements the projection and its equality only. There is no
/// hashing and no persistence: two projections are compared by value, which is
/// exactly enough to answer "has this period changed since it was closed?"
/// once a baseline exists to compare against.
///
/// ## What is deliberately excluded
///
/// Operational clocks are not semantics. A period whose meaning is identical
/// must project identically however many times it was synced:
///
/// - sync request / completion times
/// - `CurrentPendingProviderSnapshot.authoritativeAt`
/// - provider `lastSuccessfulSyncAt`
/// - `ExternalObservation.observedAt` and `ProviderBalanceSnapshot.observedAt`
/// - `ExternalObservationResolution.resolvedAt`
/// - UI labels, section order, and any cached or presentational value
/// - the identity and multiplicity of transport-only pending snapshot rows
///
/// Coverage contributes *normalized* semantics, not authority timestamps:
/// complete coverage projects as `.complete` and nothing else, so a later,
/// wider complete coverage of the same period is semantically equal to an
/// earlier, narrower one.
///
/// ## What the projection admits
///
/// Observations enter by `ExternalObservation.economicPeriodDay` — the one
/// implementation of the period rule — and only when
/// `isCheckpointSemanticObservation` holds. Two things are therefore absent:
/// rows resolved `.outsideSyncBoundary`, which sit before their binding's own
/// start, and transport-only pending snapshots, whose ids are minted per sync
/// run and accumulate without ever changing what a period means. A durable row
/// whose provider status has *regressed* is not transport-only and stays.
///
/// Transactions enter by `Transaction.date` and only when they are observed,
/// matching what `ReviewEngine` counts as the period's economics.
///
/// ## The closure this exists to support
///
/// For a closeable period, two equal projections must imply equal
/// checkpoint-relevant exception and safe-claim state. That is why the
/// observation fact carries provider identity, provider eligibility, binding
/// activity and any aggregate relationship: each can change which exceptions
/// a period carries — and therefore what it may truthfully claim — without
/// moving a single euro.
///
/// Budget attribution and refund dependencies enter as `SemanticBudgetFact`,
/// adapted from the same resolved `ReviewBudget` that drives the shipped
/// period spending figure and category exception. Raw category keys alone
/// cannot say whether a budget still claims that category, or whether a
/// prior-period original changes the current refund's resolved treatment.

// MARK: - Interval

public struct SemanticInterval: Hashable, Sendable, Codable, Comparable {
    public let start: Day
    public let end: Day

    public init(_ interval: ReviewInterval) {
        self.start = interval.start
        self.end = interval.end
    }

    public init(start: Day, end: Day) {
        self.start = start
        self.end = end
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.start != rhs.start ? lhs.start < rhs.start : lhs.end < rhs.end
    }
}

// MARK: - Coverage semantics

/// Coverage as it bears on meaning.
///
/// Completeness is one fact. *Which* affirmative windows produced it is
/// authority detail, and folding it in would make two equally-complete
/// readings of one period compare unequal.
public enum SemanticCoverage: Hashable, Sendable, Codable {
    case complete
    case incomplete(
        status: ReviewCoverageStatus,
        missing: [SemanticInterval],
        reasons: [ReviewCoverageReasonKind]
    )

    public init(_ coverage: ReviewCoverage) {
        guard coverage.status != .complete else {
            self = .complete
            return
        }
        self = .incomplete(
            status: coverage.status,
            missing: coverage.missingIntervals.map(SemanticInterval.init).sorted(),
            reasons: coverage.reasons.map(\.kind).uniquedAndSorted()
        )
    }
}

// MARK: - Facts

/// One account movement of one transaction. Sorted, so leg order in the
/// document cannot change the projection.
public struct SemanticLegFact: Hashable, Sendable, Codable, Comparable {
    public let accountID: String
    public let minorUnits: Int64
    public let currencyCode: String

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.accountID != rhs.accountID { return lhs.accountID < rhs.accountID }
        if lhs.currencyCode != rhs.currencyCode { return lhs.currencyCode < rhs.currencyCode }
        return lhs.minorUnits < rhs.minorUnits
    }
}

/// A transaction's economic meaning. `note`, `provenance` free text and
/// creation clocks are not here; a reworded note does not change the month.
public struct SemanticTransactionFact: Hashable, Sendable, Codable, Comparable {
    public let id: String
    public let day: Day
    public let kind: TransactionKind
    public let lifecycle: TransactionLifecycle
    public let factivity: Factivity
    public let legs: [SemanticLegFact]
    public let incomeSourceID: String?
    public let ownedMinorUnits: Int64?
    public let categoryKey: String?

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.id < rhs.id }
}

/// The aggregate relationship an observation carries, when one has been
/// established elsewhere.
///
/// The pairing is computed by the layer that owns that policy and arrives here
/// as a typed fact; this file establishes no relationship of its own. It is
/// carried because the matching window reaches a few days either side of the
/// observation, so the transactions that *make* the limitation what it is can
/// sit in the neighbouring period. Without the pairing on the record, changing
/// one of those transactions would dissolve the exception while this period
/// projected identically.
public struct SemanticAggregateFact: Hashable, Sendable, Codable {

    public let basis: AggregateEvidenceBasis
    /// Sorted, so the order the pairing was discovered in cannot leak in.
    public let pairedTransactionIDs: [String]

    public init(basis: AggregateEvidenceBasis, pairedTransactionIDs: [String]) {
        self.basis = basis
        self.pairedTransactionIDs = pairedTransactionIDs.sorted()
    }
}

/// A provider observation's meaning: what the provider says, what a person has
/// decided about it, and the provider-side state that decides what the period
/// may still claim. `observedAt` and `resolvedAt` are excluded — a re-sync of
/// the identical row changes neither.
///
/// `identity`, `providerEligibleForEconomicActual` and `bindingIsActive` are
/// here because `eligibleForEconomicActual` is the conjunction of the first two
/// with `status`, and a `providerStatusConflict` exception turns on exactly
/// that conjunction while binding activity decides whether the exception is
/// raised at all. None of them moves a euro; all of them move what the period
/// may claim, which is why they belong to its meaning.
public struct SemanticObservationFact: Hashable, Sendable, Codable, Comparable {
    public let id: String
    public let statusToken: String
    public let identity: ExternalObservationIdentity
    public let providerEligibleForEconomicActual: Bool
    public let bindingIsActive: Bool
    public let resolution: ObservationResolutionState
    public let minorUnits: Int64
    public let currencyCode: String
    public let economicDay: Day?
    public let links: [SemanticEvidenceLinkFact]
    public let aggregate: SemanticAggregateFact?

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.id < rhs.id }
}

public struct SemanticEvidenceLinkFact: Hashable, Sendable, Codable, Comparable {
    public let transactionID: String
    public let role: ExternalEvidenceRole

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.transactionID != rhs.transactionID
            ? lhs.transactionID < rhs.transactionID
            : lhs.role.rawValue < rhs.role.rawValue
    }
}

/// An expected occurrence and how it stands. The settling transaction is part
/// of the meaning; the day the settlement was recorded is not.
public struct SemanticExpectationFact: Hashable, Sendable, Codable, Comparable {
    public let obligationID: String
    public let expectedDay: Day
    public let minorUnits: Int64
    public let currencyCode: String
    public let statusToken: String
    public let settledByTransactionID: String?

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.obligationID != rhs.obligationID { return lhs.obligationID < rhs.obligationID }
        return lhs.expectedDay < rhs.expectedDay
    }
}

// MARK: - Projection

public struct SemanticPeriodProjection: Hashable, Sendable, Codable {

    public let period: SemanticInterval
    public let kind: ReviewPeriodKind
    public let coverage: SemanticCoverage
    public let budget: SemanticBudgetFact
    public let transactions: [SemanticTransactionFact]
    public let observations: [SemanticObservationFact]
    public let expectations: [SemanticExpectationFact]

    /// Every array is sorted here, once, so two projections of the same
    /// meaning are equal whatever order the document happened to hold.
    public init(
        period: SemanticInterval,
        kind: ReviewPeriodKind,
        coverage: SemanticCoverage,
        budget: SemanticBudgetFact,
        transactions: [SemanticTransactionFact],
        observations: [SemanticObservationFact],
        expectations: [SemanticExpectationFact]
    ) {
        self.period = period
        self.kind = kind
        self.coverage = coverage
        self.budget = budget
        self.transactions = transactions.sorted()
        self.observations = observations.sorted()
        self.expectations = expectations.sorted()
    }
}

// MARK: - Builder

/// Projects an existing document. It classifies nothing and computes no
/// economics of its own: inputs are document facts or resolved engine output.
public enum SemanticPeriodProjectionBuilder {

    /// No parameter here carries a default.
    ///
    /// `categoryKeys` used to default to `[:]`, and the one production caller
    /// silently accepted it: every projected transaction carried a nil
    /// category, so a budget recategorisation — which changes what the period
    /// may claim about category completeness — projected as no change at all.
    /// A missing fact is not an empty fact, so every caller now has to say
    /// what it knows.
    ///
    /// - Parameters:
    ///   - budget: the period's resolved ReviewBudget, adapted without rules.
    ///   - categoryKeys: transaction id → budget category key, from the same
    ///     map the budget report itself uses. Not recomputed here.
    ///   - aggregateFacts: observation id → the aggregate relationship the
    ///     evidence layer established for it. Not established here.
    ///   - expectations: the period's expanded occurrences, from the engine.
    public static func projection(
        for interval: ReviewInterval,
        kind: ReviewPeriodKind,
        in document: FinanceDocument,
        coverage: ReviewCoverage,
        budget: SemanticBudgetFact,
        categoryKeys: [String: String],
        aggregateFacts: [String: SemanticAggregateFact],
        expectations: [ExpectedOccurrence]
    ) -> SemanticPeriodProjection {

        // `document.transactions` is the observed-economics list — persistence
        // partitions on factivity and `ReviewEngine.collectFacts` filters the
        // same way — but an interchange-imported document is not validated on
        // that, so the period's economics are stated here rather than assumed.
        // An expected transaction is not a fact and must not move a checkpoint.
        let transactions = document.transactions
            .filter { $0.factivity == .observed && interval.contains($0.date) }
            .map { transaction in
                SemanticTransactionFact(
                    id: transaction.id,
                    day: transaction.date,
                    kind: transaction.kind,
                    lifecycle: transaction.lifecycle,
                    factivity: transaction.factivity,
                    legs: transaction.legs.map {
                        SemanticLegFact(
                            accountID: $0.accountID,
                            minorUnits: $0.amount.minorUnits,
                            currencyCode: $0.amount.currency.code
                        )
                    }.sorted(),
                    incomeSourceID: transaction.incomeSourceID,
                    ownedMinorUnits: ownedMinorUnits(of: transaction),
                    categoryKey: categoryKeys[transaction.id]
                )
            }

        let resolutions = Dictionary(
            document.observationResolutions.map { ($0.observationID, $0.state) },
            uniquingKeysWith: { first, _ in first }
        )
        var linksByObservation: [String: [SemanticEvidenceLinkFact]] = [:]
        for link in document.externalEvidenceLinks {
            linksByObservation[link.observationID, default: []].append(
                SemanticEvidenceLinkFact(transactionID: link.transactionID, role: link.role)
            )
        }

        let bindingIsActive = Dictionary(
            document.externalAccountBindings.map { ($0.id, $0.isActive) },
            uniquingKeysWith: { first, _ in first }
        )

        let observations = document.externalObservations
            .compactMap { observation -> SemanticObservationFact? in
                // Absence is never "reviewed". An observation with no explicit
                // resolution row projects as unreviewed rather than dropping
                // out of the period's meaning. `validate` forbids that state,
                // so this is a floor, not a path.
                let resolution = resolutions[observation.id] ?? .unreviewed
                guard observation.isCheckpointSemanticObservation(resolution: resolution),
                      let day = observation.economicPeriodDay,
                      interval.contains(day)
                else { return nil }

                return SemanticObservationFact(
                    id: observation.id,
                    statusToken: observation.status.token,
                    identity: observation.identity,
                    providerEligibleForEconomicActual:
                        observation.providerEligibleForEconomicActual,
                    // A binding the document does not carry cannot be called
                    // active. `validate` forbids that too.
                    bindingIsActive: bindingIsActive[observation.bindingID] ?? false,
                    resolution: resolution,
                    minorUnits: observation.amount.minorUnits,
                    currencyCode: observation.amount.currency.code,
                    economicDay: day,
                    links: (linksByObservation[observation.id] ?? []).sorted(),
                    aggregate: aggregateFacts[observation.id]
                )
            }

        let expectationFacts = expectations
            .filter { interval.contains($0.expectedDay) }
            .map { occurrence in
                SemanticExpectationFact(
                    obligationID: occurrence.obligationID,
                    expectedDay: occurrence.expectedDay,
                    minorUnits: occurrence.amount.minorUnits,
                    currencyCode: occurrence.amount.currency.code,
                    statusToken: statusToken(occurrence.status),
                    settledByTransactionID: settlingTransactionID(occurrence.status)
                )
            }

        return SemanticPeriodProjection(
            period: SemanticInterval(interval),
            kind: kind,
            coverage: SemanticCoverage(coverage),
            budget: budget,
            transactions: transactions,
            observations: observations,
            expectations: expectationFacts
        )
    }

    /// The self-owned share a transaction states, in minor units. nil when the
    /// transaction states no ownership at all — which is not the same fact as
    /// stating a zero share.
    private static func ownedMinorUnits(of transaction: Transaction) -> Int64? {
        guard let ownership = transaction.ownership, !ownership.isEmpty else { return nil }
        return ownership.filter(\.isSelf).reduce(Int64(0)) { $0 + $1.amount.minorUnits }
    }

    private static func statusToken(_ status: OccurrenceStatus) -> String {
        switch status {
        case .due: "due"
        case .overdue: "overdue"
        case .paid: "paid"
        case .skipped: "skipped"
        case .noLongerDue: "noLongerDue"
        }
    }

    private static func settlingTransactionID(_ status: OccurrenceStatus) -> String? {
        if case let .paid(transactionID) = status { return transactionID }
        return nil
    }
}

// MARK: - Helpers

private extension Array where Element: Hashable & RawRepresentable, Element.RawValue == String {
    /// Deduplicated and ordered by raw value, so reason order in a coverage
    /// result cannot change a projection.
    func uniquedAndSorted() -> [Element] {
        Array(Set(self)).sorted { $0.rawValue < $1.rawValue }
    }
}
