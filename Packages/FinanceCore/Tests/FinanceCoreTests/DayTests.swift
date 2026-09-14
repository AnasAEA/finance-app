import XCTest
@testable import FinanceCore

/// The Foundation-free Gregorian day engine.
final class DayTests: XCTestCase {

    func testValidatingComponentsAndExtremeLeapYears() {
        let cases: [(Int, Bool)] = [
            (.min, true), (.min + 1, false), (-1, false), (0, true),
            (1, false), (2000, true), (.max - 1, false), (.max, false)
        ]
        for (year, leap) in cases {
            XCTAssertEqual(Day.isLeapYear(year), leap)
            XCTAssertEqual(Day(validatingYear: year, month: 3, day: 1),
                           Day(year: year, month: 3, day: 1))
            XCTAssertEqual(Day(validatingYear: year, month: 2, day: 29) != nil, leap)
            for month in [Int.min, -1, 0, 13, Int.max] {
                XCTAssertNil(Day(validatingYear: year, month: month, day: 1))
                XCTAssertNil(MonthKey(validatingYear: year, month: month))
            }
            for day in [Int.min, -1, 0, 32, Int.max] {
                XCTAssertNil(Day(validatingYear: year, month: 1, day: day))
            }
            XCTAssertNil(Day(validatingYear: year, month: 4, day: 31))
            XCTAssertEqual(MonthKey(validatingYear: year, month: 12), MonthKey(year: year, month: 12))
        }
    }

    func testComparableLawsAcrossExtremeYears() {
        let ordered = [
            Day(year: .min, month: 1, day: 1),
            Day(year: -1, month: 12, day: 31),
            Day(year: 0, month: 1, day: 1),
            Day(year: 2000, month: 1, day: 31),
            Day(year: 2000, month: 2, day: 1),
            Day(year: 2000, month: 2, day: 2),
            Day(year: .max, month: 12, day: 31)
        ]
        XCTAssertEqual(Array(ordered.reversed()).sorted(), ordered)
        let triple = [ordered[0], ordered[3], ordered[6]]
        XCTAssertEqual([triple[2], triple[1], triple[0]].sorted(), triple)
        for (i, lhs) in ordered.enumerated() {
            XCTAssertFalse(lhs < lhs)
            for (j, rhs) in ordered.enumerated() {
                XCTAssertEqual(lhs < rhs, i < j)
                XCTAssertEqual(lhs == rhs, !(lhs < rhs) && !(rhs < lhs))
                XCTAssertFalse(lhs < rhs && rhs < lhs)
                for last in ordered where lhs < rhs && rhs < last {
                    XCTAssertTrue(lhs < last)
                }
            }
        }
    }

    func testStructuralCivilFormattingIsTotal() {
        let extremes = Int.bitWidth == 64
            ? ("-9223372036854775808-03-01", "+9223372036854775807-03-01")
            : ("-2147483648-03-01", "+2147483647-03-01")
        let cases: [(Day, String)] = [
            (Day(year: 0, month: 1, day: 1), "0000-01-01"),
            (Day(year: 2026, month: 9, day: 8), "2026-09-08"),
            (Day(year: 9999, month: 12, day: 31), "9999-12-31"),
            (Day(year: 10000, month: 3, day: 1), "+10000-03-01"),
            (Day(year: -1, month: 3, day: 1), "-0001-03-01"),
            (Day(year: -10000, month: 3, day: 1), "-10000-03-01"),
            (Day(year: .min, month: 3, day: 1), extremes.0),
            (Day(year: .max, month: 3, day: 1), extremes.1)
        ]
        for (day, expected) in cases {
            XCTAssertEqual(day.isoString, expected)
            XCTAssertEqual(day.description, expected)
            XCTAssertEqual(day.monthKey.isoString, String(expected.dropLast(3)))
            XCTAssertEqual(day.monthKey.description, String(expected.dropLast(3)))
        }
    }

    func testFourDigitCodableAndOccurrenceIdentityGoldens() throws {
        for text in ["0000-01-01", "0000-02-29", "2024-02-29", "2026-09-08", "9999-12-31"] {
            let day = try XCTUnwrap(Day(isoString: text))
            let bytes = Data("\"\(text)\"".utf8)
            XCTAssertEqual(try JSONEncoder().encode(day), bytes)
            XCTAssertEqual(try JSONDecoder().decode(Day.self, from: bytes), day)
            XCTAssertEqual(OccurrenceID(obligationID: "rule", expectedDay: day).description, "rule@\(text)")
            let monthText = String(text.prefix(7))
            let monthBytes = Data("\"\(monthText)\"".utf8)
            XCTAssertEqual(try JSONEncoder().encode(day.monthKey), monthBytes)
            XCTAssertEqual(try JSONDecoder().decode(MonthKey.self, from: monthBytes), day.monthKey)
        }
    }

    func testExpandedYearsCannotEncodeAsInterchangeJSON() {
        for year in [Int.min, -10000, -1, 10000, Int.max] {
            let day = Day(year: year, month: 3, day: 1)
            XCTAssertThrowsError(try JSONEncoder().encode(day)) { error in
                guard case EncodingError.invalidValue = error else {
                    return XCTFail("expected EncodingError.invalidValue")
                }
            }
            XCTAssertThrowsError(try JSONEncoder().encode(day.monthKey)) { error in
                guard case EncodingError.invalidValue = error else {
                    return XCTFail("expected EncodingError.invalidValue")
                }
            }
        }
    }

    func testStrictFourDigitRuntimeDecoding() {
        let invalidDays = [
            "2026-00-01", "2026-13-01", "2026-01-00", "2026-04-31", "2023-02-29",
            "2026-9-08", "2026--09-08", "-0001-03-01", "+001-03-01", "+10000-03-01",
            "10000-03-01", "2026-09-08-", " 2026-09-08", "2026-09-08 ", "２０２６-09-08"
        ]
        for text in invalidDays {
            XCTAssertNil(Day(isoString: text))
            XCTAssertThrowsError(try JSONDecoder().decode(Day.self, from: Data("\"\(text)\"".utf8))) { error in
                guard case DecodingError.dataCorrupted = error else { return XCTFail("expected dataCorrupted") }
            }
        }
        for text in ["2026-00", "2026-13", "2026-9", "-0001-03", "+001-03", "+10000-03", "2026-03-"] {
            XCTAssertNil(MonthKey(isoString: text))
            XCTAssertThrowsError(try JSONDecoder().decode(MonthKey.self, from: Data("\"\(text)\"".utf8)))
        }
    }

    func testEpochAndKnownIndices() {
        XCTAssertEqual(Day(year: 1970, month: 1, day: 1).index, 0)
        XCTAssertEqual(Day(index: 0), Day(year: 1970, month: 1, day: 1))
        // 2026-09-01 → 2026-09-11 is ten days
        let sep1 = Day(isoString: "2026-09-01")!
        let sep11 = Day(isoString: "2026-09-11")!
        XCTAssertEqual(sep11.days(until: sep11), 0)
        XCTAssertEqual(sep1.days(until: sep11), 10)
        XCTAssertEqual(sep11.advanced(by: -10), sep1)
    }

    func testRoundTripAcrossCenturies() throws {
        // Every day in four years round-trips through the index.
        var day = Day(year: 2023, month: 1, day: 1)
        let end = Day(year: 2027, month: 1, day: 1)
        while day < end {
            let roundTrip = Day(index: try XCTUnwrap(day.index))
            XCTAssertEqual(roundTrip, day, "round-trip failed for \(day)")
            day = try XCTUnwrap(day.advanced(by: 1))
        }
    }

    func testLeapYearRules() {
        XCTAssertTrue(Day.isLeapYear(2024))
        XCTAssertFalse(Day.isLeapYear(2023))
        XCTAssertFalse(Day.isLeapYear(1900))
        XCTAssertTrue(Day.isLeapYear(2000))
        XCTAssertEqual(Day.daysInMonth(year: 2024, month: 2), 29)
        XCTAssertEqual(Day.daysInMonth(year: 2023, month: 2), 28)
        XCTAssertNotNil(Day(year: 2024, month: 2, day: 29))
        // Invalid days trap at construction — nil only through the parser.
        XCTAssertNil(Day(isoString: "2023-02-29"))
        XCTAssertNil(Day(isoString: "2023-13-01"))
        XCTAssertNil(Day(isoString: "2026-9-1"))
    }

    func testMonthHelpers() {
        let day = Day(year: 2026, month: 9, day: 16)
        XCTAssertEqual(day.monthKey, MonthKey(year: 2026, month: 9))
        XCTAssertEqual(day.firstDayOfMonth, Day(isoString: "2026-09-01")!)
        XCTAssertEqual(day.lastDayOfMonth, Day(isoString: "2026-09-30")!)
        // Clamping: day 31 in a 30-day month, day 29 in February.
        XCTAssertEqual(MonthKey(year: 2026, month: 4).firstDay.clampedDay(31), Day(isoString: "2026-04-30")!)
        XCTAssertEqual(MonthKey(year: 2026, month: 2).firstDay.clampedDay(29), Day(isoString: "2026-02-28")!)
        XCTAssertEqual(MonthKey(year: 2024, month: 2).firstDay.clampedDay(29), Day(isoString: "2024-02-29")!)

        XCTAssertEqual(MonthKey(year: 2026, month: 12).next, MonthKey(year: 2027, month: 1))
        XCTAssertEqual(MonthKey(year: 2027, month: 1).previous, MonthKey(year: 2026, month: 12))
        XCTAssertTrue(MonthKey(year: 2026, month: 9) < MonthKey(year: 2026, month: 10))
    }

    func testISORoundTrip() {
        let day = Day(year: 2026, month: 8, day: 23)
        XCTAssertEqual(day.isoString, "2026-08-23")
        XCTAssertEqual(Day(isoString: day.isoString), day)
        XCTAssertEqual(MonthKey(isoString: "2026-09")?.isoString, "2026-09")
        XCTAssertNil(MonthKey(isoString: "2026-9"))
    }

    func testRecurrenceExpansion() {
        let monthly = RecurrenceSpec.monthly(onDay: 11, from: MonthKey(year: 2026, month: 9), through: nil)
        let days = monthly.occurrences(from: Day(isoString: "2026-09-01")!, to: Day(isoString: "2026-12-31")!)
        XCTAssertEqual(days.map(\.isoString), ["2026-09-11", "2026-10-11", "2026-11-11", "2026-12-11"])

        // Day 31 clamps inside shorter months.
        let day31 = RecurrenceSpec.monthly(onDay: 31, from: MonthKey(year: 2026, month: 1), through: nil)
        XCTAssertEqual(
            day31.occurrences(from: Day(isoString: "2026-01-01")!, to: Day(isoString: "2026-04-30")!).map(\.isoString),
            ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30"]
        )

        // A window forecasts on the EARLI plausible day (conservative).
        let window = RecurrenceSpec.monthlyWindow(earliestDay: 5, latestDay: 8, from: MonthKey(year: 2026, month: 9), through: nil)
        XCTAssertEqual(
            window.occurrences(from: Day(isoString: "2026-09-01")!, to: Day(isoString: "2026-10-31")!).map(\.isoString),
            ["2026-09-05", "2026-10-05"]
        )

        // Horizon filtering.
        let oneShot = RecurrenceSpec.oneShot(on: Day(isoString: "2026-09-16")!)
        XCTAssertEqual(oneShot.occurrences(from: Day(isoString: "2026-09-17")!, to: Day(isoString: "2026-10-01")!), [])
    }
}
