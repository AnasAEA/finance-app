/// Closed vocabulary of why an affordability verdict came out the way it did.
/// The UI may translate these; it must not invent a second Boolean.
public enum AffordabilityReason: String, Sendable, Hashable, Codable {
    case ineligibleCurrencyOrRail
    case foreignCurrencyNotConverted
    case candidateWouldFailToSettle
    case settlementAccountInsufficient
    case poolWouldCoverButSettlementWouldNot
    case newPoolDeficit
    case firstRiskMovedEarlier
    case deepenedPoolDeficit
    case overBudget
    case withinBudget
    case notEconomicSpending
    case sufficientUnreservedCash
    case insufficientUnreservedCash
    case firstRiskUnchanged
    case newFloorBreach
    case dependsOnExcludedIncome
    case reservedMoneyIsNotSpent
    case accountBalanceIsNotSafeToSpend
    case financingDoesNotDoubleCount
    case sinkingFundConsumed
    case sinkingFundDoesNotFullyCover
}

public enum AffordabilityOverall: String, Sendable, Hashable, Codable {
    case affordable
    case affordableConditionally
    case notAffordable
}

/// Ledger vs reserved vs unreserved. None of these is Home `safeToSpend`.
public struct AffordabilityCashAssessment: Hashable, Sendable {
    /// Spendable-pool total from document balances, ignoring reservations.
    public let ledgerPool: Money
    /// Successfully withheld in the candidate's pool currency.
    public let reserved: Money
    /// `ledgerPool` after the reservation overlay. Not named `safeToSpend`.
    public let unreservedPool: Money
    public let sufficient: Bool
    public let ineligible: Bool

    public init(
        ledgerPool: Money,
        reserved: Money,
        unreservedPool: Money,
        sufficient: Bool,
        ineligible: Bool
    ) {
        self.ledgerPool = ledgerPool
        self.reserved = reserved
        self.unreservedPool = unreservedPool
        self.sufficient = sufficient
        self.ineligible = ineligible
    }
}

public struct AffordabilityBudgetAssessment: Hashable, Sendable {
    public let ceiling: Money?
    public let spent: Money
    public let committed: Money
    public let remaining: Money?
    public let economicAmount: Money
    public let countsAsSpending: Bool
    /// `nil` when there is no ceiling in this currency.
    public let withinCeiling: Bool?

    public init(
        ceiling: Money?,
        spent: Money,
        committed: Money,
        remaining: Money?,
        economicAmount: Money,
        countsAsSpending: Bool,
        withinCeiling: Bool?
    ) {
        self.ceiling = ceiling
        self.spent = spent
        self.committed = committed
        self.remaining = remaining
        self.economicAmount = economicAmount
        self.countsAsSpending = countsAsSpending
        self.withinCeiling = withinCeiling
    }
}

public struct AffordabilityTimingAssessment: Hashable, Sendable {
    public let firstNegativeBefore: Day?
    public let firstNegativeAfter: Day?
    public let firstBelowFloorBefore: Day?
    public let firstBelowFloorAfter: Day?
    public let firstRiskBefore: ForecastResult.FirstRisk?
    public let firstRiskAfter: ForecastResult.FirstRisk?
    public let lowestBefore: Money
    public let lowestAfter: Money
    public let deficitWorsened: Bool
    public let newFloorBreach: Bool

    public init(
        firstNegativeBefore: Day?,
        firstNegativeAfter: Day?,
        firstBelowFloorBefore: Day?,
        firstBelowFloorAfter: Day?,
        firstRiskBefore: ForecastResult.FirstRisk?,
        firstRiskAfter: ForecastResult.FirstRisk?,
        lowestBefore: Money,
        lowestAfter: Money,
        deficitWorsened: Bool,
        newFloorBreach: Bool
    ) {
        self.firstNegativeBefore = firstNegativeBefore
        self.firstNegativeAfter = firstNegativeAfter
        self.firstBelowFloorBefore = firstBelowFloorBefore
        self.firstBelowFloorAfter = firstBelowFloorAfter
        self.firstRiskBefore = firstRiskBefore
        self.firstRiskAfter = firstRiskAfter
        self.lowestBefore = lowestBefore
        self.lowestAfter = lowestAfter
        self.deficitWorsened = deficitWorsened
        self.newFloorBreach = newFloorBreach
    }
}

public struct AffordabilityFundingAssessment: Hashable, Sendable {
    public let operatingScenario: Scenario
    public let excludedIncomeIDs: [String]
    /// Certainty class that would have to be admitted for operating cash to
    /// succeed. `nil` when operating cash already succeeds, or when even
    /// `possible` would not.
    public let requiredCertainty: IncomeCertainty?

    public init(
        operatingScenario: Scenario,
        excludedIncomeIDs: [String],
        requiredCertainty: IncomeCertainty?
    ) {
        self.operatingScenario = operatingScenario
        self.excludedIncomeIDs = excludedIncomeIDs
        self.requiredCertainty = requiredCertainty
    }
}

/// Pooled unreserved cash versus the candidate's actual rail/account.
public struct AffordabilitySettlementAssessment: Hashable, Sendable {
    public let poolUnreserved: Money
    public let settlementAvailable: Money
    public let required: Money
    public let wouldSettle: Bool
    public let eligibleAccountIDs: [String]
    public let settlementAccountID: String?

    public init(
        poolUnreserved: Money,
        settlementAvailable: Money,
        required: Money,
        wouldSettle: Bool,
        eligibleAccountIDs: [String],
        settlementAccountID: String?
    ) {
        self.poolUnreserved = poolUnreserved
        self.settlementAvailable = settlementAvailable
        self.required = required
        self.wouldSettle = wouldSettle
        self.eligibleAccountIDs = eligibleAccountIDs
        self.settlementAccountID = settlementAccountID
    }
}

/// What-if consumption of a sinking fund. The actual fund is not mutated.
public struct SinkingFundConsumption: Hashable, Sendable {
    public let fundID: String
    public let reservedBefore: Money
    public let consumed: Money
    public let reservedAfter: Money

    public init(fundID: String, reservedBefore: Money, consumed: Money, reservedAfter: Money) {
        self.fundID = fundID
        self.reservedBefore = reservedBefore
        self.consumed = consumed
        self.reservedAfter = reservedAfter
    }
}

/// Multi-axis result of one affordability run. Not a Boolean.
public struct AffordabilityVerdict: Hashable, Sendable {

    public let overall: AffordabilityOverall
    public let reasons: [AffordabilityReason]
    public let cash: AffordabilityCashAssessment
    public let budget: AffordabilityBudgetAssessment
    public let timing: AffordabilityTimingAssessment
    public let funding: AffordabilityFundingAssessment
    public let settlement: AffordabilitySettlementAssessment
    public let reservations: ReservationApplication
    public let sinkingFundConsumption: SinkingFundConsumption?
    public let baseline: ForecastResult
    public let after: ForecastResult
    public let economicAmount: Money
    public let cashAmount: Money

    public init(
        overall: AffordabilityOverall,
        reasons: [AffordabilityReason],
        cash: AffordabilityCashAssessment,
        budget: AffordabilityBudgetAssessment,
        timing: AffordabilityTimingAssessment,
        funding: AffordabilityFundingAssessment,
        settlement: AffordabilitySettlementAssessment,
        reservations: ReservationApplication,
        sinkingFundConsumption: SinkingFundConsumption?,
        baseline: ForecastResult,
        after: ForecastResult,
        economicAmount: Money,
        cashAmount: Money
    ) {
        self.overall = overall
        self.reasons = reasons
        self.cash = cash
        self.budget = budget
        self.timing = timing
        self.funding = funding
        self.settlement = settlement
        self.reservations = reservations
        self.sinkingFundConsumption = sinkingFundConsumption
        self.baseline = baseline
        self.after = after
        self.economicAmount = economicAmount
        self.cashAmount = cashAmount
    }
}
