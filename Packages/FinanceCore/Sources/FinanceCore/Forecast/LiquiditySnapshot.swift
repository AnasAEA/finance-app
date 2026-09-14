/// Presentation-friendly read-outs over a document + forecast result.
///
/// The UI consumes these; it never needs to understand legs, provenance or
/// forensic internals.
public struct LiquiditySnapshot: Hashable, Sendable {

    /// One physical holding outside the bank rails.
    public struct PhysicalHolding: Hashable, Sendable {
        public let accountID: String
        public let name: String
        public let amount: Money
        /// Carried EUR value at the observed conversion cost (never a market
        /// estimate). nil for EUR cash (no FX involved) and when none was
        /// supplied.
        public let carriedEUR: Money?
    }

    /// What "safe to spend" is, honestly (port E): both the raw signed
    /// headroom and the display-safe clamped amount. A deficit is never
    /// hidden just because the headline is non-negative — the UI can (and
    /// should) render `rawHeadroom` when it is negative.
    public struct SafeToSpendResult: Hashable, Sendable {
        /// Display-safe amount: `max(rawHeadroom, 0)`.
        public let amount: Money
        /// Signed truth: positive = headroom, negative = deficit.
        public let rawHeadroom: Money
        /// `rawHeadroom` spread over the horizon window (rounded down);
        /// nil when there is no positive headroom to spread.
        public let dailyAmount: Money?
        /// What this number is: e.g. "account liquidity − committed outflows
        /// (next 30 days)".
        public let basis: String
        /// The window the figure was computed over, in days.
        ///
        /// Carried as a number rather than left inside `basis` so that a
        /// sentence about this deficit can name its own horizon instead of
        /// borrowing a date from the forecast, which runs over a longer one.
        public let horizonDays: Int
        /// The first day a committed constraint bites (first risk day).
        public let firstConstraint: Day?

        public var isDeficit: Bool { rawHeadroom.isNegative }
    }

    /// Money on bank/wallet accounts that can actually pay euro obligations —
    /// electronically spendable EUR liquidity only (defect D2).
    public let financialAccountLiquidity: Money

    /// Physical holdings (cash pockets), separate from account cash —
    /// **per currency**, never collapsed.
    public let physicalCashByCurrency: MoneyBag

    /// Display list of the physical holdings (names + carried EUR values).
    public let physicalHoldings: [PhysicalHolding]

    /// Everything tracked, by currency: financial accounts + physical cash.
    /// EUR and MAD entries sit next to each other and are never summed —
    /// `totalTrackedHoldings.amount(in: .mad)` stays dirhams (defect D2).
    public let totalTrackedHoldings: MoneyBag

    /// The EUR-only liquidity view: financial accounts + EUR pocket cash +
    /// foreign cash **at its observed carried cost** (never a market rate).
    /// This is the number that can be compared with euro obligations — with
    /// the explicit caveat that carried foreign value is not spendable EUR.
    public let trackedEURLiquidity: Money

    /// Spendable-pool-relevant committed outflows over the next
    /// `horizonDays` days: economic + financing commitments only.
    /// **Relocations and disposals never count** (defect D1) — moving value
    /// between owned accounts, withdrawing cash, or remitting somebody
    /// else's pass-through share is not consumption and does not reduce what
    /// is safe to spend. Variable budget spending is also *not* subtracted —
    /// it is what the user is choosing to spend.
    public let committedOutflowsNext: Money

    /// Account-balance movements that are **not** commitments: internal
    /// transfers, withdrawals/deposits, disposals. Surfaced so the UI can
    /// show "your bank balance will also drop by X on day Y because of a
    /// transfer/withdrawal" without confusing it with spending.
    public let railRelocations: [ForecastEvent]

    /// The honest safe-to-spend read-out (see `SafeToSpendResult`).
    public let safeToSpend: SafeToSpendResult

    /// Next scheduled events in application order.
    public let upcoming: [ForecastEvent]

    /// First day the spendable pool goes negative, if any.
    public let firstRiskDate: Day?

    /// The bridge that would be needed to avoid that risk.
    public let minimumBridge: Money

    /// First day below the safety floor, if supplied and breached.
    public let firstBelowFloorDate: Day?
}

public enum FinanceOverview {

    /// Builds the Home-screen snapshot.
    ///
    /// - Parameters:
    ///   - document: the interchange document (accounts + balances).
    ///   - result: a forecast run over a horizon (e.g. 30–90 days).
    ///   - today: the day the snapshot is taken for.
    ///   - horizonDays: window for "committed outflows" (default 30).
    public static func snapshot(
        document: FinanceDocument,
        result: ForecastResult,
        today: Day,
        horizonDays: Int = 30
    ) -> LiquiditySnapshot {
        let accountsByID = Dictionary(document.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let currentBalances = CurrentHoldings.overlayBalances(in: document, asOf: today)

        // Defect D2: holdings are counted per currency and by account kind,
        // never dropped and never silently converted.
        var accountLiquidity: Int64 = 0        // electronically spendable EUR
        var accountBag = MoneyBag.empty       // every non-cash account balance
        var cashBag = MoneyBag.empty          // every cash pocket balance
        var holdings: [LiquiditySnapshot.PhysicalHolding] = []
        var carriedTotal: Int64 = 0
        var eurPocketCash: Int64 = 0
        for balance in currentBalances {
            guard let account = accountsByID[balance.accountID] else { continue }
            if account.kind == .cash {
                cashBag.add(balance.balance)
                if balance.balance.currency == .eur {
                    eurPocketCash += balance.balance.minorUnits
                } else if let carried = document.planning.carriedEURValues[balance.accountID] {
                    carriedTotal += carried.minorUnits
                }
                holdings.append(
                    LiquiditySnapshot.PhysicalHolding(
                        accountID: account.id,
                        name: account.name,
                        amount: balance.balance,
                        carriedEUR: document.planning.carriedEURValues[balance.accountID]
                    )
                )
            } else {
                accountBag.add(balance.balance)
                if account.currency == .eur {
                    accountLiquidity += balance.balance.minorUnits
                }
            }
        }
        holdings.sort { $0.accountID < $1.accountID }

        var committed: Int64 = 0
        var relocations: [ForecastEvent] = []
        var upcoming: [ForecastEvent] = []
        for event in result.appliedEvents {
            // The committed-outflow window is a bounded distance from `today`,
            // asked as one: it needs no horizon day to exist, and a separation
            // too large to express is outside the window rather than a crash.
            guard event.day >= today, today.isWithin(days: horizonDays, of: event.day) else { continue }
            upcoming.append(event)
            // Rail movements first: both legs of a relocation (the credit that
            // arrives at the destination is part of the movement too) and any
            // disposal.
            if event.phase == .relocation
                || event.outflowSemantics == .relocation || event.outflowSemantics == .disposal {
                relocations.append(event)
            }
            // Defect D1: only economic and financing commitments reduce what
            // is safe to spend; relocations and disposals never do.
            guard event.isOutflow, event.isCommittedOutflow, event.phase == .scheduledDebit else { continue }
            switch event.effect {
            case let .debit(amount, _), let .directedDebit(amount, _):
                if amount.currency == .eur { committed += amount.minorUnits }
            case .credit:
                break
            }
        }

        let available = Money(minorUnits: accountLiquidity, currency: .eur)
        let committedMoney = Money(minorUnits: committed, currency: .eur)
        let rawHeadroom = Money(minorUnits: accountLiquidity - committed, currency: .eur)
        let dailyAmount = rawHeadroom.isPositive
            ? rawHeadroom.divided(by: Int64(max(horizonDays, 1)), rule: .down)
            : nil

        return LiquiditySnapshot(
            financialAccountLiquidity: available,
            physicalCashByCurrency: cashBag,
            physicalHoldings: holdings,
            totalTrackedHoldings: accountBag + cashBag,
            trackedEURLiquidity: Money(minorUnits: accountLiquidity + eurPocketCash + carriedTotal, currency: .eur),
            committedOutflowsNext: committedMoney,
            railRelocations: relocations,
            safeToSpend: LiquiditySnapshot.SafeToSpendResult(
                amount: rawHeadroom.isNegative ? Money(minorUnits: 0, currency: .eur) : rawHeadroom,
                rawHeadroom: rawHeadroom,
                dailyAmount: dailyAmount,
                basis: "account liquidity − committed outflows (next \(horizonDays) days)",
                horizonDays: horizonDays,
                firstConstraint: result.firstRisk?.day
            ),
            upcoming: upcoming,
            firstRiskDate: result.firstNegativeDate,
            minimumBridge: result.minimumBridgeRequired,
            firstBelowFloorDate: result.firstBelowSafetyFloorDate
        )
    }

    /// End-of-month spendable pool for a given month, from a forecast result.
    public static func monthEndPool(_ month: MonthKey, in result: ForecastResult) -> Money? {
        result.monthEndPool(month)
    }
}
