import Foundation
import FinanceCore
import SwiftData
import SwiftUI
import Testing
@testable import FinanceApp

/// One SwiftUI body evaluation is one logical presentation composition: it may
/// sample the current civil day once, and every section it builds must describe
/// that one day. These exercise the production builders, not copies of them.
@MainActor
@Suite("Day F4 presentation coherence")
struct DayF4PresentationCoherenceTests {
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

    /// A document with one obligation due on the 10th, so the civil day the
    /// composition samples decides whether its row reads "due" or "overdue".
    private func document() -> FinanceDocument {
        var doc = EntryFixtures.document()
        doc.balances = [AccountBalance(accountID: EntryFixtures.bank.id,
            balance: Money(minorUnits: 100_000, currency: .eur),
            asOf: Day(year: 2026, month: 9, day: 1))]
        doc.planning.recurringObligations = [RecurringObligation(
            id: "synthetic-coherence", name: "Synthetic monthly payment",
            amount: Money(minorUnits: 100, currency: .eur),
            spec: .monthly(onDay: 10, from: MonthKey(year: 2026, month: 9), through: nil),
            requirement: .euroBankPayment(), spendingClass: .optional
        )]
        return doc
    }

    private func store(_ clock: CoherenceClock, _ db: ModelContainer) throws -> FinanceStore {
        try FinanceStore(context: db.mainContext, clock: { clock.sample() }, timeZone: utc)
    }

    @Test func expectedPaymentsListTakesOneSampleAcrossMidnight() throws {
        let db = try container()
        try StoredDocumentGraph.replace(with: document(), in: db.mainContext, writtenOn: first)
        let clock = CoherenceClock(try instant("2026-09-10T23:59:00Z"))
        let store = try store(clock, db)
        clock.current = try instant("2026-09-10T23:59:59Z")
        // Any second sample this composition takes lands on the next civil day.
        clock.step = 2
        clock.samples = []
        // The exact list ExpectedPaymentsView.body builds, not a parallel model.
        _ = ExpectedPaymentsView.content(store: store)
        #expect(clock.samples == [try instant("2026-09-10T23:59:59Z")])
        #expect(store.currentDay() == DomainMapper.civilDay(next), "the clock really did cross midnight")
    }

    @Test func bankInboxListTakesOneSampleAcrossMidnight() throws {
        let db = try container()
        try StoredDocumentGraph.replace(with: document(), in: db.mainContext, writtenOn: first)
        let clock = CoherenceClock(try instant("2026-09-10T23:59:00Z"))
        let store = try store(clock, db)
        clock.current = try instant("2026-09-10T23:59:59Z")
        clock.step = 2
        clock.samples = []
        // Five partitions and a balance section, from one read.
        _ = BankInboxView.content(store: store)
        #expect(clock.samples == [try instant("2026-09-10T23:59:59Z")])
    }

    /// The standing shown either side of midnight is the day's, and a later
    /// composition is allowed to move on — what it may not do is mix the two.
    @Test func aLaterCompositionMovesOnWholesale() throws {
        let db = try container()
        try StoredDocumentGraph.replace(with: document(), in: db.mainContext, writtenOn: first)
        let clock = CoherenceClock(try instant("2026-09-10T23:59:00Z"))
        let store = try store(clock, db)
        clock.current = try instant("2026-09-10T23:59:59Z")
        let onTheDay = store.currentPresentation()
        #expect(onTheDay.snapshot.asOf == DomainMapper.civilDay(first))
        #expect(onTheDay.snapshot.expectedPayments
            .first { $0.ruleID == "synthetic-coherence" }?.status == .due)
        clock.current = try instant("2026-09-11T00:00:01Z")
        let afterMidnight = store.currentPresentation()
        #expect(afterMidnight.snapshot.asOf == DomainMapper.civilDay(next))
        #expect(afterMidnight.snapshot.expectedPayments
            .first { $0.ruleID == "synthetic-coherence" }?.status == .overdue)
    }

    /// Recorded because it was never asserted: a write must invalidate the
    /// projection cached under the current day, or a session left open across
    /// midnight would keep showing the plan from before the entry.
    @Test func aWriteAfterMidnightForcesTheForecastToRun() throws {
        let db = try container()
        try StoredDocumentGraph.replace(with: document(), in: db.mainContext, writtenOn: first)
        let clock = CoherenceClock(try instant("2026-09-10T23:59:00Z"))
        var runs = 0
        let store = try FinanceStore(
            context: db.mainContext, clock: { clock.sample() }, timeZone: utc,
            forecastRunner: { request in
                runs += 1
                return try ForecastEngine.run(request)
            }
        )
        // Cross midnight first, so the day's projection is the cached one
        // rather than the launch-day evaluation the store published.
        clock.current = try instant("2026-09-11T00:10:00Z")
        let opening = store.currentPresentation()
        #expect(opening.snapshot.asOf == DomainMapper.civilDay(next))
        let cashBefore = opening.snapshot.accountCash
        let beforeReuse = runs
        _ = store.currentPresentation()
        _ = store.snapshot
        #expect(runs == beforeReuse, "same-day reads reuse the day's forecast")

        try store.add(try #require(TransactionDraft(
            day: DomainMapper.civilDay(next), kind: .expense, amount: .eur(12),
            accountID: EntryFixtures.bank.id, categoryKey: "groceries", merchant: "Synthetic"
        )))
        #expect(runs > beforeReuse, "a write recomputes the projection")

        let afterWrite = runs
        let reread = store.currentPresentation()
        // The point of the invalidation: the reused projection is the one that
        // includes the write, not the one cached under the same day before it.
        #expect(reread.snapshot.accountCash == cashBefore - .eur(12))
        #expect(reread.snapshot.asOf == DomainMapper.civilDay(next))
        #expect(runs == afterWrite, "and the recomputed forecast is then reused")
    }
}

@MainActor
private final class CoherenceClock {
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
