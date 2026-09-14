import XCTest
@testable import FinanceCore

/// Proof #8 — payment-rail awareness inside the engine: money that cannot
/// ride the rail of an obligation is never used to satisfy it, and physical
/// MAD cash never prevents a euro bank balance from going negative.
final class RailAwarenessTests: XCTestCase {

    private let bnp = Account(id: "bnp", name: "Bank", currency: .eur, kind: .bank, supportedRails: PaymentRail.euroBankRails)
    private let madCash = Account(id: "cash-mad", name: "Dirhams", currency: .mad, kind: .cash, supportedRails: [.physicalCash])
    private let eurCash = Account(id: "cash-eur", name: "Euro pocket", currency: .eur, kind: .cash, supportedRails: [.physicalCash])

    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    private func request(
        accounts: [Account],
        balances: [String: Money],
        obligation: PaymentRequirement,
        amount: String = "300.00"
    ) -> ForecastRequest {
        ForecastRequest(
            startDate: Day(isoString: "2026-09-01")!,
            endDate: Day(isoString: "2026-09-30")!,
            accounts: accounts,
            startingBalances: balances,
            events: [
                ForecastEvent(
                    id: "rent",
                    day: Day(isoString: "2026-09-11")!,
                    phase: .scheduledDebit,
                    effect: .debit(euro(amount), requirement: obligation)
                )
            ],
            scenario: .base,
            carriedEURValues: ["cash-mad": euro("30.00")]
        )
    }

    func testPhysicalMADCashCannotPreventEuroSEPANegative() {
        // 200 MAD in hand, €50 in the bank, a €300 SEPA direct debit due.
        let result = try! ForecastEngine.run(request(
            accounts: [bnp, madCash],
            balances: ["bnp": euro("50.00"), "cash-mad": Money(exactDecimal: "200.00", currency: .mad)!],
            obligation: PaymentRequirement.euroBankPayment(rails: [.sepaDirectDebit])
        ))

        // The bank balance went negative — the dirhams did not rescue it.
        XCTAssertEqual(result.firstNegativeDate, Day(isoString: "2026-09-11")!)
        XCTAssertEqual(result.lowestBalance, euro("-250.00"))
        XCTAssertEqual(result.minimumBridgeRequired, euro("250.00"))

        // The cash balance is untouched: no cross-currency charge was invented.
        let cashAtEnd = result.dailyBalances.last!.endOfDay["cash-mad"]!
        XCTAssertEqual(cashAtEnd, Money(exactDecimal: "200.00", currency: .mad)!)

        // The uncovered part is recorded as a settlement failure, in euros —
        // requested vs settled vs unsettled, with the eligible accounts named.
        XCTAssertEqual(result.settlementFailures.count, 1)
        let failure = result.settlementFailures.first!
        XCTAssertEqual(failure.eventID, "rent")
        XCTAssertEqual(failure.requested, euro("300.00"))
        XCTAssertEqual(failure.settled, euro("50.00"))
        XCTAssertEqual(failure.unsettled, euro("250.00"))
        XCTAssertEqual(failure.eligibleAccountIDs, ["bnp"], "the MAD pocket is not eligible for a EUR SEPA debit")
        XCTAssertEqual(failure.requirement.currency, .eur)

        // Spendable pool excludes the dirhams; tracked liquidity carries them
        // at their observed cost (€30.00), never at a market estimate.
        let last = result.dailyBalances.last!
        XCTAssertEqual(last.spendablePool, euro("-250.00"))
        XCTAssertEqual(last.otherTrackedEUR, euro("30.00"))
        XCTAssertEqual(last.trackedLiquidityEUR, euro("-220.00"))
    }

    func testEuroPocketCashCannotSatisfyBankRailsEither() {
        // Right currency, wrong rail: €500 physical euros cannot pay a €300
        // card/electronic obligation.
        let result = try! ForecastEngine.run(request(
            accounts: [bnp, eurCash],
            balances: ["bnp": euro("0.00"), "cash-eur": euro("500.00")],
            obligation: PaymentRequirement.euroBankPayment(rails: [.cardDebit, .electronicPayment])
        ))
        XCTAssertEqual(result.firstNegativeDate, Day(isoString: "2026-09-11")!)
        XCTAssertEqual(result.dailyBalances.last!.endOfDay["cash-eur"], euro("500.00"),
                       "the euro pocket is untouched by a bank-rail debit")
        // The euro pocket IS tracked in EUR… but outside the spendable pool.
        XCTAssertEqual(result.dailyBalances.last!.trackedLiquidityEUR, euro("200.00")) // −300 pool + 500 pocket
        XCTAssertEqual(result.dailyBalances.last!.spendablePool, euro("-300.00"))
    }

    func testCashRailsAcceptCashWhenTheObligationsAllowsIt() {
        // The mirror case: an in-person cash-only obligation is payable with
        // euro pocket cash — and with nothing else.
        let result = try! ForecastEngine.run(request(
            accounts: [bnp, eurCash],
            balances: ["bnp": euro("500.00"), "cash-eur": euro("40.00")],
            obligation: PaymentRequirement(currency: .eur, acceptableRails: [.physicalCash]),
            amount: "40.00"
        ))
        XCTAssertNil(result.firstNegativeDate)
        XCTAssertEqual(result.dailyBalances.last!.endOfDay["cash-eur"], euro("0.00"))
        XCTAssertEqual(result.dailyBalances.last!.endOfDay["bnp"], euro("500.00"),
                       "the bank account was never drawn for a cash-only purchase")
        XCTAssertTrue(result.settlementFailures.isEmpty)
    }

    func testMixedRailsSatisfyFromSharedPool() {
        // An obligation accepting card OR electronic payment draws from any
        // account supporting either rail, in draw order.
        let wallet = Account(id: "wallet", name: "Wallet", currency: .eur, kind: .wallet, supportedRails: PaymentRail.euroWalletRails)
        let result = try! ForecastEngine.run(request(
            accounts: [wallet, bnp],
            balances: ["wallet": euro("100.00"), "bnp": euro("150.00")],
            obligation: PaymentRequirement.euroBankPayment(rails: [.cardDebit, .electronicPayment])
        ))
        XCTAssertEqual(result.dailyBalances.last!.endOfDay["wallet"], euro("0.00"))
        XCTAssertEqual(result.dailyBalances.last!.endOfDay["bnp"], euro("-50.00"))
        XCTAssertEqual(result.dailyBalances.last!.spendablePool, euro("-50.00"))
    }
}
