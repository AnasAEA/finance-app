import Foundation
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

/// Opt-in Phase 2.9A rehearsal against a COPY of the live store.
///
/// It skips silently when no copy is present, so the ordinary gate is
/// unaffected. It never opens the physical device container: the caller takes
/// a WAL-aware copy first, and this suite copies that copy again into its own
/// temporary directory before opening it. Nothing here writes to a device,
/// triggers a sync, or mutates financial state — the whole Phase 2.9A layer is
/// pure, which is what makes a read-only rehearsal meaningful.
///
/// The store copy is real financial data. Every expectation below is an
/// aggregate, a kind or a count. No amount, no counterparty, and no opaque identifier
/// is asserted or printed.
@Suite("Copy-only Phase 2.9A attention rehearsal")
@MainActor
struct AttentionRealStoreRehearsalTests {

    private var storeCopy: URL {
        URL(
            filePath: ProcessInfo.processInfo.environment["FINANCE_ATTENTION_STORE_COPY"]
                ?? "/nonexistent/FinanceCore-1.1.store"
        )
    }

    private let today = Day(year: 2026, month: 9, day: 3)

    /// Opens a disposable copy. The WAL and shm are carried across and the
    /// container is opened normally, because reading a copied SwiftData store
    /// with SQLite `immutable=1` skips the write-ahead log and silently loses
    /// everything committed since the last checkpoint.
    private func withCopy(_ body: (FinanceStore) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: storeCopy.path) else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attention-rehearsal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            // The container has left useCopy's scope before removing its DB,
            // WAL and shm. Also runs when copying, opening or the test throws.
            do {
                try FileManager.default.removeItem(at: directory)
                print("[2.9prereq] disposableCopyDirectoriesRemoved=1")
            }
            catch { Issue.record("Disposable rehearsal directory cleanup failed") }
        }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(filePath: storeCopy.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(
                at: source,
                to: directory.appendingPathComponent("FinanceCore-1.1.store\(suffix)")
            )
        }
        try useCopy(at: directory, body)
    }

    private func useCopy(at directory: URL, _ body: (FinanceStore) throws -> Void) throws {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(
                url: directory.appendingPathComponent("FinanceCore-1.1.store")
            )
        )
        try body(try FinanceStore(context: container.mainContext, now: fixtureInstant(today)))
    }

    @Test("The pure composition runs against the real store and stays quiet about it")
    func compositionRunsOnRealStore() throws {
        try withCopy { store in
            #expect(store.loadFailure == nil)

            let document = try store.exportDocument()
            let snapshot = store.snapshot
            let august = ReviewInterval.month(MonthKey(year: 2026, month: 8))

            let forecast = try? ForecastEngine.run(
                ForecastComposer.makeRequest(
                    from: document, startDate: today, endDate: try #require(today.advanced(by: 30))
                )
            )
            // Coverage comes from the store's own affirmative live-coverage
            // authority, the same path Insights uses. Nothing is assumed covered.
            let review = try ReviewEngine.review(
                ReviewRequest(
                    document: document, kind: .monthly, interval: august, asOf: august.end,
                    categoryKeys: store.categoryKeysByTransaction,
                    coverage: ReviewCoverageAdapter.coverageInput(
                        archiveCutoff: nil,
                        history: nil,
                        live: store.liveCoverage()
                    )
                )
            )
            let occurrences = OccurrenceExpander.occurrences(
                in: document,
                from: august.start,
                to: today,
                asOf: today,
                ledger: ReconciliationLedger(document.planning.settlements)
            )

            let output = AttentionComposition.evaluate(
                AttentionComposition.Input(
                    document: document,
                    asOf: today,
                    accountNames: Dictionary(
                        uniqueKeysWithValues: document.accounts.map { ($0.id, $0.name) }
                    ),
                    forecast: forecast,
                    review: review,
                    occurrences: occurrences,
                    observations: snapshot.syncedObservations,
                    freshness: BankFreshness.evaluate(
                        snapshot: snapshot, activity: .idle, pairing: .paired,
                        reference: snapshot.freshnessReference()
                    ),
                    categoryKeys: store.categoryKeysByTransaction,
                    period: august,
                    periodKind: .monthly,
                    periodLabel: "August"
                )
            )

            // Sanitized aggregates only. Every line below is a kind, a count or a
            // flag; identifiers and counterparties stay inside the value types.
            let secondaryKinds = output.attention.secondary.map { $0.kind.rawValue }
            let suppressedKinds = output.attention.suppressed.map {
                "\($0.kind.rawValue):\($0.eligibility)"
            }
            let blockerKinds = output.readiness.blockers.map { $0.kind.rawValue }
            let exceptionKinds = output.readiness.exceptions.map { $0.kind.rawValue }
            let exceptionImpacts = output.readiness.exceptions.map { exception -> String in
                let impact = exception.impact
                return exception.kind.rawValue
                    + ":T\(impact.compromisesTotalsCompleteness ? 1 : 0)"
                    + "C\(impact.compromisesCategoryCompleteness ? 1 : 0)"
                    + "A\(impact.compromisesAuditCompleteness ? 1 : 0)"
            }
            let claims = output.readiness.safeClaims
            let comparableDrift = output.driftFacts.filter { !$0.drift.isZero }.count

            print("[2.9A canary] outcome=\(output.attention.outcome)")
            print("[2.9A canary] primary=\(output.attention.primary?.kind.rawValue ?? "none")")
            print("[2.9A canary] secondary=\(secondaryKinds)")
            print("[2.9A canary] suppressed=\(suppressedKinds)")
            print("[2.9A canary] driftFacts=\(output.driftFacts.count) comparableNonZero=\(comparableDrift)")
            print("[2.9A canary] august=\(output.readiness.disposition.rawValue)/\(output.readiness.quality.rawValue)")
            print("[2.9A canary] blockers=\(blockerKinds)")
            print("[2.9A canary] exceptionKinds=\(exceptionKinds)")
            print("[2.9A canary] exceptionImpacts=\(exceptionImpacts)")
            print("[2.9A canary] safeClaims totals=\(claims.unquestionablyCompleteTotals) "
                  + "category=\(claims.completeCategoryAttribution) "
                  + "audit=\(claims.completeEvidenceAudit) "
                  + "mayShow=\(claims.mayShowCalculatedTotals)")
            print("[2.9A canary] firstRiskPresent=\(forecast?.firstRisk != nil)")
            print("[2.9A canary] baseline=\(output.readiness.baselineComparison)")

            // Whatever the real data holds, these must be true of it.
            #expect(output.attention.secondary.count <= 3)
            #expect(output.attention.primary?.eligibility != AttentionEligibility.suppressedBecauseNotActionable)
            // This rehearsal supplies no checkpoint baseline, so the key
            // reports that the source was never evaluated.
            #expect(
                output.availability.status(AttentionDependencyKey.periodCheckpointBaseline)
                    == AttentionSourceStatus.unavailable(.notEvaluated)
            )
            // A close action can never be proposed while no baseline exists.
            #expect(output.attention.primary?.kind != AttentionCandidateKind.monthReadyToClose)
            #expect(!output.attention.secondary.contains { $0.kind == AttentionCandidateKind.monthReadyToClose })
            // Determinism against real data, not just fixtures.
            #expect(!output.readiness.baselineComparison.isEstablished)
        }
    }

    @Test("Evaluating the real store twice gives the identical answer")
    func realStoreCompositionIsDeterministic() throws {
        try withCopy { store in
            let document = try store.exportDocument()
            let august = ReviewInterval.month(MonthKey(year: 2026, month: 8))
            let input = AttentionComposition.Input(
                document: document,
                asOf: today,
                observations: store.snapshot.syncedObservations,
                categoryKeys: store.categoryKeysByTransaction,
                period: august
            )
            let first = AttentionComposition.evaluate(input)
            let second = AttentionComposition.evaluate(input)
            let deterministic = first.attention == second.attention
                && first.readiness == second.readiness && first.driftFacts == second.driftFacts
            #expect(deterministic)
        }
    }

    /// The semantic-projection prerequisite, measured against real evidence.
    ///
    /// Reports the composition of the projection and the population the old
    /// builder would have admitted, so the difference is a measured fact
    /// rather than a claim. Every line printed is a count. No amount, no
    /// counterparty, no opaque identifier and no date leaves this test.
    @Test("The projection admits semantic evidence and excludes transport noise")
    func projectionCompositionOnRealEvidence() throws {
        try withCopy { store in
            let document = try store.exportDocument()
            let august = ReviewInterval.month(MonthKey(year: 2026, month: 8))

            let resolutions = Dictionary(
                document.observationResolutions.map { ($0.observationID, $0.state) },
                uniquingKeysWith: { first, _ in first }
            )

            // What the builder used to admit: any observation with an economic day.
            var previouslyAdmitted = 0
            var excludedOutsideBoundary = 0
            var excludedTransportOnly = 0
            var datelessRows = 0
            for observation in document.externalObservations {
                let resolution = resolutions[observation.id] ?? .unreviewed
                guard let day = observation.economicPeriodDay else { datelessRows += 1; continue }
                _ = day
                previouslyAdmitted += 1
                if resolution == .outsideSyncBoundary { excludedOutsideBoundary += 1 }
                else if observation.isTransportOnlyProvisionalSnapshot(resolution: resolution) {
                    excludedTransportOnly += 1
                }
            }
            let nowSemantic = document.externalObservations.filter {
                $0.isCheckpointSemanticObservation(resolution: resolutions[$0.id] ?? .unreviewed)
            }.count

            print("[2.9prereq] observations=\(document.externalObservations.count) "
                  + "withEconomicDay=\(previouslyAdmitted) withoutAnyProviderDate=\(datelessRows)")
            print("[2.9prereq] excluded outsideSyncBoundary=\(excludedOutsideBoundary) "
                  + "transportOnlyProvisional=\(excludedTransportOnly)")
            print("[2.9prereq] semanticObservations=\(nowSemantic)")

            // The exception-closure property, measured on real evidence: every
            // observation the adapter scopes into the period is in the projection.
            let surface = store.snapshot.syncedObservations
            let exceptionIDs = Set(
                AttentionFactAdapters.evidenceExceptions(from: surface, period: august).map(\.id)
            )
            let review = try ReviewEngine.review(
                ReviewRequest(
                    document: document, kind: .monthly, interval: august, asOf: today,
                    categoryKeys: store.categoryKeysByTransaction,
                    coverage: ReviewCoverageInput(liveCoveredIntervals: [august])
                )
            )
            let projection = SemanticPeriodProjectionBuilder.projection(
                for: august, kind: .monthly, in: document, coverage: review.coverage,
                budget: SemanticBudgetFact(review.budget),
                categoryKeys: store.categoryKeysByTransaction,
                aggregateFacts: AttentionFactAdapters.aggregateFacts(from: surface),
                expectations: []
            )
            let projectedIDs = Set(projection.observations.map(\.id))

            print("[2.9prereq] august projectionObservations=\(projectedIDs.count) "
                  + "exceptionCapable=\(exceptionIDs.count) "
                  + "exceptionOnly=\(exceptionIDs.subtracting(projectedIDs).count)")
            print("[2.9prereq] august transactions=\(projection.transactions.count) "
                  + "withCategoryKey=\(projection.transactions.filter { $0.categoryKey != nil }.count)")
            print("[2.9prereq] august aggregateFacts=\(projection.observations.filter { $0.aggregate != nil }.count)")
            print("[2.9prereq] attributionRows=\(projection.budget.attributions.count) "
                  + "refundTransactions=\(projection.transactions.filter { $0.kind == .refund }.count)")
            let attributionConsistent = projection.budget.periodEconomicSpending == review.budget.periodEconomicSpending
                && projection.budget.uncategorized == review.budget.uncategorized
                && projection.budget.attributions.count == review.budget.attributions.count
            #expect(attributionConsistent)

            let allExceptionsRepresented = exceptionIDs.subtracting(projectedIDs).isEmpty
            let outsideBoundaryExcluded = projection.observations.allSatisfy { $0.resolution != .outsideSyncBoundary }
            let transportOnlyExcluded = projection.observations.allSatisfy {
                !($0.identity == .provisionalSnapshot && $0.resolution == .provisional)
            }
            #expect(
                allExceptionsRepresented,
                "an exception-bearing observation must never be absent from its period's projection"
            )
            #expect(
                outsideBoundaryExcluded,
                "pre-cutover rows are not part of what the period means"
            )
            #expect(
                transportOnlyExcluded,
                "transport-only pending snapshots are not part of what the period means"
            )
        }
    }

    /// Adding the next sync's pending snapshot rows to real evidence must not
    /// change what any period means. Nothing is written: the extra rows are
    /// appended to an in-memory copy of the exported document.
    @Test("Real evidence plus another sync's pending rows projects identically")
    func realEvidenceIsStableAcrossPendingSnapshotChurn() throws {
        try withCopy { store in
            let document = try store.exportDocument()
            let august = ReviewInterval.month(MonthKey(year: 2026, month: 8))
            let categoryKeys = store.categoryKeysByTransaction
            func project(_ document: FinanceDocument) throws -> SemanticPeriodProjection {
                let review = try ReviewEngine.review(
                    ReviewRequest(
                        document: document, kind: .monthly, interval: august, asOf: today,
                        categoryKeys: categoryKeys,
                        coverage: ReviewCoverageInput(liveCoveredIntervals: [august])
                    )
                )
                return SemanticPeriodProjectionBuilder.projection(
                    for: august, kind: .monthly, in: document, coverage: review.coverage,
                    budget: SemanticBudgetFact(review.budget),
                    categoryKeys: categoryKeys,
                    aggregateFacts: AttentionFactAdapters.aggregateFacts(from: DomainMapper().bankingSurface(
                        document: document, transactionPresentation: [:]).observations), expectations: []
                )
            }
            guard let binding = document.externalAccountBindings.first else { return }

            var churned = document
            for run in 1...3 {
                let id = "rehearsal-pending-run\(run)"
                churned.externalObservations.append(
                    ExternalObservation(
                        id: id, bindingID: binding.id, provider: binding.provider,
                        identity: .provisionalSnapshot, status: .pending,
                        creditDebitIndicator: .debit,
                        amount: Money(minorUnits: -1_234, currency: .eur),
                        bookingDate: Day(year: 2026, month: 8, day: 30),
                        eligibleForEconomicActual: false,
                        observedAt: Date(timeIntervalSince1970: Double(1_000 * run))
                    )
                )
                churned.observationResolutions.append(
                    ExternalObservationResolution(observationID: id, state: .provisional)
                )
            }

            print("[2.9prereq] churn: observations \(document.externalObservations.count)"
                  + " -> \(churned.externalObservations.count)")
            let stable = try project(document) == project(churned)
            #expect(stable)
        }
    }

}
