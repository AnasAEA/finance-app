/// The single answer to "how much of this budget line is already promised?".
///
/// A budget line is a **gross** envelope: the €480.00 housing line *is* the
/// rent, not pocket money on top of it. So every module that reasons about a
/// line has to agree on which scheduled charges live inside it — otherwise the
/// budget report says a line is fully committed while the forecast happily
/// spreads the same euros again, and the same money leaves the pool twice.
///
/// This type is that agreement, and it exists so there is exactly one of it.
/// `MonthlyBudgetEngine` reduces this list for its committed totals, and
/// `ForecastComposer` reduces it into the map the variable-spending planner
/// nets against. Neither computes its own.
///
/// Three rules it keeps, deliberately:
///
/// - **Only what the ledger still expects.** The list is built from
///   `OccurrenceExpander.unresolved`, so an occurrence that was paid, skipped
///   or cancelled is not promised any more and nets nothing. A late occurrence
///   is still unresolved, so it stays promised.
/// - **No mapping is ever inferred.** An obligation with no `budgetID` is an
///   independent scheduled debit: it counts in the month's committed total and
///   inside no line. Nothing is guessed from a name or a spending class.
/// - **Currency is part of the identity.** A dirham commitment cannot reduce a
///   euro envelope. No rate is ever applied here; a commitment nets only the
///   line-month of its own currency.
///
/// Installments and debts carry no `budgetID` in the model, so they cannot
/// reach a line through here. That is intentional: an installment leg repays a
/// purchase whose economic cost was already booked, and a debt repayment
/// settles consumption that was never paid. Neither is a claim on this month's
/// envelope.
public enum BudgetCommitmentAttribution {

    /// A line-month in one currency — the grain at which commitments net.
    public struct Key: Hashable, Sendable {
        public let budgetID: String
        public let month: MonthKey
        public let currency: Currency

        public init(budgetID: String, month: MonthKey, currency: Currency) {
            self.budgetID = budgetID
            self.month = month
            self.currency = currency
        }
    }

    /// One still-expected charge, and the line it belongs to if any.
    public struct Commitment: Hashable, Sendable {
        public let obligationID: String
        /// The line this charge lives inside, or nil when the obligation is
        /// unlinked. Never inferred.
        public let budgetID: String?
        public let day: Day
        /// Always positive: what the charge will take, not its ledger sign.
        public let amount: Money

        public init(obligationID: String, budgetID: String?, day: Day, amount: Money) {
            self.obligationID = obligationID
            self.budgetID = budgetID
            self.day = day
            self.amount = amount.magnitude
        }

        public var key: Key? {
            guard let budgetID else { return nil }
            return Key(budgetID: budgetID, month: day.monthKey, currency: amount.currency)
        }
    }

    /// Every charge in `[start, end]` the ledger still expects, in day order.
    public static func commitments(
        in document: FinanceDocument,
        from start: Day,
        to end: Day,
        asOf today: Day,
        ledger: ReconciliationLedger? = nil
    ) -> [Commitment] {
        let obligations = Dictionary(
            document.planning.recurringObligations.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return OccurrenceExpander.unresolved(
            in: document, from: start, to: end, asOf: today, ledger: ledger
        ).map { occurrence in
            Commitment(
                obligationID: occurrence.obligationID,
                budgetID: obligations[occurrence.obligationID]?.budgetID,
                day: occurrence.expectedDay,
                amount: occurrence.amount
            )
        }
    }

    /// The committed amount per line-month: what each envelope owes before any
    /// everyday spending is planned inside it.
    ///
    /// Unlinked commitments are absent by construction — they belong to no line
    /// and must stay charged in full.
    public static func committedByBudgetMonth(_ commitments: [Commitment]) -> [Key: Money] {
        var totals: [Key: Money] = [:]
        for commitment in commitments {
            guard let key = commitment.key else { continue }
            let running = totals[key]?.minorUnits ?? 0
            totals[key] = Money(minorUnits: running + commitment.amount.minorUnits,
                                currency: key.currency)
        }
        return totals
    }

    /// Convenience: expand and reduce in one step over the same window.
    public static func committedByBudgetMonth(
        in document: FinanceDocument,
        from start: Day,
        to end: Day,
        asOf today: Day,
        ledger: ReconciliationLedger? = nil
    ) -> [Key: Money] {
        committedByBudgetMonth(
            commitments(in: document, from: start, to: end, asOf: today, ledger: ledger)
        )
    }
}
