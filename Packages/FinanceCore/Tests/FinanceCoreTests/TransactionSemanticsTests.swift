import XCTest
@testable import FinanceCore

/// The mandated domain examples A–D and proofs #1–#6:
/// movement ≠ spending, pass-through ownership, financing, refunds.
final class TransactionSemanticsTests: XCTestCase {

    private let eur = Currency.eur

    // MARK: - Proof 1: transfer between owned accounts is not spending

    func testTransferBetweenOwnedAccountsCreatesNoSpending() {
        let transfer = Transaction(
            id: "t1",
            date: Day(isoString: "2026-09-02")!,
            kind: .transfer,
            legs: [
                AccountLeg(accountID: "bnp", amount: Money(exactDecimal: "-100.00", currency: .eur)!),
                AccountLeg(accountID: "revolut", amount: Money(exactDecimal: "100.00", currency: .eur)!),
            ],
            factivity: .observed
        )
        let totals = Economics.totals(for: [transfer], currency: eur)
        XCTAssertEqual(totals.economicSpending, Money(exactDecimal: "0.00", currency: .eur)!)
        XCTAssertEqual(totals.personalIncome, Money(exactDecimal: "0.00", currency: .eur)!)
        XCTAssertEqual(totals.internalTransfers, Money(exactDecimal: "100.00", currency: .eur)!)
        // The account movement is real, even though the economics are nil.
        XCTAssertEqual(Economics.accountDelta(accountID: "bnp", in: [transfer])[eur],
                       Money(exactDecimal: "-100.00", currency: .eur)!)
        XCTAssertEqual(Economics.accountDelta(accountID: "revolut", in: [transfer])[eur],
                       Money(exactDecimal: "100.00", currency: .eur)!)
    }

    // MARK: - Example A / Proof 2: ATM withdrawal is not spending, no fee invented

    func testATMWithdrawalChangesAssetFormWithoutSpending() {
        let atm = Transaction(
            id: "atm",
            date: Day(isoString: "2026-08-23")!,
            kind: .cashWithdrawal,
            legs: [
                AccountLeg(accountID: "revolut", amount: Money(exactDecimal: "-30.00", currency: .eur)!),
                AccountLeg(accountID: "cash-mad", amount: Money(exactDecimal: "200.00", currency: .mad)!),
            ],
            factivity: .observed
        )
        let totals = Economics.totals(for: [atm], currency: eur)
        XCTAssertEqual(totals.economicSpending, Money(minorUnits: 0, currency: eur),
                       "an ATM withdrawal must not be economic spending")
        XCTAssertEqual(totals.personalIncome, Money(minorUnits: 0, currency: eur))
        // The movement itself is visible as a raw outflow — movement ≠ spending.
        XCTAssertEqual(totals.grossOutflow, Money(exactDecimal: "30.00", currency: .eur)!)
        // No fee leg exists; none may be invented by any layer.
        XCTAssertEqual(atm.legs.count, 2)
        XCTAssertEqual(Economics.accountDelta(accountID: "cash-mad", in: [atm])[.mad],
                       Money(exactDecimal: "200.00", currency: .mad)!)
    }

    // MARK: - Example C / Proof 3: financing repayment is not new spending

    func testFinancingRepaymentIsNotNewEconomicSpending() {
        let purchase = Transaction(
            id: "phone-purchase",
            date: Day(isoString: "2026-06-23")!,
            kind: .expense,
            legs: [AccountLeg(accountID: "paypal", amount: Money(exactDecimal: "-324.89", currency: .eur)!)],
            installmentPlanID: "ob-paypal-phone",
            factivity: .observed
        )
        let repayments = (1...4).map { index in
            Transaction(
                id: "repay-\(index)",
                date: Day(year: 2026, month: 6 + index, day: 23),
                kind: .financingRepayment,
                legs: [AccountLeg(accountID: "bnp", amount: Money(exactDecimal: "-81.22", currency: .eur)!)],
                linkedTransactionID: "phone-purchase",
                installmentPlanID: "ob-paypal-phone",
                factivity: .observed
            )
        }
        let totals = Economics.totals(for: [purchase] + repayments, currency: eur)
        XCTAssertEqual(totals.economicSpending, Money(exactDecimal: "324.89", currency: .eur)!,
                       "the phone is booked exactly once, at purchase")
        XCTAssertEqual(totals.financingRepayments, Money(exactDecimal: "324.88", currency: .eur)!,
                       "the repayments are visible as liquidity events")
        XCTAssertNotEqual(totals.economicSpending, Money(exactDecimal: "649.77", currency: .eur)!)
    }

    // MARK: - Example D / Proof 4: refund is not ordinary income

    func testRefundIsNotOrdinaryIncome() {
        let purchase = Transaction(
            id: "buy",
            date: Day(isoString: "2026-07-01")!,
            kind: .expense,
            legs: [AccountLeg(accountID: "revolut", amount: Money(exactDecimal: "-21.99", currency: .eur)!)],
            factivity: .observed
        )
        let refund = Transaction(
            id: "refund",
            date: Day(isoString: "2026-07-05")!,
            kind: .refund,
            legs: [AccountLeg(accountID: "revolut", amount: Money(exactDecimal: "21.99", currency: .eur)!)],
            linkedTransactionID: "buy",
            factivity: .observed
        )
        let totals = Economics.totals(for: [purchase, refund], currency: eur)
        XCTAssertEqual(totals.personalIncome, Money(minorUnits: 0, currency: eur),
                       "a refund is never income")
        XCTAssertEqual(totals.refunds, Money(exactDecimal: "21.99", currency: .eur)!)
        XCTAssertEqual(totals.netEconomicSpending, Money(minorUnits: 0, currency: eur),
                       "the refunded purchase nets to zero consumption")
    }

    // MARK: - Example B / Proofs 5 & 6: pass-through ownership

    private func familyPassThrough() -> [Transaction] {
        let deposit = Transaction(
            id: "parents-gross",
            date: Day(isoString: "2026-09-16")!,
            kind: .passThrough,
            legs: [AccountLeg(accountID: "bnp", amount: Money(exactDecimal: "1600.00", currency: .eur)!)],
            ownership: [
                OwnershipSplit(ownerID: "holder", isSelf: true, amount: Money(exactDecimal: "800.00", currency: .eur)!),
                OwnershipSplit(ownerID: "co-resident", isSelf: false, amount: Money(exactDecimal: "800.00", currency: .eur)!),
            ],
            factivity: .observed
        )
        let sisterRemittance = Transaction(
            id: "co-resident-out",
            date: Day(isoString: "2026-09-16")!,
            kind: .passThrough,
            legs: [AccountLeg(accountID: "bnp", amount: Money(exactDecimal: "-800.00", currency: .eur)!)],
            linkedTransactionID: "parents-gross",
            factivity: .observed
        )
        return [deposit, sisterRemittance]
    }

    func testPassThroughOwnShareOnlyIsPersonalIncome() {
        let totals = Economics.totals(for: familyPassThrough(), currency: eur)
        XCTAssertEqual(totals.personalIncome, Money(exactDecimal: "800.00", currency: .eur)!,
                       "my parental-support income is exactly my share")
        XCTAssertEqual(totals.passThroughNotMine, Money(exactDecimal: "800.00", currency: .eur)!)
        XCTAssertEqual(totals.economicSpending, Money(minorUnits: 0, currency: eur),
                       "forwarding the co-resident's share is not spending")
    }

    func testDepositPlusRemittanceYieldsOnly800EconomicSupport() {
        let transactions = familyPassThrough()
        // The bank balance moved +1600 then −800…
        XCTAssertEqual(totalsGrossInflow(transactions), Money(exactDecimal: "1600.00", currency: .eur)!)
        XCTAssertEqual(Economics.accountDelta(accountID: "bnp", in: transactions)[eur],
                       Money(exactDecimal: "800.00", currency: .eur)!)
        // …but the economic support is 800, and the temporary 1600 balance
        // never counted as personal income (asserted by the test above).
        let totals = Economics.totals(for: transactions, currency: eur)
        XCTAssertEqual(totals.personalNetFlow, Money(exactDecimal: "800.00", currency: .eur)!)
    }

    func testPassThroughWithoutSplitsIsConservativelyNotMine() {
        // No split is ever invented: without ownership, zero personal income.
        let unattributed = Transaction(
            id: "mystery",
            date: Day(isoString: "2026-09-16")!,
            kind: .passThrough,
            legs: [AccountLeg(accountID: "bnp", amount: Money(exactDecimal: "500.00", currency: .eur)!)],
            factivity: .observed
        )
        let totals = Economics.totals(for: [unattributed], currency: eur)
        XCTAssertEqual(totals.personalIncome, Money(minorUnits: 0, currency: eur))
        XCTAssertEqual(totals.passThroughNotMine, Money(exactDecimal: "500.00", currency: .eur)!)
    }

    func testFullyOwnedPassThroughCountsEntirely() {
        // The August arrival routed through the co-resident was economically 100%
        // the holder's — explicit ownership states it.
        let arrival = Transaction(
            id: "aug",
            date: Day(isoString: "2026-08-18")!,
            kind: .passThrough,
            legs: [AccountLeg(accountID: "bnp", amount: Money(exactDecimal: "900.00", currency: .eur)!)],
            ownership: [OwnershipSplit(ownerID: "holder", isSelf: true, amount: Money(exactDecimal: "900.00", currency: .eur)!)],
            factivity: .observed
        )
        XCTAssertEqual(Economics.totals(for: [arrival], currency: eur).personalIncome,
                       Money(exactDecimal: "900.00", currency: .eur)!)
    }

    private func totalsGrossInflow(_ transactions: [Transaction]) -> Money {
        Economics.totals(for: transactions, currency: eur).grossInflow
    }
}
