import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

/// Checkpoint values the persistence suites share.
///
/// Deliberately not nested inside a `@MainActor` suite: a default argument is
/// evaluated in a nonisolated context, so `period: SemanticInterval = august`
/// there is an actor-isolation violation — a warning today, an error in Swift 6,
/// and enough to stop the testing macro registering that type's tests at all.
/// `EntryFixtures` exists for the same reason.
enum CheckpointFixtures {

    static let august = SemanticInterval(
        start: Day(year: 2026, month: 8, day: 1),
        end: Day(year: 2026, month: 8, day: 31)
    )
    static let september = SemanticInterval(
        start: Day(year: 2026, month: 9, day: 1),
        end: Day(year: 2026, month: 9, day: 30)
    )
    static let closedAt = Date(timeIntervalSinceReferenceDate: 810_000_000)
    static let datasetIdentity = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    static func projection(
        period: SemanticInterval = august,
        kind: ReviewPeriodKind = .monthly,
        spendingMinor: Int64 = 12_345
    ) throws -> CanonicalSemanticPeriodProjection {
        try CanonicalSemanticPeriodProjection(
            SemanticPeriodProjection(
                period: period,
                kind: kind,
                coverage: .complete,
                budget: SemanticBudgetFact(
                    periodEconomicSpending: Money(minorUnits: spendingMinor, currency: .eur),
                    uncategorized: Money(minorUnits: 0, currency: .eur),
                    attributions: []
                ),
                transactions: [],
                observations: [],
                expectations: []
            )
        )
    }

    /// A valid closed revision, assembled as a value.
    ///
    /// Built through `init(rehydratingStoredSnapshot:)` because
    /// `PeriodCheckpointReadiness` and `ReviewResult` are not publicly
    /// constructible, so the readiness-backed path is unreachable from here
    /// without running `ReviewEngine` — the one dependency storage must never
    /// acquire. This is a test fixture, not the production shape: the writer
    /// takes an already-created revision and constructs none.
    static func revision(
        id: UUID = UUID(),
        period: SemanticInterval = august,
        kind: ReviewPeriodKind = .monthly,
        revisionNumber: Int64 = 1,
        predecessorID: UUID? = nil,
        closedAt: Date = closedAt,
        exceptions: [PeriodCheckpointException] = [],
        projection: CanonicalSemanticPeriodProjection? = nil
    ) throws -> PeriodCheckpointRevision {
        try PeriodCheckpointRevision(
            rehydratingStoredSnapshot: id,
            period: period,
            periodKind: kind,
            revisionNumber: revisionNumber,
            predecessorID: predecessorID,
            closedAt: closedAt,
            canonicalProjection: projection ?? (try CheckpointFixtures.projection(period: period, kind: kind)),
            acknowledgedExceptions: exceptions.map(AcknowledgedExceptionRecord.init),
            quality: exceptions.isEmpty ? .clean : .withExceptions,
            safeClaims: .surviving(exceptions)
        )
    }

    /// Three exceptions covering every optional field, including a
    /// three-decimal currency, so a round-trip that quietly drops or rounds one
    /// of them is visible.
    static let exceptions: [PeriodCheckpointException] = [
        PeriodCheckpointException(
            id: "agg-1",
            kind: .aggregateEvidenceModelLimitation,
            aggregateBasis: .structuralCandidateOnly,
            day: Day(year: 2026, month: 8, day: 14),
            amount: Money(minorUnits: 4_321, currency: .kwd)
        ),
        PeriodCheckpointException(
            id: "uncat-1",
            kind: .uncategorizedEconomicSpending,
            day: Day(year: 2026, month: 8, day: 3),
            amount: Money(minorUnits: -999, currency: .eur)
        ),
        PeriodCheckpointException(id: "overdue-1", kind: .overdueExpectedOccurrence)
    ]
}

/// Phase 2.9C-C — durable checkpoint revision history.
///
/// Revisions arrive from `CheckpointFixtures`, which builds them as values
/// through the rehydration initializer for the reason recorded there. That is a
/// fixture shape, not the production one: the writer takes an already-created
/// revision and constructs none, which
/// `PeriodCheckpointBoundaryTests.theWriterNeverConstructsARevision` holds from
/// outside by reading the shipped source.
///
/// Every store here is temporary and synthetic. Nothing reads the real app
/// database, and no real financial data is written anywhere.
@MainActor
@Suite("Checkpoint revision history is durable, append-only and fail-closed")
struct PeriodCheckpointPersistenceTests {

    // MARK: - Harness

    /// A temporary in-memory container and a fresh repository per call.
    ///
    /// Each `repository()` opens a new `ModelContext` on the same container, so
    /// a read after a direct row edit can never be answered from a context that
    /// still remembers the row as it was.
    @MainActor
    struct Harness {
        let container: ModelContainer

        init() throws {
            container = try ModelContainer(
                for: Schema(FinanceSchema.models),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }

        var context: ModelContext { container.mainContext }

        func repository(
            identity: UUID = CheckpointFixtures.datasetIdentity
        ) -> PeriodCheckpointRepository {
            PeriodCheckpointRepository(
                context: container.mainContext,
                makeDatasetIdentity: { identity },
                now: { CheckpointFixtures.closedAt }
            )
        }

        func rows<T: PersistentModel>(_ type: T.Type) throws -> [T] {
            try context.fetch(FetchDescriptor<T>())
        }

        /// The stored revision row for one id, for the corruption cases that
        /// have to edit persisted bytes directly.
        func revisionRow(_ id: UUID) throws -> StoredPeriodCheckpointRevision {
            let identifier = id.uuidString
            let rows = try context.fetch(
                FetchDescriptor<StoredPeriodCheckpointRevision>(
                    predicate: #Predicate { $0.identifier == identifier }
                )
            )
            return rows[0]
        }

        func save() throws { try context.save() }
    }

    // MARK: - Reading what a read returned

    static func supported(_ read: PeriodCheckpointStoredRead) throws -> PeriodCheckpointRevision {
        guard case let .supported(revision) = read else {
            Issue.record("expected a supported revision, got \(read)")
            throw CheckpointTestFailure.unexpectedReadState
        }
        return revision
    }

    static func corruption(_ read: PeriodCheckpointStoredRead) throws -> PeriodCheckpointStoreCorruption {
        guard case let .corrupt(corruption) = read else {
            Issue.record("expected corruption, got \(read)")
            throw CheckpointTestFailure.unexpectedReadState
        }
        return corruption
    }

    enum CheckpointTestFailure: Error { case unexpectedReadState }

    // MARK: - Supported V1: write, then read exactly what was written

    @Test("A clean revision round-trips byte for byte")
    func cleanRevisionRoundTrips() throws {
        let harness = try Harness()
        let id = UUID()
        let original = try CheckpointFixtures.revision(id: id)

        #expect(try harness.repository().store(original) == .stored)

        let read = try Self.supported(
            harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
        )

        #expect(read.id == id)
        #expect(read.period == CheckpointFixtures.august)
        #expect(read.periodKind == .monthly)
        #expect(read.revisionNumber == 1)
        #expect(read.predecessorID == nil)
        #expect(read.closedAt == CheckpointFixtures.closedAt)
        #expect(read.quality == .clean)
        #expect(read.projectionFormatVersion == .v1)
        #expect(read.acknowledgedExceptions.isEmpty)

        // The two things a lossy store would quietly change.
        #expect(read.canonicalProjection.bytes == original.canonicalProjection.bytes)
        #expect(read.projectionDigest.bytes == original.projectionDigest.bytes)
        #expect(read.canonicalProjection.projection == original.canonicalProjection.projection)

        #expect(read.safeClaims == original.safeClaims)
        #expect(read.safeClaims.mayShowCalculatedTotals)
        #expect(read.safeClaims.unquestionablyCompleteTotals)
        #expect(read.safeClaims.completeCategoryAttribution)
        #expect(read.safeClaims.completeEvidenceAudit)
    }

    @Test("Acknowledgment snapshots survive with every field, in order")
    func acknowledgmentSnapshotsRoundTrip() throws {
        let harness = try Harness()
        let original = try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions)
        #expect(try harness.repository().store(original) == .stored)

        let read = try Self.supported(
            harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
        )

        #expect(read.quality == .withExceptions)
        #expect(read.acknowledgedExceptions.count == CheckpointFixtures.exceptions.count)
        // Order is part of the snapshot: the stored array is the array that
        // was accepted, not a set the store re-ordered.
        #expect(read.acknowledgedExceptions.map(\.exception) == CheckpointFixtures.exceptions)

        let aggregate = read.acknowledgedExceptions[0].exception
        #expect(aggregate.kind == .aggregateEvidenceModelLimitation)
        #expect(aggregate.aggregateBasis == .structuralCandidateOnly)
        #expect(aggregate.day == Day(year: 2026, month: 8, day: 14))
        // Three-decimal money keeps its exponent, not a two-digit assumption.
        #expect(aggregate.amount == Money(minorUnits: 4_321, currency: .kwd))
        #expect(aggregate.amount?.currency.minorUnitDigits == 3)

        let overdue = read.acknowledgedExceptions[2].exception
        #expect(overdue.day == nil)
        #expect(overdue.amount == nil)
        #expect(overdue.aggregateBasis == nil)

        // Safe claims are the ones the revision recorded, and they follow from
        // these exceptions rather than from a stored boolean nobody checked.
        #expect(read.safeClaims == PeriodCheckpointSafeClaims.surviving(CheckpointFixtures.exceptions))
        #expect(!read.safeClaims.unquestionablyCompleteTotals)
        #expect(!read.safeClaims.completeCategoryAttribution)
        #expect(read.safeClaims.mayShowCalculatedTotals)
    }

    // MARK: - The four read states

    @Test("A fresh subgraph reads empty, and holds no rows at all")
    func freshStoreIsEmpty() throws {
        let harness = try Harness()

        #expect(try harness.rows(StoredPeriodCheckpointDataset.self).isEmpty)
        #expect(try harness.rows(StoredPeriodCheckpointRevision.self).isEmpty)
        #expect(try harness.rows(StoredPeriodCheckpointAcknowledgment.self).isEmpty)

        guard case .empty = harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
        else { Issue.record("a fresh subgraph should read empty"); return }
        guard case .empty = harness.repository().revisions(inPeriod: CheckpointFixtures.august, kind: .monthly)
        else { Issue.record("a fresh subgraph should have no history"); return }
        #expect(harness.repository().occupancy() == .empty)
    }

    @Test("A period with no revision reads empty even when another period has one")
    func anotherPeriodDoesNotAnswerForThisOne() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision(period: CheckpointFixtures.august))

        guard case .empty = harness.repository().latestRevision(inPeriod: CheckpointFixtures.september, kind: .monthly)
        else { Issue.record("September has never been closed"); return }
        // Same start day, different end day, is a different period.
        let shorterAugust = SemanticInterval(
            start: Day(year: 2026, month: 8, day: 1), end: Day(year: 2026, month: 8, day: 30)
        )
        guard case .empty = harness.repository().latestRevision(inPeriod: shorterAugust, kind: .monthly)
        else { Issue.record("a different interval is a different period"); return }
        // Same interval, different kind, is a different history.
        guard case .empty = harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .weekly)
        else { Issue.record("a weekly close does not speak for a monthly period"); return }
    }

    @Test("A future projection format reads as unsupported, never as corruption")
    func futureFormatIsNotCorruption() throws {
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id, exceptions: CheckpointFixtures.exceptions))

        let row = try harness.revisionRow(id)
        row.projectionFormatToken = "v2"
        // Bytes a later format wrote are not this build's to parse. Scrambled
        // here so a reader that interprets them anyway fails the test.
        row.canonicalProjection = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try harness.save()

        let read = harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
        guard case let .unsupportedFormat(header) = read else {
            Issue.record("a future format is not corruption, got \(read)")
            return
        }
        #expect(header.revisionID == id)
        #expect(header.period == CheckpointFixtures.august)
        #expect(header.periodKind == .monthly)
        #expect(header.revisionNumber == 1)
        #expect(header.predecessorID == nil)
        #expect(header.previousQuality == .withExceptions)
        // Verbatim: an unknown token is never normalized to the one this build
        // does understand.
        #expect(header.formatToken == "v2")
    }

    @Test("A supported format whose bytes are unreadable is corruption")
    func supportedFormatWithUnreadableBytesIsCorrupt() throws {
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id))

        let row = try harness.revisionRow(id)
        #expect(row.projectionFormatToken == "v1")
        row.canonicalProjection = Data([0x00, 0x01, 0x02])
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .malformedCanonicalPayload
        )
    }

    @Test("A payload that no longer hashes to its recorded digest is corruption")
    func digestMismatchIsCorrupt() throws {
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id))

        let row = try harness.revisionRow(id)
        var digest = Array(row.projectionDigest)
        digest[0] ^= 0xFF
        row.projectionDigest = Data(digest)
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .digestMismatch
        )
    }

    @Test("A digest that is not 32 bytes is corruption")
    func shortDigestIsCorrupt() throws {
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id))
        try harness.revisionRow(id).projectionDigest = Data([0x01, 0x02])
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .malformedDigest
        )
    }

    // MARK: - Append-only history

    @Test("A second revision appends, and the latest is the highest number")
    func appendingASecondRevision() throws {
        let harness = try Harness()
        let first = UUID()
        let second = UUID()

        try harness.repository().store(try CheckpointFixtures.revision(id: first, revisionNumber: 1))
        try harness.repository().store(
            try CheckpointFixtures.revision(
                id: second, revisionNumber: 2, predecessorID: first,
                closedAt: CheckpointFixtures.closedAt.addingTimeInterval(86_400),
                projection: try CheckpointFixtures.projection(spendingMinor: 99_999)
            )
        )

        let latest = try Self.supported(
            harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
        )
        #expect(latest.id == second)
        #expect(latest.revisionNumber == 2)
        #expect(latest.predecessorID == first)

        guard case let .history(history) =
            harness.repository().revisions(inPeriod: CheckpointFixtures.august, kind: .monthly)
        else { Issue.record("two revisions should read as a history"); return }
        #expect(history.count == 2)
        guard case let .supported(one) = history[0], case let .supported(two) = history[1] else {
            Issue.record("both revisions should be supported")
            return
        }
        #expect(one.revisionNumber == 1)
        #expect(two.revisionNumber == 2)

        // Revision 1 is exactly what it was: appending never rewrites history.
        let original = try CheckpointFixtures.revision(id: first, revisionNumber: 1)
        #expect(one.canonicalProjection.bytes == original.canonicalProjection.bytes)
        #expect(one.projectionDigest.bytes == original.projectionDigest.bytes)
        #expect(one.closedAt == CheckpointFixtures.closedAt)
        #expect(one.quality == .clean)
    }

    @Test("The latest revision is decided by revision number, not by closedAt")
    func latestIsByRevisionNumber() throws {
        let harness = try Harness()
        let first = UUID()
        let second = UUID()

        try harness.repository().store(
            try CheckpointFixtures.revision(id: first, revisionNumber: 1,
                              closedAt: CheckpointFixtures.closedAt.addingTimeInterval(500_000))
        )
        // Closed *earlier* on the clock, later in the chain. A store that
        // sorted by timestamp would answer with revision 1.
        try harness.repository().store(
            try CheckpointFixtures.revision(id: second, revisionNumber: 2, predecessorID: first,
                              closedAt: CheckpointFixtures.closedAt)
        )

        let latest = try Self.supported(
            harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
        )
        #expect(latest.revisionNumber == 2)
        #expect(latest.id == second)
    }

    @Test("Storing the identical revision again is an idempotent no-op")
    func identicalRetryIsANoOp() throws {
        let harness = try Harness()
        let id = UUID()
        let revision = try CheckpointFixtures.revision(id: id, exceptions: CheckpointFixtures.exceptions)

        #expect(try harness.repository().store(revision) == .stored)
        #expect(try harness.repository().store(revision) == .alreadyStored)

        #expect(try harness.rows(StoredPeriodCheckpointRevision.self).count == 1)
        #expect(try harness.rows(StoredPeriodCheckpointAcknowledgment.self).count == CheckpointFixtures.exceptions.count)
        #expect(try harness.rows(StoredPeriodCheckpointDataset.self).count == 1)
    }

    @Test("The same identity with different content is refused, never rewritten")
    func sameIdentityDifferentContentIsRefused() throws {
        let harness = try Harness()
        let id = UUID()
        let original = try CheckpointFixtures.revision(id: id)
        try harness.repository().store(original)

        let rewritten = try CheckpointFixtures.revision(
            id: id, projection: try CheckpointFixtures.projection(spendingMinor: 777)
        )
        #expect(throws: PeriodCheckpointStoreError.rejected(.revisionAlreadyStoredWithDifferentContent)) {
            try harness.repository().store(rewritten)
        }

        let read = try Self.supported(
            harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
        )
        #expect(read.canonicalProjection.bytes == original.canonicalProjection.bytes)
    }

    @Test("The same identity with a different acknowledgment set is refused")
    func sameIdentityDifferentAcknowledgmentsIsRefused() throws {
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id, exceptions: CheckpointFixtures.exceptions))

        #expect(throws: PeriodCheckpointStoreError.rejected(.revisionAlreadyStoredWithDifferentContent)) {
            try harness.repository().store(
                try CheckpointFixtures.revision(id: id, exceptions: Array(CheckpointFixtures.exceptions.dropLast()))
            )
        }
        #expect(try harness.rows(StoredPeriodCheckpointAcknowledgment.self).count == CheckpointFixtures.exceptions.count)
    }

    @Test("A second revision with a number this period already holds is refused")
    func duplicateRevisionNumberIsRefused() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision(revisionNumber: 1))

        #expect(throws: PeriodCheckpointStoreError.rejected(.duplicateRevisionNumber)) {
            try harness.repository().store(try CheckpointFixtures.revision(id: UUID(), revisionNumber: 1))
        }
        #expect(try harness.rows(StoredPeriodCheckpointRevision.self).count == 1)
    }

    @Test("A branch — two revision 2s under one revision 1 — is refused on write")
    func branchingIsRefusedOnWrite() throws {
        let harness = try Harness()
        let first = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: first, revisionNumber: 1))
        try harness.repository().store(
            try CheckpointFixtures.revision(id: UUID(), revisionNumber: 2, predecessorID: first)
        )

        #expect(throws: PeriodCheckpointStoreError.rejected(.duplicateRevisionNumber)) {
            try harness.repository().store(
                try CheckpointFixtures.revision(id: UUID(), revisionNumber: 2, predecessorID: first)
            )
        }
    }

    @Test("A branch already on disk reads as corruption, never as a timestamp race")
    func branchingOnDiskIsCorrupt() throws {
        let harness = try Harness()
        let first = UUID()
        let branchA = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: first, revisionNumber: 1))
        try harness.repository().store(
            try CheckpointFixtures.revision(id: branchA, revisionNumber: 2, predecessorID: first)
        )

        // A second revision 2, inserted behind the writer's back.
        let template = try harness.revisionRow(branchA)
        harness.context.insert(
            try StoredPeriodCheckpointRevision(
                identifier: UUID().uuidString,
                datasetIdentifier: template.datasetIdentifier,
                periodStartDay: template.periodStartDay,
                periodEndDay: template.periodEndDay,
                periodKindRaw: template.periodKindRaw,
                revisionNumber: 2,
                predecessorIdentifier: first.uuidString,
                closedAt: template.closedAt.addingTimeInterval(60),
                qualityRaw: template.qualityRaw,
                projectionFormatToken: template.projectionFormatToken,
                projectionDigest: template.projectionDigest,
                canonicalProjection: template.canonicalProjection,
                safeClaimMayShowCalculatedTotals: true,
                safeClaimUnquestionablyCompleteTotals: true,
                safeClaimCompleteCategoryAttribution: true,
                safeClaimCompleteEvidenceAudit: true,
                acknowledgmentCount: template.acknowledgmentCount,
                acknowledgmentDigest: template.acknowledgmentDigest
            )
        )
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .duplicateRevisionNumber
        )
    }

    @Test("A revision naming a predecessor that is not stored is refused")
    func unknownPredecessorIsRefused() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision(revisionNumber: 1))

        #expect(throws: PeriodCheckpointStoreError.rejected(.predecessorNotFound)) {
            try harness.repository().store(
                try CheckpointFixtures.revision(id: UUID(), revisionNumber: 2, predecessorID: UUID())
            )
        }
    }

    @Test("A predecessor from another period is refused")
    func predecessorFromAnotherPeriodIsRefused() throws {
        let harness = try Harness()
        let augustFirst = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: augustFirst, period: CheckpointFixtures.august))

        #expect(throws: PeriodCheckpointStoreError.rejected(.predecessorPeriodMismatch)) {
            try harness.repository().store(
                try CheckpointFixtures.revision(
                    id: UUID(), period: CheckpointFixtures.september, revisionNumber: 2,
                    predecessorID: augustFirst
                )
            )
        }
    }

    @Test("A predecessor of another period kind is refused")
    func predecessorOfAnotherKindIsRefused() throws {
        let harness = try Harness()
        let monthly = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: monthly, kind: .monthly))

        #expect(throws: PeriodCheckpointStoreError.rejected(.predecessorKindMismatch)) {
            try harness.repository().store(
                try CheckpointFixtures.revision(id: UUID(), kind: .weekly, revisionNumber: 2, predecessorID: monthly)
            )
        }
    }

    @Test("A predecessor that is not the preceding revision is refused")
    func predecessorMustBeTheImmediatelyPrecedingRevision() throws {
        let harness = try Harness()
        let first = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: first, revisionNumber: 1))

        #expect(throws: PeriodCheckpointStoreError.rejected(.predecessorRevisionNumberMismatch)) {
            try harness.repository().store(
                try CheckpointFixtures.revision(id: UUID(), revisionNumber: 3, predecessorID: first)
            )
        }
    }

    @Test("Weekly and monthly histories of one interval do not collide")
    func kindKeepsHistoriesApart() throws {
        let harness = try Harness()
        let monthly = UUID()
        let weekly = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: monthly, kind: .monthly))
        // Same start, same end, other kind: revision 1 of its own history.
        try harness.repository().store(try CheckpointFixtures.revision(id: weekly, kind: .weekly))

        #expect(
            try Self.supported(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ).id == monthly
        )
        #expect(
            try Self.supported(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .weekly)
            ).id == weekly
        )
    }

    // MARK: - Dataset identity

    @Test("The first append creates dataset, revision and acknowledgments together")
    func firstAppendIsAtomic() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions))

        let datasets = try harness.rows(StoredPeriodCheckpointDataset.self)
        #expect(datasets.count == 1)
        #expect(datasets[0].identifier == CheckpointFixtures.datasetIdentity.uuidString)
        #expect(datasets[0].establishedAt == CheckpointFixtures.closedAt)
        #expect(try harness.rows(StoredPeriodCheckpointRevision.self).count == 1)
        #expect(try harness.rows(StoredPeriodCheckpointAcknowledgment.self).count == CheckpointFixtures.exceptions.count)
        #expect(harness.repository().occupancy() == .holdsCheckpointHistory)
    }

    @Test("A failure inside the first append leaves nothing behind")
    func firstAppendRollsBackWholly() throws {
        let harness = try Harness()
        struct Boom: Error {}

        #expect(throws: PeriodCheckpointStoreError.self) {
            try harness.repository().store(try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions)) {
                throw Boom()
            }
        }

        // Not a dataset row on its own, not a revision without its
        // acknowledgments: none of it.
        #expect(try harness.rows(StoredPeriodCheckpointDataset.self).isEmpty)
        #expect(try harness.rows(StoredPeriodCheckpointRevision.self).isEmpty)
        #expect(try harness.rows(StoredPeriodCheckpointAcknowledgment.self).isEmpty)
        #expect(harness.repository().occupancy() == .empty)
    }

    @Test("A failure inside a later append leaves the earlier history untouched")
    func laterAppendRollsBackWholly() throws {
        let harness = try Harness()
        let first = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: first, revisionNumber: 1))
        struct Boom: Error {}

        #expect(throws: PeriodCheckpointStoreError.self) {
            try harness.repository().store(
                try CheckpointFixtures.revision(id: UUID(), revisionNumber: 2, predecessorID: first,
                                  exceptions: CheckpointFixtures.exceptions)
            ) { throw Boom() }
        }

        #expect(try harness.rows(StoredPeriodCheckpointRevision.self).count == 1)
        #expect(try harness.rows(StoredPeriodCheckpointAcknowledgment.self).isEmpty)
        #expect(
            try Self.supported(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ).revisionNumber == 1
        )
    }

    @Test("Later revisions keep the dataset identity the first one minted")
    func laterRevisionsShareTheDataset() throws {
        let harness = try Harness()
        let first = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: first, revisionNumber: 1))
        // A repository that would mint a *different* identity if it were asked.
        try harness.repository(identity: UUID()).store(
            try CheckpointFixtures.revision(id: UUID(), revisionNumber: 2, predecessorID: first)
        )
        try harness.repository(identity: UUID()).store(
            try CheckpointFixtures.revision(id: UUID(), period: CheckpointFixtures.september, revisionNumber: 1)
        )

        let datasets = try harness.rows(StoredPeriodCheckpointDataset.self)
        #expect(datasets.count == 1)
        #expect(datasets[0].identifier == CheckpointFixtures.datasetIdentity.uuidString)
        let identifiers = Set(try harness.rows(StoredPeriodCheckpointRevision.self).map(\.datasetIdentifier))
        #expect(identifiers == [CheckpointFixtures.datasetIdentity.uuidString])
    }

    @Test("A revision naming another dataset makes the subgraph unreadable")
    func foreignDatasetIsCorrupt() throws {
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id))
        try harness.revisionRow(id).datasetIdentifier = UUID().uuidString
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .revisionDatasetMismatch
        )
        // And nothing may be appended on top of it.
        #expect(throws: PeriodCheckpointStoreError.corrupt(.revisionDatasetMismatch)) {
            try harness.repository().store(try CheckpointFixtures.revision(period: CheckpointFixtures.september))
        }
    }

    @Test("Revisions without dataset metadata are corruption, not a fresh store")
    func revisionsWithoutDatasetAreCorrupt() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision())
        try harness.rows(StoredPeriodCheckpointDataset.self).forEach(harness.context.delete)
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .datasetMetadataMissing
        )
        #expect(harness.repository().occupancy() == .unreadable(.datasetMetadataMissing))
    }

    @Test("Two dataset identities are corruption")
    func duplicateDatasetRowsAreCorrupt() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision())
        harness.context.insert(
            StoredPeriodCheckpointDataset(identifier: UUID().uuidString, establishedAt: CheckpointFixtures.closedAt)
        )
        try harness.save()

        #expect(harness.repository().occupancy() == .unreadable(.multipleDatasetRows))
    }

    @Test("A dataset identifier that is not an identity is corruption")
    func malformedDatasetIdentifierIsCorrupt() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision())
        let dataset = try #require(try harness.rows(StoredPeriodCheckpointDataset.self).first)
        dataset.identifier = "not-an-identity"
        try harness.save()

        #expect(harness.repository().occupancy() == .unreadable(.malformedDatasetIdentifier))
    }

    @Test("Dataset metadata with no revision at all is a torn write, not emptiness")
    func datasetWithoutRevisionsIsCorrupt() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions))
        try harness.rows(StoredPeriodCheckpointAcknowledgment.self).forEach(harness.context.delete)
        try harness.rows(StoredPeriodCheckpointRevision.self).forEach(harness.context.delete)
        try harness.save()

        #expect(harness.repository().occupancy() == .unreadable(.datasetWithoutRevisions))
    }

    // MARK: - Corrupt revision headers

    @Test("A revision identifier that is not an identity is corruption")
    func malformedRevisionIdentifierIsCorrupt() throws {
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id))
        try harness.revisionRow(id).identifier = "not-an-identity"
        try harness.save()

        #expect(harness.repository().occupancy() == .unreadable(.malformedRevisionIdentifier))
    }

    @Test("Two revisions under one identifier are corruption")
    func duplicateRevisionIdentifierIsCorrupt() throws {
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id))
        let template = try harness.revisionRow(id)
        harness.context.insert(
            try StoredPeriodCheckpointRevision(
                identifier: template.identifier,
                datasetIdentifier: template.datasetIdentifier,
                periodStartDay: try #require(CheckpointFixtures.september.start.checkedPersistenceOrdinal),
                periodEndDay: try #require(CheckpointFixtures.september.end.checkedPersistenceOrdinal),
                periodKindRaw: template.periodKindRaw,
                revisionNumber: 1,
                predecessorIdentifier: nil,
                closedAt: template.closedAt,
                qualityRaw: template.qualityRaw,
                projectionFormatToken: template.projectionFormatToken,
                projectionDigest: template.projectionDigest,
                canonicalProjection: template.canonicalProjection,
                safeClaimMayShowCalculatedTotals: true,
                safeClaimUnquestionablyCompleteTotals: true,
                safeClaimCompleteCategoryAttribution: true,
                safeClaimCompleteEvidenceAudit: true,
                acknowledgmentCount: template.acknowledgmentCount,
                acknowledgmentDigest: template.acknowledgmentDigest
            )
        )
        try harness.save()

        #expect(harness.repository().occupancy() == .unreadable(.duplicateRevisionIdentifier))
    }

    @Test("A revision number below one is corruption")
    func revisionNumberBelowOneIsCorrupt() throws {
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id))
        let row = try harness.revisionRow(id)
        row.revisionNumber = 0
        try harness.save()

        #expect(harness.repository().occupancy() == .unreadable(.invalidRevisionNumber))
    }

    @Test("A stored period that is not a calendar interval is corruption")
    func malformedPeriodIsCorrupt() throws {
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id))
        try harness.revisionRow(id).periodStartDay = 20_268_845
        try harness.save()

        #expect(harness.repository().occupancy() == .unreadable(.malformedPeriod))
    }

    @Test("An unknown period-kind token is refused, never read as monthly")
    func unknownPeriodKindIsCorrupt() throws {
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id))
        try harness.revisionRow(id).periodKindRaw = "fortnightly"
        try harness.save()

        #expect(harness.repository().occupancy() == .unreadable(.unknownPeriodKindToken))
    }

    @Test("An unknown quality token is refused, never read as clean")
    func unknownQualityIsCorrupt() throws {
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id))
        try harness.revisionRow(id).qualityRaw = "immaculate"
        try harness.save()

        #expect(harness.repository().occupancy() == .unreadable(.unknownQualityToken))
    }

    @Test("Safe claims that do not follow from the exceptions are refused")
    func malformedSafeClaimsAreCorrupt() throws {
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id))
        // An unblocked period may always show its calculated figures, so a
        // stored `false` here describes a revision that could not have closed.
        try harness.revisionRow(id).safeClaimMayShowCalculatedTotals = false
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .domainRejectedStoredRevision
        )
    }

    @Test("A row whose period disagrees with its payload is refused")
    func rowPeriodMustMatchThePayload() throws {
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id, period: CheckpointFixtures.august))
        let row = try harness.revisionRow(id)
        row.periodStartDay = try #require(CheckpointFixtures.september.start.checkedPersistenceOrdinal)
        row.periodEndDay = try #require(CheckpointFixtures.september.end.checkedPersistenceOrdinal)
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.september, kind: .monthly)
            ) == .domainRejectedStoredRevision
        )
    }

    @Test("A row whose kind disagrees with its payload is refused")
    func rowKindMustMatchThePayload() throws {
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id, kind: .monthly))
        try harness.revisionRow(id).periodKindRaw = ReviewPeriodKind.weekly.rawValue
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .weekly)
            ) == .domainRejectedStoredRevision
        )
    }

    // MARK: - Corrupt chains

    @Test("A later revision with no predecessor is corruption")
    func laterRevisionWithoutPredecessorIsCorrupt() throws {
        let harness = try Harness()
        let first = UUID()
        let second = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: first, revisionNumber: 1))
        try harness.repository().store(
            try CheckpointFixtures.revision(id: second, revisionNumber: 2, predecessorID: first)
        )
        try harness.revisionRow(second).predecessorIdentifier = nil
        try harness.save()

        #expect(harness.repository().occupancy() == .unreadable(.missingPredecessor))
    }

    @Test("A first revision that names a predecessor is corruption")
    func firstRevisionWithPredecessorIsCorrupt() throws {
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id, revisionNumber: 1))
        try harness.revisionRow(id).predecessorIdentifier = UUID().uuidString
        try harness.save()

        #expect(harness.repository().occupancy() == .unreadable(.unexpectedPredecessor))
    }

    @Test("A revision that names itself as its predecessor is corruption")
    func selfPredecessorIsCorrupt() throws {
        let harness = try Harness()
        let first = UUID()
        let second = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: first, revisionNumber: 1))
        try harness.repository().store(
            try CheckpointFixtures.revision(id: second, revisionNumber: 2, predecessorID: first)
        )
        try harness.revisionRow(second).predecessorIdentifier = second.uuidString
        try harness.save()

        #expect(harness.repository().occupancy() == .unreadable(.predecessorIsSelf))
    }

    @Test("A predecessor identifier that is not an identity is corruption")
    func malformedPredecessorIdentifierIsCorrupt() throws {
        let harness = try Harness()
        let first = UUID()
        let second = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: first, revisionNumber: 1))
        try harness.repository().store(
            try CheckpointFixtures.revision(id: second, revisionNumber: 2, predecessorID: first)
        )
        try harness.revisionRow(second).predecessorIdentifier = "not-an-identity"
        try harness.save()

        #expect(harness.repository().occupancy() == .unreadable(.malformedPredecessorIdentifier))
    }

    @Test("A predecessor row that is not stored is corruption on read")
    func missingPredecessorRowIsCorruptOnRead() throws {
        let harness = try Harness()
        let first = UUID()
        let second = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: first, revisionNumber: 1))
        try harness.repository().store(
            try CheckpointFixtures.revision(id: second, revisionNumber: 2, predecessorID: first)
        )
        harness.context.delete(try harness.revisionRow(first))
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .predecessorNotFound
        )
    }

    @Test("A predecessor in another period is corruption on read")
    func crossPeriodPredecessorIsCorruptOnRead() throws {
        let harness = try Harness()
        let augustFirst = UUID()
        let septemberFirst = UUID()
        let septemberSecond = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: augustFirst, period: CheckpointFixtures.august))
        try harness.repository().store(try CheckpointFixtures.revision(id: septemberFirst, period: CheckpointFixtures.september))
        try harness.repository().store(
            try CheckpointFixtures.revision(id: septemberSecond, period: CheckpointFixtures.september,
                              revisionNumber: 2, predecessorID: septemberFirst)
        )
        // Re-point September's revision 2 at August's revision 1.
        try harness.revisionRow(septemberSecond).predecessorIdentifier = augustFirst.uuidString
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.september, kind: .monthly)
            ) == .predecessorPeriodMismatch
        )
        // August is a different chain and is still readable.
        #expect(
            try Self.supported(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ).id == augustFirst
        )
    }

    @Test("A predecessor of another kind is corruption on read")
    func crossKindPredecessorIsCorruptOnRead() throws {
        let harness = try Harness()
        let monthlyFirst = UUID()
        let weeklyFirst = UUID()
        let weeklySecond = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: monthlyFirst, kind: .monthly))
        try harness.repository().store(try CheckpointFixtures.revision(id: weeklyFirst, kind: .weekly))
        try harness.repository().store(
            try CheckpointFixtures.revision(id: weeklySecond, kind: .weekly, revisionNumber: 2,
                              predecessorID: weeklyFirst)
        )
        try harness.revisionRow(weeklySecond).predecessorIdentifier = monthlyFirst.uuidString
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .weekly)
            ) == .predecessorKindMismatch
        )
    }

    @Test("A predecessor that is not the preceding number is corruption on read")
    func predecessorNumberMismatchIsCorruptOnRead() throws {
        let harness = try Harness()
        let first = UUID()
        let second = UUID()
        let third = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: first, revisionNumber: 1))
        try harness.repository().store(
            try CheckpointFixtures.revision(id: second, revisionNumber: 2, predecessorID: first)
        )
        try harness.repository().store(
            try CheckpointFixtures.revision(id: third, revisionNumber: 3, predecessorID: second)
        )
        // Skip a link: revision 3 now claims revision 1 as its predecessor.
        try harness.revisionRow(third).predecessorIdentifier = first.uuidString
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .predecessorRevisionNumberMismatch
        )
    }

    // MARK: - Corrupt acknowledgments

    @Test("A revision that closed with exceptions and holds none is corruption")
    func missingAcknowledgmentRowsAreCorrupt() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions))
        try harness.rows(StoredPeriodCheckpointAcknowledgment.self).forEach(harness.context.delete)
        try harness.save()

        #expect(harness.repository().occupancy() == .unreadable(.acknowledgmentCountMismatch))
    }

    @Test("An acknowledgment naming a revision that is not stored is corruption")
    func orphanAcknowledgmentIsCorrupt() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision())
        harness.context.insert(
            try StoredPeriodCheckpointAcknowledgment(
                revisionIdentifier: UUID().uuidString,
                exceptionIdentifier: "stray",
                kindRaw: PeriodCheckpointExceptionKind.uncategorizedEconomicSpending.rawValue,
                aggregateBasisRaw: nil, day: nil,
                amountMinor: nil, amountCurrencyCode: nil, amountCurrencyExponent: nil,
                sequence: 0
            )
        )
        try harness.save()

        #expect(harness.repository().occupancy() == .unreadable(.orphanAcknowledgment))
    }

    @Test("Two acknowledgments of one exception in one revision are corruption")
    func duplicateAcknowledgmentIsCorrupt() throws {
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id, exceptions: CheckpointFixtures.exceptions))
        let existing = try #require(try harness.rows(StoredPeriodCheckpointAcknowledgment.self).first)
        harness.context.insert(
            try StoredPeriodCheckpointAcknowledgment(
                revisionIdentifier: existing.revisionIdentifier,
                exceptionIdentifier: existing.exceptionIdentifier,
                kindRaw: existing.kindRaw,
                aggregateBasisRaw: existing.aggregateBasisRaw,
                day: existing.day,
                amountMinor: existing.amountMinor,
                amountCurrencyCode: existing.amountCurrencyCode,
                amountCurrencyExponent: existing.amountCurrencyExponent,
                sequence: 99
            )
        )
        try harness.save()

        #expect(harness.repository().occupancy() == .unreadable(.duplicateAcknowledgment))
    }

    @Test("An unknown exception kind is refused, never read as a neighbour")
    func unknownExceptionKindIsCorrupt() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions))
        let row = try #require(try harness.rows(StoredPeriodCheckpointAcknowledgment.self).first)
        row.kindRaw = "someKindFromALaterBuild"
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .unknownExceptionKindToken
        )
    }

    @Test("An unknown aggregate basis is refused")
    func unknownAggregateBasisIsCorrupt() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions))
        let row = try #require(
            try harness.rows(StoredPeriodCheckpointAcknowledgment.self)
                .first { $0.aggregateBasisRaw != nil }
        )
        row.aggregateBasisRaw = "provenByVibes"
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .unknownAggregateBasisToken
        )
    }

    @Test("An aggregate basis on the wrong kind is refused before it can trap")
    func mismatchedAggregateBasisIsCorrupt() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions))
        // `PeriodCheckpointException.init` asserts this pairing. Reaching that
        // assertion from a stored row would end the process; the repository has
        // to refuse the row first.
        let row = try #require(
            try harness.rows(StoredPeriodCheckpointAcknowledgment.self)
                .first { $0.aggregateBasisRaw == nil }
        )
        row.aggregateBasisRaw = AggregateEvidenceBasis.structuralCandidateOnly.rawValue
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .malformedAcknowledgmentAggregateBasis
        )
    }

    @Test("An acknowledgment day that is not a calendar day is refused")
    func malformedAcknowledgmentDayIsCorrupt() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions))
        let row = try #require(
            try harness.rows(StoredPeriodCheckpointAcknowledgment.self).first { $0.day != nil }
        )
        row.day = 20_260_899
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .malformedAcknowledgmentDay
        )
    }

    @Test("A half-stored acknowledgment amount is refused, never read as zero")
    func halfStoredAmountIsCorrupt() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions))
        let row = try #require(
            try harness.rows(StoredPeriodCheckpointAcknowledgment.self).first { $0.amountMinor != nil }
        )
        row.amountCurrencyCode = nil
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .malformedAcknowledgmentAmount
        )
    }

    @Test("An impossible acknowledgment currency is refused before it can trap")
    func impossibleCurrencyIsCorrupt() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions))
        // `Currency.init(code:minorUnitDigits:)` asserts both of these.
        let row = try #require(
            try harness.rows(StoredPeriodCheckpointAcknowledgment.self).first { $0.amountMinor != nil }
        )
        row.amountCurrencyCode = "euro"
        try harness.save()
        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .malformedAcknowledgmentAmount
        )

        row.amountCurrencyCode = "EUR"
        row.amountCurrencyExponent = 9
        try harness.save()
        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .malformedAcknowledgmentAmount
        )
    }

    // MARK: - Acknowledgment array commitment

    @Test("A clean revision commits the empty acknowledgment array")
    func cleanRevisionCommitsEmptyAcknowledgmentArray() throws {
        let harness = try Harness()
        let original = try CheckpointFixtures.revision()
        try harness.repository().store(original)

        let row = try harness.revisionRow(original.id)
        #expect(row.acknowledgmentCount == 0)
        #expect(try harness.rows(StoredPeriodCheckpointAcknowledgment.self).isEmpty)
        let emptyDigest = try CheckpointAcknowledgmentCommitment.digest(
            of: [] as [AcknowledgedExceptionRecord]
        )
        #expect(row.acknowledgmentDigest == emptyDigest)
        #expect(emptyDigest.count == 32)
        #expect(try CheckpointAcknowledgmentCommitment.digest(of: [] as [AcknowledgedExceptionRecord]) == emptyDigest)

        let read = try Self.supported(
            harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
        )
        #expect(read.acknowledgedExceptions.isEmpty)
        #expect(harness.repository().occupancy() == .holdsCheckpointHistory)
    }

    @Test("An ordinary acknowledgment revision keeps exact order")
    func ordinaryAcknowledgmentOrderIsPreserved() throws {
        let harness = try Harness()
        let original = try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions)
        try harness.repository().store(original)
        let read = try Self.supported(
            harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
        )
        #expect(read.acknowledgedExceptions.map(\.exception) == CheckpointFixtures.exceptions)
        let row = try harness.revisionRow(original.id)
        #expect(row.acknowledgmentCount == 3)
        #expect(
            row.acknowledgmentDigest
                == (try CheckpointAcknowledgmentCommitment.digest(of: original.acknowledgedExceptions))
        )
    }

    @Test("Deleting one of two same-impact acknowledgments is corruption")
    func deletingOverlappingImpactAcknowledgmentIsCorrupt() throws {
        let harness = try Harness()
        let exceptions = [
            PeriodCheckpointException(id: "overdue-one", kind: .overdueExpectedOccurrence),
            PeriodCheckpointException(id: "overdue-two", kind: .overdueExpectedOccurrence)
        ]
        try harness.repository().store(try CheckpointFixtures.revision(exceptions: exceptions))
        let row = try #require(
            try harness.rows(StoredPeriodCheckpointAcknowledgment.self).first { $0.sequence == 1 }
        )
        harness.context.delete(row)
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .acknowledgmentCountMismatch
        )
        #expect(harness.repository().occupancy() == .unreadable(.acknowledgmentCountMismatch))
        #expect(try FinanceStore(context: harness.context).importBlocker == .storeUnreadable)
    }

    @Test("Deleting uncat-1 from the three-row fixture is corruption even when claims match")
    func deletingUncategorizedFromFixtureIsCorrupt() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions))
        let remaining = CheckpointFixtures.exceptions.filter { $0.id != "uncat-1" }
        #expect(
            PeriodCheckpointSafeClaims.surviving(remaining)
                == PeriodCheckpointSafeClaims.surviving(CheckpointFixtures.exceptions)
        )
        let row = try #require(
            try harness.rows(StoredPeriodCheckpointAcknowledgment.self)
                .first { $0.exceptionIdentifier == "uncat-1" }
        )
        harness.context.delete(row)
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .acknowledgmentCountMismatch
        )
    }

    @Test("Inserting an extra acknowledgment is corruption")
    func insertingExtraAcknowledgmentIsCorrupt() throws {
        let harness = try Harness()
        let original = try CheckpointFixtures.revision(
            exceptions: [PeriodCheckpointException(id: "overdue-one", kind: .overdueExpectedOccurrence)]
        )
        try harness.repository().store(original)
        harness.context.insert(
            try StoredPeriodCheckpointAcknowledgment(
                AcknowledgedExceptionRecord(
                    exception: PeriodCheckpointException(id: "overdue-two", kind: .overdueExpectedOccurrence)
                ),
                revisionIdentifier: original.id.uuidString,
                sequence: 1
            )
        )
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .acknowledgmentCountMismatch
        )
    }

    @Test("Mutating amountMinor is an acknowledgment digest mismatch")
    func mutatingAcknowledgmentAmountIsCorrupt() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions))
        let row = try #require(
            try harness.rows(StoredPeriodCheckpointAcknowledgment.self).first { $0.amountMinor != nil }
        )
        row.amountMinor = 7_654_321
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .acknowledgmentDigestMismatch
        )
        #expect(harness.repository().occupancy() == .unreadable(.acknowledgmentDigestMismatch))
    }

    @Test("A duplicate sequence is corruption")
    func duplicateAcknowledgmentSequenceIsCorrupt() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions))
        let rows = try harness.rows(StoredPeriodCheckpointAcknowledgment.self).sorted { $0.sequence < $1.sequence }
        rows[1].sequence = 0
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .malformedAcknowledgmentSequence
        )
    }

    @Test("A negative sequence is corruption")
    func negativeAcknowledgmentSequenceIsCorrupt() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions))
        let rows = try harness.rows(StoredPeriodCheckpointAcknowledgment.self).sorted { $0.sequence < $1.sequence }
        rows[0].sequence = -1
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .malformedAcknowledgmentSequence
        )
    }

    @Test("A gapped sequence is corruption")
    func gappedAcknowledgmentSequenceIsCorrupt() throws {
        let harness = try Harness()
        let exceptions = [
            PeriodCheckpointException(id: "overdue-one", kind: .overdueExpectedOccurrence),
            PeriodCheckpointException(id: "overdue-two", kind: .overdueExpectedOccurrence)
        ]
        try harness.repository().store(try CheckpointFixtures.revision(exceptions: exceptions))
        let rows = try harness.rows(StoredPeriodCheckpointAcknowledgment.self).sorted { $0.sequence < $1.sequence }
        rows[1].sequence = 2
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .malformedAcknowledgmentSequence
        )
        #expect(harness.repository().occupancy() == .unreadable(.malformedAcknowledgmentSequence))
    }

    @Test("A one-row history whose sequence is not zero is corruption")
    func nonzeroSequenceOnSingleAcknowledgmentIsCorrupt() throws {
        let harness = try Harness()
        try harness.repository().store(
            try CheckpointFixtures.revision(
                exceptions: [PeriodCheckpointException(id: "overdue-one", kind: .overdueExpectedOccurrence)]
            )
        )
        let row = try #require(try harness.rows(StoredPeriodCheckpointAcknowledgment.self).first)
        row.sequence = 9
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .malformedAcknowledgmentSequence
        )
    }

    @Test("A dense sequence permutation is an acknowledgment digest mismatch")
    func denseSequencePermutationIsDigestMismatch() throws {
        let harness = try Harness()
        try harness.repository().store(try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions))
        let rows = try harness.rows(StoredPeriodCheckpointAcknowledgment.self).sorted { $0.sequence < $1.sequence }
        rows[0].sequence = 2
        rows[1].sequence = 1
        rows[2].sequence = 0
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .acknowledgmentDigestMismatch
        )
    }

    @Test("Acknowledgment digest commits to order, not to a set")
    func acknowledgmentDigestIsOrderSensitive() throws {
        let records = CheckpointFixtures.exceptions.map(AcknowledgedExceptionRecord.init)
        let forward = try CheckpointAcknowledgmentCommitment.digest(of: records)
        let reversed = try CheckpointAcknowledgmentCommitment.digest(of: records.reversed().map { $0 })
        #expect(forward != reversed)
        #expect(forward.count == 32)
    }

    // MARK: - Full-chain integrity

    @Test("A corrupt supported predecessor makes latestRevision corrupt")
    func corruptPredecessorMakesLatestCorrupt() throws {
        let harness = try Harness()
        let first = try CheckpointFixtures.revision()
        let second = try CheckpointFixtures.revision(revisionNumber: 2, predecessorID: first.id)
        try harness.repository().store(first)
        try harness.repository().store(second)
        try harness.revisionRow(first.id).projectionDigest = Data(repeating: 0, count: 32)
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .digestMismatch
        )
        guard case .corrupt(.digestMismatch) =
            harness.repository().revisions(inPeriod: CheckpointFixtures.august, kind: .monthly)
        else {
            Issue.record("revisions must agree with latestRevision about chain integrity")
            return
        }
        #expect(harness.repository().occupancy() == .unreadable(.digestMismatch))
        #expect(try FinanceStore(context: harness.context).importBlocker == .storeUnreadable)
    }

    @Test("A broken chain refuses a further append")
    func appendOnBrokenChainIsRefused() throws {
        let harness = try Harness()
        let first = try CheckpointFixtures.revision()
        let second = try CheckpointFixtures.revision(revisionNumber: 2, predecessorID: first.id)
        try harness.repository().store(first)
        try harness.repository().store(second)
        try harness.revisionRow(second.id).predecessorIdentifier = UUID().uuidString
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .predecessorNotFound
        )
        #expect(throws: PeriodCheckpointStoreError.corrupt(.predecessorNotFound)) {
            try harness.repository().store(
                try CheckpointFixtures.revision(revisionNumber: 3, predecessorID: second.id)
            )
        }
        #expect(try harness.rows(StoredPeriodCheckpointRevision.self).count == 2)
    }

    @Test("V1 then unsupported V2 reads as unsupported latest")
    func supportedThenUnsupportedLatestIsUnsupported() throws {
        let harness = try Harness()
        let first = try CheckpointFixtures.revision()
        let second = try CheckpointFixtures.revision(revisionNumber: 2, predecessorID: first.id)
        try harness.repository().store(first)
        try harness.repository().store(second)
        let row = try harness.revisionRow(second.id)
        row.projectionFormatToken = "v2"
        row.canonicalProjection = Data([0xDE, 0xAD])
        try harness.save()

        guard case .unsupportedFormat = harness.repository().latestRevision(
            inPeriod: CheckpointFixtures.august, kind: .monthly
        ) else {
            Issue.record("a V2 latest is unsupported, not supported or corrupt")
            return
        }
        guard case let .history(history) = harness.repository().revisions(
            inPeriod: CheckpointFixtures.august, kind: .monthly
        ) else {
            Issue.record("V1 then V2 is a readable mixed history")
            return
        }
        #expect(history.count == 2)
        #expect(harness.repository().occupancy() == .holdsCheckpointHistory)
        #expect(try FinanceStore(context: harness.context).importBlocker == .storeNotEmpty)
        #expect(throws: PeriodCheckpointStoreError.rejected(.existingHistoryNotSupported)) {
            try harness.repository().store(
                try CheckpointFixtures.revision(revisionNumber: 3, predecessorID: second.id)
            )
        }
    }

    @Test("Unsupported V2 then supported V1 is not a supported latest")
    func unsupportedThenSupportedIsNotSupported() throws {
        let harness = try Harness()
        let first = try CheckpointFixtures.revision()
        let second = try CheckpointFixtures.revision(revisionNumber: 2, predecessorID: first.id)
        try harness.repository().store(first)
        try harness.repository().store(second)
        let row = try harness.revisionRow(first.id)
        row.projectionFormatToken = "v2"
        row.canonicalProjection = Data()
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .incompatibleFormatChain
        )
        guard case .corrupt(.incompatibleFormatChain) = harness.repository().revisions(
            inPeriod: CheckpointFixtures.august, kind: .monthly
        ) else {
            Issue.record("revisions must not present a supported latest on an unverifiable predecessor")
            return
        }
        #expect(throws: PeriodCheckpointStoreError.corrupt(.incompatibleFormatChain)) {
            try harness.repository().store(
                try CheckpointFixtures.revision(revisionNumber: 3, predecessorID: second.id)
            )
        }
    }

    @Test("A corrupt March chain does not make September unreadable")
    func periodLocalCorruptionDoesNotPoisonAnotherPeriod() throws {
        let harness = try Harness()
        let march = SemanticInterval(
            start: Day(year: 2026, month: 3, day: 1),
            end: Day(year: 2026, month: 3, day: 31)
        )
        let marchRevision = try CheckpointFixtures.revision(period: march)
        let september = try CheckpointFixtures.revision(period: CheckpointFixtures.september)
        try harness.repository().store(marchRevision)
        try harness.repository().store(september)
        try harness.revisionRow(marchRevision.id).projectionDigest = Data(repeating: 0, count: 32)
        try harness.save()

        #expect(
            try Self.supported(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.september, kind: .monthly)
            ).id == september.id
        )
        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: march, kind: .monthly)
            ) == .digestMismatch
        )
        #expect(harness.repository().occupancy() == .unreadable(.digestMismatch))
        #expect(try FinanceStore(context: harness.context).importBlocker == .storeUnreadable)
    }

    @Test("A malformed V1 payload makes occupancy unreadable")
    func malformedPayloadMakesOccupancyUnreadable() throws {
        let harness = try Harness()
        let revision = try CheckpointFixtures.revision()
        try harness.repository().store(revision)
        try harness.revisionRow(revision.id).canonicalProjection = Data([0x00, 0x01, 0x02])
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
            ) == .malformedCanonicalPayload
        )
        #expect(harness.repository().occupancy() == .unreadable(.malformedCanonicalPayload))
        #expect(try FinanceStore(context: harness.context).importBlocker == .storeUnreadable)
    }

    @Test("An unsupported V2 history occupies the store without being unreadable")
    func unsupportedHistoryOccupiesWithoutUnreadability() throws {
        let harness = try Harness()
        let revision = try CheckpointFixtures.revision()
        try harness.repository().store(revision)
        let row = try harness.revisionRow(revision.id)
        row.projectionFormatToken = "v2"
        row.canonicalProjection = Data([0xFF])
        try harness.save()

        guard case .unsupportedFormat = harness.repository().latestRevision(
            inPeriod: CheckpointFixtures.august, kind: .monthly
        ) else {
            Issue.record("a lone V2 revision is unsupported")
            return
        }
        #expect(harness.repository().occupancy() == .holdsCheckpointHistory)
        #expect(try FinanceStore(context: harness.context).importBlocker == .storeNotEmpty)
        #expect(try FinanceStore(context: harness.context).isEmpty == false)
    }

    // MARK: - There is no store to write to

    @Test("A store with no context reads empty and refuses to write")
    func contextlessRepositoryRefusesWrites() throws {
        let repository = PeriodCheckpointRepository(context: nil)
        guard case .empty = repository.latestRevision(inPeriod: CheckpointFixtures.august, kind: .monthly)
        else { Issue.record("a contextless repository has nothing to read"); return }
        #expect(repository.occupancy() == .empty)
        #expect(throws: PeriodCheckpointStoreError.storeUnavailable) {
            try repository.store(try CheckpointFixtures.revision())
        }
    }
}
