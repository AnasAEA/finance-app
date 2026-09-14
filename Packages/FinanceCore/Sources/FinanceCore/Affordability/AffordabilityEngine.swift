/// Pure affordability engine.
///
/// Same request → same verdict. Evaluating a candidate never mutates the
/// document, balances, planned purchases, sinking funds, or budgets. Home
/// `safeToSpend` is not this overlay and is not renamed here.
public enum AffordabilityEngine {

    public static func evaluate(_ request: AffordabilityRequest) throws -> AffordabilityVerdict {
        try request.validate()
        let document = request.document
        let candidate = request.candidate
        let poolRequirement = PaymentRequirement(
            currency: .eur,
            acceptableRails: PaymentRail.euroBankRails
        )

        let currentBalances = Dictionary(
            uniqueKeysWithValues: CurrentHoldings.overlayBalances(in: document, asOf: request.today).map {
                ($0.accountID, $0.balance)
            }
        )
        let overlay = ReservationOverlay.apply(
            positions: ReservationOverlay.positions(
                purchases: request.plannedPurchases,
                funds: request.sinkingFunds
            ),
            to: currentBalances,
            accounts: document.accounts,
            poolRequirement: poolRequirement
        )

        let ledgerPool = pool(currentBalances, accounts: document.accounts, requirement: poolRequirement)
        let unreservedPool = pool(
            overlay.availableBalances.map { AccountBalance(accountID: $0.key, balance: $0.value, asOf: request.today) },
            accounts: document.accounts,
            requirement: poolRequirement
        )
        let reserved = overlay.reserved.amount(in: poolRequirement.currency)

        let consumption = sinkingConsumption(request: request, overlay: overlay)
        let eligible = eligibleAccounts(for: candidate, in: document, funds: request.sinkingFunds)
        let ineligible = eligible.isEmpty
            || candidate.amount.currency != candidate.requirement.currency

        let budget = budgetAssessment(request: request)
        let extraEvents: [ForecastEvent]
        if ineligible {
            extraEvents = []
        } else {
            extraEvents = releaseEvents(consumption: consumption, overlay: overlay, on: candidate.on)
                + candidateEvents(candidate, funds: request.sinkingFunds)
        }

        var envelopes = document.planning.budgets
        if !ineligible,
           candidate.countsAsEconomicSpending,
           budget.withinCeiling == true,
           candidate.economicAmount.currency == poolRequirement.currency {
            envelopes = reducingDiscretionary(
                envelopes,
                in: candidate.on.monthKey,
                by: candidate.economicAmount
            )
        }

        let baselineRequest = composedRequest(
            document: document,
            start: request.today,
            end: request.horizonEnd,
            balances: overlay.availableBalances,
            extraEvents: [],
            budgets: document.planning.budgets
        )
        let afterRequest = composedRequest(
            document: document,
            start: request.today,
            end: request.horizonEnd,
            balances: overlay.availableBalances,
            extraEvents: extraEvents,
            budgets: envelopes
        )

        let baseline = try ForecastEngine.run(baselineRequest)
        let after: ForecastResult
        if ineligible {
            after = baseline
        } else {
            after = try ForecastEngine.run(afterRequest)
        }

        let timing = timingAssessment(before: baseline, after: after, currency: poolRequirement.currency)
        let settlement = settlementAssessment(
            candidate: candidate,
            document: document,
            overlay: overlay,
            consumption: consumption,
            unreservedPool: unreservedPool,
            ineligible: ineligible,
            funds: request.sinkingFunds
        )

        let operatingCashFails = operatingCashFailed(
            ineligible: ineligible,
            settlement: settlement,
            after: after,
            candidate: candidate,
            timing: timing
        )

        let requiredCertainty = try requiredIncomeCertainty(
            operatingCashFails: operatingCashFails,
            ineligible: ineligible,
            budget: budget,
            request: request,
            overlay: overlay,
            extraEvents: extraEvents,
            envelopes: envelopes,
            baseline: baseline,
            candidate: candidate
        )

        var reasons: [AffordabilityReason] = []
        if ineligible {
            reasons.append(.ineligibleCurrencyOrRail)
            if candidate.amount.currency != poolRequirement.currency {
                reasons.append(.foreignCurrencyNotConverted)
            }
        }
        if reserved.isPositive || !overlay.overReserved.isEmpty {
            reasons.append(.reservedMoneyIsNotSpent)
            reasons.append(.accountBalanceIsNotSafeToSpend)
        }
        if candidate.kind == .financingPurchase {
            reasons.append(.financingDoesNotDoubleCount)
        }
        if candidate.kind == .reservation {
            reasons.append(.notEconomicSpending)
        }
        if let consumption, consumption.consumed.isPositive {
            reasons.append(.sinkingFundConsumed)
            if consumption.consumed.minorUnits < candidate.cashAmount.minorUnits {
                reasons.append(.sinkingFundDoesNotFullyCover)
            }
        }
        if !settlement.wouldSettle && !ineligible {
            reasons.append(.candidateWouldFailToSettle)
            if candidate.settlementAccountID != nil {
                reasons.append(.settlementAccountInsufficient)
            }
            if unreservedPool.minorUnits >= candidate.cashAmount.minorUnits {
                reasons.append(.poolWouldCoverButSettlementWouldNot)
            }
        }
        if timing.deficitWorsened {
            if baseline.firstNegativeDate == nil {
                reasons.append(.newPoolDeficit)
            } else if let afterDay = after.firstNegativeDate,
                      let beforeDay = baseline.firstNegativeDate,
                      afterDay < beforeDay {
                reasons.append(.firstRiskMovedEarlier)
            } else {
                reasons.append(.deepenedPoolDeficit)
            }
        }
        if budget.withinCeiling == false {
            reasons.append(.overBudget)
        } else if candidate.countsAsEconomicSpending, budget.withinCeiling == true {
            reasons.append(.withinBudget)
        }
        if requiredCertainty != nil {
            reasons.append(.dependsOnExcludedIncome)
        } else if timing.newFloorBreach && !operatingCashFails {
            reasons.append(.newFloorBreach)
        }
        if !timing.deficitWorsened {
            reasons.append(.firstRiskUnchanged)
        }
        if operatingCashFails {
            reasons.append(.insufficientUnreservedCash)
        } else {
            reasons.append(.sufficientUnreservedCash)
        }

        let overall: AffordabilityOverall
        if ineligible || budget.withinCeiling == false {
            overall = .notAffordable
        } else if operatingCashFails, requiredCertainty != nil {
            overall = .affordableConditionally
        } else if operatingCashFails {
            overall = .notAffordable
        } else if timing.newFloorBreach {
            overall = .affordableConditionally
        } else {
            overall = .affordable
        }

        return AffordabilityVerdict(
            overall: overall,
            reasons: uniqued(reasons),
            cash: AffordabilityCashAssessment(
                ledgerPool: ledgerPool,
                reserved: reserved,
                unreservedPool: unreservedPool,
                sufficient: !operatingCashFails,
                ineligible: ineligible
            ),
            budget: budget,
            timing: timing,
            funding: AffordabilityFundingAssessment(
                operatingScenario: baselineRequest.scenario,
                excludedIncomeIDs: baseline.excludedIncomeEventIDs,
                requiredCertainty: requiredCertainty
            ),
            settlement: settlement,
            reservations: overlay,
            sinkingFundConsumption: consumption,
            baseline: baseline,
            after: after,
            economicAmount: candidate.economicAmount,
            cashAmount: candidate.cashAmount
        )
    }

    // MARK: - Composition

    private static func composedRequest(
        document: FinanceDocument,
        start: Day,
        end: Day,
        balances: [String: Money],
        extraEvents: [ForecastEvent],
        budgets: [BudgetAllocation]
    ) -> ForecastRequest {
        var request = ForecastComposer.makeRequest(
            from: document,
            startDate: start,
            endDate: end
        )
        request.startingBalances = balances
        request.events.append(contentsOf: extraEvents)
        request.budgets = budgets
        return request
    }

    private static func candidateEvents(
        _ candidate: AffordabilityCandidate,
        funds: [SinkingFund]
    ) -> [ForecastEvent] {
        switch candidate.kind {
        case .consumption:
            return [
                ForecastEvent(
                    id: "afford-\(candidate.id)",
                    day: candidate.on,
                    phase: .scheduledDebit,
                    priority: 1,
                    effect: debitEffect(candidate, amount: candidate.amount, funds: funds),
                    outflowSemantics: .economicCommitment,
                    sourceRef: candidate.id
                )
            ]
        case .reservation:
            return [
                ForecastEvent(
                    id: "afford-\(candidate.id)-hold",
                    day: candidate.on,
                    phase: .scheduledDebit,
                    priority: 1,
                    effect: debitEffect(candidate, amount: candidate.amount, funds: funds),
                    outflowSemantics: .relocation,
                    sourceRef: candidate.id
                )
            ]
        case .financingPurchase:
            guard let financing = candidate.financing else { return [] }
            return financing.installments
                .filter { $0.status == .scheduled }
                .enumerated()
                .map { index, installment in
                    ForecastEvent(
                        id: "afford-\(candidate.id)-inst-\(installment.sequence)",
                        day: installment.dueDate,
                        phase: .scheduledDebit,
                        priority: 1 + index,
                        effect: debitEffect(candidate, amount: installment.amount, funds: funds),
                        outflowSemantics: .financingCommitment,
                        sourceRef: candidate.id
                    )
                }
        }
    }

    private static func debitEffect(
        _ candidate: AffordabilityCandidate,
        amount: Money,
        funds: [SinkingFund]
    ) -> ForecastEvent.Effect {
        if let accountID = candidate.settlementAccountID {
            return .directedDebit(amount, fromAccount: accountID)
        }
        if let fundID = candidate.sinkingFundID,
           let fund = funds.first(where: { $0.id == fundID }),
           case let .dedicatedAccount(accountID) = fund.custody {
            return .directedDebit(amount, fromAccount: accountID)
        }
        return .debit(amount, requirement: candidate.requirement)
    }

    private static func releaseEvents(
        consumption: SinkingFundConsumption?,
        overlay: ReservationApplication,
        on day: Day
    ) -> [ForecastEvent] {
        guard let consumption, consumption.consumed.isPositive else { return [] }
        let draws = ReservationOverlay.consumptionDraws(
            from: overlay.draws,
            sourceID: consumption.fundID,
            limit: consumption.consumed
        )
        return draws.map { draw in
            ForecastEvent(
                id: "afford-release-\(draw.sourceID)-\(draw.accountID)",
                day: day,
                phase: .scheduledDebit,
                priority: 0,
                effect: .credit(draw.amount, toAccount: draw.accountID),
                outflowSemantics: .relocation,
                sourceRef: draw.sourceID
            )
        }
    }

    private static func sinkingConsumption(
        request: AffordabilityRequest,
        overlay: ReservationApplication
    ) -> SinkingFundConsumption? {
        let candidate = request.candidate
        guard candidate.kind == .consumption, let fundID = candidate.sinkingFundID else {
            return nil
        }
        guard let fund = request.sinkingFunds.first(where: { $0.id == fundID }), fund.isReserving else {
            return nil
        }
        let withheld = overlay.reservedAmount(sourceID: fundID, currency: candidate.amount.currency)
        let consume = min(candidate.amount.minorUnits, withheld.minorUnits)
        return SinkingFundConsumption(
            fundID: fundID,
            reservedBefore: withheld,
            consumed: Money(minorUnits: consume, currency: withheld.currency),
            reservedAfter: Money(minorUnits: withheld.minorUnits - consume, currency: withheld.currency)
        )
    }

    // MARK: - Budget / envelopes

    private static func budgetAssessment(request: AffordabilityRequest) -> AffordabilityBudgetAssessment {
        let candidate = request.candidate
        let economic = candidate.economicAmount
        let report = MonthlyBudgetEngine.report(
            month: candidate.on.monthKey,
            today: request.today,
            document: request.document,
            categoryKeys: request.categoryKeys,
            currency: economic.currency
        )
        let remaining: Money?
        let within: Bool?
        if !candidate.countsAsEconomicSpending {
            remaining = report.safeToSpendBudget
            within = true
        } else if let ceiling = request.document.planning.monthlyEconomicCeiling,
                  ceiling.currency == economic.currency {
            remaining = report.safeToSpendBudget
            within = remaining!.minorUnits >= economic.minorUnits
        } else {
            remaining = nil
            within = nil
        }
        return AffordabilityBudgetAssessment(
            ceiling: request.document.planning.monthlyEconomicCeiling,
            spent: report.spent,
            committed: report.committed,
            remaining: remaining,
            economicAmount: economic,
            countsAsSpending: candidate.countsAsEconomicSpending,
            withinCeiling: within
        )
    }

    private static func reducingDiscretionary(
        _ budgets: [BudgetAllocation],
        in month: MonthKey,
        by amount: Money
    ) -> [BudgetAllocation] {
        var remaining = amount.minorUnits
        var result = budgets
        for spendingClass in [SpendingClass.optional, .flexible] {
            for index in result.indices {
                guard result[index].spendingClass == spendingClass else { continue }
                guard let monthly = result[index].amount(for: month),
                      monthly.currency == amount.currency else { continue }
                let take = min(max(monthly.minorUnits, 0), remaining)
                result[index].monthlyOverrides[month] = Money(
                    minorUnits: monthly.minorUnits - take,
                    currency: monthly.currency
                )
                remaining -= take
            }
        }
        return result
    }

    // MARK: - Timing / settlement / income

    private static func timingAssessment(
        before: ForecastResult,
        after: ForecastResult,
        currency: Currency
    ) -> AffordabilityTimingAssessment {
        var deficitWorsened = false
        if before.firstNegativeDate == nil, after.firstNegativeDate != nil {
            deficitWorsened = true
        } else if let beforeDay = before.firstNegativeDate,
                  let afterDay = after.firstNegativeDate,
                  afterDay < beforeDay {
            deficitWorsened = true
        } else if after.lowestBalance.minorUnits < before.lowestBalance.minorUnits,
                  after.lowestBalance.isNegative {
            deficitWorsened = true
        }
        let newFloor = before.firstBelowSafetyFloorDate == nil && after.firstBelowSafetyFloorDate != nil
        return AffordabilityTimingAssessment(
            firstNegativeBefore: before.firstNegativeDate,
            firstNegativeAfter: after.firstNegativeDate,
            firstBelowFloorBefore: before.firstBelowSafetyFloorDate,
            firstBelowFloorAfter: after.firstBelowSafetyFloorDate,
            firstRiskBefore: before.firstRisk,
            firstRiskAfter: after.firstRisk,
            lowestBefore: Money(minorUnits: before.lowestBalance.minorUnits, currency: currency),
            lowestAfter: Money(minorUnits: after.lowestBalance.minorUnits, currency: currency),
            deficitWorsened: deficitWorsened,
            newFloorBreach: newFloor
        )
    }

    private static func settlementAssessment(
        candidate: AffordabilityCandidate,
        document: FinanceDocument,
        overlay: ReservationApplication,
        consumption: SinkingFundConsumption?,
        unreservedPool: Money,
        ineligible: Bool,
        funds: [SinkingFund]
    ) -> AffordabilitySettlementAssessment {
        var available = overlay.availableBalances
        if let consumption {
            for draw in ReservationOverlay.consumptionDraws(
                from: overlay.draws,
                sourceID: consumption.fundID,
                limit: consumption.consumed
            ) {
                let current = available[draw.accountID] ?? Money(minorUnits: 0, currency: draw.amount.currency)
                available[draw.accountID] = Money(
                    minorUnits: current.minorUnits + draw.amount.minorUnits,
                    currency: current.currency
                )
            }
        }
        let eligible = eligibleAccounts(for: candidate, in: document, funds: funds)
        let settlementAvailable = eligible.reduce(Int64(0)) { total, account in
            total + max((available[account.id] ?? Money(minorUnits: 0, currency: account.currency)).minorUnits, 0)
        }
        let required = candidate.kind == .financingPurchase
            ? (candidate.financing?.installments.first(where: { $0.status == .scheduled })?.amount
                ?? Money(minorUnits: 0, currency: candidate.amount.currency))
            : candidate.amount
        let wouldSettle = !ineligible && settlementAvailable >= required.minorUnits
        return AffordabilitySettlementAssessment(
            poolUnreserved: unreservedPool,
            settlementAvailable: Money(minorUnits: settlementAvailable, currency: required.currency),
            required: required,
            wouldSettle: wouldSettle,
            eligibleAccountIDs: eligible.map(\.id),
            settlementAccountID: candidate.settlementAccountID
        )
    }

    private static func operatingCashFailed(
        ineligible: Bool,
        settlement: AffordabilitySettlementAssessment,
        after: ForecastResult,
        candidate: AffordabilityCandidate,
        timing: AffordabilityTimingAssessment
    ) -> Bool {
        if ineligible { return true }
        if !settlement.wouldSettle { return true }
        if candidateFailed(after, candidate: candidate) { return true }
        if timing.deficitWorsened { return true }
        return false
    }

    private static func candidateFailed(_ result: ForecastResult, candidate: AffordabilityCandidate) -> Bool {
        let prefix = "afford-\(candidate.id)"
        return result.settlementFailures.contains { $0.eventID.hasPrefix(prefix) }
    }

    private static func requiredIncomeCertainty(
        operatingCashFails: Bool,
        ineligible: Bool,
        budget: AffordabilityBudgetAssessment,
        request: AffordabilityRequest,
        overlay: ReservationApplication,
        extraEvents: [ForecastEvent],
        envelopes: [BudgetAllocation],
        baseline: ForecastResult,
        candidate: AffordabilityCandidate
    ) throws -> IncomeCertainty? {
        guard operatingCashFails, !ineligible, budget.withinCeiling != false else { return nil }
        let operating = request.document.planning.defaultScenario ?? .base
        let operatingRank = operating.defaultPolicy.minimumCertainty
        let attempts: [(Scenario, Bool, IncomeCertainty)] = [
            (.base, false, .expected),
            (.upside, false, .target),
            (.upside, true, .possible),
        ]
        for (scenario, includesPossible, certainty) in attempts {
            if !includesPossible, certainty >= operatingRank { continue }
            var optimistic = composedRequest(
                document: request.document,
                start: request.today,
                end: request.horizonEnd,
                balances: overlay.availableBalances,
                extraEvents: extraEvents,
                budgets: envelopes
            )
            optimistic.scenario = scenario
            optimistic.policy = ScenarioPolicy(
                minimumCertainty: includesPossible ? .target : certainty,
                includesPossible: includesPossible
            )
            let result = try ForecastEngine.run(optimistic)
            let timing = timingAssessment(before: baseline, after: result, currency: .eur)
            let settlement = settlementAssessment(
                candidate: candidate,
                document: request.document,
                overlay: overlay,
                consumption: sinkingConsumption(request: request, overlay: overlay),
                unreservedPool: pool(
                    overlay.availableBalances.map { AccountBalance(accountID: $0.key, balance: $0.value, asOf: request.today) },
                    accounts: request.document.accounts,
                    requirement: PaymentRequirement(currency: .eur, acceptableRails: PaymentRail.euroBankRails)
                ),
                ineligible: false,
                funds: request.sinkingFunds
            )
            if !operatingCashFailed(
                ineligible: false,
                settlement: settlement,
                after: result,
                candidate: candidate,
                timing: timing
            ) {
                return certainty
            }
        }
        return nil
    }

    // MARK: - Accounts

    private static func eligibleAccounts(
        for candidate: AffordabilityCandidate,
        in document: FinanceDocument,
        funds: [SinkingFund]
    ) -> [Account] {
        let matching = document.accounts
            .filter { $0.satisfies(candidate.requirement) }
            .sorted { ($0.drawOrder, $0.id) < ($1.drawOrder, $1.id) }
        if let accountID = candidate.settlementAccountID {
            return matching.filter { $0.id == accountID }
        }
        if let fundID = candidate.sinkingFundID,
           let fund = funds.first(where: { $0.id == fundID }),
           case let .dedicatedAccount(accountID) = fund.custody {
            return matching.filter { $0.id == accountID }
        }
        return matching
    }

    private static func pool(
        _ balances: [AccountBalance],
        accounts: [Account],
        requirement: PaymentRequirement
    ) -> Money {
        let byID = Dictionary(balances.map { ($0.accountID, $0.balance) }, uniquingKeysWith: { first, _ in first })
        var total: Int64 = 0
        for account in accounts where account.satisfies(requirement) {
            total += (byID[account.id] ?? Money(minorUnits: 0, currency: account.currency)).minorUnits
        }
        return Money(minorUnits: total, currency: requirement.currency)
    }

    private static func pool(
        _ balances: [String: Money],
        accounts: [Account],
        requirement: PaymentRequirement
    ) -> Money {
        pool(
            balances.map { AccountBalance(accountID: $0.key, balance: $0.value, asOf: Day(year: 2001, month: 1, day: 1)) },
            accounts: accounts,
            requirement: requirement
        )
    }

    private static func uniqued(_ reasons: [AffordabilityReason]) -> [AffordabilityReason] {
        var seen = Set<AffordabilityReason>()
        var result: [AffordabilityReason] = []
        for reason in reasons where seen.insert(reason).inserted {
            result.append(reason)
        }
        return result
    }
}
