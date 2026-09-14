import XCTest
@testable import FinanceCore

/// Phase 2.9A — period checkpoint semantics and the conceptual projection.
///
/// Every fixture is synthetic. Amounts, names and identifiers are invented for
/// the test; none of them is anybody's financial data.
final class PeriodCheckpointTests: XCTestCase {

    // MARK: - Fixtures

    private func euro(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .eur)! }
    private func day(_ iso: String) -> Day { Day(isoString: iso)! }

    private let august = MonthKey(year: 2026, month: 8)
    private let september = MonthKey(year: 2026, month: 9)
    private var augustInterval: ReviewInterval { .month(august) }

    private var bank: Account {
        Account(
            id: "bank", name: "Bank", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 0
        )
    }

    private func binding(isActive: Bool = true) -> ExternalAccountBinding {
        ExternalAccountBinding(
            id: "binding-1", provider: .bnp, remoteOpaqueAccountID: "remote-1",
            localAccountID: "bank", syncStartBoundary: day("2026-01-01"),
            isActive: isActive, createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func document(
        transactions: [Transaction] = [],
        observations: [ExternalObservation] = [],
        resolutions: [ExternalObservationResolution] = [],
        links: [ExternalEvidenceLink] = [],
        bindingIsActive: Bool = true
    ) -> FinanceDocument {
        FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [bank],
            balances: [AccountBalance(accountID: "bank", balance: euro("800.00"), asOf: day("2026-08-01"))],
            transactions: transactions,
            planning: FinanceDocument.Planning(defaultScenario: .base),
            externalAccountBindings: [binding(isActive: bindingIsActive)],
            externalObservations: observations,
            externalEvidenceLinks: links,
            observationResolutions: resolutions
        )
    }

    private func expense(_ id: String, _ amount: String, on iso: String) -> Transaction {
        Transaction(
            id: id, date: day(iso), kind: .expense,
            legs: [AccountLeg(accountID: "bank", amount: euro("-\(amount)"))],
            factivity: .observed
        )
    }

    private func coverage(
        _ status: ReviewCoverageStatus,
        reasons: [ReviewCoverageReason] = [],
        missing: [ReviewInterval] = []
    ) -> ReviewCoverage {
        ReviewCoverage(
            status: status, reasons: reasons, missingIntervals: missing,
            archiveCutoff: nil, usedArchive: false, usedLive: true
        )
    }

    /// A minimal successful review of `interval`. The checkpoint evaluator only
    /// reads `kind`, `interval` and `coverage`, so the rest is inert filler.
    private func review(
        _ interval: ReviewInterval,
        kind: ReviewPeriodKind = .monthly,
        coverage: ReviewCoverage? = nil,
        uncategorized: Money? = nil
    ) -> ReviewResult {
        let zero = euro("0.00")
        return ReviewResult(
            kind: kind,
            interval: interval,
            asOf: interval.end,
            currency: .eur,
            coverage: coverage ?? self.coverage(.complete),
            totals: ReviewTotals(
                currency: .eur, economicSpending: zero, refunds: zero,
                netEconomicSpending: zero, personalIncome: zero,
                passThroughNotMine: zero, financingRepayments: zero,
                internalTransfers: zero
            ),
            budget: ReviewBudget(
                periodEconomicSpending: zero, attributions: [], monthlyContexts: [],
                uncategorized: uncategorized ?? zero, financingRepayments: zero,
                drivers: [], ordinaryRecurring: zero, ordinaryVariable: zero,
                exceptional: zero, unresolvedNature: zero
            ),
            income: ReviewIncome(
                personalIncome: zero, parentalSupportGross: zero,
                parentalSupportOwned: zero, earnedOrOther: zero, reimbursements: zero,
                passThroughGross: zero, passThroughOwned: zero, passThroughNotMine: zero,
                internalMovement: zero, unresolved: zero
            ),
            expectations: ReviewExpectations(items: []),
            goals: ReviewGoals(
                currentlySetAside: zero, reservationHistoryKnown: false,
                reservationChange: nil, activePurchases: [], upcomingTargetDates: []
            ),
            risk: ReviewRisk(
                asOf: interval.end, asOfLedgerLiquidity: zero, outlookEnd: interval.end,
                upcomingObligations: [], firstHardCashRiskDate: nil,
                firstFloorWarningDate: nil, firstRisk: nil, minimumBridgeRequired: zero
            ),
            comparison: .unavailable(.notRequested),
            findings: []
        )
    }

    /// Acknowledgment authority for a test, obtained the only way production
    /// can obtain it: real confirmation against the carried values. Naming an
    /// id that no carried exception has is not a decision at all — the public
    /// API has no way to express one — so such ids are simply not offered.
    private func confirmed(
        _ ids: Set<String>, carrying exceptions: [PeriodCheckpointException]
    ) throws -> PeriodCheckpointConfirmedAcknowledgments {
        try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            decisions: exceptions.filter { ids.contains($0.id) },
            carriedExceptions: exceptions
        )
    }

    private func request(
        period: ReviewInterval? = nil,
        kind: ReviewPeriodKind = .monthly,
        asOf: String = "2026-09-01",
        review reviewResult: ReviewResult?? = nil,
        exceptions: [PeriodCheckpointException] = [],
        acknowledged: Set<String> = [],
        projection: SemanticPeriodProjection? = nil,
        requiresProjection: Bool = false,
        baseline: PeriodCheckpointBaselineComparison = .unavailable(.noBaselinePersistence)
    ) throws -> PeriodCheckpointRequest {
        let period = period ?? augustInterval
        return PeriodCheckpointRequest(
            period: period,
            kind: kind,
            asOf: day(asOf),
            review: reviewResult ?? review(period, kind: kind),
            exceptions: exceptions,
            confirmedAcknowledgments: try confirmed(acknowledged, carrying: exceptions),
            projection: projection,
            requiresSemanticProjection: requiresProjection,
            baselineComparison: baseline
        )
    }

    private func exception(
        _ id: String,
        _ kind: PeriodCheckpointExceptionKind,
        basis: AggregateEvidenceBasis? = nil
    ) -> PeriodCheckpointException {
        PeriodCheckpointException(id: id, kind: kind, aggregateBasis: basis)
    }

    // MARK: - Disposition

    func testCleanPeriodIsReadyClean() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(try request())
        XCTAssertEqual(readiness.disposition, .readyClean)
        XCTAssertEqual(readiness.quality, .clean)
        XCTAssertTrue(readiness.blockers.isEmpty)
        XCTAssertTrue(readiness.safeClaims.unquestionablyCompleteTotals)
        XCTAssertTrue(readiness.safeClaims.completeCategoryAttribution)
        XCTAssertTrue(readiness.safeClaims.completeEvidenceAudit)
        XCTAssertTrue(readiness.safeClaims.mayShowCalculatedTotals)
    }

    func testUnacknowledgedExceptionNeedsDecisions() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(
            try request(exceptions: [exception("e1", .uncategorizedEconomicSpending)])
        )
        XCTAssertEqual(readiness.disposition, .needsDecisions)
        XCTAssertEqual(readiness.quality, .withExceptions)
        XCTAssertEqual(readiness.undecidedExceptions.map(\.id), ["e1"])
        XCTAssertTrue(readiness.acknowledgedExceptions.isEmpty)
    }

    func testAcknowledgedExceptionIsReadyWithExceptions() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(
            try request(
                exceptions: [exception("e1", .uncategorizedEconomicSpending)],
                acknowledged: ["e1"]
            )
        )
        XCTAssertEqual(readiness.disposition, .readyWithAcknowledgedExceptions)
        XCTAssertEqual(readiness.quality, .withExceptions)
    }

    /// Acknowledgment is a decision about a limitation, not a repair of one.
    func testAcknowledgmentChangesNoUnderlyingFinancialFact() throws {
        let carried = [exception("e1", .unknownBookedEconomics)]
        let undecided = PeriodCheckpointEvaluator.evaluate(try request(exceptions: carried))
        let accepted = PeriodCheckpointEvaluator.evaluate(
            try request(exceptions: carried, acknowledged: ["e1"])
        )
        XCTAssertNotEqual(undecided.disposition, accepted.disposition)
        XCTAssertEqual(undecided.quality, accepted.quality)
        XCTAssertEqual(undecided.safeClaims, accepted.safeClaims)
        XCTAssertEqual(undecided.exceptions, accepted.exceptions)
    }

    /// An identifier naming no carried exception acknowledges nothing — and
    /// since the migration to typed authority it cannot even be stated: there
    /// is no public API that turns a bare identifier into a decision.
    func testUnknownAcknowledgmentAcknowledgesNothing() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(
            try request(
                exceptions: [exception("e1", .uncategorizedEconomicSpending)],
                acknowledged: ["not-an-exception"]
            )
        )
        XCTAssertEqual(readiness.disposition, .needsDecisions)
    }

    // MARK: - Blockers

    func testInvalidPeriodBlocks() throws {
        let backwards = ReviewInterval(start: day("2026-08-31"), end: day("2026-08-01"))
        let readiness = PeriodCheckpointEvaluator.evaluate(try request(period: backwards))
        XCTAssertEqual(readiness.disposition, .blocked)
        XCTAssertEqual(readiness.blockers.map(\.kind), [.invalidPeriod])
    }

    func testPeriodNotEndedBlocks() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(try request(asOf: "2026-08-20"))
        XCTAssertEqual(readiness.disposition, .blocked)
        XCTAssertTrue(readiness.blockers.contains { $0.kind == .periodNotEnded })
    }

    func testReviewUnavailableBlocks() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(try request(review: .some(nil)))
        XCTAssertEqual(readiness.disposition, .blocked)
        XCTAssertEqual(readiness.blockers.map(\.kind), [.reviewUnavailable])
    }

    func testReviewOfAnotherPeriodBlocks() throws {
        let july = ReviewInterval.month(MonthKey(year: 2026, month: 7))
        let readiness = PeriodCheckpointEvaluator.evaluate(try request(review: review(july)))
        XCTAssertEqual(readiness.disposition, .blocked)
        XCTAssertEqual(readiness.blockers.map(\.kind), [.reviewPeriodMismatch])
    }

    func testReviewOfAnotherKindBlocks() throws {
        let weekly = review(augustInterval, kind: .weekly)
        let readiness = PeriodCheckpointEvaluator.evaluate(try request(review: weekly))
        XCTAssertEqual(readiness.blockers.map(\.kind), [.reviewPeriodMismatch])
    }

    /// The five coverage reasons map one-to-one onto blockers, and the
    /// checkpoint invents no coverage rule of its own.
    func testEveryCoverageReasonBecomesItsOwnBlocker() throws {
        let expected: [ReviewCoverageReasonKind: PeriodCheckpointBlockerKind] = [
            .coverageMetadataAbsent: .coverageMetadataAbsent,
            .archiveHistoryAbsent: .archiveHistoryAbsent,
            .missingArchiveInterval: .missingArchiveInterval,
            .missingLiveInterval: .missingLiveInterval,
            .sourceGap: .sourceGap,
        ]
        for (reason, blocker) in expected {
            let incomplete = coverage(.insufficient, reasons: [ReviewCoverageReason(kind: reason)])
            let readiness = PeriodCheckpointEvaluator.evaluate(
                try request(review: review(augustInterval, coverage: incomplete))
            )
            XCTAssertEqual(readiness.disposition, .blocked, "\(reason)")
            XCTAssertEqual(readiness.blockers.map(\.kind), [blocker], "\(reason)")
        }
    }

    /// Incomplete coverage that enumerates no reason is still incomplete.
    func testIncompleteCoverageWithoutReasonsStillBlocks() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(
            try request(review: review(augustInterval, coverage: coverage(.partial)))
        )
        XCTAssertEqual(readiness.blockers.map(\.kind), [.coverageMetadataAbsent])
    }

    func testRequiredProjectionMissingBlocks() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(try request(requiresProjection: true))
        XCTAssertEqual(readiness.blockers.map(\.kind), [.semanticProjectionUnavailable])
    }

    func testProjectionNotRequiredDoesNotBlock() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(try request(requiresProjection: false))
        XCTAssertTrue(readiness.blockers.isEmpty)
    }

    /// Coverage incompleteness is a blocker, not an exception, and no
    /// acknowledgment of any kind reaches it.
    func testNoAcknowledgmentEverClearsABlocker() throws {
        let incomplete = coverage(
            .insufficient, reasons: [ReviewCoverageReason(kind: .missingLiveInterval)]
        )
        let readiness = PeriodCheckpointEvaluator.evaluate(
            try request(
                review: review(augustInterval, coverage: incomplete),
                exceptions: [exception("e1", .uncategorizedEconomicSpending)],
                acknowledged: ["e1", "missingLiveInterval", "coverage"]
            )
        )
        XCTAssertEqual(readiness.disposition, .blocked)
        XCTAssertEqual(readiness.safeClaims, .blocked)
        for kind in PeriodCheckpointBlockerKind.allCases {
            XCTAssertFalse(kind.isAcknowledgeable, "\(kind) must never be acknowledgeable")
        }
    }

    func testBlockedPeriodClaimsNothingAtAll() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(try request(asOf: "2026-08-02"))
        XCTAssertFalse(readiness.safeClaims.mayShowCalculatedTotals)
        XCTAssertFalse(readiness.safeClaims.unquestionablyCompleteTotals)
        XCTAssertFalse(readiness.safeClaims.completeCategoryAttribution)
        XCTAssertFalse(readiness.safeClaims.completeEvidenceAudit)
    }

    func testBlockersAreSortedAndDeduplicated() throws {
        let incomplete = coverage(.insufficient, reasons: [
            ReviewCoverageReason(kind: .sourceGap),
            ReviewCoverageReason(kind: .sourceGap),
            ReviewCoverageReason(kind: .missingLiveInterval),
        ])
        let readiness = PeriodCheckpointEvaluator.evaluate(
            try request(asOf: "2026-08-10", review: review(augustInterval, coverage: incomplete))
        )
        XCTAssertEqual(readiness.blockers.map(\.kind), [.periodNotEnded, .missingLiveInterval, .sourceGap])
    }

    // MARK: - Safe claims

    /// Unknown booked economics: figures may still be shown as calculated, but
    /// the month's totals may not be called complete.
    func testUnknownBookedEconomicsBlocksTotalsButNotDisplay() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(
            try request(exceptions: [exception("e1", .unknownBookedEconomics)], acknowledged: ["e1"])
        )
        XCTAssertTrue(readiness.safeClaims.mayShowCalculatedTotals)
        XCTAssertFalse(readiness.safeClaims.unquestionablyCompleteTotals)
    }

    /// Category-only uncertainty leaves economic spending complete.
    func testUncategorizedSpendingCostsOnlyCategoryCompleteness() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(
            try request(exceptions: [exception("e1", .uncategorizedEconomicSpending)], acknowledged: ["e1"])
        )
        XCTAssertTrue(readiness.safeClaims.unquestionablyCompleteTotals)
        XCTAssertFalse(readiness.safeClaims.completeCategoryAttribution)
        XCTAssertTrue(readiness.safeClaims.completeEvidenceAudit)
    }

    /// An audit-only limitation leaves economics and categories safe.
    func testUnresolvedLinkageCostsOnlyAuditCompleteness() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(
            try request(exceptions: [exception("e1", .unresolvedEvidenceLinkage)], acknowledged: ["e1"])
        )
        XCTAssertTrue(readiness.safeClaims.unquestionablyCompleteTotals)
        XCTAssertTrue(readiness.safeClaims.completeCategoryAttribution)
        XCTAssertFalse(readiness.safeClaims.completeEvidenceAudit)
    }

    func testIncomeClassificationCostsTotalsNotCategories() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(
            try request(
                exceptions: [exception("e1", .unresolvedIncomeClassificationOrOwnership)],
                acknowledged: ["e1"]
            )
        )
        XCTAssertFalse(readiness.safeClaims.unquestionablyCompleteTotals)
        XCTAssertTrue(readiness.safeClaims.completeCategoryAttribution)
        XCTAssertTrue(readiness.safeClaims.completeEvidenceAudit)
    }

    func testAcceptedReconciliationDifferenceCostsOnlyAudit() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(
            try request(
                exceptions: [exception("e1", .acceptedReconciliationAmountDifference)],
                acknowledged: ["e1"]
            )
        )
        XCTAssertTrue(readiness.safeClaims.unquestionablyCompleteTotals)
        XCTAssertTrue(readiness.safeClaims.completeCategoryAttribution)
        XCTAssertFalse(readiness.safeClaims.completeEvidenceAudit)
    }

    /// Every kind states an impact. A kind added without one would silently
    /// claim to cost nothing.
    func testEveryExceptionKindCostsSomething() throws {
        for kind in PeriodCheckpointExceptionKind.allCases {
            let basis: AggregateEvidenceBasis? =
                kind == .aggregateEvidenceModelLimitation ? .structuralCandidateOnly : nil
            let impact = PeriodCheckpointException(id: "e", kind: kind, aggregateBasis: basis).impact
            XCTAssertNotEqual(impact, .none, "\(kind) claims to cost nothing")
        }
    }

    /// Impacts combine by union: one exception cannot restore a claim another
    /// took away.
    func testImpactsCombineByUnion() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(
            try request(
                exceptions: [
                    exception("a", .uncategorizedEconomicSpending),
                    exception("b", .unresolvedEvidenceLinkage),
                    exception("c", .unresolvedIncomeClassificationOrOwnership),
                ],
                acknowledged: ["a", "b", "c"]
            )
        )
        XCTAssertFalse(readiness.safeClaims.unquestionablyCompleteTotals)
        XCTAssertFalse(readiness.safeClaims.completeCategoryAttribution)
        XCTAssertFalse(readiness.safeClaims.completeEvidenceAudit)
    }

    // MARK: - Refinement C — aggregate basis

    /// A structural pairing is not proof of identity, so totals stay
    /// questionable. This is the conservative branch, and the one the current
    /// typed data actually produces.
    func testStructuralAggregateCandidateCannotClaimCompleteTotals() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(
            try request(
                exceptions: [
                    exception("e1", .aggregateEvidenceModelLimitation, basis: .structuralCandidateOnly)
                ],
                acknowledged: ["e1"]
            )
        )
        XCTAssertEqual(readiness.quality, .withExceptions)
        XCTAssertEqual(readiness.disposition, .readyWithAcknowledgedExceptions)
        XCTAssertFalse(readiness.safeClaims.unquestionablyCompleteTotals)
        XCTAssertFalse(readiness.safeClaims.completeEvidenceAudit)
    }

    /// Only a source-established relationship licenses the stronger claim.
    func testSourceEstablishedAggregateKeepsTotalsButNotAudit() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(
            try request(
                exceptions: [
                    exception("e1", .aggregateEvidenceModelLimitation,
                              basis: .sourceEstablishedAggregateRelationship)
                ],
                acknowledged: ["e1"]
            )
        )
        XCTAssertTrue(readiness.safeClaims.unquestionablyCompleteTotals)
        XCTAssertFalse(readiness.safeClaims.completeEvidenceAudit)
    }

    func testAggregateBasisOnlyDescribesAggregateLimitation() throws {
        // A basis on any other kind is a construction error, and an aggregate
        // limitation without one is too. Both are preconditions; this pins the
        // pairing that is legal.
        let legal = PeriodCheckpointException(
            id: "e", kind: .aggregateEvidenceModelLimitation,
            aggregateBasis: .structuralCandidateOnly
        )
        XCTAssertEqual(legal.aggregateBasis, .structuralCandidateOnly)
        XCTAssertNil(exception("e", .unknownBookedEconomics).aggregateBasis)
    }

    // MARK: - Baseline is its own axis

    func testBaselineIsUnavailableAndDoesNotAffectDisposition() throws {
        let readiness = PeriodCheckpointEvaluator.evaluate(try request())
        XCTAssertEqual(readiness.baselineComparison, .unavailable(.noBaselinePersistence))
        XCTAssertFalse(readiness.baselineComparison.isEstablished)
        XCTAssertEqual(readiness.disposition, .readyClean)
    }

    func testBaselineComparisonDoesNotChangeSafeClaims() throws {
        let withoutBaseline = PeriodCheckpointEvaluator.evaluate(try request())
        let withBaseline = PeriodCheckpointEvaluator.evaluate(
            try request(baseline: .unchangedSinceClose(previousQuality: .clean))
        )
        XCTAssertEqual(withoutBaseline.safeClaims, withBaseline.safeClaims)
        XCTAssertEqual(withoutBaseline.disposition, withBaseline.disposition)
    }

    // MARK: - Determinism

    func testSameInputProducesIdenticalOutputIncludingOrder() throws {
        let exceptions = [
            exception("z", .unknownBookedEconomics),
            exception("a", .uncategorizedEconomicSpending),
            exception("m", .unresolvedEvidenceLinkage),
        ]
        let first = PeriodCheckpointEvaluator.evaluate(try request(exceptions: exceptions))
        let second = PeriodCheckpointEvaluator.evaluate(try request(exceptions: exceptions.reversed()))
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first.exceptions.map(\.id),
            ["a", "z", "m"],
            "sorted by kind then id"
        )
    }

    // MARK: - Semantic projection

    private func projection(
        _ document: FinanceDocument,
        interval: ReviewInterval? = nil,
        coverage status: ReviewCoverage? = nil,
        categoryKeys: [String: String] = [:],
        aggregateFacts: [String: SemanticAggregateFact] = [:],
        expectations: [ExpectedOccurrence] = []
    ) throws -> SemanticPeriodProjection {
        SemanticPeriodProjectionBuilder.projection(
            for: interval ?? augustInterval,
            kind: .monthly,
            in: document,
            coverage: status ?? coverage(.complete),
            budget: SemanticBudgetFact(try ReviewEngine.review(ReviewRequest(
                document: document, kind: .monthly, interval: interval ?? augustInterval,
                asOf: (interval ?? augustInterval).end, categoryKeys: categoryKeys,
                coverage: ReviewCoverageInput(liveCoveredIntervals: [interval ?? augustInterval])
            )).budget),
            categoryKeys: categoryKeys,
            aggregateFacts: aggregateFacts,
            expectations: expectations
        )
    }

    /// Complete coverage normalizes to one fact, so a later, wider complete
    /// reading of the same period is semantically equal to a narrower one.
    func testWiderCompleteCoverageIsSemanticallyEqual() throws {
        let document = self.document(transactions: [expense("t1", "10.00", on: "2026-08-05")])
        let narrow = coverage(.complete)
        let wide = ReviewCoverage(
            status: .complete, reasons: [], missingIntervals: [],
            archiveCutoff: day("2026-01-31"), usedArchive: true, usedLive: true
        )
        XCTAssertEqual(
            try projection(document, coverage: narrow),
            try projection(document, coverage: wide)
        )
    }

    func testCoverageBecomingIncompleteIsInequality() throws {
        let document = self.document(transactions: [expense("t1", "10.00", on: "2026-08-05")])
        let incomplete = coverage(
            .partial,
            reasons: [ReviewCoverageReason(kind: .missingLiveInterval)],
            missing: [ReviewInterval(start: day("2026-08-20"), end: day("2026-08-21"))]
        )
        XCTAssertNotEqual(
            try projection(document),
            try projection(document, coverage: incomplete)
        )
    }

    func testNewPeriodEvidenceIsInequality() throws {
        let before = document(transactions: [expense("t1", "10.00", on: "2026-08-05")])
        let after = document(transactions: [
            expense("t1", "10.00", on: "2026-08-05"),
            expense("t2", "5.00", on: "2026-08-06"),
        ])
        XCTAssertNotEqual(try projection(before), try projection(after))
    }

    func testEvidenceOutsideThePeriodDoesNotChangeIt() throws {
        let inside = document(transactions: [expense("t1", "10.00", on: "2026-08-05")])
        let alsoSeptember = document(transactions: [
            expense("t1", "10.00", on: "2026-08-05"),
            expense("t2", "5.00", on: "2026-09-06"),
        ])
        XCTAssertEqual(try projection(inside), try projection(alsoSeptember))
    }

    func testResolutionChangeIsInequality() throws {
        let observation = self.observation("o1", "-16.44", on: "2026-08-07")
        let unreviewed = document(
            observations: [observation],
            resolutions: [ExternalObservationResolution(observationID: "o1", state: .unreviewed)]
        )
        let resolved = document(
            observations: [observation],
            resolutions: [ExternalObservationResolution(observationID: "o1", state: .noEconomicEffect)]
        )
        XCTAssertNotEqual(try projection(unreviewed), try projection(resolved))
    }

    func testClassificationChangeIsInequality() throws {
        let asExpense = document(transactions: [expense("t1", "10.00", on: "2026-08-05")])
        let asTransfer = document(transactions: [
            Transaction(
                id: "t1", date: day("2026-08-05"), kind: .transfer,
                legs: [AccountLeg(accountID: "bank", amount: euro("-10.00"))],
                factivity: .observed
            )
        ])
        XCTAssertNotEqual(try projection(asExpense), try projection(asTransfer))
    }

    /// Operational clocks are not semantics. A re-sync of the identical row
    /// moves `observedAt` and nothing else, and must project identically.
    func testObservationClocksAreExcludedFromMeaning() throws {
        let early = observation("o1", "-16.44", on: "2026-08-07",
                                observedAt: Date(timeIntervalSince1970: 1_000))
        let late = observation("o1", "-16.44", on: "2026-08-07",
                               observedAt: Date(timeIntervalSince1970: 9_000_000))
        let resolutions = [
            ExternalObservationResolution(
                observationID: "o1", state: .unreviewed,
                resolvedAt: Date(timeIntervalSince1970: 5_000)
            )
        ]
        let otherResolutions = [
            ExternalObservationResolution(
                observationID: "o1", state: .unreviewed,
                resolvedAt: Date(timeIntervalSince1970: 8_000_000)
            )
        ]
        XCTAssertEqual(
            try projection(document(observations: [early], resolutions: resolutions)),
            try projection(document(observations: [late], resolutions: otherResolutions))
        )
    }

    func testEvidenceLinkChangeIsInequality() throws {
        let observation = self.observation("o1", "-16.44", on: "2026-08-07")
        let resolutions = [ExternalObservationResolution(observationID: "o1", state: .linkedToTransaction)]
        let unlinked = document(observations: [observation], resolutions: resolutions)
        let linked = document(
            transactions: [expense("t1", "16.44", on: "2026-08-07")],
            observations: [observation],
            resolutions: resolutions,
            links: [ExternalEvidenceLink(
                id: "l1", observationID: "o1", transactionID: "t1", role: .accountMovement
            )]
        )
        XCTAssertNotEqual(try projection(unlinked), try projection(linked))
    }

    /// An observation with no explicit resolution row projects as unreviewed.
    /// Absence is never "reviewed".
    func testMissingResolutionProjectsAsUnreviewed() throws {
        let built = try projection(document(observations: [observation("o1", "-16.44", on: "2026-08-07")]))
        XCTAssertEqual(built.observations.map(\.resolution), [.unreviewed])
    }

    func testProjectionOrderingIsIndependentOfDocumentOrder() throws {
        let forward = document(transactions: [
            expense("a", "1.00", on: "2026-08-05"),
            expense("b", "2.00", on: "2026-08-06"),
            expense("c", "3.00", on: "2026-08-07"),
        ])
        let shuffled = document(transactions: [
            expense("c", "3.00", on: "2026-08-07"),
            expense("a", "1.00", on: "2026-08-05"),
            expense("b", "2.00", on: "2026-08-06"),
        ])
        XCTAssertEqual(try projection(forward), try projection(shuffled))
        XCTAssertEqual(try projection(shuffled).transactions.map(\.id), ["a", "b", "c"])
    }

    func testProjectionCarriesSemanticMonthFacts() throws {
        let built = try projection(document(transactions: [expense("t1", "10.00", on: "2026-08-05")]))
        XCTAssertEqual(built.period.start, day("2026-08-01"))
        XCTAssertEqual(built.period.end, day("2026-08-31"))
        XCTAssertEqual(built.kind, .monthly)
        XCTAssertEqual(built.coverage, .complete)
        XCTAssertEqual(built.transactions.first?.kind, .expense)
        XCTAssertEqual(built.transactions.first?.legs.first?.minorUnits, -1_000)
    }

    // MARK: - Prerequisite matrix: one period rule

    /// The rule has one implementation. `suggestedEconomicDate` is the older
    /// name for the same day, and every consumer resolves to this expression.
    func testEconomicPeriodDayIsTheOnlyRuleAndSuggestedDateDelegatesToIt() throws {
        let shapes = [
            evidence("bnp-card", booking: "2026-09-01", derived: "2026-08-31"),
            evidence("bnp-plain", booking: "2026-08-15"),
            evidence("paypal", transaction: "2026-08-15"),
            evidence("revolut", booking: "2026-08-15", value: "2026-08-16"),
            evidence("value-only", value: "2026-08-15"),
            evidence("dateless")
        ]
        for observation in shapes {
            XCTAssertEqual(
                observation.economicPeriodDay,
                observation.suggestedEconomicDate,
                "\(observation.id): the two names must be one rule"
            )
        }
        XCTAssertEqual(shapes[0].economicPeriodDay, day("2026-08-31"), "derived capture outranks booking")
        XCTAssertEqual(shapes[1].economicPeriodDay, day("2026-08-15"), "falls back to booking")
        XCTAssertEqual(shapes[2].economicPeriodDay, day("2026-08-15"), "provider transaction date wins")
        XCTAssertEqual(shapes[3].economicPeriodDay, day("2026-08-15"), "booking outranks value")
        XCTAssertEqual(shapes[4].economicPeriodDay, day("2026-08-15"), "falls back to value")
        XCTAssertNil(shapes[5].economicPeriodDay, "no provider date is no answer")
    }

    /// 1 — a BNP card purchase captured on 31 August and booked on 1 September
    /// is August's spending, in the projection and in the review alike.
    func testDerivedCaptureDayDecidesTheMonthNotBooking() throws {
        let observation = evidence("o1", booking: "2026-09-01", derived: "2026-08-31")
        let document = self.document(
            observations: [observation], resolutions: [resolution("o1", .unreviewed)]
        )
        XCTAssertEqual(try projection(document).observations.map(\.id), ["o1"])
        XCTAssertEqual(try projection(document, interval: .month(september)).observations, [])
        XCTAssertEqual(try projection(document).observations.first?.economicDay, day("2026-08-31"))
    }

    /// 2 — the same disagreement across a Monday week boundary.
    func testDerivedCaptureDayDecidesTheWeekNotBooking() throws {
        let observation = evidence("o1", booking: "2026-08-31", derived: "2026-08-29")
        let document = self.document(
            observations: [observation], resolutions: [resolution("o1", .unreviewed)]
        )
        let weekEndingSunday = ReviewInterval.weekStarting(day("2026-08-24"))
        let weekContainingBooking = ReviewInterval.weekStarting(day("2026-08-31"))
        XCTAssertEqual(try projection(document, interval: weekEndingSunday).observations.map(\.id), ["o1"])
        XCTAssertEqual(try projection(document, interval: weekContainingBooking).observations, [])
    }

    /// 3 and 4 — booking-only and value-only rows still land in their period.
    /// The old recorded blocker claimed these fell out of the projection.
    func testBookingOnlyAndValueOnlyRowsStillEnterTheirPeriod() throws {
        for observation in [evidence("booking", booking: "2026-08-15"),
                            evidence("value", value: "2026-08-15")] {
            let document = self.document(
                observations: [observation],
                resolutions: [resolution(observation.id, .unreviewed)]
            )
            XCTAssertEqual(
                try projection(document).observations.map(\.id), [observation.id],
                "\(observation.id) must be in August"
            )
        }
    }

    /// 5 — no provider date at all means no period, symmetrically.
    func testObservationWithNoProviderDateIsInNoPeriod() throws {
        let document = self.document(
            observations: [evidence("dateless")], resolutions: [resolution("dateless", .unreviewed)]
        )
        XCTAssertEqual(try projection(document).observations, [])
        XCTAssertEqual(try projection(document, interval: .month(september)).observations, [])
    }

    /// 6 — membership agrees with the rule over every combination of the four
    /// provider dates, rather than over one hand-picked shape.
    func testProjectionMembershipAgreesWithTheRuleOverEveryDateCombination() throws {
        let candidates: [String?] = [nil, "2026-07-31", "2026-08-15", "2026-09-01"]
        var checked = 0
        for booking in candidates {
            for transaction in candidates {
                for value in candidates {
                    for derived in candidates {
                        let observation = evidence(
                            "o1", booking: booking, transaction: transaction,
                            value: value, derived: derived
                        )
                        let document = self.document(
                            observations: [observation],
                            resolutions: [resolution("o1", .unreviewed)]
                        )
                        let expected = observation.economicPeriodDay.map(augustInterval.contains) ?? false
                        XCTAssertEqual(
                            try projection(document).observations.isEmpty, !expected,
                            "b=\(booking ?? "-") t=\(transaction ?? "-") v=\(value ?? "-") d=\(derived ?? "-")"
                        )
                        checked += 1
                    }
                }
            }
        }
        XCTAssertEqual(checked, 256, "every combination of the four provider dates")
    }

    // MARK: - Prerequisite matrix: transport-only rows

    /// 7 — a pending snapshot row carries no meaning and no period.
    func testTransportOnlyProvisionalSnapshotContributesNothing() throws {
        let document = self.document(
            observations: [evidence("pend_run1_acct_0", booking: "2026-08-30",
                                    status: .pending, identity: .provisionalSnapshot,
                                    providerEligible: false)],
            resolutions: [resolution("pend_run1_acct_0", .provisional)]
        )
        XCTAssertEqual(try projection(document).observations, [])
    }

    /// 8 — the invariant this whole change exists for. Successive syncs mint
    /// fresh run-scoped pending ids and never remove the old ones; none of
    /// that is a change in what August means.
    func testAccumulatingPendingSnapshotsAcrossSyncsDoNotChangeTheProjection() throws {
        func afterSyncs(_ count: Int) -> FinanceDocument {
            var observations = [evidence("booked-1", booking: "2026-08-20")]
            var resolutions = [resolution("booked-1", .unreviewed)]
            for run in 1...count {
                observations.append(
                    evidence("pend_run\(run)_acct_0", "-25.00", booking: "2026-08-30",
                             status: .pending, identity: .provisionalSnapshot,
                             providerEligible: false,
                             observedAt: Date(timeIntervalSince1970: Double(1_000 * run)))
                )
                resolutions.append(resolution("pend_run\(run)_acct_0", .provisional))
            }
            return document(observations: observations, resolutions: resolutions)
        }
        let one = try projection(afterSyncs(1))
        XCTAssertEqual(one, try projection(afterSyncs(2)))
        XCTAssertEqual(one, try projection(afterSyncs(3)))
        XCTAssertEqual(one.observations.map(\.id), ["booked-1"])
    }

    /// 9 — the booked row that eventually represents that money is new meaning.
    func testPendingRowBecomingABookedDurableRowIsInequality() throws {
        let pendingOnly = document(
            observations: [evidence("pend_run1_acct_0", "-25.00", booking: "2026-08-30",
                                    status: .pending, identity: .provisionalSnapshot,
                                    providerEligible: false)],
            resolutions: [resolution("pend_run1_acct_0", .provisional)]
        )
        let nowBooked = document(
            observations: [
                evidence("pend_run1_acct_0", "-25.00", booking: "2026-08-30",
                         status: .pending, identity: .provisionalSnapshot, providerEligible: false),
                evidence("obs-9", "-25.00", booking: "2026-08-31", derived: "2026-08-30")
            ],
            resolutions: [resolution("pend_run1_acct_0", .provisional),
                          resolution("obs-9", .unreviewed)]
        )
        XCTAssertNotEqual(try projection(pendingOnly), try projection(nowBooked))
        XCTAssertEqual(try projection(nowBooked).observations.map(\.id), ["obs-9"])
    }

    /// 14 — rows before the binding's own start are outside the evidence
    /// surface and stay outside the period's meaning.
    func testOutsideSyncBoundaryRowsAreAbsentFromTheProjection() throws {
        let document = self.document(
            observations: [evidence("old-1", booking: "2026-08-05")],
            resolutions: [resolution("old-1", .outsideSyncBoundary)]
        )
        XCTAssertEqual(try projection(document).observations, [])
    }

    // MARK: - Prerequisite matrix: provider and audit state

    private func linkedDocument(
        status: ExternalObservationStatus = .booked,
        identity: ExternalObservationIdentity = .durable,
        providerEligible: Bool = true,
        bindingIsActive: Bool = true,
        merchant: String? = nil
    ) -> FinanceDocument {
        document(
            transactions: [expense("t1", "30.00", on: "2026-08-10")],
            observations: [evidence("o1", "-30.00", booking: "2026-08-10", status: status,
                                    identity: identity, providerEligible: providerEligible,
                                    merchant: merchant)],
            resolutions: [resolution("o1", .linkedToTransaction,
                                     resolvedAt: Date(timeIntervalSince1970: 500))],
            links: [ExternalEvidenceLink(id: "l1", observationID: "o1",
                                         transactionID: "t1", role: .accountMovement)],
            bindingIsActive: bindingIsActive
        )
    }

    /// 10 — the provider withdraws eligibility on a still-booked, still-durable
    /// row a person already resolved. No euro moves; a `providerStatusConflict`
    /// appears and the period can no longer claim complete totals or audit.
    func testProviderWithdrawingEligibilityIsInequality() throws {
        let before = linkedDocument(providerEligible: true)
        let after = linkedDocument(providerEligible: false)
        XCTAssertEqual(ExternalEvidenceReview.providerStatusWarnings(in: before), [])
        XCTAssertEqual(ExternalEvidenceReview.providerStatusWarnings(in: after), ["o1"])
        XCTAssertNotEqual(try projection(before), try projection(after))
    }

    /// 11 — an identity downgrade on a row a person already resolved. It stays
    /// in the projection precisely because it is not transport-only.
    func testIdentityDowngradeOnAResolvedRowIsInequalityAndStaysRepresented() throws {
        let before = linkedDocument(identity: .durable)
        let after = linkedDocument(identity: .provisionalSnapshot)
        XCTAssertEqual(ExternalEvidenceReview.providerStatusWarnings(in: after), ["o1"])
        XCTAssertNotEqual(try projection(before), try projection(after))
        XCTAssertEqual(
            try projection(after).observations.map(\.id), ["o1"],
            "a resolved row whose provider identity regressed is not transport noise"
        )
    }

    /// 12 — a booked row a person resolved falls back to pending.
    func testBookedToPendingOnAResolvedRowIsInequalityAndRaisesTheConflict() throws {
        let before = linkedDocument(status: .booked)
        let after = linkedDocument(status: .pending)
        XCTAssertEqual(ExternalEvidenceReview.providerStatusWarnings(in: after), ["o1"])
        XCTAssertNotEqual(try projection(before), try projection(after))
        XCTAssertEqual(try projection(after).observations.map(\.id), ["o1"])
    }

    /// 13 — binding activity decides whether the exception is raised at all,
    /// so it is part of what the period may claim.
    func testBindingDeactivationIsInequality() throws {
        XCTAssertNotEqual(
            try projection(linkedDocument(providerEligible: false, bindingIsActive: true)),
            try projection(linkedDocument(providerEligible: false, bindingIsActive: false))
        )
    }

    /// The closure this file exists to guarantee: a provider conflict on a row
    /// whose identity has gone provisional must never be an exception-bearing
    /// state that the projection cannot see.
    func testProviderConflictOnAProvisionalIdentityIsVisibleInTheProjection() throws {
        let healthy = linkedDocument(identity: .durable, providerEligible: true)
        let conflicted = linkedDocument(identity: .provisionalSnapshot, providerEligible: true)

        XCTAssertTrue(ExternalEvidenceReview.providerStatusWarnings(in: healthy).isEmpty)
        XCTAssertEqual(ExternalEvidenceReview.providerStatusWarnings(in: conflicted), ["o1"])

        let quiet = try projection(healthy)
        let loud = try projection(conflicted)
        XCTAssertNotEqual(quiet, loud, "an exception appeared; the projection must say so")

        // And the fact carries the reason, not just a difference.
        XCTAssertEqual(loud.observations.first?.identity, .provisionalSnapshot)
        XCTAssertEqual(quiet.observations.first?.identity, .durable)

        // The safe claims the conflict costs, stated from the same evidence.
        let carried = PeriodCheckpointSafeClaims.surviving(
            [PeriodCheckpointException(id: "o1", kind: .providerStatusConflict)]
        )
        XCTAssertFalse(carried.unquestionablyCompleteTotals)
        XCTAssertFalse(carried.completeEvidenceAudit)
    }

    // MARK: - Prerequisite matrix: economic meaning

    /// 15 — recategorising a budget line changes what the period may claim
    /// about category completeness, so it changes the projection.
    func testBudgetRecategorisationIsInequality() throws {
        let document = self.document(transactions: [expense("t1", "10.00", on: "2026-08-05")])
        let groceries = try projection(document, categoryKeys: ["t1": "groceries"])
        let restaurants = try projection(document, categoryKeys: ["t1": "restaurants"])
        XCTAssertNotEqual(groceries, restaurants)
        XCTAssertEqual(groceries.transactions.first?.categoryKey, "groceries")
        XCTAssertNotEqual(
            try projection(document, categoryKeys: [:]), groceries,
            "an uncategorised period and a categorised one are different facts"
        )
    }

    /// 19 — a genuine re-dating moves the euro, so both months change.
    func testEconomicDayChangeIsInequalityInBothPeriods() throws {
        let august = document(
            observations: [evidence("o1", booking: "2026-08-31")],
            resolutions: [resolution("o1", .unreviewed)]
        )
        let september = document(
            observations: [evidence("o1", booking: "2026-09-01",
                                    observedAt: Date(timeIntervalSince1970: 5_000))],
            resolutions: [resolution("o1", .unreviewed)]
        )
        XCTAssertNotEqual(try projection(august), try projection(september))
        XCTAssertNotEqual(
            try projection(august, interval: .month(self.september)),
            try projection(september, interval: .month(self.september))
        )
    }

    /// 20 — the aggregate window reaches into the next month, so the pairing
    /// has to be on the record. Reversing one paired transaction dissolves the
    /// limitation; August must not project identically through that.
    func testAggregateRelationshipChangingOutsideThePeriodIsInequality() throws {
        let document = self.document(
            transactions: [expense("t-sep-1", "100.00", on: "2026-09-02"),
                           expense("t-sep-2", "62.44", on: "2026-09-03")],
            observations: [evidence("o1", "-162.44", booking: "2026-08-31")],
            resolutions: [resolution("o1", .unreviewed)]
        )
        let paired = try projection(
            document,
            aggregateFacts: ["o1": SemanticAggregateFact(
                basis: .structuralCandidateOnly,
                pairedTransactionIDs: ["t-sep-2", "t-sep-1"]
            )]
        )
        let dissolved = try projection(document, aggregateFacts: [:])
        XCTAssertNotEqual(paired, dissolved)
        XCTAssertEqual(
            paired.observations.first?.aggregate?.pairedTransactionIDs,
            ["t-sep-1", "t-sep-2"],
            "sorted, so discovery order cannot leak in"
        )
        XCTAssertNil(dissolved.observations.first?.aggregate)
    }

    /// A different pairing of the same size is still a different relationship.
    func testDifferentAggregatePairingIsInequality() throws {
        let document = self.document(
            transactions: [expense("t-a", "100.00", on: "2026-09-02"),
                           expense("t-b", "62.44", on: "2026-09-03")],
            observations: [evidence("o1", "-162.44", booking: "2026-08-31")],
            resolutions: [resolution("o1", .unreviewed)]
        )
        func withPair(_ ids: [String]) throws -> SemanticPeriodProjection {
            try projection(document, aggregateFacts: ["o1": SemanticAggregateFact(
                basis: .structuralCandidateOnly, pairedTransactionIDs: ids
            )])
        }
        XCTAssertNotEqual(try withPair(["t-a", "t-b"]), try withPair(["t-a", "t-c"]))
        XCTAssertEqual(try withPair(["t-a", "t-b"]), try withPair(["t-b", "t-a"]), "order is not meaning")
    }

    // MARK: - Prerequisite matrix: operational noise

    /// 21 — the clocks move on every sync and mean nothing.
    func testOperationalClocksAloneAreEquality() throws {
        func atClock(_ seconds: Double) -> FinanceDocument {
            document(
                transactions: [expense("t1", "30.00", on: "2026-08-10")],
                observations: [evidence("o1", "-30.00", booking: "2026-08-10",
                                        observedAt: Date(timeIntervalSince1970: seconds))],
                resolutions: [resolution("o1", .linkedToTransaction,
                                         resolvedAt: Date(timeIntervalSince1970: seconds))],
                links: [ExternalEvidenceLink(id: "l1", observationID: "o1",
                                             transactionID: "t1", role: .accountMovement)]
            )
        }
        XCTAssertEqual(try projection(atClock(1_000)), try projection(atClock(9_000_000)))
        XCTAssertEqual(try CanonicalSemanticPeriodProjection(try projection(atClock(1_000))),
                       try CanonicalSemanticPeriodProjection(try projection(atClock(9_000_000))))
    }

    /// 23 — merchant enrichment is presentation, not economics.
    func testMerchantEnrichmentAloneIsEquality() throws {
        XCTAssertEqual(try CanonicalSemanticPeriodProjection(try projection(linkedDocument(merchant: nil))),
                       try CanonicalSemanticPeriodProjection(try projection(linkedDocument(merchant: "A Merchant Name"))))
        XCTAssertEqual(
            try projection(linkedDocument(merchant: nil)),
            try projection(linkedDocument(merchant: "A Merchant Name"))
        )
    }

    // MARK: - Prerequisite matrix: factivity

    /// 28 — `document.transactions` is the observed-economics list and
    /// `ReviewEngine` counts it that way. An expected transaction is not a
    /// period fact and must not move a checkpoint.
    func testExpectedTransactionsAreNotCheckpointEconomics() throws {
        let observed = expense("t-observed", "10.00", on: "2026-08-05")
        let expected = Transaction(
            id: "t-expected", date: day("2026-08-06"), kind: .expense,
            legs: [AccountLeg(accountID: "bank", amount: euro("-20.00"))],
            factivity: .expected
        )
        let withoutPlan = document(transactions: [observed])
        let withPlan = document(transactions: [observed, expected])
        XCTAssertEqual(try projection(withoutPlan), try projection(withPlan))
        XCTAssertEqual(try projection(withPlan).transactions.map(\.id), ["t-observed"])
    }

    // MARK: - Prerequisite matrix: blocked periods

    /// 27 — an archive cutoff inside the period leaves coverage partial, and a
    /// period whose days are not all covered cannot be closed. No fingerprint
    /// semantics are claimed for it.
    func testArchiveCutoffInsideThePeriodBlocksTheCheckpoint() throws {
        let document = self.document(transactions: [expense("t1", "10.00", on: "2026-08-25")])
        let result = try ReviewEngine.review(
            ReviewRequest(
                document: document, kind: .monthly, interval: augustInterval,
                asOf: day("2026-08-31"),
                coverage: ReviewCoverageInput(
                    archiveCutoff: day("2026-08-10"),
                    liveCoveredIntervals: [augustInterval]
                )
            )
        )
        XCTAssertNotEqual(result.coverage.status, .complete)
        let readiness = PeriodCheckpointEvaluator.evaluate(
            try request(asOf: "2026-09-01", review: result)
        )
        XCTAssertEqual(readiness.disposition, .blocked)
        XCTAssertEqual(readiness.safeClaims, .blocked)
        XCTAssertFalse(readiness.blockers.isEmpty)
    }

    private func observation(
        _ id: String,
        _ amount: String,
        on iso: String,
        status: ExternalObservationStatus = .booked,
        observedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> ExternalObservation {
        ExternalObservation(
            id: id, bindingID: "binding-1", provider: .bnp, status: status,
            creditDebitIndicator: .debit, amount: euro(amount),
            bookingDate: day(iso), transactionDate: day(iso),
            eligibleForEconomicActual: true, observedAt: observedAt
        )
    }

    /// Full control over the four provider dates and the provider-side state,
    /// so a fixture can state a real BNP/PayPal/Revolut shape rather than an
    /// idealised one where every date agrees.
    private func evidence(
        _ id: String,
        _ amount: String = "-16.44",
        booking: String? = nil,
        transaction: String? = nil,
        value: String? = nil,
        derived: String? = nil,
        status: ExternalObservationStatus = .booked,
        identity: ExternalObservationIdentity = .durable,
        providerEligible: Bool = true,
        merchant: String? = nil,
        observedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> ExternalObservation {
        ExternalObservation(
            id: id, bindingID: "binding-1", provider: .bnp, identity: identity,
            status: status, creditDebitIndicator: .debit, amount: euro(amount),
            bookingDate: booking.map(day), transactionDate: transaction.map(day),
            valueDate: value.map(day), derivedTransactionDate: derived.map(day),
            derivedDateProvenance: derived == nil ? nil : .parsedFromProviderRemittance,
            structuredMerchantName: merchant,
            eligibleForEconomicActual: providerEligible, observedAt: observedAt
        )
    }

    private func resolution(
        _ id: String,
        _ state: ObservationResolutionState,
        resolvedAt: Date? = nil
    ) -> ExternalObservationResolution {
        ExternalObservationResolution(observationID: id, state: state, resolvedAt: resolvedAt)
    }
}
