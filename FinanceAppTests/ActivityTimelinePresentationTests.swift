import Foundation
import Testing
@testable import FinanceApp

@Suite("Activity timeline presentation")
struct ActivityTimelinePresentationTests {
    private struct Row: Identifiable {
        let id: String
        let date: CalendarDay?
    }

    @Test("An undated first row forms a group without indexing an empty array")
    func undatedFirst() {
        let rows = [Row(id: "unknown-1", date: nil), Row(id: "unknown-2", date: nil)]
        let groups = ActivityTimelineGrouping.adjacent(rows, date: \.date)
        #expect(groups.count == 1)
        #expect(groups.first?.date == nil)
        #expect(groups.first?.rows.map(\.id) == ["unknown-1", "unknown-2"])
    }

    @Test("Date headings preserve a selected amount order")
    func adjacentOnly() {
        let day = CalendarDay(year: 2026, month: 9, day: 23)
        let other = CalendarDay(year: 2026, month: 9, day: 22)
        let rows = [Row(id: "largest", date: day), Row(id: "middle", date: other), Row(id: "smallest", date: day)]
        let groups = ActivityTimelineGrouping.adjacent(rows, date: \.date)
        #expect(groups.count == 3)
        #expect(groups.flatMap(\.rows).map(\.id) == rows.map(\.id))
    }

    @Test("Readable statement casing preserves mixed case and known acronyms")
    func readableTitles() {
        #expect(ActivityTextPresentation.readableTitle("PAYPAL EUROPE") == "PayPal Europe")
        #expect(ActivityTextPresentation.readableTitle("BNP SEPA TRANSFER") == "BNP SEPA Transfer")
        #expect(ActivityTextPresentation.readableTitle("Google Payment Ireland") == "Google Payment Ireland")
        #expect(ActivityTextPresentation.readableTitle("ATM") == "ATM")
    }
}
