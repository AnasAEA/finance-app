import XCTest
@testable import FinanceCore

/// Checked civil-day arithmetic at the edges of the structural year domain.
///
/// Every case here is unreachable from ordinary financial dates. They exist
/// because the alternative to answering them is a trap, and a trap in a
/// forecast is the app disappearing while someone is looking at their money.
final class DayCheckedArithmeticTests: XCTestCase {

    private let intExtremes = [Int.min, Int.min + 1, -1, 0, 1, Int.max - 1, Int.max]

    // MARK: - index

    func testEpochAndPinnedOrdinals() {
        // Pinned so the definition of "index" cannot drift.
        let pinned: [(String, Int)] = [
            ("1970-01-01", 0), ("1970-01-02", 1), ("1969-12-31", -1),
            ("2000-03-01", 11017), ("2026-09-11", 20707), ("0001-01-01", -719162)
        ]
        for (iso, expected) in pinned {
            XCTAssertEqual(Day(isoString: iso)?.index, expected, iso)
        }
        XCTAssertEqual(Day(year: 0, month: 1, day: 1).index, -719528)
    }

    func testExtremeStructuralYearsHaveNoRepresentableOrdinal() {
        // ~365.2425 days per year: an Int year's ordinal is far outside Int.
        for year in [Int.min, Int.min + 1, Int.max - 1, Int.max] {
            for month in [1, 2, 3, 12] {
                XCTAssertNil(Day(year: year, month: month, day: 1).index,
                             "\(year)-\(month) should have no representable ordinal")
            }
        }
    }

    /// The boundary of representability itself, from both sides.
    func testTheOrdinalDomainBoundaryIsExactNotApproximate() throws {
        let highest = Day(index: .max)
        XCTAssertEqual(highest.index, .max)
        XCTAssertNil(try XCTUnwrap(highest.advanced(by: 1)).index)

        let lowest = Day(index: .min)
        XCTAssertEqual(lowest.index, .min)
        XCTAssertNil(try XCTUnwrap(lowest.advanced(by: -1)).index)
    }

    // MARK: - Day(index:) is total

    func testEveryIntOrdinalDecodesToOneDayAndBack() {
        for ordinal in intExtremes + [Int.min / 2, Int.max / 2, -719528, 20707] {
            let day = Day(index: ordinal)
            XCTAssertTrue((1...12).contains(day.month), "\(ordinal) → \(day)")
            XCTAssertTrue((1...Day.daysInMonth(year: day.year, month: day.month)).contains(day.day))
            // Total: the round trip is exact for every sampled Int ordinal.
            XCTAssertEqual(day.index, ordinal, "round trip failed for \(ordinal)")
        }
    }

    func testTheOrdinalDomainStaysWellInsideTheStructuralYearDomain() {
        // The claim that makes Day(index:) total: |year| stays ~2.5e16.
        XCTAssertLessThan(Day(index: .max).year, Int.max / 100)
        XCTAssertGreaterThan(Day(index: .min).year, Int.min / 100)
    }

    // MARK: - days(until:)

    func testSelfDistanceIsZeroAtEveryStructuralYear() {
        for year in [Int.min, Int.min + 1, -1, 0, 1, 1970, 2026, Int.max - 1, Int.max] {
            for (month, day) in [(1, 1), (2, 28), (3, 1), (12, 31)] {
                let value = Day(year: year, month: month, day: day)
                XCTAssertEqual(value.days(until: value), 0, "\(value)")
            }
        }
    }

    func testAdjacentExtremeDaysAreExactlyOneApart() {
        let lowFirst = Day(year: .min, month: 1, day: 1)
        let lowSecond = Day(year: .min, month: 1, day: 2)
        XCTAssertEqual(lowFirst.days(until: lowSecond), 1)
        XCTAssertEqual(lowSecond.days(until: lowFirst), -1)

        let highLast = Day(year: .max, month: 12, day: 31)
        let highPenultimate = Day(year: .max, month: 12, day: 30)
        XCTAssertEqual(highPenultimate.days(until: highLast), 1)
        XCTAssertEqual(highLast.days(until: highPenultimate), -1)

        // Int.max is not a leap year, so February ends on the 28th.
        XCTAssertFalse(Day.isLeapYear(.max))
        XCTAssertEqual(
            Day(year: .max, month: 2, day: 28).days(until: Day(year: .max, month: 3, day: 1)), 1
        )
    }

    func testAnUnrepresentableSeparationIsRefusedNotWrapped() {
        XCTAssertNil(
            Day(year: .min, month: 1, day: 1).days(until: Day(year: .max, month: 12, day: 31))
        )
        XCTAssertNil(
            Day(year: .max, month: 12, day: 31).days(until: Day(year: .min, month: 1, day: 1))
        )
    }

    func testOrdinaryDistancesAreUnchanged() {
        XCTAssertEqual(Day(isoString: "2026-09-01")!.days(until: Day(isoString: "2026-09-11")!), 10)
        XCTAssertEqual(Day(isoString: "2026-09-11")!.days(until: Day(isoString: "2026-09-01")!), -10)
        // Across a leap day, and across a century that is not a leap year.
        XCTAssertEqual(Day(isoString: "2024-02-28")!.days(until: Day(isoString: "2024-03-01")!), 2)
        XCTAssertEqual(Day(isoString: "1900-02-28")!.days(until: Day(isoString: "1900-03-01")!), 1)
        XCTAssertEqual(Day(isoString: "1970-01-01")!.days(until: Day(isoString: "2026-09-11")!), 20707)
    }

    func testDistanceIsAntisymmetricWhereNegationIsRepresentable() {
        let samples = [
            Day(index: .min), Day(index: .min + 1), Day(index: -1), Day(index: 0),
            Day(index: 1), Day(index: .max - 1), Day(index: .max),
            Day(year: .min, month: 6, day: 1), Day(year: .max, month: 6, day: 1)
        ]
        for lhs in samples {
            for rhs in samples {
                guard let forward = lhs.days(until: rhs) else { continue }
                let backward = rhs.days(until: lhs)
                if forward == .min {
                    // -Int.min is not representable, so the mirror must refuse.
                    XCTAssertNil(backward, "\(lhs) → \(rhs)")
                } else {
                    XCTAssertEqual(backward, -forward, "\(lhs) → \(rhs)")
                }
            }
        }
    }

    // MARK: - isWithin(days:of:)

    func testBoundedDistanceHonoursItsExactBound() {
        let day = Day(isoString: "2026-09-11")!
        XCTAssertTrue(day.isWithin(days: 0, of: day))
        XCTAssertFalse(day.isWithin(days: -1, of: day))
        XCTAssertFalse(day.isWithin(days: .min, of: day))
        XCTAssertFalse(day.isWithin(days: 0, of: Day(isoString: "2026-09-12")!))

        for offset in [-10, -1, 1, 10] {
            let other = day.advanced(by: offset)!
            XCTAssertTrue(day.isWithin(days: 10, of: other), "\(offset)")
            XCTAssertTrue(other.isWithin(days: 10, of: day), "symmetry at \(offset)")
        }
        XCTAssertFalse(day.isWithin(days: 10, of: day.advanced(by: 11)!))
        XCTAssertFalse(day.isWithin(days: 10, of: day.advanced(by: -11)!))
    }

    func testAnUnrepresentableSeparationIsOutsideEveryFiniteWindow() {
        let low = Day(year: .min, month: 1, day: 1)
        let high = Day(year: .max, month: 12, day: 31)
        for limit in [0, 1, 10, Int.max - 1, Int.max] {
            XCTAssertFalse(low.isWithin(days: limit, of: high), "limit \(limit)")
            XCTAssertFalse(high.isWithin(days: limit, of: low), "limit \(limit)")
        }
        // Every day is within any nonnegative window of itself, extremes included.
        XCTAssertTrue(low.isWithin(days: 0, of: low))
        XCTAssertTrue(high.isWithin(days: .max, of: high))
    }

    // MARK: - advanced(by:)

    func testZeroAdvancementIsIdentityAtEveryStructuralYear() {
        for year in [Int.min, Int.min + 1, -1, 0, 1, 1970, 2026, Int.max - 1, Int.max] {
            for (month, day) in [(1, 1), (2, 28), (3, 1), (12, 31)] {
                let value = Day(year: year, month: month, day: day)
                // Advancement must not depend on the absolute ordinal existing.
                XCTAssertEqual(value.advanced(by: 0), value, "\(value)")
            }
        }
    }

    func testExtremeYearsStillAdvanceLocally() {
        XCTAssertEqual(
            Day(year: .min, month: 1, day: 1).advanced(by: 1), Day(year: .min, month: 1, day: 2)
        )
        XCTAssertEqual(
            Day(year: .max, month: 12, day: 31).advanced(by: -1), Day(year: .max, month: 12, day: 30)
        )
        XCTAssertEqual(
            Day(year: .max, month: 1, day: 1).advanced(by: 31), Day(year: .max, month: 2, day: 1)
        )
    }

    func testAdvancingOutOfTheStructuralDomainIsRefusedNotClamped() {
        XCTAssertNil(Day(year: .max, month: 12, day: 31).advanced(by: 1))
        XCTAssertNil(Day(year: .min, month: 1, day: 1).advanced(by: -1))
        XCTAssertNil(Day(year: .max, month: 12, day: 31).advanced(by: .max))
        XCTAssertNil(Day(year: .min, month: 1, day: 1).advanced(by: .min))
    }

    func testOffsetExtremesNeverTrapAndAgreeWithDistance() {
        let bases = [
            Day(year: .min, month: 3, day: 1), Day(year: -1, month: 3, day: 1),
            Day(isoString: "1970-01-01")!, Day(isoString: "2026-09-11")!,
            Day(year: .max, month: 3, day: 1)
        ]
        for base in bases {
            for offset in [Int.min, Int.min + 1, -365, -1, 0, 1, 365, Int.max - 1, Int.max] {
                guard let moved = base.advanced(by: offset) else { continue }
                // Whatever it produced, it is exactly `offset` days away.
                XCTAssertEqual(base.days(until: moved), offset, "\(base) + \(offset)")
            }
        }
        // An ordinary day genuinely can absorb the whole Int offset range.
        XCTAssertNotNil(Day(isoString: "1970-01-01")!.advanced(by: .max))
        XCTAssertNotNil(Day(isoString: "1970-01-01")!.advanced(by: .min))
    }

    func testOrdinaryAdvancementIsUnchangedIncludingLeapTransitions() {
        XCTAssertEqual(Day(isoString: "2026-09-11")!.advanced(by: -10), Day(isoString: "2026-09-01")!)
        XCTAssertEqual(Day(isoString: "2024-02-28")!.advanced(by: 1), Day(isoString: "2024-02-29")!)
        XCTAssertEqual(Day(isoString: "2023-02-28")!.advanced(by: 1), Day(isoString: "2023-03-01")!)
        XCTAssertEqual(Day(isoString: "2026-12-31")!.advanced(by: 1), Day(isoString: "2027-01-01")!)
        XCTAssertEqual(Day(isoString: "2027-01-01")!.advanced(by: -1), Day(isoString: "2026-12-31")!)
    }

    func testAdvancementRoundTripsWhereTheInverseOffsetIsRepresentable() throws {
        let day = Day(isoString: "2026-09-11")!
        for offset in [-100_000, -365, -1, 0, 1, 365, 100_000] {
            XCTAssertEqual(day.advanced(by: offset)?.advanced(by: -offset), day, "\(offset)")
        }
        // `Int.min` has no representable negation, so it is checked on its own
        // terms: the forward step is exact, and the distance back is the value
        // that cannot be negated rather than a wrapped one.
        let moved = try XCTUnwrap(day.advanced(by: .min))
        XCTAssertEqual(day.days(until: moved), .min)
        XCTAssertNil(moved.days(until: day))
    }

    // MARK: - MonthKey movement

    func testOrdinaryMonthMovementIsUnchanged() {
        XCTAssertEqual(MonthKey(year: 2026, month: 12).next, MonthKey(year: 2027, month: 1))
        XCTAssertEqual(MonthKey(year: 2027, month: 1).previous, MonthKey(year: 2026, month: 12))
        XCTAssertEqual(MonthKey(year: 2026, month: 9).next, MonthKey(year: 2026, month: 10))
        XCTAssertEqual(MonthKey(year: 2026, month: 9).previous, MonthKey(year: 2026, month: 8))
    }

    func testMonthMovementRefusesToLeaveTheYearDomain() {
        XCTAssertNil(MonthKey(year: .max, month: 12).next)
        XCTAssertNil(MonthKey(year: .min, month: 1).previous)
        // One month inside the edge still moves.
        XCTAssertEqual(MonthKey(year: .max, month: 11).next, MonthKey(year: .max, month: 12))
        XCTAssertEqual(MonthKey(year: .min, month: 2).previous, MonthKey(year: .min, month: 1))
    }

    func testZeroMonthAdvancementIsIdentityEverywhere() {
        for year in [Int.min, -1, 0, 2026, Int.max] {
            for month in 1...12 {
                let key = MonthKey(year: year, month: month)
                XCTAssertEqual(key.advanced(byMonths: 0), key, "\(key)")
            }
        }
    }

    func testMonthAdvancementMatchesRepeatedSingleSteps() {
        let base = MonthKey(year: 2026, month: 9)
        for offset in -30...30 {
            var stepped: MonthKey? = base
            for _ in 0..<abs(offset) {
                stepped = offset < 0 ? stepped?.previous : stepped?.next
            }
            XCTAssertEqual(base.advanced(byMonths: offset), stepped, "offset \(offset)")
        }
        XCTAssertEqual(MonthKey(year: 2026, month: 9).advanced(byMonths: 12),
                       MonthKey(year: 2027, month: 9))
        XCTAssertEqual(MonthKey(year: 2026, month: 9).advanced(byMonths: -12),
                       MonthKey(year: 2025, month: 9))
    }

    func testMonthOffsetExtremesNeverTrap() {
        for year in [Int.min, -1, 0, 2026, Int.max] {
            for month in [1, 6, 12] {
                for offset in [Int.min, Int.min + 1, -13, -1, 1, 13, Int.max - 1, Int.max] {
                    // Nothing here may trap; `year * 12` would have.
                    _ = MonthKey(year: year, month: month).advanced(byMonths: offset)
                }
            }
        }
        // From an ordinary month, the whole Int offset range is representable:
        // Int.max months is ~7.7e17 years, well inside the year domain. The
        // results are exact, not saturated.
        XCTAssertEqual(
            MonthKey(year: 2026, month: 9).advanced(byMonths: .max),
            MonthKey(year: 768_614_336_404_566_677, month: 4)
        )
        XCTAssertEqual(
            MonthKey(year: 2026, month: 9).advanced(byMonths: .min),
            MonthKey(year: -768_614_336_404_562_624, month: 1)
        )
        // Refusal comes from the year domain itself, one step past its edge.
        XCTAssertNil(MonthKey(year: .max, month: 1).advanced(byMonths: 12))
        XCTAssertNil(MonthKey(year: .min, month: 12).advanced(byMonths: -12))
        XCTAssertEqual(MonthKey(year: .max, month: 1).advanced(byMonths: 11),
                       MonthKey(year: .max, month: 12))
        XCTAssertEqual(MonthKey(year: .min, month: 12).advanced(byMonths: -11),
                       MonthKey(year: .min, month: 1))
    }
}
