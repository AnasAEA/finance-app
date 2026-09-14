import XCTest
@testable import FinanceCore

/// Money, currency, rounding and explicit exchange rates.
///
/// Proof #16 (currency mismatch requires explicit conversion) lives here at
/// the value level: there is no API that converts implicitly — the only path
/// from EUR to MAD is an `ExchangeRate`, and arithmetic across currencies is
/// a trapped programming error rather than silent behavior.
final class MoneyTests: XCTestCase {

    func testIntegerMinorUnitsNeverUseDouble() {
        let eur = Money(minorUnits: 48_000, currency: .eur)
        XCTAssertEqual(eur.minorUnits, 48_000)
        XCTAssertEqual(eur.description, "480.00 EUR")
        XCTAssertEqual(Money(exactDecimal: "0.10", currency: .eur)! + Money(exactDecimal: "0.20", currency: .eur)!,
                       Money(exactDecimal: "0.30", currency: .eur)!)
        // The classic Double trap: 0.1 + 0.2 != 0.3 in binary floating point.
        // Integer minor units make it exact.
        XCTAssertNotEqual(0.1 + 0.2, 0.3)
    }

    func testExactDecimalParsingIsStrict() {
        XCTAssertEqual(Money(exactDecimal: "-30.00", currency: .eur)?.minorUnits, -3_000)
        XCTAssertEqual(Money(exactDecimal: "200.00", currency: .mad)?.minorUnits, 20_000)
        XCTAssertNil(Money(exactDecimal: "1.999", currency: .eur))   // too many fractional digits
        XCTAssertNil(Money(exactDecimal: "1.2.3", currency: .eur))
        XCTAssertNil(Money(exactDecimal: "", currency: .eur))
        XCTAssertNil(Money(exactDecimal: "abc", currency: .eur))
        // Zero-digit currency accepts no fractional part
        XCTAssertNil(Money(exactDecimal: "1.0", currency: .jpy))
        XCTAssertEqual(Money(exactDecimal: "1000", currency: .jpy)?.minorUnits, 1_000)
    }

    func testCurrencyIdentityIncludesMinorUnitDigits() {
        XCTAssertEqual(Currency.eur.code, "EUR")
        XCTAssertEqual(Currency.mad.minorUnitDigits, 2)
        XCTAssertEqual(Currency.jpy.minorUnitDigits, 0)
        XCTAssertNotEqual(Currency(code: "EUR", minorUnitDigits: 2), Currency(code: "EUR", minorUnitDigits: 3))
    }

    func testAllocationSumsBackExactlyAndDeterministically() {
        let hundred = Money(exactDecimal: "100.00", currency: .eur)!
        let parts = hundred.allocated(ratios: [1, 1, 1])
        XCTAssertEqual(parts, [Money(exactDecimal: "33.34", currency: .eur)!,
                               Money(exactDecimal: "33.33", currency: .eur)!,
                               Money(exactDecimal: "33.33", currency: .eur)!])
        XCTAssertEqual(Money.sum(parts, currency: .eur), hundred)

        // Largest remainder is deterministic: the earliest index takes the cent.
        let tenCentsOverFour = Money(exactDecimal: "0.10", currency: .eur)!.allocated(ratios: [1, 1, 1, 1])
        XCTAssertEqual(tenCentsOverFour.map(\.minorUnits), [3, 3, 2, 2])
    }

    func testRoundingRules() {
        // 2.5
        XCTAssertEqual(roundDivide(5, by: 2, rule: .down), 2)
        XCTAssertEqual(roundDivide(5, by: 2, rule: .up), 3)
        XCTAssertEqual(roundDivide(5, by: 2, rule: .halfUp), 3)
        XCTAssertEqual(roundDivide(5, by: 2, rule: .halfEven), 2)
        // 3.5
        XCTAssertEqual(roundDivide(7, by: 2, rule: .halfUp), 4)
        XCTAssertEqual(roundDivide(7, by: 2, rule: .halfEven), 4)
        // 0.5
        XCTAssertEqual(roundDivide(1, by: 2, rule: .halfUp), 1)
        XCTAssertEqual(roundDivide(1, by: 2, rule: .halfEven), 0)
        // Negatives round symmetrically (away/toward zero, not floor/ceil)
        XCTAssertEqual(roundDivide(-5, by: 2, rule: .down), -2)
        XCTAssertEqual(roundDivide(-5, by: 2, rule: .up), -3)
        XCTAssertEqual(roundDivide(-5, by: 2, rule: .halfUp), -3)
        XCTAssertEqual(roundDivide(-5, by: 2, rule: .halfEven), -2)
    }

    /// The observed ATM rate: €30.00 became 200 MAD. Converting back must be
    /// exact — it is an observation, not an estimate.
    func testObservedExchangeRateRoundTrip() {
        let withdrawalCost = Money(exactDecimal: "30.00", currency: .eur)!
        let dirhams = Money(exactDecimal: "200.00", currency: .mad)!
        let rate = ExchangeRate.observed(fromAmount: withdrawalCost, toAmount: dirhams)

        XCTAssertEqual(rate.convert(withdrawalCost, to: .mad, rule: .halfUp), dirhams)
        XCTAssertEqual(rate.inverted.convert(dirhams, to: .eur, rule: .halfUp), withdrawalCost)

        // 1 MAD in euro terms at the observed rate: 30.00/200 = 0.15
        XCTAssertEqual(rate.inverted.convert(Money(exactDecimal: "1.00", currency: .mad)!, to: .eur, rule: .down),
                       Money(exactDecimal: "0.15", currency: .eur)!)
    }

    func testExplicitRateRounding() {
        // 1 EUR = 2.5 MAD expressed exactly.
        let rate = ExchangeRate(from: .eur, to: .mad, numerator: 250, denominator: 100)
        let oneCent = Money(minorUnits: 1, currency: .eur)
        XCTAssertEqual(rate.convert(oneCent, to: .mad, rule: .down).minorUnits, 2)
        XCTAssertEqual(rate.convert(oneCent, to: .mad, rule: .halfUp).minorUnits, 3)
        XCTAssertEqual(rate.convert(oneCent, to: .mad, rule: .halfEven).minorUnits, 2)
    }

    /// There is no implicit conversion anywhere in the API surface: Money has
    /// no `converted(to:)` without a rate, and mixed-currency arithmetic is a
    /// trap (precondition), not a silent value.
    func testNoImplicitConversionAPI() {
        let eur = Money(exactDecimal: "10.00", currency: .eur)!
        let mad = Money(exactDecimal: "10.00", currency: .mad)!
        XCTAssertNotEqual(eur, mad) // same magnitude, different money
        // The only conversion entry points:
        _ = eur.converted(to: .mad, rate: ExchangeRate(from: .eur, to: .mad, numerator: 250, denominator: 100), rule: .down)
        let rate = ExchangeRate(from: .mad, to: .eur, numerator: 100, denominator: 250)
        _ = rate.convert(mad, to: .eur, rule: .down)
    }
}
