import FinanceCore
import Foundation

/// Turns authoritative engine results into attention proposals.
///
/// ## Ownership
///
/// These adapters **read**. They never recalculate balances, `CurrentHoldings`,
/// spending, income or support, budget, forecast, `FirstRisk`, expected
/// occurrences, or evidence economics. Every amount and every date they carry
/// is copied from the engine result that owns it, and an amount is never
/// paired with a date from a different computation.
///
/// They are the only place in the attention layer that imports `FinanceCore`.
/// `AttentionModel` and `AttentionCoordinator` stay free of it so Phase 2.9B
/// can consume the result from SwiftUI.
enum AttentionFactAdapters {

    // MARK: - Required funding gap

    /// One funding proposal from one already-successful forecast.
    ///
    /// The forecast is not re-run and its arithmetic is not repeated. The
    /// amount is `FirstRisk.shortfall` and the date is `FirstRisk.day`, taken
    /// together from the same object — which is why `FirstRisk` carries them
    /// together in the first place. `minimumBridgeRequired` is never consulted
    /// here: it is a horizon-wide up-front bridge, and welding it to a
    /// first-risk day would state an amount and a date from two different
    /// computations.
    ///
    /// Returns nil when there is no risk. Returns an *incoherent* marker
    /// rather than a candidate when the risk does not hold together, so the
    /// caller can record `.incoherent` on `.forecastProjection` instead of
    /// quietly showing nothing.
    /// What a statement about the plan's funding rests on.
    ///
    /// Declared once, because two callers need it and a copy would drift: the
    /// proposal below carries it, and anything that wants to say the plan is
    /// *funded* has to find every one of these available. A gap suppressed
    /// because one of them is compromised leaves no candidate behind, and
    /// reading that absence as safety is the failure this constant exists to
    /// prevent.
    static let fundingGapDependencies: Set<AttentionDependencyKey> = [
        .forecastProjection, .currentAccountTruth
    ]

    static func fundingGap(
        from forecast: ForecastResult,
        accountNames: [String: String],
        triggerLabels: [String: String]
    ) -> Result<AttentionCandidateProposal?, AttentionSourceFailure> {

        guard let risk = forecast.firstRisk else { return .success(nil) }

        // Coherence, checked against the run that produced it. A shortfall
        // that is not positive is not a gap; a day outside the horizon the
        // engine actually evaluated cannot be quoted from it.
        guard risk.shortfall.minorUnits > 0 else {
            return .failure(.amountOutsideExpectedRange)
        }
        guard risk.day >= forecast.startDate, risk.day <= forecast.endDate else {
            return .failure(.dayOutsideEvaluatedHorizon)
        }
        guard risk.shortfall.currency == forecast.projectedEndBalance.currency else {
            return .failure(.currencyMismatch)
        }

        let failure = forecast.settlementFailures.first {
            $0.eventID == risk.triggerEventID && $0.day == risk.day
        }
        if risk.kind == .poolDeficit, let failure,
           failure.unsettled != risk.shortfall {
            return .failure(.resultInternallyInconsistent)
        }
        let settlement = failure.map {
            SettlementFailureFact(
                day: DomainMapper.civilDay($0.day),
                requested: DomainMapper.amount($0.requested),
                settled: DomainMapper.amount($0.settled),
                unsettled: DomainMapper.amount($0.unsettled),
                eligibleAccountIDs: $0.eligibleAccountIDs.sorted()
            )
        }

        // Subject specificity is never manufactured. One proved eligible
        // account names that account; anything else keeps the less specific
        // pool, and neither form names a source to move money *from*.
        let subject: AttentionSubject
        if let eligible = failure?.eligibleAccountIDs, eligible.count == 1,
           let accountID = eligible.first {
            subject = .account(id: accountID, name: accountNames[accountID] ?? accountID)
        } else {
            subject = .paymentPool(
                eligibleAccountIDs: (failure?.eligibleAccountIDs ?? []).sorted(),
                currencyCode: risk.shortfall.currency.code
            )
        }

        // `triggerLabel` is `sourceRef ?? eventID` — a plan-item *identity*,
        // not a name. It is resolved through the document's own plan items, the
        // same bridge Home and Insights already use, and dropped when it
        // resolves to nothing: an internal identifier must never reach a
        // person, and "ob-rent" is not a landlord.
        let label = triggerLabels[risk.triggerLabel]

        let fact = RequiredFundingGapFact(
            riskKind: risk.kind == .poolDeficit ? .poolDeficit : .belowSafetyFloor,
            day: DomainMapper.civilDay(risk.day),
            shortfall: DomainMapper.amount(risk.shortfall),
            triggerLabel: label,
            triggerEventID: risk.triggerEventID,
            subject: subject,
            settlementFailure: settlement
        )

        return .success(
            AttentionCandidateProposal(
                kind: .requiredFundingGap,
                identity: "\(risk.kind.rawValue)@\(risk.day.isoString)",
                subject: subject,
                detail: .fundingGap(fact),
                dependencies: fundingGapDependencies,
                orderingDay: fact.day,
                orderingMinorUnits: fact.shortfall.minorUnits
            )
        )
    }

    /// Plan-item identities to the names a person would recognise.
    ///
    /// The same bridge Home and Insights already use: a `sourceRef` is
    /// resolved through the document's own recurring obligations, income
    /// streams, financing plans and debts. A reference that resolves to
    /// nothing is deliberately absent from the map, so the caller shows no
    /// label rather than an internal identifier.
    static func triggerLabels(in document: FinanceDocument) -> [String: String] {
        var labels: [String: String] = [:]
        for obligation in document.planning.recurringObligations {
            labels[obligation.id] = obligation.name
        }
        for source in document.incomeSources {
            labels[source.id] = source.name
        }
        for plan in document.installments {
            labels[plan.id] = DisplayDescriptor.instalmentTitle(
                purchaseDescription: plan.purchaseDescription,
                provider: plan.provider
            )
        }
        for debt in document.debts {
            labels[debt.id] = debt.name
        }
        return labels
    }

    // MARK: - Provider authority

    /// Authority proposals from the app's one bank-freshness summary.
    ///
    /// Refinement B and G: only a state the app **already** defines as needing
    /// a person becomes a task. `BankFreshness.needsAttention` is that state —
    /// it is produced by `ProviderConnectionState.needsAttention`
    /// (reauthorization required, revoked), an expiring connection, a reported
    /// connection error, revoked pairing, or a failed sync. Ordinary freshness
    /// is not: a stale or never-synced connection is chrome with a caption,
    /// and a snapshot being older than another is not a task at all.
    ///
    /// `.stale` and `.neverSynced` still produce a proposal, marked
    /// non-actionable, so the decision to keep them quiet is an inspectable
    /// diagnostic rather than a silent omission.
    static func authority(from freshness: BankFreshness) -> AttentionCandidateProposal? {
        switch freshness {
        case .notConnected, .updated:
            // Nothing to say. Entering transactions by hand is a way to use
            // this app, and a healthy connection is meant to be silent.
            return nil

        case .neverSynced, .stale:
            return AttentionCandidateProposal(
                kind: .authorityNeedsAttention,
                identity: "freshness:\(freshness.diagnosticToken)",
                subject: .providerConnection(providerName: ""),
                detail: .authority(state: freshness.diagnosticToken),
                dependencies: [.providerAuthority],
                isActionable: false
            )

        case .needsAttention:
            return AttentionCandidateProposal(
                kind: .authorityNeedsAttention,
                identity: "freshness:needsAttention",
                subject: .providerConnection(providerName: ""),
                detail: .authority(state: freshness.diagnosticToken),
                dependencies: [.providerAuthority]
            )
        }
    }

    // MARK: - Current account drift

    /// Comparable provider/ledger differences, as typed facts.
    ///
    /// A fact is produced for every account where `CurrentHoldings` could
    /// compare the two sides and they differ. No threshold is applied and none
    /// exists: a difference is a difference. Whether it is also a *task* is a
    /// separate decision — see `driftProposal`.
    static func driftFacts(
        in document: FinanceDocument,
        asOf: Day,
        accountNames: [String: String]
    ) -> [CurrentAccountDriftFact] {
        document.balances
            .map { stored -> CurrentAccountDriftFact? in
                let value = CurrentHoldings.effective(
                    accountID: stored.accountID, asOf: asOf, in: document
                )
                guard let drift = value.driftFromLedger else { return nil }
                guard drift.minorUnits != 0 else { return nil }
                return CurrentAccountDriftFact(
                    accountID: stored.accountID,
                    accountName: accountNames[stored.accountID] ?? stored.accountID,
                    drift: DomainMapper.amount(drift),
                    isComparable: true
                )
            }
            .compactMap { $0 }
            .sorted { $0.accountID < $1.accountID }
    }

    /// What, if anything, licenses promoting a drift fact into a task.
    ///
    /// ## Refinement B policy, and why it is this narrow
    ///
    /// The architecture already answers "which figure is authoritative":
    /// `CurrentHoldings` *chooses* the canonical provider snapshot when one is
    /// usable, and everything downstream — Home cash, Accounts, Safe to Use,
    /// and the forecast's starting liquidity — reads that same overlay. Drift
    /// is documented there as diagnostic state, "never a reason to mutate the
    /// anchor". So on a healthy connection the funding answer was computed
    /// from the side the architecture already trusts, and the difference does
    /// not compromise it.
    ///
    /// There is therefore **no established criterion in the current
    /// architecture for promoting standalone drift**, and inventing one would
    /// mean inventing financial materiality math. Phase 2.9A keeps standalone
    /// drift out of primary attention and leaves the question to 2.9B.
    ///
    /// What *is* established is composition with an existing intervention
    /// state. Both bases below are read from typed facts that already exist;
    /// neither introduces a threshold:
    ///
    /// - `providerAuthorityRequiresIntervention` — the connection that
    ///   produced the provider figure is in the app's own needs-a-person
    ///   state, so the figure beneath the forecast is not trustworthy while
    ///   the two sides also disagree.
    /// - `currentAmountUnestablished` — no usable current amount could be
    ///   derived for an account the spendable pool depends on.
    enum DriftPromotionBasis: String, Hashable, Sendable {
        case none
        case providerAuthorityRequiresIntervention
        case currentAmountUnestablished
    }

    /// The established basis for promoting drift, or `.none`.
    ///
    /// Composed from facts the app already owns. It computes no materiality
    /// and compares no amount against any bound.
    static func driftPromotionBasis(
        facts: [CurrentAccountDriftFact],
        freshness: BankFreshness,
        accountsWithoutUsableAmount: Set<String>
    ) -> DriftPromotionBasis {
        if !accountsWithoutUsableAmount.isEmpty { return .currentAmountUnestablished }
        guard !facts.isEmpty else { return .none }
        if freshness == .needsAttention { return .providerAuthorityRequiresIntervention }
        return .none
    }

    /// One integrity proposal covering the drifting accounts.
    ///
    /// With `.none`, the proposal is still produced and marked non-actionable:
    /// the reconciliation fact stays representable and inspectable, and the
    /// coordinator's suppression records that keeping it quiet was a decision.
    /// With an established basis it declares `.currentAccountTruth`
    /// compromised, which is what gates a funding candidate down to secondary.
    static func driftProposal(
        facts: [CurrentAccountDriftFact],
        basis: DriftPromotionBasis
    ) -> AttentionCandidateProposal? {
        guard let leading = facts.max(by: {
            abs($0.drift.minorUnits) != abs($1.drift.minorUnits)
                ? abs($0.drift.minorUnits) < abs($1.drift.minorUnits)
                : $0.accountID > $1.accountID
        }) else { return nil }

        let promoted = basis != .none
        return AttentionCandidateProposal(
            kind: .currentAccountDrift,
            identity: "drift:\(facts.map(\.accountID).sorted().joined(separator: ","))",
            subject: .account(id: leading.accountID, name: leading.accountName),
            detail: .drift(leading),
            dependencies: [.currentAccountTruth],
            compromisedDependencies: promoted ? [.currentAccountTruth] : [],
            isActionable: promoted,
            orderingMinorUnits: leading.drift.minorUnits
        )
    }

    // MARK: - Unresolved booked evidence

    /// Proposals for booked provider observations awaiting an economic
    /// decision.
    ///
    /// Pending and provisional evidence is filtered out entirely — it creates
    /// no action and no exception anywhere in this phase. A recognized
    /// aggregate model limitation is kept but marked non-actionable: the
    /// schema cannot record one observation against two transactions, so there
    /// is no decision to offer, and it is carried as a checkpoint exception
    /// instead. Every other duplicate conflict, including a settled-recurring
    /// candidate, still needs a person and stays actionable.
    static func bookedEvidence(
        from observations: [SyncedObservationItem]
    ) -> [AttentionCandidateProposal] {
        observations
            .filter { $0.status == .booked }
            .filter { $0.resolution == .unreviewed }
            .filter(\.isAccountBindingActive)
            .map { item in
                let isAggregateLimitation = item.duplicateConflict?.kind == .aggregateExisting
                return AttentionCandidateProposal(
                    kind: .unresolvedBookedEvidence,
                    identity: item.id,
                    subject: .observation(id: item.id),
                    detail: .bookedEvidence(
                        amount: item.amount,
                        day: item.dates.economicPeriod
                    ),
                    dependencies: [.evidenceReviewQueue],
                    isActionable: !isAggregateLimitation,
                    orderingDay: item.dates.economicPeriod,
                    orderingMinorUnits: item.amount.minorUnits
                )
            }
            .sorted { $0.identity < $1.identity }
    }

    // MARK: - Overdue expected occurrences

    /// Proposals for occurrences the authoritative engine marks overdue.
    ///
    /// `OccurrenceStatus` is the engine's answer and is used verbatim: an
    /// occurrence is overdue because the expander said so, never because this
    /// layer compared a date. Due today is still `.due`, not overdue. Resolved
    /// statuses and future occurrences produce nothing at all.
    static func overdueOccurrences(
        from occurrences: [ExpectedOccurrence]
    ) -> [AttentionCandidateProposal] {
        occurrences
            .filter { $0.status == .overdue }
            .map { occurrence in
                AttentionCandidateProposal(
                    kind: .overdueExpectedOccurrence,
                    identity: occurrence.id.description,
                    subject: .expectedOccurrence(
                        obligationID: occurrence.obligationID, name: occurrence.name
                    ),
                    detail: .overdueOccurrence(
                        amount: DomainMapper.amount(occurrence.amount),
                        expectedDay: DomainMapper.civilDay(occurrence.expectedDay)
                    ),
                    dependencies: [.expectedOccurrenceLedger],
                    conditionResolved: false,
                    orderingDay: DomainMapper.civilDay(occurrence.expectedDay),
                    orderingMinorUnits: occurrence.amount.minorUnits
                )
            }
            .sorted { $0.identity < $1.identity }
    }

    // MARK: - Month ready to close

    /// A close proposal from a period's readiness.
    ///
    /// Readiness and the close *action* are different questions. A period can
    /// be perfectly ready while nothing establishes whether it has already
    /// been closed, and proposing a close in that state would fabricate "not
    /// previously closed". The proposal therefore declares
    /// `.periodCheckpointBaseline` as a dependency.
    ///
    /// Since Phase 2.9C-D that key is answered from stored history rather than
    /// pinned unavailable, so a real baseline can make it available. No close
    /// proposal reaches a person from that: the production composition that
    /// runs this adapter carries no period review, so its readiness is blocked
    /// and this returns nil before eligibility is ever considered — and there
    /// is still no close action to perform. Because the key is not one the
    /// current-attention domain requires, today's answer stays determinate
    /// either way. That is refinement A.
    ///
    /// A Home entry into the canonical Insights verification flow, not a
    /// close action. Only a conclusive "never closed" or "moved since close"
    /// reading proposes; an unchanged month stays quiet, and an unavailable
    /// or indeterminate comparison never offers a fake CTA. Blockers that
    /// mean the period cannot be opened as ended-month verification suppress
    /// the proposal. Needing decisions does not: that is why the person
    /// should open the month.
    static func monthReadyToClose(
        from readiness: PeriodCheckpointReadiness,
        asOf: Day,
        periodLabel: String
    ) -> AttentionCandidateProposal? {
        if readiness.blockers.contains(where: { Self.unverifiableBlockers.contains($0.kind) }) {
            return nil
        }
        let changed: Bool
        switch readiness.baselineComparison {
        case .unchangedSinceClose:
            return nil
        case .notPreviouslyClosed:
            changed = false
        case .changedSinceClose:
            changed = true
        case .unavailable, .indeterminate, .requiresReverification:
            return nil
        }
        return AttentionCandidateProposal(
            kind: .monthReadyToClose,
            identity: "close:\(readiness.period.start.isoString)",
            subject: .period(label: periodLabel),
            detail: .periodClose(
                changed: changed,
                monthOffset: monthOffset(asOf: asOf, period: readiness.period)
            ),
            dependencies: [.periodReview, .periodCheckpointBaseline],
            orderingDay: DomainMapper.civilDay(readiness.period.end)
        )
    }

    private static let unverifiableBlockers: Set<PeriodCheckpointBlockerKind> = [
        .invalidPeriod, .periodNotEnded, .reviewUnavailable, .reviewPeriodMismatch,
    ]

    private static func monthOffset(asOf: Day, period: SemanticInterval) -> Int {
        let from = asOf.monthKey
        let to = period.start.monthKey
        return (to.year * 12 + to.month) - (from.year * 12 + from.month)
    }

    // MARK: - Checkpoint exceptions

    /// Typed checkpoint exceptions from the app's evidence facts.
    ///
    /// Classification is read, never invented. In particular the aggregate
    /// basis is `.structuralCandidateOnly` because that is what the app's
    /// duplicate detection actually establishes — an exact signed-cent pairing
    /// within the existing five-day window on the bound account. An arithmetic
    /// sum is a structural candidate, not proof that the observation is the
    /// same money, so refinement C's conservative branch applies and the
    /// period's totals stay questionable. Nothing in the current typed data
    /// produces `.sourceEstablishedAggregateRelationship`; the case exists so
    /// a future source-backed fact has somewhere truthful to land.
    ///
    /// Pending and provisional evidence contributes no exception, exactly as
    /// it contributes no action.
    static func evidenceExceptions(
        from observations: [SyncedObservationItem],
        period: ReviewInterval
    ) -> [PeriodCheckpointException] {
        observations.compactMap { item -> PeriodCheckpointException? in
            guard item.isAccountBindingActive else { return nil }
            // The domain's `economicPeriodDay`, carried through the surface.
            // The projection scopes observations by the same value, so the two
            // populations cannot disagree about which period a row is in.
            guard let civil = item.dates.economicPeriod else { return nil }
            guard let day = DomainMapper.day(civil), period.contains(day) else { return nil }

            let amount = DomainMapper.money(item.amount)

            if item.hasProviderStatusWarning {
                return PeriodCheckpointException(
                    id: item.id,
                    kind: .providerStatusConflict,
                    day: day,
                    amount: amount
                )
            }
            guard item.status == .booked else { return nil }
            guard item.resolution == .unreviewed else { return nil }
            if item.duplicateConflict?.kind == .aggregateExisting {
                return PeriodCheckpointException(
                    id: item.id,
                    kind: .aggregateEvidenceModelLimitation,
                    aggregateBasis: .structuralCandidateOnly,
                    day: day,
                    amount: amount
                )
            }
            return PeriodCheckpointException(
                id: item.id,
                kind: .unknownBookedEconomics,
                day: day,
                amount: amount
            )
        }
        .sorted { $0.id < $1.id }
    }

    /// The aggregate relationships the same observations carry, for the
    /// semantic projection.
    ///
    /// Read from `duplicateConflict` — the identical field, on the identical
    /// list, that `evidenceExceptions` reads to raise the limitation — so the
    /// exception and the projected relationship can never describe different
    /// pairings. The basis is `.structuralCandidateOnly` for the same reason
    /// it is there: an exact signed-cent pairing inside the existing five-day
    /// window is a structural candidate, not proof of identity.
    ///
    /// This carries the pairing precisely because that window reaches outside
    /// the observation's own period. Without it, reversing one of the paired
    /// transactions in the next month would dissolve the limitation while this
    /// month projected unchanged.
    static func aggregateFacts(
        from observations: [SyncedObservationItem]
    ) -> [String: SemanticAggregateFact] {
        var result: [String: SemanticAggregateFact] = [:]
        for item in observations {
            guard let conflict = item.duplicateConflict,
                  conflict.kind == .aggregateExisting else { continue }
            result[item.id] = SemanticAggregateFact(
                basis: .structuralCandidateOnly,
                pairedTransactionIDs: conflict.transactionIDs
            )
        }
        return result
    }

    /// Exceptions for occurrences the engine reports overdue inside the period.
    static func occurrenceExceptions(
        from occurrences: [ExpectedOccurrence],
        period: ReviewInterval
    ) -> [PeriodCheckpointException] {
        occurrences
            .filter { period.contains($0.expectedDay) && $0.status == .overdue }
            .map {
                PeriodCheckpointException(
                    id: $0.id.description,
                    kind: .overdueExpectedOccurrence,
                    day: $0.expectedDay,
                    amount: $0.amount
                )
            }
            .sorted { $0.id < $1.id }
    }

    /// The category-only exception, from the review engine's own uncategorized
    /// bucket. The figure is the engine's; nothing is re-tallied here.
    static func uncategorizedException(
        from review: ReviewResult
    ) -> PeriodCheckpointException? {
        guard review.budget.uncategorized.minorUnits != 0 else { return nil }
        return PeriodCheckpointException(
            id: "uncategorized:\(review.interval.start.isoString)",
            kind: .uncategorizedEconomicSpending,
            day: review.interval.end,
            amount: review.budget.uncategorized
        )
    }
}

// MARK: - Diagnostics

extension BankFreshness {
    /// A stable token for diagnostics and identity. Never shown to a person —
    /// `caption(relativeTo:)` remains the only user-facing wording — and never
    /// carrying a timestamp, so a suppressed diagnostic does not change every
    /// time the clock moves.
    var diagnosticToken: String {
        switch self {
        case .notConnected: "notConnected"
        case .neverSynced: "neverSynced"
        case .updated: "updated"
        case .stale: "stale"
        case .needsAttention: "needsAttention"
        }
    }
}
