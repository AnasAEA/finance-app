import Testing
import Foundation
import FinanceCore
@testable import FinanceApp

/// Dates on screen follow the person's locale, and every screen writes a day
/// the same way.
///
/// Insights used to build "6 Sep" from a hard-coded English month list while
/// Activity asked Foundation, so an en_US phone read "Sep 6" on one tab and
/// "6 Sep" on the next, and a French one read English months in Insights only.
/// These tests pin the shared wording rather than a machine's locale: exact
/// strings are asserted only for an explicitly chosen locale.
@Suite("Dates follow the locale and agree across screens")
struct LocaleDateTextTests {

    static let enUS = Locale(identifier: "en_US")
    static let frFR = Locale(identifier: "fr_FR")
    static let thin = "\u{2009}"

    static func day(_ month: Int, _ day: Int, year: Int = 2026) -> CalendarDay {
        CalendarDay(year: year, month: month, day: day)
    }

    @Test("A span inside one month writes the month once")
    func sameMonthSpan() {
        let text = Self.day(9, 1).formatted(through: Self.day(9, 6), locale: Self.enUS)
        #expect(text == "Sep 1\(Self.thin)–\(Self.thin)6")
    }

    @Test("A span across a month end names both months")
    func crossMonthSpan() {
        let text = Self.day(8, 31).formatted(through: Self.day(9, 6), locale: Self.enUS)
        #expect(text == "Aug 31\(Self.thin)–\(Self.thin)Sep 6")
    }

    @Test("A span across a year end names both years, and only then")
    func crossYearSpan() {
        let across = Self.day(12, 29).formatted(through: Self.day(1, 4, year: 2027), locale: Self.enUS)
        #expect(across.contains("2026") && across.contains("2027"))
        let within = Self.day(12, 1).formatted(through: Self.day(12, 7), locale: Self.enUS)
        #expect(!within.contains("2026"))
    }

    @Test("French spans use French months, never the English list")
    func frenchSpan() {
        let text = Self.day(9, 1).formatted(through: Self.day(9, 6), locale: Self.frFR)
        #expect(text.contains("sept."))
        #expect(!text.contains("Sep"))
        #expect(text.components(separatedBy: "sept.").count == 2, "month written once: \(text)")
        let cross = Self.day(8, 31).formatted(through: Self.day(9, 6), locale: Self.frFR)
        #expect(cross.contains("août") && cross.contains("sept."))
    }

    @Test("A one-day span is that day, written like any other day")
    func singleDaySpan() {
        let day = Self.day(3, 1)
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(Self.enUS)
        #expect(day.formatted(through: day, locale: Self.enUS) == day.formatted(style))
        #expect(day.formatted(through: day, locale: Self.enUS) == "Mar 1")
    }

    @Test("A month title follows the locale")
    func monthTitle() {
        #expect(CalendarDay.monthTitle(year: 2026, month: 9, locale: Self.enUS) == "September 2026")
        #expect(CalendarDay.monthTitle(year: 2026, month: 9, locale: Self.frFR) == "septembre 2026")
    }

    @Test("Both ends and the span are written in the locale's own calendar")
    func calendarFollowsTheLocale() {
        // Pinned to the locale, not the device: a Hebrew-calendar locale reads
        // Hebrew dates end to end, and a Gregorian one stays Gregorian.
        let hebrew = Locale(identifier: "en_US@calendar=hebrew")
        let span = Self.day(9, 1).formatted(through: Self.day(9, 6), locale: hebrew)
        let single = Self.day(9, 1).formatted(through: Self.day(9, 1), locale: hebrew)
        #expect(span.contains("Elul") && !span.contains("Sep"), "\(span)")
        #expect(single.contains("Elul") && !single.contains("Sep"), "\(single)")
        #expect(CalendarDay.monthTitle(year: 2026, month: 9, locale: hebrew).contains("Elul"))
        #expect(Self.day(9, 1).formatted(through: Self.day(9, 6), locale: Self.enUS)
                == "Sep 1\(Self.thin)–\(Self.thin)6")
    }

    @Test("A day with no instant prints structurally instead of becoming another day")
    func uninstantiableDays() {
        let text = Self.day(9, 1, year: 0).formatted(through: Self.day(9, 6, year: 0), locale: Self.enUS)
        #expect(text == "0000-09-01\(Self.thin)–\(Self.thin)0000-09-06")
        #expect(CalendarDay.monthTitle(year: 0, month: 9, locale: Self.enUS) == "0000-09-01")
    }

    @Test("The time zone never moves a civil span to other days")
    func zonesDoNotShiftSpans() {
        let expected = Self.day(8, 31).formatted(through: Self.day(9, 6), locale: Self.enUS)
        for zone in CivilDateTests.zones {
            let text = Self.day(8, 31).formatted(through: Self.day(9, 6), timeZone: zone, locale: Self.enUS)
            #expect(text == expected, "\(zone.identifier)")
        }
    }

    @Test("Insights writes days, spans and months the way the rest of the app does")
    func insightsAgreesWithTheApp() throws {
        let day = Day(year: 2026, month: 9, day: 6)
        #expect(ReviewPresentationMapper.dayText(day)
                == Self.day(9, 6).formatted(.dateTime.day().month(.abbreviated)))

        let week = ReviewInterval(start: Day(year: 2026, month: 8, day: 31), end: day)
        #expect(ReviewPresentationMapper.rangeText(week)
                == Self.day(8, 31).formatted(through: Self.day(9, 6)))

        let single = ReviewInterval(start: day, end: day)
        #expect(ReviewPresentationMapper.rangeText(single)
                == Self.day(9, 6).formatted(.dateTime.day().month(.abbreviated)))

        #expect(ReviewPresentationMapper.monthLabel(MonthKey(year: 2026, month: 9))
                == CalendarDay.monthTitle(year: 2026, month: 9))
    }
}
