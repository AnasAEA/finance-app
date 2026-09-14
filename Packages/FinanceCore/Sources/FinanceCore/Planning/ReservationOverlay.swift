/// One earmark the affordability engine must honour.
///
/// A reservation is not spending. It does not create a transaction, does not
/// consume the economic-spending ceiling, and does not rewrite ledger
/// balances. It only reduces *available* cash in an affordability run.
public struct ReservationPosition: Hashable, Sendable {

    public enum SourceKind: String, Sendable {
        case plannedPurchase
        case sinkingFund
    }

    public let sourceID: String
    public let sourceKind: SourceKind
    public let amount: Money
    public let custody: SinkingFundCustody

    public init(
        sourceID: String,
        sourceKind: SourceKind,
        amount: Money,
        custody: SinkingFundCustody
    ) {
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.amount = amount
        self.custody = custody
    }
}

/// Where one reservation actually withheld cash, so a funded purchase can
/// release the same accounts rather than inventing a transfer.
public struct ReservationDraw: Hashable, Sendable {
    public let sourceID: String
    public let accountID: String
    public let amount: Money

    public init(sourceID: String, accountID: String, amount: Money) {
        self.sourceID = sourceID
        self.accountID = accountID
        self.amount = amount
    }
}

/// Result of applying reservations to a *copy* of starting balances.
///
/// `availableBalances` is what an affordability forecast may spend. Ledger
/// balances are untouched: account balance is not safe-to-spend, and this
/// overlay is not Home `safeToSpend`.
public struct ReservationApplication: Hashable, Sendable {

    public let availableBalances: [String: Money]
    /// Successfully withheld, per currency. Never converted.
    public let reserved: MoneyBag
    /// Asked-for reservation that positive eligible balances could not cover.
    public let overReserved: MoneyBag
    /// Per-source draws, in application order, so a later consumption can
    /// reverse the same accounts.
    public let draws: [ReservationDraw]

    public init(
        availableBalances: [String: Money],
        reserved: MoneyBag,
        overReserved: MoneyBag,
        draws: [ReservationDraw]
    ) {
        self.availableBalances = availableBalances
        self.reserved = reserved
        self.overReserved = overReserved
        self.draws = draws
    }

    public func reservedAmount(sourceID: String, currency: Currency) -> Money {
        let total = draws
            .filter { $0.sourceID == sourceID && $0.amount.currency == currency }
            .reduce(Int64(0)) { $0 + $1.amount.minorUnits }
        return Money(minorUnits: total, currency: currency)
    }
}

/// Pure reservation math. Deterministic: positions apply in `sourceID` order.
public enum ReservationOverlay {

    /// Active earmarks. A sinking-funded goal does not also carry its own
    /// `reservedAmount` — the fund owns the reservation.
    public static func positions(
        purchases: [PlannedPurchase],
        funds: [SinkingFund]
    ) -> [ReservationPosition] {
        var result: [ReservationPosition] = []
        let reserving = funds.filter(\.isReserving)
        let fundIDs = Set(reserving.map(\.id))
        let fundsByGoal = Dictionary(
            reserving.compactMap { fund -> (String, String)? in
                fund.goalID.map { ($0, fund.id) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        for fund in reserving {
            result.append(
                ReservationPosition(
                    sourceID: fund.id,
                    sourceKind: .sinkingFund,
                    amount: fund.reservedAmount,
                    custody: fund.custody
                )
            )
        }

        for purchase in purchases {
            let own = purchase.ownReservation
            guard own.isPositive else { continue }
            if case let .sinkingFund(id) = purchase.funding, fundIDs.contains(id) {
                continue
            }
            if let goalFund = fundsByGoal[purchase.id], fundIDs.contains(goalFund) {
                continue
            }
            result.append(
                ReservationPosition(
                    sourceID: purchase.id,
                    sourceKind: .plannedPurchase,
                    amount: own,
                    custody: .virtualReservation
                )
            )
        }

        return result.sorted { $0.sourceID < $1.sourceID }
    }

    /// Withhold reserved money from a copy of ledger balances.
    ///
    /// Virtual EUR earmarks draw from spendable-pool accounts in
    /// `(drawOrder, id)` order. Dedicated accounts are charged only
    /// themselves — never also overlaid on the rest of the pool.
    /// Foreign-currency virtual earmarks draw only from accounts in that
    /// currency. Nothing is converted to cover a shortfall.
    public static func apply(
        positions: [ReservationPosition],
        to balances: [String: Money],
        accounts: [Account],
        poolRequirement: PaymentRequirement
    ) -> ReservationApplication {
        var available = balances
        var reserved = MoneyBag()
        var overReserved = MoneyBag()
        var draws: [ReservationDraw] = []
        let accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for position in positions.sorted(by: { $0.sourceID < $1.sourceID }) {
            let amount = position.amount
            guard amount.isPositive else { continue }
            let targets: [Account]
            switch position.custody {
            case .virtualReservation:
                if amount.currency == poolRequirement.currency {
                    targets = accounts
                        .filter { $0.satisfies(poolRequirement) }
                        .sorted { ($0.drawOrder, $0.id) < ($1.drawOrder, $1.id) }
                } else {
                    targets = accounts
                        .filter { $0.isActive && $0.currency == amount.currency }
                        .sorted { ($0.drawOrder, $0.id) < ($1.drawOrder, $1.id) }
                }
            case let .dedicatedAccount(accountID):
                if let account = accountsByID[accountID], account.currency == amount.currency {
                    targets = [account]
                } else {
                    targets = []
                }
            }

            var remaining = amount.minorUnits
            for account in targets where remaining > 0 {
                let current = available[account.id] ?? Money(minorUnits: 0, currency: account.currency)
                let take = min(max(current.minorUnits, 0), remaining)
                guard take > 0 else { continue }
                available[account.id] = Money(minorUnits: current.minorUnits - take, currency: account.currency)
                remaining -= take
                draws.append(
                    ReservationDraw(
                        sourceID: position.sourceID,
                        accountID: account.id,
                        amount: Money(minorUnits: take, currency: amount.currency)
                    )
                )
            }
            let withheld = amount.minorUnits - remaining
            if withheld > 0 {
                reserved.add(Money(minorUnits: withheld, currency: amount.currency))
            }
            if remaining > 0 {
                overReserved.add(Money(minorUnits: remaining, currency: amount.currency))
            }
        }

        return ReservationApplication(
            availableBalances: available,
            reserved: reserved,
            overReserved: overReserved,
            draws: draws
        )
    }

    /// The prefix of `draws` for `sourceID` totalling at most `limit`.
    /// Used to release a sinking-funded purchase without inventing a transfer.
    public static func consumptionDraws(
        from draws: [ReservationDraw],
        sourceID: String,
        limit: Money
    ) -> [ReservationDraw] {
        var remaining = limit.minorUnits
        var result: [ReservationDraw] = []
        for draw in draws where draw.sourceID == sourceID && remaining > 0 {
            guard draw.amount.currency == limit.currency else { continue }
            let take = min(draw.amount.minorUnits, remaining)
            guard take > 0 else { continue }
            result.append(
                ReservationDraw(
                    sourceID: sourceID,
                    accountID: draw.accountID,
                    amount: Money(minorUnits: take, currency: limit.currency)
                )
            )
            remaining -= take
        }
        return result
    }
}
