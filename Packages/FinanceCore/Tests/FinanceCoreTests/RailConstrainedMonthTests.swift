import XCTest
@testable import FinanceCore

/// The rail-constrained month shape that exposed the defect, pinned end to end.
///
/// This is the production-shaped case: a small euro pool split across a bank
/// account, a daily-spending card wallet and an online wallet; a large rent
/// direct debit the bank alone can pay; two buy-now-pay-later legs only the
/// online wallet can pay; a pass-through arrival most of which belongs to
/// somebody else; and budget lines that already contain those obligations.
///
/// **Everything here is invented.** The identifiers are placeholders, the
/// accounts belong to nobody, and the amounts were chosen so that the
/// arithmetic below is checkable by hand. What is real is the *shape*: it is
/// the one combination in which a gross-envelope budget, a rail-constrained
/// payment and a pass-through all interact, and the one in which the old
/// forecast produced a number nobody could derive.
///
/// # The inputs
///
/// | | |
/// |---|---|
/// | opening pool | 110.00 card + 48.00 online + 320.00 bank = **478.00** |
/// | pass-through, 5 Sep | 1200.00 arrives in a cash pocket; 700.00 is handed on |
/// | handover deposit, 20 Sep | 500.00 pocket → bank (the owned share) |
/// | obligations, linked | 45.00 (3rd) + 520.00 (11th) + 25.00 (22nd) + 9.00 (28th) = **599.00** |
/// | installment legs | 48.00 (8th) + 60.00 (16th) = **108.00** |
/// | budget lines | 520.00 + 45.00 + 25.00 + 9.00 + 140.00 = **739.00** |
/// | monthly ceiling | 800.00 |
///
/// # The answers, and where each comes from
///
/// - **Everyday spending 140.00.** Four of the five lines are exactly the
///   obligation linked to them, so they have nothing left to spread:
///   739.00 − 599.00. Before the fix the forecast spread all 739.00 *on top
///   of* the obligations it had already charged.
/// - **Committed & scheduled 707.00.** 599.00 obligations + 108.00 legs.
/// - **Projected closing 131.00.** 478.00 + 500.00 − 707.00 − 140.00.
/// - **Unfunded 305.00.** Rent asks 520.00 of an account holding 275.00
///   (320.00 − the 45.00 on the 3rd) → 245.00 unpayable; the 60.00 leg on the
///   16th asks an online wallet emptied by the 48.00 leg on the 8th → 60.00
///   unpayable. Nothing else misses, and no everyday spending misses at all.
/// - **First risk 11 Sep, short by 245.00.** Rent is the event that first
///   takes the pool below zero, and the amount is that same payment's own
///   unsettled remainder — not the pool gap of 186.37 it happens to leave.
/// - **Budget left 201.00 of 800.00.** Ceiling 800.00 − 0.00 spent −
///   599.00 committed.
///
/// Every one of those numbers is asserted below against the real composer and
/// the real engine. None of them is written down anywhere in the
/// implementation.
final class RailConstrainedMonthTests: XCTestCase {

    // MARK: - Fixture

    private func euro(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .eur)! }
    private func day(_ iso: String) -> Day { Day(isoString: iso)! }
    private let month = MonthKey(year: 2026, month: 9)
    private let firstDay = Day(isoString: "2026-09-01")!
    private let lastDay = Day(isoString: "2026-09-30")!

    /// The card wallet everyday spending comes off first, then the online
    /// wallet, then the bank. Draw order is a modelling fact about where money
    /// is spent from, not a ranking of the accounts.
    private let daily = Account(
        id: "acct-daily", name: "Daily card", currency: .eur, kind: .wallet,
        supportedRails: [.cardDebit, .sepaCreditTransfer], drawOrder: 0
    )
    /// The only account that can settle an `electronicPayment` — which is why
    /// the installment legs can run out of money while the bank is solvent.
    private let online = Account(
        id: "acct-online", name: "Online wallet", currency: .eur, kind: .wallet,
        supportedRails: [.electronicPayment], drawOrder: 1
    )
    /// The only account that can settle a `sepaDirectDebit` — which is why the
    /// rent can fail while the pool as a whole still holds money.
    private let bank = Account(
        id: "acct-main", name: "Bank", currency: .eur, kind: .bank,
        supportedRails: [.sepaDirectDebit, .sepaCreditTransfer, .cardDebit], drawOrder: 2
    )
    /// Physical cash: no bank rail, so it is outside the spendable pool. The
    /// pass-through lands here, which is exactly why its gross never inflates
    /// the pool.
    private let pocket = Account(
        id: "acct-pocket", name: "Cash pocket", currency: .eur, kind: .cash,
        supportedRails: [.physicalCash], drawOrder: 3
    )

    private func line(_ id: String, _ amount: String) -> BudgetAllocation {
        BudgetAllocation(
            id: id, name: id, spendingClass: .flexible, monthlyAmount: euro(amount),
            effectiveFrom: MonthKey(year: 2026, month: 1), confirmation: .userConfirmed
        )
    }

    private func obligation(
        _ id: String, _ amount: String, onDay: Int, budgetID: String, rails: Set<PaymentRail>
    ) -> RecurringObligation {
        RecurringObligation(
            id: id, name: id, amount: euro(amount),
            spec: .monthly(onDay: onDay, from: MonthKey(year: 2026, month: 1), through: nil),
            requirement: PaymentRequirement(currency: .eur, acceptableRails: rails),
            spendingClass: .essential, budgetID: budgetID
        )
    }

    private func plan(_ id: String, _ amount: String, dueOn: String, sequence: Int) -> InstallmentPlan {
        InstallmentPlan(
            id: id, provider: id, purchaseDescription: id,
            originalPurchaseAmount: euro(amount),
            installments: [Installment(sequence: sequence, dueDate: day(dueOn), amount: euro(amount))],
            paymentRequirement: PaymentRequirement(currency: .eur, acceptableRails: [.electronicPayment])
        )
    }

    private func makeDocument() -> FinanceDocument {
        // The pass-through chain: gross arrival into the pocket, the share that
        // belongs to somebody else handed back out of the pocket, and the owned
        // share deposited to the bank later in the month.
        let arrival = Transaction(
            id: "etx-arrival", date: day("2026-09-05"), kind: .passThrough,
            legs: [AccountLeg(accountID: pocket.id, amount: euro("1200.00"))],
            ownership: [
                OwnershipSplit(ownerID: "self", isSelf: true, amount: euro("500.00")),
                OwnershipSplit(ownerID: "other", isSelf: false, amount: euro("700.00")),
            ],
            incomeSourceID: "src-support",
            factivity: .expected, certainty: .guaranteed
        )
        let handover = Transaction(
            id: "etx-handover", date: day("2026-09-05"), kind: .passThrough,
            legs: [AccountLeg(accountID: pocket.id, amount: euro("-700.00"))],
            linkedTransactionID: "etx-arrival", factivity: .expected
        )
        let deposit = Transaction(
            id: "etx-deposit", date: day("2026-09-20"), kind: .transfer,
            legs: [
                AccountLeg(accountID: pocket.id, amount: euro("-500.00")),
                AccountLeg(accountID: bank.id, amount: euro("500.00")),
            ],
            factivity: .expected
        )

        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [daily, online, bank, pocket],
            balances: [
                AccountBalance(accountID: daily.id, balance: euro("110.00"), asOf: firstDay),
                AccountBalance(accountID: online.id, balance: euro("48.00"), asOf: firstDay),
                AccountBalance(accountID: bank.id, balance: euro("320.00"), asOf: firstDay),
                AccountBalance(accountID: pocket.id, balance: euro("0.00"), asOf: firstDay),
            ],
            expectedTransactions: [arrival, handover, deposit],
            incomeSources: [
                // Represented by the chain above, so the composer suppresses it.
                // It is present because the physical document has it: the fixture
                // must exercise the suppression, not dodge it.
                IncomeSource(
                    id: "src-support", name: "src-support", amount: euro("1200.00"),
                    certainty: .guaranteed,
                    schedule: .monthly(onDay: 5, from: MonthKey(year: 2026, month: 1), through: nil),
                    arrivesOnAccount: pocket.id
                )
            ],
            installments: [
                plan("plan-device", "48.00", dueOn: "2026-09-08", sequence: 3),
                plan("plan-appliance", "60.00", dueOn: "2026-09-16", sequence: 2),
            ],
            planning: FinanceDocument.Planning(
                monthlyEconomicCeiling: euro("800.00"),
                budgets: [
                    line("housing", "520.00"),
                    line("utilities", "45.00"),
                    line("transport", "25.00"),
                    line("subscriptions", "9.00"),
                    line("everyday", "140.00"),
                ],
                recurringObligations: [
                    obligation("ob-utilities", "45.00", onDay: 3,
                               budgetID: "utilities", rails: [.sepaDirectDebit]),
                    obligation("ob-housing", "520.00", onDay: 11,
                               budgetID: "housing", rails: [.sepaDirectDebit]),
                    obligation("ob-transport", "25.00", onDay: 22,
                               budgetID: "transport", rails: [.cardDebit]),
                    obligation("ob-media", "9.00", onDay: 28,
                               budgetID: "subscriptions", rails: [.cardDebit]),
                ]
            )
        )
    }

    private func forecast(to end: Day? = nil) throws -> ForecastResult {
        try ForecastEngine.run(
            ForecastComposer.makeRequest(
                from: makeDocument(), startDate: firstDay, endDate: end ?? lastDay, scenario: .base
            )
        )
    }

    private func budgetReport() -> MonthlyBudgetReport {
        MonthlyBudgetEngine.report(month: month, today: firstDay, document: makeDocument())
    }

    // MARK: - The everyday envelope is what the lines have left

    /// 739.00 of budget lines, 599.00 of it already promised to obligations the
    /// forecast charges by name, so 140.00 is what everyday spending can still
    /// take. The pre-fix engine spread the whole 739.00 in addition to the
    /// obligations, which is where the unexplainable projection came from.
    func testEverydaySpendingIsOnlyWhatTheLinesHaveNotAlreadyPromised() throws {
        let result = try forecast()

        var byLine: [String: Int64] = [:]
        for event in result.appliedEvents where event.phase == .variableSpending {
            guard case let .debit(amount, _) = event.effect else { continue }
            byLine[event.sourceRef ?? "?", default: 0] += amount.magnitude.minorUnits
        }

        XCTAssertEqual(byLine["everyday"], euro("140.00").minorUnits,
                       "the only line with room left spreads all of it")
        for fullyCommitted in ["housing", "utilities", "transport", "subscriptions"] {
            XCTAssertNil(byLine[fullyCommitted],
                         "\(fullyCommitted) is exactly its obligation, so it emits nothing")
        }
        XCTAssertEqual(byLine.values.reduce(0, +), euro("140.00").minorUnits,
                       "739.00 of lines − 599.00 already committed to them")
        XCTAssertNotEqual(byLine.values.reduce(0, +), euro("739.00").minorUnits,
                          "the gross envelope must never be spread on top of its own obligations")
    }

    /// §3 at fixture scale: what the forecast spreads and what the budget report
    /// says is left are one number, line by line, in the shape a person actually
    /// has on their phone.
    func testForecastEverydaySpendingEqualsTheBudgetReportsRemainder() throws {
        let result = try forecast()
        let report = budgetReport()

        var forecastByLine: [String: Int64] = [:]
        for event in result.appliedEvents where event.phase == .variableSpending {
            guard case let .debit(amount, _) = event.effect else { continue }
            forecastByLine[event.sourceRef ?? "?", default: 0] += amount.magnitude.minorUnits
        }

        for progress in report.lines {
            XCTAssertEqual(progress.spent, euro("0.00"),
                           "\(progress.id): fixture precondition — nothing spent yet")
            XCTAssertEqual(
                forecastByLine[progress.id] ?? 0,
                max(progress.remainingAfterCommitted.minorUnits, 0),
                "\(progress.id): the forecast and the report must not disagree about what is left"
            )
        }
        XCTAssertEqual(
            forecastByLine.values.reduce(0, +),
            max(report.remainingAfterCommitted.minorUnits, 0),
            "and the month totals agree too"
        )
    }

    // MARK: - The month adds up

    /// §15. Opening, income, committed, everyday, closing — five rows a person
    /// can add up, and they must add up exactly, because the four groups
    /// partition every movement the pool saw. If a hidden phase moved cash, this
    /// fails.
    func testTheMonthLedgerAddsUpToTheCent() throws {
        let result = try forecast()
        let ledger = try XCTUnwrap(result.monthLedgers[month])

        XCTAssertEqual(ledger.opening, euro("478.00"), "110.00 + 48.00 + 320.00")
        XCTAssertEqual(ledger.income, euro("500.00"), "the owned share of the pass-through, net")
        XCTAssertEqual(ledger.committed, euro("707.00"), "599.00 obligations + 108.00 installment legs")
        XCTAssertEqual(ledger.everyday, euro("140.00"), "739.00 of lines − 599.00 already committed")
        XCTAssertEqual(ledger.closing, euro("131.00"), "478.00 + 500.00 − 707.00 − 140.00")

        XCTAssertEqual(ledger.reconciledClosing, ledger.closing,
                       "the five rows are one arithmetic model, not two")
        XCTAssertEqual(result.projectedMonthEnd[month], euro("131.00"),
                       "and the ledger's closing is the same closing the projection shows")
    }

    /// The number the buggy engine showed. Pinned as a negative so a regression
    /// cannot quietly restore it: −17.13 is 131.00 minus the 599.00 that was
    /// being charged twice.
    func testTheOldDoubleChargedClosingBalanceCannotComeBack() throws {
        let result = try forecast()
        XCTAssertNotEqual(result.projectedMonthEnd[month], euro("-468.00"),
                          "spreading the gross envelope on top of its obligations produced this")
    }

    // MARK: - Pass-through: the pool only ever sees the owned share

    /// §7. The gross 1200.00 is real and it is in the document, but it lands in
    /// a cash pocket that no bank rail can reach, so the pool never sees it.
    /// What the pool sees is the 500.00 deposit — and that is precisely the
    /// number the summary shows as income. Visible income and net pool
    /// contribution are the same quantity, so no conversion or guess is needed.
    func testOnlyTheOwnedShareOfThePassThroughReachesThePool() throws {
        let result = try forecast()
        let ledger = try XCTUnwrap(result.monthLedgers[month])

        let chain = result.appliedEvents.filter {
            ["etx-arrival", "etx-handover", "etx-deposit"].contains($0.sourceRef ?? "")
        }
        XCTAssertEqual(chain.count, 4, "gross credit, handover, deposit out, deposit in")

        // Gross in, non-owned share out, and the deposit moving the owned share
        // into a spendable account: +1600 − 800 − 800 + 800 as *balances*, but
        // only the last leg touches the pool.
        XCTAssertEqual(ledger.income, euro("500.00"),
                       "the visible income row is the net pool contribution of the chain")
        XCTAssertFalse(result.includedIncomeEventIDs.contains { $0.contains("src-support") },
                       "the linked income source is represented by the chain, never twice")
        // Across the arrival day the pool moves by the everyday spending of the
        // 5th and the 6th and by nothing else: 1200.00 in and 700.00 out again,
        // both in cash, are invisible to it.
        let fourth = try XCTUnwrap(result.dailyBalances.first { $0.day == self.day("2026-09-04") })
        let sixth = try XCTUnwrap(result.dailyBalances.first { $0.day == self.day("2026-09-06") })
        XCTAssertEqual(fourth.spendablePool - sixth.spendablePool, euro("9.34"),
                       "two days of everyday spending at 4.67, and no trace of the 1200.00")
        XCTAssertEqual(sixth.otherTrackedEUR, euro("500.00"),
                       "it is tracked, just not spendable — 1200.00 in, 700.00 handed on")
    }

    // MARK: - Unfunded payments are not a negative month

    /// §9. Two named payments cannot be made from the accounts they require:
    /// 245.00 of the rent and the whole 60.00 leg. That is 305.00 — a fact about
    /// two payments on two days, not the month's closing balance, which is
    /// +131.00. The two numbers must never be presented as the same thing.
    func testUnfundedIsTwoNamedPaymentsAndNotTheClosingBalance() throws {
        let result = try forecast()

        let unfunded = try XCTUnwrap(result.unfundedEURByMonth[month])
        XCTAssertEqual(unfunded, euro("305.00"), "245.00 of rent + 60.00 of the installment leg")

        let failures = result.settlementFailures.filter { $0.day.monthKey == month }
        XCTAssertEqual(failures.count, 2, "exactly two payments miss, and both are named")
        let rent = try XCTUnwrap(failures.first { $0.eventID.hasPrefix("ob-housing") })
        XCTAssertEqual(rent.day, day("2026-09-11"))
        XCTAssertEqual(rent.requested, euro("520.00"))
        XCTAssertEqual(rent.settled, euro("275.00"), "320.00 opening − the 45.00 debit on the 3rd")
        XCTAssertEqual(rent.unsettled, euro("245.00"))
        XCTAssertEqual(rent.eligibleAccountIDs, [bank.id],
                       "a direct debit can only be taken from the account that has the mandate")
        let leg = try XCTUnwrap(failures.first { $0.eventID.hasPrefix("plan-appliance") })
        XCTAssertEqual(leg.day, day("2026-09-16"))
        XCTAssertEqual(leg.settled, euro("0.00"), "the online wallet was emptied by the 48.00 leg")
        XCTAssertEqual(leg.unsettled, euro("60.00"))

        XCTAssertFalse(failures.contains { $0.eventID.hasPrefix("var-") },
                       "no everyday spending misses: the card wallet covers all 140.00")
        XCTAssertTrue(result.projectedMonthEnd[month]!.isPositive,
                      "unfunded payments and a negative month are different facts")
    }

    /// The buggy total, pinned as a negative for the same reason as the closing
    /// balance: 519.54 was 305.00 plus the everyday spending that the
    /// double-charged envelope could no longer pay for.
    func testTheOldUnfundedTotalCannotComeBack() throws {
        let result = try forecast()
        XCTAssertNotEqual(result.unfundedEURByMonth[month], euro("519.54"))
    }

    // MARK: - One risk, one amount, one date

    /// §10 and §16. The sentence a person reads is "short by X by D". X and D
    /// have to come from the same object, or the app is welding an amount from
    /// one horizon to a date from another — which is exactly what it used to do.
    ///
    /// Here D is 11 Sep and X is 245.00: the rent's own unsettled remainder, the
    /// thing a person can act on. Note what X is *not*: the pool ends that day
    /// 186.37 below zero, and a 30-day headroom figure would be different again.
    /// Both would be defensible numbers; neither is the number that belongs next
    /// to this date.
    func testTheFirstRiskCarriesItsOwnAmountAndDate() throws {
        let result = try forecast()
        let risk = try XCTUnwrap(result.firstRisk)

        XCTAssertEqual(risk.day, day("2026-09-11"))
        XCTAssertEqual(risk.kind, .poolDeficit)
        XCTAssertEqual(risk.shortfall, euro("245.00"))
        XCTAssertEqual(risk.triggerLabel, "ob-housing")
        XCTAssertEqual(result.firstNegativeDate, risk.day, "one detection, not two")
        XCTAssertEqual(result.cashRunwayDays, 10, "1 Sep to 11 Sep")

        // The amount is the trigger's own failure, from the same event, on the
        // same day. Anything that recomputed it elsewhere would break this.
        let trigger = try XCTUnwrap(result.settlementFailures.first { $0.eventID == risk.triggerEventID })
        XCTAssertEqual(trigger.unsettled, risk.shortfall)
        XCTAssertEqual(trigger.day, risk.day)

        // The pool gap is a real, different quantity — pinned positively so the
        // documented contrast cannot quietly stop being true.
        let eleventh = try XCTUnwrap(result.dailyBalances.first { $0.day == self.day("2026-09-11") })
        XCTAssertEqual(eleventh.spendablePool, euro("-186.37"),
                       "478.00 − 51.37 everyday − 45.00 − 48.00 − 520.00")
        XCTAssertNotEqual(risk.shortfall, eleventh.spendablePool.magnitude,
                          "the pool gap is a different quantity from the payment that caused it")
    }

    /// The same object over the app's real 120-day horizon. Lengthening the
    /// window must not move the amount or the date: a risk is dated where it
    /// happens, and it carries its own shortfall with it. A presentation that
    /// took the amount from a 30-day window and the date from a 120-day one
    /// would disagree with one of these two runs.
    func testTheFirstRiskIsTheSameOverALongerHorizon() throws {
        let short = try XCTUnwrap(try forecast(to: lastDay).firstRisk)
        let long = try XCTUnwrap(try forecast(to: try XCTUnwrap(firstDay.advanced(by: 119))).firstRisk)

        XCTAssertEqual(long.day, short.day, "the risk is dated where it happens, not where you look")
        XCTAssertEqual(long.shortfall, short.shortfall)
        XCTAssertEqual(long.triggerEventID, short.triggerEventID)
        XCTAssertEqual(long.day, day("2026-09-11"))
        XCTAssertEqual(long.shortfall, euro("245.00"))
    }

    // MARK: - What is left of the ceiling

    /// §14. The budget card's own arithmetic: an 800.00 ceiling with nothing spent
    /// yet and 599.00 already committed leaves 201.00. This is a third quantity,
    /// distinct from the 707.00 that is scheduled and the 140.00 of everyday
    /// spending planned, and the three must never be shown as one.
    func testMonthBudgetLeftAgainstTheCeiling() throws {
        let report = budgetReport()

        XCTAssertEqual(report.ceiling, euro("800.00"))
        XCTAssertEqual(report.target, euro("739.00"), "the five lines")
        XCTAssertEqual(report.spent, euro("0.00"))
        XCTAssertEqual(report.committed, euro("599.00"), "four linked obligations, none of them paid yet")
        XCTAssertEqual(report.remainingAfterCommitted, euro("140.00"), "739.00 − 0.00 − 599.00")
        XCTAssertEqual(report.safeToSpendBudget, euro("201.00"), "800.00 − 0.00 − 599.00")

        let housing = try XCTUnwrap(report.lines.first { $0.id == "housing" })
        XCTAssertEqual(housing.committed, euro("520.00"))
        XCTAssertEqual(housing.remainingAfterCommitted, euro("0.00"),
                       "the rent is inside the housing envelope, not beside it")
        let everyday = try XCTUnwrap(report.lines.first { $0.id == "everyday" })
        XCTAssertEqual(everyday.committed, euro("0.00"), "nothing is linked to it")
        XCTAssertEqual(everyday.remainingAfterCommitted, euro("140.00"))
    }

    /// The installment legs are 108.00 of scheduled cash that no budget line can
    /// absorb, because installment plans carry no `budgetID` — so they are
    /// charged in full and they net nothing. Same for anything else unlinked:
    /// §1's rule that an obligation without a line stays an independent debit.
    func testInstallmentLegsAreScheduledCashThatNoEnvelopeContains() throws {
        let result = try forecast()
        let report = budgetReport()

        var legs: Int64 = 0
        for event in result.appliedEvents
        where event.phase == .scheduledDebit && (event.sourceRef ?? "").hasPrefix("plan-") {
            guard case let .debit(amount, _) = event.effect else { continue }
            legs += amount.magnitude.minorUnits
        }
        XCTAssertEqual(legs, euro("108.00").minorUnits, "48.00 on the 8th + 60.00 on the 16th")

        XCTAssertEqual(report.committed, euro("599.00"),
                       "the report's committed total is obligations only — legs have no line to sit in")
        let ledger = try XCTUnwrap(result.monthLedgers[month])
        XCTAssertEqual(ledger.committed, euro("707.00"),
                       "but the cash ledger charges them in full: 599.00 + 108.00")
    }
}
