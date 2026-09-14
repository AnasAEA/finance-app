import XCTest
@testable import FinanceCore

/// Defect D4 — PAYMENT_SETTLEMENT_FAILURE (this payment could not settle from
/// eligible accounts) is a different fact from POOL_DEFICIT (the aggregate
/// spendable pool is below zero / the floor). Each must be reportable without
/// the other.
final class SettlementVsPoolDeficitTests: XCTestCase {

    private let bnp = Account(id: "bnp", name: "Bank", currency: .eur, kind: .bank, supportedRails: PaymentRail.euroBankRails)
    private let wallet = Account(id: "wallet", name: "Wallet", currency: .eur, kind: .wallet, supportedRails: PaymentRail.euroWalletRails)

    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    private func day(_ iso: String) -> Day {
        Day(isoString: iso)!
    }

    private func run(_ events: [ForecastEvent], balances: [String: Money]) throws -> ForecastResult {
        try ForecastEngine.run(
            ForecastRequest(
                startDate: day("2026-09-01"),
                endDate: day("2026-09-05"),
                accounts: [bnp, wallet],
                startingBalances: balances,
                events: events,
                scenario: .base
            )
        )
    }

    func testSettledPaymentInsideANegativePoolIsNotAFailure() throws {
        // Day 1: a €300 SEPA debit with only €20 on the wallet and €0 in the
        // bank → settlement failure; the bank absorbs −300.
        // Day 2: a €6.13 card debit — the wallet still holds €20 of *eligible,
        // positive* money, so it settles in full even though the pool is −280.
        let result = try run(
            [
                ForecastEvent(
                    id: "big-sepa", day: day("2026-09-01"), phase: .scheduledDebit,
                    effect: .debit(euro("300.00"), requirement: PaymentRequirement.euroBankPayment(rails: [.sepaDirectDebit]))
                ),
                ForecastEvent(
                    id: "small-card", day: day("2026-09-02"), phase: .scheduledDebit,
                    effect: .debit(euro("6.13"), requirement: PaymentRequirement.euroBankPayment(rails: [.cardDebit]))
                ),
            ],
            balances: ["bnp": euro("0.00"), "wallet": euro("20.00")]
        )

        // The settlement fact: exactly one payment failed, and it is not the
        // €6.13 — a successful card payment is never labelled bounced because
        // the aggregate pool is negative.
        XCTAssertEqual(result.settlementFailures.count, 1)
        XCTAssertEqual(result.settlementFailures.first?.eventID, "big-sepa")
        XCTAssertFalse(result.settlementFailures.contains { $0.eventID == "small-card" })

        // The pool-deficit facts coexist independently. Day 1 pool after the
        // SEPA failure: bank −300 + wallet 20 = −280; day 2 after the settled
        // card debit: −286.13 (the true minimum).
        XCTAssertEqual(result.firstNegativeDate, day("2026-09-01"))
        XCTAssertEqual(result.lowestBalance, euro("-286.13"))
        XCTAssertEqual(result.firstRisk?.kind, .poolDeficit)
        XCTAssertEqual(result.firstRisk?.triggerEventID, "big-sepa")

        // And the card payment really moved eligible money.
        XCTAssertEqual(result.dailyBalances[1].endOfDay["wallet"], euro("13.87"))
    }

    func testUnsettledPaymentWhileThePoolStaysPositive() throws {
        // The mirror proof: a €20 SEPA debit consults only the bank (€5
        // there), settles €5 and leaves €15 unsettled — while the aggregate
        // pool never goes negative, because the wallet's €20 (wrong rail, but
        // real, positive, in-pool money) outweighs the bank's −15. A pool
        // read-out alone would have said "fine"; the settlement fact says a
        // €15 payment bounced.
        let result = try run(
            [
                ForecastEvent(
                    id: "sepa", day: day("2026-09-01"), phase: .scheduledDebit,
                    effect: .debit(euro("20.00"), requirement: PaymentRequirement.euroBankPayment(rails: [.sepaDirectDebit]))
                ),
            ],
            balances: ["bnp": euro("5.00"), "wallet": euro("20.00")]
        )

        XCTAssertEqual(result.settlementFailures.count, 1)
        XCTAssertEqual(result.settlementFailures.first?.eventID, "sepa")
        XCTAssertEqual(result.settlementFailures.first?.requested, euro("20.00"))
        XCTAssertEqual(result.settlementFailures.first?.settled, euro("5.00"))
        XCTAssertEqual(result.settlementFailures.first?.unsettled, euro("15.00"))
        XCTAssertEqual(result.settlementFailures.first?.eligibleAccountIDs, ["bnp"])

        XCTAssertNil(result.firstNegativeDate, "the pool stayed positive: −15 bank + 20 wallet")
        XCTAssertEqual(result.projectedEndBalance, euro("5.00"))
        XCTAssertEqual(result.lowestBalance, euro("5.00"))
        XCTAssertEqual(result.dailyBalances[0].endOfDay["bnp"], euro("-15.00"),
                       "the unsettled remainder is applied to the bank, never silently dropped")
        XCTAssertEqual(result.dailyBalances[0].endOfDay["wallet"], euro("20.00"), "untouched: wrong rail")
    }

    func testPartialSettlementReportsRequestedSettledUnsettled() throws {
        // €5 in the bank, €7 on the wallet, a €20 SEPA debit: the bank pays
        // its €5, the rest is unsettled. The wallet is ineligible for SEPA.
        let result = try run(
            [
                ForecastEvent(
                    id: "sepa", day: day("2026-09-01"), phase: .scheduledDebit,
                    effect: .debit(euro("20.00"), requirement: PaymentRequirement.euroBankPayment(rails: [.sepaDirectDebit]))
                ),
            ],
            balances: ["bnp": euro("5.00"), "wallet": euro("7.00")]
        )

        let failure = try XCTUnwrap(result.settlementFailures.first)
        XCTAssertEqual(failure.requested, euro("20.00"))
        XCTAssertEqual(failure.settled, euro("5.00"), "negative-eligible accounts contribute; ineligible-but-positive ones never do")
        XCTAssertEqual(failure.unsettled, euro("15.00"))
        XCTAssertEqual(failure.eligibleAccountIDs, ["bnp"])
        XCTAssertEqual(failure.day, day("2026-09-01"))
        XCTAssertEqual(failure.requirement.acceptableRails, [.sepaDirectDebit])

        XCTAssertEqual(result.dailyBalances[0].endOfDay["bnp"], euro("-15.00"))
        XCTAssertEqual(result.dailyBalances[0].endOfDay["wallet"], euro("7.00"), "untouched: wrong rail")
    }

    func testUnfundedByMonthSummarizesFailures() throws {
        let result = try run(
            [
                ForecastEvent(
                    id: "a", day: day("2026-09-01"), phase: .scheduledDebit,
                    effect: .debit(euro("10.00"), requirement: PaymentRequirement.euroBankPayment(rails: [.sepaDirectDebit]))
                ),
                ForecastEvent(
                    id: "b", day: day("2026-09-03"), phase: .scheduledDebit,
                    effect: .debit(euro("5.00"), requirement: PaymentRequirement.euroBankPayment(rails: [.sepaDirectDebit]))
                ),
            ],
            balances: ["bnp": euro("0.00"), "wallet": euro("0.00")]
        )
        XCTAssertEqual(result.unfundedByMonth[MonthKey(year: 2026, month: 9)], MoneyBag(euro("15.00")))
        XCTAssertEqual(result.unfunded(in: .eur, month: MonthKey(year: 2026, month: 9)), euro("15.00"))
        XCTAssertEqual(result.unfundedEURByMonth[MonthKey(year: 2026, month: 9)], euro("15.00"))
    }
}
