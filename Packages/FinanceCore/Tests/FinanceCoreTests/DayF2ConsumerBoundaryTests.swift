import XCTest
@testable import FinanceCore

/// What each consumer of the checked Day arithmetic does at the boundary.
///
/// Day-F2 classified every migrated caller into one of four policies, and this
/// suite is that classification made executable: exact required arithmetic
/// fails with a typed error, finite thresholds report "outside the window",
/// advisory calculations are omitted, and deterministic loops produce the
/// requested final value before they advance.
final class DayF2ConsumerBoundaryTests: XCTestCase {

    private func day(_ iso: String) -> Day { Day(isoString: iso)! }

    private var bank: Account {
        Account(
            id: "bank", name: "Bank", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails
        )
    }

    private func euro(_ minorUnits: Int64) -> Money {
        Money(minorUnits: minorUnits, currency: .eur)
    }

    // MARK: - A. Forecast: a required horizon fails, it does not shrink

    private func forecastRequest(from start: Day, to end: Day) -> ForecastRequest {
        ForecastRequest(
            startDate: start, endDate: end, accounts: [bank],
            startingBalances: ["bank": euro(100_000)], scenario: .base
        )
    }

    func testOrdinaryForecastHorizonsAreUnchanged() throws {
        let start = day("2026-09-01")
        let end = try XCTUnwrap(start.advanced(by: 119))
        let result = try ForecastEngine.run(forecastRequest(from: start, to: end))
        XCTAssertEqual(result.dailyBalances.count, 120)
        XCTAssertEqual(result.dailyBalances.first?.day, start)
        XCTAssertEqual(result.dailyBalances.last?.day, end)
        // Inclusive: no deficit means the runway is the whole horizon.
        XCTAssertEqual(result.cashRunwayDays, 120)

        // A one-day horizon is one day, and the walk stops without asking for
        // the day after the end.
        let single = try ForecastEngine.run(forecastRequest(from: start, to: start))
        XCTAssertEqual(single.dailyBalances.map(\.day), [start])
        XCTAssertEqual(single.cashRunwayDays, 1)
    }

    /// The final day of the horizon is produced, and the walk stops there
    /// rather than advancing once more into a day that does not exist.
    func testAForecastEndingOnTheLastRepresentableDayStillCompletes() throws {
        let end = Day(year: .max, month: 12, day: 31)
        let start = try XCTUnwrap(end.advanced(by: -2))
        let result = try ForecastEngine.run(forecastRequest(from: start, to: end))
        XCTAssertEqual(result.dailyBalances.map(\.day.day), [29, 30, 31])
        XCTAssertEqual(result.dailyBalances.last?.day, end)
    }

    /// A horizon whose own length cannot be stated is refused, and refused
    /// before the day walk starts. It is never answered with a shorter
    /// horizon, an empty one, or a zero runway.
    func testAnUnstatableHorizonIsATypedFailureNotAZeroForecast() {
        let start = Day(year: .min, month: 1, day: 1)
        let end = Day(year: .max, month: 12, day: 31)
        XCTAssertNil(start.days(until: end))
        XCTAssertThrowsError(try ForecastEngine.validate(forecastRequest(from: start, to: end))) {
            XCTAssertEqual($0 as? ForecastError, .dateArithmeticOutOfRange)
        }
        XCTAssertThrowsError(try ForecastEngine.run(forecastRequest(from: start, to: end))) {
            XCTAssertEqual($0 as? ForecastError, .dateArithmeticOutOfRange)
        }
        // The existing empty-horizon refusal is untouched and still comes first.
        XCTAssertThrowsError(try ForecastEngine.run(forecastRequest(from: end, to: start))) {
            XCTAssertEqual($0 as? ForecastError, .emptyHorizon)
        }
    }

    // MARK: - B. Reconciliation: a finite window, and nothing outside it

    private func matchingDocument(expectedOn: Day, actualOn: Day) -> FinanceDocument {
        var document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [bank],
            balances: [],
            transactions: [
                Transaction(
                    id: "actual", date: actualOn, kind: .expense,
                    legs: [AccountLeg(accountID: "bank", amount: euro(-799))],
                    factivity: .observed, lifecycle: .cleared
                )
            ],
            planning: FinanceDocument.Planning(defaultScenario: .base)
        )
        document.planning.recurringObligations = [
            RecurringObligation(
                id: "sub", name: "Streaming", amount: euro(799),
                spec: .oneShot(on: expectedOn),
                requirement: PaymentRequirement(
                    currency: .eur, acceptableRails: PaymentRail.euroBankRails
                ),
                spendingClass: .optional
            )
        ]
        return document
    }

    private func candidateCount(expectedOn: Day, actualOn: Day) -> Int {
        let document = matchingDocument(expectedOn: expectedOn, actualOn: actualOn)
        return ReconciliationMatcher.candidates(
            forActual: "actual",
            in: ReconciliationContext(document: document, today: actualOn)
        ).count
    }

    func testTheOrdinaryMatchingWindowIsUnchangedAtItsExactEdges() {
        let actual = day("2026-09-11")
        // Inside the ±10-day window, on both sides.
        XCTAssertEqual(candidateCount(expectedOn: actual, actualOn: actual), 1)
        XCTAssertEqual(candidateCount(expectedOn: day("2026-09-01"), actualOn: actual), 1)
        XCTAssertEqual(candidateCount(expectedOn: day("2026-09-21"), actualOn: actual), 1)
        // One day outside it, on both sides.
        XCTAssertEqual(candidateCount(expectedOn: day("2026-08-31"), actualOn: actual), 0)
        XCTAssertEqual(candidateCount(expectedOn: day("2026-09-22"), actualOn: actual), 0)
    }

    /// A separation too large to express as an Int is outside every finite
    /// window. That is an answer, not an error — and the obligation is
    /// untouched either way.
    func testAnUnrepresentableSeparationProposesNoCandidateAndChangesNothing() {
        let actual = Day(year: .max, month: 12, day: 31)
        let document = matchingDocument(
            expectedOn: Day(year: .min, month: 1, day: 1), actualOn: actual
        )
        let context = ReconciliationContext(document: document, today: actual)
        XCTAssertNil(document.planning.recurringObligations[0].spec.occurrences(
            from: actual, to: actual
        ).first)
        XCTAssertTrue(ReconciliationMatcher.candidates(forActual: "actual", in: context).isEmpty)
        // Advisory only: the obligation still exists and still says what it said.
        XCTAssertEqual(document.planning.recurringObligations.count, 1)
        XCTAssertEqual(document.planning.recurringObligations[0].amount, euro(799))
        XCTAssertTrue(document.planning.settlements.isEmpty)
    }

    /// The advisory expansion window itself. When it cannot be built the
    /// matcher proposes nothing; it does not decide the obligation is absent.
    func testAnExpansionWindowThatCannotBeBuiltProposesNothing() {
        let actual = Day(year: .max, month: 12, day: 31)
        XCTAssertNil(actual.advanced(by: ReconciliationMatcher.defaultWindowDays))
        let document = matchingDocument(expectedOn: actual, actualOn: actual)
        let context = ReconciliationContext(document: document, today: actual)
        XCTAssertTrue(ReconciliationMatcher.candidates(forActual: "actual", in: context).isEmpty)
        XCTAssertEqual(document.planning.recurringObligations.count, 1)
    }

    /// The scoring predicate itself, at the one separation `abs` cannot
    /// express. The ordinal domain spans exactly `Int`, so a pair exactly
    /// `Int.min` days apart is constructible — and `abs(distance)` on it is a
    /// trap, not a large number. The bounded predicate answers instead.
    func testTheScoringWindowSurvivesAnExactlyIntMinSeparation() {
        let expected = Day(index: .max)
        let actual = Day(index: -1)
        // Representable, and exactly the value that cannot be negated.
        XCTAssertEqual(expected.days(until: actual), .min)
        XCTAssertFalse(expected.isWithin(days: .max, of: actual))

        let occurrence = ExpectedOccurrence(
            obligationID: "sub", name: "Streaming", expectedDay: expected, amount: euro(799),
            requirement: PaymentRequirement(
                currency: .eur, acceptableRails: PaymentRail.euroBankRails
            ),
            spendingClass: .optional, status: .due
        )
        let transaction = Transaction(
            id: "actual", date: actual, kind: .expense,
            legs: [AccountLeg(accountID: "bank", amount: euro(-799))],
            factivity: .observed, lifecycle: .cleared
        )
        var document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion, documentKind: "TEST",
            accounts: [bank], balances: [], transactions: [transaction],
            planning: FinanceDocument.Planning(defaultScenario: .base)
        )
        document.planning.settlements = []
        let context = ReconciliationContext(document: document, today: actual)
        // The amounts match exactly; only the date window rejects this pairing,
        // and it does so without negating the separation.
        XCTAssertNil(
            ReconciliationMatcher.candidate(
                occurrence: occurrence, actual: transaction, in: context
            )
        )
        // A pairing inside the window is still scored, so the guard rejects on
        // distance rather than on everything.
        let near = ExpectedOccurrence(
            obligationID: "sub", name: "Streaming",
            expectedDay: Day(index: 0), amount: euro(799),
            requirement: PaymentRequirement(
                currency: .eur, acceptableRails: PaymentRail.euroBankRails
            ),
            spendingClass: .optional, status: .due
        )
        let candidate = ReconciliationMatcher.candidate(
            occurrence: near, actual: transaction, in: context
        )
        XCTAssertEqual(candidate?.daysApart, -1)
    }

    func testConfiguredWindowRejectsIntMinWithoutChangingAuthority() {
        let date = Day(index: 0)
        let document = matchingDocument(expectedOn: date, actualOn: date)
        // Prove this actual/expected pair is otherwise eligible.
        XCTAssertEqual(ReconciliationMatcher.candidates(
            forActual: "actual",
            in: ReconciliationContext(document: document, today: date, windowDays: 0)
        ).count, 1)
        for window in [Int.min, -1] {
            let context = ReconciliationContext(document: document, today: date, windowDays: window)
            XCTAssertTrue(ReconciliationMatcher.candidates(forActual: "actual", in: context).isEmpty)
            XCTAssertEqual(context.document, document)
        }
        // Zero, ordinary, and maximal finite windows keep inclusive bounds.
        for (window, distance, count) in [(0, 0, 1), (0, 1, 0), (5, 5, 1), (5, 6, 0),
                                          (Int.max, Int.max, 1), (Int.max, Int.min, 0)] {
            let actual = Day(index: distance)
            let context = ReconciliationContext(
                document: matchingDocument(expectedOn: date, actualOn: actual),
                today: actual, windowDays: window
            )
            XCTAssertEqual(ReconciliationMatcher.candidates(forActual: "actual", in: context).count, count)
        }
    }

    // MARK: - D. Recurrence: the final requested value, then stop

    func testOrdinaryRecurrenceSchedulesAndMonthDayClampingAreUnchanged() {
        let monthly = RecurrenceSpec.monthly(
            onDay: 11, from: MonthKey(year: 2026, month: 9), through: nil
        )
        XCTAssertEqual(
            monthly.occurrences(from: day("2026-09-01"), to: day("2026-12-31")).map(\.isoString),
            ["2026-09-11", "2026-10-11", "2026-11-11", "2026-12-11"]
        )
        // Calendar clamping is business behaviour and stays exactly as it was.
        let day31 = RecurrenceSpec.monthly(
            onDay: 31, from: MonthKey(year: 2026, month: 1), through: nil
        )
        XCTAssertEqual(
            day31.occurrences(from: day("2026-01-01"), to: day("2026-04-30")).map(\.isoString),
            ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30"]
        )
    }

    /// The window's last month is emitted and the loop stops, instead of
    /// advancing into a month past the end of the year domain.
    func testRecurrenceEmitsTheFinalMonthWithoutAdvancingPastIt() {
        let lastMonth = MonthKey(year: .max, month: 12)
        XCTAssertNil(lastMonth.next)
        let spec = RecurrenceSpec.monthly(onDay: 15, from: lastMonth, through: nil)
        let occurrences = spec.occurrences(
            from: Day(year: .max, month: 12, day: 1), to: Day(year: .max, month: 12, day: 31)
        )
        XCTAssertEqual(occurrences, [Day(year: .max, month: 12, day: 15)])

        // The same at the low edge, where the first month has no predecessor.
        let firstMonth = MonthKey(year: .min, month: 1)
        XCTAssertNil(firstMonth.previous)
        XCTAssertEqual(
            RecurrenceSpec.monthlyWindow(
                earliestDay: 5, latestDay: 8, from: firstMonth, through: nil
            ).occurrences(
                from: Day(year: .min, month: 1, day: 1), to: Day(year: .min, month: 1, day: 31)
            ),
            [Day(year: .min, month: 1, day: 5)]
        )
    }

    func testIntervalMonthKeysStopAtTheFinalMonth() {
        let interval = ReviewInterval(
            start: Day(year: .max, month: 11, day: 1), end: Day(year: .max, month: 12, day: 31)
        )
        XCTAssertEqual(
            interval.monthKeys,
            [MonthKey(year: .max, month: 11), MonthKey(year: .max, month: 12)]
        )
        XCTAssertEqual(
            ReviewInterval.month(MonthKey(year: 2026, month: 9)).monthKeys,
            [MonthKey(year: 2026, month: 9)]
        )
    }

    // MARK: - ReviewEngine: adjacency, and a period it cannot compute

    /// Merging touches intervals that overlap or sit one day apart. A
    /// separation no Int can express is a gap; nothing about the arithmetic
    /// failing may fabricate adjacency.
    func testIntervalMergingTreatsAnUnrepresentableSeparationAsAGap() {
        let low = ReviewInterval(
            start: Day(year: .min, month: 1, day: 1), end: Day(year: .min, month: 1, day: 2)
        )
        let high = ReviewInterval(
            start: Day(year: .max, month: 12, day: 30), end: Day(year: .max, month: 12, day: 31)
        )
        XCTAssertNil(low.end.days(until: high.start))
        XCTAssertEqual(ReviewEngine.mergeIntervals([low, high]), [low, high])
    }

    func testOrdinaryIntervalAdjacencyAndOverlapAreUnchanged() {
        let first = ReviewInterval(start: day("2026-09-01"), end: day("2026-09-10"))
        let adjacent = ReviewInterval(start: day("2026-09-11"), end: day("2026-09-20"))
        let overlapping = ReviewInterval(start: day("2026-09-05"), end: day("2026-09-20"))
        let separated = ReviewInterval(start: day("2026-09-12"), end: day("2026-09-20"))

        XCTAssertEqual(
            ReviewEngine.mergeIntervals([first, adjacent]),
            [ReviewInterval(start: day("2026-09-01"), end: day("2026-09-20"))]
        )
        XCTAssertEqual(
            ReviewEngine.mergeIntervals([first, overlapping]),
            [ReviewInterval(start: day("2026-09-01"), end: day("2026-09-20"))]
        )
        XCTAssertEqual(ReviewEngine.mergeIntervals([first, separated]), [first, separated])
    }

    private func request(_ interval: ReviewInterval, asOf: Day) -> ReviewRequest {
        ReviewRequest(
            document: FinanceDocument(
                schemaVersion: Interchange.currentSchemaVersion,
                documentKind: "TEST", accounts: [bank], balances: [],
                planning: FinanceDocument.Planning(defaultScenario: .base)
            ),
            kind: .monthly,
            interval: interval,
            asOf: asOf,
            coverage: ReviewCoverageInput(liveCoveredIntervals: [interval])
        )
    }

    /// An interval whose own length cannot be stated is refused. No coverage
    /// verdict, no zero totals, no ReviewResult standing in for one.
    func testAPeriodWhoseLengthCannotBeStatedIsRefused() {
        let interval = ReviewInterval(
            start: Day(year: .min, month: 1, day: 1), end: Day(year: .max, month: 12, day: 31)
        )
        XCTAssertNil(interval.dayCount)
        XCTAssertThrowsError(try ReviewEngine.review(request(interval, asOf: interval.end))) {
            XCTAssertEqual($0 as? ReviewError, .dateArithmeticOutOfRange)
        }
    }

    /// An outlook horizon that cannot be built is the same refusal. The review
    /// does not quietly report risk over a window it did not use.
    func testAnUnbuildableOutlookHorizonIsRefused() {
        let asOf = Day(year: .max, month: 12, day: 31)
        let interval = ReviewInterval(start: asOf, end: asOf)
        var request = request(interval, asOf: asOf)
        XCTAssertNil(request.resolvedForecastEnd)
        XCTAssertThrowsError(try ReviewEngine.review(request)) {
            XCTAssertEqual($0 as? ReviewError, .dateArithmeticOutOfRange)
        }
        // With a horizon it can express, the same period reviews normally.
        request.forecastHorizonEnd = asOf
        XCTAssertEqual(try ReviewEngine.review(request).interval, interval)
    }

    func testAstronomicalOutlookIsRefusedBeforeMonthlyExpansion() {
        let asOf = Day(index: 0)
        let interval = ReviewInterval(start: asOf, end: asOf)
        var request = request(interval, asOf: asOf)
        request.document.planning.recurringObligations = [
            RecurringObligation(
                id: "monthly", name: "Monthly", amount: euro(100),
                spec: .monthly(onDay: 1, from: asOf.monthKey, through: nil),
                requirement: PaymentRequirement(currency: .eur, acceptableRails: PaymentRail.euroBankRails),
                spendingClass: .essential
            )
        ]
        // Neither horizon can be walked to completion. Preflight must precede
        // expansion: one distance is nil, the other's inclusive count overflows.
        for end in [Day(year: .max, month: 12, day: 31), Day(index: .max)] {
            request.forecastHorizonEnd = end
            XCTAssertThrowsError(try ReviewEngine.review(request)) {
                XCTAssertEqual($0 as? ReviewError, .dateArithmeticOutOfRange)
            }
        }
    }

    func testSharedHorizonPreflightPreservesForecastBoundaries() {
        let start = Day(index: 0)
        for end in [start, Day(index: .max - 1)] {
            XCTAssertNoThrow(try ForecastEngine.validateHorizon(start: start, end: end))
            XCTAssertNoThrow(try ForecastEngine.validate(forecastRequest(from: start, to: end)))
        }
        for (end, error) in [(Day(index: -1), ForecastError.emptyHorizon),
                             (Day(index: .max), .dateArithmeticOutOfRange),
                             (Day(year: .max, month: 12, day: 31), .dateArithmeticOutOfRange)] {
            XCTAssertThrowsError(try ForecastEngine.validateHorizon(start: start, end: end)) {
                XCTAssertEqual($0 as? ForecastError, error)
            }
            XCTAssertThrowsError(try ForecastEngine.validate(forecastRequest(from: start, to: end))) {
                XCTAssertEqual($0 as? ForecastError, error)
            }
        }
    }

    /// A comparison was asked for; a prior period that cannot be built is
    /// reported rather than answered with a coverage refusal that would read
    /// as evidence about records.
    func testAnUnbuildablePriorPeriodIsRefusedNotRefusedAsCoverage() {
        let interval = ReviewInterval(
            start: Day(year: .min, month: 1, day: 1), end: Day(year: .min, month: 1, day: 31)
        )
        XCTAssertNil(interval.previous(kind: .monthly))
        var request = request(interval, asOf: interval.end)
        request.comparePreviousPeriod = true
        request.forecastHorizonEnd = interval.end
        XCTAssertThrowsError(try ReviewEngine.review(request)) {
            XCTAssertEqual($0 as? ReviewError, .dateArithmeticOutOfRange)
        }
    }

    /// The uncovered-day walk counts the interval's last day and stops there.
    func testTheUncoveredDayWalkCountsTheFinalDayAndStops() {
        let interval = ReviewInterval(
            start: Day(year: .max, month: 12, day: 29), end: Day(year: .max, month: 12, day: 31)
        )
        XCTAssertNil(interval.end.advanced(by: 1))
        XCTAssertEqual(
            ReviewEngine.uncoveredDayCount(interval: interval, missing: [interval]), 3
        )
        XCTAssertEqual(ReviewEngine.uncoveredDayCount(interval: interval, missing: []), 0)
    }
}
