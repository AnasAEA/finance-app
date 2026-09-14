import Foundation
import FinanceCore
import Testing
@testable import FinanceApp

@MainActor
@Suite("Day F4 month projection boundaries")
struct DayF4ProjectionTests {
    @Test func invalidEventRefusesTheWholeProjection() throws {
        let document = EntryFixtures.document()
        let day = EntryFixtures.today
        let end = try #require(day.advanced(by: 30))
        let forecast = try ForecastEngine.run(ForecastComposer.makeRequest(
            from: document, startDate: day, endDate: end
        ))
        let input = DomainMapper.Inputs(
            today: day, horizonDays: 31, document: document,
            forecast: forecast,
            overview: FinanceOverview.snapshot(document: document, result: forecast,
                                                today: day, horizonDays: 30)
        )
        let valid = event(id: "synthetic-valid", date: DomainMapper.civilDay(day))
        let invalid = event(id: "synthetic-invalid", date: CalendarDay(year: 2026, month: 2, day: 30))
        let ordinary = try DomainMapper().monthProjections(input, plannedEvents: [valid])
        #expect(ordinary.flatMap(\.events).map(\.id).contains(valid.id))
        #expect(throws: DomainMapper.ProjectionError.invalidPlannedEventDate) {
            try DomainMapper().monthProjections(input, plannedEvents: [valid, invalid])
        }
    }

    private func event(id: String, date: CalendarDay) -> PlannedEvent {
        PlannedEvent(id: id, date: date, label: "Synthetic event", amount: .eur(-10),
                     isInflow: false, isGuaranteedButNotReceived: false,
                     certaintyLabel: nil, isRecovery: false, hasApproximateDate: false, note: nil)
    }
}
