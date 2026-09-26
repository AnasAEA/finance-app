/// The day-level forecast engine. Pure: same request → same result, always,
/// independent of dictionary or array iteration order.
///
/// Semantics summary (full detail in DOMAIN.md):
///
/// - Every applied event is ordered by the total order
///   `(day, phase, priority, id)` — see `EventPhase` for the documented
///   same-day rule (debits before credits, relocations after arrivals,
///   dependent disposals last).
/// - A debit carrying a `PaymentRequirement` can only draw from accounts with
///   the matching currency AND an acceptable rail. Money that cannot ride the
///   rail is never spent on it: 200 MAD of physical cash never prevents a
///   SEPA balance from going negative.
/// - A debit **settles** iff the *positive* balances of eligible accounts
///   cover it. Negative sibling balances never make a payment "fail", and a
///   fully-settled payment is never reported as a failure even when the
///   aggregate pool is negative (defect D4: settlement failure is a fact
///   about the payment; the pool deficit is a different fact, reported via
///   `firstNegativeDate`/`lowestBalance`/`firstRisk`).
/// - An unsettled remainder is still applied (first eligible account goes
///   negative) and recorded in `settlementFailures` — never dropped, never
///   cross-currency funded.
/// - Headline metrics are measured on the **spendable euro pool**; tracked
///   liquidity additionally carries other EUR holdings and foreign cash at
///   its *observed conversion cost*, never at a market rate.
public enum ForecastEngine {

    // MARK: - Entry point

    public static func run(_ request: ForecastRequest) throws -> ForecastResult {
        try validate(request)

        let policy = request.policy ?? request.scenario.defaultPolicy
        let poolCurrency = request.spendablePoolRequirement.currency

        // 1. Expand income sources under the scenario policy.
        //    - Certainty is the *effective* certainty after `dependsOn`
        //      propagation (a grant depending on an unsigned job is only as
        //      certain as the job).
        //    - Zero-amount streams are tracked structures, not resources:
        //      they contribute no events and no list entries (electricity at
        //      €0 while the chèque énergie covers it, a €0 job target).
        var includedIncome: [String] = []
        var excludedIncome: [String] = []
        var creditEvents: [ForecastEvent] = []
        for source in request.incomeSources.sorted(by: { $0.id < $1.id }) {
            guard source.amount.minorUnits > 0 else { continue }
            let occurrences = source.schedule.occurrences(from: request.startDate, to: request.endDate)
            guard !occurrences.isEmpty else { continue }
            let effectiveCertainty = source.effectiveCertainty(in: request.incomeSources)
            if policy.includes(effectiveCertainty) {
                includedIncome.append(source.id)
                let accountID = try landingAccount(for: source, in: request)
                for day in occurrences {
                    creditEvents.append(
                        ForecastEvent(
                            id: "inc-\(source.id)-\(day.isoString)",
                            day: day,
                            phase: .credit,
                            effect: .credit(source.amount, toAccount: accountID),
                            sourceRef: source.id,
                            certainty: effectiveCertainty
                        )
                    )
                }
            } else {
                excludedIncome.append(source.id)
            }
        }

        // 2. Expand budget envelopes into daily spending events. A line is a
        //    gross envelope, so only what is left inside it after its own
        //    committed charges is spread.
        let variableEvents = VariableSpendingPlanner.events(
            budgets: request.budgets,
            committedByBudgetMonth: request.committedByBudgetMonth,
            from: request.startDate,
            to: request.endDate
        )

        // 3. Total deterministic order (events outside the horizon are dropped).
        let allEvents = (request.events + creditEvents + variableEvents)
            .filter { $0.day >= request.startDate && $0.day <= request.endDate }
        let ordered = allEvents.sorted { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            if lhs.phase != rhs.phase { return lhs.phase < rhs.phase }
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.id < rhs.id
        }

        // 4. Simulate.
        var balances = request.startingBalances
        var daily: [ForecastResult.DayBalance] = []
        var settlementFailures: [ForecastResult.SettlementFailure] = []

        // Baseline: the starting pool itself is a balance the forecast must
        // not ignore (a negative or floor-breaching start is already a fact).
        var minimumPool = spendablePool(balances: balances, request: request)
        var minimumPoolDay: Day? = request.startDate
        var firstNegative: Day?
        var firstNegativeEvent: ForecastEvent?
        var firstBelowFloor: Day?
        var firstBelowFloorEvent: ForecastEvent?
        let floor = request.safetyFloor?.minorUnits
        var minimumBelowFloorReached: Int64 = 0 // deepest gap under the floor, in minor units (≤ 0)
        // How much was missing when each risk was first reached. Captured here,
        // at detection, so the amount and the day can never come from different
        // computations later on.
        var firstNegativeShortfall: Int64 = 0
        var firstBelowFloorShortfall: Int64 = 0
        if minimumPool.minorUnits < 0 {
            firstNegative = request.startDate
            firstNegativeShortfall = -minimumPool.minorUnits
        }
        if let floor, minimumPool.minorUnits < floor {
            firstBelowFloor = request.startDate
            firstBelowFloorShortfall = floor - minimumPool.minorUnits
            minimumBelowFloorReached = minimumPool.minorUnits - floor
        }

        // Per month, the pool movement of every event, partitioned by phase so a
        // month summary can be stated as a ledger that actually adds up.
        var monthIncome: [MonthKey: Int64] = [:]
        var monthCommitted: [MonthKey: Int64] = [:]
        var monthEveryday: [MonthKey: Int64] = [:]

        var eventIndex = 0
        var currentDay = request.startDate
        while currentDay <= request.endDate {
            // Apply this day's events in order.
            while eventIndex < ordered.count, ordered[eventIndex].day == currentDay {
                let event = ordered[eventIndex]
                eventIndex += 1
                let poolBeforeEvent = spendablePool(balances: balances, request: request).minorUnits
                switch event.effect {
                case let .credit(amount, accountID):
                    balances[accountID, default: poolMoney(0, balancesCurrency(of: accountID, in: request))] =
                        balances[accountID, default: poolMoney(0, balancesCurrency(of: accountID, in: request))] + amount

                case let .debit(amount, requirement):
                    if let failure = try applyDebit(
                        amount, requirement: requirement, event: event,
                        balances: &balances, request: request
                    ) {
                        settlementFailures.append(failure)
                    }

                case let .directedDebit(amount, accountID):
                    let currency = balancesCurrency(of: accountID, in: request)
                    balances[accountID, default: poolMoney(0, currency)] =
                        balances[accountID, default: poolMoney(0, currency)] - amount
                }

                // Post-event pool accounting.
                let pool = spendablePool(balances: balances, request: request)

                // The event's effect on the pool, attributed to its phase. The
                // three buckets cover every phase, so they sum to the whole
                // change in the pool and nothing moves cash unaccounted for.
                let poolDelta = pool.minorUnits - poolBeforeEvent
                let month = currentDay.monthKey
                switch event.phase {
                case .scheduledDebit: monthCommitted[month, default: 0] -= poolDelta
                case .variableSpending: monthEveryday[month, default: 0] -= poolDelta
                case .credit, .relocation, .dependentDisposal: monthIncome[month, default: 0] += poolDelta
                }

                if pool.minorUnits < minimumPool.minorUnits {
                    minimumPool = pool
                    minimumPoolDay = currentDay
                }
                if firstNegative == nil, pool.minorUnits < 0 {
                    firstNegative = currentDay
                    firstNegativeEvent = event
                    // A payment that could not be settled names its own gap:
                    // that is the money its eligible accounts could not find,
                    // and the fact a person can act on. Without one, the gap is
                    // how far the pool itself went under.
                    let unsettled = settlementFailures.last.flatMap {
                        $0.eventID == event.id && $0.unsettled.currency == poolCurrency
                            ? $0.unsettled.minorUnits : nil
                    }
                    firstNegativeShortfall = unsettled ?? -pool.minorUnits
                }
                if let floor, firstBelowFloor == nil, pool.minorUnits < floor {
                    firstBelowFloor = currentDay
                    firstBelowFloorEvent = event
                    firstBelowFloorShortfall = floor - pool.minorUnits
                }
                if let floor {
                    let gap = pool.minorUnits - floor // how far under the floor we are (negative = under)
                    if gap < minimumBelowFloorReached { minimumBelowFloorReached = gap }
                }
            }

            daily.append(
                ForecastResult.DayBalance(
                    day: currentDay,
                    endOfDay: balances,
                    spendablePool: spendablePool(balances: balances, request: request),
                    otherTrackedEUR: otherTrackedEUR(balances: balances, request: request),
                    trackedLiquidityEUR: spendablePool(balances: balances, request: request) + otherTrackedEUR(balances: balances, request: request)
                )
            )
            // The horizon's final day has been produced. Advancing once more
            // would ask for a day beyond it that the result does not need.
            if currentDay == request.endDate { break }
            guard let following = currentDay.advanced(by: 1) else {
                throw ForecastError.dateArithmeticOutOfRange
            }
            currentDay = following
        }

        let last = daily.last!
        let bridge = minimumPool.isNegative ? minimumPool.negated : poolMoney(0, poolCurrency)
        var floorBridge = poolMoney(0, poolCurrency)
        if request.safetyFloor != nil, minimumBelowFloorReached < 0 {
            floorBridge = Money(minorUnits: Int64(-minimumBelowFloorReached), currency: poolCurrency)
        }

        // Product-shaped read-outs (port E).
        // Runway is a stated count of days, so it is exact or it is refused.
        // Reporting a truncated or wrapped runway would be a financial claim
        // the arithmetic did not support. `validate` already established that
        // the horizon's own span is expressible, and every day reached lies
        // inside it, so neither branch can fail once the walk has run.
        let cashRunwayDays: Int
        if let firstNegative {
            guard let days = request.startDate.days(until: firstNegative) else {
                throw ForecastError.dateArithmeticOutOfRange
            }
            cashRunwayDays = days
        } else {
            guard let span = request.startDate.days(until: request.endDate),
                  case let (inclusive, overflow) = span.addingReportingOverflow(1), !overflow
            else {
                throw ForecastError.dateArithmeticOutOfRange
            }
            cashRunwayDays = inclusive
        }

        var projectedMonthEnd: [MonthKey: Money] = [:]
        for entry in daily {
            projectedMonthEnd[entry.day.monthKey] = entry.spendablePool // ascending days → last write wins per month
        }

        // Per month, per currency: mixing an EUR failure with an MAD failure
        // in the same month must never add (never trap, never convert) — the
        // bag keeps each currency's deficit exact and separate.
        var unfundedByMonth: [MonthKey: MoneyBag] = [:]
        for failure in settlementFailures {
            unfundedByMonth[failure.day.monthKey, default: MoneyBag()].add(failure.unsettled)
        }

        let firstRisk = Self.firstRisk(
            negativeDay: firstNegative, negativeEvent: firstNegativeEvent,
            negativeShortfall: firstNegativeShortfall,
            floorDay: firstBelowFloor, floorEvent: firstBelowFloorEvent,
            floorShortfall: firstBelowFloorShortfall,
            poolCurrency: poolCurrency
        )

        // One ledger per month, chained: each month opens where the previous one
        // closed, and the first opens on the pool the run started from.
        var monthLedgers: [MonthKey: ForecastResult.MonthLedger] = [:]
        var openingPool = spendablePool(balances: request.startingBalances, request: request)
        for month in projectedMonthEnd.keys.sorted() {
            let closing = projectedMonthEnd[month] ?? openingPool
            monthLedgers[month] = ForecastResult.MonthLedger(
                month: month,
                opening: openingPool,
                income: Money(minorUnits: monthIncome[month] ?? 0, currency: poolCurrency),
                committed: Money(minorUnits: monthCommitted[month] ?? 0, currency: poolCurrency),
                everyday: Money(minorUnits: monthEveryday[month] ?? 0, currency: poolCurrency),
                closing: closing
            )
            openingPool = closing
        }

        return ForecastResult(
            scenario: request.scenario,
            startDate: request.startDate,
            endDate: request.endDate,
            dailyBalances: daily,
            projectedEndBalance: last.spendablePool,
            projectedEndTrackedLiquidityEUR: last.trackedLiquidityEUR,
            lowestBalance: minimumPool,
            lowestBalanceDate: minimumPoolDay,
            firstNegativeDate: firstNegative,
            minimumBridgeRequired: bridge,
            firstBelowSafetyFloorDate: firstBelowFloor,
            minimumBridgeForSafetyFloor: floorBridge,
            includedIncomeEventIDs: includedIncome,
            excludedIncomeEventIDs: excludedIncome,
            settlementFailures: settlementFailures,
            appliedEvents: ordered,
            cashRunwayDays: cashRunwayDays,
            projectedMonthEnd: projectedMonthEnd,
            firstRisk: firstRisk,
            unfundedByMonth: unfundedByMonth,
            monthLedgers: monthLedgers
        )
    }

    // MARK: - Internals

    /// Chooses the product-facing first risk: earliest day wins; a pool
    /// deficit beats a floor breach on the same day (going negative is the
    /// stronger statement). A negative/floor-breaching **opening** balance is
    /// itself the first risk, attributed to the opening balance.
    static func firstRisk(
        negativeDay: Day?, negativeEvent: ForecastEvent?, negativeShortfall: Int64,
        floorDay: Day?, floorEvent: ForecastEvent?, floorShortfall: Int64,
        poolCurrency: Currency
    ) -> ForecastResult.FirstRisk? {
        typealias Candidate = (Day, ForecastEvent?, ForecastResult.FirstRisk.Kind, Int64)
        let negative: Candidate? = negativeDay.map { ($0, negativeEvent, .poolDeficit, negativeShortfall) }
        let floorBreach: Candidate? = floorDay.map { ($0, floorEvent, .belowSafetyFloor, floorShortfall) }
        let chosen: Candidate
        switch (negative, floorBreach) {
        case let (n?, f?):
            chosen = n.0 <= f.0 ? n : f
        case let (n?, nil): chosen = n
        case let (nil, f?): chosen = f
        case (nil, nil): return nil
        }
        let event = chosen.1
        return ForecastResult.FirstRisk(
            day: chosen.0,
            kind: chosen.2,
            triggerEventID: event?.id ?? "opening-balance",
            triggerLabel: event?.sourceRef ?? event?.id ?? "opening balance",
            shortfall: Money(minorUnits: chosen.3, currency: poolCurrency)
        )
    }

    /// Draws `amount` from accounts satisfying the requirement, in
    /// `(drawOrder, id)` order.
    ///
    /// Settlement (defect D4): the payment settles from the **positive**
    /// balances of eligible accounts. `settled = min(requested, Σ positive)`;
    /// when that is below the request, a `SettlementFailure` is returned
    /// describing exactly what was asked, what was covered, and which
    /// accounts were consulted. The remainder is applied to the first
    /// eligible account as a negative balance (overdraft/bounce modelling) —
    /// never to ineligible money.
    private static func applyDebit(
        _ amount: Money,
        requirement: PaymentRequirement,
        event: ForecastEvent,
        balances: inout [String: Money],
        request: ForecastRequest
    ) throws -> ForecastResult.SettlementFailure? {
        let eligible = request.accounts
            .filter { $0.isActive && $0.satisfies(requirement) }
            .sorted { ($0.drawOrder, $0.id) < ($1.drawOrder, $1.id) }
        guard !eligible.isEmpty else {
            throw ForecastError.noEligibleAccount(eventID: event.id, requirement: "\(requirement.currency.code)/\(requirement.acceptableRails.map(\.id).sorted().joined(separator: "+"))")
        }

        // Only positive balances can settle a payment; a negative sibling
        // never turns a settled payment into a failure.
        let positiveAvailable = eligible.reduce(Int64(0)) { $0 + max(balances[$1.id]?.minorUnits ?? 0, 0) }
        let settledMinor = min(amount.minorUnits, positiveAvailable)

        var failure: ForecastResult.SettlementFailure?
        if settledMinor < amount.minorUnits {
            failure = ForecastResult.SettlementFailure(
                eventID: event.id,
                day: event.day,
                requested: amount,
                settled: Money(minorUnits: settledMinor, currency: amount.currency),
                unsettled: Money(minorUnits: amount.minorUnits - settledMinor, currency: amount.currency),
                eligibleAccountIDs: eligible.map(\.id),
                requirement: requirement
            )
        }

        var remaining = amount.minorUnits
        for account in eligible where remaining > 0 {
            let balance = balances[account.id] ?? poolMoney(0, account.currency)
            let take = min(max(balance.minorUnits, 0), remaining)
            balances[account.id] = Money(minorUnits: balance.minorUnits - take, currency: account.currency)
            remaining -= take
        }
        // Anything still remaining lands on the first eligible account as a
        // negative balance. It is never charged to ineligible money.
        if remaining > 0 {
            let first = eligible[0]
            let balance = balances[first.id] ?? poolMoney(0, first.currency)
            balances[first.id] = Money(minorUnits: balance.minorUnits - remaining, currency: first.currency)
        }
        return failure
    }

    static func landingAccount(for source: IncomeSource, in request: ForecastRequest) throws -> String {
        if let specified = source.arrivesOnAccount {
            guard request.accounts.contains(where: {
                $0.id == specified && $0.isActive && $0.currency == source.amount.currency
            }) else {
                throw ForecastError.invalidIncomeAccount(sourceID: source.id, accountID: specified)
            }
            return specified
        }
        // Prefer an account that can receive this source's own currency.
        let eligible = request.accounts.filter {
            $0.isActive && $0.currency == source.amount.currency
        }
        let preferred = eligible
            .filter({ $0.kind != .cash })
            .sorted { ($0.drawOrder, $0.id) < ($1.drawOrder, $1.id) }
            .first
        let fallback = eligible.sorted { ($0.drawOrder, $0.id) < ($1.drawOrder, $1.id) }.first
        guard let chosen = preferred ?? fallback else {
            throw ForecastError.noIncomeAccount(sourceID: source.id)
        }
        return chosen.id
    }

    static func spendablePool(balances: [String: Money], request: ForecastRequest) -> Money {
        let currency = request.spendablePoolRequirement.currency
        var total: Int64 = 0
        for account in request.accounts where account.isActive && account.satisfies(request.spendablePoolRequirement) {
            total += balances[account.id]?.minorUnits ?? 0
        }
        return Money(minorUnits: total, currency: currency)
    }

    /// EUR value of holdings outside the spendable pool: EUR balances of
    /// ineligible accounts plus the *carried* (observed-cost) value of
    /// foreign-currency holdings. Never a market estimate.
    static func otherTrackedEUR(balances: [String: Money], request: ForecastRequest) -> Money {
        var total: Int64 = 0
        for account in request.accounts where account.isActive {
            let inPool = account.satisfies(request.spendablePoolRequirement)
            let balance = balances[account.id] ?? Money(minorUnits: 0, currency: account.currency)
            if account.currency == .eur {
                if !inPool { total += balance.minorUnits }
            } else if let carried = request.carriedEURValues[account.id] {
                total += carried.minorUnits
            }
        }
        return Money(minorUnits: total, currency: .eur)
    }

    static func poolMoney(_ minorUnits: Int64, _ currency: Currency) -> Money {
        Money(minorUnits: minorUnits, currency: currency)
    }

    static func balancesCurrency(of accountID: String, in request: ForecastRequest) -> Currency {
        request.accounts.first { $0.id == accountID }?.currency ?? .eur
    }

    /// Constant-time preflight shared with callers that expand the horizon
    /// before assembling a ForecastRequest.
    static func validateHorizon(start: Day, end: Day) throws {
        guard start <= end else { throw ForecastError.emptyHorizon }
        guard let span = start.days(until: end),
              case let (inclusive, overflow) = span.addingReportingOverflow(1), !overflow,
              inclusive > 0
        else { throw ForecastError.dateArithmeticOutOfRange }
    }

    static func validate(_ request: ForecastRequest) throws {
        try validateHorizon(start: request.startDate, end: request.endDate)
        let ids = Set(request.accounts.map(\.id))
        for (accountID, balance) in request.startingBalances {
            guard ids.contains(accountID) else { throw ForecastError.missingBalance(accountID: accountID) }
            guard let account = request.accounts.first(where: { $0.id == accountID }) else { continue }
            guard account.currency == balance.currency else {
                throw ForecastError.balanceCurrencyMismatch(accountID: accountID, expected: account.currency.code, got: balance.currency.code)
            }
        }
        for account in request.accounts where account.isActive {
            guard request.startingBalances[account.id] != nil else {
                throw ForecastError.missingBalance(accountID: account.id)
            }
        }
        if let floor = request.safetyFloor {
            guard floor.currency == request.spendablePoolRequirement.currency else {
                throw ForecastError.safetyFloorCurrencyMismatch(expected: request.spendablePoolRequirement.currency.code, got: floor.currency.code)
            }
        }
        var seen = Set<String>()
        for event in request.events {
            if !seen.insert(event.id).inserted { throw ForecastError.duplicateEventID(event.id) }
            switch event.effect {
            case let .credit(_, accountID), let .directedDebit(_, accountID):
                guard ids.contains(accountID) else {
                    throw ForecastError.unknownEventAccount(eventID: event.id, accountID: accountID)
                }
            case let .debit(amount, requirement):
                guard amount.currency == requirement.currency else {
                    throw ForecastError.eventCurrencyMismatch(eventID: event.id, expected: requirement.currency.code, got: amount.currency.code)
                }
            }
        }
    }
}
