import XCTest
@testable import FinanceCore

/// The complete sample-scenario vector — the acceptance test that the
/// fixture, composer and engine agree with the scenario as modelled.
///
/// The fixture is invented. No person, account, merchant, amount or date in
/// it refers to anything real; the values were chosen so that every number
/// below can be checked by hand, independently of the engine.
///
/// ## Hand-derived event table (March 2027 BASE)
///
/// Opening electronic pool on Mar 1:
/// card-wallet 96.00 + online-wallet 0.00 + bank-main 300.00 = **396.00**
/// (the euro and franc cash pockets are outside the pool by definition).
///
/// | day    | event                                    | effect                                   |
/// |--------|------------------------------------------|------------------------------------------|
/// | 1–10   | everyday 10 × 2.91 (card rails)          | card 96.00 → 66.90                       |
/// | 4      | broadband 29.00 (sepa_direct → bank)     | bank 300.00 → 271.00                     |
/// | 6      | headphones leg 40.00 (card rails)        | card → 26.90 after the day's 2.91        |
/// | 10     | housing 480.00 (sepa_direct → bank only) | bank 271.00 → **−209.00**, failure       |
/// |        |                                          |   unsettled 209.00 · pool **−182.10**    |
/// | 11–14  | everyday 4 × 2.90                        | card 26.90 → 15.30 before the 13th       |
/// | 13     | contents insurance 8.00 (card rails)     | card → 10.20 after the day's 2.90        |
/// | 15     | camera leg 60.00 (card rails)            | card 7.30 → **−55.60**, failure          |
/// |        |                                          |   settled 7.30, unsettled 52.70          |
/// | 15     | everyday 2.90                            | card → −58.50, failure 2.90              |
/// | 16     | everyday 2.90 (debits precede credits)   | pool **−267.50 = intraday minimum**      |
/// | 16     | pot arrival +1000.00 (credit → pocket)   | pool unchanged (pocket ≠ pool)           |
/// | 16     | own share relocated: pocket −400.00,     | bank −209.00 → 191.00                    |
/// |        |   bank +400.00                           |                                          |
/// | 16     | handover −600.00 (pocket, last)          | pool **132.50**                          |
/// | 17–20  | everyday 4 × 2.90 (bank)                 | bank → 179.40                            |
/// | 21     | transit 24.00                            | bank → 152.50                            |
/// | 22–25  | everyday 4 × 2.90                        | bank → 140.90                            |
/// | 26     | music 11.00 + everyday 2.90              | bank → 127.00                            |
/// | 27–31  | everyday 5 × 2.90                        | bank → 112.50                            |
///
/// Month-end pool: 396.00 + 400.00 − 652.00 committed − 90.00 everyday =
/// **54.00**, and −58.50 + 0.00 + 112.50 = 54.00 agrees leg by leg.
/// Total unsettled March: 209.00 + 52.70 + 2.90 + 2.90 = **267.50** = the
/// minimum bridge.
final class FixtureVectorTests: XCTestCase {

    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    private func loadDocument() throws -> FinanceDocument {
        let url = Bundle.module.url(forResource: "sample-scenario", withExtension: "fixture.json", subdirectory: "Fixtures")!
        return try Interchange.decode(try Data(contentsOf: url))
    }

    private func march(_ document: FinanceDocument, scenario: Scenario? = nil, policy: ScenarioPolicy? = nil) throws -> ForecastResult {
        let request = ForecastComposer.makeRequest(
            from: document,
            startDate: Day(isoString: "2027-03-01")!,
            endDate: Day(isoString: "2027-03-31")!,
            scenario: scenario,
            policy: policy
        )
        return try ForecastEngine.run(request)
    }

    // MARK: - The headline vector

    func testMarchBaseVector() throws {
        let result = try march(try loadDocument())

        // End of March: 396.00 + 400.00 net chain − (652.00 committed + 90.00 everyday) = 54.00.
        XCTAssertEqual(result.projectedEndBalance, euro("54.00"))
        XCTAssertEqual(result.projectedMonthEnd[MonthKey(year: 2027, month: 3)], euro("54.00"))
        XCTAssertEqual(result.monthEndPool(MonthKey(year: 2027, month: 3)), euro("54.00"))

        // Mar 10 (housing day): the direct debit drains the bank below zero;
        // the card-rail everyday spending still settles from the card wallet.
        let mar10 = result.dailyBalances.first { $0.day == Day(isoString: "2027-03-10")! }!
        XCTAssertEqual(mar10.spendablePool, euro("-182.10"))
        XCTAssertEqual(mar10.endOfDay["bank-main"], euro("-209.00"))
        XCTAssertEqual(mar10.endOfDay["card-wallet"], euro("26.90"))

        // Mar 16: the day's everyday spending hits BEFORE the 1,000.00
        // arrives (debits before credits) — the intraday true minimum is
        // −267.50, far below the day's close of 132.50.
        XCTAssertEqual(result.lowestBalance, euro("-267.50"))
        XCTAssertEqual(result.lowestBalanceDate, Day(isoString: "2027-03-16")!)
        let mar16 = result.dailyBalances.first { $0.day == Day(isoString: "2027-03-16")! }!
        XCTAssertEqual(mar16.spendablePool, euro("132.50"))
        // The chain's account truth at close: the bank keeps the owned share,
        // the pocket is empty again, the co-traveller's money is gone.
        XCTAssertEqual(mar16.endOfDay["bank-main"], euro("191.00"))
        XCTAssertEqual(mar16.endOfDay["pocket-eur"], euro("0.00"))
        XCTAssertEqual(mar16.endOfDay["card-wallet"], euro("-58.50"))

        // Risk outputs (pool-deficit facts — distinct from settlement facts).
        XCTAssertEqual(result.firstNegativeDate, Day(isoString: "2027-03-10")!)
        XCTAssertEqual(result.minimumBridgeRequired, euro("267.50"))
        XCTAssertEqual(result.firstBelowSafetyFloorDate, Day(isoString: "2027-03-10")!)
        XCTAssertEqual(result.minimumBridgeForSafetyFloor, euro("347.50"))
        XCTAssertEqual(result.cashRunwayDays, 9, "pool first goes negative on Mar 10: 9 covered days")

        // Product-shaped first risk: the housing debit is the trigger.
        XCTAssertEqual(result.firstRisk?.day, Day(isoString: "2027-03-10")!)
        XCTAssertEqual(result.firstRisk?.kind, .poolDeficit)
        XCTAssertEqual(result.firstRisk?.triggerEventID, "ob-housing-2027-03-10")
        XCTAssertEqual(result.firstRisk?.triggerLabel, "ob-housing")
        XCTAssertEqual(result.firstRisk?.shortfall, euro("209.00"),
                       "the trigger's own unsettled remainder, not the pool gap it leaves")

        // Settlement failures: housing could not settle from sepa-capable
        // money; the camera leg and two everyday draws could not settle from
        // positive card money. The headphones leg is NOT among them.
        XCTAssertEqual(result.settlementFailures.count, 4)
        let housing = result.settlementFailures[0]
        XCTAssertEqual(housing.eventID, "ob-housing-2027-03-10")
        XCTAssertEqual(housing.requested, euro("480.00"))
        XCTAssertEqual(housing.settled, euro("271.00"))
        XCTAssertEqual(housing.unsettled, euro("209.00"))
        XCTAssertEqual(housing.eligibleAccountIDs, ["bank-main"],
                       "only the bank rides sepa_direct_debit — the franc pocket and card wallets are ineligible")
        let camera = result.settlementFailures[1]
        XCTAssertEqual(camera.eventID, "plan-camera-seq2")
        XCTAssertEqual(camera.settled, euro("7.30"))
        XCTAssertEqual(camera.unsettled, euro("52.70"))
        XCTAssertEqual(result.settlementFailures[2].unsettled, euro("2.90"))
        XCTAssertEqual(result.settlementFailures[3].unsettled, euro("2.90"))
        XCTAssertEqual(result.unfundedByMonth[MonthKey(year: 2027, month: 3)], MoneyBag(euro("267.50")))
        XCTAssertEqual(result.unfunded(in: .eur, month: MonthKey(year: 2027, month: 3)), euro("267.50"))
        XCTAssertEqual(result.unfunded(in: .chf, month: MonthKey(year: 2027, month: 3)),
                       Money(exactDecimal: "0.00", currency: .chf)!,
                       "the francs rode along untouched — they never become an unfunded fact")

        // A successful 40.00 card payment must NOT be labelled a settlement
        // failure merely because a later day ran the wallet dry.
        XCTAssertFalse(result.settlementFailures.contains { $0.eventID == "plan-headphones-seq3" })

        // No engine-expanded income source occurs in March; the 400.00
        // arrives via the composed chain instead.
        XCTAssertTrue(result.includedIncomeEventIDs.isEmpty)
        XCTAssertTrue(result.excludedIncomeEventIDs.isEmpty)

        // The francs rode along the whole month, untouched, at observed cost.
        XCTAssertEqual(result.dailyBalances.last?.endOfDay["pocket-chf"], Money(exactDecimal: "150.00", currency: .chf)!)
        XCTAssertEqual(result.dailyBalances.last?.trackedLiquidityEUR, euro("84.00")) // 54.00 pool + 30.00 carried

        // The 90.00 March envelope was spread exactly (largest remainder):
        // 10 × 2.91 + 21 × 2.90.
        let everyday = result.appliedEvents.filter { $0.id.hasPrefix("var-budget-everyday") }
        XCTAssertEqual(everyday.count, 31)
        XCTAssertEqual(Money.sum(everyday.map(\.signedPoolEffect), currency: .eur), euro("-90.00"))
    }

    // MARK: - The Mar 16 chain

    func testMarch16ChainComposedDirectly() throws {
        let document = try loadDocument()
        let result = try march(document)

        // The chain is fully present, in same-day order: debit (everyday) →
        // arrival credit → relocation (out then in) → dependent disposal last.
        let mar16 = result.appliedEvents.filter { $0.day == Day(isoString: "2027-03-16")! }
        XCTAssertEqual(
            mar16.map(\.id),
            [
                "var-budget-everyday-2027-03-16",
                "etx-pot-arrival",        // credit (gross 1000, pocket)
                "etx-pot-deposit-out",    // relocation out (pocket)
                "etx-pot-deposit-in",     // relocation in (bank)
                "etx-pot-handover",       // dependentDisposal (pocket −600)
            ]
        )

        // The gross 1,000.00 arrival never creates 1,000.00 of personal
        // income: economics over the chain say income = owned share only.
        let chain = document.expectedTransactions
        XCTAssertEqual(chain.count, 3)
        let totals = Economics.totals(for: chain, currency: .eur)
        XCTAssertEqual(totals.personalIncome, euro("400.00"), "income is exactly the 400.00 own share")
        XCTAssertEqual(totals.passThroughNotMine, euro("600.00"), "the co-traveller's 600.00 is documented as not-mine")
        XCTAssertEqual(totals.economicSpending, euro("0.00"), "relocation + disposal are not spending")
        XCTAssertEqual(totals.internalTransfers, euro("400.00"), "the deposit is visible as an internal transfer")

        // The handover is a disposal, not a commitment: it never enters
        // committed outflows, and is classified on the event itself.
        let disposal = result.appliedEvents.first { $0.id == "etx-pot-handover" }!
        XCTAssertEqual(disposal.outflowSemantics, .disposal)
        XCTAssertFalse(disposal.isCommittedOutflow)
        let depositOut = result.appliedEvents.first { $0.id == "etx-pot-deposit-out" }!
        XCTAssertEqual(depositOut.outflowSemantics, .relocation)
        XCTAssertFalse(depositOut.isCommittedOutflow)

        // Net pool effect of the chain on Mar 16: +1000 − 400 pocket-side and
        // +400 bank-side = +400 — the same liquidity a bare 400.00 income
        // credit would produce, but with the full account truth preserved.
        let mar15 = result.dailyBalances.first { $0.day == Day(isoString: "2027-03-15")! }!
        let mar16Close = result.dailyBalances.first { $0.day == Day(isoString: "2027-03-16")! }!
        XCTAssertEqual(
            mar16Close.spendablePool.minorUnits,
            mar15.spendablePool.minorUnits - 2_90 + 400_00,
            "the chain's net pool effect is exactly +400.00, after the day's 2.90 everyday debit"
        )
    }

    // MARK: - A guaranteed owned share enters every scenario

    func testGuaranteedMarchEqualsBase() throws {
        let document = try loadDocument()
        let base = try march(document, scenario: .base)
        let guaranteed = try march(document, scenario: .guaranteed)

        // The 400.00 share is GUARANTEED — a committed future resource.
        // It enters GUARANTEED, BASE and UPSIDE alike.
        XCTAssertEqual(guaranteed.projectedEndBalance, base.projectedEndBalance)
        XCTAssertEqual(guaranteed.unfundedByMonth, base.unfundedByMonth)
        XCTAssertEqual(guaranteed.projectedEndBalance, euro("54.00"),
                       "the guaranteed own share keeps March positive at close even in the GUARANTEED scenario")
        let upside = try march(document, scenario: .upside)
        XCTAssertEqual(upside.projectedEndBalance, euro("54.00"))

        // The fixture's source states the policy.
        let source = document.incomeSources.first { $0.id == "inc-trip-pot" }!
        XCTAssertEqual(source.certainty, .guaranteed)
        // And it is suppressed from engine expansion — the chain represents it.
        XCTAssertFalse(guaranteed.includedIncomeEventIDs.contains("inc-trip-pot"))
    }

    // MARK: - Arrears exist, and commit nothing

    func testArrearsExistButCommitNothing() throws {
        let document = try loadDocument()
        let debt = try XCTUnwrap(document.debts.first { $0.id == "debt-housing-arrears" })

        // The debt exists: two unpaid months of 480.00 = 960.00.
        XCTAssertEqual(debt.originalAmount, euro("960.00"))
        // …but there is NO agreed schedule: zero committed repayment events.
        XCTAssertTrue(debt.paymentSchedule.isEmpty)
        XCTAssertEqual(debt.remainingAmount, euro("0.00"))
        XCTAssertEqual(debt.unscheduledBalance, euro("960.00"),
                       "the whole arrear is owed-but-unscheduled")

        // No invented recovery payment anywhere in the fixture, and the
        // composer emits no debt events over the following six months.
        let request = ForecastComposer.makeRequest(
            from: document,
            startDate: Day(isoString: "2027-03-01")!,
            endDate: Day(isoString: "2027-08-31")!
        )
        XCTAssertFalse(request.events.contains { $0.id.hasPrefix("debt-housing-arrears") },
                       "no arrears repayment event may exist until a real agreement promotes one")
    }

    // MARK: - Observed facts are recorded exactly once

    func testObservedSupportIsRecordedExactlyOnce() throws {
        let document = try loadDocument()

        // The one-off support is an observed fact exactly once; no expectation
        // and no income source re-states it as a future stream.
        XCTAssertEqual(document.transactions.filter { $0.legs.contains { $0.amount == euro("410.00") } }.count, 1)
        XCTAssertFalse(document.expectedTransactions.contains { $0.legs.contains { $0.amount == euro("410.00") } })
        XCTAssertFalse(document.incomeSources.contains { $0.amount == euro("410.00") })

        // A reversed observed debit is economically void, and stays recorded.
        let reversed = try XCTUnwrap(document.transactions.first { $0.id == "tx-housing-reversed-2027-02-10" })
        XCTAssertEqual(reversed.lifecycle, .reversed)
        XCTAssertEqual(Economics.totals(for: [reversed], currency: .eur).economicSpending, euro("0.00"))
    }

    // MARK: - Bridge verification re-runs

    func testDepositingTheExactBridgeEliminatesTheNegative() throws {
        var document = try loadDocument()
        document.balances = document.balances.map { entry in
            entry.accountID == "bank-main"
                ? AccountBalance(accountID: entry.accountID, balance: euro("567.50"), asOf: entry.asOf, status: entry.status)
                : entry
        }
        let result = try march(document)

        XCTAssertNil(result.firstNegativeDate)
        XCTAssertEqual(result.lowestBalance, euro("0.00"),
                       "300.00 + 267.50 keeps every intraday balance non-negative — on Mar 16 the pool touches exactly zero")
        XCTAssertEqual(result.minimumBridgeRequired, euro("0.00"))
        XCTAssertTrue(result.settlementFailures.isEmpty)
        XCTAssertEqual(result.projectedEndBalance, euro("321.50")) // 54.00 + 267.50
    }

    func testDepositingTheExactFloorBridgeHoldsTheFloor() throws {
        var document = try loadDocument()
        document.balances = document.balances.map { entry in
            entry.accountID == "bank-main"
                ? AccountBalance(accountID: entry.accountID, balance: euro("647.50"), asOf: entry.asOf, status: entry.status)
                : entry
        }
        let result = try march(document)

        XCTAssertNil(result.firstBelowSafetyFloorDate)
        XCTAssertEqual(result.lowestBalance, euro("80.00"),
                       "the lowest intraday point lands exactly on the 80.00 floor")
        XCTAssertEqual(result.minimumBridgeForSafetyFloor, euro("0.00"))
    }

    // MARK: - Scenario behaviour on the fixture

    func testAprilUpsideMinusBaseIsExactlyTheUnsecuredIncome() throws {
        let document = try loadDocument()
        let request = { (scenario: Scenario) in
            ForecastComposer.makeRequest(from: document,
                                         startDate: Day(isoString: "2027-04-01")!,
                                         endDate: Day(isoString: "2027-04-30")!,
                                         scenario: scenario)
        }
        let base = try ForecastEngine.run(request(.base))
        let upside = try ForecastEngine.run(request(.upside))

        XCTAssertEqual(base.includedIncomeEventIDs, ["inc-studio"])
        XCTAssertEqual(upside.includedIncomeEventIDs, ["inc-grant", "inc-studio", "inc-workshops"],
                       "UPSIDE adds the target workshop fees (180.00) and the target grant (140.00)")
        let difference = upside.projectedEndBalance.minorUnits - base.projectedEndBalance.minorUnits
        XCTAssertEqual(difference, Int64(32000), "180.00 + 140.00 = 320.00, exactly the unsecured ladder steps")

        // The zero-amount royalties stream is tracked but silent: it never
        // appears in either list and contributes no events.
        XCTAssertFalse(base.includedIncomeEventIDs.contains("inc-royalties"))
        XCTAssertFalse(base.excludedIncomeEventIDs.contains("inc-royalties"))
        XCTAssertFalse(base.appliedEvents.contains { $0.sourceRef == "inc-royalties" })
    }

    func testPossibleAssistanceNeedsAnExplicitPolicy() throws {
        let document = try loadDocument()
        let request = { (policy: ScenarioPolicy?) in
            ForecastComposer.makeRequest(from: document,
                                         startDate: Day(isoString: "2027-05-01")!,
                                         endDate: Day(isoString: "2027-05-31")!,
                                         scenario: .base,
                                         policy: policy)
        }
        let base = try ForecastEngine.run(request(nil))
        XCTAssertTrue(base.excludedIncomeEventIDs.contains("inc-hardship"))

        let allowed = try ForecastEngine.run(request(ScenarioPolicy(minimumCertainty: .expected, includesPossible: true)))
        XCTAssertTrue(allowed.includedIncomeEventIDs.contains("inc-hardship"))
        let difference = allowed.projectedEndBalance.minorUnits - base.projectedEndBalance.minorUnits
        XCTAssertEqual(difference, Int64(21000), "opting in adds exactly the 210.00 possible assistance")
    }

    // MARK: - Determinism at the composer level

    func testComposerOutputOrderNeverMatters() throws {
        var document = try loadDocument()
        let reference = try march(document)

        // Reverse every input collection the composer reads; the engine's
        // total order must make the result identical.
        document.expectedTransactions.reverse()
        document.incomeSources.reverse()
        document.installments.reverse()
        document.planning.recurringObligations.reverse()
        document.balances.reverse()
        let shuffled = try march(document)

        XCTAssertEqual(shuffled, reference)
        XCTAssertEqual(shuffled.appliedEvents.map(\.id), reference.appliedEvents.map(\.id))
    }

    // MARK: - Home-screen snapshot

    func testSnapshotReadouts() throws {
        let document = try loadDocument()
        let result = try march(document)
        let snapshot = FinanceOverview.snapshot(
            document: document,
            result: result,
            today: Day(isoString: "2027-03-01")!,
            horizonDays: 30
        )

        // Accounts / Cash / Total tracked holdings — never collapsed.
        XCTAssertEqual(snapshot.financialAccountLiquidity, euro("396.00"))
        XCTAssertEqual(snapshot.physicalCashByCurrency.amount(in: .chf), Money(exactDecimal: "150.00", currency: .chf)!)
        XCTAssertEqual(snapshot.physicalCashByCurrency.amount(in: .eur), euro("0.00"), "the euro pocket is empty on Feb 28")
        XCTAssertEqual(snapshot.physicalCashByCurrency.currencies, [.chf])
        XCTAssertEqual(snapshot.totalTrackedHoldings.amount(in: .eur), euro("396.00"))
        XCTAssertEqual(snapshot.totalTrackedHoldings.amount(in: .chf), Money(exactDecimal: "150.00", currency: .chf)!)
        XCTAssertEqual(snapshot.physicalHoldings.count, 2)
        XCTAssertEqual(snapshot.trackedEURLiquidity, euro("426.00"))

        // Committed outflows over the next 30 days — 652.00. The relocation
        // and the handover are NOT among them:
        // 29 + 480 + 8 + 24 + 11 obligations + 40 + 60 financing legs.
        XCTAssertEqual(snapshot.committedOutflowsNext, euro("652.00"))
        XCTAssertEqual(snapshot.railRelocations.count, 3,
                       "relocation out + relocation in + handover surface as rail movements, not commitments")
        XCTAssertEqual(Set(snapshot.railRelocations.map(\.id)),
                       ["etx-pot-deposit-out", "etx-pot-deposit-in", "etx-pot-handover"])

        // Safe to spend: the deficit is never hidden behind a clamped zero.
        XCTAssertEqual(snapshot.safeToSpend.rawHeadroom, euro("-256.00")) // 396.00 − 652.00
        XCTAssertEqual(snapshot.safeToSpend.amount, euro("0.00"))
        XCTAssertTrue(snapshot.safeToSpend.isDeficit)
        XCTAssertNil(snapshot.safeToSpend.dailyAmount)
        XCTAssertEqual(snapshot.safeToSpend.firstConstraint, Day(isoString: "2027-03-10")!)

        XCTAssertEqual(snapshot.firstRiskDate, Day(isoString: "2027-03-10")!)
        XCTAssertEqual(snapshot.minimumBridge, euro("267.50"))
        XCTAssertEqual(snapshot.firstBelowFloorDate, Day(isoString: "2027-03-10")!)

        // The upcoming feed is in deterministic application order and starts
        // with the first day's everyday spending.
        XCTAssertEqual(snapshot.upcoming.first?.day, Day(isoString: "2027-03-01")!)
        XCTAssertEqual(snapshot.upcoming.count, 42) // 31 everyday + 5 obligations + 2 financing legs + 4 chain events
    }
}

/// Test-only helper: the euro pool effect of a single event, signed.
extension ForecastEvent {
    var signedPoolEffect: Money {
        switch effect {
        case let .credit(amount, _):
            return amount
        case let .debit(amount, _), let .directedDebit(amount, _):
            return Money(minorUnits: -amount.minorUnits, currency: amount.currency)
        }
    }
}
