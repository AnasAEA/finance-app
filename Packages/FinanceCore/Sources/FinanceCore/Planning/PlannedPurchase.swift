/// Whether a planned purchase is still prospective, has money earmarked, or
/// has already become an observed transaction.
///
/// A planned purchase is **not** a transaction. A status label never creates
/// an obligation, never enters `ForecastComposer`, and never consumes the
/// economic-spending ceiling. Evaluating one as an affordability candidate
/// is a what-if overlay. `purchased` means the economics live on the actual
/// `Transaction`, not on this row.
public enum PlannedPurchaseStatus: String, Sendable, Codable, CaseIterable {
    /// Wishlist. No reservation, no forecast effect, no economic effect.
    case planned
    /// Money is earmarked (directly, or via a linked sinking fund).
    case reserved
    /// The purchase happened. This object still invents no economics.
    case purchased
    /// Abandoned. Ignored by reservation overlay and affordability.
    case cancelled
}

/// How a planned purchase is meant to be paid for.
///
/// Mutually exclusive on purpose: cash on the day, a sinking fund, or
/// financing. Combining them would double-count the same euros.
public enum PlannedPurchaseFunding: Hashable, Sendable, Codable {
    /// Pay from the unreserved spendable pool on the purchase day.
    case cashOnPurchase
    /// Funded by the named sinking fund. That fund owns the reservation.
    case sinkingFund(id: String)
    /// Financed. Economic spending is the purchase; repayments are liquidity.
    case financing
}

/// A goal: a future purchase that is not yet an economic event.
public struct PlannedPurchase: Identifiable, Hashable, Sendable, Codable {

    public let id: String
    public var name: String
    public var targetAmount: Money
    public var targetDate: Day?
    public var status: PlannedPurchaseStatus
    public var funding: PlannedPurchaseFunding

    /// Direct virtual earmark. Ignored when `funding` is `.sinkingFund`.
    public var reservedAmount: Money

    public var purchasedTransactionID: String?
    public var installmentPlanID: String?
    public var budgetID: String?
    public var requirement: PaymentRequirement
    public var note: String?

    public init(
        id: String,
        name: String,
        targetAmount: Money,
        targetDate: Day? = nil,
        status: PlannedPurchaseStatus = .planned,
        funding: PlannedPurchaseFunding = .cashOnPurchase,
        reservedAmount: Money? = nil,
        purchasedTransactionID: String? = nil,
        installmentPlanID: String? = nil,
        budgetID: String? = nil,
        requirement: PaymentRequirement,
        note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.targetAmount = targetAmount
        self.targetDate = targetDate
        self.status = status
        self.funding = funding
        self.reservedAmount = reservedAmount ?? Money(minorUnits: 0, currency: targetAmount.currency)
        self.purchasedTransactionID = purchasedTransactionID
        self.installmentPlanID = installmentPlanID
        self.budgetID = budgetID
        self.requirement = requirement
        self.note = note
    }

    /// Direct earmark this row itself owns. Zero when cancelled, purchased,
    /// funded by a sinking fund, or never reserved.
    public var ownReservation: Money {
        let zero = Money(minorUnits: 0, currency: reservedAmount.currency)
        guard status == .reserved, reservedAmount.isPositive else { return zero }
        if case .sinkingFund = funding { return zero }
        return reservedAmount
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, targetAmount, targetDate, status, funding
        case reservedAmount, purchasedTransactionID, installmentPlanID
        case budgetID, requirement, note
    }

    private enum FundingKeys: String, CodingKey {
        case kind, id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        targetAmount = try container.decode(Money.self, forKey: .targetAmount)
        targetDate = try container.decodeIfPresent(Day.self, forKey: .targetDate)
        status = try container.decode(PlannedPurchaseStatus.self, forKey: .status)
        reservedAmount = try container.decodeIfPresent(Money.self, forKey: .reservedAmount)
            ?? Money(minorUnits: 0, currency: targetAmount.currency)
        purchasedTransactionID = try container.decodeIfPresent(String.self, forKey: .purchasedTransactionID)
        installmentPlanID = try container.decodeIfPresent(String.self, forKey: .installmentPlanID)
        budgetID = try container.decodeIfPresent(String.self, forKey: .budgetID)
        requirement = try container.decode(PaymentRequirement.self, forKey: .requirement)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        let fundingContainer = try container.nestedContainer(keyedBy: FundingKeys.self, forKey: .funding)
        switch try fundingContainer.decode(String.self, forKey: .kind) {
        case "cash_on_purchase":
            funding = .cashOnPurchase
        case "sinking_fund":
            funding = .sinkingFund(id: try fundingContainer.decode(String.self, forKey: .id))
        case "financing":
            funding = .financing
        case let other:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown planned-purchase funding '\(other)'")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(targetAmount, forKey: .targetAmount)
        try container.encodeIfPresent(targetDate, forKey: .targetDate)
        try container.encode(status, forKey: .status)
        try container.encode(reservedAmount, forKey: .reservedAmount)
        try container.encodeIfPresent(purchasedTransactionID, forKey: .purchasedTransactionID)
        try container.encodeIfPresent(installmentPlanID, forKey: .installmentPlanID)
        try container.encodeIfPresent(budgetID, forKey: .budgetID)
        try container.encode(requirement, forKey: .requirement)
        try container.encodeIfPresent(note, forKey: .note)
        var fundingContainer = container.nestedContainer(keyedBy: FundingKeys.self, forKey: .funding)
        switch funding {
        case .cashOnPurchase:
            try fundingContainer.encode("cash_on_purchase", forKey: .kind)
        case let .sinkingFund(id):
            try fundingContainer.encode("sinking_fund", forKey: .kind)
            try fundingContainer.encode(id, forKey: .id)
        case .financing:
            try fundingContainer.encode("financing", forKey: .kind)
        }
    }
}
