/// The resolved period budget result used by the shipped spending figure and
/// checkpoint category exception. This adapts engine output; it does not read
/// budget configuration, follow refund links or decide attribution.
///
/// Cross-period dependencies stop at the current period's resolved rows. A
/// refund's original can change those rows without becoming a transaction of
/// this period. Display names, notes and clocks never enter this value.
public struct SemanticBudgetFact: Hashable, Sendable, Codable {
    public let periodEconomicSpending: Money
    public let uncategorized: Money
    public let attributions: [SemanticBudgetAttributionFact]

    /// Lossless value construction for canonical decoding; no attribution policy.
    public init(periodEconomicSpending: Money, uncategorized: Money, attributions: [SemanticBudgetAttributionFact]) {
        self.periodEconomicSpending = periodEconomicSpending
        self.uncategorized = uncategorized
        self.attributions = attributions
    }

    public init(_ budget: ReviewBudget) {
        periodEconomicSpending = budget.periodEconomicSpending
        uncategorized = budget.uncategorized
        attributions = budget.attributions
            .map(SemanticBudgetAttributionFact.init)
            .sorted { $0.transactionID < $1.transactionID }
    }
}

/// The monthly engine's canonical answer, with no additional dependency state.
/// A nil budgetID is its explicit unattributed answer for nonzero economics;
/// a suppressed refund produces no row. Basis retains the authority's own
/// category/settlement/refund relationship, never an invented matching rule.
public struct SemanticBudgetAttributionFact: Hashable, Sendable, Codable {
    public let transactionID: String
    public let budgetID: String?
    public let basis: MonthlyBudgetEngine.AttributionBasis
    public let amount: Money

    /// Lossless value construction for canonical decoding; basis is supplied.
    public init(transactionID: String, budgetID: String?, basis: MonthlyBudgetEngine.AttributionBasis, amount: Money) {
        self.transactionID = transactionID
        self.budgetID = budgetID
        self.basis = basis
        self.amount = amount
    }

    public init(_ attribution: MonthlyBudgetEngine.Attribution) {
        transactionID = attribution.transactionID
        budgetID = attribution.budgetID
        basis = attribution.basis
        amount = attribution.amount
    }
}
