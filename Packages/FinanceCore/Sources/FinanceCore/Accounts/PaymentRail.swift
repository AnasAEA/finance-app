/// A payment rail: the physical/electronic channel through which a payment
/// can actually be settled.
///
/// This is the type that keeps **rail capability** separate from **currency**
/// and from **account kind**. A €480.00 rent obligation is payable by SEPA
/// direct debit; 200 MAD of physical cash can neither ride that rail nor enter
/// that currency, so it cannot satisfy the obligation — no matter what the
/// total "net worth" number says.
///
/// Modeled as an extensible identified value rather than a closed enum, so a
/// deployment can define rails FinanceCore does not know about (e.g. a
/// national instant-payment scheme) without forking the domain.
public struct PaymentRail: Hashable, Sendable, Codable, CustomStringConvertible {

    /// Stable, machine-readable identifier (snake_case string).
    public let id: String

    /// Short human explanation, informational only.
    public let summary: String

    /// - Requires: `id` is non-empty lowercase snake_case ASCII.
    public init(id: String, summary: String) {
        precondition(!id.isEmpty, "rail id must not be empty")
        precondition(id.allSatisfy { ($0.isASCII && $0.isLowercase && $0.isLetter) || $0 == "_" },
                     "rail id must be lowercase snake_case, got '\(id)'")
        self.id = id
        self.summary = summary
    }

    /// Identity is the id alone — the summary is documentation.
    public static func == (lhs: PaymentRail, rhs: PaymentRail) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public var description: String { id }

    // MARK: - Well-known rails

    /// SEPA credit transfer (ordinary euro bank transfer).
    public static let sepaCreditTransfer = PaymentRail(id: "sepa_credit_transfer", summary: "SEPA credit transfer (euro bank transfer)")

    /// SEPA direct debit (PRLV — creditor-initiated euro bank debit).
    public static let sepaDirectDebit = PaymentRail(id: "sepa_direct_debit", summary: "SEPA direct debit (creditor-initiated)")

    /// Debit against a bank-issued or wallet-issued payment card.
    public static let cardDebit = PaymentRail(id: "card_debit", summary: "Bank or wallet card debit")

    /// Electronic wallet / e-money payment (PayPal, Apple Pay where funded by
    /// the wallet itself, etc.).
    public static let electronicPayment = PaymentRail(id: "electronic_payment", summary: "Electronic wallet / e-money payment")

    /// Physical cash, in person only. Held by CASH-kind accounts.
    public static let physicalCash = PaymentRail(id: "physical_cash", summary: "Physical cash, in person")

    /// The rails a normal euro bank account can settle on.
    public static let euroBankRails: Set<PaymentRail> = [.sepaCreditTransfer, .sepaDirectDebit, .cardDebit, .electronicPayment]

    /// The rails an e-money wallet (Revolut-style, euro IBAN + card) settles on.
    public static let euroWalletRails: Set<PaymentRail> = [.sepaCreditTransfer, .cardDebit, .electronicPayment]

    /// The only rail physical cash settles on.
    public static let cashOnlyRails: Set<PaymentRail> = [.physicalCash]

    // MARK: - Codable (id string; summary is re-derived for well-known ids)

    static let knownRails: [String: String] = [
        sepaCreditTransfer.id: sepaCreditTransfer.summary,
        sepaDirectDebit.id: sepaDirectDebit.summary,
        cardDebit.id: cardDebit.summary,
        electronicPayment.id: electronicPayment.summary,
        physicalCash.id: physicalCash.summary,
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let id = try container.decode(String.self)
        self.init(id: id, summary: PaymentRail.knownRails[id] ?? id)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

/// Encodes/decodes a `Set<PaymentRail>` as a **sorted** id array so that JSON
/// output is byte-deterministic (a Swift `Set` iterates in hash order).
public struct SortedRailSet: Codable {

    public var rails: Set<PaymentRail>

    public init(_ rails: Set<PaymentRail>) { self.rails = rails }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let ids = try container.decode([String].self)
        self.rails = Set(ids.map { PaymentRail(id: $0, summary: PaymentRail.knownRails[$0] ?? $0) })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rails.map(\.id).sorted())
    }
}
