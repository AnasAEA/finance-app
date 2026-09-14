/// Input to a forecast run.
public struct ForecastRequest: Hashable, Sendable {

    public var startDate: Day
    public var endDate: Day

    public var accounts: [Account]

    /// Account balances at the opening of `startDate`.
    public var startingBalances: [String: Money]

    /// Pre-dated events (obligations, installments, arrears, disposals…).
    /// Income sources and budgets are expanded by the engine itself.
    public var events: [ForecastEvent]

    public var incomeSources: [IncomeSource]
    public var budgets: [BudgetAllocation]

    /// How much of each budget line-month is already promised to scheduled
    /// charges carried in `events`, from `BudgetCommitmentAttribution`.
    ///
    /// Budget lines are gross envelopes, so the engine spreads only what is left
    /// inside a line after its own commitments. Populated by
    /// `ForecastComposer.makeRequest` over this request's own window; empty
    /// means "nothing is linked", which is the right reading for a request built
    /// by hand from bare allocations.
    public var committedByBudgetMonth: [BudgetCommitmentAttribution.Key: Money]

    public var scenario: Scenario
    /// nil → `scenario.defaultPolicy`.
    public var policy: ScenarioPolicy?

    /// A floor the euro spendable pool should not fall below (e.g. an
    /// operating floor). Drives `firstBelowSafetyFloorDate` and
    /// `minimumBridgeForSafetyFloor`.
    public var safetyFloor: Money?

    /// Carried euro value of non-EUR accounts (physical cash carried at what
    /// an observed conversion actually cost — never a market estimate).
    /// Keyed by account id.
    public var carriedEURValues: [String: Money]

    /// Defines the "spendable euro pool" all headline metrics are measured on:
    /// the accounts that can satisfy this requirement. Defaults to euro
    /// bank/wallet rails; physical cash (wrong currency or cash-only rail)
    /// never satisfies it.
    public var spendablePoolRequirement: PaymentRequirement

    public init(
        startDate: Day,
        endDate: Day,
        accounts: [Account],
        startingBalances: [String: Money],
        events: [ForecastEvent] = [],
        incomeSources: [IncomeSource] = [],
        budgets: [BudgetAllocation] = [],
        committedByBudgetMonth: [BudgetCommitmentAttribution.Key: Money] = [:],
        scenario: Scenario,
        policy: ScenarioPolicy? = nil,
        safetyFloor: Money? = nil,
        carriedEURValues: [String: Money] = [:],
        spendablePoolRequirement: PaymentRequirement = PaymentRequirement(currency: .eur, acceptableRails: PaymentRail.euroBankRails)
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.accounts = accounts
        self.startingBalances = startingBalances
        self.events = events
        self.incomeSources = incomeSources
        self.budgets = budgets
        self.committedByBudgetMonth = committedByBudgetMonth
        self.scenario = scenario
        self.policy = policy
        self.safetyFloor = safetyFloor
        self.carriedEURValues = carriedEURValues
        self.spendablePoolRequirement = spendablePoolRequirement
    }
}

/// Structural problems a request can carry. These are distinct from
/// *shortfalls*, which are legitimate forecast outcomes (a payment the
/// projected liquidity cannot cover when it comes due).
public enum ForecastError: Error, Hashable, Sendable {
    case emptyHorizon
    case missingBalance(accountID: String)
    case balanceCurrencyMismatch(accountID: String, expected: String, got: String)
    case unknownEventAccount(eventID: String, accountID: String)
    case eventCurrencyMismatch(eventID: String, expected: String, got: String)
    case noEligibleAccount(eventID: String, requirement: String)
    case duplicateEventID(String)
    case safetyFloorCurrencyMismatch(expected: String, got: String)
    /// A day the run required — the next day of the walk, or the horizon's own
    /// length — lies outside the range an `Int` day ordinal can express. The
    /// request is not answerable; it is never answered with a shorter horizon,
    /// fewer days, or a zero forecast.
    case dateArithmeticOutOfRange
}
