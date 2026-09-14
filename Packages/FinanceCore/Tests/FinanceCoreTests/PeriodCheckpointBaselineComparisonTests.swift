import XCTest
import Foundation
@testable import FinanceCore

/// Phase 2.9C-B — baseline comparison and deterministic change classification.
///
/// Every fixture is synthetic. Amounts, names and identifiers are invented for
/// the test; none of them is anybody's financial data.
final class PeriodCheckpointBaselineComparisonTests: XCTestCase {

    typealias W = CheckpointWire
    typealias Class = PeriodCheckpointChangeClass

    // MARK: - Fixtures

    func money(_ units: Int64, _ code: String = "EUR", _ digits: Int = 2) -> Money {
        Money(minorUnits: units, currency: Currency(code: code, minorUnitDigits: digits))
    }
    func day(_ index: Int) -> Day { Day(index: index) }

    var period: SemanticInterval { SemanticInterval(start: day(10), end: day(40)) }

    var incompleteCoverage: SemanticCoverage {
        .incomplete(
            status: .partial,
            missing: [SemanticInterval(start: day(12), end: day(20))],
            reasons: [.sourceGap, .archiveHistoryAbsent]
        )
    }

    /// One projection carrying every V1 shape: both optional presences, all
    /// four attribution bases, several currencies and exponents.
    func fixture(coverage: SemanticCoverage = .complete) -> SemanticPeriodProjection {
        SemanticPeriodProjection(
            period: period,
            kind: .monthly,
            coverage: coverage,
            budget: SemanticBudgetFact(
                periodEconomicSpending: money(-500),
                uncategorized: money(25, "KWD", 3),
                attributions: [
                    .init(transactionID: "purchase", budgetID: "groceries",
                          basis: .category("food"), amount: money(-300)),
                    .init(transactionID: "refund", budgetID: "groceries",
                          basis: .refundOfLinkedTransaction("prior"), amount: money(120, "KWD", 3)),
                    .init(transactionID: "rent", budgetID: nil,
                          basis: .settledObligation(obligationID: "lease"), amount: money(-900)),
                    .init(transactionID: "misc", budgetID: nil,
                          basis: .unattributed, amount: money(-25, "XAF", 0))
                ]
            ),
            transactions: [
                .init(id: "purchase", day: day(15), kind: .expense, lifecycle: .cleared,
                      factivity: .observed,
                      legs: [.init(accountID: "bank", minorUnits: -300, currencyCode: "EUR")],
                      incomeSourceID: "salary", ownedMinorUnits: 300, categoryKey: "food"),
                .init(id: "rent", day: day(20), kind: .transfer, lifecycle: .reconciled,
                      factivity: .observed,
                      legs: [.init(accountID: "bank", minorUnits: -900, currencyCode: "EUR"),
                             .init(accountID: "cash", minorUnits: 900, currencyCode: "KWD")],
                      incomeSourceID: nil, ownedMinorUnits: nil, categoryKey: nil)
            ],
            observations: [
                .init(id: "obs-linked", statusToken: "BOOKED", identity: .durable,
                      providerEligibleForEconomicActual: true, bindingIsActive: true,
                      resolution: .linkedToTransaction, minorUnits: -300, currencyCode: "EUR",
                      economicDay: day(15),
                      links: [.init(transactionID: "purchase", role: .accountMovement),
                              .init(transactionID: "rent", role: .supportingEvidence)],
                      aggregate: .init(basis: .structuralCandidateOnly,
                                       pairedTransactionIDs: ["purchase", "rent"])),
                .init(id: "obs-bare", statusToken: "PENDING", identity: .provisionalSnapshot,
                      providerEligibleForEconomicActual: false, bindingIsActive: false,
                      resolution: .unreviewed, minorUnits: 0, currencyCode: "XAF",
                      economicDay: nil, links: [], aggregate: nil)
            ],
            expectations: [
                .init(obligationID: "lease", expectedDay: day(20), minorUnits: -900,
                      currencyCode: "EUR", statusToken: "paid", settledByTransactionID: "rent"),
                .init(obligationID: "utilities", expectedDay: day(25), minorUnits: -60,
                      currencyCode: "KWD", statusToken: "overdue", settledByTransactionID: nil)
            ]
        )
    }

    // MARK: - Builders

    func canonical(_ projection: SemanticPeriodProjection) throws -> CanonicalSemanticPeriodProjection {
        try CanonicalSemanticPeriodProjection(projection)
    }

    func exception(_ id: String) -> PeriodCheckpointException {
        PeriodCheckpointException(id: id, kind: .uncategorizedEconomicSpending)
    }

    func readiness(
        _ projection: SemanticPeriodProjection,
        exceptions: [PeriodCheckpointException] = [],
        blockers: [PeriodCheckpointBlocker] = []
    ) -> PeriodCheckpointReadiness {
        let disposition: PeriodCheckpointDisposition = blockers.isEmpty
            ? (exceptions.isEmpty ? .readyClean : .readyWithAcknowledgedExceptions)
            : .blocked
        return PeriodCheckpointReadiness(
            period: projection.period, kind: projection.kind, disposition: disposition,
            quality: exceptions.isEmpty ? .clean : .withExceptions, blockers: blockers,
            exceptions: exceptions, acknowledgedExceptions: exceptions, undecidedExceptions: [],
            safeClaims: blockers.isEmpty ? .surviving(exceptions) : .blocked,
            baselineComparison: .unavailable(.noBaselinePersistence), projection: projection
        )
    }

    /// A stored baseline built the only way this build can build one: a
    /// validated revision over a validated canonical payload.
    func stored(
        _ projection: SemanticPeriodProjection,
        quality: PeriodCheckpointQuality = .clean
    ) throws -> PeriodCheckpointBaselineSource {
        let exceptions = quality == .clean ? [] : [exception("synthetic-limitation")]
        let revision = try PeriodCheckpointRevision(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            revisionNumber: 1, predecessorID: nil, closedAt: Date(timeIntervalSince1970: 0),
            readiness: readiness(projection, exceptions: exceptions),
            canonicalProjection: try canonical(projection)
        )
        return .latest(PeriodCheckpointBaseline(revision))
    }

    func current(_ projection: SemanticPeriodProjection) throws -> PeriodCheckpointCurrentState {
        PeriodCheckpointCurrentState(try canonical(projection))
    }

    /// Classes the classifier derives between two projections of one period.
    ///
    /// Both sides are put through the canonical round-trip first, because that
    /// is the only form the comparator ever sees: a stored baseline is decoded
    /// canonical bytes and a current payload is re-encoded from the projection.
    /// Comparing a hand-built value against a decoded one would report the
    /// serializer's own normalization — collection order, deduplicated coverage
    /// reasons — as a change in the period.
    func classes(
        _ previous: SemanticPeriodProjection, _ current: SemanticPeriodProjection
    ) throws -> Set<Class> {
        try PeriodCheckpointChangeClassifier.classes(
            from: try canonical(previous).projection, to: try canonical(current).projection
        )
    }

    // MARK: - Baseline contract

    func testEveryStateReportsEstablishedConclusiveAndPreviousQuality() {
        let changes = PeriodCheckpointChangeClasses(.economicsChanged)
        let limits = PeriodCheckpointComparabilityLimits(.missingLiveInterval)
        let cases: [(PeriodCheckpointBaselineComparison, Bool, Bool, PeriodCheckpointQuality?)] = [
            (.unavailable(.noBaselinePersistence), false, false, nil),
            (.unavailable(.baselineProjectionUnreadable), false, false, nil),
            (.notPreviouslyClosed, true, true, nil),
            (.unchangedSinceClose(previousQuality: .clean), true, true, .clean),
            (.changedSinceClose(previousQuality: .withExceptions, changes: changes),
             true, true, .withExceptions),
            (.indeterminate(previousQuality: .clean, blockers: limits), true, false, .clean),
            (.requiresReverification(previousQuality: .withExceptions,
                                     storedFormatToken: "v2", comparisonFormat: .v1),
             true, false, .withExceptions)
        ]
        for (comparison, established, conclusive, quality) in cases {
            XCTAssertEqual(comparison.isEstablished, established, "\(comparison)")
            XCTAssertEqual(comparison.isConclusive, conclusive, "\(comparison)")
            XCTAssertEqual(comparison.previousQuality, quality, "\(comparison)")
        }
    }

    /// `isEstablished` answers "did we learn what the source says", not "may we
    /// assert unchanged". The two inconclusive-but-established states are the
    /// whole reason the distinction exists.
    func testEstablishedIsNotTheSameQuestionAsConclusive() {
        let indeterminate = PeriodCheckpointBaselineComparison.indeterminate(
            previousQuality: .clean,
            blockers: PeriodCheckpointComparabilityLimits(.coverageMetadataAbsent)
        )
        let reverify = PeriodCheckpointBaselineComparison.requiresReverification(
            previousQuality: .clean, storedFormatToken: "v2", comparisonFormat: .v1
        )
        for comparison in [indeterminate, reverify] {
            XCTAssertTrue(comparison.isEstablished)
            XCTAssertFalse(comparison.isConclusive)
        }
    }

    // MARK: - First close

    func testSuccessfulReadWithNoRevisionIsNotPreviouslyClosed() throws {
        let comparison = try PeriodCheckpointBaselineComparator.compare(
            baseline: .noRevision, current: try current(fixture())
        )
        XCTAssertEqual(comparison, .notPreviouslyClosed)
        XCTAssertTrue(comparison.isEstablished)
        XCTAssertTrue(comparison.isConclusive)
        XCTAssertNil(comparison.previousQuality)
        XCTAssertNil(comparison.changes)
    }

    /// An empty history is not a broken store. The first close is an ordinary
    /// close, never a structurally unavailable one.
    func testEmptyHistoryIsNeverReportedAsUnavailable() throws {
        let comparison = try PeriodCheckpointBaselineComparator.compare(
            baseline: .noRevision, current: try current(fixture())
        )
        if case .unavailable = comparison { XCTFail("empty history reported as unavailable") }
    }

    /// A period whose current state cannot be compared still has no prior
    /// close: emptiness is a fact about the source, not about today's evidence.
    func testNotPreviouslyClosedSurvivesAnUncomparableCurrentPeriod() throws {
        let blocked = PeriodCheckpointCurrentState(
            period: period, kind: .monthly,
            limits: PeriodCheckpointComparabilityLimits(.missingLiveInterval)
        )
        XCTAssertEqual(
            try PeriodCheckpointBaselineComparator.compare(baseline: .noRevision, current: blocked),
            .notPreviouslyClosed
        )
    }

    func testUnavailableSourcesStayUnavailable() throws {
        for reason: PeriodCheckpointBaselineComparison.Unavailability
            in [.noBaselinePersistence, .baselineProjectionUnreadable] {
            let comparison = try PeriodCheckpointBaselineComparator.compare(
                baseline: .unavailable(reason), current: try current(fixture())
            )
            XCTAssertEqual(comparison, .unavailable(reason))
            XCTAssertFalse(comparison.isEstablished)
            XCTAssertNil(comparison.previousQuality)
        }
    }

    // MARK: - Equality and previous quality

    func testIdenticalProjectionIsUnchangedAndRetainsPreviousQuality() throws {
        for quality: PeriodCheckpointQuality in [.clean, .withExceptions] {
            let comparison = try PeriodCheckpointBaselineComparator.compare(
                baseline: try stored(fixture(), quality: quality),
                current: try current(fixture())
            )
            XCTAssertEqual(comparison, .unchangedSinceClose(previousQuality: quality))
            XCTAssertEqual(comparison.previousQuality, quality)
        }
    }

    /// The historical revision's quality is an audit fact. A period that has
    /// moved since a `.withExceptions` close still reports `.withExceptions`,
    /// even though today's projection would close clean.
    func testChangedCarriesPreviousQualityNotCurrentQuality() throws {
        let moved = mutate(fixture()) { $0.budget = SemanticBudgetFact(
            periodEconomicSpending: money(-501), uncategorized: $0.budget.uncategorized,
            attributions: $0.budget.attributions
        ) }
        let comparison = try PeriodCheckpointBaselineComparator.compare(
            baseline: try stored(fixture(), quality: .withExceptions),
            current: try current(moved)
        )
        XCTAssertEqual(comparison.previousQuality, .withExceptions)
        XCTAssertEqual(comparison.changes?.classes, [.economicsChanged])
    }

    // MARK: - Change classes, one dimension at a time

    func testCoverageClassFromComparableCoverageDifference() throws {
        XCTAssertEqual(try classes(fixture(), fixture(coverage: incompleteCoverage)),
                       [.coverageChanged])
        let otherReasons = SemanticCoverage.incomplete(
            status: .partial, missing: [SemanticInterval(start: day(12), end: day(20))],
            reasons: [.sourceGap]
        )
        XCTAssertEqual(try classes(fixture(coverage: incompleteCoverage),
                                   fixture(coverage: otherReasons)), [.coverageChanged])
        let otherStatus = SemanticCoverage.incomplete(
            status: .insufficient, missing: [SemanticInterval(start: day(12), end: day(20))],
            reasons: [.sourceGap, .archiveHistoryAbsent]
        )
        XCTAssertEqual(try classes(fixture(coverage: incompleteCoverage),
                                   fixture(coverage: otherStatus)), [.coverageChanged])
    }

    func testRawTransactionEconomicsClass() throws {
        let lifecycle = mutate(fixture()) { $0.edit(transaction: "purchase") { $0.lifecycle = .reversed } }
        XCTAssertEqual(try classes(fixture(), lifecycle), [.economicsChanged])

        let economicDay = mutate(fixture()) { $0.edit(transaction: "purchase") { $0.day = Day(index: 16) } }
        XCTAssertEqual(try classes(fixture(), economicDay), [.economicsChanged])

        let membership = mutate(fixture()) { $0.transactions.removeFirst() }
        XCTAssertEqual(try classes(fixture(), membership), [.economicsChanged])

        let legs = mutate(fixture()) {
            $0.edit(transaction: "purchase") {
                $0.legs = [.init(accountID: "bank", minorUnits: -301, currencyCode: "EUR")]
            }
        }
        XCTAssertEqual(try classes(fixture(), legs), [.economicsChanged])

        let owned = mutate(fixture()) { $0.edit(transaction: "purchase") { $0.ownedMinorUnits = nil } }
        XCTAssertEqual(try classes(fixture(), owned), [.economicsChanged])
    }

    /// §8B. The projected transactions of this period are byte-identical; only
    /// the *resolved* period figure moved, because a linked original outside
    /// this period changed. That is economics, not attribution.
    func testCrossPeriodResolvedSpendingIsEconomicsWithIdenticalTransactions() throws {
        let previous = fixture()
        let moved = mutate(previous) {
            $0.budget = SemanticBudgetFact(
                periodEconomicSpending: self.money(-380),
                uncategorized: $0.budget.uncategorized,
                attributions: $0.budget.attributions
            )
        }
        XCTAssertEqual(previous.transactions, moved.transactions)
        XCTAssertEqual(previous.observations, moved.observations)
        XCTAssertEqual(previous.budget.attributions, moved.budget.attributions)
        let derived = try classes(previous, moved)
        XCTAssertTrue(derived.contains(.economicsChanged),
                      "resolved periodEconomicSpending must classify as economics")
        XCTAssertEqual(derived, [.economicsChanged])
    }

    func testBudgetAttributionClasses() throws {
        // Budget line removal.
        let removed = mutate(fixture()) { $0.budget = SemanticBudgetFact(
            periodEconomicSpending: $0.budget.periodEconomicSpending,
            uncategorized: $0.budget.uncategorized,
            attributions: Array($0.budget.attributions.dropFirst())
        ) }
        XCTAssertEqual(try classes(fixture(), removed), [.budgetAttributionChanged])

        // Budget membership change.
        let reassigned = mutate(fixture()) { projection in
            var rows = projection.budget.attributions
            rows[0] = .init(transactionID: rows[0].transactionID, budgetID: "dining",
                            basis: rows[0].basis, amount: rows[0].amount)
            projection.budget = SemanticBudgetFact(
                periodEconomicSpending: projection.budget.periodEconomicSpending,
                uncategorized: projection.budget.uncategorized, attributions: rows
            )
        }
        XCTAssertEqual(try classes(fixture(), reassigned), [.budgetAttributionChanged])

        // Attribution basis change — a refund resolved against a different original.
        let rebased = mutate(fixture()) { projection in
            var rows = projection.budget.attributions
            let refund = rows.firstIndex { $0.transactionID == "refund" }!
            rows[refund] = .init(transactionID: "refund", budgetID: rows[refund].budgetID,
                                 basis: .refundOfLinkedTransaction("a-different-original"),
                                 amount: rows[refund].amount)
            projection.budget = SemanticBudgetFact(
                periodEconomicSpending: projection.budget.periodEconomicSpending,
                uncategorized: projection.budget.uncategorized, attributions: rows
            )
        }
        XCTAssertEqual(try classes(fixture(), rebased), [.budgetAttributionChanged])

        // Uncategorized amount change.
        let uncategorized = mutate(fixture()) { $0.budget = SemanticBudgetFact(
            periodEconomicSpending: $0.budget.periodEconomicSpending,
            uncategorized: self.money(40, "KWD", 3), attributions: $0.budget.attributions
        ) }
        XCTAssertEqual(try classes(fixture(), uncategorized), [.budgetAttributionChanged])

        // Transaction recategorization — economics untouched.
        let recategorized = mutate(fixture()) {
            $0.edit(transaction: "purchase") { $0.categoryKey = "dining" }
        }
        XCTAssertEqual(try classes(fixture(), recategorized), [.budgetAttributionChanged])
    }

    func testEvidenceClasses() throws {
        let resolution = mutate(fixture()) {
            $0.edit(observation: "obs-linked") { $0.resolution = .noEconomicEffect }
        }
        XCTAssertEqual(try classes(fixture(), resolution), [.evidenceChanged])

        let links = mutate(fixture()) {
            $0.edit(observation: "obs-linked") {
                $0.links = [.init(transactionID: "purchase", role: .merchantEnrichment)]
            }
        }
        XCTAssertEqual(try classes(fixture(), links), [.evidenceChanged])

        let membership = mutate(fixture()) { $0.observations.removeAll { $0.id == "obs-bare" } }
        XCTAssertEqual(try classes(fixture(), membership), [.evidenceChanged])

        let amount = mutate(fixture()) {
            $0.edit(observation: "obs-linked") { $0.minorUnits = -299 }
        }
        XCTAssertEqual(try classes(fixture(), amount), [.evidenceChanged])
    }

    func testProviderStateClasses() throws {
        let eligibility = mutate(fixture()) {
            $0.edit(observation: "obs-linked") { $0.providerEligibleForEconomicActual = false }
        }
        XCTAssertEqual(try classes(fixture(), eligibility), [.providerStateChanged])

        let identity = mutate(fixture()) {
            $0.edit(observation: "obs-linked") { $0.identity = .provisionalSnapshot }
        }
        XCTAssertEqual(try classes(fixture(), identity), [.providerStateChanged])

        let binding = mutate(fixture()) {
            $0.edit(observation: "obs-linked") { $0.bindingIsActive = false }
        }
        XCTAssertEqual(try classes(fixture(), binding), [.providerStateChanged])

        let status = mutate(fixture()) {
            $0.edit(observation: "obs-linked") { $0.statusToken = "REJECTED" }
        }
        XCTAssertEqual(try classes(fixture(), status), [.providerStateChanged])
    }

    func testAggregateRelationshipClasses() throws {
        let basis = mutate(fixture()) {
            $0.edit(observation: "obs-linked") {
                $0.aggregate = .init(basis: .sourceEstablishedAggregateRelationship,
                                     pairedTransactionIDs: ["purchase", "rent"])
            }
        }
        XCTAssertEqual(try classes(fixture(), basis), [.aggregateRelationshipChanged])

        // Same observation, same amount, day and status, same basis — only the
        // candidate relationship moved. The limitation now refers to different
        // money, and that must not vanish.
        let paired = mutate(fixture()) {
            $0.edit(observation: "obs-linked") {
                $0.aggregate = .init(basis: .structuralCandidateOnly,
                                     pairedTransactionIDs: ["purchase", "misc"])
            }
        }
        let derived = try classes(fixture(), paired)
        XCTAssertEqual(derived, [.aggregateRelationshipChanged])

        let dropped = mutate(fixture()) {
            $0.edit(observation: "obs-linked") { $0.aggregate = nil }
        }
        XCTAssertEqual(try classes(fixture(), dropped), [.aggregateRelationshipChanged])
    }

    func testExpectationClasses() throws {
        let standings: [(String, String?)] = [
            ("skipped", nil), ("noLongerDue", nil), ("due", nil), ("overdue", nil)
        ]
        for (token, settler) in standings {
            let moved = mutate(fixture()) {
                $0.edit(expectation: "lease") {
                    $0.statusToken = token
                    $0.settledByTransactionID = settler
                }
            }
            XCTAssertEqual(try classes(fixture(), moved), [.expectationChanged], token)
        }

        let settler = mutate(fixture()) {
            $0.edit(expectation: "lease") { $0.settledByTransactionID = "purchase" }
        }
        XCTAssertEqual(try classes(fixture(), settler), [.expectationChanged])

        let amount = mutate(fixture()) {
            $0.edit(expectation: "lease") { $0.minorUnits = -901 }
        }
        XCTAssertEqual(try classes(fixture(), amount), [.expectationChanged])

        let expectedDay = mutate(fixture()) {
            $0.edit(expectation: "lease") { $0.expectedDay = Day(index: 21) }
        }
        XCTAssertEqual(try classes(fixture(), expectedDay), [.expectationChanged])

        let membership = mutate(fixture()) { $0.expectations.removeFirst() }
        XCTAssertEqual(try classes(fixture(), membership), [.expectationChanged])
    }

    // MARK: - Multi-class

    /// Exclusivity is not forced. A mutation that genuinely moves several
    /// projected dimensions reports all of them.
    func testMutationAcrossSeveralDimensionsReportsEveryClass() throws {
        let moved = mutate(fixture(coverage: .complete)) { projection in
            projection.coverage = self.incompleteCoverage
            projection.budget = SemanticBudgetFact(
                periodEconomicSpending: self.money(-450),
                uncategorized: self.money(0, "KWD", 3),
                attributions: Array(projection.budget.attributions.dropFirst())
            )
            projection.edit(transaction: "purchase") {
                $0.lifecycle = .reversed
                $0.categoryKey = "dining"
            }
            projection.edit(observation: "obs-linked") {
                $0.resolution = .noEconomicEffect
                $0.bindingIsActive = false
                $0.aggregate = nil
            }
            projection.edit(expectation: "lease") {
                $0.statusToken = "skipped"
                $0.settledByTransactionID = nil
            }
        }
        XCTAssertEqual(try classes(fixture(), moved), Set(Class.allCases))
    }

    /// One recategorization that also changes the resolved figure is both
    /// economics and attribution — two dimensions really did move.
    func testRecategorizationThatAlsoMovesResolvedSpendingIsBothClasses() throws {
        let moved = mutate(fixture()) { projection in
            projection.edit(transaction: "purchase") { $0.categoryKey = "dining" }
            projection.budget = SemanticBudgetFact(
                periodEconomicSpending: self.money(-460),
                uncategorized: projection.budget.uncategorized,
                attributions: projection.budget.attributions
            )
        }
        XCTAssertEqual(try classes(fixture(), moved),
                       [.economicsChanged, .budgetAttributionChanged])
    }

    /// A single observation mutation that moves two independent axes emits
    /// both, so a provider change is never hidden behind an evidence change.
    func testOneObservationMutationCanEmitEvidenceAndProviderState() throws {
        let moved = mutate(fixture()) {
            $0.edit(observation: "obs-linked") {
                $0.resolution = .economicallyIneligible
                $0.providerEligibleForEconomicActual = false
            }
        }
        XCTAssertEqual(try classes(fixture(), moved), [.evidenceChanged, .providerStateChanged])
    }

    // MARK: - Invariants

    func testChangeClassesCannotBeEmpty() {
        XCTAssertNil(PeriodCheckpointChangeClasses([]))
        XCTAssertEqual(PeriodCheckpointChangeClasses([.economicsChanged, .economicsChanged])?.classes,
                       [.economicsChanged])
        // Ordered by rank, never by insertion or hash seed.
        XCTAssertEqual(
            PeriodCheckpointChangeClasses([.expectationChanged, .coverageChanged, .economicsChanged])?.classes,
            [.coverageChanged, .economicsChanged, .expectationChanged]
        )
        XCTAssertNil(PeriodCheckpointComparabilityLimits([]))
        XCTAssertEqual(
            PeriodCheckpointComparabilityLimits([.sourceGap, .periodNotEnded, .sourceGap])?.blockers,
            [.periodNotEnded, .sourceGap]
        )
    }

    /// Equal digest is the only shortcut. Anything else must be explained.
    func testDigestEqualityAndDifferenceAgree() throws {
        let previous = fixture()
        XCTAssertEqual(try classes(previous, fixture()), [])
        XCTAssertEqual(try canonical(previous).digest, try canonical(fixture()).digest)
    }

    // MARK: - Version mismatch

    func testStoredFormatThisBuildCannotReadRequiresReverification() throws {
        let foreign = try PeriodCheckpointBaseline(
            period: period, periodKind: .monthly, previousQuality: .withExceptions,
            unreadableFormatToken: "v2"
        )
        let comparison = try PeriodCheckpointBaselineComparator.compare(
            baseline: .latest(foreign), current: try current(fixture())
        )
        XCTAssertEqual(comparison, .requiresReverification(
            previousQuality: .withExceptions, storedFormatToken: "v2", comparisonFormat: .v1
        ))
        XCTAssertTrue(comparison.isEstablished)
        XCTAssertFalse(comparison.isConclusive)
        XCTAssertNil(comparison.changes)
        if case .unchangedSinceClose = comparison { XCTFail("version mismatch claimed unchanged") }
        if case .changedSinceClose = comparison { XCTFail("version mismatch claimed changed") }
    }

    /// A format this build *can* read must arrive as a validated payload. The
    /// unreadable-format door does not accept V1.
    func testSupportedFormatCannotBeDeclaredUnreadable() {
        XCTAssertThrowsError(try PeriodCheckpointBaseline(
            period: period, periodKind: .monthly, previousQuality: .clean,
            unreadableFormatToken: "v1"
        )) {
            XCTAssertEqual($0 as? PeriodCheckpointComparisonError, .supportedFormatDeclaredUnreadable)
        }
    }

    /// Format incompatibility is a durable property of the stored baseline and
    /// outranks a transient current-evidence limit.
    func testVersionMismatchOutranksIndeterminateCurrentState() throws {
        let foreign = try PeriodCheckpointBaseline(
            period: period, periodKind: .monthly, previousQuality: .clean,
            unreadableFormatToken: "v2"
        )
        let blocked = PeriodCheckpointCurrentState(
            period: period, kind: .monthly,
            limits: PeriodCheckpointComparabilityLimits(.missingArchiveInterval)
        )
        let comparison = try PeriodCheckpointBaselineComparator.compare(
            baseline: .latest(foreign), current: blocked
        )
        XCTAssertEqual(comparison, .requiresReverification(
            previousQuality: .clean, storedFormatToken: "v2", comparisonFormat: .v1
        ))
    }

    // MARK: - Unreadable baseline

    /// A stored payload that cannot be read or validated is a source failure,
    /// never emptiness and never change.
    func testUnreadableStoredBaselineIsUnavailable() throws {
        let comparison = try PeriodCheckpointBaselineComparator.compare(
            baseline: .unavailable(.baselineProjectionUnreadable), current: try current(fixture())
        )
        XCTAssertEqual(comparison, .unavailable(.baselineProjectionUnreadable))
        XCTAssertNotEqual(comparison, .notPreviouslyClosed)
        XCTAssertFalse(comparison.isEstablished)
    }

    /// Malformed stored bytes never decode into a comparable baseline, so a
    /// caller cannot reach `changedSinceClose` with a corrupt payload.
    func testMalformedStoredPayloadCannotBecomeABaseline() throws {
        let bytes = try canonical(fixture()).bytes
        for corrupt in [Array(bytes.dropLast()), bytes + [110], Array(bytes.dropFirst())] {
            XCTAssertThrowsError(try CanonicalSemanticPeriodProjection(bytes: corrupt))
        }
    }

    // MARK: - Indeterminate current state

    func testBlockedCurrentPeriodIsIndeterminateNotChanged() throws {
        let blockerKinds: [PeriodCheckpointBlockerKind] = [
            .missingLiveInterval, .coverageMetadataAbsent, .archiveHistoryAbsent,
            .missingArchiveInterval, .sourceGap, .semanticProjectionUnavailable
        ]
        for kind in blockerKinds {
            let blocked = PeriodCheckpointCurrentState(
                period: period, kind: .monthly,
                limits: PeriodCheckpointComparabilityLimits(kind)
            )
            let comparison = try PeriodCheckpointBaselineComparator.compare(
                baseline: try stored(fixture()), current: blocked
            )
            XCTAssertEqual(comparison, .indeterminate(
                previousQuality: .clean,
                blockers: PeriodCheckpointComparabilityLimits(kind)
            ), "\(kind)")
            XCTAssertTrue(comparison.isEstablished)
            XCTAssertFalse(comparison.isConclusive)
            XCTAssertNil(comparison.changes)
        }
    }

    /// The end-to-end path: a real evaluator verdict, not a hand-built limit.
    /// An unknown-coverage August cannot be compared, and the projection it
    /// would have compared is beside the point.
    func testEvaluatedBlockedReadinessProducesIndeterminate() throws {
        let blocked = readiness(fixture(), blockers: [
            PeriodCheckpointBlocker(kind: .archiveHistoryAbsent),
            PeriodCheckpointBlocker(kind: .missingLiveInterval, affectedSources: ["bank"])
        ])
        let comparison = try PeriodCheckpointBaselineComparator.compare(
            baseline: try stored(fixture()), current: PeriodCheckpointCurrentState(blocked)
        )
        XCTAssertEqual(comparison, .indeterminate(
            previousQuality: .clean,
            blockers: PeriodCheckpointComparabilityLimits([.archiveHistoryAbsent, .missingLiveInterval])!
        ))
    }

    /// Blockers win even when the current projection would compare equal: a
    /// period the evaluator will not close cannot certify itself unchanged.
    func testBlockersOutrankAnEqualDigest() throws {
        let blocked = readiness(fixture(), blockers: [PeriodCheckpointBlocker(kind: .sourceGap)])
        let comparison = try PeriodCheckpointBaselineComparator.compare(
            baseline: try stored(fixture()), current: PeriodCheckpointCurrentState(blocked)
        )
        XCTAssertNotEqual(comparison, .unchangedSinceClose(previousQuality: .clean))
        XCTAssertEqual(comparison.previousQuality, .clean)
        XCTAssertFalse(comparison.isConclusive)
    }

    /// A readiness with no projection states why rather than claiming change.
    func testMissingCurrentProjectionIsIndeterminate() throws {
        let noProjection = PeriodCheckpointReadiness(
            period: period, kind: .monthly, disposition: .readyClean, quality: .clean,
            blockers: [], exceptions: [], acknowledgedExceptions: [], undecidedExceptions: [],
            safeClaims: .surviving([]),
            baselineComparison: .unavailable(.noBaselinePersistence), projection: nil
        )
        let comparison = try PeriodCheckpointBaselineComparator.compare(
            baseline: try stored(fixture()), current: PeriodCheckpointCurrentState(noProjection)
        )
        XCTAssertEqual(comparison, .indeterminate(
            previousQuality: .clean,
            blockers: PeriodCheckpointComparabilityLimits(.semanticProjectionUnavailable)
        ))
    }

    // MARK: - Period validation

    func testPeriodAndKindMismatchAreRejected() throws {
        let september = SemanticInterval(start: day(41), end: day(70))
        let other = SemanticPeriodProjection(
            period: september, kind: .monthly, coverage: .complete,
            budget: fixture().budget, transactions: fixture().transactions,
            observations: fixture().observations, expectations: fixture().expectations
        )
        XCTAssertThrowsError(try PeriodCheckpointBaselineComparator.compare(
            baseline: try stored(fixture()), current: try current(other)
        )) {
            XCTAssertEqual($0 as? PeriodCheckpointComparisonError, .periodMismatch)
        }
        XCTAssertThrowsError(try classes(fixture(), other)) {
            XCTAssertEqual($0 as? PeriodCheckpointComparisonError, .periodMismatch)
        }

        let weekly = SemanticPeriodProjection(
            period: period, kind: .weekly, coverage: .complete,
            budget: fixture().budget, transactions: fixture().transactions,
            observations: fixture().observations, expectations: fixture().expectations
        )
        XCTAssertThrowsError(try PeriodCheckpointBaselineComparator.compare(
            baseline: try stored(fixture()), current: try current(weekly)
        )) {
            XCTAssertEqual($0 as? PeriodCheckpointComparisonError, .periodKindMismatch)
        }
        XCTAssertThrowsError(try classes(fixture(), weekly)) {
            XCTAssertEqual($0 as? PeriodCheckpointComparisonError, .periodKindMismatch)
        }
    }

    // MARK: - Noise controls

    /// Nothing outside the projection can churn a baseline. These values are
    /// deliberately absent from `SemanticPeriodProjection`, so the control is
    /// that two closes built from different such state still compare equal.
    func testSemanticallyEqualProjectionsAreUnchanged() throws {
        // Different acknowledgment decisions, exceptions, quality and safe
        // claims on the two readinesses; identical projection.
        let clean = try stored(fixture(), quality: .clean)
        let carried = try stored(fixture(), quality: .withExceptions)
        for source in [clean, carried] {
            let comparison = try PeriodCheckpointBaselineComparator.compare(
                baseline: source, current: try current(fixture())
            )
            XCTAssertTrue(comparison.isConclusive)
            XCTAssertNil(comparison.changes)
        }
    }

    /// Collection order in the source document is not meaning.
    func testCollectionOrderDoesNotProduceAChange() throws {
        let reordered = mutate(fixture()) {
            $0.transactions.reverse()
            $0.observations.reverse()
            $0.expectations.reverse()
        }
        XCTAssertEqual(try classes(fixture(), reordered), [])
        XCTAssertEqual(
            try PeriodCheckpointBaselineComparator.compare(
                baseline: try stored(fixture()), current: try current(reordered)
            ),
            .unchangedSinceClose(previousQuality: .clean)
        )
    }

    /// §26. Safe claims are not a comparison dimension. Two revisions over the
    /// same projection carry different safe claims and still compare equal —
    /// the prerequisite invariant, not a new change class.
    func testSafeClaimsAreNotAChangeClass() throws {
        let clean = readiness(fixture())
        let carried = readiness(fixture(), exceptions: [exception("synthetic-limitation")])
        XCTAssertNotEqual(clean.safeClaims, carried.safeClaims)
        XCTAssertEqual(try classes(clean.projection!, carried.projection!), [])
    }

    // MARK: - Systematic field → class matrix

    /// What one canonical V1 wire position means for classification.
    enum FieldExpectation: Equatable {
        /// Comparing across a difference here is a precondition failure.
        case precondition(PeriodCheckpointComparisonError)
        /// Exactly these classes, no more and no fewer.
        case classes(Set<Class>)
    }

    /// The deliberate mapping from canonical V1 wire position to change class.
    ///
    /// Keys are wire paths: `tag[fieldIndex]` components joined by `/`, with
    /// `#` for an array element. They name *positions in the frozen V1
    /// grammar*, not Swift property names, so a Swift rename cannot silently
    /// move an entry.
    ///
    /// The matrix test asserts this table's key set equals the set of positions
    /// a full mutation walk actually reaches. A V2 field added to any record
    /// therefore fails the test until someone decides, explicitly, which class
    /// it belongs to.
    static let fieldClasses: [String: FieldExpectation] = {
        let root = "semantic-period-projection"
        var table: [String: FieldExpectation] = [
            "\(root)[1]/interval[0]/day[0]": .precondition(.periodMismatch),
            "\(root)[1]/interval[1]/day[0]": .precondition(.periodMismatch),
            "\(root)[2]": .precondition(.periodKindMismatch)
        ]
        func put(_ paths: [String], _ expected: Set<Class>) {
            for path in paths { table[path] = .classes(expected) }
        }
        put([
            "\(root)[3]",
            "\(root)[3]/incomplete[0]",
            "\(root)[3]/incomplete[1]",
            "\(root)[3]/incomplete[1]/#/interval[0]/day[0]",
            "\(root)[3]/incomplete[1]/#/interval[1]/day[0]",
            "\(root)[3]/incomplete[2]",
            "\(root)[3]/incomplete[2]/#"
        ], [.coverageChanged])

        // Resolved period spending is economics; everything else in the budget
        // record is attribution.
        put([
            "\(root)[4]/budget[0]/money[0]",
            "\(root)[4]/budget[0]/money[1]",
            "\(root)[4]/budget[0]/money[2]"
        ], [.economicsChanged])
        put([
            "\(root)[4]/budget[1]/money[0]",
            "\(root)[4]/budget[1]/money[1]",
            "\(root)[4]/budget[1]/money[2]",
            "\(root)[4]/budget[2]",
            "\(root)[4]/budget[2]/#/attribution[0]",
            "\(root)[4]/budget[2]/#/attribution[1]",
            "\(root)[4]/budget[2]/#/attribution[2]",
            "\(root)[4]/budget[2]/#/attribution[2]/category[0]",
            "\(root)[4]/budget[2]/#/attribution[2]/linked-refund[0]",
            "\(root)[4]/budget[2]/#/attribution[2]/settled-obligation[0]",
            "\(root)[4]/budget[2]/#/attribution[3]/money[0]",
            "\(root)[4]/budget[2]/#/attribution[3]/money[1]",
            "\(root)[4]/budget[2]/#/attribution[3]/money[2]"
        ], [.budgetAttributionChanged])

        put([
            "\(root)[5]",
            "\(root)[5]/#/transaction[0]",
            "\(root)[5]/#/transaction[1]/day[0]",
            "\(root)[5]/#/transaction[2]",
            "\(root)[5]/#/transaction[3]",
            "\(root)[5]/#/transaction[4]",
            "\(root)[5]/#/transaction[5]",
            "\(root)[5]/#/transaction[5]/#/leg[0]",
            "\(root)[5]/#/transaction[5]/#/leg[1]",
            "\(root)[5]/#/transaction[5]/#/leg[2]",
            "\(root)[5]/#/transaction[6]",
            "\(root)[5]/#/transaction[7]"
        ], [.economicsChanged])
        put(["\(root)[5]/#/transaction[8]"], [.budgetAttributionChanged])

        put([
            "\(root)[6]",
            "\(root)[6]/#/observation[0]",
            "\(root)[6]/#/observation[5]",
            "\(root)[6]/#/observation[6]",
            "\(root)[6]/#/observation[7]",
            "\(root)[6]/#/observation[8]",
            "\(root)[6]/#/observation[8]/day[0]",
            "\(root)[6]/#/observation[9]",
            "\(root)[6]/#/observation[9]/#/link[0]",
            "\(root)[6]/#/observation[9]/#/link[1]"
        ], [.evidenceChanged])
        put([
            "\(root)[6]/#/observation[1]",
            "\(root)[6]/#/observation[2]",
            "\(root)[6]/#/observation[3]",
            "\(root)[6]/#/observation[4]"
        ], [.providerStateChanged])
        put([
            "\(root)[6]/#/observation[10]",
            "\(root)[6]/#/observation[10]/aggregate[0]",
            "\(root)[6]/#/observation[10]/aggregate[1]",
            "\(root)[6]/#/observation[10]/aggregate[1]/#"
        ], [.aggregateRelationshipChanged])

        put([
            "\(root)[7]",
            "\(root)[7]/#/expectation[0]",
            "\(root)[7]/#/expectation[1]/day[0]",
            "\(root)[7]/#/expectation[2]",
            "\(root)[7]/#/expectation[3]",
            "\(root)[7]/#/expectation[4]",
            "\(root)[7]/#/expectation[5]"
        ], [.expectationChanged])
        return table
    }()

    /// §22 / §23 / §33. Mutate every reachable V1 wire position, and prove for
    /// each one that the digest moves *and* that the classifier names the
    /// dimension the table says it should. Reflection is deliberately not used:
    /// the walk is over the frozen wire grammar, which is the contract, and the
    /// table is written by hand so a new field cannot be mapped by accident.
    func testEveryCanonicalFieldMapsToItsChangeClass() throws {
        var visited: Set<String> = []
        var mutationCount = 0

        for coverage in [SemanticCoverage.complete, incompleteCoverage] {
            let payload = try canonical(fixture(coverage: coverage))
            let baseline = payload.projection
            let node = try CanonicalProjectionV1.node(baseline)

            for mutation in mutations(of: node, at: "") {
                visited.insert(mutation.path)
                mutationCount += 1

                let projection = try CanonicalProjectionV1.projection(mutation.node)
                let changed = try canonical(projection)
                XCTAssertNotEqual(changed.bytes, payload.bytes, mutation.path)
                XCTAssertNotEqual(changed.digest, payload.digest, mutation.path)

                guard let expectation = Self.fieldClasses[mutation.path] else {
                    XCTFail("no class mapping for V1 wire position \(mutation.path)")
                    continue
                }
                switch expectation {
                case let .precondition(error):
                    XCTAssertThrowsError(try classes(baseline, projection), mutation.path) {
                        XCTAssertEqual($0 as? PeriodCheckpointComparisonError, error, mutation.path)
                    }
                case let .classes(expected):
                    let derived = try classes(baseline, projection)
                    XCTAssertFalse(derived.isEmpty,
                                   "digest moved with no class at \(mutation.path)")
                    XCTAssertEqual(derived, expected, mutation.path)
                }
            }
        }

        XCTAssertEqual(visited, Set(Self.fieldClasses.keys),
                       "mapping table and reachable V1 wire positions disagree")
        XCTAssertGreaterThan(mutationCount, 100)
    }

    /// The same walk, through the comparator, proves the end-to-end invariant:
    /// a digest difference is always `changedSinceClose` with a non-empty class
    /// set, and never an unexplained change.
    func testDigestDifferenceAlwaysYieldsANonEmptyClassSet() throws {
        let baseline = try canonical(fixture()).projection
        let source = try stored(baseline)
        var compared = 0
        for mutation in mutations(of: try CanonicalProjectionV1.node(baseline), at: "") {
            let projection = try CanonicalProjectionV1.projection(mutation.node)
            guard case .classes = Self.fieldClasses[mutation.path] else { continue }
            let comparison = try PeriodCheckpointBaselineComparator.compare(
                baseline: source, current: try current(projection)
            )
            guard case let .changedSinceClose(quality, changes) = comparison else {
                XCTFail("expected changedSinceClose at \(mutation.path), got \(comparison)")
                continue
            }
            XCTAssertEqual(quality, .clean)
            XCTAssertFalse(changes.classes.isEmpty, mutation.path)
            compared += 1
        }
        XCTAssertGreaterThan(compared, 100)
    }

    // MARK: - Mutation walk

    struct Mutation {
        let node: W
        /// The deepest V1 wire position this mutation altered.
        let path: String
    }

    /// One replacement per variant: a leaf value, an enum case, an optional's
    /// presence, or a collection's membership. Structural tags, record arity
    /// and the format version are format-validation concerns and are covered by
    /// `CanonicalProjectionTests`.
    func mutations(of node: W, at path: String) -> [Mutation] {
        func descend(_ next: String) -> String { path.isEmpty ? next : path + "/" + next }

        switch node {
        case let .string(value):
            if value == SemanticPeriodProjectionFormat.v1.token { return [] }
            if ["EUR", "KWD", "XAF"].contains(value) {
                return [Mutation(node: .string("USD"), path: path)]
            }
            return [Mutation(node: .string(value + ":changed"), path: path)]

        case let .integer(value):
            return [Mutation(node: .integer(value + 1), path: path)]

        case let .bool(value):
            return [Mutation(node: .bool(!value), path: path)]

        case .absent:
            return [Mutation(node: .present(Self.absentReplacement(for: path)), path: path)]

        case let .present(child):
            return [Mutation(node: .absent, path: path)]
                + mutations(of: child, at: path).map {
                    Mutation(node: .present($0.node), path: $0.path)
                }

        case let .array(values):
            var result: [Mutation] = values.isEmpty
                ? []
                : [Mutation(node: .array(Array(values.dropFirst())), path: path)]
            for (index, child) in values.enumerated() {
                for mutation in mutations(of: child, at: descend("#")) {
                    var copy = values
                    copy[index] = mutation.node
                    result.append(Mutation(node: .array(copy), path: mutation.path))
                }
            }
            return result

        case let .record(tag, fields):
            var result: [Mutation] = []
            if let alternative = Self.alternatives(for: tag, fields: fields) {
                result.append(Mutation(node: alternative, path: path))
            }
            for (index, child) in fields.enumerated() {
                for mutation in mutations(of: child, at: descend("\(tag)[\(index)]")) {
                    var copy = fields
                    copy[index] = mutation.node
                    result.append(Mutation(node: .record(tag, copy), path: mutation.path))
                }
            }
            return result
        }
    }

    /// A value of the right V1 shape for an optional that is currently absent.
    static func absentReplacement(for path: String) -> W {
        if path.hasSuffix("transaction[7]") { return .integer(7) }
        if path.hasSuffix("observation[8]") { return .record("day", [.integer(0)]) }
        if path.hasSuffix("observation[10]") {
            return .record("aggregate", [.record("structuralCandidateOnly", []), .array([])])
        }
        return .string("added")
    }

    /// A different case of the same closed V1 vocabulary.
    static func alternatives(for tag: String, fields: [W]) -> W? {
        switch tag {
        case "monthly": .record("weekly", [])
        case "complete": .record("incomplete", [.record("partial", []), .array([]), .array([])])
        case "incomplete": .record("complete", [])
        case "partial": .record("insufficient", [])
        case "sourceGap": .record("missingLiveInterval", [])
        case "archiveHistoryAbsent": .record("coverageMetadataAbsent", [])
        case "expense": .record("income", [])
        case "transfer": .record("refund", [])
        case "cleared": .record("pending", [])
        case "reconciled": .record("reversed", [])
        case "observed": .record("expected", [])
        case "durable": .record("provisionalSnapshot", [])
        case "provisionalSnapshot": .record("durable", [])
        case "linkedToTransaction": .record("unreviewed", [])
        case "unreviewed": .record("noEconomicEffect", [])
        case "accountMovement": .record("merchantEnrichment", [])
        case "supportingEvidence": .record("accountMovement", [])
        case "structuralCandidateOnly": .record("sourceEstablishedAggregateRelationship", [])
        case "paid": .record("skipped", [])
        case "overdue": .record("due", [])
        case "unattributed": .record("category", [.string("food")])
        case "category": .record("linked-refund", fields)
        case "linked-refund": .record("settled-obligation", fields)
        case "settled-obligation": .record("category", fields)
        default: nil
        }
    }
    // MARK: - Value editing helpers

    /// A projection opened for editing and rebuilt through its own
    /// initializer, so every variant is normalized exactly as a real one is.
    ///
    /// Facts are addressed by identity, never by position. The projection
    /// sorts its own collections, so `observations[0]` is whichever id sorts
    /// first — an index-addressed edit silently becomes a no-op the moment a
    /// fixture gains a fact, and a no-op mutation makes a change test pass for
    /// the wrong reason.
    struct ProjectionDraft {
        var coverage: SemanticCoverage
        var budget: SemanticBudgetFact
        var transactions: [SemanticTransactionFact]
        var observations: [SemanticObservationFact]
        var expectations: [SemanticExpectationFact]

        mutating func edit(transaction id: String, _ edit: (inout TransactionDraft) -> Void) {
            let index = transactions.firstIndex { $0.id == id }!
            let fact = transactions[index]
            var draft = TransactionDraft(
                id: fact.id, day: fact.day, kind: fact.kind, lifecycle: fact.lifecycle,
                factivity: fact.factivity, legs: fact.legs, incomeSourceID: fact.incomeSourceID,
                ownedMinorUnits: fact.ownedMinorUnits, categoryKey: fact.categoryKey
            )
            edit(&draft)
            transactions[index] = SemanticTransactionFact(
                id: draft.id, day: draft.day, kind: draft.kind, lifecycle: draft.lifecycle,
                factivity: draft.factivity, legs: draft.legs,
                incomeSourceID: draft.incomeSourceID,
                ownedMinorUnits: draft.ownedMinorUnits, categoryKey: draft.categoryKey
            )
        }

        mutating func edit(observation id: String, _ edit: (inout ObservationDraft) -> Void) {
            let index = observations.firstIndex { $0.id == id }!
            let fact = observations[index]
            var draft = ObservationDraft(
                id: fact.id, statusToken: fact.statusToken, identity: fact.identity,
                providerEligibleForEconomicActual: fact.providerEligibleForEconomicActual,
                bindingIsActive: fact.bindingIsActive, resolution: fact.resolution,
                minorUnits: fact.minorUnits, currencyCode: fact.currencyCode,
                economicDay: fact.economicDay, links: fact.links, aggregate: fact.aggregate
            )
            edit(&draft)
            observations[index] = SemanticObservationFact(
                id: draft.id, statusToken: draft.statusToken, identity: draft.identity,
                providerEligibleForEconomicActual: draft.providerEligibleForEconomicActual,
                bindingIsActive: draft.bindingIsActive, resolution: draft.resolution,
                minorUnits: draft.minorUnits, currencyCode: draft.currencyCode,
                economicDay: draft.economicDay, links: draft.links, aggregate: draft.aggregate
            )
        }

        mutating func edit(expectation id: String, _ edit: (inout ExpectationDraft) -> Void) {
            let index = expectations.firstIndex { $0.obligationID == id }!
            let fact = expectations[index]
            var draft = ExpectationDraft(
                obligationID: fact.obligationID, expectedDay: fact.expectedDay,
                minorUnits: fact.minorUnits, currencyCode: fact.currencyCode,
                statusToken: fact.statusToken,
                settledByTransactionID: fact.settledByTransactionID
            )
            edit(&draft)
            expectations[index] = SemanticExpectationFact(
                obligationID: draft.obligationID, expectedDay: draft.expectedDay,
                minorUnits: draft.minorUnits, currencyCode: draft.currencyCode,
                statusToken: draft.statusToken,
                settledByTransactionID: draft.settledByTransactionID
            )
        }
    }

    struct TransactionDraft {
        var id: String
        var day: Day
        var kind: TransactionKind
        var lifecycle: TransactionLifecycle
        var factivity: Factivity
        var legs: [SemanticLegFact]
        var incomeSourceID: String?
        var ownedMinorUnits: Int64?
        var categoryKey: String?
    }

    struct ObservationDraft {
        var id: String
        var statusToken: String
        var identity: ExternalObservationIdentity
        var providerEligibleForEconomicActual: Bool
        var bindingIsActive: Bool
        var resolution: ObservationResolutionState
        var minorUnits: Int64
        var currencyCode: String
        var economicDay: Day?
        var links: [SemanticEvidenceLinkFact]
        var aggregate: SemanticAggregateFact?
    }

    struct ExpectationDraft {
        var obligationID: String
        var expectedDay: Day
        var minorUnits: Int64
        var currencyCode: String
        var statusToken: String
        var settledByTransactionID: String?
    }

    func mutate(
        _ projection: SemanticPeriodProjection, _ edit: (inout ProjectionDraft) -> Void
    ) -> SemanticPeriodProjection {
        var draft = ProjectionDraft(
            coverage: projection.coverage, budget: projection.budget,
            transactions: projection.transactions, observations: projection.observations,
            expectations: projection.expectations
        )
        edit(&draft)
        return SemanticPeriodProjection(
            period: projection.period, kind: projection.kind, coverage: draft.coverage,
            budget: draft.budget, transactions: draft.transactions,
            observations: draft.observations, expectations: draft.expectations
        )
    }
}
