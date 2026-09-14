import XCTest
@testable import FinanceCore

/// Lifecycle and economics — the per-transaction `EconomicEffect`
/// read-out and the transaction lifecycle (pending/cleared/reconciled/reversed
/// with booked-date and date-precision context).
final class LifecycleAndEconomicsTests: XCTestCase {

    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    private func day(_ iso: String) -> Day {
        Day(isoString: iso)!
    }

    // MARK: - Role per kind (the per-row read-out the UI consumes)

    func testExpenseIsSpending() {
        let t = Transaction(
            id: "e", date: day("2026-09-13"), kind: .expense,
            legs: [AccountLeg(accountID: "wallet", amount: euro("-6.13"))],
            factivity: .observed
        )
        let effect = Economics.effect(of: t, currency: .eur)
        XCTAssertEqual(effect.role, .spending)
        XCTAssertEqual(effect.spending, euro("6.13"))
        XCTAssertTrue(effect.isConsumption)
        XCTAssertEqual(effect.netPersonalFlow, euro("-6.13"))
    }

    func testIncomeIsIncome() {
        let t = Transaction(
            id: "i", date: day("2026-11-05"), kind: .income,
            legs: [AccountLeg(accountID: "bnp", amount: euro("292.50"))],
            factivity: .expected
        )
        let effect = Economics.effect(of: t, currency: .eur)
        XCTAssertEqual(effect.role, .income)
        XCTAssertEqual(effect.income, euro("292.50"))
        XCTAssertEqual(effect.netPersonalFlow, euro("292.50"))
    }

    func testRefundOffsetsSpendingAndIsNeverIncome() {
        let expense = Transaction(
            id: "x", date: day("2026-09-01"), kind: .expense,
            legs: [AccountLeg(accountID: "wallet", amount: euro("-40.00"))],
            factivity: .observed
        )
        let refund = Transaction(
            id: "r", date: day("2026-09-05"), kind: .refund,
            legs: [AccountLeg(accountID: "wallet", amount: euro("40.00"))],
            linkedTransactionID: "x",
            factivity: .observed
        )
        let totals = Economics.totals(for: [expense, refund], currency: .eur)
        XCTAssertEqual(totals.economicSpending, euro("40.00"))
        XCTAssertEqual(totals.refunds, euro("40.00"))
        XCTAssertEqual(totals.netEconomicSpending, euro("0.00"))
        XCTAssertEqual(totals.personalIncome, euro("0.00"), "a refund is never income")
        XCTAssertEqual(Economics.effect(of: refund, currency: .eur).role, .refund)
    }

    func testFinancingRepaymentIsLiquidityNotSpending() {
        let t = Transaction(
            id: "f", date: day("2026-09-08"), kind: .financingRepayment,
            legs: [AccountLeg(accountID: "wallet", amount: euro("-24.00"))],
            factivity: .observed
        )
        let effect = Economics.effect(of: t, currency: .eur)
        XCTAssertEqual(effect.role, .financingRepayment)
        XCTAssertEqual(effect.financingRepayment, euro("24.00"))
        XCTAssertEqual(effect.spending, euro("0.00"), "the purchase was already booked at purchase time")
    }

    func testPassThroughArrivalCountsOnlyTheOwnedShare() {
        let t = Transaction(
            id: "p", date: day("2026-09-16"), kind: .passThrough,
            legs: [AccountLeg(accountID: "pocket", amount: euro("1600.00"))],
            ownership: [
                OwnershipSplit(ownerID: "holder", isSelf: true, amount: euro("800.00")),
                OwnershipSplit(ownerID: "co-resident", isSelf: false, amount: euro("800.00")),
            ],
            factivity: .expected
        )
        let effect = Economics.effect(of: t, currency: .eur)
        XCTAssertEqual(effect.income, euro("800.00"))
        XCTAssertEqual(effect.passThroughNotMine, euro("800.00"))
        XCTAssertEqual(effect.role, .income, "the arrival's role for me is income — exactly the owned share")
    }

    func testPassThroughDisposalIsAMovementOfSomeoneElsesMoney() {
        let t = Transaction(
            id: "d", date: day("2026-09-16"), kind: .passThrough,
            legs: [AccountLeg(accountID: "bnp", amount: euro("-800.00"))],
            linkedTransactionID: "p",
            factivity: .expected
        )
        let effect = Economics.effect(of: t, currency: .eur)
        XCTAssertEqual(effect.role, .accountMovement)
        XCTAssertTrue(effect.isRelocation)
        XCTAssertEqual(effect.spending, euro("0.00"))
        XCTAssertEqual(effect.income, euro("0.00"))
        XCTAssertEqual(effect.accountMovementOut, euro("800.00"))
    }

    // MARK: - Lifecycle (port B)

    func testReversedDebitIsZeroEconomicsDirectlyNoFakeIncome() {
        // August 2026: the direct debit was pulled back after it hit the
        // account. The reversal lives on the transaction itself — there is no
        // synthetic income entry and no obligation deleted.
        let reversed = Transaction(
            id: "tx-rent-reversed", date: day("2026-08-11"), kind: .expense,
            legs: [AccountLeg(accountID: "bnp", amount: euro("-480.00"))],
            factivity: .observed,
            lifecycle: .reversed,
            note: "direct debit reversed by the creditor; the debt moved to arrears"
        )
        let effect = Economics.effect(of: reversed, currency: .eur)
        XCTAssertEqual(effect.role, .none)
        XCTAssertEqual(effect.spending, euro("0.00"), "a reversed debit never economically happened")
        XCTAssertEqual(effect.accountMovementOut, euro("480.00"), "the movement fact is still carried")
        XCTAssertEqual(Economics.totals(for: [reversed], currency: .eur).economicSpending, euro("0.00"))
    }

    func testPendingAndReconciledStillCountOnlyReversedZeroes() {
        // `pending` (a card hold) and `reconciled` (statement-confirmed) are
        // settlement states of something that DID happen economically — only
        // `reversed` voids the economics.
        let pending = Transaction(
            id: "hold", date: day("2026-09-13"), kind: .expense,
            legs: [AccountLeg(accountID: "wallet", amount: euro("-6.13"))],
            factivity: .observed, lifecycle: .pending
        )
        let reconciled = Transaction(
            id: "done", date: day("2026-09-13"), kind: .expense,
            legs: [AccountLeg(accountID: "wallet", amount: euro("-6.13"))],
            factivity: .observed, lifecycle: .reconciled
        )
        XCTAssertEqual(Economics.effect(of: pending, currency: .eur).spending, euro("6.13"))
        XCTAssertEqual(Economics.effect(of: reconciled, currency: .eur).spending, euro("6.13"))
        XCTAssertEqual(Economics.effect(of: pending, currency: .eur).lifecycle, .pending)
    }

    func testLifecycleDefaultsFollowFactivity() {
        let observed = Transaction(
            id: "o", date: day("2026-09-01"), kind: .expense,
            legs: [AccountLeg(accountID: "bnp", amount: euro("-1.00"))],
            factivity: .observed
        )
        let expected = Transaction(
            id: "x", date: day("2026-09-01"), kind: .income,
            legs: [AccountLeg(accountID: "bnp", amount: euro("1.00"))],
            factivity: .expected
        )
        XCTAssertEqual(observed.lifecycle, .cleared)
        XCTAssertEqual(expected.lifecycle, .pending, "an expectation has not settled yet")
        XCTAssertEqual(observed.certainty, .received, "a fact is a fact — observed transactions carry received")
    }

    // MARK: - Booking date and date precision

    func testBookedDateAndPrecisionRoundTrip() throws {
        let transaction = Transaction(
            id: "bd", date: day("2026-08-31"), kind: .expense,
            legs: [AccountLeg(accountID: "bnp", amount: euro("-15.00"))],
            factivity: .observed,
            bookedDate: day("2026-09-01"),
            datePrecision: .estimated
        )
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Transaction.self, from: try JSONEncoder().encode(transaction))
        XCTAssertEqual(decoded.bookedDate, day("2026-09-01"), "value date vs posting date survives the round-trip")
        XCTAssertEqual(decoded.datePrecision, .estimated)
        XCTAssertEqual(decoded.date, day("2026-08-31"))
    }

    func testPre110DocumentDecodesWithSensibleDefaults() throws {
        // A 1.0.0 document has no lifecycle / bookedDate / datePrecision /
        // incomeSourceID fields — decoding must succeed with defaults.
        let json = """
        {
          "id" : "legacy",
          "date" : "2026-08-11",
          "kind" : "expense",
          "legs" : [ { "accountID" : "bnp", "amount" : "-480.00 EUR" } ],
          "factivity" : "observed",
          "provenance" : { "source" : "BNP-STATEMENT", "evidenceGrade" : "primarySource" }
        }
        """
        let legacy = try legacyMoneyDecoder().decode(Transaction.self, from: Data(json.utf8))
        XCTAssertEqual(legacy.lifecycle, .cleared)
        XCTAssertEqual(legacy.datePrecision, .exact)
        XCTAssertNil(legacy.bookedDate)
        XCTAssertNil(legacy.incomeSourceID)
        XCTAssertEqual(legacy.certainty, .received)
    }
}
