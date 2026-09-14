/// Economic read-outs over a set of transactions, computed in one currency.
///
/// This is where the forensic distinctions live as pure functions:
///
/// | event                    | account movement | economic spending | personal income |
/// |--------------------------|------------------|-------------------|-----------------|
/// | expense                  | out              | +amount           | —               |
/// | income                   | in               | —                 | +amount         |
/// | transfer (own accounts)  | out + in         | 0                 | 0               |
/// | refund                   | in               | −amount (nets its linked expense) | 0 |
/// | financingRepayment       | out              | 0                 | —               |
/// | passThrough arrival      | in               | —                 | +owned share only |
/// | passThrough disposal     | out              | 0                 | 0               |
/// | cashWithdrawal / conversion | out + in      | 0                 | 0               |
/// | any transaction `.reversed` | whatever       | 0                 | 0               |
///
/// `reversed` transactions contribute nothing: a reversed debit never
/// economically happened (the still-owed obligation belongs to the planning
/// layer, not to a synthetic income entry).
public enum Economics {

    // MARK: - Per-transaction effect

    /// The economic effect of **one** transaction in one currency — the
    /// first-class read-out the UI consumes per row, so no caller has to
    /// reproduce the kind switch.
    ///
    /// All amounts are non-negative magnitudes in `currency` (zero when not
    /// applicable); `accountMovementIn`/`Out` carry the raw movement facts so
    /// "movement ≠ economics" stays visible per row.
    public struct EconomicEffect: Hashable, Sendable {

        /// One-line economic role for display.
        public enum Role: String, Sendable {
            /// New consumption.
            case spending
            /// Resources that became mine (income + owned pass-through share).
            case income
            /// Money back for a previously booked expense.
            case refund
            /// Liquidity out, zero new spending.
            case financingRepayment
            /// Somebody else's money moving through my accounts.
            case passThrough
            /// Value changing form/place between my own positions.
            case accountMovement
            /// Nothing economically happened (e.g. a reversed debit).
            case none
        }

        public let currency: Currency
        /// New economic consumption this transaction created (≥ 0).
        public let spending: Money
        /// Personal economic income — including the owned share of a
        /// pass-through arrival (≥ 0).
        public let income: Money
        /// Refund received — offsets spending, never income (≥ 0).
        public let refund: Money
        /// Financing repayment — committed liquidity, zero new spending (≥ 0).
        public let financingRepayment: Money
        /// Pass-through volume that was **not** mine (≥ 0).
        public let passThroughNotMine: Money
        /// Raw inflow across legs in `currency` (the movement fact).
        public let accountMovementIn: Money
        /// Raw outflow across legs in `currency` (the movement fact).
        public let accountMovementOut: Money
        /// The lifecycle of the source transaction (reversed → all-zero effect).
        public let lifecycle: TransactionLifecycle

        /// What this transaction did to me economically:
        /// income − (spending − refund).
        public var netPersonalFlow: Money { income - (spending - refund) }

        /// True when value only changed form or place between my positions
        /// (transfer, withdrawal, conversion — or a disposal of foreign money).
        public var isRelocation: Bool {
            role == .accountMovement || role == .passThrough
        }

        /// True when this transaction created new consumption.
        public var isConsumption: Bool { role == .spending && spending.minorUnits > 0 }

        /// The single most informative role label for UI display.
        public var role: Role {
            if lifecycle == .reversed { return .none }
            switch (spending.minorUnits, income.minorUnits, refund.minorUnits,
                    financingRepayment.minorUnits, passThroughNotMine.minorUnits,
                    accountMovementIn.minorUnits, accountMovementOut.minorUnits) {
            case (0, 0, 0, 0, 0, 0, 0): return .none
            case (let s, _, _, _, _, _, _) where s > 0: return .spending
            case (_, let i, _, _, _, _, _) where i > 0: return .income
            case (_, _, let r, _, _, _, _) where r > 0: return .refund
            case (_, _, _, let f, _, _, _) where f > 0: return .financingRepayment
            case (_, _, _, _, let p, _, _) where p > 0: return .passThrough
            default: return .accountMovement
            }
        }
    }

    /// The per-transaction economic effect in `currency`. Legs in other
    /// currencies contribute zero (an ATM's MAD leg is measured by its EUR
    /// cost leg; see DOMAIN.md).
    public static func effect(of transaction: Transaction, currency: Currency) -> EconomicEffect {
        var spending: Int64 = 0
        var income: Int64 = 0
        var refund: Int64 = 0
        var repayment: Int64 = 0
        var notMine: Int64 = 0
        var movementIn: Int64 = 0
        var movementOut: Int64 = 0

        for leg in transaction.legs where leg.amount.currency == currency {
            let magnitude = leg.amount.minorUnits < 0 ? -leg.amount.minorUnits : leg.amount.minorUnits
            if leg.amount.minorUnits > 0 { movementIn += leg.amount.minorUnits }
            if leg.amount.minorUnits < 0 { movementOut += magnitude }

            guard transaction.lifecycle != .reversed else { continue }

            switch transaction.kind {
            case .expense:
                if leg.isOutflow { spending += magnitude }
            case .income:
                if leg.isInflow { income += magnitude }
            case .refund:
                if leg.isInflow { refund += magnitude }
            case .financingRepayment:
                if leg.isOutflow { repayment += magnitude }
            case .transfer, .cashWithdrawal, .currencyConversion:
                break // movement without economics
            case .passThrough:
                if leg.isInflow {
                    let owned = ownedShare(of: transaction, currency: currency)
                    income += owned.minorUnits
                    notMine += magnitude - owned.minorUnits
                }
                // Disposal outflows carry somebody else's money: no effect.
            }
        }

        return EconomicEffect(
            currency: currency,
            spending: Money(minorUnits: spending, currency: currency),
            income: Money(minorUnits: income, currency: currency),
            refund: Money(minorUnits: refund, currency: currency),
            financingRepayment: Money(minorUnits: repayment, currency: currency),
            passThroughNotMine: Money(minorUnits: notMine, currency: currency),
            accountMovementIn: Money(minorUnits: movementIn, currency: currency),
            accountMovementOut: Money(minorUnits: movementOut, currency: currency),
            lifecycle: transaction.lifecycle
        )
    }

    // MARK: - Aggregate totals

    /// Aggregate economic totals in one currency, over the given transactions.
    public struct Totals: Hashable, Sendable {
        public let currency: Currency

        /// Sum of all positive legs (raw money in, before any semantics).
        public let grossInflow: Money
        /// Sum of all negative legs (raw money out).
        public let grossOutflow: Money

        /// New economic consumption: expenses + arrears-type debt payments.
        public let economicSpending: Money
        /// Refunds received. Never part of personal income.
        public let refunds: Money
        /// Spending net of refunds — the honest "what did consumption cost me".
        public let netEconomicSpending: Money
        /// Personal economic income: income + owned share of pass-throughs.
        public let personalIncome: Money
        /// Pass-through volume that was **not** mine.
        public let passThroughNotMine: Money
        /// Financing repayments: liquidity out, zero economic spending.
        public let financingRepayments: Money
        /// Internal transfer volume (informational).
        public let internalTransfers: Money

        /// Personal cash flow: what these events did to my economics.
        public var personalNetFlow: Money { personalIncome - netEconomicSpending }
    }

    /// Computes totals for `currency` by folding per-transaction effects —
    /// one semantic source of truth (the per-row `effect(of:)` and the
    /// aggregate totals can never disagree).
    public static func totals(for transactions: [Transaction], currency: Currency) -> Totals {
        var grossIn: Int64 = 0
        var grossOut: Int64 = 0
        var spending: Int64 = 0
        var refundTotal: Int64 = 0
        var incomeTotal: Int64 = 0
        var notMine: Int64 = 0
        var repayments: Int64 = 0
        var transfers: Int64 = 0

        for transaction in transactions {
            let effect = effect(of: transaction, currency: currency)
            grossIn += effect.accountMovementIn.minorUnits
            grossOut += effect.accountMovementOut.minorUnits
            spending += effect.spending.minorUnits
            refundTotal += effect.refund.minorUnits
            incomeTotal += effect.income.minorUnits
            notMine += effect.passThroughNotMine.minorUnits
            repayments += effect.financingRepayment.minorUnits

            switch transaction.kind {
            case .transfer, .cashWithdrawal, .currencyConversion:
                if transaction.lifecycle != .reversed {
                    transfers += effect.accountMovementOut.minorUnits
                }
            default:
                break
            }
        }

        return Totals(
            currency: currency,
            grossInflow: Money(minorUnits: grossIn, currency: currency),
            grossOutflow: Money(minorUnits: grossOut, currency: currency),
            economicSpending: Money(minorUnits: spending, currency: currency),
            refunds: Money(minorUnits: refundTotal, currency: currency),
            netEconomicSpending: Money(minorUnits: spending - refundTotal, currency: currency),
            personalIncome: Money(minorUnits: incomeTotal, currency: currency),
            passThroughNotMine: Money(minorUnits: notMine, currency: currency),
            financingRepayments: Money(minorUnits: repayments, currency: currency),
            internalTransfers: Money(minorUnits: transfers, currency: currency)
        )
    }

    /// The explicitly-owned share of a pass-through inflow.
    ///
    /// **No split is ever invented**: a pass-through without ownership splits
    /// is conservatively 0% mine — a temporary bank balance must never become
    /// personal income by default.
    public static func ownedShare(of transaction: Transaction, currency: Currency) -> Money {
        precondition(transaction.kind == .passThrough, "ownedShare applies to pass-through transactions")
        let splits = transaction.ownership ?? []
        let owned = splits.filter(\.isSelf).filter { $0.amount.currency == currency }
        return Money.sum(owned.map(\.amount), currency: currency)
    }

    /// Net change a set of transactions caused to one account.
    /// (Account movement — the raw fact, independent of economics.)
    public static func accountDelta(accountID: String, in transactions: [Transaction]) -> [Currency: Money] {
        var byCurrency: [Currency: Int64] = [:]
        for transaction in transactions {
            for leg in transaction.legs where leg.accountID == accountID {
                byCurrency[leg.amount.currency, default: 0] += leg.amount.minorUnits
            }
        }
        return Dictionary(
            byCurrency.map { (currency, minorUnits) in (currency, Money(minorUnits: minorUnits, currency: currency)) },
            uniquingKeysWith: { a, _ in a }
        )
    }
}
