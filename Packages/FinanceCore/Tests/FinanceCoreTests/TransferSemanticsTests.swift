import XCTest
@testable import FinanceCore

/// Defect D1 — OWNED→OWNED movements are never economic spend and never
/// reduce what is safe to spend, while rail-specific liquidity (which account,
/// which rail) still moves honestly.
final class TransferSemanticsTests: XCTestCase {

    private let bnp = Account(id: "bnp", name: "Bank", currency: .eur, kind: .bank, supportedRails: PaymentRail.euroBankRails)
    /// A SEPA-only bank (the fixture's bank-main shape): cannot pay by card.
    private let sepaBank = Account(id: "bnp", name: "Bank", currency: .eur, kind: .bank, supportedRails: [.sepaCreditTransfer, .sepaDirectDebit])
    private let wallet = Account(id: "wallet", name: "Wallet", currency: .eur, kind: .wallet, supportedRails: PaymentRail.euroWalletRails)
    private let pocket = Account(id: "pocket", name: "Euro pocket", currency: .eur, kind: .cash, supportedRails: [.physicalCash])

    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    private func day(_ iso: String) -> Day {
        Day(isoString: iso)!
    }

    // MARK: - Economics layer

    func testTransferIsZeroSpendZeroIncomeButARealMovement() {
        let transfer = Transaction(
            id: "t1", date: day("2026-09-10"), kind: .transfer,
            legs: [
                AccountLeg(accountID: "bnp", amount: euro("-150.00")),
                AccountLeg(accountID: "wallet", amount: euro("150.00")),
            ],
            factivity: .observed
        )
        let effect = Economics.effect(of: transfer, currency: .eur)
        XCTAssertEqual(effect.spending, euro("0.00"))
        XCTAssertEqual(effect.income, euro("0.00"))
        XCTAssertEqual(effect.accountMovementOut, euro("150.00"))
        XCTAssertEqual(effect.accountMovementIn, euro("150.00"))
        XCTAssertTrue(effect.isRelocation)
        XCTAssertFalse(effect.isConsumption)
        XCTAssertEqual(effect.role, .accountMovement)

        let totals = Economics.totals(for: [transfer], currency: .eur)
        XCTAssertEqual(totals.economicSpending, euro("0.00"))
        XCTAssertEqual(totals.personalIncome, euro("0.00"))
        XCTAssertEqual(totals.internalTransfers, euro("150.00"), "the movement is visible as informational volume")
    }

    func testCashWithdrawalChangesFormNotEconomics() {
        let withdrawal = Transaction(
            id: "w1", date: day("2026-09-10"), kind: .cashWithdrawal,
            legs: [
                AccountLeg(accountID: "bnp", amount: euro("-200.00")),
                AccountLeg(accountID: "pocket", amount: euro("200.00")),
            ],
            factivity: .observed
        )
        let totals = Economics.totals(for: [withdrawal], currency: .eur)
        XCTAssertEqual(totals.economicSpending, euro("0.00"))
        XCTAssertEqual(totals.personalIncome, euro("0.00"))
        XCTAssertEqual(Economics.accountDelta(accountID: "pocket", in: [withdrawal])[.eur], euro("200.00"))
        XCTAssertEqual(Economics.accountDelta(accountID: "bnp", in: [withdrawal])[.eur], euro("-200.00"))
    }

    // MARK: - Engine layer: relocation preserves the pool but moves rails

    func testRelocationMovesRailLiquidityWithoutTouchingThePool() throws {
        // €150 sits in a SEPA-only bank (cannot pay by card). A card payment
        // of €60 is due tomorrow. Moving the money to the wallet today lets
        // the card payment settle — the total pool never moved.
        let result = try ForecastEngine.run(
            ForecastRequest(
                startDate: day("2026-09-01"),
                endDate: day("2026-09-03"),
                accounts: [sepaBank, wallet],
                startingBalances: ["bnp": euro("150.00"), "wallet": euro("0.00")],
                events: [
                    ForecastEvent(
                        id: "move-out", day: day("2026-09-01"), phase: .relocation, priority: 0,
                        effect: .directedDebit(euro("150.00"), fromAccount: "bnp"),
                        outflowSemantics: .relocation
                    ),
                    ForecastEvent(
                        id: "move-in", day: day("2026-09-01"), phase: .relocation, priority: 1,
                        effect: .credit(euro("150.00"), toAccount: "wallet")
                    ),
                    ForecastEvent(
                        id: "card-payment", day: day("2026-09-02"), phase: .scheduledDebit,
                        effect: .debit(euro("60.00"), requirement: PaymentRequirement.euroBankPayment(rails: [.cardDebit]))
                    ),
                ],
                scenario: .base
            )
        )

        XCTAssertTrue(result.settlementFailures.isEmpty,
                      "without the relocation the wallet rail could not pay the card; with it, the payment settles")
        XCTAssertEqual(result.projectedEndBalance, euro("90.00"), "the pool is unchanged by the relocation itself")
        XCTAssertEqual(result.dailyBalances[0].endOfDay["bnp"], euro("0.00"))
        XCTAssertEqual(result.dailyBalances[0].endOfDay["wallet"], euro("150.00"))
        XCTAssertEqual(result.dailyBalances[1].endOfDay["wallet"], euro("90.00"))
        XCTAssertNil(result.firstNegativeDate)
    }

    func testRailMismatchWithoutRelocationIsASettlementFailure() throws {
        // The mirror case: €150 in the SEPA-only bank, a card debit, no
        // transfer. The bank's money is real, positive and in the pool — but
        // it cannot ride the card rail, so the payment fails.
        let result = try ForecastEngine.run(
            ForecastRequest(
                startDate: day("2026-09-01"),
                endDate: day("2026-09-02"),
                accounts: [sepaBank, wallet],
                startingBalances: ["bnp": euro("150.00"), "wallet": euro("0.00")],
                events: [
                    ForecastEvent(
                        id: "card-payment", day: day("2026-09-02"), phase: .scheduledDebit,
                        effect: .debit(euro("60.00"), requirement: PaymentRequirement.euroBankPayment(rails: [.cardDebit]))
                    ),
                ],
                scenario: .base
            )
        )
        XCTAssertEqual(result.settlementFailures.count, 1)
        XCTAssertEqual(result.settlementFailures.first?.eligibleAccountIDs, ["wallet"],
                       "the bank is not eligible for a card debit — only the wallet was consulted")
        XCTAssertEqual(result.settlementFailures.first?.unsettled, euro("60.00"))
    }

    // MARK: - Snapshot layer: commitments vs rail movements

    func testDisposalAndRelocationNeverCountAsCommittedOutflows() throws {
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "hand-built",
            accounts: [bnp, wallet, pocket],
            balances: [
                AccountBalance(accountID: "bnp", balance: euro("800.00"), asOf: day("2026-09-01")),
                AccountBalance(accountID: "wallet", balance: euro("20.00"), asOf: day("2026-09-01")),
                AccountBalance(accountID: "pocket", balance: euro("0.00"), asOf: day("2026-09-01")),
            ]
        )
        let result = try ForecastEngine.run(
            ForecastRequest(
                startDate: day("2026-09-01"),
                endDate: day("2026-09-03"),
                accounts: document.accounts,
                startingBalances: Dictionary(document.balances.map { ($0.accountID, $0.balance) }, uniquingKeysWith: { a, _ in a }),
                events: [
                    ForecastEvent(
                        id: "rent", day: day("2026-09-02"), phase: .scheduledDebit,
                        effect: .debit(euro("480.00"), requirement: PaymentRequirement.euroBankPayment(rails: [.sepaDirectDebit])),
                        sourceRef: "ob-rent"
                    ),
                    ForecastEvent(
                        id: "deposit-out", day: day("2026-09-03"), phase: .relocation, priority: 0,
                        effect: .directedDebit(euro("1000.00"), fromAccount: "pocket"),
                        outflowSemantics: .relocation
                    ),
                    ForecastEvent(
                        id: "deposit-in", day: day("2026-09-03"), phase: .relocation, priority: 1,
                        effect: .credit(euro("1000.00"), toAccount: "bnp")
                    ),
                    ForecastEvent(
                        id: "co-resident-share", day: day("2026-09-03"), phase: .dependentDisposal,
                        effect: .directedDebit(euro("800.00"), fromAccount: "bnp"),
                        outflowSemantics: .disposal
                    ),
                ],
                scenario: .base
            )
        )
        let snapshot = FinanceOverview.snapshot(document: document, result: result, today: day("2026-09-01"), horizonDays: 30)

        // Only the rent is a commitment. The €1,000 deposit (both legs) and
        // the €600 handover disposal are rail movements — huge account balances
        // moving, zero effect on what is safe to spend.
        XCTAssertEqual(snapshot.committedOutflowsNext, euro("480.00"))
        XCTAssertEqual(snapshot.railRelocations.map(\.id), ["deposit-out", "deposit-in", "co-resident-share"])

        // Safe-to-spend subtracts the commitment only: 820 − 480.00.
        XCTAssertEqual(snapshot.safeToSpend.rawHeadroom, euro("340.00"))
        XCTAssertEqual(snapshot.safeToSpend.amount, euro("340.00"))
        XCTAssertFalse(snapshot.safeToSpend.isDeficit)
    }
}
