import XCTest
@testable import FinanceCore

func legacyMoneyDecoder() -> JSONDecoder {
    let decoder = Interchange.decoder()
    decoder.userInfo[.financeDocumentMoneyWire] = InterchangeFormat.v1
    return decoder
}

final class LegacyMoneyCodingTests: XCTestCase {
    func testHistoricalTableIsFrozenMemberByMember() {
        let zero: Set<String> = ["JPY", "KRW", "VND", "CLP"]
        let three: Set<String> = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]
        for a in UInt8(65)...90 { for b in UInt8(65)...90 { for c in UInt8(65)...90 {
            let code = String(bytes: [a,b,c], encoding: .utf8)!
            XCTAssertEqual(Currency.legacyDefaultDigits(code), zero.contains(code) ? 0 : three.contains(code) ? 3 : 2, code)
        } } }
    }

    func testHistoricalInterpretationAndMalformedCodes() throws {
        for (wire, expected) in [("1 EUR", Money(minorUnits: 100, currency: .eur)),
                                  ("1 JPY", Money(minorUnits: 1, currency: .jpy)),
                                  ("0.001 KWD", Money(minorUnits: 1, currency: .kwd))] {
            XCTAssertEqual(try legacyMoneyDecoder().decode(Money.self, from: JSONEncoder().encode(wire)), expected)
        }
        for wire in ["0.001 EUR", "1 ZZZZ", "1 eur", "9223372036854775808 JPY"] {
            XCTAssertThrowsError(try legacyMoneyDecoder().decode(Money.self, from: JSONEncoder().encode(wire)))
        }
        XCTAssertEqual(try legacyMoneyDecoder().decode(Currency.self, from: Data("\"EUR\"".utf8)), .eur)
        XCTAssertThrowsError(try legacyMoneyDecoder().decode(Currency.self, from: Data("\"eur\"".utf8)))
    }

    func testDecimalGrammarAndOverflow() {
        for (text, units) in [("0",0), ("-0",0), ("1.",100), ("01.20",120), ("0012",1200)] {
            XCTAssertEqual(Money(exactDecimal: text, currency: .eur)?.minorUnits, Int64(units))
        }
        for text in [".5", "1.2.3", "1.234", "+1", "١", "１", " 1", "1 ", "92233720368547758.08", "-92233720368547758.09", "999999999999999999999999999999"] {
            XCTAssertNil(Money(exactDecimal: text, currency: .eur), text)
        }
        XCTAssertEqual(Money(exactDecimal: "1.", currency: .jpy)?.minorUnits, 1)
        XCTAssertNil(Money(exactDecimal: "1.0", currency: .jpy))
        XCTAssertEqual(Money(exactDecimal: "-92233720368547758.08", currency: .eur)?.minorUnits, .min)
    }

    func testSafeRendererAndInt64LegacyRoundTrip() throws {
        for (units, currency, expected) in [(Int64.min, Currency.eur, "-92233720368547758.08"),
            (.min, .jpy, "-9223372036854775808"), (.max, .eur, "92233720368547758.07"), (-5, .eur, "-0.05")] {
            XCTAssertEqual(Money(minorUnits: units, currency: currency).decimalString, expected)
        }
        let encoder = Interchange.encoder()
        encoder.userInfo[.financeDocumentMoneyWire] = InterchangeFormat.v1
        for currency in [Currency.eur, .jpy, .kwd, Currency(code: "XAA")] {
            for units in [Int64.min, -1, 0, 1, .max] {
                let money = Money(minorUnits: units, currency: currency)
                XCTAssertEqual(try legacyMoneyDecoder().decode(Money.self, from: encoder.encode(money)), money)
            }
        }
        XCTAssertThrowsError(try encoder.encode(Money(minorUnits: 1, currency: Currency(code: "EUR", minorUnitDigits: 0))))

        // A standalone currency carries the same refusal. The document
        // preflight normally rejects first, so this is the only assertion that
        // reaches the leaf's own guard — without it, deleting that guard is
        // invisible and `accounts[].currency` silently loses its exponent on
        // any encoder driven directly rather than through `Interchange.encode`.
        XCTAssertEqual(
            String(decoding: try encoder.encode(Currency.eur), as: UTF8.self), "\"EUR\""
        )
        for exponent in [0, 1, 3, 6] {
            XCTAssertThrowsError(
                try encoder.encode(Currency(code: "EUR", minorUnitDigits: exponent)), "EUR/\(exponent)"
            ) { error in
                XCTAssertEqual(error as? InterchangeError, .notRepresentableInV1(field: ""))
            }
        }
    }
}
