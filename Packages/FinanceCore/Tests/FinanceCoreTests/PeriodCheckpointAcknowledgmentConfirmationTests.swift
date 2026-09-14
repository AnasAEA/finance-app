import XCTest
import Foundation
@testable import FinanceCore

/// Phase 2.9C-E2 — candidate versus confirmed acknowledgment. Synthetic
/// fixtures only. E1's own suite is untouched; this file covers the boundary
/// E1 documented in prose and left to the type system to enforce.
final class PeriodCheckpointAcknowledgmentConfirmationTests: XCTestCase {

    private let period = SemanticInterval(start: Day(index: 10), end: Day(index: 40))
    private let revisionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func money(_ units: Int64, _ code: String = "EUR", _ digits: Int = 2) -> Money {
        Money(minorUnits: units, currency: Currency(code: code, minorUnitDigits: digits))
    }

    private func observation(
        id: String,
        minorUnits: Int64 = -4200,
        day: Day? = Day(index: 15)
    ) -> SemanticObservationFact {
        SemanticObservationFact(
            id: id, statusToken: "BOOKED", identity: .durable,
            providerEligibleForEconomicActual: true, bindingIsActive: true,
            resolution: .unreviewed, minorUnits: minorUnits, currencyCode: "EUR",
            economicDay: day, links: [], aggregate: nil
        )
    }

    private func periodProjection(
        observations: [SemanticObservationFact] = []
    ) -> SemanticPeriodProjection {
        SemanticPeriodProjection(
            period: period, kind: .monthly, coverage: .complete,
            budget: SemanticBudgetFact(
                periodEconomicSpending: money(0), uncategorized: money(0), attributions: []
            ),
            transactions: [], observations: observations, expectations: []
        )
    }

    private func exception(
        _ id: String,
        _ kind: PeriodCheckpointExceptionKind = .unknownBookedEconomics,
        basis: AggregateEvidenceBasis? = nil,
        day: Day? = nil,
        amount: Money? = nil
    ) -> PeriodCheckpointException {
        PeriodCheckpointException(id: id, kind: kind, aggregateBasis: basis, day: day, amount: amount)
    }

    private func canonical(_ projection: SemanticPeriodProjection) throws -> CanonicalSemanticPeriodProjection {
        try CanonicalSemanticPeriodProjection(projection)
    }

    private func revision(
        _ projection: SemanticPeriodProjection,
        acknowledgments: [PeriodCheckpointException]
    ) throws -> PeriodCheckpointRevision {
        let payload = try canonical(projection)
        return try PeriodCheckpointRevision(
            rehydratingStoredSnapshot: revisionID,
            period: payload.projection.period, periodKind: payload.projection.kind,
            revisionNumber: 1, predecessorID: nil,
            closedAt: Date(timeIntervalSince1970: 0),
            canonicalProjection: payload,
            acknowledgedExceptions: acknowledgments.map(AcknowledgedExceptionRecord.init),
            quality: acknowledgments.isEmpty ? .clean : .withExceptions,
            safeClaims: .surviving(acknowledgments)
        )
    }

    private func match(
        previous: [PeriodCheckpointException],
        previousProjection: SemanticPeriodProjection,
        current: [PeriodCheckpointException],
        currentProjection: SemanticPeriodProjection
    ) throws -> PeriodCheckpointAcknowledgmentMatchResult {
        PeriodCheckpointAcknowledgmentMatcher.match(
            previousRevision: try revision(previousProjection, acknowledgments: previous),
            currentExceptions: current,
            currentProjection: try canonical(currentProjection)
        )
    }

    /// The standard shape: one previously acknowledged booked-economics
    /// exception whose subject is unchanged this revision.
    private func carriedMatch(
        id: String = "obs-booked"
    ) throws -> (result: PeriodCheckpointAcknowledgmentMatchResult, carried: [PeriodCheckpointException]) {
        let projection = periodProjection(observations: [observation(id: id)])
        let carried = [exception(id)]
        let result = try match(
            previous: carried, previousProjection: projection,
            current: carried, currentProjection: projection
        )
        return (result, carried)
    }

    private func review(_ interval: ReviewInterval) -> ReviewResult {
        let zero = money(0)
        return ReviewResult(
            kind: .monthly, interval: interval, asOf: interval.end, currency: .eur,
            coverage: ReviewCoverage(
                status: .complete, reasons: [], missingIntervals: [],
                archiveCutoff: nil, usedArchive: false, usedLive: true
            ),
            totals: ReviewTotals(
                currency: .eur, economicSpending: zero, refunds: zero,
                netEconomicSpending: zero, personalIncome: zero, passThroughNotMine: zero,
                financingRepayments: zero, internalTransfers: zero
            ),
            budget: ReviewBudget(
                periodEconomicSpending: zero, attributions: [], monthlyContexts: [],
                uncategorized: zero, financingRepayments: zero, drivers: [],
                ordinaryRecurring: zero, ordinaryVariable: zero, exceptional: zero,
                unresolvedNature: zero
            ),
            income: ReviewIncome(
                personalIncome: zero, parentalSupportGross: zero, parentalSupportOwned: zero,
                earnedOrOther: zero, reimbursements: zero, passThroughGross: zero,
                passThroughOwned: zero, passThroughNotMine: zero, internalMovement: zero,
                unresolved: zero
            ),
            expectations: ReviewExpectations(items: []),
            goals: ReviewGoals(
                currentlySetAside: zero, reservationHistoryKnown: false,
                reservationChange: nil, activePurchases: [], upcomingTargetDates: []
            ),
            risk: ReviewRisk(
                asOf: interval.end, asOfLedgerLiquidity: zero, outlookEnd: interval.end,
                upcomingObligations: [], firstHardCashRiskDate: nil, firstFloorWarningDate: nil,
                firstRisk: nil, minimumBridgeRequired: zero
            ),
            comparison: .unavailable(.notRequested),
            findings: []
        )
    }

    private func request(
        exceptions: [PeriodCheckpointException],
        acknowledged: PeriodCheckpointConfirmedAcknowledgments,
        projection: SemanticPeriodProjection
    ) -> PeriodCheckpointRequest {
        let interval = ReviewInterval(start: period.start, end: period.end)
        return PeriodCheckpointRequest(
            period: interval, kind: .monthly, asOf: interval.end,
            review: review(interval), exceptions: exceptions,
            confirmedAcknowledgments: acknowledged,
            projection: projection, requiresSemanticProjection: true
        )
    }

    // MARK: - T1–T3. A candidate exists only for a real, unique match

    func testT1UniqueMatchProducesOneCandidateWithProvenance() throws {
        let (result, _) = try carriedMatch()
        XCTAssertEqual(result.matched.count, 1)
        let candidates = result.carryForwardCandidates
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].currentException, exception("obs-booked"))
        XCTAssertEqual(candidates[0].previousException, exception("obs-booked"))
        XCTAssertEqual(candidates.map(\.currentException.id), result.carryForwardCandidateIDs)
    }

    func testT2AmbiguousSubjectProducesNoCandidate() throws {
        // The projection holds two observations under one identifier, so the
        // exception's semantic subject cannot be reconstructed uniquely.
        let projection = periodProjection(
            observations: [observation(id: "obs-dup"), observation(id: "obs-dup", minorUnits: -99)]
        )
        let result = try match(
            previous: [exception("obs-dup")], previousProjection: projection,
            current: [exception("obs-dup")], currentProjection: projection
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertTrue(result.carryForwardCandidates.isEmpty)
        XCTAssertEqual(result.previousUnmatchable.map(\.exception.id), ["obs-dup"])
        XCTAssertEqual(result.currentUnmatchable.map(\.id), ["obs-dup"])
    }

    func testT2AmbiguousPairingProducesNoCandidate() throws {
        // One previous acknowledgment against two current exceptions sharing
        // the same subject is not a one-to-one carry.
        let projection = periodProjection(observations: [observation(id: "obs-dup")])
        let result = try match(
            previous: [exception("obs-dup")], previousProjection: projection,
            current: [exception("obs-dup"), exception("obs-dup")],
            currentProjection: projection
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertTrue(result.carryForwardCandidates.isEmpty)
        XCTAssertEqual(result.previousUnmatchable.map(\.exception.id), ["obs-dup"])
    }

    func testT3IncompleteSubjectProducesNoCandidate() throws {
        // The exception names an observation the projection does not contain.
        let projection = periodProjection(observations: [])
        let result = try match(
            previous: [exception("obs-missing")], previousProjection: projection,
            current: [exception("obs-missing")], currentProjection: projection
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertTrue(result.carryForwardCandidates.isEmpty)
        XCTAssertEqual(result.previousUnmatchable.map(\.exception.id), ["obs-missing"])
    }

    func testT3KindWithoutASemanticSubjectProducesNoCandidate() throws {
        let projection = periodProjection(observations: [observation(id: "obs-booked")])
        let unmatchable = exception("lnk", .unresolvedEvidenceLinkage)
        let result = try match(
            previous: [unmatchable], previousProjection: projection,
            current: [unmatchable], currentProjection: projection
        )
        XCTAssertTrue(result.carryForwardCandidates.isEmpty)
        XCTAssertEqual(result.previousUnmatchable.map(\.exception.id), ["lnk"])
    }

    // MARK: - T4–T6. Candidate is not confirmation

    func testT4CandidateAndConfirmedAreDistinctNonInterchangeableTypes() throws {
        let (result, carried) = try carriedMatch()
        let candidate = result.carryForwardCandidates[0]
        let confirmed = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            [candidate], carriedExceptions: carried
        )
        // A candidate exposes provenance and no authority; only the confirmed
        // value carries an acknowledgment set.
        let candidateFields = Set(Mirror(reflecting: candidate).children.compactMap(\.label))
        XCTAssertEqual(candidateFields, ["previousException", "currentException"])
        XCTAssertFalse(candidateFields.contains("confirmedAcknowledgmentIDs"))
        let confirmedFields = Set(Mirror(reflecting: confirmed).children.compactMap(\.label))
        XCTAssertEqual(confirmedFields, ["confirmedExceptions"])
        let payload = try XCTUnwrap(Mirror(reflecting: confirmed).children.first)
        XCTAssertEqual(payload.value as? Set<PeriodCheckpointException>, Set(carried))
        XCTAssertEqual(confirmed.confirmedAcknowledgmentIDs, ["obs-booked"])
    }

    func testT5MatchingAloneConfirmsNothingAndCannotChangeReadiness() throws {
        let projection = periodProjection(observations: [observation(id: "obs-booked")])
        let carried = [exception("obs-booked")]
        let pending = request(exceptions: carried, acknowledged: .noDecisions, projection: projection)
        let before = PeriodCheckpointEvaluator.evaluate(pending)
        XCTAssertEqual(before.disposition, .needsDecisions)

        let result = try match(
            previous: carried, previousProjection: projection,
            current: carried, currentProjection: projection
        )
        XCTAssertEqual(result.carryForwardCandidates.count, 1)

        // Deriving candidates changes neither the request nor its readiness.
        XCTAssertEqual(pending.confirmedAcknowledgments, .noDecisions)
        XCTAssertEqual(PeriodCheckpointEvaluator.evaluate(pending), before)
        XCTAssertEqual(PeriodCheckpointEvaluator.evaluate(pending).disposition, .needsDecisions)
    }

    func testT6ConfirmationIsRequiredBeforeAnAcknowledgmentSetExists() throws {
        let projection = periodProjection(observations: [observation(id: "obs-booked")])
        let carried = [exception("obs-booked")]
        let result = try match(
            previous: carried, previousProjection: projection,
            current: carried, currentProjection: projection
        )
        // Without the explicit call there is no confirmed set to apply.
        let unconfirmed = request(exceptions: carried, acknowledged: .noDecisions, projection: projection)
        XCTAssertEqual(PeriodCheckpointEvaluator.evaluate(unconfirmed).disposition, .needsDecisions)

        let confirmed = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            result.carryForwardCandidates, carriedExceptions: carried
        )
        let applied = request(exceptions: carried, acknowledged: confirmed, projection: projection)
        XCTAssertEqual(
            PeriodCheckpointEvaluator.evaluate(applied).disposition,
            .readyWithAcknowledgedExceptions
        )
    }

    // MARK: - T7, T10. Confirmed behaviour is the intended acknowledgment behaviour

    /// Reframed at the authority repair. This once asserted that the confirmed
    /// path and a raw `["obs-booked"]` acknowledgment produced equal readiness,
    /// which encoded the raw-identifier bridge as a desirable property — the
    /// very bridge that made confirmation optional. The legitimate reading is
    /// that acknowledgment still *means* what it always meant, and that the two
    /// honest provenances — a carry-forward candidate and a first-time decision
    /// — agree, because both are checked by the same whole-value rule. Neither
    /// arm can be reached with an identifier.
    func testT7ConfirmedAuthorityProducesTheIntendedAcknowledgmentReadiness() throws {
        let projection = periodProjection(observations: [observation(id: "obs-booked")])
        let carried = [exception("obs-booked")]
        let result = try match(
            previous: carried, previousProjection: projection,
            current: carried, currentProjection: projection
        )
        let viaCarryForward = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            result.carryForwardCandidates, carriedExceptions: carried
        )
        let viaFirstTimeDecision = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            decisions: carried, carriedExceptions: carried
        )
        XCTAssertEqual(viaCarryForward, viaFirstTimeDecision)

        let readiness = PeriodCheckpointEvaluator.evaluate(
            request(exceptions: carried, acknowledged: viaCarryForward, projection: projection)
        )
        XCTAssertEqual(
            readiness,
            PeriodCheckpointEvaluator.evaluate(
                request(exceptions: carried, acknowledged: viaFirstTimeDecision,
                        projection: projection)
            )
        )
        XCTAssertEqual(readiness.disposition, .readyWithAcknowledgedExceptions)
        XCTAssertEqual(readiness.acknowledgedExceptions, carried)
        XCTAssertTrue(readiness.undecidedExceptions.isEmpty)
        XCTAssertEqual(readiness.quality, .withExceptions)
    }

    func testT10EmptyConfirmationLeavesTheDecisionUnmade() throws {
        let projection = periodProjection(observations: [observation(id: "obs-booked")])
        let carried = [exception("obs-booked")]
        let confirmed = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            [], carriedExceptions: carried
        )
        XCTAssertTrue(confirmed.confirmedAcknowledgmentIDs.isEmpty)
        XCTAssertEqual(
            PeriodCheckpointEvaluator.evaluate(
                request(exceptions: carried, acknowledged: confirmed, projection: projection)
            ).disposition,
            .needsDecisions
        )
    }

    // MARK: - T8, C3–C5. Identifiers are joins, not authority

    func testT8IdentifierAloneCannotConfirmWhenSubjectMaterialDiffers() throws {
        let (result, _) = try carriedMatch()
        let candidate = result.carryForwardCandidates[0]
        // Same identifier, different semantic material, on every axis.
        let differentKind = exception("obs-booked", .providerStatusConflict)
        let differentDay = exception("obs-booked", day: Day(index: 15))
        let differentAmount = exception("obs-booked", amount: money(-4200))
        for carried in [[differentKind], [differentDay], [differentAmount]] {
            XCTAssertThrowsError(
                try PeriodCheckpointAcknowledgmentConfirmation.confirm(
                    [candidate], carriedExceptions: carried
                )
            ) { error in
                XCTAssertEqual(
                    error as? PeriodCheckpointAcknowledgmentConfirmationError,
                    .candidateSubjectNotCarried
                )
            }
        }
    }

    func testC3CandidateCannotBeConfirmedAgainstADifferentSubject() throws {
        let (result, _) = try carriedMatch()
        let candidate = result.carryForwardCandidates[0]
        XCTAssertThrowsError(
            try PeriodCheckpointAcknowledgmentConfirmation.confirm(
                [candidate], carriedExceptions: [exception("obs-other")]
            )
        ) { error in
            XCTAssertEqual(
                error as? PeriodCheckpointAcknowledgmentConfirmationError,
                .candidateSubjectNotCarried
            )
        }
    }

    func testC4ChangedIdentifierWithSameSubjectFollowsTheCurrentCarriedValue() throws {
        // The container identifier differs between revisions; the matcher pairs
        // on canonical subject, so the candidate names the current identifier
        // and confirmation yields that one, not the historical one.
        let previousProjection = periodProjection(observations: [observation(id: "obs-old")])
        let currentProjection = periodProjection(observations: [observation(id: "obs-new")])
        let result = try match(
            previous: [exception("obs-old")], previousProjection: previousProjection,
            current: [exception("obs-new")], currentProjection: currentProjection
        )
        // Subjects include the observation's own identity, so a renamed
        // container is not the same subject: nothing carries.
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertTrue(result.carryForwardCandidates.isEmpty)
        XCTAssertEqual(result.previousDisappeared.map(\.exception.id), ["obs-old"])
        XCTAssertEqual(result.currentUnmatched.map(\.id), ["obs-new"])
    }

    /// Repaired at the authority repair. The previous version of this test
    /// stopped at `confirmed.confirmedAcknowledgmentIDs == ["obs-booked"]` and
    /// concluded "confers no authority" — but it never ran the evaluator, and
    /// the authority behaviour was the opposite of its name: both same-id
    /// subjects were acknowledged by the one confirmed identifier. The real
    /// boundary is that such an exception set never reaches acknowledgment at
    /// all.
    func testC5SharedIdentifierAcrossDistinctSubjectsIsBlockedBeforeAuthorityApplies() throws {
        let (result, _) = try carriedMatch()
        let candidate = result.carryForwardCandidates[0]
        let projection = periodProjection(observations: [observation(id: "obs-booked")])
        // Two distinct carried exceptions share the candidate's identifier.
        let a = exception("obs-booked")
        let b = exception("obs-booked", day: Day(index: 16))
        XCTAssertEqual(a.id, b.id)
        XCTAssertNotEqual(a, b)

        // Confirmation itself is still exactly right: only the value-equal
        // subject is honoured, and the identifier alone does not reach `b`.
        let confirmed = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            [candidate], carriedExceptions: [a, b]
        )
        XCTAssertEqual(confirmed.confirmedAcknowledgmentIDs, ["obs-booked"])
        XCTAssertEqual([a, b].filter { $0 == candidate.currentException }.count, 1)

        // And the evaluator never gets the chance to spread that identifier
        // across both: the duplicate identity blocks the period outright.
        let readiness = PeriodCheckpointEvaluator.evaluate(
            request(exceptions: [a, b], acknowledged: confirmed, projection: projection)
        )
        XCTAssertEqual(readiness.disposition, .blocked)
        XCTAssertTrue(readiness.blockers.map(\.kind).contains(.duplicateExceptionIdentity))
        XCTAssertTrue(readiness.acknowledgedExceptions.isEmpty)
        XCTAssertEqual(readiness.undecidedExceptions.count, 2)
        XCTAssertEqual(readiness.safeClaims, .blocked)
    }

    func testAmbiguousCarriedDuplicateRefusesConfirmation() throws {
        let (result, _) = try carriedMatch()
        let candidate = result.carryForwardCandidates[0]
        XCTAssertThrowsError(
            try PeriodCheckpointAcknowledgmentConfirmation.confirm(
                [candidate], carriedExceptions: [exception("obs-booked"), exception("obs-booked")]
            )
        ) { error in
            XCTAssertEqual(
                error as? PeriodCheckpointAcknowledgmentConfirmationError,
                .candidateSubjectAmbiguous
            )
        }
    }

    // MARK: - C6. Malformed confirmation states

    func testC6DuplicateCandidateRefusesTheWholeConfirmation() throws {
        let (result, carried) = try carriedMatch()
        let candidate = result.carryForwardCandidates[0]
        XCTAssertThrowsError(
            try PeriodCheckpointAcknowledgmentConfirmation.confirm(
                [candidate, candidate], carriedExceptions: carried
            )
        ) { error in
            XCTAssertEqual(
                error as? PeriodCheckpointAcknowledgmentConfirmationError,
                .duplicateCandidate
            )
        }
    }

    func testC6OneBadCandidateRefusesEveryOtherCandidateToo() throws {
        let first = observation(id: "obs-a")
        let second = observation(id: "obs-b")
        let projection = periodProjection(observations: [first, second])
        let carried = [exception("obs-a"), exception("obs-b")]
        let result = try match(
            previous: carried, previousProjection: projection,
            current: carried, currentProjection: projection
        )
        XCTAssertEqual(result.carryForwardCandidates.count, 2)
        // Confirming against a set that no longer carries "obs-b" refuses the
        // whole decision rather than half-applying it.
        XCTAssertThrowsError(
            try PeriodCheckpointAcknowledgmentConfirmation.confirm(
                result.carryForwardCandidates, carriedExceptions: [exception("obs-a")]
            )
        ) { error in
            XCTAssertEqual(
                error as? PeriodCheckpointAcknowledgmentConfirmationError,
                .candidateSubjectNotCarried
            )
        }
        let both = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            result.carryForwardCandidates, carriedExceptions: carried
        )
        XCTAssertEqual(both.confirmedAcknowledgmentIDs, ["obs-a", "obs-b"])
    }

    // MARK: - T9. Advisory state never reaches canonical bytes

    func testT9CandidatesAndConfirmationDoNotMoveTheCanonicalDigest() throws {
        let projection = periodProjection(observations: [observation(id: "obs-booked")])
        let carried = [exception("obs-booked")]
        let before = try canonical(projection)
        let result = try match(
            previous: carried, previousProjection: projection,
            current: carried, currentProjection: projection
        )
        let confirmed = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            result.carryForwardCandidates, carriedExceptions: carried
        )
        XCTAssertFalse(confirmed.confirmedAcknowledgmentIDs.isEmpty)
        let after = try canonical(projection)
        XCTAssertEqual(after.bytes, before.bytes)
        XCTAssertEqual(after.digest, before.digest)
        XCTAssertEqual(after.format, before.format)
        // The closed revision's canonical payload is likewise untouched.
        let stored = try revision(projection, acknowledgments: carried)
        XCTAssertEqual(stored.canonicalProjection.bytes, before.bytes)
        XCTAssertEqual(stored.projectionDigest, before.digest)
    }

    // MARK: - A1–A6. Exclusive typed authority

    /// A1. Running the matcher, by itself, acknowledges nothing.
    func testA1MatcherResultAloneGrantsNoAcknowledgment() throws {
        let projection = periodProjection(observations: [observation(id: "obs-booked")])
        let carried = [exception("obs-booked")]
        let result = try match(
            previous: carried, previousProjection: projection,
            current: carried, currentProjection: projection
        )
        XCTAssertEqual(result.carryForwardCandidateIDs, ["obs-booked"])
        let readiness = PeriodCheckpointEvaluator.evaluate(
            request(exceptions: carried, acknowledged: .noDecisions, projection: projection)
        )
        XCTAssertEqual(readiness.disposition, .needsDecisions)
        XCTAssertTrue(readiness.acknowledgedExceptions.isEmpty)
        XCTAssertEqual(readiness.undecidedExceptions, carried)
    }

    /// A3/A4. Explicit confirmation yields typed authority, and the evaluator
    /// acknowledges exactly the confirmed subject — no more, no less.
    func testA3A4ConfirmedAuthorityAcknowledgesExactlyTheConfirmedException() throws {
        let projection = periodProjection(
            observations: [observation(id: "obs-one"), observation(id: "obs-two")]
        )
        let carried = [exception("obs-one"), exception("obs-two")]
        let confirmed = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            decisions: [carried[0]], carriedExceptions: carried
        )
        XCTAssertEqual(confirmed.confirmedAcknowledgmentIDs, ["obs-one"])
        let readiness = PeriodCheckpointEvaluator.evaluate(
            request(exceptions: carried, acknowledged: confirmed, projection: projection)
        )
        XCTAssertEqual(readiness.acknowledgedExceptions.map(\.id), ["obs-one"])
        XCTAssertEqual(readiness.undecidedExceptions.map(\.id), ["obs-two"])
        XCTAssertEqual(readiness.disposition, .needsDecisions)
    }

    /// A5. A built request cannot be re-authorized. `confirmedAcknowledgments`
    /// is `let`, so the mutation that used to work is not expressible; this
    /// pins the observable half — copying a request preserves its authority
    /// and nothing can widen it after the fact.
    func testA5RequestAuthorityCannotBeWidenedAfterConstruction() throws {
        let projection = periodProjection(observations: [observation(id: "obs-booked")])
        let carried = [exception("obs-booked")]
        var pending = request(exceptions: carried, acknowledged: .noDecisions,
                              projection: projection)
        XCTAssertEqual(PeriodCheckpointEvaluator.evaluate(pending).disposition, .needsDecisions)
        // Everything still mutable on a request is orthogonal to authority.
        pending.requiresSemanticProjection = false
        XCTAssertEqual(pending.confirmedAcknowledgments, .noDecisions)
        XCTAssertEqual(PeriodCheckpointEvaluator.evaluate(pending).disposition, .needsDecisions)
    }

    // MARK: - D1–D6. Identity uniqueness

    /// D1–D5. Every shape of same-identifier/different-subject is blocked
    /// before acknowledgment authority is joined — never deduplicated, never
    /// first-one-wins, never both.
    func testD1ToD5DuplicateIdentifiersBlockBeforeAuthorityApplies() throws {
        let projection = periodProjection(observations: [observation(id: "obs-booked")])
        let base = exception("obs-booked")
        let variants: [(String, PeriodCheckpointException)] = [
            ("D1 day", exception("obs-booked", day: Day(index: 16))),
            ("D2 kind", exception("obs-booked", .providerStatusConflict)),
            ("D3 amount", exception("obs-booked", amount: money(-4200))),
            ("D4 basis", exception("obs-booked", .aggregateEvidenceModelLimitation,
                                   basis: .structuralCandidateOnly)),
            ("D5 identical", exception("obs-booked")),
        ]
        for (label, other) in variants {
            let carried = [base, other]
            // Authority is legitimately obtained for the base subject first,
            // so the block is not an artefact of having no decision.
            let confirmed: PeriodCheckpointConfirmedAcknowledgments
            if other == base {
                // An exactly duplicated value is ambiguous to confirmation too.
                XCTAssertThrowsError(
                    try PeriodCheckpointAcknowledgmentConfirmation.confirm(
                        decisions: [base], carriedExceptions: carried
                    )
                ) { error in
                    XCTAssertEqual(
                        error as? PeriodCheckpointAcknowledgmentConfirmationError,
                        .candidateSubjectAmbiguous, label
                    )
                }
                confirmed = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
                    decisions: [base], carriedExceptions: [base]
                )
            } else {
                confirmed = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
                    decisions: [base], carriedExceptions: carried
                )
                XCTAssertEqual(confirmed.confirmedAcknowledgmentIDs, ["obs-booked"], label)
            }
            let readiness = PeriodCheckpointEvaluator.evaluate(
                request(exceptions: carried, acknowledged: confirmed, projection: projection)
            )
            XCTAssertEqual(readiness.disposition, .blocked, label)
            XCTAssertTrue(
                readiness.blockers.map(\.kind).contains(.duplicateExceptionIdentity), label
            )
            XCTAssertTrue(readiness.acknowledgedExceptions.isEmpty, label)
            XCTAssertEqual(readiness.undecidedExceptions.count, 2, label)
            XCTAssertEqual(readiness.exceptions.count, 2, "\(label): never silently deduplicated")
            XCTAssertEqual(readiness.safeClaims, .blocked, label)
        }
    }

    /// D6. Distinct identifiers are untouched by the new invariant.
    func testD6UniqueIdentifiersKeepExistingEvaluatorBehaviour() throws {
        let projection = periodProjection(
            observations: [observation(id: "obs-one"), observation(id: "obs-two")]
        )
        let carried = [exception("obs-one"), exception("obs-two")]
        let confirmed = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            decisions: carried, carriedExceptions: carried
        )
        let readiness = PeriodCheckpointEvaluator.evaluate(
            request(exceptions: carried, acknowledged: confirmed, projection: projection)
        )
        XCTAssertEqual(readiness.disposition, .readyWithAcknowledgedExceptions)
        XCTAssertTrue(readiness.blockers.isEmpty)
        XCTAssertEqual(Set(readiness.acknowledgedExceptions), Set(carried))
        XCTAssertTrue(readiness.undecidedExceptions.isEmpty)
    }

    /// The duplicate blocker is a blocker in the full sense: not acknowledgeable,
    /// and it removes every safe claim rather than merely flagging the period.
    func testDuplicateIdentityBlockerIsNeverAcknowledgeable() throws {
        XCTAssertFalse(PeriodCheckpointBlockerKind.duplicateExceptionIdentity.isAcknowledgeable)
        XCTAssertFalse(PeriodCheckpointBlockerKind.duplicateExceptionIdentity.isCoverageDerived)
    }

    /// Ordering was previously left to the caller's array order for same-id
    /// subjects. Those inputs are blocked now, so evaluable inputs order
    /// deterministically regardless of how they arrive.
    func testEvaluableExceptionsOrderIndependentlyOfInputOrder() throws {
        let projection = periodProjection(
            observations: [observation(id: "obs-one"), observation(id: "obs-two")]
        )
        let a = exception("obs-one")
        let b = exception("obs-two")
        let forward = PeriodCheckpointEvaluator.evaluate(
            request(exceptions: [a, b], acknowledged: .noDecisions, projection: projection)
        )
        let backward = PeriodCheckpointEvaluator.evaluate(
            request(exceptions: [b, a], acknowledged: .noDecisions, projection: projection)
        )
        XCTAssertEqual(forward.exceptions, backward.exceptions)
    }

    // MARK: - API shape

    /// The confirmed value must have exactly one construction site in the whole
    /// module: the explicit `confirm` call. Any other producer — a convenience
    /// property on the match result, an auto-promotion helper — would make a
    /// confirmed set reachable without a decision, which is the one thing this
    /// boundary exists to prevent.
    func testConfirmIsTheOnlyProducerOfANonEmptyConfirmedSet() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let sources = url.appendingPathComponent("Sources/FinanceCore")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        var sites: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let count = text.components(separatedBy: "PeriodCheckpointConfirmedAcknowledgments(").count - 1
            sites.append(contentsOf: Array(repeating: file.lastPathComponent, count: count))
        }
        // Exactly two sites, both in the boundary's own file: the validator,
        // and the empty `noDecisions` constant. Nothing else in FinanceCore
        // builds one.
        XCTAssertEqual(
            sites,
            ["PeriodCheckpointAcknowledgmentConfirmation.swift",
             "PeriodCheckpointAcknowledgmentConfirmation.swift"]
        )

        let source = sources
            .appendingPathComponent("Checkpoint/PeriodCheckpointAcknowledgmentConfirmation.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        // The matcher-result extension builds no confirmed value: candidates
        // never auto-promote.
        let extensionBlock = try XCTUnwrap(
            text.components(separatedBy: "extension PeriodCheckpointAcknowledgmentMatchResult {").last?
                .components(separatedBy: "\n}").first
        )
        XCTAssertFalse(extensionBlock.contains("Confirmed"))

        // The second site grants nothing: `noDecisions` is literally empty, so
        // the only construction that can produce authority is the validator's.
        let collapsed = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        XCTAssertTrue(
            collapsed.contains(
                "public static let noDecisions = PeriodCheckpointConfirmedAcknowledgments( "
                + "confirmedExceptions: [] )"
            )
        )
        XCTAssertTrue(PeriodCheckpointConfirmedAcknowledgments.noDecisions
            .confirmedAcknowledgmentIDs.isEmpty)

        // The authority-bearing construction is the last statement of the
        // private validator, after every per-subject check.
        let validator = try XCTUnwrap(
            text.components(separatedBy: "private static func confirm(").last
        )
        XCTAssertTrue(validator.contains("candidateSubjectNotCarried"))
        XCTAssertTrue(validator.contains("candidateSubjectAmbiguous"))
        XCTAssertTrue(validator.contains("duplicateCandidate"))
        let checks = try XCTUnwrap(validator.range(of: "duplicateCandidate"))
        let construction = try XCTUnwrap(
            validator.range(of: "PeriodCheckpointConfirmedAcknowledgments(")
        )
        XCTAssertTrue(checks.lowerBound < construction.lowerBound)
    }

    /// A6. The repair's central property, pinned at the API shape: there is no
    /// second, raw way to grant acknowledgment authority. A `Set<String>` a
    /// caller controls must not appear as an acknowledgment input on the
    /// request, and the evaluator must read its authority from the confirmed
    /// value rather than from anything the caller can hand it directly.
    func testNoRawIdentifierAuthorityInputRemains() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let checkpoint = url.appendingPathComponent("Sources/FinanceCore/Checkpoint")
        let readiness = try String(
            contentsOf: checkpoint.appendingPathComponent("PeriodCheckpointReadiness.swift"),
            encoding: .utf8
        )
        // The old raw property is gone in name and in shape.
        XCTAssertFalse(readiness.contains("acknowledgedExceptionIDs"))
        XCTAssertFalse(readiness.contains("var confirmedAcknowledgments"))
        XCTAssertTrue(
            readiness.contains("public let confirmedAcknowledgments: PeriodCheckpointConfirmedAcknowledgments")
        )
        // Independent of property names: an unrelated label must not hide a
        // second raw authority input. Pin runtime storage and constructor shape.
        let pending = request(exceptions: [], acknowledged: .noDecisions,
                              projection: periodProjection())
        for field in Mirror(reflecting: pending).children {
            XCTAssertFalse(field.value is Set<String>, "request cannot store raw identifier authority")
        }
        let requestSource = try XCTUnwrap(readiness
            .components(separatedBy: "public struct PeriodCheckpointRequest:").last?
            .components(separatedBy: "// MARK: - Readiness").first)
        XCTAssertFalse(requestSource.contains("Set<String>"))
        XCTAssertFalse(requestSource.contains("Set <String>"))

        let evaluator = try String(
            contentsOf: checkpoint.appendingPathComponent("PeriodCheckpointEvaluator.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(evaluator.contains("request.acknowledgedExceptionIDs"))
        XCTAssertTrue(
            evaluator.contains("request.confirmedAcknowledgments.confirmedExceptions")
        )
        XCTAssertFalse(evaluator.contains("confirmedAcknowledgmentIDs"))
        XCTAssertTrue(evaluator.contains("exceptions.filter { confirmedSubjects.contains($0) }"))
        XCTAssertTrue(evaluator.contains("exceptions.filter { !confirmedSubjects.contains($0) }"))
        // Uniqueness and semantic membership are independent guards.
        XCTAssertTrue(evaluator.contains("confirmedAcknowledgmentSubjectMismatch"))
        XCTAssertTrue(evaluator.contains("identifiersAreUnique"))
        XCTAssertTrue(evaluator.contains("duplicateExceptionIdentity"))
    }

    func testConfirmationSourceKeepsTheBoundaryClosed() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let source = url
            .appendingPathComponent("Sources/FinanceCore/Checkpoint/PeriodCheckpointAcknowledgmentConfirmation.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        // Neither value may be fabricated from outside FinanceCore.
        XCTAssertTrue(text.contains("init(confirmedExceptions:"))
        XCTAssertFalse(text.contains("public init(confirmedExceptions:"))
        let confirmedType = try XCTUnwrap(text
            .components(separatedBy: "public struct PeriodCheckpointConfirmedAcknowledgments:").last?
            .components(separatedBy: "\n}").first)
        XCTAssertNil(confirmedType.range(of: #"public\s+init\s*[<(]"#,
                                         options: .regularExpression))
        XCTAssertTrue(confirmedType.contains("let confirmedExceptions: Set<PeriodCheckpointException>"))
        XCTAssertFalse(confirmedType.contains("var confirmedExceptions"))
        XCTAssertTrue(text.contains("init(previousException:"))
        XCTAssertFalse(text.contains("public init(previousException:"))
        // The boundary never evaluates, mutates or persists anything.
        XCTAssertFalse(text.contains("PeriodCheckpointEvaluator"))
        XCTAssertFalse(text.contains("inout PeriodCheckpointRequest"))
        XCTAssertFalse(text.contains("inout PeriodCheckpointReadiness"))
        XCTAssertFalse(text.contains("SwiftData"))
        XCTAssertFalse(text.contains("FinanceStore"))
        XCTAssertFalse(text.contains("Date()"))
        // No sensitive vocabulary, matching the E1 matcher's own rule.
        for token in ["merchant", "remittance", "IBAN", "iban", "account number", "email"] {
            XCTAssertFalse(text.contains(token), "unexpected token in confirmation source: \(token)")
        }
    }
    // MARK: - R3. Confirmed subjects survive through evaluator application

    private func evaluateConfirmed(
        _ subjects: [PeriodCheckpointException], current: [PeriodCheckpointException]
    ) throws -> PeriodCheckpointReadiness {
        let confirmed = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            decisions: subjects, carriedExceptions: subjects
        )
        return PeriodCheckpointEvaluator.evaluate(
            request(exceptions: current, acknowledged: confirmed, projection: periodProjection())
        )
    }

    private func assertStale(
        _ subjects: [PeriodCheckpointException], current: [PeriodCheckpointException],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let readiness = try evaluateConfirmed(subjects, current: current)
        XCTAssertEqual(readiness.disposition, .blocked, file: file, line: line)
        XCTAssertEqual(readiness.blockers.map(\.kind), [.confirmedAcknowledgmentSubjectMismatch],
                       file: file, line: line)
        XCTAssertTrue(readiness.acknowledgedExceptions.isEmpty, file: file, line: line)
        XCTAssertEqual(Set(readiness.undecidedExceptions), Set(current), file: file, line: line)
        XCTAssertEqual(readiness.safeClaims, .blocked, file: file, line: line)
        XCTAssertThrowsError(try PeriodCheckpointRevision(
            id: revisionID, revisionNumber: 1, predecessorID: nil,
            closedAt: Date(timeIntervalSince1970: 0), readiness: readiness,
            canonicalProjection: canonical(periodProjection())
        ), file: file, line: line) { error in
            XCTAssertEqual(error as? SemanticProjectionFormatError, .invalidRevision,
                           file: file, line: line)
        }
    }

    func testS1ChangedKindBlocksSubjectReplay() throws {
        try assertStale([exception("exc-1")], current: [exception("exc-1", .providerStatusConflict)])
    }

    func testS2ChangedDayBlocksSubjectReplay() throws {
        try assertStale([exception("exc-1", day: Day(index: 15))],
                        current: [exception("exc-1", day: Day(index: 16))])
    }

    func testS3ChangedAmountBlocksSubjectReplay() throws {
        try assertStale([exception("exc-1", amount: money(-4200))],
                        current: [exception("exc-1", amount: money(-4201))])
    }

    func testS4ChangedAggregateBasisBlocksSubjectReplay() throws {
        try assertStale([
            exception("exc-1", .aggregateEvidenceModelLimitation,
                      basis: .sourceEstablishedAggregateRelationship)
        ], current: [exception("exc-1", .aggregateEvidenceModelLimitation,
                              basis: .structuralCandidateOnly)])
    }

    func testS5R3SubstitutionCannotCreateClosedDigestBearingRevision() throws {
        try assertStale([exception("exc-1", day: Day(index: 15), amount: money(-4200))],
                        current: [exception("exc-1", .providerStatusConflict,
                                            day: Day(index: 16), amount: money(-9900))])
    }

    func testS6ExactDecisionSubjectAcknowledgesNormally() throws {
        let a = exception("exc-1", day: Day(index: 15), amount: money(-4200))
        let readiness = try evaluateConfirmed([a], current: [a])
        XCTAssertEqual(readiness.acknowledgedExceptions, [a])
        XCTAssertEqual(readiness.disposition, .readyWithAcknowledgedExceptions)
        XCTAssertTrue(readiness.blockers.isEmpty)
        let accepted = try PeriodCheckpointRevision(
            id: revisionID, revisionNumber: 1, predecessorID: nil,
            closedAt: Date(timeIntervalSince1970: 0), readiness: readiness,
            canonicalProjection: canonical(periodProjection())
        )
        XCTAssertEqual(accepted.acknowledgedExceptions.map(\.exception), [a])
    }

    func testS7DifferentIDIsNotTheConfirmedSubject() throws {
        try assertStale([exception("exc-1")], current: [exception("exc-renamed")])
    }

    func testS8AbsentSubjectBlocksForeignReplay() throws {
        try assertStale([exception("exc-1")], current: [exception("unrelated", .providerStatusConflict)])
        try assertStale([exception("exc-1")], current: [])
    }

    func testS9ExtraCurrentExceptionDoesNotInvalidateConfirmedSubject() throws {
        let a = exception("exc-1")
        let b = exception("exc-2", .providerStatusConflict)
        let readiness = try evaluateConfirmed([a], current: [b, a])
        XCTAssertEqual(readiness.acknowledgedExceptions, [a])
        XCTAssertEqual(readiness.undecidedExceptions, [b])
        XCTAssertEqual(readiness.disposition, .needsDecisions)
        XCTAssertTrue(readiness.blockers.isEmpty)
        XCTAssertEqual(readiness.safeClaims, .surviving([a, b]))
    }

    func testS10MultipleExactSubjectsAcknowledgeNormally() throws {
        let subjects = [exception("exc-1"), exception("exc-2")]
        let readiness = try evaluateConfirmed(subjects, current: subjects.reversed())
        XCTAssertEqual(Set(readiness.acknowledgedExceptions), Set(subjects))
        XCTAssertTrue(readiness.undecidedExceptions.isEmpty)
        XCTAssertTrue(readiness.blockers.isEmpty)
        XCTAssertEqual(readiness.disposition, .readyWithAcknowledgedExceptions)
    }

    func testS11MixedValidAndSubstitutedSubjectsApplyNoAuthority() throws {
        let a = exception("exc-1")
        try assertStale([a, exception("exc-2")],
                        current: [a, exception("exc-2", day: Day(index: 16))])
    }

    func testS12OneMissingConfirmedSubjectAppliesNoAuthority() throws {
        let a = exception("exc-1")
        try assertStale([a, exception("exc-2")], current: [a])
    }

    func testNoDecisionsIsNeverStale() throws {
        for current in [[], [exception("exc-1")],
                        [exception("exc-1"), exception("exc-2", .providerStatusConflict)]] {
            let readiness = try evaluateConfirmed([], current: current)
            XCTAssertTrue(readiness.blockers.isEmpty)
            XCTAssertTrue(readiness.acknowledgedExceptions.isEmpty)
            XCTAssertEqual(Set(readiness.undecidedExceptions), Set(current))
            XCTAssertEqual(readiness.disposition, current.isEmpty ? .readyClean : .needsDecisions)
        }
    }

    func testCandidateConfirmationRetainsSubjectThroughEvaluator() throws {
        let (result, carried) = try carriedMatch()
        let confirmed = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            result.carryForwardCandidates, carriedExceptions: carried
        )
        let exact = PeriodCheckpointEvaluator.evaluate(request(
            exceptions: carried, acknowledged: confirmed, projection: periodProjection()
        ))
        XCTAssertEqual(exact.acknowledgedExceptions, carried)
        XCTAssertEqual(exact.disposition, .readyWithAcknowledgedExceptions)
        let substituted = exception("obs-booked", day: Day(index: 16))
        let stale = PeriodCheckpointEvaluator.evaluate(request(
            exceptions: [substituted], acknowledged: confirmed, projection: periodProjection()
        ))
        XCTAssertEqual(stale.blockers.map(\.kind), [.confirmedAcknowledgmentSubjectMismatch])
        XCTAssertEqual(stale.disposition, .blocked)
        XCTAssertTrue(stale.acknowledgedExceptions.isEmpty)
        XCTAssertEqual(stale.undecidedExceptions, [substituted])
        XCTAssertEqual(stale.safeClaims, .blocked)
    }

    func testDecisionConfirmationStillValidatesWholeSubjects() throws {
        let a = exception("exc-1")
        XCTAssertThrowsError(try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            decisions: [a], carriedExceptions: [exception("exc-1", day: Day(index: 16))]
        )) { error in
            XCTAssertEqual(error as? PeriodCheckpointAcknowledgmentConfirmationError,
                           .candidateSubjectNotCarried)
        }
    }

    func testMismatchBlockerIsUnacknowledgeableAndOrdersWithIndependentBlockers() throws {
        let mismatch = PeriodCheckpointBlockerKind.confirmedAcknowledgmentSubjectMismatch
        XCTAssertFalse(mismatch.isAcknowledgeable)
        XCTAssertFalse(mismatch.isCoverageDerived)
        let a = exception("exc-1")
        let b = exception("exc-1", day: Day(index: 16))
        let confirmed = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            decisions: [a], carriedExceptions: [a]
        )
        let c = exception("exc-1", .providerStatusConflict)
        for current in [[b, c], [c, b]] {
            var pending = request(exceptions: current, acknowledged: confirmed,
                                  projection: periodProjection())
            pending.asOf = period.start
            pending.review = nil
            pending.projection = nil
            let readiness = PeriodCheckpointEvaluator.evaluate(pending)
            XCTAssertEqual(readiness.blockers.map(\.kind), [
                .periodNotEnded, .reviewUnavailable, .semanticProjectionUnavailable,
                .duplicateExceptionIdentity, mismatch
            ])
            XCTAssertEqual(readiness.disposition, .blocked)
            XCTAssertEqual(readiness.safeClaims, .blocked)
            XCTAssertTrue(readiness.acknowledgedExceptions.isEmpty)
            XCTAssertEqual(readiness.undecidedExceptions.count, 2)
            // Membership is checked even before the invalid-period early return.
            pending.period = ReviewInterval(start: period.end, end: period.start)
            XCTAssertEqual(PeriodCheckpointEvaluator.evaluate(pending).blockers.map(\.kind),
                           [.invalidPeriod, .duplicateExceptionIdentity, mismatch])
        }
    }

}
