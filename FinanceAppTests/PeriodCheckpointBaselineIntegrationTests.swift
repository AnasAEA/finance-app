import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

/// Phase 2.9C-D — stored checkpoint history is the product's baseline.
///
/// What this suite proves is a *wiring* claim, not a comparison claim: the
/// comparison rules belong to `PeriodCheckpointBaselineComparator` and are
/// tested exhaustively in FinanceCore. What was missing until now is that the
/// product asked the question at all — the baseline dependency was pinned to a
/// placeholder, so every period reported an unestablished baseline whatever
/// its history said.
///
/// So these tests run the real production path —
/// `PeriodCheckpointRepository` → `PeriodCheckpointBaselineReader` →
/// `AttentionComposition.readiness` → `PeriodCheckpointReadiness.baselineComparison`
/// — against a real `ModelContainer` holding real stored revisions.
///
/// Every store is temporary and synthetic. No real store is opened, copied or
/// written, and nothing here closes a period: the fixtures write revisions
/// through the storage primitive, which is still the only writer that exists.
@MainActor
@Suite("Stored checkpoint history is the production baseline")
struct PeriodCheckpointBaselineIntegrationTests {

    // MARK: - Periods and days

    private static let july = ReviewInterval.month(MonthKey(year: 2026, month: 7))
    private static let august = ReviewInterval.month(MonthKey(year: 2026, month: 8))
    private static let september = ReviewInterval.month(MonthKey(year: 2026, month: 9))

    /// After August ended, so the period is closeable on its own terms.
    private let asOf = Day(year: 2026, month: 9, day: 3)
    private let closedAt = Date(timeIntervalSinceReferenceDate: 810_000_000)

    private func day(_ iso: String) -> Day {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        return Day(year: parts[0], month: parts[1], day: parts[2])
    }

    private func euro(_ minorUnits: Int64) -> Money {
        Money(minorUnits: minorUnits, currency: .eur)
    }

    // MARK: - The document under comparison

    /// One account, one observed August receipt, one bank-bound observation.
    ///
    /// Small on purpose: every mutation below moves exactly one projected
    /// dimension, so a change class that appears is a class that was really
    /// derived rather than a side effect of a busy fixture.
    private func document(
        incomeMinor: Int64 = 2_000,
        observationEligible: Bool = true,
        observationResolution: ObservationResolutionState = .noEconomicEffect
    ) -> FinanceDocument {
        let bank = Account(
            id: "bank", name: "Current", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 0
        )
        var document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [bank],
            balances: [
                AccountBalance(accountID: "bank", balance: euro(44_747), asOf: day("2026-08-01"))
            ]
        )
        // Income, so the period carries no uncategorised spending and is
        // therefore genuinely clean — which is what lets a stored
        // `withExceptions` quality be told apart from a recomputed one.
        document.transactions = [
            Transaction(
                id: "tx-august",
                date: day("2026-08-05"),
                kind: .income,
                legs: [AccountLeg(accountID: "bank", amount: euro(incomeMinor))],
                factivity: .observed
            )
        ]
        document.externalAccountBindings = [
            ExternalAccountBinding(
                id: "binding", provider: .bnp,
                remoteOpaqueAccountID: "synthetic-remote", localAccountID: "bank",
                syncStartBoundary: day("2026-01-01"),
                createdAt: Date(timeIntervalSince1970: 0)
            )
        ]
        document.externalObservations = [
            ExternalObservation(
                id: "observation", bindingID: "binding", provider: .bnp,
                identity: .durable, status: .booked, creditDebitIndicator: .debit,
                amount: euro(-2_000), bookingDate: day("2026-08-15"),
                eligibleForEconomicActual: observationEligible,
                observedAt: Date(timeIntervalSince1970: 1_000)
            )
        ]
        document.observationResolutions = [
            ExternalObservationResolution(
                observationID: "observation", state: observationResolution
            )
        ]
        return document
    }

    /// A settled August occurrence: it projects as an expectation and carries
    /// no exception, so adding it moves one dimension and nothing else.
    private func settledOccurrence() -> ExpectedOccurrence {
        ExpectedOccurrence(
            obligationID: "rent",
            name: "Rent",
            expectedDay: day("2026-08-05"),
            amount: euro(20_000),
            requirement: .euroBankPayment(),
            spendingClass: .essential,
            status: .paid(actualTransactionID: "tx-august")
        )
    }

    /// One real review, produced by the authoritative engine.
    ///
    /// `ReviewResult` has no public memberwise initialiser — it is something
    /// the engine produces, not something a caller assembles — so the fixture
    /// runs the engine and the checkpoint consumes what production would hand
    /// it.
    private func review(
        _ document: FinanceDocument,
        interval: ReviewInterval,
        coverage: ReviewCoverageInput?
    ) throws -> ReviewResult {
        try ReviewEngine.review(
            ReviewRequest(
                document: document,
                kind: .monthly,
                interval: interval,
                asOf: asOf,
                coverage: coverage ?? .liveCovered([interval])
            )
        )
    }

    // MARK: - The production composition

    private func input(
        _ document: FinanceDocument,
        baseline: PeriodCheckpointBaselineSource,
        interval: ReviewInterval? = nil,
        coverage: ReviewCoverageInput? = nil,
        occurrences: [ExpectedOccurrence] = []
    ) throws -> AttentionComposition.Input {
        let interval = interval ?? Self.august
        return AttentionComposition.Input(
            document: document,
            asOf: asOf,
            review: try review(document, interval: interval, coverage: coverage),
            occurrences: occurrences,
            observations: [],
            categoryKeys: [:],
            checkpointBaseline: baseline,
            period: interval,
            periodKind: .monthly,
            periodLabel: "August"
        )
    }

    private func readiness(
        _ document: FinanceDocument,
        baseline: PeriodCheckpointBaselineSource,
        interval: ReviewInterval? = nil,
        coverage: ReviewCoverageInput? = nil,
        occurrences: [ExpectedOccurrence] = []
    ) throws -> PeriodCheckpointReadiness {
        AttentionComposition.readiness(
            for: try input(
                document, baseline: baseline, interval: interval,
                coverage: coverage, occurrences: occurrences
            )
        )
    }

    /// The comparison the product would hold for this document and history.
    private func comparison(
        _ document: FinanceDocument,
        baseline: PeriodCheckpointBaselineSource,
        interval: ReviewInterval? = nil,
        coverage: ReviewCoverageInput? = nil,
        occurrences: [ExpectedOccurrence] = []
    ) throws -> PeriodCheckpointBaselineComparison {
        try readiness(
            document, baseline: baseline, interval: interval,
            coverage: coverage, occurrences: occurrences
        ).baselineComparison
    }

    // MARK: - Real persistence

    @MainActor
    private struct Harness {
        let container: ModelContainer

        init() throws {
            container = try ModelContainer(
                for: Schema(FinanceSchema.models),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }

        var context: ModelContext { container.mainContext }

        /// A fresh repository — and so a fresh `ModelContext` — per call, so a
        /// read after a direct row edit is never answered from a stale cache.
        func repository() -> PeriodCheckpointRepository {
            PeriodCheckpointRepository(
                context: container.mainContext,
                makeDatasetIdentity: { CheckpointFixtures.datasetIdentity },
                now: { Date(timeIntervalSinceReferenceDate: 810_000_000) }
            )
        }

        func rows<T: PersistentModel>(_ type: T.Type) throws -> [T] {
            try context.fetch(FetchDescriptor<T>())
        }

        func revisionRow(_ id: UUID) throws -> StoredPeriodCheckpointRevision {
            let identifier = id.uuidString
            return try context.fetch(
                FetchDescriptor<StoredPeriodCheckpointRevision>(
                    predicate: #Predicate { $0.identifier == identifier }
                )
            )[0]
        }

        func save() throws { try context.save() }

        /// Exactly the production read: one exact period, through the one
        /// production adapter.
        func baseline(
            _ interval: ReviewInterval, kind: ReviewPeriodKind = .monthly
        ) -> PeriodCheckpointBaselineSource {
            baseline(SemanticInterval(interval), kind: kind)
        }

        func baseline(
            _ period: SemanticInterval, kind: ReviewPeriodKind = .monthly
        ) -> PeriodCheckpointBaselineSource {
            PeriodCheckpointBaselineReader.source(
                from: repository(), period: period, kind: kind
            )
        }
    }

    /// A closed revision recording exactly the state this readiness projects.
    ///
    /// Assembled through the rehydration initializer because a
    /// `PeriodCheckpointReadiness` carrying an accepted decision is not
    /// publicly constructible and no close action exists to produce one. That
    /// is a fixture shape: production writes no revision in this phase, which
    /// `PeriodCheckpointBoundaryTests` holds from outside by reading the source.
    private func revision(
        recording readiness: PeriodCheckpointReadiness,
        id: UUID = UUID(),
        revisionNumber: Int64 = 1,
        predecessorID: UUID? = nil,
        exceptions: [PeriodCheckpointException] = []
    ) throws -> PeriodCheckpointRevision {
        let projection = try #require(readiness.projection)
        return try PeriodCheckpointRevision(
            rehydratingStoredSnapshot: id,
            period: readiness.period,
            periodKind: readiness.kind,
            revisionNumber: revisionNumber,
            predecessorID: predecessorID,
            closedAt: closedAt,
            canonicalProjection: try CanonicalSemanticPeriodProjection(projection),
            acknowledgedExceptions: exceptions.map(AcknowledgedExceptionRecord.init),
            quality: exceptions.isEmpty ? .clean : .withExceptions,
            safeClaims: .surviving(exceptions)
        )
    }

    /// The revision a store would hold if this document's period had been
    /// closed exactly as it stands.
    @discardableResult
    private func storeClose(
        _ interval: ReviewInterval,
        of document: FinanceDocument,
        in harness: Harness,
        id: UUID = UUID(),
        exceptions: [PeriodCheckpointException] = []
    ) throws -> UUID {
        let closed = try readiness(document, baseline: .noRevision, interval: interval)
        #expect(closed.blockers.isEmpty, "the fixture period must be comparable")
        try harness.repository().store(
            try revision(recording: closed, id: id, exceptions: exceptions)
        )
        return id
    }

    // MARK: - A / B — no stored checkpoint

    @Test("A: an empty history is 'never closed', not an unavailable baseline")
    func emptyHistoryIsNotPreviouslyClosed() throws {
        let harness = try Harness()
        let comparison = try comparison(document(), baseline: harness.baseline(Self.august))

        #expect(comparison == .notPreviouslyClosed)
        #expect(comparison.isEstablished)
        #expect(comparison.isConclusive)
        #expect(comparison.previousQuality == nil)
    }

    @Test("B: a blocked current period with no history is still a first close")
    func blockedCurrentPeriodWithNoHistoryStaysFirstClose() throws {
        let harness = try Harness()
        let readiness = try readiness(
            document(), baseline: harness.baseline(Self.august), coverage: .absent
        )

        // The current period genuinely cannot be closed…
        #expect(readiness.disposition == .blocked)
        #expect(!readiness.blockers.isEmpty)
        // …and that is not a reason to invent a baseline it does not have.
        #expect(readiness.baselineComparison == .notPreviouslyClosed)
    }

    // MARK: - C / D — unchanged

    @Test("C: an identical current period is unchanged since a clean close")
    func identicalCurrentPeriodIsUnchanged() throws {
        let harness = try Harness()
        try storeClose(Self.august, of: document(), in: harness)

        #expect(
            try comparison(document(), baseline: harness.baseline(Self.august))
                == .unchangedSinceClose(previousQuality: .clean)
        )
    }

    @Test("D: a close carrying acknowledged exceptions keeps its recorded quality")
    func acknowledgedExceptionsSurviveAsPreviousQuality() throws {
        let harness = try Harness()
        try storeClose(
            Self.august, of: document(), in: harness,
            exceptions: CheckpointFixtures.exceptions
        )

        let comparison = try comparison(document(), baseline: harness.baseline(Self.august))
        #expect(comparison == .unchangedSinceClose(previousQuality: .withExceptions))
        #expect(comparison.previousQuality == .withExceptions)
        // The historical quality is carried, never recomputed: today's period
        // carries no exception at all and still reports `withExceptions`.
        let today = try readiness(document(), baseline: .noRevision)
        #expect(today.quality == .clean)
        #expect(today.exceptions.isEmpty)
    }

    // MARK: - E / F / G — changed

    @Test("E: a moved amount is an economic change")
    func movedAmountIsEconomicChange() throws {
        let harness = try Harness()
        try storeClose(Self.august, of: document(), in: harness)

        let comparison = try comparison(
            document(incomeMinor: 3_500), baseline: harness.baseline(Self.august)
        )
        let changes = try #require(comparison.changes)
        #expect(changes.contains(.economicsChanged))
        #expect(comparison.previousQuality == .clean)
    }

    @Test("F: a re-decided observation is an evidence change")
    func redecidedObservationIsEvidenceChange() throws {
        let harness = try Harness()
        try storeClose(Self.august, of: document(), in: harness)

        let comparison = try comparison(
            document(observationResolution: .unreviewed),
            baseline: harness.baseline(Self.august)
        )
        let changes = try #require(comparison.changes)
        #expect(changes.contains(.evidenceChanged))
    }

    @Test("G: three independent dimensions produce exactly three classes")
    func multiAxisChangeReportsEveryDimension() throws {
        let harness = try Harness()
        try storeClose(Self.august, of: document(), in: harness)

        let comparison = try comparison(
            document(observationEligible: false, observationResolution: .unreviewed),
            baseline: harness.baseline(Self.august),
            occurrences: [settledOccurrence()]
        )
        let changes = try #require(comparison.changes)
        // Non-exclusive and rank-ordered, exactly as the comparator derives
        // them: the resolution is evidence, the provider eligibility is
        // provider state, and the occurrence is an expectation.
        #expect(changes.classes == [.evidenceChanged, .providerStateChanged, .expectationChanged])
    }

    // MARK: - H — the current period cannot be compared

    @Test("H: an uncomparable current period is indeterminate, never changed")
    func uncomparableCurrentPeriodIsIndeterminate() throws {
        let harness = try Harness()
        try storeClose(Self.august, of: document(), in: harness)

        // Coverage this build cannot establish, on a period that has also
        // moved — so a comparator ranking the digest first would say "changed".
        let readiness = try readiness(
            document(incomeMinor: 9_900),
            baseline: harness.baseline(Self.august),
            coverage: .absent
        )
        let blockers = try #require(
            PeriodCheckpointComparabilityLimits(readiness.blockers.map(\.kind))
        )
        #expect(!blockers.blockers.isEmpty)
        // The blocker set is the period's own, from the readiness authority.
        #expect(
            readiness.baselineComparison
                == .indeterminate(previousQuality: .clean, blockers: blockers)
        )
        #expect(readiness.baselineComparison.changes == nil)
    }

    // MARK: - I / J — a stored format this build cannot read

    /// Rewrites the stored format token, and scrambles the payload so a reader
    /// that parses bytes it declared unreadable fails loudly.
    private func makeUnsupported(_ id: UUID, in harness: Harness) throws {
        let row = try harness.revisionRow(id)
        row.projectionFormatToken = "v2"
        row.canonicalProjection = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try harness.save()
    }

    @Test("I: an unsupported stored format asks for re-verification, with its raw token")
    func unsupportedStoredFormatRequiresReverification() throws {
        let harness = try Harness()
        let id = try storeClose(
            Self.august, of: document(), in: harness,
            exceptions: CheckpointFixtures.exceptions
        )
        try makeUnsupported(id, in: harness)

        #expect(
            try comparison(document(), baseline: harness.baseline(Self.august))
                == .requiresReverification(
                    previousQuality: .withExceptions,
                    storedFormatToken: "v2",
                    comparisonFormat: .v1
                )
        )
    }

    @Test("J: a stored format problem outranks a current-period blocker")
    func storedFormatOutranksCurrentBlocker() throws {
        let harness = try Harness()
        let id = try storeClose(Self.august, of: document(), in: harness)
        try makeUnsupported(id, in: harness)

        // Both are true at once. The comparator's precedence is the durable
        // fact first, and D transports it rather than reordering it.
        let readiness = try readiness(
            document(), baseline: harness.baseline(Self.august), coverage: .absent
        )
        #expect(readiness.disposition == .blocked)
        #expect(
            readiness.baselineComparison
                == .requiresReverification(
                    previousQuality: .clean, storedFormatToken: "v2", comparisonFormat: .v1
                )
        )
    }

    // MARK: - K / L — history that exists and cannot be trusted

    @Test("K: corrupt history is an unreadable baseline, never a first close")
    func corruptHistoryIsUnreadableNotAbsent() throws {
        let harness = try Harness()
        let id = try storeClose(Self.august, of: document(), in: harness)

        // A payload edited after acceptance: the format is one this build
        // reads, and the bytes no longer hash to the recorded digest.
        let row = try harness.revisionRow(id)
        row.canonicalProjection = Data([0x00, 0x01, 0x02])
        try harness.save()

        let comparison = try comparison(document(), baseline: harness.baseline(Self.august))
        #expect(comparison == .unavailable(.baselineProjectionUnreadable))
        #expect(!comparison.isEstablished)
        #expect(comparison != .notPreviouslyClosed)
        #expect(comparison != .unavailable(.noBaselinePersistence))
        #expect(comparison != .unchangedSinceClose(previousQuality: .clean))
        #expect(comparison.previousQuality == nil)
    }

    @Test("L: an incompatible V2 → V1 chain is unreadable, not a supported baseline")
    func incompatibleFormatChainIsUnreadable() throws {
        let harness = try Harness()
        let document = self.document()
        let closed = try readiness(document, baseline: .noRevision)

        let first = UUID()
        try harness.repository().store(try revision(recording: closed, id: first))
        try harness.repository().store(
            try revision(recording: closed, revisionNumber: 2, predecessorID: first)
        )
        // The predecessor turns out to have been written by a later build. A
        // supported revision cannot follow one this build cannot interpret.
        try makeUnsupported(first, in: harness)

        #expect(
            try comparison(document, baseline: harness.baseline(Self.august))
                == .unavailable(.baselineProjectionUnreadable)
        )
    }

    // MARK: - M / N — period identity and isolation

    @Test("M: a checkpoint for another period is not this period's baseline")
    func anotherPeriodIsNotABaseline() throws {
        let harness = try Harness()
        try storeClose(Self.august, of: document(), in: harness)

        // A different month.
        #expect(harness.baseline(Self.september).isFirstClose)
        // The same start day, a different end day.
        #expect(
            harness.baseline(
                SemanticInterval(start: day("2026-08-01"), end: day("2026-08-30"))
            ).isFirstClose
        )
        // The same interval, a different period kind.
        #expect(harness.baseline(Self.august, kind: .weekly).isFirstClose)
        // And the period that really was closed still reads back.
        #expect(!harness.baseline(Self.august).isFirstClose)
    }

    @Test("N: a corrupt period does not stop another period being compared")
    func corruptionStaysPeriodLocal() throws {
        let harness = try Harness()
        let document = self.document()

        let augustID = try storeClose(Self.august, of: document, in: harness)
        try storeClose(Self.july, of: document, in: harness)

        // August's payload is now untrustworthy.
        let row = try harness.revisionRow(augustID)
        row.canonicalProjection = Data([0x00])
        try harness.save()

        #expect(
            try comparison(document, baseline: harness.baseline(Self.august))
                == .unavailable(.baselineProjectionUnreadable)
        )
        // July's own history validated, so July still compares.
        #expect(
            try comparison(document, baseline: harness.baseline(Self.july), interval: Self.july)
                == .unchangedSinceClose(previousQuality: .clean)
        )
        // Store-wide occupancy is import safety, and is deliberately not the
        // comparison authority: it fails while July still succeeds.
        guard case .unreadable = harness.repository().occupancy() else {
            Issue.record("a corrupt period makes the store unsafe to import into")
            return
        }
    }

    // MARK: - O — the placeholder is gone

    @Test("O: a real empty repository establishes the baseline instead of a placeholder")
    func emptyRepositoryEstablishesTheBaseline() throws {
        let harness = try Harness()
        let output = AttentionComposition.evaluate(
            try input(document(), baseline: harness.baseline(Self.august))
        )

        #expect(output.readiness.baselineComparison == .notPreviouslyClosed)
        #expect(output.readiness.baselineComparison.isEstablished)
        #expect(output.availability.status(.periodCheckpointBaseline) == .available)
        #expect(output.availability.status(.periodCheckpointBaseline)
                    != .unavailable(.notImplementedInThisBuild))
        #expect(output.availability.isFullyEvaluated(for: .checkpointBaseline))
    }

    @Test("A read that failed is a source failure; a read that found nothing is not")
    func availabilitySeparatesFailureFromEmptiness() throws {
        let harness = try Harness()
        let id = try storeClose(Self.august, of: document(), in: harness)
        let row = try harness.revisionRow(id)
        row.canonicalProjection = Data([0x00])
        try harness.save()

        let corrupt = AttentionComposition.evaluate(
            try input(document(), baseline: harness.baseline(Self.august))
        )
        #expect(corrupt.availability.status(.periodCheckpointBaseline)
                    == .incoherent(.resultInternallyInconsistent))
        #expect(!corrupt.availability.isFullyEvaluated(for: .checkpointBaseline))

        // And a composition that consulted no history says exactly that.
        let unread = AttentionComposition.evaluate(
            try input(document(), baseline: .unavailable(.noBaselinePersistence))
        )
        #expect(unread.availability.status(.periodCheckpointBaseline)
                    == .unavailable(.notEvaluated))
    }

    // MARK: - The load-bearing round trip

    @Test("Real persistence: closed, unchanged, then changed by an ordinary edit")
    func realPersistenceRoundTrip() throws {
        let harness = try Harness()
        let closed = self.document()
        try storeClose(Self.august, of: closed, in: harness)

        // Nothing about the document moved.
        #expect(
            try comparison(closed, baseline: harness.baseline(Self.august))
                == .unchangedSinceClose(previousQuality: .clean)
        )

        // One ordinary edit to the *current* document, and only that.
        var edited = closed
        edited.transactions.append(
            Transaction(
                id: "tx-late", date: day("2026-08-20"), kind: .expense,
                legs: [AccountLeg(accountID: "bank", amount: euro(-1_250))],
                factivity: .observed
            )
        )
        let after = try comparison(edited, baseline: harness.baseline(Self.august))
        let changes = try #require(after.changes)
        #expect(changes.contains(.economicsChanged))
        #expect(after.previousQuality == .clean)

        // And the stored history is what it always was.
        #expect(
            try comparison(closed, baseline: harness.baseline(Self.august))
                == .unchangedSinceClose(previousQuality: .clean)
        )
    }

    // MARK: - Read-only

    /// Everything a write would move, captured as plain values.
    private struct StoreImage: Equatable {
        let datasets: Int
        let revisions: Int
        let acknowledgments: Int
        let canonicalBytes: [String: [UInt8]]
        let digests: [String: [UInt8]]
        let acknowledgmentDigests: [String: [UInt8]]

        @MainActor
        init(_ harness: Harness) throws {
            datasets = try harness.rows(StoredPeriodCheckpointDataset.self).count
            let rows = try harness.rows(StoredPeriodCheckpointRevision.self)
            revisions = rows.count
            acknowledgments = try harness.rows(StoredPeriodCheckpointAcknowledgment.self).count
            canonicalBytes = Dictionary(
                rows.map { ($0.identifier, Array($0.canonicalProjection)) },
                uniquingKeysWith: { first, _ in first }
            )
            digests = Dictionary(
                rows.map { ($0.identifier, Array($0.projectionDigest)) },
                uniquingKeysWith: { first, _ in first }
            )
            acknowledgmentDigests = Dictionary(
                rows.map { ($0.identifier, Array($0.acknowledgmentDigest)) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    @Test("Reading a baseline changes nothing about the history it read")
    func baselineReadsAreObservational() throws {
        let harness = try Harness()
        try storeClose(
            Self.august, of: document(), in: harness,
            exceptions: CheckpointFixtures.exceptions
        )

        let before = try StoreImage(harness)
        #expect(before.datasets == 1)
        #expect(before.revisions == 1)
        #expect(before.acknowledgments == CheckpointFixtures.exceptions.count)

        // Repeatedly, across the states that make the reader work hardest.
        for _ in 0..<3 {
            _ = try comparison(document(), baseline: harness.baseline(Self.august))
            _ = try comparison(document(incomeMinor: 7_777), baseline: harness.baseline(Self.august))
            _ = try comparison(document(), baseline: harness.baseline(Self.august), coverage: .absent)
            _ = try comparison(document(), baseline: harness.baseline(Self.july), interval: Self.july)
            _ = AttentionComposition.evaluate(
                try input(document(), baseline: harness.baseline(Self.august))
            )
        }

        #expect(try StoreImage(harness) == before)
    }

    @Test("Opening the product's read surfaces creates no checkpoint rows")
    func productSurfacesWriteNoCheckpointHistory() throws {
        let harness = try Harness()
        let store = try FinanceStore(context: harness.context, now: fixtureInstant(asOf))
        try store.importDocument(document())

        // The two production paths that now read a baseline: Home's attention
        // composition, refreshed by every ordinary write, and the Insights
        // verification preview for an ended month.
        _ = store.attentionPresentation
        _ = store.review(ReviewPeriodSelection(scope: .month, offset: -1))
        _ = store.review(ReviewPeriodSelection(scope: .month, offset: 0))
        _ = store.attentionPresentation

        #expect(try harness.rows(StoredPeriodCheckpointDataset.self).isEmpty)
        #expect(try harness.rows(StoredPeriodCheckpointRevision.self).isEmpty)
        #expect(try harness.rows(StoredPeriodCheckpointAcknowledgment.self).isEmpty)
        #expect(store.checkpoints.occupancy() == .empty)
    }

    @Test("A store with no persistence reads an empty history rather than failing")
    func storeWithoutPersistenceStillEstablishesEmptiness() {
        let store = FinanceStore.preview()
        _ = store.review(ReviewPeriodSelection(scope: .month, offset: -1))
        #expect(store.checkpoints.occupancy() == .empty)
        #expect(
            PeriodCheckpointBaselineReader.source(
                from: store.checkpoints,
                period: SemanticInterval(Self.august), kind: .monthly
            ).isFirstClose
        )
    }
}

// MARK: - Test-only readability

extension PeriodCheckpointBaselineSource {
    /// `.noRevision` — the source was read and holds nothing for this period.
    var isFirstClose: Bool {
        if case .noRevision = self { return true }
        return false
    }
}
