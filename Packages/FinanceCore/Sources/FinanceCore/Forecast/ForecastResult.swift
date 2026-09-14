/// The outcome of one forecast run.
public struct ForecastResult: Hashable, Sendable {

    public struct DayBalance: Hashable, Sendable {
        public let day: Day
        /// End-of-day balances per account.
        public let endOfDay: [String: Money]
        /// The spendable euro pool at end of day (see request definition).
        public let spendablePool: Money
        /// EUR balance of spendable-ineligible accounts (e.g. a euro cash
        /// pocket) plus carried EUR values of foreign-currency holdings.
        public let otherTrackedEUR: Money
        /// spendablePool + otherTrackedEUR.
        public let trackedLiquidityEUR: Money
    }

    /// **PAYMENT_SETTLEMENT_FAILURE** (defect D4): this specific event could
    /// not be fully settled from accounts eligible for its requirement
    /// (right currency, right rail, active) at the moment it came due.
    ///
    /// This is a fact about *the payment*, and it is deliberately **not** the
    /// same fact as the pool being negative: a €6.13 card debit paid in full
    /// from Revolut while the aggregate euro pool is already negative is
    /// **settled** — it is never labelled a bounced payment here. Pool
    /// weakness is reported separately (see `firstNegativeDate`,
    /// `lowestBalance`, `firstRisk`).
    public struct SettlementFailure: Hashable, Sendable {
        public let eventID: String
        public let day: Day
        /// What the payment asked for.
        public let requested: Money
        /// What eligible liquidity could actually cover (≥ 0; negative
        /// balances contribute nothing).
        public let settled: Money
        /// requested − settled. Positive.
        public let unsettled: Money
        /// The accounts that were eligible for this payment's requirement,
        /// in draw order (the rails/currency that were consulted).
        public let eligibleAccountIDs: [String]
        public let requirement: PaymentRequirement
    }

    /// The first risk the projection surfaces, product-shaped (port E).
    public struct FirstRisk: Hashable, Sendable {
        public enum Kind: String, Sendable {
            /// The spendable pool went below zero after this event.
            case poolDeficit
            /// The pool fell strictly below the safety floor after this event
            /// (without necessarily going negative).
            case belowSafetyFloor
        }

        public let day: Day
        public let kind: Kind
        /// The event whose application first crossed the line.
        public let triggerEventID: String
        /// Human-readable trigger label (`sourceRef` when available, else the
        /// event id) — e.g. `"ob-rent"`.
        public let triggerLabel: String

        /// How much was missing at the moment this risk was reached, in the
        /// pool currency.
        ///
        /// It lives here, beside `day`, so that a sentence naming an amount and
        /// a date cannot take the two from different computations over different
        /// horizons. Whoever says "short by" must say "by when" from this same
        /// object.
        ///
        /// For a pool deficit triggered by a payment that could not be settled,
        /// this is that payment's unsettled remainder — the money its own
        /// eligible accounts could not find, which is the fact a person can act
        /// on. Otherwise it is the gap itself: how far below zero the pool went,
        /// or how far below the safety floor.
        public let shortfall: Money
    }

    /// Every euro that moved through the spendable pool in one month, grouped
    /// so that a ledger-style summary adds up — exactly, to the cent:
    ///
    /// ```
    /// opening + income − committed − everyday == closing
    /// ```
    ///
    /// The four groups partition *every* pool movement of the month, which is
    /// the whole point: a summary built from these cannot hide a phase that
    /// also moves cash. Movements that do not touch the pool (a credit to a
    /// cash pocket, a charge in another currency) contribute zero and are
    /// therefore never guessed at or converted.
    public struct MonthLedger: Hashable, Sendable {
        public let month: MonthKey
        /// Pool at the opening of the month's first day inside the horizon.
        public let opening: Money
        /// Net of everything that is not a scheduled charge or everyday
        /// spending: income arriving, money moved between own accounts, and
        /// shares handed on to someone else. Net, so a pass-through that lands
        /// gross and hands most of it back contributes only what was kept.
        public let income: Money
        /// Scheduled, committed charges — the `.scheduledDebit` phase.
        public let committed: Money
        /// Everyday spending planned out of budget envelopes — the
        /// `.variableSpending` phase.
        public let everyday: Money
        /// Pool at the close of the month's last day inside the horizon.
        public let closing: Money

        public init(month: MonthKey, opening: Money, income: Money,
                    committed: Money, everyday: Money, closing: Money) {
            self.month = month
            self.opening = opening
            self.income = income
            self.committed = committed
            self.everyday = everyday
            self.closing = closing
        }

        /// `opening + income − committed − everyday`. Equals `closing`.
        public var reconciledClosing: Money {
            Money(minorUnits: opening.minorUnits + income.minorUnits
                    - committed.minorUnits - everyday.minorUnits,
                  currency: closing.currency)
        }
    }

    public let scenario: Scenario
    public let startDate: Day
    public let endDate: Day

    /// One entry per calendar day in the horizon, ascending.
    public let dailyBalances: [DayBalance]

    /// Spendable euro pool at `endDate`.
    public let projectedEndBalance: Money
    /// Total tracked liquidity in EUR terms at `endDate` (pool + carried).
    public let projectedEndTrackedLiquidityEUR: Money

    /// The true minimum of the spendable pool — measured **after every event
    /// application**, not just at day close. Intraday dips count.
    public let lowestBalance: Money
    public let lowestBalanceDate: Day?

    /// First day on which any post-event pool balance was below zero.
    /// **POOL_DEFICIT fact** — see `SettlementFailure` for the other fact.
    public let firstNegativeDate: Day?

    /// The smallest amount that, deposited into the spendable pool before the
    /// first event, would keep the pool non-negative on every day and every
    /// event of the horizon. Zero when never negative.
    public let minimumBridgeRequired: Money

    /// First day the post-event pool fell strictly below the safety floor.
    /// nil when no floor was supplied or it never breached.
    public let firstBelowSafetyFloorDate: Day?

    /// Like `minimumBridgeRequired`, but holding the safety floor instead of
    /// zero. Zero when the floor never breached (or no floor was supplied).
    public let minimumBridgeForSafetyFloor: Money

    /// Scenario-filtered income that entered the projection, with certainty.
    public let includedIncomeEventIDs: [String]
    /// Prospective income filtered out by the scenario policy.
    public let excludedIncomeEventIDs: [String]

    /// Payments that could not be settled in full when due (defect D4).
    /// An unsettled remainder is still applied (the first eligible account
    /// goes negative — overdraft/bounce modelling); it is never silently
    /// dropped, and never paid with ineligible money (e.g. foreign cash).
    public let settlementFailures: [SettlementFailure]

    /// The applied events, in application order — the deterministic run log.
    public let appliedEvents: [ForecastEvent]

    // MARK: - Product-shaped read-outs (port E)

    /// How many days the spendable pool stays non-negative, starting from
    /// `startDate`: `startDate.days(until: firstNegativeDate)` when a deficit
    /// occurs, else the full horizon length. Measured on the post-event
    /// (intraday-aware) balance, matching `firstNegativeDate`.
    public let cashRunwayDays: Int

    /// Spendable pool at the close of each calendar month inside the horizon.
    public let projectedMonthEnd: [MonthKey: Money]

    /// The earliest risk surfaced by the run (pool deficit preferred over a
    /// floor breach on the same day), with the event that triggered it.
    public let firstRisk: FirstRisk?

    /// Unsettled payment volume summed per calendar month, **per currency**
    /// — the "unfunded" summary for month cards. A month whose failures
    /// span currencies holds each deficit separately (EUR 12.50 *and*
    /// MAD 100.00); same-currency failures aggregate normally. There is no
    /// implicit FX anywhere: the presentation layer chooses a currency
    /// explicitly via `unfunded(in:month:)` and never sees a converted total.
    public let unfundedByMonth: [MonthKey: MoneyBag]

    /// Spendable pool at the last day of `month`, if the month is in range.
    public func monthEndPool(_ month: MonthKey) -> Money? {
        projectedMonthEnd[month]
    }

    /// The unsettled volume of `month` in `currency` specifically — zero when
    /// that month had no failure in that currency. This is the explicit,
    /// conversion-free way to read one currency's shortfall.
    public func unfunded(in currency: Currency, month: MonthKey) -> Money {
        unfundedByMonth[month]?.amount(in: currency) ?? Money(minorUnits: 0, currency: currency)
    }

    /// One ledger per calendar month in the horizon. See `MonthLedger`: these
    /// are the only numbers a month summary should add up, because they are the
    /// only grouping that provably accounts for the whole change in the pool.
    public let monthLedgers: [MonthKey: MonthLedger]

    /// EUR-only view of `unfundedByMonth`, for EUR-led presentation.
    /// Foreign-currency shortfalls are **not** included and **never**
    /// converted — read them via `unfundedByMonth` (a `MoneyBag`) or
    /// `unfunded(in:month:)` so they stay visible.
    public var unfundedEURByMonth: [MonthKey: Money] {
        unfundedByMonth.mapValues { $0.amount(in: .eur) }
    }
}
