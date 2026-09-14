import FinanceCore
import Foundation

/// The one place Phase 2.9A's pieces are assembled.
///
/// ## Ownership
///
/// A composition, not an engine. It calls the adapters, hands their output to
/// `AttentionCoordinator` and `PeriodCheckpointEvaluator`, and does nothing
/// else. There is no arithmetic here and no policy that is not already stated
/// in one of those files.
///
/// Everything it needs arrives on `Input`: no store, no clock, no network. The
/// same input always produces the same output, which is what lets a read-only
/// copy of the real store be evaluated without touching it.
enum AttentionComposition {

    /// Authoritative results, gathered by the caller.
    ///
    /// Each engine result is optional in exactly one sense: nil means *that
    /// engine did not produce a result*, which is recorded as an unavailable
    /// source for the domains that need it — never as a zero, and never as an
    /// answer.
    struct Input: Sendable {
        var document: FinanceDocument
        var asOf: Day
        var accountNames: [String: String]

        /// One already-successful forecast. Never re-run here.
        var forecast: ForecastResult?
        /// One already-successful review of `period`. Never re-run here.
        var review: ReviewResult?
        /// Expanded occurrences, or nil when expansion did not succeed.
        var occurrences: [ExpectedOccurrence]?
        /// The evidence review queue, or nil when it could not be read.
        var observations: [SyncedObservationItem]?

        var freshness: BankFreshness
        /// Accounts the spendable pool depends on for which no usable current
        /// amount could be established.
        var accountsWithoutUsableAmount: Set<String>

        /// Transaction id → budget category key, from the store's own
        /// authoritative presentation map — the same one the budget report
        /// reads. Deliberately has no default: a period whose spend is
        /// categorised and a period whose categories were never supplied are
        /// different facts, and silently defaulting them to empty is how the
        /// projection came to be blind to recategorisation.
        var categoryKeys: [String: String]

        /// What a read of this period's stored checkpoint history returned.
        ///
        /// Supplied, never read here: the composition owns no store. The
        /// default is the same "persistence was not consulted" state
        /// `PeriodCheckpointRequest` defaults to, so a caller that does not
        /// read history establishes nothing rather than asserting a period was
        /// never closed. Production reads it through
        /// `PeriodCheckpointBaselineReader`.
        var checkpointBaseline: PeriodCheckpointBaselineSource

        /// The acknowledgment decisions a person has explicitly confirmed for
        /// this period, as live interaction state.
        ///
        /// Typed and supplied, exactly like `checkpointBaseline`: the only
        /// producer is `PeriodCheckpointAcknowledgmentConfirmation.confirm`,
        /// which honours a decision only when it is value-equal to a carried
        /// exception. There is no identifier a caller could hand in instead.
        /// The default is `.noDecisions` — nothing decided, everything
        /// undecided — which is what every caller but the ended-month
        /// verification interaction supplies, and what production evaluated
        /// before that interaction existed.
        ///
        /// Nothing here is read from or written to a store. A confirmation
        /// lives as long as the interaction that made it.
        var confirmedAcknowledgments: PeriodCheckpointConfirmedAcknowledgments

        var period: ReviewInterval
        var periodKind: ReviewPeriodKind
        var periodLabel: String

        init(
            document: FinanceDocument,
            asOf: Day,
            accountNames: [String: String] = [:],
            forecast: ForecastResult? = nil,
            review: ReviewResult? = nil,
            occurrences: [ExpectedOccurrence]? = nil,
            observations: [SyncedObservationItem]? = nil,
            freshness: BankFreshness = .notConnected,
            accountsWithoutUsableAmount: Set<String> = [],
            categoryKeys: [String: String],
            checkpointBaseline: PeriodCheckpointBaselineSource
                = .unavailable(.noBaselinePersistence),
            confirmedAcknowledgments: PeriodCheckpointConfirmedAcknowledgments = .noDecisions,
            period: ReviewInterval,
            periodKind: ReviewPeriodKind = .monthly,
            periodLabel: String = ""
        ) {
            self.document = document
            self.asOf = asOf
            self.accountNames = accountNames
            self.forecast = forecast
            self.review = review
            self.occurrences = occurrences
            self.observations = observations
            self.freshness = freshness
            self.accountsWithoutUsableAmount = accountsWithoutUsableAmount
            self.categoryKeys = categoryKeys
            self.checkpointBaseline = checkpointBaseline
            self.confirmedAcknowledgments = confirmedAcknowledgments
            self.period = period
            self.periodKind = periodKind
            self.periodLabel = periodLabel
        }
    }

    struct Output: Sendable {
        let attention: AttentionState
        let readiness: PeriodCheckpointReadiness
        /// Every comparable provider/ledger difference, whether or not any of
        /// them became a task. Refinement B's reconciliation facts.
        let driftFacts: [CurrentAccountDriftFact]
        let availability: AttentionSourceAvailability
    }

    static func evaluate(_ input: Input) -> Output {

        var availability = AttentionSourceAvailability()
        var proposals: [AttentionCandidateProposal] = []

        // Current account truth. Holdings are derived by `CurrentHoldings`;
        // this reads its verdict and never recomputes a balance.
        let driftFacts = AttentionFactAdapters.driftFacts(
            in: input.document, asOf: input.asOf, accountNames: input.accountNames
        )
        availability.record(
            .currentAccountTruth,
            input.accountsWithoutUsableAmount.isEmpty
                ? .available
                : .incoherent(.resultInternallyInconsistent)
        )

        let basis = AttentionFactAdapters.driftPromotionBasis(
            facts: driftFacts,
            freshness: input.freshness,
            accountsWithoutUsableAmount: input.accountsWithoutUsableAmount
        )
        if let drift = AttentionFactAdapters.driftProposal(facts: driftFacts, basis: basis) {
            proposals.append(drift)
        }

        // Provider authority. Freshness is always evaluable: "not connected"
        // is an answer, not a failure.
        availability.record(.providerAuthority, .available)
        if let authority = AttentionFactAdapters.authority(from: input.freshness) {
            proposals.append(authority)
        }

        // Forecast. A run that did not happen is unavailable; a run whose
        // first risk does not hold together is incoherent. Neither is quiet.
        var quiet = AttentionQuiet.unquantified
        if let forecast = input.forecast {
            switch AttentionFactAdapters.fundingGap(
                from: forecast,
                accountNames: input.accountNames,
                triggerLabels: AttentionFactAdapters.triggerLabels(in: input.document)
            ) {
            case let .success(proposal):
                // A horizon is quoted only from the run that established it,
                // and only when its length is an exact number of days. A
                // horizon whose span cannot be expressed is left unquantified
                // rather than stated as some other number.
                if let horizonDays = forecast.startDate.days(until: forecast.endDate) {
                    availability.record(.forecastProjection, .available)
                    quiet = AttentionQuiet(
                        horizonDays: horizonDays,
                        horizonEnd: DomainMapper.civilDay(forecast.endDate)
                    )
                    if let proposal { proposals.append(proposal) }
                } else {
                    availability.record(
                        .forecastProjection, .unavailable(.engineDidNotProduceResult)
                    )
                }
            case let .failure(reason):
                availability.record(.forecastProjection, .incoherent(reason))
            }
        } else {
            availability.record(.forecastProjection, .unavailable(.engineDidNotProduceResult))
        }

        // Evidence queue.
        if let observations = input.observations {
            availability.record(.evidenceReviewQueue, .available)
            proposals.append(contentsOf: AttentionFactAdapters.bookedEvidence(from: observations))
        } else {
            availability.record(.evidenceReviewQueue, .unavailable(.engineDidNotProduceResult))
        }

        // Expected occurrences.
        if let occurrences = input.occurrences {
            availability.record(.expectedOccurrenceLedger, .available)
            proposals.append(
                contentsOf: AttentionFactAdapters.overdueOccurrences(from: occurrences)
            )
        } else {
            availability.record(.expectedOccurrenceLedger, .unavailable(.engineDidNotProduceResult))
        }

        // Period review — a *checkpoint* source. Its absence must not reach
        // the current-attention domain, and it does not: `.periodReview` is
        // not one of that domain's required keys.
        availability.record(
            .periodReview,
            input.review == nil ? .unavailable(.engineDidNotProduceResult) : .available
        )

        // Checkpoint baseline. The readiness carries the comparison the
        // caller's history read produced; this key reports whether that read
        // established baseline state at all, which is a different question
        // from whether the answer was conclusive.
        let readiness = self.readiness(for: input)
        availability.record(
            .periodCheckpointBaseline, baselineStatus(of: readiness.baselineComparison)
        )

        if let close = AttentionFactAdapters.monthReadyToClose(
            from: readiness, periodLabel: input.periodLabel
        ) {
            proposals.append(close)
        }

        return Output(
            attention: AttentionCoordinator.evaluate(
                proposals: proposals, availability: availability, quiet: quiet
            ),
            readiness: readiness,
            driftFacts: driftFacts,
            availability: availability
        )
    }

    /// What a baseline comparison says about the source it came from.
    ///
    /// `isEstablished` is the right predicate and the only one: a period that
    /// has never been closed, one whose comparison is indeterminate and one
    /// whose stored format needs re-verification have all learned what the
    /// checkpoint history says. Only a read that failed has not — and a read
    /// that found unreadable history is a contradiction rather than a gap,
    /// which is what `.incoherent` means here.
    private static func baselineStatus(
        of comparison: PeriodCheckpointBaselineComparison
    ) -> AttentionSourceStatus {
        switch comparison {
        case .unavailable(.noBaselinePersistence):
            // No history was read for this period. Absence of a reading, never
            // a reading of absence.
            .unavailable(.notEvaluated)
        case .unavailable(.baselineProjectionUnreadable):
            .incoherent(.resultInternallyInconsistent)
        case .notPreviouslyClosed, .unchangedSinceClose, .changedSinceClose,
             .indeterminate, .requiresReverification:
            .available
        }
    }

    /// The period's readiness, built from the same authoritative facts.
    ///
    /// Two evaluator passes over **one** request, and deliberately so. The
    /// current side of a baseline comparison must come from an evaluated
    /// `PeriodCheckpointReadiness` — blockers win there, and reaching past it
    /// to the raw projection would let insufficient current coverage read as a
    /// change — but the comparison it produces is itself part of the readiness.
    /// So the request is assembled once, evaluated to establish the current
    /// state, compared, and evaluated again carrying the answer.
    ///
    /// Nothing financial runs twice: the review, the occurrences and the
    /// semantic projection are inputs on the request by then, and the evaluator
    /// is a pure sort-and-classify over values it is handed. The baseline
    /// itself is read once, by the caller, before either pass.
    static func readiness(for input: Input) -> PeriodCheckpointReadiness {
        var exceptions: [PeriodCheckpointException] = []
        if let observations = input.observations {
            exceptions += AttentionFactAdapters.evidenceExceptions(
                from: observations, period: input.period
            )
        }
        if let occurrences = input.occurrences {
            exceptions += AttentionFactAdapters.occurrenceExceptions(
                from: occurrences, period: input.period
            )
        }
        if let review = input.review,
           let uncategorized = AttentionFactAdapters.uncategorizedException(from: review) {
            exceptions.append(uncategorized)
        }

        var request = PeriodCheckpointRequest(
            period: input.period,
            kind: input.periodKind,
            asOf: input.asOf,
            review: input.review,
            exceptions: exceptions,
            // Carried through untouched. The composition neither confirms a
            // decision nor widens one: the evaluator rechecks these exact
            // subjects against the exceptions assembled just above, and a
            // subject that is absent or has changed underneath its identifier
            // blocks the whole application rather than acknowledging part of it.
            confirmedAcknowledgments: input.confirmedAcknowledgments,
            projection: input.review.map { review in
                SemanticPeriodProjectionBuilder.projection(
                    for: input.period,
                    kind: input.periodKind,
                    in: input.document,
                    coverage: review.coverage,
                    budget: SemanticBudgetFact(review.budget),
                    categoryKeys: input.categoryKeys,
                    // The same observation list the exceptions above were
                    // built from, so a projected aggregate relationship and
                    // the exception that reports it stay one fact.
                    aggregateFacts: input.observations.map(
                        AttentionFactAdapters.aggregateFacts(from:)
                    ) ?? [:],
                    expectations: input.occurrences ?? []
                )
            }
        )

        // Pass one establishes the current state — its blockers and its
        // projection — which is the only side of the comparison the baseline
        // may be measured against.
        request.baselineComparison = PeriodCheckpointBaselineReader.comparison(
            baseline: input.checkpointBaseline,
            current: PeriodCheckpointEvaluator.evaluate(request)
        )
        return PeriodCheckpointEvaluator.evaluate(request)
    }
}
