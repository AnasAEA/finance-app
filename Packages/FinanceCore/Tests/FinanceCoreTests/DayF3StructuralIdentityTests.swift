import XCTest
@testable import FinanceCore

final class DayF3StructuralIdentityTests: XCTestCase {
    func testStructuralIdentityIsSeparateFromJSON() throws {
        let values: [(Int, String)] = [(0, "0000"), (2026, "2026"), (9999, "9999"), (10000, "+10000"), (-1, "-0001"), (-10000, "-10000"), (Int.min, "-9223372036854775808"), (Int.max, "+9223372036854775807")]
        for (year, text) in values {
            let day = Day(year: year, month: 1, day: 31)
            let month = MonthKey(year: year, month: 1)
            XCTAssertEqual(day.isoString, text + "-01-31")
            XCTAssertEqual(month.isoString, text + "-01")
            XCTAssertEqual(Day(structuralISOString: text + "-01-31"), day)
            XCTAssertEqual(MonthKey(structuralISOString: text + "-01"), month)
            if (0...9999).contains(year) {
                XCTAssertEqual(try JSONEncoder().encode(day), Data(("\"" + text + "-01-31\"").utf8))
            } else {
                XCTAssertThrowsError(try JSONEncoder().encode(day))
                XCTAssertThrowsError(try JSONEncoder().encode(month))
                XCTAssertThrowsError(try JSONDecoder().decode(Day.self, from: Data(("\"" + text + "-01-31\"").utf8)))
            }
        }
    }

    func testStructuralParserRejectsNoncanonicalOrInvalidInput() {
        for text in ["+2026-01-01", "-0000-01-01", "+010000-01-01", "-1-01-01", "+10000-02-30", "+10000-13-01", "+10000-01-1", "2026-01-01junk", "+9223372036854775808-01-01", "-9223372036854775809-01-01"] {
            XCTAssertNil(Day(structuralISOString: text), text)
        }
        for text in ["+2026-01", "-0000-01", "+10000-00", "+10000-13", "+10000-1", "2026-01junk"] {
            XCTAssertNil(MonthKey(structuralISOString: text), text)
        }
    }
}
