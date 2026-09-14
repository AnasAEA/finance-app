import Foundation
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

@MainActor
@Suite("Day F3 checked boundaries")
struct DayF3BoundaryTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema(FinanceSchema.models),
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func initializationSamplesOnceAcrossMidnight() throws {
        let db = try container()
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-09-10T23:59:59Z"))
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        var calls = 0
        let store = try FinanceStore(context: db.mainContext, clock: {
            defer { calls += 1 }
            return instant.addingTimeInterval(Double(calls) * 60)
        }, timeZone: zone)
        #expect(calls == 1)
        #expect(store.initialDay == CalendarDay(year: 2026, month: 9, day: 10))
        #expect(store.publishedEvaluation.snapshot.snapshot.asOf == store.initialDay)
    }

    @Test func laterEventsUseTheirOperationInstant() async throws {
        let db = try container()
        try StoredDocumentGraph.replace(with: EntryFixtures.document(), in: db.mainContext, writtenOn: EntryFixtures.today)
        let clock = TestClock()
        let launch = clock.current
        let store = try FinanceStore(context: db.mainContext, clock: { clock.sample() })
        #expect(clock.calls == 1)
        var evidence = BankSyncSnapshot()
        evidence.accounts = [.init(id: "synthetic-remote", provider: .bnp,
            displayName: "Synthetic", product: nil, cashAccountType: nil,
            currencyCode: "EUR", syncedFrom: nil, syncedThrough: nil)]
        try await store.importBankEvidence(from: ClockProvider(snapshot: evidence))
        clock.current = launch.addingTimeInterval(3600)
        try store.mapRemoteAccount("synthetic-remote", toLocalAccount: EntryFixtures.bank.id)
        #expect(try store.exportDocument().externalAccountBindings.first?.createdAt == clock.current)
        clock.current = launch.addingTimeInterval(7200)
        try store.checkpoints.store(CheckpointFixtures.revision())
        #expect(try db.mainContext.fetch(FetchDescriptor<StoredPeriodCheckpointDataset>()).first?.establishedAt == clock.current)
        _ = try store.history.prepareImport(data: HistoryArchiveFixture.data())
        clock.current = launch.addingTimeInterval(10800)
        _ = try store.history.confirmImport()
        #expect(try store.history.metadata()?.importedAt == clock.current)
        #expect(clock.calls > 1)
    }

    @Test func syncSamplesAfterSuspendedEvidenceCompletes() async throws {
        let clock = TestClock()
        let store = try FinanceStore(context: nil, clock: { clock.sample() })
        let gate = EvidenceGate()
        clock.current = clock.current.addingTimeInterval(7140)
        let sync = Task { await store.syncNow(using: SuspendedClockProvider(gate: gate)) }
        while !(await gate.waiting) { await Task.yield() }
        clock.current = clock.current.addingTimeInterval(60)
        let completedAt = clock.current
        await gate.resume()
        await sync.value
        #expect(store.bankSyncActivity == .succeeded(at: completedAt))
    }

    @Test func freshnessAgesTogetherAtTheExactThreshold() async throws {
        let clock = TestClock()
        let launch = clock.current
        let store = try FinanceStore(context: nil, clock: { clock.sample() })
        let lastSync = launch.addingTimeInterval(-3600)
        var evidence = BankSyncSnapshot()
        evidence.connections = [.init(id: "synthetic-connection", provider: .bnp,
            institution: "Synthetic", status: "active", validUntil: nil,
            lastSuccessfulSyncAt: lastSync, lastErrorCode: nil)]
        try await store.importBankEvidence(from: ClockProvider(snapshot: evidence))
        let ages: [TimeInterval] = [172_799, 172_800, 172_801, 262_800]
        for elapsed in ages {
            clock.current = lastSync.addingTimeInterval(elapsed)
            let before = clock.calls
            let presentation = store.currentPresentation()
            #expect(clock.calls == before + 1)
            let expected: BankFreshness = elapsed > BankFreshness.staleAfter ? .stale(lastSync) : .updated(lastSync)
            #expect(presentation.freshness.state == expected)
            #expect(presentation.attention == store.attentionPresentation)
            #expect(store.bankFreshness == expected)
            #expect(store.freshnessEvaluation().state == expected)
            #expect(presentation.freshness.state.requiresAction == (elapsed > BankFreshness.staleAfter))
            #expect(presentation.freshness.caption == expected.caption(relativeTo: clock.current))
            if elapsed > BankFreshness.staleAfter {
                #expect(presentation.freshness.caption?.contains("check sync") == true)
            }
            if elapsed == 262_800 {
                #expect(presentation.freshness.caption == "Last sync 3 days ago · check sync")
            }
        }
    }

    @Test func providerUTCDesignatorCompatibilityStaysStrict() throws {
        let upper = try MobileSnapshotMapper.requiredTimestamp("2026-09-09T12:34:56Z")
        #expect(try MobileSnapshotMapper.requiredTimestamp("2026-09-09T12:34:56z") == upper)
        for text in ["2026-09-09T12:34:56zjunk", "2026-02-30T12:34:56z", "2026-09-09T12:34:56+25:00", "2026-09-09T12:34z"] {
            #expect(throws: BankSyncClientError.malformedResponse) { try MobileSnapshotMapper.requiredTimestamp(text) }
        }
    }

    @Test func needsReviewCompositionSamplesOnceAcrossFreshnessBoundary() async throws {
        let clock = TestClock()
        let store = try FinanceStore(context: nil, clock: { clock.sample() })
        let lastSync = clock.current.addingTimeInterval(-3600)
        var evidence = BankSyncSnapshot()
        evidence.connections = [.init(id: "synthetic-connection", provider: .bnp,
            institution: "Synthetic", status: "active", validUntil: nil,
            lastSuccessfulSyncAt: lastSync, lastErrorCode: nil)]
        try await store.importBankEvidence(from: ClockProvider(snapshot: evidence))
        clock.current = lastSync.addingTimeInterval(172_799)
        clock.step = 2
        clock.samples = []
        // The exact builder called by NeedsReviewView.body, not a parallel model.
        _ = NeedsReviewView.content(store: store)
        #expect(clock.samples == [lastSync.addingTimeInterval(172_799)])
        #expect(clock.samples.map { $0.timeIntervalSince(lastSync) > BankFreshness.staleAfter } == [false])
        // A later body pass may age naturally; sections within either pass cannot.
        clock.samples = []
        _ = NeedsReviewView.content(store: store)
        #expect(clock.samples == [lastSync.addingTimeInterval(172_801)])
        #expect(clock.samples.map { $0.timeIntervalSince(lastSync) > BankFreshness.staleAfter } == [true])
    }

    @Test func snapshotRecalculationDoesNotComposeUnusedAttention() throws {
        let clock = TestClock()
        let store = try FinanceStore(context: nil, clock: { clock.sample() })
        let calls = clock.calls
        // A real scenario change, so the snapshot half is observably still done.
        store.scenario = .upside
        #expect(store.publishedEvaluation.snapshot.snapshot.scenario == .upside)
        // F4 needs a current day for the scenario operation, but still composes
        // no attention here. A dead attention read would add another sample.
        #expect(clock.calls == calls + 1)
        _ = store.currentPresentation()
        #expect(clock.calls == calls + 2)
    }

    @Test func failedClockInitializationDoesNotTouchExistingData() throws {
        let db = try container()
        let original = EntryFixtures.document()
        try StoredDocumentGraph.replace(with: original, in: db.mainContext, writtenOn: EntryFixtures.today)
        let revision = try #require(db.mainContext.fetch(FetchDescriptor<StoredDocumentMeta>()).first?.documentRevision)
        // Three instants that cannot be a CE civil day: two non-finite, and one
        // explicitly far outside the era. `Date.distantPast` is deliberately not
        // used — Foundation's era handling for it differs between OS versions,
        // which makes the same assertion pass on one machine and fail on another.
        let beforeTheEra = Date(timeIntervalSinceReferenceDate: -1_000_000_000_000)
        for instant in [Date(timeIntervalSinceReferenceDate: .nan), Date(timeIntervalSinceReferenceDate: .infinity), beforeTheEra] {
            #expect(throws: FinanceClockError.currentDayUnavailable) {
                try FinanceStore(context: db.mainContext, clock: { instant })
            }
        }
        #expect(try db.mainContext.fetch(FetchDescriptor<StoredDocumentMeta>()).first?.documentRevision == revision)
        #expect(try db.mainContext.fetchCount(FetchDescriptor<StoredAccount>()) == original.accounts.count)
        #expect(!db.mainContext.hasChanges)
    }

    @Test func requiredAndOptionalPersistenceDatesAreChecked() throws {
        let bad = Day(year: Int.max, month: 1, day: 1)
        let ordinary = EntryFixtures.today
        #expect(try PersistenceCoding.ordinal(ordinary) == 20260916)
        #expect(try PersistenceCoding.ordinal(nil as Day?) == nil)
        #expect(throws: PersistenceMappingError.unrepresentableDay) { try PersistenceCoding.ordinal(bad) }
        #expect(throws: PersistenceMappingError.unrepresentableDay) { try PersistenceCoding.ordinal(Optional(bad)) }
        let tx = Transaction(id: "f3-synthetic", date: ordinary, kind: .expense,
                             legs: [AccountLeg(accountID: EntryFixtures.bank.id, amount: Money(minorUnits: -1, currency: .eur))], factivity: .observed, bookedDate: bad)
        #expect(throws: PersistenceMappingError.unrepresentableDay) { try StoredTransaction(tx, sequence: 0) }
        #expect(throws: PersistenceMappingError.unsupportedEncodedValue) {
            try PersistenceCoding.encode(RecurrenceSpec.oneShot(on: bad))
        }
    }

    @Test func replacementPreflightPreservesSavedAndPendingState() throws {
        let db = try container()
        let original = EntryFixtures.document()
        try StoredDocumentGraph.replace(with: original, in: db.mainContext, writtenOn: EntryFixtures.today)
        let meta = try #require(db.mainContext.fetch(FetchDescriptor<StoredDocumentMeta>()).first)
        let revision = meta.documentRevision
        // An unsaved change proves the writer did not purge and rollback first.
        meta.note = "Synthetic pending note"
        var replacement = original
        let balance = replacement.balances[0]
        replacement.balances[0] = AccountBalance(accountID: balance.accountID, balance: balance.balance, asOf: Day(year: Int.max, month: 1, day: 1), status: balance.status)
        #expect(throws: PersistenceMappingError.unrepresentableDay) {
            try StoredDocumentGraph.replace(with: replacement, in: db.mainContext, writtenOn: EntryFixtures.today)
        }
        #expect(meta.note == "Synthetic pending note")
        #expect(meta.documentRevision == revision)
        #expect(try db.mainContext.fetchCount(FetchDescriptor<StoredAccount>()) == original.accounts.count)
        db.mainContext.rollback()
        #expect(try db.mainContext.fetch(FetchDescriptor<StoredDocumentMeta>()).first?.documentRevision == revision)
    }

    @Test func civilIngressAndFoundationRefuseInvalidValues() throws {
        let invalid = CalendarDay(year: 2026, month: 2, day: 30)
        #expect(DomainMapper.day(invalid) == nil)
        #expect(throws: AppEntryError.invalidDate) { try DomainMapper.requiredDay(invalid, or: AppEntryError.invalidDate) }
        for civil in [invalid, CalendarDay(year: Int.max, month: 1, day: 1), CalendarDay(year: Int.min, month: 1, day: 1), CalendarDay(year: 0, month: 1, day: 1)] {
            #expect(civil.date() == nil)
        }
        let extreme = Day(year: Int.min, month: 1, day: 1)
        #expect(DomainMapper.civilDay(extreme).description == "-9223372036854775808-01-01")
        #expect(DomainMapper.civilDay(extreme).formatted(.dateTime.year()) == extreme.isoString)
        let shell = DomainMapper().snapshotWithoutProjection(document: EntryFixtures.document(), today: extreme, scenario: .base, horizonDays: 120, incomeSourceActive: [:], lastExpenseAccountID: nil, lastIncomeAccountID: nil)
        #expect(shell.asOf == DomainMapper.civilDay(extreme))
    }

    @Test func optionalProviderDatesDistinguishAbsenceFromMalformed() throws {
        #expect(try MobileSnapshotMapper.optionalDay(nil) == nil)
        #expect(try MobileSnapshotMapper.optionalTimestamp(nil) == nil)
        for text in ["", "2026-02-30", "not-a-date", "+10000-01-01"] {
            #expect(throws: BankSyncClientError.malformedResponse) { try MobileSnapshotMapper.optionalDay(text) }
        }
        #expect(throws: BankSyncClientError.malformedResponse) { try MobileSnapshotMapper.requiredTimestamp("bad") }
        #expect(throws: BankSyncClientError.malformedResponse) { try MobileSnapshotMapper.optionalTimestamp("bad") }
        #expect(try MobileSnapshotMapper.optionalDay("2026-09-09") == Day(year: 2026, month: 9, day: 9))
        #expect(try MobileSnapshotMapper.requiredTimestamp("1970-01-01T00:00:00Z") == Date(timeIntervalSince1970: 0))
    }

    @Test func identifiersKeepStructuralDatesAndStorageDomain() throws {
        for (year, text) in [(2026, "2026-01-01"), (10000, "+10000-01-01"), (-1, "-0001-01-01"), (-10000, "-10000-01-01"), (Int.min, "-9223372036854775808-01-01"), (Int.max, "+9223372036854775807-01-01")] {
            let id = "obligation@" + text
            let occurrence = try #require(DomainMapper.occurrenceID(id))
            #expect(occurrence.expectedDay == Day(year: year, month: 1, day: 1))
            #expect(DomainMapper.expectedPaymentID(occurrence) == id)
        }
        let amount = Money(minorUnits: 123, currency: .eur)
        #expect(throws: PersistenceMappingError.unrepresentableMonth) {
            try StoredBudgetOverride.persistedIdentifier(month: MonthKey(year: Int.max, month: 1), budgetID: "budget")
        }
        let ordinary = try StoredBudgetOverride(month: MonthKey(year: 2026, month: 9), amount: amount, budgetID: "budget")
        #expect(ordinary.identifier == "budget#2026-09")
        #expect(ordinary.monthOrdinal == 202609)
        #expect(throws: PersistenceMappingError.unrepresentableMonth) {
            try StoredBudgetOverride(month: MonthKey(year: Int.max, month: 1), amount: amount, budgetID: "budget")
        }
    }

    @Test func checkpointPeriodBoundsArePreflighted() throws {
        for period in [
            SemanticInterval(start: Day(year: 214749, month: 1, day: 1), end: Day(year: 214749, month: 1, day: 2)),
            SemanticInterval(start: Day(year: 214748, month: 12, day: 31), end: Day(year: 214749, month: 1, day: 1))
        ] {
            let db = try container()
            let repository = PeriodCheckpointRepository(context: db.mainContext)
            let revision = try CheckpointFixtures.revision(period: period, kind: .monthly)
            #expect(throws: PeriodCheckpointStoreError.rejected(.unrepresentableDate)) { try repository.store(revision) }
            #expect(try db.mainContext.fetchCount(FetchDescriptor<StoredPeriodCheckpointDataset>()) == 0)
            #expect(try db.mainContext.fetchCount(FetchDescriptor<StoredPeriodCheckpointRevision>()) == 0)
            // Exercise the repository's private context with a subsequent save.
            let good = try CheckpointFixtures.revision()
            try repository.store(good)
            #expect(try db.mainContext.fetchCount(FetchDescriptor<StoredPeriodCheckpointDataset>()) == 1)
            let saved = try db.mainContext.fetch(FetchDescriptor<StoredPeriodCheckpointRevision>())
            #expect(saved.count == 1)
            #expect(saved.first?.identifier == good.id.uuidString)
        }
    }

    @Test func checkpointUnrepresentableExceptionDoesNotAppendOrMintDataset() throws {
        let db = try container()
        let repository = PeriodCheckpointRepository(context: db.mainContext)
        let exception = PeriodCheckpointException(id: "synthetic", kind: .overdueExpectedOccurrence,
            day: Day(year: Int.max, month: 1, day: 1))
        let invalid = try CheckpointFixtures.revision(exceptions: [exception])
        #expect(throws: PeriodCheckpointStoreError.rejected(.unrepresentableDate)) { try repository.store(invalid) }
        #expect(try db.mainContext.fetchCount(FetchDescriptor<StoredPeriodCheckpointDataset>()) == 0)
        #expect(try db.mainContext.fetchCount(FetchDescriptor<StoredPeriodCheckpointRevision>()) == 0)
        #expect(try db.mainContext.fetchCount(FetchDescriptor<StoredPeriodCheckpointAcknowledgment>()) == 0)
        let good = try CheckpointFixtures.revision()
        try repository.store(good)
        #expect(try db.mainContext.fetchCount(FetchDescriptor<StoredPeriodCheckpointDataset>()) == 1)
        #expect(try db.mainContext.fetchCount(FetchDescriptor<StoredPeriodCheckpointAcknowledgment>()) == 0)
        let invalidNext = try CheckpointFixtures.revision(revisionNumber: 2, predecessorID: good.id, exceptions: [exception])
        #expect(throws: PeriodCheckpointStoreError.rejected(.unrepresentableDate)) { try repository.store(invalidNext) }
        #expect(try db.mainContext.fetchCount(FetchDescriptor<StoredPeriodCheckpointRevision>()) == 1)
        let next = try CheckpointFixtures.revision(revisionNumber: 2, predecessorID: good.id)
        try repository.store(next)
        #expect(try db.mainContext.fetchCount(FetchDescriptor<StoredPeriodCheckpointRevision>()) == 2)
    }
}

@MainActor
private final class TestClock {
    var current = Date(timeIntervalSince1970: 1_789_034_400)
    var calls = 0
    var step: TimeInterval = 0
    var samples: [Date] = []
    func sample() -> Date {
        calls += 1
        samples.append(current)
        defer { current = current.addingTimeInterval(step) }
        return current
    }
}

private struct ClockProvider: BankSyncProviding {
    let snapshot: BankSyncSnapshot
    func runRemoteSync() async throws {}
    func fetchSnapshot(bindings: [ExternalAccountBinding], since: String?) async throws -> BankSyncSnapshot { snapshot }
}

private actor EvidenceGate {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiting = true
        }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

private struct SuspendedClockProvider: BankSyncProviding {
    let gate: EvidenceGate
    func runRemoteSync() async throws { await Task.yield() }
    func fetchSnapshot(bindings: [ExternalAccountBinding], since: String?) async throws -> BankSyncSnapshot {
        await gate.suspend()
        return BankSyncSnapshot()
    }
}
