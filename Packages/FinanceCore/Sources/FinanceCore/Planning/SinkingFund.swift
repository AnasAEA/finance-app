/// Where earmarked money for a sinking fund actually lives.
///
/// Virtual reservation and a dedicated account are mutually exclusive.
/// Transferring cash into a savings account *and* also overlaying
/// `reservedAmount` on the spendable pool would hide the same euros twice.
public enum SinkingFundCustody: Hashable, Sendable, Codable {
    /// Earmark against the general spendable pool. Ledger balances do not change.
    case virtualReservation
    /// Physically segregated in `accountID`. That account's reserved slice is
    /// not generally spendable, even if the account sits inside pooled
    /// liquidity. `reservedAmount` is not *also* overlaid on other accounts.
    case dedicatedAccount(accountID: String)
}

public enum SinkingFundStatus: String, Sendable, Codable, CaseIterable {
    case active
    case paused
    case completed
    case cancelled
}

/// A save-up envelope for a future purchase.
///
/// A contribution is **not** economic spending. `reservedAmount` is explicit
/// and never inferred from the wall clock. A candidate evaluation may
/// *describe* consuming some of it; it never mutates this value.
public struct SinkingFund: Identifiable, Hashable, Sendable, Codable {

    public let id: String
    public var name: String
    public var goalID: String?
    public var targetAmount: Money
    public var reservedAmount: Money
    public var contributionAmount: Money?
    public var contributionSchedule: RecurrenceSpec?
    public var custody: SinkingFundCustody
    public var status: SinkingFundStatus
    public var note: String?

    public init(
        id: String,
        name: String,
        goalID: String? = nil,
        targetAmount: Money,
        reservedAmount: Money? = nil,
        contributionAmount: Money? = nil,
        contributionSchedule: RecurrenceSpec? = nil,
        custody: SinkingFundCustody = .virtualReservation,
        status: SinkingFundStatus = .active,
        note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.goalID = goalID
        self.targetAmount = targetAmount
        self.reservedAmount = reservedAmount ?? Money(minorUnits: 0, currency: targetAmount.currency)
        self.contributionAmount = contributionAmount
        self.contributionSchedule = contributionSchedule
        self.custody = custody
        self.status = status
        self.note = note
    }

    public var isReserving: Bool {
        status == .active && reservedAmount.isPositive
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, goalID, targetAmount, reservedAmount
        case contributionAmount, contributionSchedule, custody, status, note
    }

    private enum CustodyKeys: String, CodingKey {
        case kind, accountID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        goalID = try container.decodeIfPresent(String.self, forKey: .goalID)
        targetAmount = try container.decode(Money.self, forKey: .targetAmount)
        reservedAmount = try container.decodeIfPresent(Money.self, forKey: .reservedAmount)
            ?? Money(minorUnits: 0, currency: targetAmount.currency)
        contributionAmount = try container.decodeIfPresent(Money.self, forKey: .contributionAmount)
        contributionSchedule = try container.decodeIfPresent(RecurrenceSpec.self, forKey: .contributionSchedule)
        status = try container.decode(SinkingFundStatus.self, forKey: .status)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        let custodyContainer = try container.nestedContainer(keyedBy: CustodyKeys.self, forKey: .custody)
        switch try custodyContainer.decode(String.self, forKey: .kind) {
        case "virtual":
            custody = .virtualReservation
        case "dedicated_account":
            custody = .dedicatedAccount(accountID: try custodyContainer.decode(String.self, forKey: .accountID))
        case let other:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown sinking-fund custody '\(other)'")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(goalID, forKey: .goalID)
        try container.encode(targetAmount, forKey: .targetAmount)
        try container.encode(reservedAmount, forKey: .reservedAmount)
        try container.encodeIfPresent(contributionAmount, forKey: .contributionAmount)
        try container.encodeIfPresent(contributionSchedule, forKey: .contributionSchedule)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(note, forKey: .note)
        var custodyContainer = container.nestedContainer(keyedBy: CustodyKeys.self, forKey: .custody)
        switch custody {
        case .virtualReservation:
            try custodyContainer.encode("virtual", forKey: .kind)
        case let .dedicatedAccount(accountID):
            try custodyContainer.encode("dedicated_account", forKey: .kind)
            try custodyContainer.encode(accountID, forKey: .accountID)
        }
    }
}
