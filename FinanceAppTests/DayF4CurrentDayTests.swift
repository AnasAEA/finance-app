import Foundation
import FinanceCore
import SwiftData
import Testing
@testable import FinanceApp

@MainActor
@Suite("Day F4 current operations")
struct DayF4CurrentDayTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let first = Day(year: 2026, month: 9, day: 10)
    private let next = Day(year: 2026, month: 9, day: 11)

    private func instant(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema(FinanceSchema.models),
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func document() -> FinanceDocument {
        var doc = EntryFixtures.document()
        doc.balances = [AccountBalance(accountID: EntryFixtures.bank.id,
            balance: Money(minorUnits: 100_000, currency: .eur),
            asOf: Day(year: 2026, month: 9, day: 1))]
        doc.planning.recurringObligations = [RecurringObligation(
            id: "synthetic-midnight", name: "Synthetic monthly payment",
            amount: Money(minorUnits: 100, currency: .eur),
            spec: .monthly(onDay: 10, from: MonthKey(year: 2026, month: 9), through: nil),
            requirement: .euroBankPayment(), spendingClass: .optional
        )]
        return doc
    }

    @Test func midnightSequenceUsesProductionDefaultsSnapshotReviewAndForecast() throws {
        let db = try container()
        try StoredDocumentGraph.replace(with: document(), in: db.mainContext, writtenOn: first)
        let clock = F4Clock(try instant("2026-09-10T23:59:00Z"))
        var starts: [Day] = []
        let store = try FinanceStore(context: db.mainContext, clock: { clock.sample() }, timeZone: utc,
            forecastRunner: { request in
                starts.append(request.startDate)
                return try ForecastEngine.run(request)
            })
        #expect(clock.samples.count == 1)
        #expect(store.initialDay == DomainMapper.civilDay(first))
        #expect(store.publishedEvaluation.snapshot.snapshot.asOf == DomainMapper.civilDay(first))
        for (text, expected) in [("2026-09-10T23:59:30Z", first),
                                 ("2026-09-11T00:00:30Z", next),
                                 ("2026-09-11T12:00:00Z", next)] {
            clock.current = try instant(text)
            clock.samples = []
            let day = DomainMapper.civilDay(expected)
            // These are the methods the new sheets call, not copies of defaults.
            #expect(AddTransactionSheet.defaultDate(store: store) == day)
            #expect(GoalEditorView.defaultDate(store: store) == day)
            #expect(store.makeAffordabilityDraft().on == day)
            let defaults = store.affordabilityDefaults()
            #expect(defaults.day == day)
            #expect(defaults.range.flatMap { CalendarDay($0.lowerBound, in: utc) } == day)
            let end = try #require(expected.advanced(by: 119))
            #expect(defaults.range.flatMap { CalendarDay($0.upperBound, in: utc) } == DomainMapper.civilDay(end))
            #expect(store.defaultBoundaryDay(for: EntryFixtures.wallet.id) == day)
            #expect(store.defaultBoundaryDay(for: EntryFixtures.bank.id) == CalendarDay(year: 2026, month: 9, day: 1))
            let before = clock.samples.count
            let runs = starts.count
            let presentation = store.currentPresentation()
            #expect(clock.samples.count == before + 1)
            #expect(presentation.freshness.reference == clock.current)
            #expect(presentation.snapshot.asOf == day)
            #expect(starts.last == expected)
            #expect(starts.count <= runs + 1)
            #expect(presentation.snapshot.expectedPayments.first { $0.ruleID == "synthetic-midnight" }?.status == (expected == first ? .due : .overdue))
            let reviewBefore = clock.samples.count
            let review = try #require(store.review(.init()))
            #expect(review.rangeLabel == "1 Sep – \(expected.day) Sep · so far")
            #expect(clock.samples.count == reviewBefore + 1)
            let currentRuns = starts.count
            _ = store.snapshot
            _ = store.currentPresentation()
            #expect(starts.count == currentRuns, "same-day reads reuse the exact forecast")
        }
    }

    @Test func compositionCannotStraddleMidnightOnASecondSample() throws {
        let db = try container()
        try StoredDocumentGraph.replace(with: document(), in: db.mainContext, writtenOn: first)
        let clock = F4Clock(try instant("2026-09-10T23:59:00Z"))
        let store = try FinanceStore(context: db.mainContext, clock: { clock.sample() }, timeZone: utc)
        clock.current = try instant("2026-09-10T23:59:59Z")
        clock.step = 2
        clock.samples = []
        let presentation = store.currentPresentation()
        #expect(clock.samples.count == 1)
        #expect(presentation.snapshot.asOf == DomainMapper.civilDay(first))
        #expect(presentation.freshness.reference == clock.samples.first)
        #expect(presentation.snapshot.expectedPayments.first?.status == .due)
        let after = store.currentPresentation()
        #expect(clock.samples.count == 2)
        #expect(after.snapshot.asOf == DomainMapper.civilDay(next))
        #expect(after.snapshot.expectedPayments.first?.status == .overdue)
    }

    @Test func bindingAuditBoundaryAndWriterShareOneInstant() async throws {
        let db = try container()
        try StoredDocumentGraph.replace(with: document(), in: db.mainContext, writtenOn: first)
        let clock = F4Clock(try instant("2026-09-10T23:59:00Z"))
        var writtenDays: [Day] = []
        let writer = DocumentWriter { document, context, day, presentation, metadata in
            writtenDays.append(day)
            try DocumentWriter.live.write(document, context, day, presentation, metadata)
        }
        let store = try FinanceStore(context: db.mainContext, clock: { clock.sample() }, timeZone: utc, writer: writer)
        var directory = BankSyncSnapshot()
        directory.accounts = [.init(id: "synthetic-f4-remote", provider: .bnp,
            displayName: "Synthetic", product: nil, cashAccountType: nil,
            currencyCode: "EUR", syncedFrom: nil, syncedThrough: nil)]
        try await store.importBankEvidence(from: F4Provider(snapshot: directory))
        clock.current = try instant("2026-09-11T23:59:59Z")
        clock.step = 2
        clock.samples = []
        try store.mapRemoteAccount("synthetic-f4-remote", toLocalAccount: EntryFixtures.wallet.id)
        let binding = try #require(try store.exportDocument().externalAccountBindings.first)
        #expect(clock.samples.count == 1)
        #expect(binding.createdAt == clock.samples.first)
        #expect(binding.syncStartBoundary == next)
        #expect(writtenDays.last == next)
        #expect(store.publishedEvaluation.snapshot.snapshot.asOf == DomainMapper.civilDay(next))
    }

    @Test func configuredZonesAndSkippedLocalMidnightAreRespected() throws {
        let now = try instant("2026-09-10T22:30:00Z")
        for (zone, expected) in [(utc, first), (try #require(TimeZone(identifier: "Europe/Paris")), next)] {
            let clock = F4Clock(now.addingTimeInterval(-86400))
            let store = try FinanceStore(context: nil, clock: { clock.sample() }, timeZone: zone)
            clock.current = now
            #expect(store.currentDay() == DomainMapper.civilDay(expected))
            #expect(AddTransactionSheet.defaultDate(store: store) == DomainMapper.civilDay(expected))
            #expect(store.currentPresentation().snapshot.asOf == DomainMapper.civilDay(expected))
        }
        let zone = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        let clock = F4Clock(try instant("2018-11-03T15:00:00Z"))
        let store = try FinanceStore(context: nil, clock: { clock.sample() }, timeZone: zone)
        // Brazil advanced from 23:59 to 01:00; this local day has no midnight.
        clock.current = try instant("2018-11-04T03:30:00Z")
        let day = CalendarDay(year: 2018, month: 11, day: 4)
        #expect(store.currentDay() == day)
        #expect(store.currentPresentation().snapshot.asOf == day)
        #expect(day.date(in: zone).flatMap { CalendarDay($0, in: zone) } == day)
    }

    @Test func unavailableCurrentDayRefusesBeforeMutationAndPreservesDatedData() throws {
        let db = try container()
        let original = document()
        try StoredDocumentGraph.replace(with: original, in: db.mainContext, writtenOn: first)
        let clock = F4Clock(try instant("2026-09-10T23:59:00Z"))
        let store = try FinanceStore(context: db.mainContext, clock: { clock.sample() }, timeZone: utc)
        let revision = try #require(db.mainContext.fetch(FetchDescriptor<StoredDocumentMeta>()).first?.documentRevision)
        clock.current = Date(timeIntervalSinceReferenceDate: .nan)
        #expect(store.currentDay() == nil)
        #expect(AddTransactionSheet.defaultDate(store: store) == nil)
        #expect(store.affordabilityDefaults().range == nil)
        #expect(store.defaultBoundaryDay(for: EntryFixtures.wallet.id) == nil)
        #expect(store.review(.init()) == nil)
        let presentation = store.currentPresentation()
        #expect(presentation.projectionFailed)
        #expect(!presentation.attention.heroIsAvailable)
        #expect(presentation.snapshot.asOf == DomainMapper.civilDay(first)) // last dated data, not a current day
        #expect(store.loadFailure == nil)
        #expect(throws: AppEntryError.currentDayUnavailable) { try store.add(EntryFixtures.draft()) }
        #expect(try store.exportDocument() == original)
        #expect(try db.mainContext.fetch(FetchDescriptor<StoredDocumentMeta>()).first?.documentRevision == revision)
        #expect(!db.mainContext.hasChanges)
        // An independently invalid input still gets its original validation error.
        var invalid = EntryFixtures.draft()
        invalid.day = CalendarDay(year: 2026, month: 2, day: 30)
        #expect(throws: AppEntryError.invalidDate) { try store.add(invalid) }
        clock.current = try instant("2026-09-11T00:10:00Z")
        #expect(store.currentPresentation().snapshot.asOf == DomainMapper.civilDay(next))
    }

    @Test func explicitFixtureDaysRemainIndependentOfTheirInstant() throws {
        let fixture = FinanceStore(document: document(), today: first,
                                   now: try instant("2030-01-01T00:00:00Z"), scenario: .base)
        #expect(fixture.currentDay() == DomainMapper.civilDay(first))
        #expect(fixture.currentPresentation().snapshot.asOf == DomainMapper.civilDay(first))
        let fixed = FinanceStore(snapshot: .empty(asOf: DomainMapper.civilDay(first)),
                                 now: try instant("2030-01-01T00:00:00Z"))
        #expect(fixed.currentDay() == DomainMapper.civilDay(first))
    }
}

@MainActor
private final class F4Clock {
    var current: Date
    var step: TimeInterval = 0
    var samples: [Date] = []
    init(_ current: Date) { self.current = current }
    func sample() -> Date {
        samples.append(current)
        defer { current = current.addingTimeInterval(step) }
        return current
    }
}

private struct F4Provider: BankSyncProviding {
    let snapshot: BankSyncSnapshot
    func runRemoteSync() async throws {}
    func fetchSnapshot(bindings: [ExternalAccountBinding], since: String?) async throws -> BankSyncSnapshot { snapshot }
}
