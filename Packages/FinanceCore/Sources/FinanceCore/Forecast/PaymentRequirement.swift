/// What a payment needs in order to be settled: a currency **and** the set of
/// rails it may ride (any one of which suffices).
///
/// Examples:
/// - French rent by SEPA direct debit → `EUR` × `[sepaDirectDebit]`
/// - Groceries → `EUR` × `[cardDebit, electronicPayment, physicalCash]`
/// - An in-person-only purchase → `EUR` × `[physicalCash]`
public struct PaymentRequirement: Hashable, Sendable, Codable {

    public let currency: Currency

    /// The payment can be settled through ANY of these rails.
    public let acceptableRails: Set<PaymentRail>

    public init(currency: Currency, acceptableRails: Set<PaymentRail>) {
        precondition(!acceptableRails.isEmpty, "a payment requirement needs at least one rail")
        self.currency = currency
        self.acceptableRails = acceptableRails
    }

    public init(currencyCode: String, rails: Set<PaymentRail>) {
        self.init(currency: Currency(code: currencyCode), acceptableRails: rails)
    }

    /// Convenience for a bank-settled euro payment.
    public static func euroBankPayment(rails: Set<PaymentRail> = PaymentRail.euroBankRails) -> PaymentRequirement {
        PaymentRequirement(currency: .eur, acceptableRails: rails)
    }

    // MARK: - Codable (rails sorted for determinism)

    private enum CodingKeys: String, CodingKey {
        case currency, rails
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.currency = try container.decode(Currency.self, forKey: .currency)
        self.acceptableRails = try container.decode(SortedRailSet.self, forKey: .rails).rails
        precondition(!acceptableRails.isEmpty, "a payment requirement needs at least one rail")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currency, forKey: .currency)
        try container.encode(SortedRailSet(acceptableRails), forKey: .rails)
    }
}
