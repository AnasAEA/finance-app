import Testing
import FinanceCore
import Foundation
@testable import FinanceApp

/// Phase 2.9A — the Financial Attention Loop's NOW semantics.
///
/// Every fixture is synthetic. The two "real-shape" fixtures reproduce the
/// *structure* of cases that occurred on the physical canary — an aggregate
/// observation, a funding gap — with invented identifiers and sanitized
/// figures. No private identifier, counterparty or account number appears
/// here, and none is hardcoded into production logic.
struct AttentionSemanticsTests {

    // MARK: - Fixtures

    private func day(_ iso: String) -> Day { Day(isoString: iso)! }
    private func euro(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .eur)! }
    private func civil(_ iso: String) -> CalendarDay { DomainMapper.civilDay(day(iso)) }

    private var bank: Account {
        Account(
            id: "acct-bank", name: "Bank", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 0
        )
    }
    private var wallet: Account {
        Account(
            id: "acct-wallet", name: "Wallet", currency: .eur, kind: .wallet,
            supportedRails: PaymentRail.euroWalletRails, drawOrder: 1
        )
    }

    private func proposal(
        _ kind: AttentionCandidateKind,
        identity: String = "x",
        dependencies: Set<AttentionDependencyKey> = [],
        compromises: Set<AttentionDependencyKey> = [],
        actionable: Bool = true,
        resolved: Bool = false,
        representedBy: AttentionCandidateKind? = nil,
        orderingDay: CalendarDay? = nil,
        orderingMinorUnits: Int64 = 0
    ) -> AttentionCandidateProposal {
        AttentionCandidateProposal(
            kind: kind,
            identity: identity,
            subject: .period(label: "test"),
            detail: .periodClose(changed: false, monthOffset: -1),
            dependencies: dependencies,
            compromisedDependencies: compromises,
            isActionable: actionable,
            conditionResolved: resolved,
            representedBy: representedBy,
            orderingDay: orderingDay,
            orderingMinorUnits: orderingMinorUnits
        )
    }

    /// Every current-attention source succeeded, and no checkpoint history was
    /// read — which is what a caller that does not consult persistence
    /// establishes: nothing.
    private var currentSourcesAvailable: AttentionSourceAvailability {
        AttentionSourceAvailability([
            .currentAccountTruth: .available,
            .providerAuthority: .available,
            .forecastProjection: .available,
            .evidenceReviewQueue: .available,
            .expectedOccurrenceLedger: .available,
            .periodReview: .available,
            .periodCheckpointBaseline: .unavailable(.notEvaluated),
        ])
    }

    private func observation(
        id: String,
        amount: Amount,
        status: SyncedObservationStatus = .booked,
        resolution: SyncedObservationResolution = .unreviewed,
        on iso: String = "2026-08-07",
        conflict: ObservationDuplicateConflict? = nil,
        providerStatusWarning: Bool = false,
        bindingActive: Bool = true
    ) -> SyncedObservationItem {
        SyncedObservationItem(
            id: id,
            providerName: "Synthetic Bank",
            providerAccountName: "Current account",
            isAccountBindingActive: bindingActive,
            amount: amount,
            status: status,
            resolution: resolution,
            displayMerchant: "Bank activity",
            observedMerchant: nil,
            rawMerchantText: nil,
            remittance: nil,
            merchantEmail: nil,
            bankTransactionCode: nil,
            dates: ObservationDates(
                booking: civil(iso), transaction: civil(iso), value: nil,
                derivedTransaction: nil, derivedProvenanceLabel: nil,
                economicPeriod: civil(iso)
            ),
            observedAt: Date(timeIntervalSince1970: 1_777_680_000),
            suggestions: [],
            duplicateConflict: conflict,
            hasProviderStatusWarning: providerStatusWarning
        )
    }

    // MARK: - Priority

    @Test("Nominal precedence orders eligible candidates")
    func nominalPrecedence() throws {
        let state = AttentionCoordinator.evaluate(
            proposals: [
                proposal(.monthReadyToClose, identity: "close"),
                proposal(.requiredFundingGap, identity: "gap"),
                proposal(.unresolvedBookedEvidence, identity: "obs"),
            ],
            availability: currentSourcesAvailable
        )
        #expect(state.primary?.kind == .requiredFundingGap)
        #expect(state.secondary.map(\.kind) == [.unresolvedBookedEvidence, .monthReadyToClose])
        #expect(state.outcome == .actionsAvailable)
    }

    @Test("Validity gating overrides nominal precedence")
    func validityBeatsPrecedence() throws {
        // The funding candidate holds the highest slot and is still not
        // primary, because its source did not produce a result.
        let state = AttentionCoordinator.evaluate(
            proposals: [
                proposal(.requiredFundingGap, identity: "gap", dependencies: [.forecastProjection]),
                proposal(.unresolvedBookedEvidence, identity: "obs"),
            ],
            availability: currentSourcesAvailable.recording(
                .forecastProjection, .unavailable(.engineDidNotProduceResult)
            )
        )
        #expect(state.primary?.kind == .unresolvedBookedEvidence)
        #expect(
            state.suppressed.first?.eligibility
                == .suppressedBecauseSourceUnavailable(.forecastProjection)
        )
    }

    @Test("Secondary holds at most three")
    func secondaryCap() throws {
        let state = AttentionCoordinator.evaluate(
            proposals: AttentionCandidateKind.allCases.map { proposal($0, identity: $0.rawValue) },
            availability: currentSourcesAvailable
        )
        #expect(state.primary != nil)
        #expect(state.secondary.count == 3)
    }

    @Test("Within-kind ties break by day, then amount, then identity")
    func withinKindTieBreakers() throws {
        let state = AttentionCoordinator.evaluate(
            proposals: [
                proposal(.unresolvedBookedEvidence, identity: "c",
                         orderingDay: civil("2026-08-10"), orderingMinorUnits: 100),
                proposal(.unresolvedBookedEvidence, identity: "a",
                         orderingDay: civil("2026-08-05"), orderingMinorUnits: 100),
                proposal(.unresolvedBookedEvidence, identity: "b",
                         orderingDay: civil("2026-08-05"), orderingMinorUnits: 900),
            ],
            availability: currentSourcesAvailable
        )
        // Soonest day first; within the day, the larger amount; identity last.
        #expect(state.primary?.proposal.identity == "b")
        #expect(state.secondary.map(\.proposal.identity) == ["a", "c"])
    }

    @Test("A candidate with no day sorts after one that has a day")
    func missingDaySortsLast() throws {
        let state = AttentionCoordinator.evaluate(
            proposals: [
                proposal(.unresolvedBookedEvidence, identity: "undated"),
                proposal(.unresolvedBookedEvidence, identity: "dated", orderingDay: civil("2026-08-05")),
            ],
            availability: currentSourcesAvailable
        )
        #expect(state.primary?.proposal.identity == "dated")
    }

    // MARK: - Test L — determinism

    @Test("Same semantic input produces value-identical output whatever the order")
    func deterministicOrdering() throws {
        let proposals = [
            proposal(.unresolvedBookedEvidence, identity: "b", orderingDay: civil("2026-08-05")),
            proposal(.requiredFundingGap, identity: "gap", orderingDay: civil("2026-09-11")),
            proposal(.overdueExpectedOccurrence, identity: "occ", orderingDay: civil("2026-08-02")),
            proposal(.unresolvedBookedEvidence, identity: "a", orderingDay: civil("2026-08-05")),
        ]
        let forward = AttentionCoordinator.evaluate(
            proposals: proposals, availability: currentSourcesAvailable
        )
        let reversed = AttentionCoordinator.evaluate(
            proposals: proposals.reversed(), availability: currentSourcesAvailable
        )
        #expect(forward == reversed)
        #expect(forward.primary?.id == reversed.primary?.id)
        #expect(forward.secondary.map(\.id) == reversed.secondary.map(\.id))
        #expect(forward.suppressed.map(\.id) == reversed.suppressed.map(\.id))
    }

    // MARK: - Suppression vocabulary

    @Test("Each suppression reason is reachable and named")
    func suppressionReasons() throws {
        let state = AttentionCoordinator.evaluate(
            proposals: [
                proposal(.requiredFundingGap, identity: "unavailable",
                         dependencies: [.forecastProjection]),
                proposal(.overdueExpectedOccurrence, identity: "incoherent",
                         dependencies: [.expectedOccurrenceLedger]),
                proposal(.unresolvedBookedEvidence, identity: "resolved", resolved: true),
                proposal(.currentAccountDrift, identity: "quiet", actionable: false),
                proposal(.monthReadyToClose, identity: "represented",
                         representedBy: .requiredFundingGap),
            ],
            availability: currentSourcesAvailable
                .recording(.forecastProjection, .unavailable(.engineDidNotProduceResult))
                .recording(.expectedOccurrenceLedger, .incoherent(.resultInternallyInconsistent))
        )
        let reasons = Dictionary(
            uniqueKeysWithValues: state.suppressed.map { ($0.proposal.identity, $0.eligibility) }
        )
        #expect(reasons["unavailable"] == .suppressedBecauseSourceUnavailable(.forecastProjection))
        #expect(reasons["incoherent"] == .suppressedBecauseSourceIncoherent(.expectedOccurrenceLedger))
        #expect(reasons["resolved"] == .suppressedBecauseConditionResolved)
        #expect(reasons["quiet"] == .suppressedBecauseNotActionable)
        #expect(reasons["represented"] == .suppressedBecauseRepresentedBy(.requiredFundingGap))
        #expect(state.primary == nil)
    }

    // MARK: - Test F — drift gates funding

    @Test("Drift compromising a funding dependency gates funding to secondary")
    func driftGatesFunding() throws {
        let state = AttentionCoordinator.evaluate(
            proposals: [
                proposal(.requiredFundingGap, identity: "gap",
                         dependencies: [.forecastProjection, .currentAccountTruth]),
                proposal(.currentAccountDrift, identity: "drift",
                         dependencies: [.currentAccountTruth],
                         compromises: [.currentAccountTruth]),
            ],
            availability: currentSourcesAvailable
        )
        // The integrity candidate leads; the funding candidate is real but may
        // not be primary while the ground beneath it is disputed.
        #expect(state.primary?.kind == .currentAccountDrift)
        #expect(state.secondary.map(\.kind) == [.requiredFundingGap])
        #expect(
            state.secondary.first?.eligibility
                == .secondaryOnlyBecauseDependencyCompromised(.currentAccountTruth)
        )
    }

    @Test("A compromise nobody eligible reports suppresses what rests on it")
    func uncredibleCompromiseSuppresses() throws {
        let state = AttentionCoordinator.evaluate(
            proposals: [
                proposal(.requiredFundingGap, identity: "gap",
                         dependencies: [.forecastProjection, .currentAccountTruth]),
                // The reporter is itself non-actionable, so nothing is going to
                // tell the person why the ground moved.
                proposal(.currentAccountDrift, identity: "drift",
                         dependencies: [.currentAccountTruth],
                         compromises: [.currentAccountTruth],
                         actionable: false),
            ],
            availability: currentSourcesAvailable
        )
        #expect(state.primary == nil)
        #expect(state.outcome != .actionsAvailable)
        let funding = state.suppressed.first { $0.kind == .requiredFundingGap }
        #expect(funding?.eligibility == .suppressedBecauseSourceIncoherent(.currentAccountTruth))
    }

    @Test("An integrity candidate is not demoted by its own report")
    func reporterIsNotSelfGated() throws {
        let state = AttentionCoordinator.evaluate(
            proposals: [
                proposal(.currentAccountDrift, identity: "drift",
                         dependencies: [.currentAccountTruth],
                         compromises: [.currentAccountTruth]),
            ],
            availability: currentSourcesAvailable
        )
        #expect(state.primary?.eligibility == .eligible)
    }

    // MARK: - Refinement A: domain-scoped completeness

    @Test("A: an unavailable checkpoint baseline suppresses close but leaves funding determinate")
    func baselineUnavailableDoesNotPoisonCurrent() throws {
        let state = AttentionCoordinator.evaluate(
            proposals: [
                proposal(.requiredFundingGap, identity: "gap",
                         dependencies: [.forecastProjection, .currentAccountTruth]),
                proposal(.monthReadyToClose, identity: "close",
                         dependencies: [.periodReview, .periodCheckpointBaseline]),
            ],
            availability: currentSourcesAvailable
        )
        #expect(state.primary?.kind == .requiredFundingGap)
        #expect(state.primary?.eligibility == .eligible)
        #expect(
            state.suppressed.first { $0.kind == .monthReadyToClose }?.eligibility
                == .suppressedBecauseSourceUnavailable(.periodCheckpointBaseline)
        )
        #expect(state.outcome == .actionsAvailable)
    }

    @Test("B: no baseline and no candidates still permits no-action")
    func baselineUnavailableStillPermitsNoAction() throws {
        let state = AttentionCoordinator.evaluate(
            proposals: [],
            availability: currentSourcesAvailable,
            quiet: AttentionQuiet(horizonDays: 30, horizonEnd: civil("2026-10-03"))
        )
        #expect(state.outcome == .noActionNeeded(
            AttentionQuiet(horizonDays: 30, horizonEnd: civil("2026-10-03"))
        ))
    }

    @Test("C: an unrelated optional source failure does not poison the state")
    func unrelatedFailureDoesNotPoison() throws {
        // The period review failed. It is a checkpoint source, not a
        // current-attention one, so today's answer is still an answer.
        let state = AttentionCoordinator.evaluate(
            proposals: [],
            availability: currentSourcesAvailable
                .recording(.periodReview, .unavailable(.engineDidNotProduceResult))
        )
        guard case .noActionNeeded = state.outcome else {
            Issue.record("expected noActionNeeded, got \(state.outcome)")
            return
        }
    }

    @Test("D: a direct current-attention source failure is indeterminate, never no-action")
    func directFailureIsIndeterminate() throws {
        for key in AttentionSourceDomain.currentAttention.requiredKeys {
            let state = AttentionCoordinator.evaluate(
                proposals: [],
                availability: currentSourcesAvailable
                    .recording(key, .unavailable(.engineDidNotProduceResult))
            )
            #expect(state.outcome == .indeterminate(failedKeys: [key]), "\(key)")
            if case .noActionNeeded = state.outcome {
                Issue.record("\(key) failure must never read as no-action")
            }
        }
    }

    @Test("Indeterminate names every failed key, sorted")
    func indeterminateNamesKeys() throws {
        let state = AttentionCoordinator.evaluate(
            proposals: [],
            availability: currentSourcesAvailable
                .recording(.forecastProjection, .unavailable(.engineDidNotProduceResult))
                .recording(.currentAccountTruth, .incoherent(.resultInternallyInconsistent))
        )
        #expect(state.outcome == .indeterminate(
            failedKeys: [.currentAccountTruth, .forecastProjection]
        ))
    }

    @Test("The checkpoint baseline is not a current-attention source")
    func baselineIsNotACurrentSource() throws {
        #expect(
            !AttentionSourceDomain.currentAttention.requiredKeys.contains(.periodCheckpointBaseline)
        )
        #expect(!AttentionSourceDomain.currentAttention.requiredKeys.contains(.periodReview))
        #expect(AttentionSourceDomain.checkpointBaseline.requiredKeys == [.periodCheckpointBaseline])
        #expect(AttentionSourceDomain.periodCheckpoint.requiredKeys == [.periodReview])
    }

    @Test("An unrecorded source is never treated as successful")
    func unrecordedSourceIsNotSuccess() throws {
        let empty = AttentionSourceAvailability()
        #expect(empty.status(.forecastProjection) == .unavailable(.notEvaluated))
        #expect(!empty.isFullyEvaluated(for: .currentAttention))
    }

    // MARK: - No-action semantics

    @Test("A horizon is quoted only from a successful forecast")
    func horizonOnlyFromForecast() throws {
        let state = AttentionCoordinator.evaluate(
            proposals: [], availability: currentSourcesAvailable, quiet: .unquantified
        )
        #expect(state.outcome == .noActionNeeded(.unquantified))
        guard case let .noActionNeeded(quiet) = state.outcome else { return }
        #expect(quiet.horizonDays == nil)
        #expect(quiet.horizonEnd == nil)
    }

    @Test("No-action is not a candidate")
    func noActionIsNotACandidate() throws {
        let state = AttentionCoordinator.evaluate(
            proposals: [], availability: currentSourcesAvailable
        )
        #expect(state.primary == nil)
        #expect(state.secondary.isEmpty)
        #expect(state.suppressed.isEmpty)
    }

    @Test("A candidate that only suppressed still leaves no actions available")
    func onlySuppressedIsNotActionsAvailable() throws {
        let state = AttentionCoordinator.evaluate(
            proposals: [proposal(.currentAccountDrift, identity: "quiet", actionable: false)],
            availability: currentSourcesAvailable
        )
        guard case .noActionNeeded = state.outcome else {
            Issue.record("a suppressed candidate is not an action")
            return
        }
        #expect(state.suppressed.count == 1)
    }

    // MARK: - Required funding gap contract

    /// The real-shape canary: €447.47 of holdings, a €661.61 landlord charge
    /// on 11 September, and therefore €214.14 missing on that day.
    private func fundingDocument(
        balance: String = "447.47",
        obligationAmount: String = "661.61",
        laterCharge: String? = nil
    ) -> FinanceDocument {
        var obligations = [
            RecurringObligation(
                id: "ob-housing",
                name: "Property manager",
                amount: euro(obligationAmount),
                spec: .monthly(
                    onDay: 11,
                    from: MonthKey(year: 2026, month: 9),
                    through: MonthKey(year: 2026, month: 9)
                ),
                requirement: .euroBankPayment(),
                spendingClass: .essential,
                budgetID: nil
            )
        ]
        if let laterCharge {
            // A second charge later in the horizon deepens the trough without
            // moving the first risk. The up-front bridge grows; the first-risk
            // shortfall does not — which is exactly why the two must never be
            // quoted as one sentence.
            obligations.append(
                RecurringObligation(
                    id: "ob-later",
                    name: "Later charge",
                    amount: euro(laterCharge),
                    spec: .monthly(
                        onDay: 20,
                        from: MonthKey(year: 2026, month: 9),
                        through: MonthKey(year: 2026, month: 9)
                    ),
                    requirement: .euroBankPayment(),
                    spendingClass: .essential,
                    budgetID: nil
                )
            )
        }
        return makeFundingDocument(balance: balance, obligations: obligations)
    }

    private func makeFundingDocument(
        balance: String,
        obligations: [RecurringObligation]
    ) -> FinanceDocument {
        FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [bank],
            balances: [AccountBalance(accountID: "acct-bank", balance: euro(balance), asOf: day("2026-09-03"))],
            planning: FinanceDocument.Planning(
                defaultScenario: .base,
                monthlyEconomicCeiling: nil,
                recurringObligations: obligations
            )
        )
    }

    /// One real forecast run. The candidate must consume it, never redo it.
    private func forecast(
        _ document: FinanceDocument,
        from: String = "2026-09-03",
        to: String = "2026-10-03"
    ) throws -> ForecastResult {
        try ForecastEngine.run(
            ForecastComposer.makeRequest(
                from: document, startDate: day(from), endDate: day(to)
            )
        )
    }

    @Test("J: the funding candidate pairs the shortfall with its own day")
    func fundingGapCoherence() throws {
        let document = fundingDocument()
        let result = try forecast(document)
        let outcome = AttentionFactAdapters.fundingGap(
            from: result,
            accountNames: ["acct-bank": "Bank"],
            triggerLabels: AttentionFactAdapters.triggerLabels(in: document)
        )
        let proposal = try #require(try outcome.get())
        guard case let .fundingGap(fact) = proposal.detail else {
            Issue.record("expected a funding fact")
            return
        }
        #expect(fact.shortfall == Amount.eur(214.14))
        #expect(fact.day == civil("2026-09-11"))
        #expect(fact.riskKind == .poolDeficit)
        #expect(fact.triggerLabel == "Property manager")
        // The amount and the date are the engine's own, taken together.
        #expect(fact.shortfall.minorUnits == result.firstRisk?.shortfall.minorUnits)
        #expect(DomainMapper.day(fact.day) == result.firstRisk?.day)
    }

    @Test("The funding candidate never quotes minimumBridgeRequired")
    func fundingGapIgnoresBridge() throws {
        let document = fundingDocument(laterCharge: "100.00")
        let result = try forecast(document)
        // The two figures are genuinely different here, so a mix-up is visible.
        #expect(result.minimumBridgeRequired.minorUnits != result.firstRisk?.shortfall.minorUnits)
        let proposal = try #require(
            try AttentionFactAdapters.fundingGap(
                from: result, accountNames: [:],
                triggerLabels: AttentionFactAdapters.triggerLabels(in: document)
            ).get()
        )
        guard case let .fundingGap(fact) = proposal.detail else { return }
        #expect(fact.shortfall.minorUnits != result.minimumBridgeRequired.minorUnits)
    }

    @Test("A proved single account names that account")
    func provedAccountSubject() throws {
        let document = fundingDocument()
        let proposal = try #require(
            try AttentionFactAdapters.fundingGap(
                from: try forecast(document), accountNames: ["acct-bank": "Bank"],
                triggerLabels: AttentionFactAdapters.triggerLabels(in: document)
            ).get()
        )
        #expect(proposal.subject == .account(id: "acct-bank", name: "Bank"))
    }

    @Test("A pool with several eligible accounts keeps the less specific subject")
    func poolSubjectStaysUnspecific() throws {
        var document = fundingDocument()
        document.accounts.append(wallet)
        document.balances.append(
            AccountBalance(accountID: "acct-wallet", balance: euro("0.00"), asOf: day("2026-09-03"))
        )
        let proposal = try #require(
            try AttentionFactAdapters.fundingGap(
                from: try forecast(document), accountNames: [:],
                triggerLabels: AttentionFactAdapters.triggerLabels(in: document)
            ).get()
        )
        guard case let .paymentPool(accounts, currency) = proposal.subject else {
            Issue.record("expected a pool subject, got \(proposal.subject)")
            return
        }
        #expect(accounts.count > 1)
        #expect(currency == "EUR")
    }

    @Test("No transfer source is ever inferred")
    func noTransferSourceInferred() throws {
        var document = fundingDocument()
        document.accounts.append(wallet)
        document.balances.append(
            AccountBalance(accountID: "acct-wallet", balance: euro("5000.00"), asOf: day("2026-09-03"))
        )
        let proposal = try AttentionFactAdapters.fundingGap(
            from: try forecast(document), accountNames: [:],
            triggerLabels: AttentionFactAdapters.triggerLabels(in: document)
        ).get()
        // A funded wallet removes the risk entirely rather than becoming a
        // recommended source to move money from.
        #expect(proposal == nil)
    }

    @Test("A solvent forecast produces no funding candidate")
    func solventForecastIsQuiet() throws {
        let document = fundingDocument(balance: "5000.00")
        let proposal = try AttentionFactAdapters.fundingGap(
            from: try forecast(document), accountNames: [:], triggerLabels: [:]
        ).get()
        #expect(proposal == nil)
    }

    @Test("An unresolvable trigger shows no label rather than an internal id")
    func unresolvedTriggerLabelIsDropped() throws {
        let document = fundingDocument()
        let proposal = try #require(
            try AttentionFactAdapters.fundingGap(
                from: try forecast(document), accountNames: [:], triggerLabels: [:]
            ).get()
        )
        guard case let .fundingGap(fact) = proposal.detail else { return }
        #expect(fact.triggerLabel == nil)
    }

    // MARK: - Refinement B: drift and authority nuisance policy

    /// A document whose provider snapshot differs from the ledger by one cent.
    private func driftDocument(driftCents: Int64) -> FinanceDocument {
        let ledger = euro("447.47")
        let provider = Money(minorUnits: ledger.minorUnits + driftCents, currency: .eur)
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [bank],
            balances: [AccountBalance(accountID: "acct-bank", balance: ledger, asOf: day("2026-09-03"))],
            planning: FinanceDocument.Planning(defaultScenario: .base),
            externalAccountBindings: [
                ExternalAccountBinding(
                    id: "bind-1", provider: .bnp, remoteOpaqueAccountID: "opaque-1",
                    localAccountID: "acct-bank", syncStartBoundary: day("2026-01-01"),
                    createdAt: Date(timeIntervalSince1970: 0)
                )
            ],
            providerBalanceSnapshots: [
                ProviderBalanceSnapshot(
                    id: "snap-1", bindingID: "bind-1", provider: .bnp, balanceType: "CLBD",
                    amount: provider, referenceDate: day("2026-09-03"),
                    observedAt: Date(timeIntervalSince1970: 1_777_680_000)
                )
            ]
        )
    }

    @Test("E: a one-cent discrepancy is a typed fact")
    func tinyDriftIsRepresentedAsFact() throws {
        let facts = AttentionFactAdapters.driftFacts(
            in: driftDocument(driftCents: 1), asOf: day("2026-09-03"),
            accountNames: ["acct-bank": "Bank"]
        )
        #expect(facts.count == 1)
        #expect(facts.first?.drift == Amount(minorUnits: 1, currencyCode: "EUR"))
        #expect(facts.first?.isComparable == true)
        #expect(facts.first?.accountName == "Bank")
    }

    @Test("E: a one-cent discrepancy never becomes a nuisance primary")
    func tinyDriftIsNotAPrimaryAction() throws {
        let facts = AttentionFactAdapters.driftFacts(
            in: driftDocument(driftCents: 1), asOf: day("2026-09-03"), accountNames: [:]
        )
        let basis = AttentionFactAdapters.driftPromotionBasis(
            facts: facts, freshness: .updated(Date(timeIntervalSince1970: 1_777_680_000)),
            accountsWithoutUsableAmount: []
        )
        #expect(basis == .none)

        let state = AttentionCoordinator.evaluate(
            proposals: [AttentionFactAdapters.driftProposal(facts: facts, basis: basis)!],
            availability: currentSourcesAvailable
        )
        #expect(state.primary == nil)
        #expect(state.suppressed.first?.eligibility == .suppressedBecauseNotActionable)
    }

    @Test("E: no monetary threshold exists — a large healthy drift is equally quiet")
    func largeDriftIsEquallyQuiet() throws {
        // The policy is not "small drift is quiet". It is "drift alone is not
        // established grounds for a task", whatever its size.
        for cents in [Int64(1), 5_000, 1_000_000] {
            let facts = AttentionFactAdapters.driftFacts(
                in: driftDocument(driftCents: cents), asOf: day("2026-09-03"), accountNames: [:]
            )
            let basis = AttentionFactAdapters.driftPromotionBasis(
                facts: facts, freshness: .updated(Date(timeIntervalSince1970: 1_777_680_000)),
                accountsWithoutUsableAmount: []
            )
            #expect(basis == .none, "\(cents) cents")
        }
    }

    @Test("Zero drift produces no fact at all")
    func zeroDriftProducesNothing() throws {
        let facts = AttentionFactAdapters.driftFacts(
            in: driftDocument(driftCents: 0), asOf: day("2026-09-03"), accountNames: [:]
        )
        #expect(facts.isEmpty)
        #expect(AttentionFactAdapters.driftProposal(facts: facts, basis: .none) == nil)
    }

    @Test("Drift promotes only on an established intervention state")
    func driftPromotesOnEstablishedState() throws {
        let facts = AttentionFactAdapters.driftFacts(
            in: driftDocument(driftCents: 250), asOf: day("2026-09-03"), accountNames: [:]
        )
        #expect(
            AttentionFactAdapters.driftPromotionBasis(
                facts: facts, freshness: .needsAttention, accountsWithoutUsableAmount: []
            ) == .providerAuthorityRequiresIntervention
        )
        #expect(
            AttentionFactAdapters.driftPromotionBasis(
                facts: facts, freshness: .updated(Date(timeIntervalSince1970: 0)),
                accountsWithoutUsableAmount: ["acct-bank"]
            ) == .currentAmountUnestablished
        )
        // Staleness is ordinary freshness and promotes nothing.
        #expect(
            AttentionFactAdapters.driftPromotionBasis(
                facts: facts, freshness: .stale(Date(timeIntervalSince1970: 0)),
                accountsWithoutUsableAmount: []
            ) == .none
        )
    }

    @Test("A promoted drift declares the dependency it compromises")
    func promotedDriftCompromisesAccountTruth() throws {
        let facts = AttentionFactAdapters.driftFacts(
            in: driftDocument(driftCents: 250), asOf: day("2026-09-03"), accountNames: [:]
        )
        let proposal = AttentionFactAdapters.driftProposal(
            facts: facts, basis: .providerAuthorityRequiresIntervention
        )
        #expect(proposal?.isActionable == true)
        #expect(proposal?.compromisedDependencies == [.currentAccountTruth])
    }

    @Test("G: ordinary freshness is not a task")
    func freshnessIsNotATask() throws {
        let reference = Date(timeIntervalSince1970: 1_777_680_000)
        #expect(AttentionFactAdapters.authority(from: .updated(reference)) == nil)
        #expect(AttentionFactAdapters.authority(from: .notConnected) == nil)

        for quiet in [BankFreshness.stale(reference), .neverSynced] {
            let state = AttentionCoordinator.evaluate(
                proposals: [AttentionFactAdapters.authority(from: quiet)!],
                availability: currentSourcesAvailable
            )
            #expect(state.primary == nil, "\(quiet)")
            #expect(state.suppressed.first?.eligibility == .suppressedBecauseNotActionable)
        }
    }

    @Test("G: an established authority state is a task")
    func needsAttentionIsATask() throws {
        let state = AttentionCoordinator.evaluate(
            proposals: [AttentionFactAdapters.authority(from: .needsAttention)!],
            availability: currentSourcesAvailable
        )
        #expect(state.primary?.kind == .authorityNeedsAttention)
        #expect(state.primary?.eligibility == .eligible)
    }

    @Test("A suppressed freshness diagnostic carries no timestamp")
    func freshnessDiagnosticIsClockFree() throws {
        let early = AttentionFactAdapters.authority(from: .stale(Date(timeIntervalSince1970: 1)))
        let late = AttentionFactAdapters.authority(from: .stale(Date(timeIntervalSince1970: 9_000_000)))
        #expect(early == late)
    }

    // MARK: - Evidence candidates

    @Test("K: pending evidence creates no action and no exception")
    func pendingEvidenceIsInert() throws {
        let pending = [
            observation(id: "obs-p1", amount: .eur(-12.50), status: .pending),
            observation(id: "obs-p2", amount: .eur(-3.10), status: .pending,
                        resolution: .provisional),
        ]
        #expect(AttentionFactAdapters.bookedEvidence(from: pending).isEmpty)
        #expect(
            AttentionFactAdapters.evidenceExceptions(
                from: pending, period: .month(MonthKey(year: 2026, month: 8))
            ).isEmpty
        )
    }

    @Test("Resolved and inactive-binding evidence creates no action")
    func resolvedEvidenceIsInert() throws {
        let settled = [
            observation(id: "obs-r1", amount: .eur(-12.50), resolution: .linked),
            observation(id: "obs-r2", amount: .eur(-12.50), resolution: .noEconomicEffect),
            observation(id: "obs-r3", amount: .eur(-12.50), bindingActive: false),
        ]
        #expect(AttentionFactAdapters.bookedEvidence(from: settled).isEmpty)
    }

    @Test("An unresolved booked observation is actionable")
    func unresolvedBookedEvidenceIsActionable() throws {
        let proposals = AttentionFactAdapters.bookedEvidence(
            from: [observation(id: "obs-799", amount: .eur(-7.99))]
        )
        #expect(proposals.count == 1)
        #expect(proposals.first?.isActionable == true)
        #expect(proposals.first?.orderingDay == civil("2026-08-07"))
        #expect(proposals.first?.orderingMinorUnits == -799)
    }

    @Test("A booked-to-pending provider downgrade remains a period exception")
    func providerDowngradeRemainsPeriodException() throws {
        let downgraded = observation(
            id: "obs-downgraded",
            amount: .eur(-24.00),
            status: .pending,
            resolution: .linked,
            providerStatusWarning: true
        )

        let exceptions = AttentionFactAdapters.evidenceExceptions(
            from: [downgraded],
            period: .month(MonthKey(year: 2026, month: 8))
        )

        let exception = try #require(exceptions.first)
        #expect(exception.kind == .providerStatusConflict)
        #expect(exception.day == day("2026-08-07"))
        #expect(exception.amount == euro("-24.00"))
    }

    @Test("A provider conflict does not change the user's prior resolution")
    func providerConflictPreservesResolution() throws {
        let resolved = observation(
            id: "obs-resolved",
            amount: .eur(-24.00),
            status: .pending,
            resolution: .noEconomicEffect,
            providerStatusWarning: true
        )

        _ = AttentionFactAdapters.evidenceExceptions(
            from: [resolved],
            period: .month(MonthKey(year: 2026, month: 8))
        )

        #expect(resolved.resolution == .noEconomicEffect)
        #expect(AttentionFactAdapters.bookedEvidence(from: [resolved]).isEmpty)
    }

    /// A settled-recurring duplicate still needs a person: the app's accepted
    /// policy is to leave it unresolved and require an explicit override, not
    /// to auto-link it or hide it.
    @Test("A settled-recurring duplicate candidate stays actionable")
    func settledRecurringStaysActionable() throws {
        let proposals = AttentionFactAdapters.bookedEvidence(
            from: [observation(
                id: "obs-799", amount: .eur(-7.99),
                conflict: ObservationDuplicateConflict(
                    kind: .settledRecurring, transactionIDs: ["t-1"], relatedObservationID: nil
                )
            )]
        )
        #expect(proposals.first?.isActionable == true)
    }

    // MARK: - The aggregate model limitation, sanitized

    /// One booked observation of −€162.44 standing against two existing
    /// −€81.22 transactions on the same account, in the same currency, with
    /// the same sign — the exact structural shape the evidence schema cannot
    /// encode. Identifiers are invented.
    private func aggregateDocument() -> FinanceDocument {
        let legs = { (amount: String) in [AccountLeg(accountID: "acct-bank", amount: self.euro(amount))] }
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [bank],
            balances: [AccountBalance(accountID: "acct-bank", balance: euro("500.00"), asOf: day("2026-08-01"))],
            transactions: [
                Transaction(id: "tx-a", date: day("2026-08-07"), kind: .expense,
                            legs: legs("-81.22"), factivity: .observed),
                Transaction(id: "tx-b", date: day("2026-08-07"), kind: .expense,
                            legs: legs("-81.22"), factivity: .observed),
            ],
            planning: FinanceDocument.Planning(defaultScenario: .base),
            externalAccountBindings: [
                ExternalAccountBinding(
                    id: "bind-1", provider: .bnp, remoteOpaqueAccountID: "opaque-1",
                    localAccountID: "acct-bank", syncStartBoundary: day("2026-01-01"),
                    createdAt: Date(timeIntervalSince1970: 0)
                )
            ],
            externalObservations: [
                ExternalObservation(
                    id: "obs-agg", bindingID: "bind-1", provider: .bnp, status: .booked,
                    creditDebitIndicator: .debit, amount: euro("-162.44"),
                    bookingDate: day("2026-08-07"), transactionDate: day("2026-08-07"),
                    eligibleForEconomicActual: true,
                    observedAt: Date(timeIntervalSince1970: 1_777_680_000)
                )
            ],
            observationResolutions: [
                ExternalObservationResolution(observationID: "obs-agg", state: .unreviewed)
            ]
        )
    }

    @Test("I: the aggregate shape is recognized by the app's own duplicate detection")
    func aggregateShapeIsRecognized() throws {
        let document = aggregateDocument()
        let conflict = DomainMapper().duplicateConflict(
            for: document.externalObservations[0], in: document
        )
        #expect(conflict?.kind == .aggregateExisting)
        #expect(conflict?.transactionIDs == ["tx-a", "tx-b"])
    }

    @Test("I: it creates no transaction and no evidence link")
    func aggregateCreatesNothing() throws {
        let document = aggregateDocument()
        #expect(document.transactions.count == 2)
        #expect(document.externalEvidenceLinks.isEmpty)
        #expect(document.observationResolutions.first?.state == .unreviewed)
        // Neither of the two dispositions that would falsify the record.
        #expect(document.observationResolutions.first?.state != .noEconomicEffect)
        #expect(document.observationResolutions.first?.state != .linkedToTransaction)
    }

    @Test("I: it creates no normal evidence action")
    func aggregateCreatesNoNormalAction() throws {
        let item = observation(
            id: "obs-agg", amount: .eur(-162.44),
            conflict: ObservationDuplicateConflict(
                kind: .aggregateExisting, transactionIDs: ["tx-a", "tx-b"], relatedObservationID: nil
            )
        )
        let proposals = AttentionFactAdapters.bookedEvidence(from: [item])
        #expect(proposals.count == 1)
        #expect(proposals.first?.isActionable == false)

        let state = AttentionCoordinator.evaluate(
            proposals: proposals, availability: currentSourcesAvailable
        )
        #expect(state.primary == nil)
        #expect(state.suppressed.first?.eligibility == .suppressedBecauseNotActionable)
    }

    @Test("I: it is carryable as a checkpoint exception and remains auditable")
    func aggregateIsCarryable() throws {
        let item = observation(
            id: "obs-agg", amount: .eur(-162.44),
            conflict: ObservationDuplicateConflict(
                kind: .aggregateExisting, transactionIDs: ["tx-a", "tx-b"], relatedObservationID: nil
            )
        )
        let exceptions = AttentionFactAdapters.evidenceExceptions(
            from: [item], period: .month(MonthKey(year: 2026, month: 8))
        )
        let exception = try #require(exceptions.first)
        #expect(exception.kind == .aggregateEvidenceModelLimitation)
        #expect(exception.amount == euro("-162.44"))
        #expect(exception.day == day("2026-08-07"))
    }

    /// Refinement C. The app's aggregate detection is an exact signed-cent
    /// pairing inside the existing five-day window: a *structural* candidate,
    /// not a source-backed proof that the observation is the same money.
    /// The conservative branch therefore applies.
    @Test("H: a structural aggregate suggestion cannot grant complete totals")
    func aggregateCannotGrantCompleteTotals() throws {
        let item = observation(
            id: "obs-agg", amount: .eur(-162.44),
            conflict: ObservationDuplicateConflict(
                kind: .aggregateExisting, transactionIDs: ["tx-a", "tx-b"], relatedObservationID: nil
            )
        )
        let exceptions = AttentionFactAdapters.evidenceExceptions(
            from: [item], period: .month(MonthKey(year: 2026, month: 8))
        )
        #expect(exceptions.first?.aggregateBasis == .structuralCandidateOnly)

        let readiness = PeriodCheckpointEvaluator.evaluate(
            PeriodCheckpointRequest(
                period: .month(MonthKey(year: 2026, month: 8)),
                kind: .monthly,
                asOf: day("2026-09-03"),
                review: try realReview(.month(MonthKey(year: 2026, month: 8))),
                exceptions: exceptions,
                // Acknowledgment is a confirmed decision about a whole
                // exception value, never a bare identifier — the app layer
                // reaches it through the same public boundary production will.
                confirmedAcknowledgments: try PeriodCheckpointAcknowledgmentConfirmation.confirm(
                    decisions: exceptions.filter { $0.id == "obs-agg" },
                    carriedExceptions: exceptions
                )
            )
        )
        #expect(readiness.quality == .withExceptions)
        #expect(readiness.safeClaims.unquestionablyCompleteTotals == false)
        #expect(readiness.safeClaims.completeEvidenceAudit == false)
        #expect(readiness.safeClaims.mayShowCalculatedTotals == true)
    }

    @Test("Nothing in the current typed data produces a source-established aggregate")
    func noSourceEstablishedAggregateExistsYet() throws {
        // The stronger basis exists in the taxonomy so a future source-backed
        // fact has somewhere truthful to land. No adapter emits it today.
        let item = observation(
            id: "obs-agg", amount: .eur(-162.44),
            conflict: ObservationDuplicateConflict(
                kind: .aggregateExisting, transactionIDs: ["tx-a", "tx-b"], relatedObservationID: nil
            )
        )
        let bases = AttentionFactAdapters
            .evidenceExceptions(from: [item], period: .month(MonthKey(year: 2026, month: 8)))
            .compactMap(\.aggregateBasis)
        #expect(!bases.contains(.sourceEstablishedAggregateRelationship))
    }

    // MARK: - Occurrences

    @Test("Only engine-overdue occurrences create overdue attention")
    func occurrenceStatusDrivesEligibility() throws {
        let overdue = occurrence("ob-a", "40.00", on: "2026-08-05", status: .overdue)
        let dueToday = occurrence("ob-today", "30.00", on: "2026-09-03", status: .due)
        let paid = occurrence("ob-b", "20.00", on: "2026-08-06",
                              status: .paid(actualTransactionID: "tx-1"))
        let skipped = occurrence("ob-s", "15.00", on: "2026-08-04", status: .skipped)
        let noLongerDue = occurrence("ob-n", "12.00", on: "2026-08-03", status: .noLongerDue)
        let future = occurrence("ob-c", "10.00", on: "2026-09-20", status: .due)

        let proposals = AttentionFactAdapters.overdueOccurrences(
            from: [overdue, dueToday, paid, skipped, noLongerDue, future]
        )
        #expect(proposals.map(\.identity).count == 1)
        let byID = Dictionary(uniqueKeysWithValues: proposals.map { ($0.identity, $0) })
        #expect(byID[overdue.id.description]?.conditionResolved == false)
        #expect(byID[dueToday.id.description] == nil)
        #expect(byID[future.id.description] == nil)
        #expect(byID[paid.id.description] == nil)
        #expect(byID[skipped.id.description] == nil)
        #expect(byID[noLongerDue.id.description] == nil)
        #expect(paid.status.isResolved)
        #expect(skipped.status.isResolved)
        #expect(noLongerDue.status.isResolved)
    }

    @Test("Occurrence exceptions carry only the overdue ones")
    func occurrenceExceptions() throws {
        let exceptions = AttentionFactAdapters.occurrenceExceptions(
            from: [
                occurrence("ob-a", "40.00", on: "2026-08-05", status: .overdue),
                occurrence("ob-b", "20.00", on: "2026-08-06",
                           status: .paid(actualTransactionID: "tx-1")),
                occurrence("ob-c", "10.00", on: "2026-09-05", status: .overdue),
            ],
            period: .month(MonthKey(year: 2026, month: 8))
        )
        #expect(exceptions.map(\.kind) == [.overdueExpectedOccurrence])
        #expect(exceptions.first?.amount == euro("40.00"))
    }

    private func occurrence(
        _ id: String, _ amount: String, on iso: String, status: OccurrenceStatus
    ) -> ExpectedOccurrence {
        ExpectedOccurrence(
            obligationID: id, name: id, expectedDay: day(iso), amount: euro(amount),
            requirement: .euroBankPayment(), spendingClass: .essential, status: status
        )
    }

    // MARK: - Month ready to close in 2.9A

    @Test("Readiness and the close action are different questions")
    func readinessIsNotACloseAction() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(
            PeriodCheckpointRequest(
                period: .month(MonthKey(year: 2026, month: 8)),
                kind: .monthly,
                asOf: day("2026-09-03"),
                review: try realReview(.month(MonthKey(year: 2026, month: 8)))
            )
        )
        // The period really is ready…
        #expect(readiness.disposition == .readyClean)

        // …and no Home action follows, because this request read no checkpoint
        // history. An unavailable comparison is not a verification CTA.
        #expect(
            AttentionFactAdapters.monthReadyToClose(
                from: readiness, asOf: day("2026-09-03"), periodLabel: "August"
            ) == nil
        )
        #expect(!readiness.baselineComparison.isEstablished)
    }

    // MARK: - Month ready to close against stored checkpoint history

    /// The same ready month, asked under each baseline comparison.
    private func closeProposal(
        _ comparison: PeriodCheckpointBaselineComparison
    ) throws -> AttentionCandidateProposal? {
        let readiness = PeriodCheckpointEvaluator.evaluate(
            PeriodCheckpointRequest(
                period: .month(MonthKey(year: 2026, month: 8)),
                kind: .monthly,
                asOf: day("2026-09-03"),
                review: try realReview(.month(MonthKey(year: 2026, month: 8))),
                baselineComparison: comparison
            )
        )
        #expect(readiness.disposition == .readyClean)
        return AttentionFactAdapters.monthReadyToClose(
            from: readiness, asOf: day("2026-09-03"), periodLabel: "August"
        )
    }

    @Test("P10: a month already current against its checkpoint proposes no close")
    func verifiedUnchangedMonthProposesNoClose() throws {
        #expect(try closeProposal(.unchangedSinceClose(previousQuality: .clean)) == nil)
        #expect(try closeProposal(.unchangedSinceClose(previousQuality: .withExceptions)) == nil)
    }

    @Test("P11: a month never closed still proposes a close")
    func neverClosedMonthStillProposesClose() throws {
        #expect(try closeProposal(.notPreviouslyClosed) != nil)
    }

    @Test("P12: a month that moved since its close still proposes a close")
    func changedMonthStillProposesClose() throws {
        #expect(
            try closeProposal(
                .changedSinceClose(previousQuality: .clean, changes: .init(.economicsChanged))
            ) != nil
        )
    }

    @Test("An unavailable or indeterminate comparison offers no verification action")
    func unavailableComparisonDoesNotProposeClose() throws {
        #expect(
            try closeProposal(
                .indeterminate(previousQuality: .clean, blockers: .init(.sourceGap))
            ) == nil
        )
        #expect(try closeProposal(.unavailable(.noBaselinePersistence)) == nil)
        #expect(
            try closeProposal(
                .requiresReverification(
                    previousQuality: .clean,
                    storedFormatToken: "v0",
                    comparisonFormat: .v1
                )
            ) == nil
        )
    }

    @Test("A blocked or undecided period offers no close proposal")
    func unreadyPeriodOffersNoClose() throws {
        let blocked = PeriodCheckpointEvaluator.evaluate(
            PeriodCheckpointRequest(
                period: .month(MonthKey(year: 2026, month: 8)),
                kind: .monthly, asOf: day("2026-08-15"),
                review: try realReview(.month(MonthKey(year: 2026, month: 8)))
            )
        )
        #expect(
            AttentionFactAdapters.monthReadyToClose(
                from: blocked, asOf: day("2026-08-15"), periodLabel: "August"
            ) == nil
        )
    }

    @Test("A never-closed month that still needs decisions still proposes review")
    func neverClosedMonthNeedingDecisionsStillProposes() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(
            PeriodCheckpointRequest(
                period: .month(MonthKey(year: 2026, month: 8)),
                kind: .monthly,
                asOf: day("2026-09-03"),
                review: try realReview(.month(MonthKey(year: 2026, month: 8))),
                exceptions: [
                    PeriodCheckpointException(
                        id: "obs-booked",
                        kind: .unknownBookedEconomics,
                        day: day("2026-08-07"),
                        amount: euro("-7.99")
                    )
                ],
                baselineComparison: .notPreviouslyClosed
            )
        )
        #expect(readiness.disposition == .needsDecisions)
        let proposal = try #require(
            AttentionFactAdapters.monthReadyToClose(
                from: readiness, asOf: day("2026-09-03"), periodLabel: "August 2026"
            )
        )
        guard case let .periodClose(changed, offset) = proposal.detail else {
            Issue.record("expected a period-close detail")
            return
        }
        #expect(changed == false)
        #expect(offset == -1)
    }

    @Test("A changed proposal names Review-changes occupancy, not identity")
    func changedProposalCarriesChangedFlag() throws {
        let proposal = try #require(
            try closeProposal(
                .changedSinceClose(previousQuality: .clean, changes: .init(.economicsChanged))
            )
        )
        guard case let .periodClose(changed, offset) = proposal.detail else {
            Issue.record("expected a period-close detail")
            return
        }
        #expect(changed == true)
        #expect(offset == -1)
    }

    // MARK: - Real-shape composition

    /// The approved physical-canary shape, sanitized: €447.47 of holdings, a
    /// first risk of €214.14 on 11 September triggered by the landlord charge,
    /// zero comparable drift, one unresolved €7.99-style booked observation, a
    /// settled expected occurrence and complete August coverage.
    private func realShapeInput() throws -> AttentionComposition.Input {
        var document = fundingDocument()
        document.transactions = [
            Transaction(
                id: "tx-settled", date: day("2026-08-05"), kind: .expense,
                legs: [AccountLeg(accountID: "acct-bank", amount: euro("-20.00"))],
                factivity: .observed
            )
        ]
        return AttentionComposition.Input(
            document: document,
            asOf: day("2026-09-03"),
            accountNames: ["acct-bank": "Bank"],
            forecast: try forecast(document),
            review: try realReview(.month(MonthKey(year: 2026, month: 8))),
            occurrences: [
                occurrence("ob-settled", "20.00", on: "2026-08-05",
                           status: .paid(actualTransactionID: "tx-settled"))
            ],
            observations: [observation(id: "obs-799", amount: .eur(-7.99))],
            freshness: .updated(Date(timeIntervalSince1970: 1_777_680_000)),
            categoryKeys: [:],
            period: .month(MonthKey(year: 2026, month: 8)),
            periodKind: .monthly,
            periodLabel: "August"
        )
    }

    @Test("Real-shape: funding gap is primary, unresolved evidence secondary")
    func realShapePrimaryAndSecondary() throws {
        let output = AttentionComposition.evaluate(try realShapeInput())
        #expect(output.attention.primary?.kind == .requiredFundingGap)
        #expect(output.attention.secondary.map(\.kind) == [.unresolvedBookedEvidence])
        #expect(output.attention.outcome == .actionsAvailable)

        guard case let .fundingGap(fact) = try #require(output.attention.primary).detail else {
            Issue.record("expected a funding fact")
            return
        }
        #expect(fact.shortfall == Amount.eur(214.14))
        #expect(fact.day == civil("2026-09-11"))
        #expect(fact.triggerLabel == "Property manager")
    }

    @Test("Real-shape: zero comparable drift, and no drift candidate")
    func realShapeHasNoDrift() throws {
        let output = AttentionComposition.evaluate(try realShapeInput())
        #expect(output.driftFacts.isEmpty)
        #expect(!output.attention.suppressed.contains { $0.kind == .currentAccountDrift })
        #expect(output.attention.primary?.kind != .currentAccountDrift)
    }

    @Test("Real-shape: August needs decisions until the evidence is handled")
    func realShapeAugustNeedsDecisions() throws {
        let output = AttentionComposition.evaluate(try realShapeInput())
        #expect(output.readiness.disposition == .needsDecisions)
        #expect(output.readiness.quality == .withExceptions)
        #expect(output.readiness.undecidedExceptions.map(\.kind) == [.unknownBookedEconomics])
        #expect(output.readiness.blockers.isEmpty)
    }

    @Test("Real-shape: the close action is suppressed, not fabricated")
    func realShapeCloseIsSuppressed() throws {
        let output = AttentionComposition.evaluate(try realShapeInput())
        #expect(!output.attention.secondary.contains { $0.kind == .monthReadyToClose })
        #expect(output.availability.status(.periodCheckpointBaseline)
                == .unavailable(.notEvaluated))
        #expect(output.availability.isFullyEvaluated(for: .currentAttention))
        #expect(!output.availability.isFullyEvaluated(for: .checkpointBaseline))
    }

    @Test("Real-shape: the composition is deterministic")
    func realShapeIsDeterministic() throws {
        let first = AttentionComposition.evaluate(try realShapeInput())
        let second = AttentionComposition.evaluate(try realShapeInput())
        #expect(first.attention == second.attention)
        #expect(first.readiness == second.readiness)
        #expect(first.driftFacts == second.driftFacts)
    }

    @Test("A: a coverage-blocked period leaves the current funding risk determinate")
    func historicalCoverageDoesNotInvalidateCurrent() throws {
        var input = try realShapeInput()
        // No affirmative coverage evidence at all: the engine's own
        // fail-closed rule makes August's coverage insufficient.
        input.review = try realReview(
            .month(MonthKey(year: 2026, month: 8)), coverage: .absent
        )
        let output = AttentionComposition.evaluate(input)
        #expect(output.readiness.disposition == .blocked)
        #expect(output.attention.primary?.kind == .requiredFundingGap)
        #expect(output.attention.primary?.eligibility == .eligible)
        #expect(output.attention.outcome == .actionsAvailable)
    }

    @Test("A missing forecast makes attention indeterminate, not quiet")
    func missingForecastIsIndeterminate() throws {
        var input = try realShapeInput()
        input.forecast = nil
        input.observations = []
        let output = AttentionComposition.evaluate(input)
        #expect(output.attention.outcome == .indeterminate(failedKeys: [.forecastProjection]))
    }

    @Test("A quiet composition quotes the horizon its own forecast established")
    func quietCompositionQuotesItsForecast() throws {
        var input = try realShapeInput()
        let solvent = fundingDocument(balance: "5000.00")
        input.document = solvent
        input.forecast = try forecast(solvent)
        input.observations = []
        input.occurrences = []
        let output = AttentionComposition.evaluate(input)
        #expect(output.attention.outcome == .noActionNeeded(
            AttentionQuiet(horizonDays: 30, horizonEnd: civil("2026-10-03"))
        ))
    }

    // MARK: - Helpers

    /// One real review of `interval`, produced by the authoritative engine.
    ///
    /// The result types carry no public memberwise initialiser, which is the
    /// right shape: a `ReviewResult` is something the engine produces, not
    /// something a caller assembles. So the fixture runs the engine, and the
    /// checkpoint consumes exactly what production would hand it.
    private func realReview(
        _ interval: ReviewInterval,
        document: FinanceDocument? = nil,
        coverage: ReviewCoverageInput? = nil
    ) throws -> ReviewResult {
        try ReviewEngine.review(
            ReviewRequest(
                document: document ?? FinanceDocument(
                    schemaVersion: Interchange.currentSchemaVersion,
                    documentKind: "TEST",
                    accounts: [bank],
                    balances: [
                        AccountBalance(
                            accountID: "acct-bank", balance: euro("447.47"),
                            asOf: interval.start
                        )
                    ],
                    planning: FinanceDocument.Planning(defaultScenario: .base)
                ),
                kind: .monthly,
                interval: interval,
                asOf: interval.end,
                coverage: coverage ?? .liveCovered([interval])
            )
        )
    }


    /// The composition boundary carries category keys into the projection.
    /// This is the hop where the silent `categoryKeys: [:]` default used to
    /// swallow them, so a budget recategorisation projected as no change.
    @Test("Composition threads category keys into the checkpoint projection")
    func compositionThreadsCategoryKeysIntoTheProjection() throws {
        var input = try realShapeInput()
        input.categoryKeys = ["tx-settled": "groceries"]
        let categorised = AttentionComposition.readiness(for: input)

        input.categoryKeys = ["tx-settled": "restaurants"]
        let recategorised = AttentionComposition.readiness(for: input)

        input.categoryKeys = [:]
        let uncategorised = AttentionComposition.readiness(for: input)

        #expect(categorised.projection?.transactions.first?.categoryKey == "groceries")
        #expect(recategorised.projection?.transactions.first?.categoryKey == "restaurants")
        #expect(uncategorised.projection?.transactions.first?.categoryKey == nil)
        #expect(categorised.projection != recategorised.projection)
        #expect(categorised.projection != uncategorised.projection)
    }

    // MARK: - Semantic projection prerequisite: one period rule, transported

    /// The app never restates the fallback chain. `DomainMapper` carries
    /// `ExternalObservation.economicPeriodDay` onto the surface, and the
    /// adapters read that.
    @Test("The surface carries the domain's economic period day verbatim")
    func surfaceTransportsTheDomainPeriodDay() throws {
        let shapes: [(String, ExternalObservation)] = [
            ("bnp-card", prereqObservation("bnp-card", booking: "2026-09-01", derived: "2026-08-31")),
            ("bnp-plain", prereqObservation("bnp-plain", booking: "2026-08-15")),
            ("paypal", prereqObservation("paypal", transaction: "2026-08-15")),
            ("revolut", prereqObservation("revolut", booking: "2026-08-15", value: "2026-08-16")),
            ("value-only", prereqObservation("value-only", value: "2026-08-15")),
            ("dateless", prereqObservation("dateless"))
        ]
        let document = prereqDocument(observations: shapes.map(\.1),
                                      resolutions: shapes.map { prereqResolution($0.0, .unreviewed) })
        let surface = DomainMapper().bankingSurface(document: document, transactionPresentation: [:])
        let byID = Dictionary(uniqueKeysWithValues: surface.observations.map { ($0.id, $0) })

        for (id, observation) in shapes {
            let carried = byID[id]?.dates.economicPeriod.flatMap(DomainMapper.day)
            #expect(carried == observation.economicPeriodDay, "\(id) must carry the domain's own answer")
        }
    }

    /// Matrix item 6, app half: over every combination of the four provider
    /// dates, every observation the exception adapter scopes into a period is
    /// also in that period's projection. The adapter may be narrower — it
    /// filters on binding, status and resolution — but it can never be wider.
    @Test("Exception membership is always a subset of projection membership")
    func exceptionMembershipNeverEscapesTheProjection() throws {
        let candidates: [String?] = [nil, "2026-07-31", "2026-08-15", "2026-09-01"]
        let august = ReviewInterval.month(MonthKey(year: 2026, month: 8))
        var checked = 0

        for booking in candidates {
            for transaction in candidates {
                for value in candidates {
                    for derived in candidates {
                        let observation = prereqObservation(
                            "o1", booking: booking, transaction: transaction,
                            value: value, derived: derived
                        )
                        let document = prereqDocument(
                            observations: [observation],
                            resolutions: [prereqResolution("o1", .unreviewed)]
                        )
                        let surface = DomainMapper().bankingSurface(
                            document: document, transactionPresentation: [:]
                        )
                        let exceptions = Set(
                            AttentionFactAdapters
                                .evidenceExceptions(from: surface.observations, period: august)
                                .map(\.id)
                        )
                        let projected = Set(
                            SemanticPeriodProjectionBuilder.projection(
                                for: august, kind: .monthly, in: document,
                                coverage: try prereqCompleteCoverage(august),
                                budget: SemanticBudgetFact(try ReviewEngine.review(ReviewRequest(
                                    document: document, kind: .monthly, interval: august, asOf: august.end,
                                    coverage: ReviewCoverageInput(liveCoveredIntervals: [august])
                                )).budget),
                                categoryKeys: [:], aggregateFacts: [:], expectations: []
                            ).observations.map(\.id)
                        )
                        #expect(
                            exceptions.subtracting(projected).isEmpty,
                            "b=\(booking ?? "-") t=\(transaction ?? "-") v=\(value ?? "-") d=\(derived ?? "-")"
                        )
                        checked += 1
                    }
                }
            }
        }
        #expect(checked == 256)
    }

    /// The aggregate pairing the projection carries is read from the same
    /// `duplicateConflict` the exception is raised from, so the two can never
    /// describe different transactions.
    @Test("Projected aggregate pairing matches the exception's own conflict")
    func aggregateFactMatchesTheExceptionSource() throws {
        let conflict = ObservationDuplicateConflict(
            kind: .aggregateExisting,
            transactionIDs: ["tx-b", "tx-a"],
            relatedObservationID: nil
        )
        let item = observation(id: "obs-agg", amount: .eur(-162.44), conflict: conflict)
        let facts = AttentionFactAdapters.aggregateFacts(from: [item])

        #expect(facts["obs-agg"]?.basis == .structuralCandidateOnly)
        #expect(facts["obs-agg"]?.pairedTransactionIDs == ["tx-a", "tx-b"])

        let exceptions = AttentionFactAdapters.evidenceExceptions(
            from: [item], period: ReviewInterval.month(MonthKey(year: 2026, month: 8))
        )
        #expect(exceptions.first?.kind == .aggregateEvidenceModelLimitation)
        #expect(exceptions.first?.aggregateBasis == facts["obs-agg"]?.basis)
    }

    // MARK: - Prerequisite fixtures

    private func prereqBinding(isActive: Bool = true) -> ExternalAccountBinding {
        ExternalAccountBinding(
            id: "binding-1", provider: .bnp, remoteOpaqueAccountID: "remote-1",
            localAccountID: "acct-bank", syncStartBoundary: day("2026-01-01"),
            isActive: isActive, createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func prereqObservation(
        _ id: String,
        booking: String? = nil,
        transaction: String? = nil,
        value: String? = nil,
        derived: String? = nil
    ) -> ExternalObservation {
        ExternalObservation(
            id: id, bindingID: "binding-1", provider: .bnp, status: .booked,
            creditDebitIndicator: .debit, amount: euro("-16.44"),
            bookingDate: booking.map(day), transactionDate: transaction.map(day),
            valueDate: value.map(day), derivedTransactionDate: derived.map(day),
            derivedDateProvenance: derived == nil ? nil : .parsedFromProviderRemittance,
            eligibleForEconomicActual: true,
            observedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func prereqResolution(
        _ id: String, _ state: ObservationResolutionState
    ) -> ExternalObservationResolution {
        ExternalObservationResolution(observationID: id, state: state)
    }

    private func prereqDocument(
        observations: [ExternalObservation],
        resolutions: [ExternalObservationResolution]
    ) -> FinanceDocument {
        FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [bank],
            balances: [AccountBalance(accountID: "acct-bank", balance: euro("800.00"),
                                      asOf: day("2026-01-01"))],
            planning: FinanceDocument.Planning(defaultScenario: .base),
            externalAccountBindings: [prereqBinding()],
            externalObservations: observations,
            observationResolutions: resolutions
        )
    }

    /// Coverage from the engine itself — `ReviewCoverage` has no public
    /// initializer, so a test cannot fabricate a coverage verdict.
    private func prereqCompleteCoverage(_ interval: ReviewInterval) throws -> ReviewCoverage {
        try ReviewEngine.review(
            ReviewRequest(
                document: FinanceDocument(
                    schemaVersion: Interchange.currentSchemaVersion,
                    documentKind: "TEST", accounts: [bank], balances: [],
                    planning: FinanceDocument.Planning(defaultScenario: .base)
                ),
                kind: .monthly, interval: interval, asOf: interval.end,
                coverage: ReviewCoverageInput(liveCoveredIntervals: [interval])
            )
        ).coverage
    }

}
