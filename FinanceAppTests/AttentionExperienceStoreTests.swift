import FinanceCore
import Foundation
import Testing
@testable import FinanceApp

/// Phase 2.9B store coherence. All values and identities are synthetic.
@MainActor
struct AttentionExperienceStoreTests {
    private func day(_ iso: String) -> Day { Day(isoString: iso)! }
    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    private func document() -> FinanceDocument {
        let account = Account(
            id: "account-test",
            name: "Test current account",
            currency: .eur,
            kind: .bank,
            supportedRails: PaymentRail.euroBankRails,
            drawOrder: 0
        )
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account],
            balances: [
                AccountBalance(
                    accountID: account.id,
                    balance: euro("500.00"),
                    asOf: day("2026-09-03")
                )
            ],
            planning: FinanceDocument.Planning(defaultScenario: .base)
        )
    }

    private func fundingDocument() -> FinanceDocument {
        let account = Account(
            id: "account-payment",
            name: "Payment account",
            currency: .eur,
            kind: .bank,
            supportedRails: PaymentRail.euroBankRails,
            drawOrder: 0
        )
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account],
            balances: [
                AccountBalance(
                    accountID: account.id,
                    balance: euro("50.00"),
                    asOf: day("2026-09-03")
                )
            ],
            planning: FinanceDocument.Planning(
                defaultScenario: .base,
                recurringObligations: [
                    RecurringObligation(
                        id: "ob-payment",
                        name: "Test payment",
                        amount: euro("100.00"),
                        spec: .monthly(
                            onDay: 11,
                            from: MonthKey(year: 2026, month: 9),
                            through: MonthKey(year: 2026, month: 9)
                        ),
                        requirement: .euroBankPayment(),
                        spendingClass: .essential
                    )
                ]
            )
        )
    }

    private var available: AttentionSourceAvailability {
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

    private func observation(_ index: Int, aggregate: Bool = false) -> SyncedObservationItem {
        SyncedObservationItem(
            id: "observation-\(index)",
            providerName: "Test Bank",
            providerAccountName: "Test current account",
            isAccountBindingActive: true,
            amount: Amount(minorUnits: -Int64(index + 1) * 100, currencyCode: "EUR"),
            status: .booked,
            resolution: .unreviewed,
            displayMerchant: "Test item \(index)",
            observedMerchant: nil,
            rawMerchantText: nil,
            remittance: nil,
            merchantEmail: nil,
            bankTransactionCode: nil,
            dates: ObservationDates(
                booking: CalendarDay(year: 2026, month: 9, day: index + 1),
                transaction: nil,
                value: nil,
                derivedTransaction: nil,
                derivedProvenanceLabel: nil,
                economicPeriod: CalendarDay(year: 2026, month: 9, day: index + 1)
            ),
            observedAt: Date(timeIntervalSince1970: 1_788_000_000 + Double(index)),
            suggestions: [],
            duplicateConflict: aggregate
                ? ObservationDuplicateConflict(
                    kind: .aggregateExisting,
                    transactionIDs: ["record-a", "record-b"],
                    relatedObservationID: nil
                )
                : nil,
            hasProviderStatusWarning: false
        )
    }

    private func evidenceProposal(_ index: Int, actionable: Bool = true) -> AttentionCandidateProposal {
        AttentionCandidateProposal(
            kind: .unresolvedBookedEvidence,
            identity: "observation-\(index)",
            subject: .observation(id: "observation-\(index)"),
            detail: .bookedEvidence(
                amount: Amount(minorUnits: -Int64(index + 1) * 100, currencyCode: "EUR"),
                day: CalendarDay(year: 2026, month: 9, day: index + 1)
            ),
            dependencies: [.evidenceReviewQueue],
            isActionable: actionable
        )
    }

    @Test("Published snapshot retains the exact forecast evaluation that produced it")
    func publishedSnapshotRetainsForecast() throws {
        var runCount = 0
        var evaluated: ForecastResult?
        let store = FinanceStore(
            document: document(),
            today: day("2026-09-03"),
            scenario: .base
        ) { request in
            runCount += 1
            let result = try ForecastEngine.run(request)
            evaluated = result
            return result
        }

        #expect(runCount == 1)
        #expect(store.snapshotEvaluation.forecast?.startDate == evaluated?.startDate)
        #expect(store.snapshotEvaluation.forecast?.endDate == evaluated?.endDate)
        #expect(store.snapshotEvaluation.forecast?.firstRisk == evaluated?.firstRisk)
        #expect(store.snapshot.horizonDays == 120)
        #expect(store.safeToUseIsAvailable)
    }

    @Test("Snapshot hero and funding presentation consume one exact risky forecast")
    func riskyForecastIsSharedWithoutSecondRun() throws {
        var runCount = 0
        var evaluated: ForecastResult?
        let store = FinanceStore(
            document: fundingDocument(),
            today: day("2026-09-03"),
            scenario: .base
        ) { request in
            runCount += 1
            let result = try ForecastEngine.run(request)
            evaluated = result
            return result
        }

        let risk = try #require(evaluated?.firstRisk)
        let funding = try #require(store.attentionPresentation.fundingNeeded)
        #expect(runCount == 1)
        #expect(store.snapshotEvaluation.forecast?.firstRisk == risk)
        #expect(store.snapshot.firstRisk?.shortfall?.minorUnits == risk.shortfall.minorUnits)
        #expect(store.snapshot.firstRisk?.date == DomainMapper.civilDay(risk.day))
        #expect(funding.unsettled.minorUnits == risk.shortfall.minorUnits)
        #expect(funding.day == DomainMapper.civilDay(risk.day))
        #expect(funding.requested.minorUnits - funding.settled.minorUnits == funding.unsettled.minorUnits)
        #expect(funding.subject == .account(name: "Payment account", kind: "Bank"))
    }

    @Test("Forecast failure preserves populated account state instead of onboarding")
    func failureIsNotAnEmptyStore() {
        let store = FinanceStore(
            document: document(),
            today: day("2026-09-03"),
            scenario: .base
        ) { _ in
            throw ForecastError.emptyHorizon
        }

        #expect(!store.isEmpty)
        #expect(store.snapshotProjectionFailed)
        #expect(!store.safeToUseIsAvailable)
        #expect(store.snapshot.accounts.map(\.name) == ["Test current account"])
        #expect(store.snapshot.accountCash == .eur(500))
    }

    @Test("Presentation exposes ACT, REVIEW ONLY, QUIET and INDETERMINATE states")
    func fourHomeStates() {
        var snapshot = FinanceAppSnapshot.empty(asOf: CalendarDay(year: 2026, month: 9, day: 3))
        let gap = RequiredFundingGapFact(
            riskKind: .poolDeficit,
            day: CalendarDay(year: 2026, month: 9, day: 12),
            shortfall: .eur(75),
            triggerLabel: "Test payment",
            triggerEventID: "event-payment",
            subject: .paymentPool(eligibleAccountIDs: [], currencyCode: "EUR"),
            settlementFailure: SettlementFailureFact(
                day: CalendarDay(year: 2026, month: 9, day: 12),
                requested: .eur(100),
                settled: .eur(25),
                unsettled: .eur(75),
                eligibleAccountIDs: []
            )
        )
        let actState = AttentionCoordinator.evaluate(
            proposals: [
                AttentionCandidateProposal(
                    kind: .requiredFundingGap,
                    identity: "risk@2026-09-12",
                    subject: gap.subject,
                    detail: .fundingGap(gap),
                    dependencies: [.forecastProjection, .currentAccountTruth]
                )
            ],
            availability: available
        )
        let act = AttentionPresentationMapper.present(
            actState, snapshot: snapshot, heroIsAvailable: true
        )
        guard case let .act(card, _) = act.home else {
            Issue.record("Expected ACT")
            return
        }
        #expect(card.title.contains("75"))
        #expect(act.fundingNeeded?.unsettled == .eur(75))
        #expect(
            act.fundingNeeded?.day
                == CalendarDay(year: 2026, month: 9, day: 12)
        )

        snapshot.syncedObservations = [observation(0)]
        let reviewState = AttentionCoordinator.evaluate(
            proposals: [evidenceProposal(0)], availability: available
        )
        let review = AttentionPresentationMapper.present(
            reviewState, snapshot: snapshot, heroIsAvailable: true
        )
        guard case let .reviewOnly(count) = review.home else {
            Issue.record("Expected REVIEW ONLY")
            return
        }
        #expect(count == 1)

        let quietState = AttentionCoordinator.evaluate(
            proposals: [],
            availability: available,
            quiet: AttentionQuiet(
                horizonDays: 119,
                horizonEnd: CalendarDay(year: 2026, month: 12, day: 31)
            )
        )
        let quiet = AttentionPresentationMapper.present(
            quietState, snapshot: snapshot, heroIsAvailable: true
        )
        guard case let .quiet(detail) = quiet.home else {
            Issue.record("Expected QUIET")
            return
        }
        #expect(detail?.contains("31") == true)

        let uncertainState = AttentionCoordinator.evaluate(
            proposals: [],
            availability: available.recording(
                .evidenceReviewQueue,
                .unavailable(.engineDidNotProduceResult)
            )
        )
        let uncertain = AttentionPresentationMapper.present(
            uncertainState, snapshot: snapshot, heroIsAvailable: true
        )
        guard case let .indeterminate(message) = uncertain.home else {
            Issue.record("Expected INDETERMINATE")
            return
        }
        #expect(message.message == "Your bank records couldn't all be checked.")
        #expect(uncertain.heroIsAvailable)
    }

    @Test("An ended month that needs verification becomes the Home action")
    func monthVerificationBecomesHomeAction() {
        let snapshot = FinanceAppSnapshot.empty(asOf: CalendarDay(year: 2026, month: 9, day: 3))
        let sources = available.recording(.periodCheckpointBaseline, .available)
        let neverClosed = AttentionCoordinator.evaluate(
            proposals: [
                AttentionCandidateProposal(
                    kind: .monthReadyToClose,
                    identity: "close:2026-08-01",
                    subject: .period(label: "August 2026"),
                    detail: .periodClose(changed: false, monthOffset: -1),
                    dependencies: [.periodReview, .periodCheckpointBaseline]
                )
            ],
            availability: sources
        )
        let never = AttentionPresentationMapper.present(
            neverClosed, snapshot: snapshot, heroIsAvailable: true
        )
        guard case let .act(card, _) = never.home else {
            Issue.record("expected a Home action")
            return
        }
        #expect(card.title == "August 2026 isn't verified yet.")
        #expect(card.actionTitle == "Review month")
        #expect(
            card.destination
                == .insightsMonthVerification(ReviewPeriodSelection(scope: .month, offset: -1))
        )

        let changedState = AttentionCoordinator.evaluate(
            proposals: [
                AttentionCandidateProposal(
                    kind: .monthReadyToClose,
                    identity: "close:2026-08-01",
                    subject: .period(label: "August 2026"),
                    detail: .periodClose(changed: true, monthOffset: -1),
                    dependencies: [.periodReview, .periodCheckpointBaseline]
                )
            ],
            availability: sources
        )
        let changed = AttentionPresentationMapper.present(
            changedState, snapshot: snapshot, heroIsAvailable: true
        )
        guard case let .act(changedCard, _) = changed.home else {
            Issue.record("expected a changed-month Home action")
            return
        }
        #expect(changedCard.title == "August 2026 changed since verification.")
        #expect(changedCard.actionTitle == "Review changes")
    }

    @Test("A funding gap stays in front of month verification")
    func fundingGapOutranksMonthVerificationOnHome() {
        let snapshot = FinanceAppSnapshot.empty(asOf: CalendarDay(year: 2026, month: 9, day: 3))
        let gap = RequiredFundingGapFact(
            riskKind: .poolDeficit,
            day: CalendarDay(year: 2026, month: 9, day: 12),
            shortfall: .eur(75),
            triggerLabel: "Test payment",
            triggerEventID: "event-payment",
            subject: .paymentPool(eligibleAccountIDs: [], currencyCode: "EUR"),
            settlementFailure: SettlementFailureFact(
                day: CalendarDay(year: 2026, month: 9, day: 12),
                requested: .eur(100),
                settled: .eur(25),
                unsettled: .eur(75),
                eligibleAccountIDs: []
            )
        )
        let state = AttentionCoordinator.evaluate(
            proposals: [
                AttentionCandidateProposal(
                    kind: .requiredFundingGap,
                    identity: "risk@2026-09-12",
                    subject: gap.subject,
                    detail: .fundingGap(gap),
                    dependencies: [.forecastProjection, .currentAccountTruth]
                ),
                AttentionCandidateProposal(
                    kind: .monthReadyToClose,
                    identity: "close:2026-08-01",
                    subject: .period(label: "August 2026"),
                    detail: .periodClose(changed: false, monthOffset: -1),
                    dependencies: [.periodReview, .periodCheckpointBaseline]
                )
            ],
            availability: available.recording(.periodCheckpointBaseline, .available)
        )
        let presentation = AttentionPresentationMapper.present(
            state, snapshot: snapshot, heroIsAvailable: true
        )
        guard case let .act(card, _) = presentation.home else {
            Issue.record("expected the funding card")
            return
        }
        #expect(card.destination == .planFundingNeeded)
        #expect(card.actionTitle == "See what's needed")
    }

    @Test("Review count is pre-cap and excludes aggregate and pending work")
    func reviewCountIsTruthfulBeyondSecondaryCap() {
        var snapshot = FinanceAppSnapshot.empty(asOf: CalendarDay(year: 2026, month: 9, day: 3))
        snapshot.syncedObservations = (0..<5).map { observation($0) }
            + [observation(8, aggregate: true), observation(9)]
        snapshot.currentPendingProviderSnapshots = [
            CurrentPendingProviderSnapshot(
                id: "test-provider",
                providerName: "Test Bank",
                authoritativeAt: Date(timeIntervalSince1970: 1_788_000_100),
                observationIDs: ["observation-9"]
            )
        ]
        // Make the last observation genuinely provisional/pending.
        let pending = SyncedObservationItem(
            id: "observation-9",
            providerName: "Test Bank",
            providerAccountName: "Test current account",
            isAccountBindingActive: true,
            amount: .eur(0),
            status: .pending,
            resolution: .provisional,
            displayMerchant: "Pending item",
            observedMerchant: nil,
            rawMerchantText: nil,
            remittance: nil,
            merchantEmail: nil,
            bankTransactionCode: nil,
            dates: ObservationDates(
                booking: CalendarDay(year: 2026, month: 9, day: 10),
                transaction: nil,
                value: nil,
                derivedTransaction: nil,
                derivedProvenanceLabel: nil,
                economicPeriod: CalendarDay(year: 2026, month: 9, day: 10)
            ),
            observedAt: Date(timeIntervalSince1970: 1_788_000_200),
            suggestions: [],
            duplicateConflict: nil,
            hasProviderStatusWarning: false
        )
        snapshot.syncedObservations.removeAll { $0.id == pending.id }
        snapshot.syncedObservations.append(pending)

        let proposals = (0..<5).map { evidenceProposal($0) }
            + [evidenceProposal(8, actionable: false)]
        let state = AttentionCoordinator.evaluate(
            proposals: proposals, availability: available
        )
        #expect(state.secondary.count == 3)

        let presentation = AttentionPresentationMapper.present(
            state, snapshot: snapshot, heroIsAvailable: true
        )
        #expect(presentation.actionableReviewCount == 5)
        #expect(presentation.activity.decisions.count == 5)
        #expect(presentation.activity.decisions.allSatisfy {
            if case .observationReview = $0.destination { return true }
            return false
        })
        #expect(presentation.activity.limitations.count == 1)
        #expect(presentation.activity.pending.count == 1)
    }

    @Test("Activity routes overdue payment work to the existing decision workflow")
    func activityPaymentDestination() {
        let expectedDay = CalendarDay(year: 2026, month: 9, day: 2)
        let payment = ExpectedPayment(
            id: "obligation-test@2026-09-02",
            ruleID: "obligation-test",
            ruleName: "Test subscription",
            expectedDate: expectedDay,
            amount: .eur(12),
            status: .overdue,
            expectedAccountLabel: "Test current account"
        )
        var snapshot = FinanceAppSnapshot.empty(asOf: expectedDay)
        snapshot.expectedPayments = [payment]
        let proposal = AttentionCandidateProposal(
            kind: .overdueExpectedOccurrence,
            identity: payment.id,
            subject: .expectedOccurrence(
                obligationID: payment.ruleID,
                name: payment.ruleName
            ),
            detail: .overdueOccurrence(amount: payment.amount, expectedDay: expectedDay),
            dependencies: [.expectedOccurrenceLedger]
        )
        let state = AttentionCoordinator.evaluate(
            proposals: [proposal], availability: available
        )

        let presentation = AttentionPresentationMapper.present(
            state, snapshot: snapshot, heroIsAvailable: true
        )
        #expect(presentation.activity.paymentsToConfirm.count == 1)
        #expect(presentation.activity.paymentsToConfirm[0].subtitle.contains("nothing matched"))
        if case let .expectedPayment(destination) =
            presentation.activity.paymentsToConfirm[0].destination {
            #expect(destination == payment)
        } else {
            Issue.record("Expected exact expected-payment destination")
        }
    }

    @Test("Home removes only the primary trigger inside the seven-day window")
    func nextSevenDaysDeduplicatesExactTrigger() {
        let start = CalendarDay(year: 2026, month: 9, day: 3)
        var snapshot = FinanceAppSnapshot.empty(asOf: start)
        snapshot.upcomingEvents = [
            PlannedEvent(
                id: "primary-trigger",
                date: CalendarDay(year: 2026, month: 9, day: 6),
                label: "Primary payment",
                amount: .eur(-100),
                isInflow: false,
                isGuaranteedButNotReceived: false,
                certaintyLabel: nil,
                isRecovery: false,
                hasApproximateDate: false,
                note: nil
            ),
            PlannedEvent(
                id: "other-event",
                date: CalendarDay(year: 2026, month: 9, day: 7),
                label: "Other payment",
                amount: .eur(-20),
                isInflow: false,
                isGuaranteedButNotReceived: false,
                certaintyLabel: nil,
                isRecovery: false,
                hasApproximateDate: false,
                note: nil
            ),
            PlannedEvent(
                id: "outside-window",
                date: CalendarDay(year: 2026, month: 9, day: 20),
                label: "Later payment",
                amount: .eur(-200),
                isInflow: false,
                isGuaranteedButNotReceived: false,
                certaintyLabel: nil,
                isRecovery: false,
                hasApproximateDate: false,
                note: nil
            ),
        ]

        #expect(
            PlanningTotals.nextSevenDays(
                from: snapshot,
                limit: 3,
                excludingEventID: "primary-trigger"
            ).map(\.id) == ["other-event"]
        )
        // A risk outside Home's window removes nothing that would have shown.
        #expect(
            Set(PlanningTotals.nextSevenDays(
                from: snapshot,
                limit: 3,
                excludingEventID: "outside-window"
            ).map(\.id)) == ["primary-trigger", "other-event"]
        )
    }
}
