import Testing
import FinanceCore
@testable import FinanceApp

@Suite("Civil persistence boundaries")
struct DayPersistenceTests {
    @Test func validDayOrdinalsRemainCompatible() throws {
        let cases: [(Int32, Day)] = [
            (101, Day(year: 0, month: 1, day: 1)),
            (229, Day(year: 0, month: 2, day: 29)),
            (20240229, Day(year: 2024, month: 2, day: 29)),
            (20260916, Day(year: 2026, month: 9, day: 16)),
            (2147481231, Day(year: 214748, month: 12, day: 31))
        ]
        for (ordinal, expected) in cases {
            let day = try #require(Day(persistenceOrdinal: ordinal))
            #expect(day == expected)
            #expect(day.checkedPersistenceOrdinal == ordinal)
        }
    }

    @Test func malformedDayOrdinalsFailSafely() {
        let invalid: [Int32] = [
            0, -1, -101, .min, .max, 20260001, 20261301, 20260100,
            20260132, 20260431, 20230229, 20260899
        ]
        for ordinal in invalid { #expect(Day(persistenceOrdinal: ordinal) == nil) }
    }

    @Test func checkedDayEncodingRefusesUnrepresentableYears() {
        for year in [Int.min, -1, 214749, Int.max] {
            #expect(Day(year: year, month: 1, day: 1).checkedPersistenceOrdinal == nil)
        }
    }

    @Test func validMonthOrdinalsRemainCompatible() throws {
        let cases: [(Int32, MonthKey)] = [
            (1, MonthKey(year: 0, month: 1)),
            (202609, MonthKey(year: 2026, month: 9)),
            (2147483612, MonthKey(year: 21474836, month: 12))
        ]
        for (ordinal, expected) in cases {
            let month = try #require(MonthKey(persistenceOrdinal: ordinal))
            #expect(month == expected)
            #expect(month.checkedPersistenceOrdinal == ordinal)
        }
    }

    @Test func malformedMonthOrdinalsFailSafely() {
        let invalid: [Int32] = [0, -1, .min, .max, 202600, 202613]
        for ordinal in invalid {
            #expect(MonthKey(persistenceOrdinal: ordinal) == nil)
        }
    }

    @Test func checkedMonthEncodingRefusesUnrepresentableYears() {
        for year in [Int.min, -1, 21474837, Int.max] {
            #expect(MonthKey(year: year, month: 1).checkedPersistenceOrdinal == nil)
        }
    }
}
