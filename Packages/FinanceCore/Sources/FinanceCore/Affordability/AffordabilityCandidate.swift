/// What a candidate purchase *means* economically.
///
/// - `consumption` — economic spending and a cash debit.
/// - `reservation` — earmark only; not spending, not a cash leaving-the-system debit.
/// - `financingPurchase` — economic spending is the original purchase;
///   cash is the instalment schedule. The original amount is never also
///   debited as cash.
public enum AffordabilityCandidateKind: String, Sendable, Hashable, Codable {
    case consumption
    case reservation
    case financingPurchase
}

/// Cash legs of a financed purchase. Economic cost is `originalPurchaseAmount`.
public struct FinancingProposal: Hashable, Sendable {
    public let originalPurchaseAmount: Money
    public let installments: [Installment]

    public init(originalPurchaseAmount: Money, installments: [Installment]) {
        self.originalPurchaseAmount = originalPurchaseAmount
        self.installments = installments
    }

    public var cashTotal: Money {
        Money.sum(
            installments.filter { $0.status == .scheduled }.map(\.amount),
            currency: originalPurchaseAmount.currency
        )
    }
}

/// The what-if the affordability engine answers.
///
/// This is not a `Transaction` and not a `PlannedPurchase`. Evaluating it
/// does not persist it.
public struct AffordabilityCandidate: Identifiable, Hashable, Sendable {

    public let id: String
    public let name: String
    public let amount: Money
    public let on: Day
    public let requirement: PaymentRequirement
    public let kind: AffordabilityCandidateKind

    /// When set, the candidate must settle from this account. Other pooled
    /// cash is not a transfer and cannot rescue it.
    public let settlementAccountID: String?

    /// When set, the purchase is funded by this sinking fund: reserved cash
    /// is released then spent, so reservation + purchase are not both
    /// withheld. Does not exempt the purchase from the economic ceiling.
    public let sinkingFundID: String?

    public let financing: FinancingProposal?

    public init(
        id: String,
        name: String,
        amount: Money,
        on: Day,
        requirement: PaymentRequirement,
        kind: AffordabilityCandidateKind = .consumption,
        settlementAccountID: String? = nil,
        sinkingFundID: String? = nil,
        financing: FinancingProposal? = nil
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.on = on
        self.requirement = requirement
        self.kind = kind
        self.settlementAccountID = settlementAccountID
        self.sinkingFundID = sinkingFundID
        self.financing = financing
    }

    /// Amount that counts against the monthly economic-spending ceiling.
    public var economicAmount: Money {
        switch kind {
        case .reservation:
            return Money(minorUnits: 0, currency: amount.currency)
        case .financingPurchase:
            return financing?.originalPurchaseAmount ?? amount
        case .consumption:
            return amount
        }
    }

    /// Cash that actually leaves accounts under this candidate.
    public var cashAmount: Money {
        switch kind {
        case .financingPurchase:
            return financing?.cashTotal ?? Money(minorUnits: 0, currency: amount.currency)
        case .consumption, .reservation:
            return amount
        }
    }

    public var countsAsEconomicSpending: Bool {
        kind != .reservation
    }
}
