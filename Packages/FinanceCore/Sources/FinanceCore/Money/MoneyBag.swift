import Foundation

/// A multi-currency bag of money: several `Money` amounts, each kept in its
/// own currency, with **no implicit conversion anywhere**.
///
/// A MoneyBag can hold €54.00 *and* 200 MAD at the same time, but it can
/// never add them together: there is no `total`, no `sum`, and no way to ask
/// "how much is this worth" without supplying an explicit conversion policy.
/// Merging two bags is per-currency and exact; `amount(in:)` returns zero for
/// currencies the bag does not hold.
///
/// This is the honest representation of *tracked holdings*: total wealth that
/// cannot settle each other's obligations (dirhams do not pay a SEPA debit)
/// must not be collapsed into one number.
public struct MoneyBag: Hashable, Sendable, CustomStringConvertible, Codable {

    /// Minor units per currency. Only non-zero entries are ever stored —
    /// a currency with no money is absent, not zero (so `currencies` lists
    /// real holdings only).
    private var storage: [Currency: Int64]

    /// An empty bag.
    public init() {
        self.storage = [:]
    }

    /// A bag holding exactly one amount.
    public init(_ money: Money) {
        self.storage = money.isZero ? [:] : [money.currency: money.minorUnits]
    }

    /// A bag from several amounts (same as starting empty and adding each).
    public init<S: Sequence>(_ amounts: S) where S.Element == Money {
        self.storage = [:]
        for money in amounts { add(money) }
    }

    // MARK: - Reading

    /// The currencies this bag actually holds, in a **total** order: ISO code
    /// first, then minor-unit digits.
    ///
    /// The tie-break is not decoration. `Currency` hashes on both its code and
    /// its digit count, so a bag can hold two currencies sharing a code and
    /// disagreeing about digits. Ordering on the code alone leaves those two
    /// equal to the comparator, and `sort` is not stable, so their relative
    /// order came from wherever the dictionary's hash seed happened to put
    /// them — different on each run of the same program.
    public var currencies: [Currency] {
        storage.keys.sorted { ($0.code, $0.minorUnitDigits) < ($1.code, $1.minorUnitDigits) }
    }

    /// Whether every currency holds zero (equivalently: no currencies).
    public var isEmpty: Bool { storage.isEmpty }

    /// The amount held in `currency` — zero when nothing is held there.
    public func amount(in currency: Currency) -> Money {
        Money(minorUnits: storage[currency] ?? 0, currency: currency)
    }

    // MARK: - Adding / removing (per currency, never converting)

    /// Adds `money` in its own currency. Never converts, never rounds.
    public mutating func add(_ money: Money) {
        guard !money.isZero else { return }
        storage[money.currency, default: 0] += money.minorUnits
        if storage[money.currency] == 0 { storage[money.currency] = nil }
    }

    /// Subtracts `money` in its own currency. Never converts, never rounds.
    /// May drive that currency's entry negative.
    public mutating func subtract(_ money: Money) {
        add(money.negated)
    }

    /// A copy with `money` added.
    public func adding(_ money: Money) -> MoneyBag {
        var copy = self
        copy.add(money)
        return copy
    }

    /// A copy with `money` subtracted.
    public func subtracting(_ money: Money) -> MoneyBag {
        var copy = self
        copy.subtract(money)
        return copy
    }

    /// Merges `other` into a new bag, per currency. Never converts.
    public static func + (lhs: MoneyBag, rhs: MoneyBag) -> MoneyBag {
        var merged = lhs
        for currency in rhs.storage.keys {
            merged.storage[currency, default: 0] += rhs.storage[currency]!
            if merged.storage[currency] == 0 { merged.storage[currency] = nil }
        }
        return merged
    }

    /// The zero bag in every currency.
    public static let empty = MoneyBag()

    // MARK: - Description / Codable

    public var description: String {
        currencies.map { "\($0.code) \(amount(in: $0).decimalString)" }
            .joined(separator: " + ")
    }

    /// Encodes one entry per held currency, ordered by code then exponent.
    /// Historical currencies retain `["CODE", minorUnits]`; other exponents
    /// use `[["CODE", exponent], minorUnits]`. The nested first element makes
    /// the explicit form structurally disjoint from the historical decoder,
    /// which required a String first and ignored everything after minorUnits.
    /// In particular, `["EUR",4,100]` must still mean four minor units of EUR/2.
    ///
    /// Arrays preserve deterministic bytes under a bare JSONEncoder. Keyed
    /// objects would require every caller to remember `.sortedKeys`.
    private struct Entry: Decodable {
        /// Nil only for a legacy zero, whose metadata was historically ignored.
        let currency: Currency?
        let minorUnits: Int64

        private enum ObjectKey: String, CodingKey { case currency, minorUnits }

        init(from decoder: Decoder) throws {
            if var entry = try? decoder.unkeyedContainer() {
                // Advance the outer entry once. Shape probing happens on this
                // element's own decoder, never by retrying a failed value decode
                // on a shared unkeyed cursor.
                let first = try entry.superDecoder()
                if var metadata = try? first.unkeyedContainer() {
                    let code = try metadata.decode(String.self)
                    let exponent = try metadata.decode(Int.self)
                    guard metadata.isAtEnd else {
                        throw DecodingError.dataCorruptedError(
                            in: metadata, debugDescription: "Explicit money bag currency must have two elements")
                    }
                    minorUnits = try entry.decode(Int64.self)
                    guard entry.isAtEnd else {
                        throw DecodingError.dataCorruptedError(
                            in: entry, debugDescription: "Explicit money bag entry must have two elements")
                    }
                    currency = try Self.currency(code: code, exponent: exponent, at: decoder.codingPath)
                } else {
                    let code = try first.singleValueContainer().decode(String.self)
                    minorUnits = try entry.decode(Int64.self)
                    // Legacy arrays ignore ALL trailing values. Zero entries
                    // skip code validation, just as the historical reader did.
                    currency = minorUnits == 0 ? nil : try Self.currency(
                        code: code, exponent: Currency.legacyDefaultDigits(code), at: decoder.codingPath)
                }
            } else {
                // Required legacy fields keep their types; unknown keys are
                // ignored, including any exponent-like key beside a bare code.
                let object = try decoder.container(keyedBy: ObjectKey.self)
                let code = try object.decode(String.self, forKey: .currency)
                minorUnits = try object.decode(Int64.self, forKey: .minorUnits)
                currency = minorUnits == 0 ? nil : try Self.currency(
                    code: code, exponent: Currency.legacyDefaultDigits(code), at: decoder.codingPath)
            }
        }

        private static func currency(code: String, exponent: Int,
                                     at path: [any CodingKey]) throws -> Currency {
            do {
                return try Currency.validating(code: code, exponent: exponent)
            } catch {
                throw DecodingError.dataCorrupted(.init(codingPath: path,
                    debugDescription: "Invalid money bag currency"))
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let entries = try container.decode([Entry].self)
        self.storage = [:]
        for entry in entries {
            guard entry.minorUnits != 0, let currency = entry.currency else { continue }
            // Keyed on the whole currency identity: EUR/2 and EUR/4 are two
            // holdings, and only a repeat of the same code *and* exponent is
            // a duplicate.
            guard storage[currency] == nil else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Duplicate currency \(currency.code)/\(currency.minorUnitDigits) in money bag"
                )
            }
            storage[currency] = entry.minorUnits
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for currency in currencies {
            var entry = container.nestedUnkeyedContainer()
            if currency.isRepresentableInV1 {
                try entry.encode(currency.code)
            } else {
                var metadata = entry.nestedUnkeyedContainer()
                try metadata.encode(currency.code)
                try metadata.encode(currency.minorUnitDigits)
            }
            try entry.encode(storage[currency]!)
        }
    }
}
