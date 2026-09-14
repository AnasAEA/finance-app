import XCTest
@testable import FinanceCore

/// A budget envelope **contains** the commitments linked to it.
///
/// `MonthlyBudgetEngine` has always said so: a €480.00 housing line with a
/// €480.00 rent obligation linked to it has `committed == 480.00` and
/// `remainingAfterCommitted == 0`. The forecast used to disagree — it charged
/// the scheduled rent *and* spread the full envelope on top, so the same euros
/// left the pool twice.
///
/// These tests pin the one shared reading: what a line still has to spend is
/// its envelope minus what is already promised to it, clamped at zero.
///
/// Every fixture is synthetic. The shapes are real; the amounts, names and
/// accounts are invented and belong to nobody.
final class BudgetEnvelopeCommitmentTests: XCTestCase {

    // MARK: - Fixture vocabulary

    private func euro(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .eur)! }
    private func dirham(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .mad)! }
    private func day(_ iso: String) -> Day { Day(isoString: iso)! }
    private let september = MonthKey(year: 2026, month: 9)
    private let october = MonthKey(year: 2026, month: 10)

    private let bank = Account(
        id: "bank", name: "Bank", currency: .eur, kind: .bank,
        supportedRails: [.cardDebit, .electronicPayment, .sepaCreditTransfer, .sepaDirectDebit],
        drawOrder: 0
    )

    private func budget(
        _ id: String, _ amount: String,
        from: MonthKey? = nil,
        overrides: [MonthKey: Money] = [:],
        categoryKeys: [String] = []
    ) -> BudgetAllocation {
        BudgetAllocation(
            id: id, name: id, spendingClass: .flexible,
            monthlyAmount: euro(amount),
            effectiveFrom: from ?? MonthKey(year: 2026, month: 1),
            monthlyOverrides: overrides,
            confirmation: .userConfirmed,
            categoryKeys: categoryKeys
        )
    }

    private func obligation(
        _ id: String, _ amount: Money, onDay: Int, budgetID: String?,
        rails: Set<PaymentRail> = [.sepaDirectDebit]
    ) -> RecurringObligation {
        RecurringObligation(
            id: id, name: id, amount: amount.magnitude,
            spec: .monthly(onDay: onDay, from: MonthKey(year: 2026, month: 1), through: nil),
            requirement: PaymentRequirement(currency: amount.currency, acceptableRails: rails),
            spendingClass: .essential, budgetID: budgetID
        )
    }

    private func document(
        opening: String = "5000.00",
        budgets: [BudgetAllocation] = [],
        obligations: [RecurringObligation] = [],
        settlements: [ObligationSettlement] = [],
        transactions: [Transaction] = [],
        installments: [InstallmentPlan] = [],
        accounts: [Account]? = nil,
        balances: [AccountBalance]? = nil,
        ceiling: Money? = nil
    ) -> FinanceDocument {
        FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: accounts ?? [bank],
            balances: balances ?? [
                AccountBalance(accountID: "bank", balance: euro(opening), asOf: day("2026-09-01"))
            ],
            transactions: transactions,
            installments: installments,
            planning: FinanceDocument.Planning(
                monthlyEconomicCeiling: ceiling,
                budgets: budgets,
                recurringObligations: obligations,
                settlements: settlements
            )
        )
    }

    /// Runs the real composer + engine over `[from, to]`.
    private func run(
        _ document: FinanceDocument,
        from: String = "2026-09-01",
        to: String = "2026-09-30"
    ) throws -> ForecastResult {
        let request = ForecastComposer.makeRequest(
            from: document, startDate: day(from), endDate: day(to), scenario: .base
        )
        return try ForecastEngine.run(request)
    }

    /// What the run actually charged as everyday/variable spending, per line.
    private func variableSpending(
        _ result: ForecastResult, line: String, month: MonthKey, currency: Currency = .eur
    ) -> Money {
        var total: Int64 = 0
        for event in result.appliedEvents
        where event.phase == .variableSpending
            && event.sourceRef == line
            && event.day.monthKey == month {
            guard case let .debit(amount, _) = event.effect, amount.currency == currency else { continue }
            total += amount.magnitude.minorUnits
        }
        return Money(minorUnits: total, currency: currency)
    }

    /// Every euro that actually left the spendable pool in `month`.
    ///
    /// Deliberately measured from the balance chain rather than by adding up
    /// the amounts written on the events: an event that was composed but moved
    /// no money must not be able to pass for a charge.
    private func totalDebits(_ result: ForecastResult, month: MonthKey) -> Money {
        guard let ledger = result.monthLedgers[month] else { return euro("0.00") }
        return ledger.opening - ledger.closing
    }

    private func report(
        _ document: FinanceDocument, month: MonthKey? = nil,
        today: String = "2026-09-01", categoryKeys: [String: String] = [:]
    ) -> MonthlyBudgetReport {
        MonthlyBudgetEngine.report(
            month: month ?? september, today: day(today),
            document: document, categoryKeys: categoryKeys
        )
    }

    // MARK: - A. A linked obligation is inside its envelope, not beside it

    /// The defect in one test. A €480.00 housing envelope with the €480.00 rent
    /// linked to it is one demand on the pool, not two: the rent is charged on
    /// its own day and the envelope has nothing left to spread.
    func testALinkedObligationIsChargedOnceAndLeavesNothingToSpread() throws {
        let doc = document(
            budgets: [budget("housing", "480.00")],
            obligations: [obligation("ob-housing", euro("480.00"), onDay: 12, budgetID: "housing")]
        )
        let result = try run(doc)

        XCTAssertEqual(variableSpending(result, line: "housing", month: september), euro("0.00"),
                       "the envelope is fully committed, so there is no everyday spending left in it")
        XCTAssertEqual(totalDebits(result, month: september), euro("480.00"),
                       "one obligation, one charge — not 919.38")
        XCTAssertTrue(result.appliedEvents.contains { $0.sourceRef == "ob-housing" },
                      "netting must not swallow the scheduled debit itself")
        XCTAssertFalse(result.appliedEvents.contains { $0.phase == .variableSpending },
                       "a zero remainder emits no events at all")
    }

    // MARK: - B. A partly committed line keeps the difference

    func testAPartlyCommittedLineSpreadsOnlyTheDifference() throws {
        let doc = document(
            budgets: [budget("groceries", "70.00")],
            obligations: [obligation("ob-box", euro("20.00"), onDay: 10, budgetID: "groceries",
                                     rails: [.cardDebit])]
        )
        let result = try run(doc)

        XCTAssertEqual(variableSpending(result, line: "groceries", month: september), euro("50.00"),
                       "70 gross − 20 already promised = 50 of everyday spending")
        XCTAssertEqual(totalDebits(result, month: september), euro("70.00"),
                       "the month still costs the gross envelope, once")
        let days = Set(result.appliedEvents.filter { $0.phase == .variableSpending }.map(\.day))
        XCTAssertEqual(days.count, 30,
                       "the daily spread is unchanged; only the amount being spread is smaller")
    }

    /// A line may be committed past its own envelope. The remainder clamps at
    /// zero — an over-committed line never turns into a credit, and the
    /// obligation is still charged in full.
    func testAnOverCommittedLineClampsAtZeroAndStillPaysTheObligation() throws {
        let doc = document(
            budgets: [budget("groceries", "20.00")],
            obligations: [obligation("ob-box", euro("70.00"), onDay: 10, budgetID: "groceries",
                                     rails: [.cardDebit])]
        )
        let result = try run(doc)

        XCTAssertEqual(variableSpending(result, line: "groceries", month: september), euro("0.00"))
        XCTAssertEqual(totalDebits(result, month: september), euro("70.00"))
        XCTAssertEqual(report(doc).lines.first?.remainingAfterCommitted, euro("-50.00"),
                       "the budget report still reports the overrun as negative; the forecast clamps")
    }

    // MARK: - C. An unlinked obligation nets nothing

    /// No mapping is inferred from a name or a spending class. An obligation
    /// with no `budgetID` is an independent scheduled debit: it is charged in
    /// full and it reduces no envelope.
    func testAnUnlinkedObligationIsChargedInFullAndReducesNoEnvelope() throws {
        let doc = document(
            budgets: [budget("groceries", "70.00")],
            obligations: [obligation("ob-housing", euro("480.00"), onDay: 12, budgetID: nil)]
        )
        let result = try run(doc)

        XCTAssertEqual(variableSpending(result, line: "groceries", month: september), euro("70.00"),
                       "an unrelated envelope is untouched")
        XCTAssertEqual(totalDebits(result, month: september), euro("550.00"),
                       "480.00 scheduled + 70.00 everyday")
        let monthly = report(doc)
        XCTAssertEqual(monthly.committed, euro("480.00"), "it counts in the month total…")
        XCTAssertEqual(monthly.lines.first?.committed, euro("0.00"), "…and in no line")
    }

    // MARK: - D. The cross-module invariant

    /// **The principal regression test.** The forecast and the budget report
    /// must not be allowed to hold different opinions about how much a line
    /// still has to spend.
    ///
    /// Scope, stated rather than assumed: the equality is exact for a forecast
    /// that spans the whole month and a month with no elapsed spending. Once
    /// money has actually been spent, the two views legitimately differ — the
    /// report subtracts `spent`, while the forecast starts from a balance that
    /// already contains it and pro-rates the envelope over the days it covers.
    /// Both of those inputs are held at zero here so the invariant is a
    /// statement about attribution and nothing else.
    func testForecastVariableSpendingEqualsRemainingAfterCommittedForEveryLine() throws {
        let cases: [(String, FinanceDocument)] = [
            ("fully committed", document(
                budgets: [budget("housing", "480.00")],
                obligations: [obligation("ob-housing", euro("480.00"), onDay: 12, budgetID: "housing")])),
            ("partly committed", document(
                budgets: [budget("groceries", "70.00")],
                obligations: [obligation("ob-box", euro("20.00"), onDay: 10, budgetID: "groceries",
                                         rails: [.cardDebit])])),
            ("uncommitted", document(budgets: [budget("groceries", "70.00")])),
            ("unlinked obligation", document(
                budgets: [budget("groceries", "70.00")],
                obligations: [obligation("ob-housing", euro("480.00"), onDay: 12, budgetID: nil)])),
            ("several lines, one linked", document(
                budgets: [budget("housing", "480.00"), budget("groceries", "70.00")],
                obligations: [obligation("ob-housing", euro("480.00"), onDay: 12, budgetID: "housing")])),
            ("resolved obligation", document(
                budgets: [budget("housing", "480.00")],
                obligations: [obligation("ob-housing", euro("480.00"), onDay: 12, budgetID: "housing")],
                settlements: [ObligationSettlement(
                    id: "s1", obligationID: "ob-housing",
                    expectedDay: day("2026-09-12"), resolution: .noLongerDue)])),
        ]

        for (label, doc) in cases {
            let result = try run(doc)
            let monthly = report(doc)
            XCTAssertEqual(monthly.spent, euro("0.00"), "\(label): fixture precondition")

            for line in monthly.lines {
                let forecast = variableSpending(result, line: line.id, month: september)
                let expected = max(0, line.remainingAfterCommitted.minorUnits)
                XCTAssertEqual(forecast.minorUnits, expected,
                               "\(label)/\(line.id): forecast spread \(forecast) but the budget "
                               + "report says \(line.remainingAfterCommitted) remains after commitments")
            }

            let totalVariable = monthly.lines.reduce(Int64(0)) { $0 + max(0, $1.remainingAfterCommitted.minorUnits) }
            var seen: Int64 = 0
            for event in result.appliedEvents
            where event.phase == .variableSpending && event.day.monthKey == september {
                guard case let .debit(amount, _) = event.effect else { continue }
                seen += amount.magnitude.minorUnits
            }
            XCTAssertEqual(seen, totalVariable, "\(label): month total")
        }
    }

    // MARK: - E. Several months

    func testNettingIsPerMonthAndFollowsMonthlyOverrides() throws {
        let doc = document(
            budgets: [budget("housing", "480.00", overrides: [october: euro("600.00")])],
            obligations: [obligation("ob-housing", euro("480.00"), onDay: 12, budgetID: "housing")]
        )
        let result = try run(doc, from: "2026-09-01", to: "2026-10-31")

        XCTAssertEqual(variableSpending(result, line: "housing", month: september), euro("0.00"),
                       "September: 480.00 envelope − 480.00 committed")
        XCTAssertEqual(variableSpending(result, line: "housing", month: october), euro("120.00"),
                       "October: the 600.00 override − the 480.00 committed that month")
        XCTAssertEqual(totalDebits(result, month: october), euro("600.00"))
    }

    // MARK: - F. Currencies never net across each other

    /// No FX is ever guessed. A dirham commitment cannot reduce a euro
    /// envelope, however similar the numbers look.
    func testACommitmentInAnotherCurrencyDoesNotNetAEuroEnvelope() throws {
        let madAccount = Account(
            id: "mad", name: "Dirham account", currency: .mad, kind: .bank,
            supportedRails: [.sepaDirectDebit, .cardDebit], drawOrder: 1
        )
        let doc = document(
            budgets: [budget("travel", "70.00")],
            obligations: [obligation("ob-mad", dirham("70.00"), onDay: 10, budgetID: "travel")],
            accounts: [bank, madAccount],
            balances: [
                AccountBalance(accountID: "bank", balance: euro("5000.00"), asOf: day("2026-09-01")),
                AccountBalance(accountID: "mad", balance: dirham("5000.00"), asOf: day("2026-09-01")),
            ]
        )
        let result = try run(doc)

        XCTAssertEqual(variableSpending(result, line: "travel", month: september), euro("70.00"),
                       "the euro envelope is untouched by a dirham commitment")
        XCTAssertEqual(totalDebits(result, month: september), euro("70.00"),
                       "and the dirham debit is still charged, in dirhams")
        XCTAssertTrue(result.settlementFailures.isEmpty)
    }

    // MARK: - G. Installments are not budget commitments

    /// An installment leg repays a purchase that was already booked in full, and
    /// the model gives installments no `budgetID` at all. So there is no link to
    /// follow and nothing to net: the leg is charged, and every envelope is
    /// spread in full. This test exists to keep that deliberate.
    func testInstallmentLegsNeverNetAnEnvelope() throws {
        let plan = InstallmentPlan(
            id: "plan-phone", provider: "Provider", purchaseDescription: "Device",
            originalPurchaseAmount: euro("205.00"),
            installments: [
                Installment(sequence: 1, dueDate: day("2026-08-16"), amount: euro("51.25"),
                            status: .paid, paidOn: day("2026-08-16")),
                Installment(sequence: 2, dueDate: day("2026-09-16"), amount: euro("51.25")),
            ],
            paymentRequirement: PaymentRequirement(currency: .eur, acceptableRails: [.cardDebit])
        )
        let doc = document(budgets: [budget("groceries", "70.00")], installments: [plan])
        let result = try run(doc)

        XCTAssertEqual(variableSpending(result, line: "groceries", month: september), euro("70.00"))
        XCTAssertEqual(totalDebits(result, month: september), euro("121.25"),
                       "51.25 financing + 70.00 everyday; the paid leg is not charged again")
        XCTAssertEqual(report(doc).committed, euro("0.00"),
                       "installments are not part of the month's budget commitments")
    }

    // MARK: - H. Late and resolved occurrences are each represented once

    /// A late obligation is still owed. It stays committed, it is still charged
    /// on its own day, and it must not also reappear as everyday spending.
    func testALateObligationIsStillCommittedAndStillChargedExactlyOnce() throws {
        let doc = document(
            budgets: [budget("housing", "480.00")],
            obligations: [obligation("ob-housing", euro("480.00"), onDay: 3, budgetID: "housing")]
        )
        let result = try run(doc)
        let monthly = report(doc, today: "2026-09-20")

        XCTAssertEqual(monthly.committed, euro("480.00"), "overdue is unresolved, so still committed")
        XCTAssertEqual(monthly.lines.first?.remainingAfterCommitted, euro("0.00"))
        XCTAssertEqual(variableSpending(result, line: "housing", month: september), euro("0.00"))
        XCTAssertEqual(totalDebits(result, month: september), euro("480.00"),
                       "charged once, on 3 September")
    }

    /// The mirror case. A resolved occurrence is charged by nobody, so it nets
    /// nothing either: both modules read the same ledger and drop it together.
    /// One representation each way — never two, never none.
    ///
    /// This is also the one place the two views legitimately diverge, and it is
    /// worth being explicit about why. The budget report is month-to-date: the
    /// settled transaction is attributed to the line, so the envelope reads as
    /// spent. The forecast is forward-looking from a balance dated before the
    /// payment, so the same euros still have to leave the pool once — and they
    /// do, through the envelope rather than the obligation. Cash is charged
    /// exactly once either way.
    func testAResolvedObligationIsNeitherChargedNorNetted() throws {
        let doc = document(
            budgets: [budget("housing", "480.00")],
            obligations: [obligation("ob-housing", euro("480.00"), onDay: 12, budgetID: "housing")],
            settlements: [ObligationSettlement(
                id: "s1", obligationID: "ob-housing", expectedDay: day("2026-09-12"),
                resolution: .paid, actualTransactionID: "t-rent")],
            transactions: [Transaction(
                id: "t-rent", date: day("2026-09-12"), kind: .expense,
                legs: [AccountLeg(accountID: "bank", amount: euro("-480.00"))],
                factivity: .observed)]
        )
        let result = try run(doc)
        let monthly = report(doc)

        XCTAssertEqual(monthly.committed, euro("0.00"), "nothing is still promised")
        XCTAssertEqual(monthly.lines.first?.spent, euro("480.00"),
                       "the settlement attributes the actual payment to the line")
        XCTAssertEqual(variableSpending(result, line: "housing", month: september), euro("480.00"),
                       "and nothing is netted, so the envelope is spread in full")
        XCTAssertFalse(result.appliedEvents.contains { $0.sourceRef == "ob-housing" },
                       "and the obligation is not charged")
        XCTAssertEqual(totalDebits(result, month: september), euro("480.00"))
    }
}
