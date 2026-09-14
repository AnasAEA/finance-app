import XCTest
import Foundation
@testable import FinanceCore

/// Phase 2.9C-E1 — pure acknowledgment matcher. Synthetic fixtures only.
final class PeriodCheckpointAcknowledgmentMatcherTests: XCTestCase {

    private let period = SemanticInterval(start: Day(index: 10), end: Day(index: 40))
    private let revisionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func money(_ units: Int64, _ code: String = "EUR", _ digits: Int = 2) -> Money {
        Money(minorUnits: units, currency: Currency(code: code, minorUnitDigits: digits))
    }

    private func observation(
        id: String,
        statusToken: String = "BOOKED",
        identity: ExternalObservationIdentity = .durable,
        eligible: Bool = true,
        bindingActive: Bool = true,
        resolution: ObservationResolutionState = .unreviewed,
        minorUnits: Int64 = -4200,
        currency: String = "EUR",
        day: Day? = Day(index: 15),
        links: [SemanticEvidenceLinkFact] = [],
        aggregate: SemanticAggregateFact? = nil
    ) -> SemanticObservationFact {
        SemanticObservationFact(
            id: id, statusToken: statusToken, identity: identity,
            providerEligibleForEconomicActual: eligible, bindingIsActive: bindingActive,
            resolution: resolution, minorUnits: minorUnits, currencyCode: currency,
            economicDay: day, links: links, aggregate: aggregate
        )
    }

    private func expectation(
        obligation: String,
        day: Day,
        minorUnits: Int64 = -9000,
        currency: String = "EUR",
        status: String = "overdue",
        settledBy: String? = nil
    ) -> SemanticExpectationFact {
        SemanticExpectationFact(
            obligationID: obligation, expectedDay: day, minorUnits: minorUnits,
            currencyCode: currency, statusToken: status, settledByTransactionID: settledBy
        )
    }

    private func attribution(
        _ transactionID: String,
        budgetID: String? = nil,
        basis: MonthlyBudgetEngine.AttributionBasis = .unattributed,
        amount: Int64
    ) -> SemanticBudgetAttributionFact {
        SemanticBudgetAttributionFact(
            transactionID: transactionID, budgetID: budgetID, basis: basis,
            amount: money(amount)
        )
    }

    private func periodProjection(
        observations: [SemanticObservationFact] = [],
        expectations: [SemanticExpectationFact] = [],
        attributions: [SemanticBudgetAttributionFact] = [],
        uncategorized: Int64 = 0,
        spending: Int64 = 0
    ) -> SemanticPeriodProjection {
        SemanticPeriodProjection(
            period: period, kind: .monthly, coverage: .complete,
            budget: SemanticBudgetFact(
                periodEconomicSpending: money(spending),
                uncategorized: money(uncategorized),
                attributions: attributions
            ),
            transactions: [], observations: observations, expectations: expectations
        )
    }

    private func exception(
        _ id: String,
        _ kind: PeriodCheckpointExceptionKind,
        basis: AggregateEvidenceBasis? = nil
    ) -> PeriodCheckpointException {
        PeriodCheckpointException(id: id, kind: kind, aggregateBasis: basis)
    }

    private func occurrenceID(_ obligation: String, _ day: Day) -> String {
        OccurrenceID(obligationID: obligation, expectedDay: day).description
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
            period: payload.projection.period,
            periodKind: payload.projection.kind,
            revisionNumber: 1,
            predecessorID: nil,
            closedAt: Date(timeIntervalSince1970: 0),
            canonicalProjection: payload,
            acknowledgedExceptions: acknowledgments.map(AcknowledgedExceptionRecord.init),
            quality: acknowledgments.isEmpty ? .clean : .withExceptions,
            safeClaims: .surviving(acknowledgments)
        )
    }

    private func match(
        previous acknowledgments: [PeriodCheckpointException],
        previousProjection: SemanticPeriodProjection,
        current: [PeriodCheckpointException],
        currentProjection: SemanticPeriodProjection
    ) throws -> PeriodCheckpointAcknowledgmentMatchResult {
        let result = PeriodCheckpointAcknowledgmentMatcher.match(
            previousRevision: try revision(previousProjection, acknowledgments: acknowledgments),
            currentExceptions: current,
            currentProjection: try canonical(currentProjection)
        )
        assertTotality(previous: acknowledgments, current: current, result: result)
        return result
    }

    private func counted(_ items: [PeriodCheckpointException]) -> [PeriodCheckpointException: Int] {
        var result: [PeriodCheckpointException: Int] = [:]
        for item in items { result[item, default: 0] += 1 }
        return result
    }

    private func assertTotality(
        previous: [PeriodCheckpointException],
        current: [PeriodCheckpointException],
        result: PeriodCheckpointAcknowledgmentMatchResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            counted(previous),
            counted(
                result.matched.map(\.previous.exception)
                    + result.previousDisappeared.map(\.exception)
                    + result.previousUnmatchable.map(\.exception)
            ),
            "previous totality",
            file: file, line: line
        )
        XCTAssertEqual(
            counted(current),
            counted(result.matched.map(\.current) + result.currentUnmatched + result.currentUnmatchable),
            "current totality",
            file: file, line: line
        )
        for pair in result.matched {
            XCTAssertEqual(pair.previous.exception.kind, pair.current.kind, file: file, line: line)
        }
    }

    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
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

    // MARK: - 4. Canonical projection normalization

    func testCanonicalProjectionInitExposesNormalizedDecodedProjection() throws {
        let nfd = "cafe\u{0301}"
        let nfc = nfd.precomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(nfd.utf8), Array(nfc.utf8))

        let unsortedAttributions = [
            attribution("tx-b", amount: -2200),
            attribution("tx-a", amount: -2000),
            attribution("tx-c", budgetID: "groceries", basis: .category("food"), amount: -1000)
        ]
        let raw = periodProjection(
            observations: [
                observation(
                    id: "obs-agg",
                    statusToken: nfd,
                    aggregate: .init(basis: .structuralCandidateOnly, pairedTransactionIDs: ["tx-b", "tx-a"])
                )
            ],
            attributions: unsortedAttributions,
            uncategorized: -4200
        )
        let payload = try canonical(raw)
        let decoded = try CanonicalSemanticPeriodProjection(bytes: payload.bytes)
        XCTAssertEqual(payload.projection, decoded.projection)
        XCTAssertEqual(payload.bytes, decoded.bytes)
        XCTAssertEqual(payload.digest, decoded.digest)

        let reversed = periodProjection(
            observations: [
                observation(
                    id: "obs-agg",
                    statusToken: nfc,
                    aggregate: .init(basis: .structuralCandidateOnly, pairedTransactionIDs: ["tx-a", "tx-b"])
                )
            ],
            attributions: unsortedAttributions.reversed(),
            uncategorized: -4200
        )
        XCTAssertEqual(try canonical(reversed).bytes, payload.bytes)
        XCTAssertEqual(try canonical(reversed).projection, payload.projection)

        XCTAssertEqual(
            payload.projection.observations.first?.statusToken,
            nfc
        )
        XCTAssertEqual(
            payload.projection.observations.first?.aggregate?.pairedTransactionIDs,
            ["tx-a", "tx-b"]
        )
    }

    // MARK: - 5. OccurrenceID join convention

    func testOccurrenceIDDescriptionJoinConvention() {
        let day = Day(year: 2026, month: 8, day: 15)
        let occurrence = OccurrenceID(obligationID: "ob-rent", expectedDay: day)
        XCTAssertEqual(occurrence.description, "ob-rent@2026-08-15")
        let fact = expectation(obligation: "ob-rent", day: day)
        XCTAssertEqual(
            OccurrenceID(obligationID: fact.obligationID, expectedDay: fact.expectedDay).description,
            occurrence.description
        )
        XCTAssertEqual(occurrenceID("ob-rent", day), "ob-rent@2026-08-15")
    }

    // MARK: - 1–3, 33–34. Determinism and totality

    func testDeterministicOutputUnderInputPermutation() throws {
        let obsA = observation(id: "obs-a")
        let obsB = observation(id: "obs-b", minorUnits: -500)
        let obsC = observation(id: "obs-c", minorUnits: -700)
        let obsBChanged = observation(id: "obs-b", minorUnits: -501)
        let obsD = observation(id: "obs-d", minorUnits: -900)
        let previousProjection = periodProjection(observations: [obsA, obsB, obsC])
        let currentProjection = periodProjection(observations: [obsA, obsBChanged, obsD])
        let previous = [
            exception("obs-a", .unknownBookedEconomics),
            exception("obs-b", .unknownBookedEconomics),
            exception("obs-c", .unknownBookedEconomics)
        ]
        let current = [
            exception("obs-a", .unknownBookedEconomics),
            exception("obs-b", .unknownBookedEconomics),
            exception("obs-d", .unknownBookedEconomics)
        ]
        let expected = try match(
            previous: previous, previousProjection: previousProjection,
            current: current, currentProjection: currentProjection
        )
        for previousOrder in permutations(previous) {
            for currentOrder in permutations(current) {
                let result = try match(
                    previous: previousOrder, previousProjection: previousProjection,
                    current: currentOrder, currentProjection: currentProjection
                )
                XCTAssertEqual(result, expected)
            }
        }
    }

    /// Duplicate `(kind, id)` with differing snapshot fields must not follow
    /// caller order. The old `(kind, id)` comparator tied here.
    func testCurrentDuplicateKindAndIDOrderIsIndependentOfInputPermutation() throws {
        let unique = observation(id: "obs-unique")
        let duplicate = observation(
            id: "obs-dup",
            aggregate: .init(basis: .structuralCandidateOnly, pairedTransactionIDs: ["tx-a", "tx-b"])
        )
        let previousProjection = periodProjection(observations: [unique])
        let currentProjection = periodProjection(observations: [unique, duplicate])
        let uniqueException = exception("obs-unique", .unknownBookedEconomics)
        let source = PeriodCheckpointException(
            id: "obs-dup",
            kind: .aggregateEvidenceModelLimitation,
            aggregateBasis: .sourceEstablishedAggregateRelationship,
            day: Day(index: 20),
            amount: money(-4200)
        )
        let structural = PeriodCheckpointException(
            id: "obs-dup",
            kind: .aggregateEvidenceModelLimitation,
            aggregateBasis: .structuralCandidateOnly,
            day: Day(index: 21),
            amount: money(-4300)
        )
        XCTAssertNotEqual(source, structural)
        XCTAssertEqual(source.kind, structural.kind)
        XCTAssertEqual(source.id, structural.id)

        let expected = try match(
            previous: [uniqueException], previousProjection: previousProjection,
            current: [uniqueException, source, structural], currentProjection: currentProjection
        )
        XCTAssertEqual(expected.matched.map { $0.current.id }, ["obs-unique"])
        XCTAssertEqual(
            expected.currentUnmatched.map(\.aggregateBasis),
            [.sourceEstablishedAggregateRelationship, .structuralCandidateOnly]
        )
        XCTAssertEqual(expected.currentUnmatched.map(\.id), ["obs-dup", "obs-dup"])

        for currentOrder in permutations([uniqueException, source, structural]) {
            let result = PeriodCheckpointAcknowledgmentMatcher.match(
                previousRevision: try revision(previousProjection, acknowledgments: [uniqueException]),
                currentExceptions: currentOrder,
                currentProjection: try canonical(currentProjection)
            )
            XCTAssertEqual(result, expected)
            XCTAssertEqual(result.currentUnmatched, [source, structural])
        }
    }

    func testCurrentSameSubjectDuplicateSnapshotFieldsOrderIsIndependentOfInputPermutation() throws {
        let fact = observation(id: "obs-booked")
        let projection = periodProjection(observations: [fact])
        let earlier = PeriodCheckpointException(
            id: "obs-booked", kind: .unknownBookedEconomics, day: Day(index: 15), amount: money(-100)
        )
        let later = PeriodCheckpointException(
            id: "obs-booked", kind: .unknownBookedEconomics, day: Day(index: 16), amount: money(-200)
        )
        XCTAssertEqual(earlier.kind, later.kind)
        XCTAssertEqual(earlier.id, later.id)
        XCTAssertNotEqual(earlier, later)

        let expected = try match(
            previous: [], previousProjection: projection,
            current: [later, earlier], currentProjection: projection
        )
        XCTAssertTrue(expected.matched.isEmpty)
        XCTAssertEqual(expected.currentUnmatchable, [earlier, later])

        for currentOrder in [[earlier, later], [later, earlier]] {
            let result = PeriodCheckpointAcknowledgmentMatcher.match(
                previousRevision: try revision(projection, acknowledgments: []),
                currentExceptions: currentOrder,
                currentProjection: try canonical(projection)
            )
            XCTAssertEqual(result, expected)
            XCTAssertEqual(result.currentUnmatchable, [earlier, later])
        }
    }

    func testExtremeDayOrderIsIndependentOfInputPermutation() throws {
        let earliest = Day(year: Int.min, month: 3, day: 1)
        let ordinary = Day(year: 2000, month: 3, day: 1)
        let latest = Day(year: Int.max, month: 3, day: 1)

        // Exact crash case, then all six permutations including the lower bound.
        try assertDaySnapshotOrder([ordinary, latest])
        try assertDaySnapshotOrder([earliest, ordinary, latest])
    }

    func testDayComponentOrderAcrossRepresentableYearBoundaries() throws {
        let years = [Int.min, Int.min + 1, -1, 0, 1, 2000, Int.max - 1, Int.max]
        for year in years {
            // Same year / different month, and same year+month / different day.
            try assertDaySnapshotOrder([
                Day(year: year, month: 1, day: 31),
                Day(year: year, month: 2, day: 1),
                Day(year: year, month: 2, day: 2)
            ])
        }
        for (earlier, later) in zip(years, years.dropFirst()) {
            // Year must take precedence even when month/day run the other way.
            try assertDaySnapshotOrder([
                Day(year: earlier, month: 12, day: 31),
                Day(year: later, month: 1, day: 1)
            ])
        }
    }

    private func assertDaySnapshotOrder(
        _ orderedDays: [Day], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let ordered = orderedDays.map {
            PeriodCheckpointException(id: "extreme-day", kind: .unresolvedEvidenceLinkage, day: $0)
        }
        let projection = try canonical(periodProjection())
        let previous = try revision(periodProjection(), acknowledgments: [])
        let expected = PeriodCheckpointAcknowledgmentMatchResult(
            matched: [], currentUnmatched: [], previousDisappeared: [],
            previousUnmatchable: [], currentUnmatchable: ordered
        )
        for input in permutations(ordered) {
            let result = PeriodCheckpointAcknowledgmentMatcher.match(
                previousRevision: previous, currentExceptions: input, currentProjection: projection
            )
            XCTAssertEqual(result, expected, file: file, line: line)
        }
    }

    func testPreviousDuplicateIDsCannotConstructSupportedRevision() {
        let first = PeriodCheckpointException(
            id: "obs-dup",
            kind: .aggregateEvidenceModelLimitation,
            aggregateBasis: .sourceEstablishedAggregateRelationship
        )
        let second = PeriodCheckpointException(
            id: "obs-dup",
            kind: .aggregateEvidenceModelLimitation,
            aggregateBasis: .structuralCandidateOnly
        )
        XCTAssertThrowsError(try revision(periodProjection(), acknowledgments: [first, second])) {
            XCTAssertEqual($0 as? SemanticProjectionFormatError, .invalidRevision)
        }
        XCTAssertThrowsError(try revision(periodProjection(), acknowledgments: [second, first])) {
            XCTAssertEqual($0 as? SemanticProjectionFormatError, .invalidRevision)
        }
    }

    func testCurrentAndPreviousAmbiguityAreRepresentedSeparately() throws {
        let unique = observation(id: "obs-unique")
        let previousProjection = periodProjection(
            observations: [unique],
            attributions: [attribution("tx-a", amount: -4200)],
            uncategorized: -4200
        )
        let currentProjection = previousProjection
        let previous = [
            exception("uncategorized:one", .uncategorizedEconomicSpending),
            exception("uncategorized:two", .uncategorizedEconomicSpending),
            exception("obs-unique", .unknownBookedEconomics)
        ]
        let current = [
            exception("uncategorized:now", .uncategorizedEconomicSpending),
            exception("obs-unique", .unknownBookedEconomics)
        ]
        let result = try match(
            previous: previous, previousProjection: previousProjection,
            current: current, currentProjection: currentProjection
        )
        XCTAssertEqual(result.matched.map { $0.current.id }, ["obs-unique"])
        XCTAssertEqual(result.previousUnmatchable.map(\.exception.id).sorted(), ["uncategorized:one", "uncategorized:two"])
        XCTAssertEqual(result.currentUnmatchable.map(\.id), ["uncategorized:now"])
        XCTAssertTrue(result.previousDisappeared.isEmpty)
        XCTAssertTrue(result.currentUnmatched.isEmpty)
    }

    // MARK: - 6–10. Aggregate

    func testAggregateExactPairMatches() throws {
        let fact = observation(
            id: "obs-agg",
            aggregate: .init(basis: .structuralCandidateOnly, pairedTransactionIDs: ["tx-a", "tx-b"])
        )
        let projection = periodProjection(observations: [fact])
        let ack = exception("obs-agg", .aggregateEvidenceModelLimitation, basis: .structuralCandidateOnly)
        let result = try match(
            previous: [ack], previousProjection: projection,
            current: [ack], currentProjection: projection
        )
        XCTAssertEqual(result.matched.map { $0.current.id }, ["obs-agg"])
        XCTAssertTrue(result.currentUnmatched.isEmpty)
        XCTAssertTrue(result.previousDisappeared.isEmpty)
    }

    func testAggregatePairReorderMatchesAfterCanonicalization() throws {
        let previous = periodProjection(observations: [
            observation(
                id: "obs-agg",
                aggregate: .init(basis: .structuralCandidateOnly, pairedTransactionIDs: ["tx-b", "tx-a"])
            )
        ])
        let current = periodProjection(observations: [
            observation(
                id: "obs-agg",
                aggregate: .init(basis: .structuralCandidateOnly, pairedTransactionIDs: ["tx-a", "tx-b"])
            )
        ])
        let ack = exception("obs-agg", .aggregateEvidenceModelLimitation, basis: .structuralCandidateOnly)
        let result = try match(
            previous: [ack], previousProjection: previous,
            current: [ack], currentProjection: current
        )
        XCTAssertEqual(result.matched.map { $0.current.id }, ["obs-agg"])
    }

    func testAggregateChangedPairDoesNotMatch() throws {
        let previous = periodProjection(observations: [
            observation(
                id: "obs-agg",
                aggregate: .init(basis: .structuralCandidateOnly, pairedTransactionIDs: ["tx-a", "tx-b"])
            )
        ])
        let current = periodProjection(observations: [
            observation(
                id: "obs-agg",
                aggregate: .init(basis: .structuralCandidateOnly, pairedTransactionIDs: ["tx-a", "tx-c"])
            )
        ])
        let ack = exception("obs-agg", .aggregateEvidenceModelLimitation, basis: .structuralCandidateOnly)
        let result = try match(
            previous: [ack], previousProjection: previous,
            current: [ack], currentProjection: current
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertEqual(result.previousDisappeared.map(\.exception.id), ["obs-agg"])
        XCTAssertEqual(result.currentUnmatched.map(\.id), ["obs-agg"])
    }

    func testAggregateMultiplicityChangeDoesNotMatch() throws {
        let previous = periodProjection(observations: [
            observation(
                id: "obs-agg",
                aggregate: .init(basis: .structuralCandidateOnly, pairedTransactionIDs: ["tx-a", "tx-a", "tx-b"])
            )
        ])
        let current = periodProjection(observations: [
            observation(
                id: "obs-agg",
                aggregate: .init(basis: .structuralCandidateOnly, pairedTransactionIDs: ["tx-a", "tx-b"])
            )
        ])
        let ack = exception("obs-agg", .aggregateEvidenceModelLimitation, basis: .structuralCandidateOnly)
        let result = try match(
            previous: [ack], previousProjection: previous,
            current: [ack], currentProjection: current
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertEqual(result.previousDisappeared.map(\.exception.id), ["obs-agg"])
        XCTAssertEqual(result.currentUnmatched.map(\.id), ["obs-agg"])
    }

    func testAggregateBasisChangeDoesNotMatch() throws {
        let previous = periodProjection(observations: [
            observation(
                id: "obs-agg",
                aggregate: .init(basis: .structuralCandidateOnly, pairedTransactionIDs: ["tx-a", "tx-b"])
            )
        ])
        let current = periodProjection(observations: [
            observation(
                id: "obs-agg",
                aggregate: .init(
                    basis: .sourceEstablishedAggregateRelationship,
                    pairedTransactionIDs: ["tx-a", "tx-b"]
                )
            )
        ])
        let previousAck = exception("obs-agg", .aggregateEvidenceModelLimitation, basis: .structuralCandidateOnly)
        let currentAck = exception(
            "obs-agg", .aggregateEvidenceModelLimitation, basis: .sourceEstablishedAggregateRelationship
        )
        let result = try match(
            previous: [previousAck], previousProjection: previous,
            current: [currentAck], currentProjection: current
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertEqual(result.previousDisappeared.map(\.exception.id), ["obs-agg"])
        XCTAssertEqual(result.currentUnmatched.map(\.id), ["obs-agg"])
    }

    // MARK: - 11–18. Observation / provider

    func testExactUnknownBookedMatches() throws {
        let fact = observation(id: "obs-booked")
        let projection = periodProjection(observations: [fact])
        let ack = exception("obs-booked", .unknownBookedEconomics)
        let result = try match(
            previous: [ack], previousProjection: projection,
            current: [ack], currentProjection: projection
        )
        XCTAssertEqual(result.matched.map { $0.current.id }, ["obs-booked"])
    }

    func testObservationAmountChangeDoesNotMatch() throws {
        try assertObservationChangeDoesNotMatch(
            previous: observation(id: "obs-booked"),
            current: observation(id: "obs-booked", minorUnits: -4300)
        )
    }

    func testObservationDayChangeDoesNotMatch() throws {
        try assertObservationChangeDoesNotMatch(
            previous: observation(id: "obs-booked", day: Day(index: 15)),
            current: observation(id: "obs-booked", day: Day(index: 16))
        )
    }

    func testObservationLinksChangeDoesNotMatch() throws {
        try assertObservationChangeDoesNotMatch(
            previous: observation(id: "obs-booked"),
            current: observation(
                id: "obs-booked",
                links: [.init(transactionID: "tx-a", role: .accountMovement)]
            )
        )
    }

    func testProviderStatusChangeDoesNotMatch() throws {
        try assertObservationChangeDoesNotMatch(
            previous: observation(id: "obs-booked", statusToken: "BOOKED"),
            current: observation(id: "obs-booked", statusToken: "PDNG")
        )
    }

    func testBindingStateChangeDoesNotMatch() throws {
        let previousFact = observation(id: "obs-booked", bindingActive: true)
        let currentFact = observation(id: "obs-booked", bindingActive: false)
        let ack = exception("obs-booked", .unknownBookedEconomics)
        let withException = try match(
            previous: [ack], previousProjection: periodProjection(observations: [previousFact]),
            current: [ack], currentProjection: periodProjection(observations: [currentFact])
        )
        XCTAssertTrue(withException.matched.isEmpty)
        XCTAssertEqual(withException.previousDisappeared.map(\.exception.id), ["obs-booked"])
        XCTAssertEqual(withException.currentUnmatched.map(\.id), ["obs-booked"])

        let disappeared = try match(
            previous: [ack], previousProjection: periodProjection(observations: [previousFact]),
            current: [], currentProjection: periodProjection(observations: [currentFact])
        )
        XCTAssertTrue(disappeared.matched.isEmpty)
        XCTAssertEqual(disappeared.previousDisappeared.map(\.exception.id), ["obs-booked"])
        XCTAssertTrue(disappeared.currentUnmatched.isEmpty)
    }

    func testUnknownBookedToProviderConflictDoesNotMatch() throws {
        let fact = observation(id: "obs-shared")
        let projection = periodProjection(observations: [fact])
        let result = try match(
            previous: [exception("obs-shared", .unknownBookedEconomics)],
            previousProjection: projection,
            current: [exception("obs-shared", .providerStatusConflict)],
            currentProjection: projection
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertEqual(result.previousDisappeared.map(\.exception.kind), [.unknownBookedEconomics])
        XCTAssertEqual(result.currentUnmatched.map(\.kind), [.providerStatusConflict])
    }

    func testUnknownBookedToAggregateLimitationDoesNotMatch() throws {
        let fact = observation(
            id: "obs-shared",
            aggregate: .init(basis: .structuralCandidateOnly, pairedTransactionIDs: ["tx-a", "tx-b"])
        )
        let projection = periodProjection(observations: [fact])
        let result = try match(
            previous: [exception("obs-shared", .unknownBookedEconomics)],
            previousProjection: projection,
            current: [exception("obs-shared", .aggregateEvidenceModelLimitation, basis: .structuralCandidateOnly)],
            currentProjection: projection
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertEqual(result.previousDisappeared.map(\.exception.kind), [.unknownBookedEconomics])
        XCTAssertEqual(result.currentUnmatched.map(\.kind), [.aggregateEvidenceModelLimitation])
    }

    private func assertObservationChangeDoesNotMatch(
        previous: SemanticObservationFact,
        current: SemanticObservationFact
    ) throws {
        let ack = exception(previous.id, .unknownBookedEconomics)
        let result = try match(
            previous: [ack], previousProjection: periodProjection(observations: [previous]),
            current: [ack], currentProjection: periodProjection(observations: [current])
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertEqual(result.previousDisappeared.map(\.exception.id), [previous.id])
        XCTAssertEqual(result.currentUnmatched.map(\.id), [current.id])
    }

    // MARK: - 19–23. Uncategorized

    func testUncategorizedExactSubjectMatches() throws {
        let rows = [attribution("tx-a", amount: -2000), attribution("tx-b", amount: -2200)]
        let projection = periodProjection(attributions: rows, uncategorized: -4200)
        let ack = exception("uncategorized:period", .uncategorizedEconomicSpending)
        let result = try match(
            previous: [ack], previousProjection: projection,
            current: [ack], currentProjection: projection
        )
        XCTAssertEqual(result.matched.map { $0.current.id }, ["uncategorized:period"])
    }

    func testUncategorizedSameTotalDifferentTransactionIDsDoesNotMatch() throws {
        let previous = periodProjection(
            attributions: [attribution("tx-a", amount: -2000), attribution("tx-b", amount: -2200)],
            uncategorized: -4200
        )
        let current = periodProjection(
            attributions: [attribution("tx-c", amount: -2000), attribution("tx-d", amount: -2200)],
            uncategorized: -4200
        )
        let ack = exception("uncategorized:period", .uncategorizedEconomicSpending)
        let result = try match(
            previous: [ack], previousProjection: previous,
            current: [ack], currentProjection: current
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertEqual(result.previousDisappeared.map(\.exception.id), ["uncategorized:period"])
        XCTAssertEqual(result.currentUnmatched.map(\.id), ["uncategorized:period"])
    }

    func testUncategorizedTotalChangeDoesNotMatch() throws {
        let previous = periodProjection(attributions: [attribution("tx-a", amount: -4200)], uncategorized: -4200)
        let current = periodProjection(attributions: [attribution("tx-a", amount: -13700)], uncategorized: -13700)
        let ack = exception("uncategorized:period", .uncategorizedEconomicSpending)
        let result = try match(
            previous: [ack], previousProjection: previous,
            current: [ack], currentProjection: current
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertEqual(result.previousDisappeared.map(\.exception.id), ["uncategorized:period"])
        XCTAssertEqual(result.currentUnmatched.map(\.id), ["uncategorized:period"])
    }

    func testUncategorizedOffsettingRowChangesWithSameTotalDoNotMatch() throws {
        let previous = periodProjection(
            attributions: [attribution("tx-a", amount: -2000), attribution("tx-b", amount: -2200)],
            uncategorized: -4200
        )
        let current = periodProjection(
            attributions: [attribution("tx-a", amount: -1000), attribution("tx-b", amount: -3200)],
            uncategorized: -4200
        )
        let ack = exception("uncategorized:period", .uncategorizedEconomicSpending)
        let result = try match(
            previous: [ack], previousProjection: previous,
            current: [ack], currentProjection: current
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertEqual(result.previousDisappeared.map(\.exception.id), ["uncategorized:period"])
        XCTAssertEqual(result.currentUnmatched.map(\.id), ["uncategorized:period"])
    }

    func testUncategorizedRowInputOrderingOnlyMatches() throws {
        let previous = periodProjection(
            attributions: [attribution("tx-b", amount: -2200), attribution("tx-a", amount: -2000)],
            uncategorized: -4200
        )
        let current = periodProjection(
            attributions: [attribution("tx-a", amount: -2000), attribution("tx-b", amount: -2200)],
            uncategorized: -4200
        )
        let ack = exception("uncategorized:period", .uncategorizedEconomicSpending)
        let result = try match(
            previous: [ack], previousProjection: previous,
            current: [ack], currentProjection: current
        )
        XCTAssertEqual(result.matched.map { $0.current.id }, ["uncategorized:period"])
    }

    // MARK: - 24–28. Overdue

    func testExactOverdueOccurrenceMatches() throws {
        let day = Day(index: 20)
        let fact = expectation(obligation: "ob-rent", day: day)
        let projection = periodProjection(expectations: [fact])
        let ack = exception(occurrenceID("ob-rent", day), .overdueExpectedOccurrence)
        let result = try match(
            previous: [ack], previousProjection: projection,
            current: [ack], currentProjection: projection
        )
        XCTAssertEqual(result.matched.map { $0.current.id }, [occurrenceID("ob-rent", day)])
    }

    func testOverdueAmountChangeDoesNotMatch() throws {
        let day = Day(index: 20)
        let previous = periodProjection(expectations: [expectation(obligation: "ob-rent", day: day, minorUnits: -9000)])
        let current = periodProjection(expectations: [expectation(obligation: "ob-rent", day: day, minorUnits: -9100)])
        let ack = exception(occurrenceID("ob-rent", day), .overdueExpectedOccurrence)
        let result = try match(
            previous: [ack], previousProjection: previous,
            current: [ack], currentProjection: current
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertEqual(result.previousDisappeared.map(\.exception.id), [ack.id])
        XCTAssertEqual(result.currentUnmatched.map(\.id), [ack.id])
    }

    func testOverdueExpectedDayChangeDisappearsAndIsFresh() throws {
        let previousDay = Day(index: 20)
        let currentDay = Day(index: 21)
        let previous = periodProjection(expectations: [expectation(obligation: "ob-rent", day: previousDay)])
        let current = periodProjection(expectations: [expectation(obligation: "ob-rent", day: currentDay)])
        let previousAck = exception(occurrenceID("ob-rent", previousDay), .overdueExpectedOccurrence)
        let currentAck = exception(occurrenceID("ob-rent", currentDay), .overdueExpectedOccurrence)
        let result = try match(
            previous: [previousAck], previousProjection: previous,
            current: [currentAck], currentProjection: current
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertEqual(result.previousDisappeared.map(\.exception.id), [previousAck.id])
        XCTAssertEqual(result.currentUnmatched.map(\.id), [currentAck.id])
    }

    func testOverdueSettlementChangeDoesNotMatch() throws {
        let day = Day(index: 20)
        let previous = periodProjection(expectations: [
            expectation(obligation: "ob-rent", day: day, status: "overdue", settledBy: nil)
        ])
        let current = periodProjection(expectations: [
            expectation(obligation: "ob-rent", day: day, status: "paid", settledBy: "tx-rent")
        ])
        let ack = exception(occurrenceID("ob-rent", day), .overdueExpectedOccurrence)
        let stillPresent = try match(
            previous: [ack], previousProjection: previous,
            current: [ack], currentProjection: current
        )
        XCTAssertTrue(stillPresent.matched.isEmpty)
        XCTAssertEqual(stillPresent.previousDisappeared.map(\.exception.id), [ack.id])
        XCTAssertEqual(stillPresent.currentUnmatched.map(\.id), [ack.id])

        let gone = try match(
            previous: [ack], previousProjection: previous,
            current: [], currentProjection: current
        )
        XCTAssertEqual(gone.previousDisappeared.map(\.exception.id), [ack.id])
        XCTAssertTrue(gone.currentUnmatched.isEmpty)
    }

    func testDuplicateExpectationJoinIsAmbiguous() throws {
        let day = Day(index: 20)
        let first = expectation(obligation: "ob-rent", day: day, minorUnits: -9000)
        let second = expectation(obligation: "ob-rent", day: day, minorUnits: -8000)
        let projection = periodProjection(expectations: [first, second])
        let ack = exception(occurrenceID("ob-rent", day), .overdueExpectedOccurrence)
        let result = try match(
            previous: [ack], previousProjection: projection,
            current: [ack], currentProjection: projection
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertEqual(result.previousUnmatchable.map(\.exception.id), [ack.id])
        XCTAssertEqual(result.currentUnmatchable.map(\.id), [ack.id])
        XCTAssertTrue(result.previousDisappeared.isEmpty)
        XCTAssertTrue(result.currentUnmatched.isEmpty)
    }

    // MARK: - 29–32. Membership

    func testPreviousDisappears() throws {
        let fact = observation(id: "obs-gone")
        let ack = exception("obs-gone", .unknownBookedEconomics)
        let result = try match(
            previous: [ack], previousProjection: periodProjection(observations: [fact]),
            current: [], currentProjection: periodProjection()
        )
        XCTAssertEqual(result.previousDisappeared.map(\.exception.id), ["obs-gone"])
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertTrue(result.currentUnmatched.isEmpty)
    }

    func testNewCurrentAppears() throws {
        let fact = observation(id: "obs-new")
        let ack = exception("obs-new", .unknownBookedEconomics)
        let result = try match(
            previous: [], previousProjection: periodProjection(),
            current: [ack], currentProjection: periodProjection(observations: [fact])
        )
        XCTAssertEqual(result.currentUnmatched.map(\.id), ["obs-new"])
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertTrue(result.previousDisappeared.isEmpty)
    }

    func testPartialSurvivalABCD() throws {
        let obsA = observation(id: "obs-a")
        let obsB = observation(id: "obs-b", minorUnits: -500)
        let obsC = observation(id: "obs-c", minorUnits: -700)
        let obsBChanged = observation(id: "obs-b", minorUnits: -501)
        let obsD = observation(id: "obs-d", minorUnits: -900)
        let result = try match(
            previous: [
                exception("obs-a", .unknownBookedEconomics),
                exception("obs-b", .unknownBookedEconomics),
                exception("obs-c", .unknownBookedEconomics)
            ],
            previousProjection: periodProjection(observations: [obsA, obsB, obsC]),
            current: [
                exception("obs-a", .unknownBookedEconomics),
                exception("obs-b", .unknownBookedEconomics),
                exception("obs-d", .unknownBookedEconomics)
            ],
            currentProjection: periodProjection(observations: [obsA, obsBChanged, obsD])
        )
        XCTAssertEqual(result.matched.map { $0.current.id }, ["obs-a"])
        XCTAssertEqual(result.currentUnmatched.map(\.id), ["obs-b", "obs-d"])
        XCTAssertEqual(result.previousDisappeared.map(\.exception.id), ["obs-b", "obs-c"])
        XCTAssertTrue(result.previousUnmatchable.isEmpty)
        XCTAssertTrue(result.currentUnmatchable.isEmpty)
    }

    func testFourUnreachableKindsNeverCarry() throws {
        let unreachable: [PeriodCheckpointExceptionKind] = [
            .unresolvedEvidenceLinkage,
            .unresolvedEconomicClassification,
            .unresolvedIncomeClassificationOrOwnership,
            .acceptedReconciliationAmountDifference
        ]
        let previous = unreachable.enumerated().map { exception("u-\($0.offset)", $0.element) }
        let current = unreachable.enumerated().map { exception("u-\($0.offset)", $0.element) }
        let empty = periodProjection()
        let result = try match(
            previous: previous, previousProjection: empty,
            current: current, currentProjection: empty
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertTrue(result.currentUnmatched.isEmpty)
        XCTAssertTrue(result.previousDisappeared.isEmpty)
        XCTAssertEqual(result.previousUnmatchable.map(\.exception.kind), unreachable.sorted { $0.rawValue < $1.rawValue })
        XCTAssertEqual(result.currentUnmatchable.map(\.kind), unreachable.sorted { $0.rawValue < $1.rawValue })
        XCTAssertTrue(result.carryForwardCandidateIDs.isEmpty)
    }

    // MARK: - 25. Unchanged reverify

    func testUnchangedProjectionExactMatchesReachableKindsAndNeverCarriesUnreachable() throws {
        let day = Day(index: 20)
        let occ = occurrenceID("ob-rent", day)
        let observations = [
            observation(id: "obs-booked"),
            observation(id: "obs-conflict", statusToken: "PDNG", resolution: .linkedToTransaction),
            observation(
                id: "obs-agg",
                aggregate: .init(basis: .structuralCandidateOnly, pairedTransactionIDs: ["tx-a", "tx-b"])
            )
        ]
        let full = periodProjection(
            observations: observations,
            expectations: [expectation(obligation: "ob-rent", day: day)],
            attributions: [attribution("tx-u", amount: -4200)],
            uncategorized: -4200
        )
        XCTAssertEqual(try canonical(full).projection, try canonical(full).projection)

        let reachable = [
            exception("obs-booked", .unknownBookedEconomics),
            exception("obs-conflict", .providerStatusConflict),
            exception("obs-agg", .aggregateEvidenceModelLimitation, basis: .structuralCandidateOnly),
            exception(occ, .overdueExpectedOccurrence),
            exception("uncategorized:period", .uncategorizedEconomicSpending)
        ]
        let unreachable = [
            exception("link", .unresolvedEvidenceLinkage),
            exception("class", .unresolvedEconomicClassification),
            exception("income", .unresolvedIncomeClassificationOrOwnership),
            exception("recon", .acceptedReconciliationAmountDifference)
        ]
        let result = try match(
            previous: reachable + unreachable, previousProjection: full,
            current: reachable + unreachable, currentProjection: full
        )
        XCTAssertEqual(
            result.matched.map { $0.current.id }.sorted(),
            reachable.map(\.id).sorted()
        )
        XCTAssertEqual(result.matched.count, 5)
        XCTAssertTrue(result.currentUnmatched.isEmpty)
        XCTAssertTrue(result.previousDisappeared.isEmpty)
        XCTAssertEqual(result.previousUnmatchable.map(\.exception.kind).sorted { $0.rawValue < $1.rawValue },
                       unreachable.map(\.kind).sorted { $0.rawValue < $1.rawValue })
        XCTAssertEqual(result.currentUnmatchable.map(\.kind).sorted { $0.rawValue < $1.rawValue },
                       unreachable.map(\.kind).sorted { $0.rawValue < $1.rawValue })
    }

    // MARK: - 27. Ambiguity extras

    func testDuplicateObservationJoinIsUnmatchableNotDisappeared() throws {
        let first = observation(id: "obs-dup", minorUnits: -100)
        let second = observation(id: "obs-dup", minorUnits: -200)
        let ack = exception("obs-dup", .unknownBookedEconomics)
        let unique = exception("obs-unique", .unknownBookedEconomics)
        let uniqueFact = observation(id: "obs-unique")
        let mixedPrevious = periodProjection(observations: [first, second, uniqueFact])
        let result = try match(
            previous: [ack, unique], previousProjection: mixedPrevious,
            current: [ack, unique], currentProjection: mixedPrevious
        )
        XCTAssertEqual(result.matched.map { $0.current.id }, ["obs-unique"])
        XCTAssertEqual(result.previousUnmatchable.map(\.exception.id), ["obs-dup"])
        XCTAssertEqual(result.currentUnmatchable.map(\.id), ["obs-dup"])
        XCTAssertTrue(result.previousDisappeared.isEmpty)
        XCTAssertTrue(result.currentUnmatched.isEmpty)
    }

    func testMissingPreviousObservationIsUnmatchableNotDisappeared() throws {
        let ack = exception("obs-missing", .unknownBookedEconomics)
        let currentFact = observation(id: "obs-missing")
        let result = try match(
            previous: [ack], previousProjection: periodProjection(),
            current: [ack], currentProjection: periodProjection(observations: [currentFact])
        )
        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertEqual(result.previousUnmatchable.map(\.exception.id), ["obs-missing"])
        XCTAssertEqual(result.currentUnmatched.map(\.id), ["obs-missing"])
        XCTAssertTrue(result.previousDisappeared.isEmpty)
    }

    // MARK: - 35–38. Policy

    /// Migrated at the E2 authority repair. This test used to end by *proving
    /// the bypass worked* — assigning `Set(result.carryForwardCandidateIDs)` to
    /// `request.acknowledgedExceptionIDs` and asserting the period turned
    /// ready. That pinned the defect as intended behaviour. The request no
    /// longer has a raw identifier property to assign, so the old ending cannot
    /// be written at all; what remains is the property it was always meant to
    /// establish, now genuinely true.
    ///
    /// Matcher semantics are untouched: `carryForwardCandidateIDs` is still
    /// produced, still advisory, and still exactly what it was.
    func testMatcherResultIsCandidatesOnlyAndCannotChangeReadiness() throws {
        let fact = observation(id: "obs-booked")
        let projection = periodProjection(observations: [fact])
        let ack = exception("obs-booked", .unknownBookedEconomics)
        let interval = ReviewInterval(start: period.start, end: period.end)
        let request = PeriodCheckpointRequest(
            period: interval, kind: .monthly, asOf: interval.end,
            review: review(interval), exceptions: [ack],
            projection: projection, requiresSemanticProjection: true
        )
        let before = request
        let blocked = PeriodCheckpointEvaluator.evaluate(request)
        XCTAssertEqual(blocked.disposition, .needsDecisions)
        XCTAssertFalse(blocked.disposition.isReady)

        let result = PeriodCheckpointAcknowledgmentMatcher.match(
            previousRevision: try revision(projection, acknowledgments: [ack]),
            currentExceptions: request.exceptions,
            currentProjection: try canonical(projection)
        )
        XCTAssertEqual(result.carryForwardCandidateIDs, ["obs-booked"])
        XCTAssertEqual(request, before)
        XCTAssertEqual(request.confirmedAcknowledgments, .noDecisions)
        let after = PeriodCheckpointEvaluator.evaluate(request)
        XCTAssertEqual(after, blocked)
        XCTAssertEqual(after.disposition, .needsDecisions)

        // The candidate identifiers cannot be spent as authority. The only way
        // to reach `readyWithAcknowledgedExceptions` is the explicit
        // confirmation, which re-checks the whole subject rather than the id.
        let confirmed = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            result.carryForwardCandidates, carriedExceptions: request.exceptions
        )
        let authorized = PeriodCheckpointRequest(
            period: interval, kind: .monthly, asOf: interval.end,
            review: review(interval), exceptions: [ack],
            confirmedAcknowledgments: confirmed,
            projection: projection, requiresSemanticProjection: true
        )
        XCTAssertEqual(
            PeriodCheckpointEvaluator.evaluate(authorized).disposition,
            .readyWithAcknowledgedExceptions
        )
        // Same identifiers, subject changed underneath: confirmation refuses,
        // so there is no authority to apply at all.
        let moved = PeriodCheckpointException(
            id: "obs-booked", kind: .unknownBookedEconomics, day: Day(index: 16)
        )
        XCTAssertThrowsError(
            try PeriodCheckpointAcknowledgmentConfirmation.confirm(
                result.carryForwardCandidates, carriedExceptions: [moved]
            )
        )
    }

    func testMatcherSourceDoesNotTreatCandidatesAsConfirmedAcknowledgments() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let source = url
            .appendingPathComponent("Sources/FinanceCore/Checkpoint/PeriodCheckpointAcknowledgmentMatcher.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(text.contains("inout PeriodCheckpointRequest"))
        XCTAssertFalse(text.contains("inout PeriodCheckpointReadiness"))
        XCTAssertFalse(text.contains("PeriodCheckpointEvaluator"))
        XCTAssertFalse(text.contains("candidateCurrentIDs"))
        XCTAssertFalse(text.contains("public var confirmedAcknowledgmentIDs"))
        XCTAssertFalse(text.contains("let confirmedAcknowledgmentIDs"))
        XCTAssertTrue(text.contains("confirmedAcknowledgmentIDs"))
        XCTAssertFalse(text.contains("coverageChanged"))
        XCTAssertFalse(text.contains("merchant"))
        XCTAssertFalse(text.contains("remittance"))
        XCTAssertFalse(text.contains("IBAN"))
        XCTAssertFalse(text.contains("iban"))
        XCTAssertFalse(text.contains("account number"))
        XCTAssertFalse(text.contains("email"))
        XCTAssertTrue(text.contains("carryForwardCandidateIDs"))
        // The raw destination the old prose warned about no longer exists, so
        // the warning must not still name it: a MUST NOT about a removed
        // property reads as though the property were still there.
        XCTAssertFalse(text.contains("acknowledgedExceptionIDs"))
        XCTAssertTrue(text.contains("PeriodCheckpointConfirmedAcknowledgments"))
    }

    func testSubjectExtractionDoesNotUseSensitiveText() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let observationSource = url
            .appendingPathComponent("Sources/FinanceCore/Checkpoint/SemanticPeriodProjection.swift")
        let text = try String(contentsOf: observationSource, encoding: .utf8)
        let observationBlock = text.components(separatedBy: "public struct SemanticObservationFact")[1]
            .components(separatedBy: "public struct SemanticEvidenceLinkFact")[0]
        for forbidden in ["merchant", "remittance", "IBAN", "iban", "email", "note", "body"] {
            XCTAssertFalse(observationBlock.contains(forbidden), forbidden)
        }
    }

    func testMatcherAPITakesSupportedRevisionOnly() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let source = try String(
            contentsOf: url.appendingPathComponent(
                "Sources/FinanceCore/Checkpoint/PeriodCheckpointAcknowledgmentMatcher.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("previousRevision: PeriodCheckpointRevision"))
        XCTAssertFalse(source.contains("PeriodCheckpointStoredHeader"))
        XCTAssertFalse(source.contains("FinanceDocument"))
        XCTAssertFalse(source.contains("SemanticPeriodProjection?"))
        XCTAssertFalse(source.contains("[PeriodCheckpointRevision]"))
    }
}
