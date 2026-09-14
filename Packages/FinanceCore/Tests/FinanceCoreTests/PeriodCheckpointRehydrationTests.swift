import XCTest
import Foundation
import FinanceCore

/// Synthetic historical snapshots; the read helper accepts stored fields only.
final class PeriodCheckpointRehydrationTests: XCTestCase {
    private let interval = ReviewInterval.month(MonthKey(year: 2026, month: 8))
    private var period: SemanticInterval { SemanticInterval(interval) }
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let prior = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func projection(coverage: SemanticCoverage = .complete) -> SemanticPeriodProjection {
        SemanticPeriodProjection(
            period: period, kind: .monthly, coverage: coverage,
            budget: SemanticBudgetFact(periodEconomicSpending: Money(minorUnits: 0, currency: .eur),
                                       uncategorized: Money(minorUnits: 0, currency: .eur), attributions: []),
            transactions: [], observations: [], expectations: []
        )
    }

    private var exceptions: [PeriodCheckpointException] {
        [PeriodCheckpointException(id: "synthetic-category", kind: .uncategorizedEconomicSpending,
                                   day: interval.start, amount: Money(minorUnits: 123, currency: .eur)),
         PeriodCheckpointException(id: "synthetic-aggregate", kind: .aggregateEvidenceModelLimitation,
                                   aggregateBasis: .sourceEstablishedAggregateRelationship)]
    }

    private func accepted(_ exceptions: [PeriodCheckpointException]) throws -> PeriodCheckpointRevision {
        // Only initial acceptance uses a review/evaluator. Re-opening below has neither input.
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion, documentKind: "TEST",
            accounts: [], balances: [], transactions: [],
            planning: FinanceDocument.Planning(defaultScenario: .base)
        )
        let review = try ReviewEngine.review(ReviewRequest(
            document: document, kind: .monthly, interval: interval, asOf: interval.end,
            coverage: ReviewCoverageInput(liveCoveredIntervals: [interval])
        ))
        let readiness = PeriodCheckpointEvaluator.evaluate(PeriodCheckpointRequest(
            period: interval, kind: .monthly, asOf: interval.end, review: review,
            exceptions: exceptions,
            confirmedAcknowledgments: try PeriodCheckpointAcknowledgmentConfirmation.confirm(
                decisions: exceptions, carriedExceptions: exceptions
            ),
            projection: projection(), requiresSemanticProjection: true
        ))
        XCTAssertEqual(Set(readiness.exceptions), Set(readiness.acknowledgedExceptions))
        return try PeriodCheckpointRevision(
            id: id, revisionNumber: exceptions.isEmpty ? 1 : 2,
            predecessorID: exceptions.isEmpty ? nil : prior,
            closedAt: Date(timeIntervalSince1970: 123), readiness: readiness,
            canonicalProjection: CanonicalSemanticPeriodProjection(projection())
        )
    }

    private func reopen(_ revision: PeriodCheckpointRevision) throws -> PeriodCheckpointRevision {
        try PeriodCheckpointRevision(
            rehydratingStoredSnapshot: revision.id, period: revision.period,
            periodKind: revision.periodKind, revisionNumber: revision.revisionNumber,
            predecessorID: revision.predecessorID, closedAt: revision.closedAt,
            canonicalProjection: CanonicalSemanticPeriodProjection(bytes: revision.canonicalProjection.bytes),
            acknowledgedExceptions: revision.acknowledgedExceptions,
            quality: revision.quality, safeClaims: revision.safeClaims
        )
    }

    private func assertRoundTrip(_ original: PeriodCheckpointRevision) throws {
        let restored = try reopen(original)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.period, original.period)
        XCTAssertEqual(restored.periodKind, original.periodKind)
        XCTAssertEqual(restored.revisionNumber, original.revisionNumber)
        XCTAssertEqual(restored.predecessorID, original.predecessorID)
        XCTAssertEqual(restored.closedAt, original.closedAt)
        XCTAssertEqual(restored.quality, original.quality)
        XCTAssertEqual(restored.projectionFormatVersion, original.projectionFormatVersion)
        XCTAssertEqual(restored.projectionDigest, original.projectionDigest)
        XCTAssertEqual(restored.canonicalProjection, original.canonicalProjection)
        XCTAssertEqual(restored.acknowledgedExceptions.map(\.exception), original.acknowledgedExceptions.map(\.exception))
        XCTAssertEqual(restored.safeClaims, original.safeClaims)
        let changed = SemanticPeriodProjection(
            period: period, kind: .monthly, coverage: .complete,
            budget: SemanticBudgetFact(periodEconomicSpending: Money(minorUnits: 1, currency: .eur),
                                       uncategorized: Money(minorUnits: 0, currency: .eur), attributions: []),
            transactions: [], observations: [], expectations: []
        )
        for current in [PeriodCheckpointCurrentState(original.canonicalProjection),
                        PeriodCheckpointCurrentState(try CanonicalSemanticPeriodProjection(changed)),
                        PeriodCheckpointCurrentState(period: period, kind: .monthly, limits: PeriodCheckpointComparabilityLimits(.semanticProjectionUnavailable))] {
            XCTAssertEqual(
                try PeriodCheckpointBaselineComparator.compare(baseline: .latest(PeriodCheckpointBaseline(restored)), current: current),
                try PeriodCheckpointBaselineComparator.compare(baseline: .latest(PeriodCheckpointBaseline(original)), current: current)
            )
        }
    }

    func testCleanRoundTrip() throws { try assertRoundTrip(accepted([])) }
    func testWithExceptionsRoundTrip() throws { try assertRoundTrip(accepted(exceptions)) }

    private func stored(
        period: SemanticInterval? = nil, kind: ReviewPeriodKind = .monthly,
        number: Int64 = 1, predecessor: UUID? = nil,
        closedAt: Date = Date(timeIntervalSince1970: 123),
        coverage: SemanticCoverage = .complete,
        exceptions: [PeriodCheckpointException] = [],
        quality: PeriodCheckpointQuality = .clean,
        claims: PeriodCheckpointSafeClaims = .surviving([])
    ) throws -> PeriodCheckpointRevision {
        try PeriodCheckpointRevision(
            rehydratingStoredSnapshot: id, period: period ?? self.period, periodKind: kind,
            revisionNumber: number, predecessorID: predecessor, closedAt: closedAt,
            canonicalProjection: CanonicalSemanticPeriodProjection(projection(coverage: coverage)),
            acknowledgedExceptions: exceptions.map(AcknowledgedExceptionRecord.init),
            quality: quality, safeClaims: claims
        )
    }

    private func invalid(_ body: @autoclosure () throws -> PeriodCheckpointRevision,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? SemanticProjectionFormatError, .invalidRevision, file: file, line: line)
        }
    }

    func testCompleteAcceptedSetDeterminesSafeClaimsWithoutReview() throws {
        let claims = PeriodCheckpointSafeClaims.surviving(exceptions)
        let revision = try stored(exceptions: exceptions, quality: .withExceptions, claims: claims)
        XCTAssertTrue(revision.safeClaims.unquestionablyCompleteTotals)
        XCTAssertFalse(revision.safeClaims.completeCategoryAttribution)
        XCTAssertFalse(revision.safeClaims.completeEvidenceAudit)
        for exception in exceptions {
            invalid(try stored(exceptions: exceptions, quality: .withExceptions, claims: .surviving([exception])))
        }
    }

    func testQualityMismatch() {
        invalid(try stored(quality: .withExceptions))
        invalid(try stored(exceptions: exceptions, claims: .surviving(exceptions)))
    }
    func testSafeClaimsMismatch() {
        invalid(try stored(claims: .blocked))
        invalid(try stored(exceptions: exceptions, quality: .withExceptions))
    }
    func testPeriodMismatch() {
        invalid(try stored(period: SemanticInterval(start: Day(index: 1), end: Day(index: 2))))
    }
    func testKindMismatch() { invalid(try stored(kind: .weekly)) }
    func testRevisionChainShapes() throws {
        for number: Int64 in [Int64.min, -1, 0] {
            invalid(try stored(number: number))
            invalid(try stored(number: number, predecessor: prior))
        }
        invalid(try stored(predecessor: prior))
        invalid(try stored(number: 2))
        invalid(try stored(number: Int64.max))
        XCTAssertNoThrow(try stored(number: Int64.max, predecessor: prior))
    }
    func testSelfPredecessor() { invalid(try stored(number: 2, predecessor: id)) }
    func testNonFiniteCloseTime() {
        for seconds in [Double.nan, .infinity, -.infinity] {
            invalid(try stored(closedAt: Date(timeIntervalSinceReferenceDate: seconds)))
        }
    }
    func testSameRevisionIdentityDuplicates() {
        let first = exceptions[0]
        for second in [first, PeriodCheckpointException(id: first.id, kind: .providerStatusConflict)] {
            let duplicates = [first, second]
            invalid(try stored(exceptions: duplicates, quality: .withExceptions, claims: .surviving(duplicates)))
        }
    }
    func testIncompleteCoverage() {
        invalid(try stored(coverage: .incomplete(status: .partial, missing: [period], reasons: [.sourceGap])))
    }
    func testInvalidBytesCannotBecomeValidatedInput() throws {
        let bytes = try CanonicalSemanticPeriodProjection(projection()).bytes
        XCTAssertThrowsError(try CanonicalSemanticPeriodProjection(bytes: Array(bytes.dropLast())))
        XCTAssertThrowsError(try CanonicalSemanticPeriodProjection(bytes: bytes + [32]))
        // Leading whitespace is not part of the frozen canonical grammar.
        XCTAssertThrowsError(try CanonicalSemanticPeriodProjection(bytes: [32] + bytes))
    }
}
