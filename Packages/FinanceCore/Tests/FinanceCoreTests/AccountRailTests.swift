import XCTest
@testable import FinanceCore

/// Proof #7 — physical cash is distinguished from bank liquidity — and the
/// general rail-capability model.
final class AccountRailTests: XCTestCase {

    private let bnp = Account(
        id: "bnp",
        name: "Bank",
        currency: .eur,
        kind: .bank,
        supportedRails: PaymentRail.euroBankRails
    )
    private let revolut = Account(
        id: "revolut",
        name: "Wallet",
        currency: .eur,
        kind: .wallet,
        supportedRails: PaymentRail.euroWalletRails
    )
    private let madCash = Account(
        id: "cash-mad",
        name: "Dirhams in hand",
        currency: .mad,
        kind: .cash,
        supportedRails: [.physicalCash]
    )
    /// Euros in the pocket: right currency, wrong rail.
    private let eurCash = Account(
        id: "cash-eur",
        name: "Euros in hand",
        currency: .eur,
        kind: .cash,
        supportedRails: [.physicalCash]
    )

    func testKindAndCapabilityAreIndependent() {
        XCTAssertEqual(bnp.kind, .bank)
        XCTAssertEqual(madCash.kind, .cash)
        // Capability comes from supportedRails, not from kind or currency.
        XCTAssertTrue(bnp.supports(anyOf: [.sepaDirectDebit]))
        XCTAssertFalse(revolut.supports(anyOf: [.sepaDirectDebit]),
                       "the wallet cannot be direct-debited even though it is euro and electronic")
        XCTAssertTrue(madCash.supports(anyOf: [.physicalCash]))
    }

    func testCurrencyAloneIsNotSatisfaction() {
        let sepaRent = PaymentRequirement(currency: .eur, acceptableRails: [.sepaDirectDebit])
        XCTAssertTrue(bnp.satisfies(sepaRent))
        XCTAssertFalse(madCash.satisfies(sepaRent), "wrong currency AND wrong rail")
        XCTAssertFalse(eurCash.satisfies(sepaRent), "right currency, wrong rail — euros in hand cannot pay a SEPA debit")
    }

    func testRailsAloneAreNotSatisfaction() {
        let cashOnlyPurchase = PaymentRequirement(currency: .eur, acceptableRails: [.physicalCash])
        XCTAssertFalse(bnp.satisfies(cashOnlyPurchase), "a bank account cannot settle an in-person-cash-only payment")
        XCTAssertTrue(eurCash.satisfies(cashOnlyPurchase))
        XCTAssertFalse(madCash.satisfies(cashOnlyPurchase), "dirhams cannot settle a euro purchase, even in person")
    }

    func testRailIdentityIsTheIDNotTheSummary() {
        XCTAssertEqual(PaymentRail(id: "sepa_direct_debit", summary: "x"),
                       PaymentRail.sepaDirectDebit)
    }

    func testRailDecodingIsExtensible() {
        let json = #""instant_payment_scheme""#
        let data = Data(json.utf8)
        let rail = try! JSONDecoder().decode(PaymentRail.self, from: data)
        XCTAssertEqual(rail.id, "instant_payment_scheme",
                       "an unknown rail decodes instead of failing — the model is not closed")
    }

    func testInactiveAccountsNeverSatisfy() {
        var closed = bnp
        closed.isActive = false
        XCTAssertFalse(closed.satisfies(PaymentRequirement.euroBankPayment()))
    }
}
