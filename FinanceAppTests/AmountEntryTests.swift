import Testing
import Foundation
@testable import FinanceApp

/// Manual entry reads a typed figure at the scale of the currency it is going
/// into, never at a hard-coded two decimals. `×100` turns ¥123 into ¥12,300 and
/// KD 12.345 into KD 123.45 — both wrong by an order of magnitude, and both
/// silent.
@MainActor
@Suite("A typed figure is read at its own currency's scale")
struct AmountEntryTests {

    @Test("EUR keeps two decimals")
    func euro() throws {
        let amount = try Amount.parse("12.34", currencyCode: "EUR", fractionDigits: 2)
        #expect(amount.minorUnits == 1234)
        #expect(amount.fractionDigits == 2)
        #expect(try Amount.parse("12", currencyCode: "EUR", fractionDigits: 2).minorUnits == 1200)
        #expect(try Amount.parse("0.05", currencyCode: "EUR", fractionDigits: 2).minorUnits == 5)
    }

    @Test("JPY has no decimals")
    func yen() throws {
        let amount = try Amount.parse("123", currencyCode: "JPY", fractionDigits: 0)
        #expect(amount.minorUnits == 123)
        #expect(amount.fractionDigits == 0)
    }

    @Test("KWD has three")
    func dinar() throws {
        let amount = try Amount.parse("12.345", currencyCode: "KWD", fractionDigits: 3)
        #expect(amount.minorUnits == 12345)
        #expect(amount.fractionDigits == 3)
        #expect(try Amount.parse("12.3", currencyCode: "KWD", fractionDigits: 3).minorUnits == 12300)
    }

    @Test("A figure finer than the currency is refused, never rounded")
    func excessPrecisionFails() {
        func failure(_ text: String, _ code: String, _ digits: Int) -> Amount.ParseFailure? {
            do { _ = try Amount.parse(text, currencyCode: code, fractionDigits: digits); return nil }
            catch let failure as Amount.ParseFailure { return failure }
            catch { return nil }
        }
        #expect(failure("123.5", "JPY", 0) == .excessPrecision(allowed: 0))
        #expect(failure("12.345", "EUR", 2) == .excessPrecision(allowed: 2))
        #expect(failure("12.3456", "KWD", 3) == .excessPrecision(allowed: 3))
    }

    @Test("A comma is a decimal separator; anything else is not a number")
    func separatorsAndJunk() throws {
        #expect(try Amount.parse("12,34", currencyCode: "EUR", fractionDigits: 2).minorUnits == 1234)
        #expect(try Amount.parse(" 12.34 ", currencyCode: "EUR", fractionDigits: 2).minorUnits == 1234)

        func failure(_ text: String) -> Amount.ParseFailure? {
            do { _ = try Amount.parse(text, currencyCode: "EUR", fractionDigits: 2); return nil }
            catch let failure as Amount.ParseFailure { return failure }
            catch { return nil }
        }
        // `Decimal(string:)` alone would read "12abc" as 12.
        #expect(failure("12abc") == .notANumber)
        #expect(failure("1.2.3") == .notANumber)
        #expect(failure("-5") == .notANumber)
        #expect(failure("") == .empty)
        #expect(failure("   ") == .empty)
    }

    @Test("Entry options carry each account's exponent")
    func entryOptionsCarryExponent() throws {
        let harness = try EntryFixtures.Harness()
        let store = harness.store
        let accounts = store.snapshot.entryOptions.accounts
        #expect(accounts.first { $0.currencyCode == "EUR" }?.fractionDigits == 2)
        #expect(accounts.first { $0.currencyCode == "KWD" }?.fractionDigits == 3)
        #expect(accounts.first { $0.currencyCode == "MAD" }?.fractionDigits == 2)
    }

    @Test("A three-decimal entry survives the whole entry path")
    func dinarEntryRoundTrip() throws {
        let harness = try EntryFixtures.Harness()
        let store = harness.store
        let amount = try Amount.parse("12.345", currencyCode: "KWD", fractionDigits: 3)
        try store.add(
            EntryFixtures.draft(amount: amount, accountID: EntryFixtures.walletKWD.id)
        )
        let saved = try #require(try store.exportDocument().transactions.first)
        #expect(saved.legs[0].amount.minorUnits == -12_345)
        #expect(saved.legs[0].amount.currency.minorUnitDigits == 3)
        #expect(saved.legs[0].amount.description == "-12.345 KWD")
    }
}
