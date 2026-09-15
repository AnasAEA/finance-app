import Testing
import Foundation
@testable import FinanceCore
@testable import FinanceApp

/// Read-only mixed-exception correspondence. E1 is invoked only here, and
/// only to name unique appeared and disappeared subjects.
@Suite("Period verification exception correspondence")
struct PeriodVerificationCorrespondenceTests {

    private let period = ReviewInterval.month(MonthKey(year: 2026, month: 8))
    private let revisionID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!

    private func day(_ iso: String) -> Day { Day(isoString: iso)! }
    private func euro(_ minor: Int64) -> Money {
        Money(minorUnits: minor, currency: .eur)
    }

    private func observation(
        id: String,
        minorUnits: Int64 = -4_200,
        day: Day = Day(isoString: "2026-08-15")!
    ) -> SemanticObservationFact {
        SemanticObservationFact(
            id: id,
            statusToken: "BOOKED",
            identity: .durable,
            providerEligibleForEconomicActual: true,
            bindingIsActive: true,
            resolution: .unreviewed,
            minorUnits: minorUnits,
            currencyCode: "EUR",
            economicDay: day,
            links: [],
            aggregate: nil
        )
    }

    private func exception(_ id: String) -> PeriodCheckpointException {
        PeriodCheckpointException(
            id: id,
            kind: .unknownBookedEconomics,
            day: day("2026-08-15"),
            amount: euro(-4_200)
        )
    }

    private func uncategorized(_ id: String) -> PeriodCheckpointException {
        PeriodCheckpointException(
            id: id,
            kind: .uncategorizedEconomicSpending,
            amount: euro(-4_200)
        )
    }

    private func periodProjection(
        observations: [SemanticObservationFact],
        uncategorized: Int64 = 0
    ) -> SemanticPeriodProjection {
        SemanticPeriodProjection(
            period: SemanticInterval(period),
            kind: .monthly,
            coverage: .complete,
            budget: SemanticBudgetFact(
                periodEconomicSpending: euro(0),
                uncategorized: euro(uncategorized),
                attributions: []
            ),
            transactions: [],
            observations: observations,
            expectations: []
        )
    }

    private func review() throws -> ReviewResult {
        let account = Account(
            id: "account-test", name: "Test current account", currency: .eur,
            kind: .bank, supportedRails: PaymentRail.euroBankRails
        )
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account],
            balances: [
                AccountBalance(
                    accountID: account.id,
                    balance: euro(50_000),
                    asOf: period.start
                )
            ],
            planning: FinanceDocument.Planning(defaultScenario: .base)
        )
        return try ReviewEngine.review(
            ReviewRequest(
                document: document,
                kind: .monthly,
                interval: period,
                asOf: period.end,
                coverage: .liveCovered([period])
            )
        )
    }

    private func revision(
        _ projection: SemanticPeriodProjection,
        acknowledgments: [PeriodCheckpointException]
    ) throws -> PeriodCheckpointRevision {
        let payload = try CanonicalSemanticPeriodProjection(projection)
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

    private func readiness(
        exceptions: [PeriodCheckpointException],
        projection: SemanticPeriodProjection
    ) throws -> PeriodCheckpointReadiness {
        PeriodCheckpointEvaluator.evaluate(
            PeriodCheckpointRequest(
                period: period,
                kind: .monthly,
                asOf: day("2026-09-03"),
                review: try review(),
                exceptions: exceptions,
                projection: projection,
                baselineComparison: .changedSinceClose(
                    previousQuality: .withExceptions,
                    changes: .init(.evidenceChanged)
                )
            )
        )
    }

    private func explain(
        previous acknowledgments: [PeriodCheckpointException],
        previousObservations: [SemanticObservationFact],
        current: [PeriodCheckpointException],
        currentObservations: [SemanticObservationFact],
        uncategorized: Int64 = 0
    ) throws -> VerificationExceptionCorrespondence? {
        let previousProjection = periodProjection(
            observations: previousObservations, uncategorized: uncategorized
        )
        let currentProjection = periodProjection(
            observations: currentObservations, uncategorized: uncategorized
        )
        return PeriodVerificationCorrespondence.explain(
            previous: .supported(try revision(previousProjection, acknowledgments: acknowledgments)),
            current: try readiness(exceptions: current, projection: currentProjection)
        )
    }

    // MARK: - Mixed unique correspondence

    @Test("Previous A/B and current B/C names A gone and C new, not B")
    func appearedAndDisappearedAroundAStableSubject() throws {
        let a = observation(id: "obs-a", minorUnits: -2_000)
        let b = observation(id: "obs-b", minorUnits: -3_000)
        let c = observation(id: "obs-c", minorUnits: -1_500)
        let correspondence = try #require(try explain(
            previous: [exception("obs-a"), exception("obs-b")],
            previousObservations: [a, b],
            current: [exception("obs-b"), exception("obs-c")],
            currentObservations: [b, c]
        ))
        #expect(correspondence.appeared.bankMovements == 1)
        #expect(correspondence.disappeared.bankMovements == 1)
        #expect(correspondence.appeared.scheduledPayments == 0)
        #expect(correspondence.disappeared.scheduledPayments == 0)
        #expect(correspondence.appeared.otherLimitations == 0)
        #expect(correspondence.disappeared.otherLimitations == 0)
    }

    @Test("A same identifier with a changed subject is not a match")
    func sameIdentifierChangedSubjectIsNotAMatch() throws {
        let previous = observation(id: "obs-same", minorUnits: -2_000)
        let current = observation(id: "obs-same", minorUnits: -9_500)
        let correspondence = try #require(try explain(
            previous: [exception("obs-same")],
            previousObservations: [previous],
            current: [exception("obs-same")],
            currentObservations: [current]
        ))
        #expect(correspondence.appeared.bankMovements == 1)
        #expect(correspondence.disappeared.bankMovements == 1)
    }

    @Test("A surviving exact subject is not an occupancy claim")
    func matchedSurvivorIsNotAnnounced() throws {
        let fact = observation(id: "obs-stable")
        let extra = observation(id: "obs-new", minorUnits: -800)
        let correspondence = try explain(
            previous: [exception("obs-stable")],
            previousObservations: [fact],
            current: [exception("obs-stable"), exception("obs-new")],
            currentObservations: [fact, extra]
        )
        let shown = try #require(correspondence)
        #expect(shown.appeared.bankMovements == 1)
        #expect(shown.disappeared.isEmpty)
    }

    @Test("All matched survivors produce no occupancy")
    func onlyMatchedSurvivorsAreSilent() throws {
        let fact = observation(id: "obs-stable")
        let correspondence = try explain(
            previous: [exception("obs-stable")],
            previousObservations: [fact],
            current: [exception("obs-stable")],
            currentObservations: [fact]
        )
        #expect(correspondence == nil)
    }

    // MARK: - Ambiguity

    @Test("Duplicate previous uncategorized subjects produce no correspondence")
    func duplicatePreviousSubjectIsNotCorrespondence() throws {
        let unique = observation(id: "obs-unique")
        let correspondence = try explain(
            previous: [
                uncategorized("uncategorized:one"),
                uncategorized("uncategorized:two"),
                exception("obs-unique"),
            ],
            previousObservations: [unique],
            current: [
                uncategorized("uncategorized:now"),
                exception("obs-unique"),
            ],
            currentObservations: [unique],
            uncategorized: -4_200
        )
        #expect(correspondence == nil)
    }

    @Test("Duplicate current uncategorized subjects produce no appeared claim")
    func duplicateCurrentSubjectIsNotAppeared() throws {
        let unique = observation(id: "obs-unique")
        let correspondence = try explain(
            previous: [
                uncategorized("uncategorized:then"),
                exception("obs-unique"),
            ],
            previousObservations: [unique],
            current: [
                uncategorized("uncategorized:a"),
                uncategorized("uncategorized:b"),
                exception("obs-unique"),
            ],
            currentObservations: [unique],
            uncategorized: -4_200
        )
        #expect(correspondence == nil)
    }

    @Test("A previous subject missing from its projection is not treated as gone")
    func incompletePreviousSubjectIsNotDisappeared() throws {
        let currentFact = observation(id: "obs-missing")
        let correspondence = try explain(
            previous: [exception("obs-missing")],
            previousObservations: [],
            current: [exception("obs-missing")],
            currentObservations: [currentFact]
        )
        #expect(correspondence == nil)
    }

    @Test("A clean previous close does not go through mixed correspondence")
    func cleanPreviousIsNotMixedCorrespondence() throws {
        let fact = observation(id: "obs-new")
        let previousProjection = periodProjection(observations: [])
        let currentProjection = periodProjection(observations: [fact])
        let revision = try revision(previousProjection, acknowledgments: [])
        #expect(revision.quality == .clean)
        let forced = PeriodCheckpointEvaluator.evaluate(
            PeriodCheckpointRequest(
                period: period,
                kind: .monthly,
                asOf: day("2026-09-03"),
                review: try review(),
                exceptions: [exception("obs-new")],
                projection: currentProjection,
                baselineComparison: .changedSinceClose(
                    previousQuality: .clean,
                    changes: .init(.evidenceChanged)
                )
            )
        )
        #expect(PeriodVerificationCorrespondence.explain(
            previous: .supported(revision),
            current: forced
        ) == nil)
    }

    @Test("Unavailable comparison does not claim item correspondence")
    func unavailableComparisonClaimsNothing() throws {
        let fact = observation(id: "obs-a")
        let projection = periodProjection(observations: [fact])
        let revision = try revision(projection, acknowledgments: [exception("obs-a")])
        let ready = PeriodCheckpointEvaluator.evaluate(
            PeriodCheckpointRequest(
                period: period,
                kind: .monthly,
                asOf: day("2026-09-03"),
                review: try review(),
                exceptions: [exception("obs-a"), exception("obs-b")],
                projection: periodProjection(observations: [fact, observation(id: "obs-b")]),
                baselineComparison: .unavailable(.baselineProjectionUnreadable)
            )
        )
        #expect(PeriodVerificationCorrespondence.explain(
            previous: .supported(revision),
            current: ready
        ) == nil)
    }

    // MARK: - One authorized caller

    @Test("Exactly one production file calls the matcher, and it does not confirm")
    func exactlyOneReadOnlyMatcherCaller() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FinanceApp")
        let files = try #require(FileManager.default.enumerator(atPath: root.path))
        var callers: [String] = []
        for case let path as String in files where path.hasSuffix(".swift") {
            let source = try String(
                contentsOf: root.appendingPathComponent(path), encoding: .utf8
            )
            if source.contains("PeriodCheckpointAcknowledgmentMatcher") {
                callers.append(path)
            }
        }
        #expect(callers == ["Persistence/PeriodVerificationCorrespondence.swift"])

        let adapter = try String(
            contentsOf: root.appendingPathComponent(
                "Persistence/PeriodVerificationCorrespondence.swift"
            ),
            encoding: .utf8
        )
        #expect(adapter.contains("PeriodCheckpointAcknowledgmentMatcher.match("))
        for forbidden in [
            "carryForwardCandidate",
            "PeriodCheckpointConfirmedAcknowledgments",
            "confirm(",
            "selectedSubjects",
            "writeEndedMonthCheckpoint",
            "repository.store",
        ] {
            #expect(!adapter.contains(forbidden), "adapter reached \(forbidden)")
        }
    }
}
