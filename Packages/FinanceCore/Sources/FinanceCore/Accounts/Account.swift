/// Broad economic class of a place value can live.
///
/// - `bank`: regulated bank account (SEPA rails).
/// - `wallet`: e-money / neobank / online-wallet account (card + electronic
///   rails, often also SEPA).
/// - `cash`: physical notes and coins in hand. Cash is a real, owned asset —
///   but it can only settle in-person payments and cannot be debited by a bank.
public enum AccountKind: String, Sendable, Codable, CaseIterable {
    case bank
    case wallet
    case cash
}

/// An account: an identified place money lives, with a currency, a kind, the
/// payment rails it can actually settle on, and an active flag.
///
/// Capability lives in `supportedRails` — NOT in `kind`. A wallet that issues
/// cards declares `cardDebit`; a cash pocket does not. This keeps the model
/// general: nothing about BNP/Revolut specifically is baked in.
public struct Account: Identifiable, Hashable, Sendable, Codable {

    public let id: String
    public var name: String
    public var currency: Currency
    public var kind: AccountKind
    public var supportedRails: Set<PaymentRail>
    public var isActive: Bool

    /// Deterministic order in which funds are drawn for an eligible payment
    /// (lower is drawn first). Lets a user say "spend from the wallet before
    /// the bank" without hardcoding account importance.
    public var drawOrder: Int

    public init(
        id: String,
        name: String,
        currency: Currency,
        kind: AccountKind,
        supportedRails: Set<PaymentRail>,
        isActive: Bool = true,
        drawOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.currency = currency
        self.kind = kind
        self.supportedRails = supportedRails
        self.isActive = isActive
        self.drawOrder = drawOrder
    }

    /// Whether this account can settle a payment on at least one of `rails`.
    public func supports(anyOf rails: Set<PaymentRail>) -> Bool {
        !supportedRails.isDisjoint(with: rails)
    }

    /// Whether this account can satisfy a payment requirement **in full**:
    /// active, right currency AND a rail in common. Currency alone is not
    /// enough (euros in hand still cannot pay a SEPA debit), rails alone are
    /// not enough (200 MAD cannot pay a euro obligation without conversion),
    /// and a closed account satisfies nothing.
    public func satisfies(_ requirement: PaymentRequirement) -> Bool {
        isActive && currency == requirement.currency && supports(anyOf: requirement.acceptableRails)
    }

    // MARK: - Codable (rails serialized sorted for byte-deterministic JSON)

    private enum CodingKeys: String, CodingKey {
        case id, name, currency, kind, supportedRails, isActive, drawOrder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.currency = try container.decode(Currency.self, forKey: .currency)
        self.kind = try container.decode(AccountKind.self, forKey: .kind)
        self.supportedRails = try container.decode(SortedRailSet.self, forKey: .supportedRails).rails
        self.isActive = try container.decode(Bool.self, forKey: .isActive)
        self.drawOrder = try container.decode(Int.self, forKey: .drawOrder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(currency, forKey: .currency)
        try container.encode(kind, forKey: .kind)
        try container.encode(SortedRailSet(supportedRails), forKey: .supportedRails)
        try container.encode(isActive, forKey: .isActive)
        try container.encode(drawOrder, forKey: .drawOrder)
    }
}

/// A carried-forward or manual balance **anchor**, inclusive through `asOf`.
///
/// This is not a mutable latest-balance cache. Current holdings are derived
/// (`CurrentHoldings`): provider current cash when usable, otherwise this
/// figure plus economic legs strictly after `asOf`.
public struct AccountBalance: Hashable, Sendable, Codable {
    public let accountID: String
    public let balance: Money
    public let asOf: Day
    public let status: BalanceStatus

    public init(accountID: String, balance: Money, asOf: Day, status: BalanceStatus = .observed) {
        self.accountID = accountID
        self.balance = balance
        self.asOf = asOf
        self.status = status
    }
}

public enum BalanceStatus: String, Sendable, Codable {
    /// Directly observed on a statement / app.
    case observed
    /// Carried forward by computation from the last observed point.
    case carriedForward
    /// Planned/hypothetical starting point (scenarios).
    case assumed
}
