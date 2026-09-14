import Foundation

/// Product-facing status of a planned purchase. The words are descriptive;
/// none of them is a transaction, a commitment, or spending.
enum GoalStatus: String, CaseIterable, Identifiable, Hashable, Sendable {
    case wishlist
    case saving
    case bought
    case cancelled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wishlist: "Wishlist"
        case .saving: "Saving"
        case .bought: "Bought"
        case .cancelled: "Cancelled"
        }
    }

    /// One line so the status cannot be mistaken for economics.
    var caption: String {
        switch self {
        case .wishlist: "An intention. Not a commitment and not spending."
        case .saving: "Money is set aside. That is not spending."
        case .bought: "This list item is not the transaction."
        case .cancelled: "No effect on cash, budget, or the forecast."
        }
    }
}

enum GoalFundingKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case cash
    case sinkingFund
    case financing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cash: "Cash on the day"
        case .sinkingFund: "Sinking fund"
        case .financing: "Financing plan"
        }
    }
}

enum FundCustodyKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case virtual
    case dedicated

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .virtual: "From general cash"
        case .dedicated: "In a specific account"
        }
    }

    var caption: String {
        switch self {
        case .virtual:
            "Set aside conceptually from spendable cash. Account balances do not change."
        case .dedicated:
            "Set aside in one account. That reserved slice is not free cash, even if the account is in the total."
        }
    }
}

enum FundStatusOption: String, CaseIterable, Identifiable, Hashable, Sendable {
    case active, paused, completed, cancelled

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }
}

/// One planned purchase as Plan reads it.
struct PlannedPurchaseSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let target: Amount
    let targetDate: CalendarDay?
    let status: GoalStatus
    let funding: GoalFundingKind
    let sinkingFundID: String?
    let sinkingFundName: String?
    let reserved: Amount
    let note: String?

    var fundingLabel: String {
        switch funding {
        case .cash: GoalFundingKind.cash.displayName
        case .sinkingFund: sinkingFundName.map { "Fund: \($0)" } ?? GoalFundingKind.sinkingFund.displayName
        case .financing: GoalFundingKind.financing.displayName
        }
    }
}

/// One sinking fund as Plan reads it.
struct SinkingFundSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let target: Amount
    let reserved: Amount
    let remaining: Amount
    let custody: FundCustodyKind
    let dedicatedAccountID: String?
    let dedicatedAccountName: String?
    let status: FundStatusOption
    let goalID: String?
    let goalName: String?
    let contribution: Amount?
    let note: String?
}

enum AffordabilityOverallKind: String, Hashable, Sendable {
    case affordable
    case affordableConditionally
    case notAffordable

    var displayName: String {
        switch self {
        case .affordable: "Affordable"
        case .affordableConditionally: "Affordable only if…"
        case .notAffordable: "Not affordable"
        }
    }
}

enum AffordabilityRiskKind: String, Hashable, Sendable {
    case none
    case hardDeficit
    case reserveWarning
}

/// What the affordability sheet shows. Built only from the engine verdict.
struct AffordabilityPresentation: Hashable, Sendable {
    let overall: AffordabilityOverallKind
    let why: [String]
    let ledgerCash: Amount
    let reserved: Amount
    let unreservedCash: Amount
    let cashCovers: Bool
    let budgetRemaining: Amount?
    let purchaseEconomic: Amount
    let budgetAfter: Amount?
    let withinBudget: Bool?
    let countsAsSpending: Bool
    let settlementCovers: Bool
    let settlementAvailable: Amount
    let poolUnreserved: Amount
    let settlementAccountName: String?
    let firstRiskKind: AffordabilityRiskKind
    let firstRiskDate: CalendarDay?
    let firstRiskLabel: String?
    let requiredIncome: String?
    let sinkingReservedBefore: Amount?
    let sinkingConsumed: Amount?
    let sinkingReservedAfter: Amount?
    let financingNote: String?
}

enum PlanningCopy {
    static let emptyGoals = "Plan something you're saving for"
    static let emptyFunds = "Set money aside without counting it as spent"
    static let affordabilityCaption = "Check a purchase against cash, the monthly budget, and later bills. This is a check, not a payment."
}

enum PlanningControlID {
    static let addGoal = "plan.goals.add"
    static let addFund = "plan.funds.add"
    static let openAffordability = "plan.afford.open"
    static let checkAffordability = "afford.check"
    static let affordabilityOverall = "afford.overall"
    static let affordabilityRisk = "afford.risk"
    static let goalName = "goal.name"
    static let goalAmount = "goal.amount"
    static let goalSave = "goal.save"
    static let fundName = "fund.name"
    static let fundSave = "fund.save"
}

enum PaymentRailChoice: String, CaseIterable, Identifiable, Hashable, Sendable {
    case card, transfer, directDebit, electronic, cash

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .card: "Card"
        case .transfer: "Transfer"
        case .directDebit: "Direct debit"
        case .electronic: "Electronic payment"
        case .cash: "Cash in hand"
        }
    }
}

/// Fields the affordability sheet collects. Not a persisted object.
struct AffordabilityDraft: Hashable, Sendable {
    var amountText: String = ""
    var currencyCode: String = "EUR"
    var fractionDigits: Int = 2
    var on: CalendarDay?
    var accountID: String?
    var rail: PaymentRailChoice = .card
    var funding: GoalFundingKind = .cash
    var sinkingFundID: String?
    var plannedPurchaseID: String?
    var installmentPlanID: String?
    var asReservation: Bool = false
}
