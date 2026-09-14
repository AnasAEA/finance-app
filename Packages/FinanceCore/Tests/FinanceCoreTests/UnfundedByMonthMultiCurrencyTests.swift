import XCTest
@testable import FinanceCore

/// Regression suite: `unfundedByMonth` is multi-currency safe.
///
/// A month whose settlement failures span currencies (EUR + MAD, + KWD …)
/// must keep each deficit exact and separate — never `Money.+` across
/// currencies (the old accumulation trapped on the second currency), never
/// an implicit conversion, never a dropped foreign-currency deficit. The
/// authoritative representation is `[MonthKey: MoneyBag]`.
final class UnfundedByMonthMultiCurrencyTests: XCTestCase {

    private let euroBank = Account(id: "eur-bank", name: "Euro bank", currency: .eur, kind: .bank, supportedRails: PaymentRail.euroBankRails)
    private let madCash = Account(id: "mad-cash", name: "Dirham pocket", currency: .mad, kind: .cash, supportedRails: PaymentRail.cashOnlyRails)
    private let kwdCash = Account(id: "kwd-cash", name: "Dinar pocket", currency: .kwd, kind: .cash, supportedRails: PaymentRail.cashOnlyRails)

    private let september = MonthKey(year: 2026, month: 9)
    private let october = MonthKey(year: 2026, month: 10)

    private func money(_ decimal: String, _ currency: Currency) -> Money {
        Money(exactDecimal: decimal, currency: currency)!
    }

    private func day(_ iso: String) -> Day {
        Day(isoString: iso)!
    }

    /// A SEPA debit the empty euro bank cannot settle.
    private func sepaEUR(_ id: String, _ decimal: String, on iso: String) -> ForecastEvent {
        ForecastEvent(
            id: id, day: day(iso), phase: .scheduledDebit,
            effect: .debit(money(decimal, .eur), requirement: PaymentRequirement.euroBankPayment(rails: [.sepaDirectDebit]))
        )
    }

    /// An in-person debit in a foreign currency the empty pocket cannot settle.
    private func cashDebit(_ id: String, _ decimal: String, currency: Currency, on iso: String) -> ForecastEvent {
        ForecastEvent(
            id: id, day: day(iso), phase: .scheduledDebit,
            effect: .debit(money(decimal, currency), requirement: PaymentRequirement(currency: currency, acceptableRails: [.physicalCash]))
        )
    }

    private func run(_ events: [ForecastEvent]) throws -> ForecastResult {
        try ForecastEngine.run(
            ForecastRequest(
                startDate: day("2026-09-01"),
                endDate: day("2026-10-31"),
                accounts: [euroBank, madCash, kwdCash],
                startingBalances: [
                    "eur-bank": money("0.00", .eur),
                    "mad-cash": money("0.00", .mad),
                    "kwd-cash": money("0.00", .kwd),
                ],
                events: events,
                scenario: .base
            )
        )
    }

    // MARK: - 1. One EUR failure

    func testOneEURFailureProducesExactEURAmount() throws {
        let result = try run([sepaEUR("a", "12.50", on: "2026-09-04")])

        XCTAssertEqual(result.unfundedByMonth[september], MoneyBag(money("12.50", .eur)))
        XCTAssertEqual(result.unfundedByMonth[september]?.currencies, [.eur])
        XCTAssertEqual(result.unfunded(in: .eur, month: september), money("12.50", .eur))
        XCTAssertNil(result.unfundedByMonth[october])
    }

    // MARK: - 2. Two EUR failures aggregate

    func testTwoEURFailuresSumCorrectly() throws {
        let result = try run([
            sepaEUR("a", "10.00", on: "2026-09-02"),
            sepaEUR("b", "5.00", on: "2026-09-20"),
        ])

        XCTAssertEqual(result.unfundedByMonth[september], MoneyBag(money("15.00", .eur)))
        XCTAssertEqual(result.unfunded(in: .eur, month: september), money("15.00", .eur))
    }

    // MARK: - 3. EUR + MAD in the same month (the original trap)

    func testEURAndMADFailuresInSameMonthAreBothPreserved() throws {
        // Before the MoneyBag fix this exact run precondition-trapped inside
        // Money.+ (EUR running total + MAD unsettled). Passing = no crash.
        let result = try run([
            sepaEUR("eur-a", "12.50", on: "2026-09-04"),
            cashDebit("mad-a", "100.00", currency: .mad, on: "2026-09-15"),
        ])

        let bag = try XCTUnwrap(result.unfundedByMonth[september])
        XCTAssertEqual(bag.amount(in: .eur), money("12.50", .eur))
        XCTAssertEqual(bag.amount(in: .mad), money("100.00", .mad))
        XCTAssertEqual(bag.currencies, [.eur, .mad], "sorted by ISO code, both currencies present")
        XCTAssertEqual(bag, MoneyBag([money("12.50", .eur), money("100.00", .mad)]))
    }

    // MARK: - 4. Three currencies, including a 3-decimal one

    func testEURMADAndKWDFailuresAreAllPreservedExactly() throws {
        let result = try run([
            sepaEUR("eur-a", "12.50", on: "2026-09-04"),
            cashDebit("mad-a", "100.00", currency: .mad, on: "2026-09-15"),
            cashDebit("kwd-a", "3.750", currency: .kwd, on: "2026-09-28"),
        ])

        let bag = try XCTUnwrap(result.unfundedByMonth[september])
        XCTAssertEqual(bag.amount(in: .eur), money("12.50", .eur))
        XCTAssertEqual(bag.amount(in: .mad), money("100.00", .mad))
        XCTAssertEqual(bag.amount(in: .kwd), money("3.750", .kwd), "KWD keeps its 3 minor digits exactly")
        XCTAssertEqual(bag.currencies, [.eur, .kwd, .mad])
        XCTAssertEqual(bag, MoneyBag([money("12.50", .eur), money("100.00", .mad), money("3.750", .kwd)]))
    }

    // MARK: - 5. Month partitioning

    func testDifferentMonthsAndCurrenciesPartitionCorrectly() throws {
        let result = try run([
            sepaEUR("sep-eur", "12.50", on: "2026-09-10"),
            cashDebit("oct-mad", "60.00", currency: .mad, on: "2026-10-05"),
            sepaEUR("oct-eur", "7.25", on: "2026-10-12"),
        ])

        XCTAssertEqual(result.unfundedByMonth[september], MoneyBag(money("12.50", .eur)))
        XCTAssertEqual(result.unfundedByMonth[september]?.currencies, [.eur], "September never sees October's dirhams")

        let octoberBag = try XCTUnwrap(result.unfundedByMonth[october])
        XCTAssertEqual(octoberBag.amount(in: .eur), money("7.25", .eur))
        XCTAssertEqual(octoberBag.amount(in: .mad), money("60.00", .mad))
        XCTAssertEqual(octoberBag.currencies, [.eur, .mad])
    }

    // MARK: - 6. Determinism under input shuffling

    func testInputOrderShuffledProducesIdenticalResult() throws {
        let events = [
            sepaEUR("eur-a", "12.50", on: "2026-09-04"),
            cashDebit("mad-a", "100.00", currency: .mad, on: "2026-09-15"),
            cashDebit("kwd-a", "3.750", currency: .kwd, on: "2026-09-28"),
            cashDebit("mad-b", "40.00", currency: .mad, on: "2026-09-20"),
        ]
        let reference = try run(events)
        let shuffled = try run(events.reversed())

        XCTAssertEqual(shuffled, reference)
        XCTAssertEqual(shuffled.unfundedByMonth, reference.unfundedByMonth)
        XCTAssertEqual(shuffled.unfundedByMonth[september]?.amount(in: .mad), money("140.00", .mad))
    }

    // MARK: - 7. No implicit FX

    func testForeignFailuresNeverConvertIntoEUR() throws {
        let euroOnly = try run([sepaEUR("eur-a", "12.50", on: "2026-09-04")])
        let mixed = try run([
            sepaEUR("eur-a", "12.50", on: "2026-09-04"),
            cashDebit("mad-a", "100.00", currency: .mad, on: "2026-09-15"),
        ])

        // The EUR read-out is byte-identical whether or not dirhams failed:
        // no rate is ever applied, no EUR-equivalent total is ever produced.
        XCTAssertEqual(mixed.unfunded(in: .eur, month: september), euroOnly.unfunded(in: .eur, month: september))
        XCTAssertEqual(mixed.unfundedEURByMonth, [september: money("12.50", .eur)],
                       "the EUR-only view carries exactly the EUR deficit — MAD 100.00 is not in it anywhere")
        XCTAssertEqual(mixed.unfundedByMonth[september]?.amount(in: .mad), money("100.00", .mad),
                       "and the dirham deficit stays a dirham fact")
    }
}
