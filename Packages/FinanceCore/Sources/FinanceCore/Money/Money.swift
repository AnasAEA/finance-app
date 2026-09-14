import Foundation

/// An amount of money in a specific currency, held as an **integer number of
/// minor units** (cents for EUR and MAD).
///
/// Invariants:
/// - Authoritative arithmetic is always integer arithmetic on `minorUnits`.
/// - `Double` is never used for authoritative money values anywhere in
///   FinanceCore.
/// - Adding or subtracting two amounts of different currencies is a
///   programming error and traps; currency conversion is only possible through
///   an explicit `ExchangeRate` (see `Money.converted(to:rule:)`).
///
/// Default Codable preserves Int64 minor units and explicit currency identity.
public struct Money: Hashable, Sendable, CustomStringConvertible, Codable {

    /// Signed integer minor units. Negative means a deficit/outflow direction
    /// where sign is meaningful (balances, legs). Always positive-or-signed
    /// depending on context — each call site documents its own convention.
    public let minorUnits: Int64

    public let currency: Currency

    public init(minorUnits: Int64, currency: Currency) {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    /// Creates a whole-major-unit amount, e.g. `Money(units: 459, .eur)` = €459.00.
    public init(units: Int64, currency: Currency) {
        self.init(minorUnits: units * currency.minorUnitsPerMajor, currency: currency)
    }

    /// Parses an exact decimal string such as `"-480.00"` in the given currency.
    /// The string must carry at most `currency.minorUnitDigits` fractional digits
    /// (no silent rounding on parse).
    public init?(exactDecimal: String, currency: Currency) {
        let digits = currency.minorUnitDigits
        var negative = false
        var text = Substring(exactDecimal)
        if text.hasPrefix("-") { negative = true; text = text.dropFirst() }
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let major = parts.first, !major.isEmpty, major.allSatisfy(\.isNumber) else { return nil }
        var minorText = parts.count == 2 ? Substring(parts[1]) : Substring("")
        guard minorText.allSatisfy(\.isNumber) else { return nil }
        guard minorText.count <= digits else { return nil }
        while minorText.count < digits { minorText += "0" }
        // Accumulate negatively so Int64.min needs no unrepresentable magnitude.
        var accumulated: Int64 = 0
        for byte in (String(major) + String(minorText)).utf8 {
            guard (48...57).contains(byte) else { return nil }
            let (scaled, multiplyOverflow) = accumulated.multipliedReportingOverflow(by: 10)
            let (next, subtractOverflow) = scaled.subtractingReportingOverflow(Int64(byte - 48))
            guard !multiplyOverflow, !subtractOverflow else { return nil }
            accumulated = next
        }
        guard negative || accumulated != Int64.min else { return nil }
        self.init(minorUnits: negative ? accumulated : -accumulated, currency: currency)
    }

    /// Creates an amount from an exact decimal string, trapping on malformed
    /// input. For parsing untrusted input use the failable
    /// `init(exactDecimal:currency:)`.
    public init(exactDecimal: String, currencyCode: String) {
        guard let money = Money(exactDecimal: exactDecimal, currency: Currency(code: currencyCode)) else {
            preconditionFailure("Invalid money decimal '\(exactDecimal)' for \(currencyCode)")
        }
        self = money
    }

    // MARK: - Predicates

    public var isZero: Bool { minorUnits == 0 }
    public var isNegative: Bool { minorUnits < 0 }
    public var isPositive: Bool { minorUnits > 0 }

    public var negated: Money { Money(minorUnits: -minorUnits, currency: currency) }
    public var magnitude: Money { Money(minorUnits: minorUnits < 0 ? -minorUnits : minorUnits, currency: currency) }

    // MARK: - Arithmetic (single-currency only)

    public static func + (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currency == rhs.currency, "Cannot add \(lhs.currency) and \(rhs.currency) — convert explicitly via ExchangeRate")
        return Money(minorUnits: lhs.minorUnits + rhs.minorUnits, currency: lhs.currency)
    }

    public static func - (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currency == rhs.currency, "Cannot subtract \(lhs.currency) from \(rhs.currency) — convert explicitly via ExchangeRate")
        return Money(minorUnits: lhs.minorUnits - rhs.minorUnits, currency: lhs.currency)
    }

    /// Sums amounts in one currency. Traps if any amount has another currency.
    public static func sum<S: Sequence>(_ amounts: S, currency: Currency) -> Money where S.Element == Money {
        var total: Int64 = 0
        for amount in amounts {
            precondition(amount.currency == currency, "Cannot sum \(amount.currency) into \(currency)")
            total += amount.minorUnits
        }
        return Money(minorUnits: total, currency: currency)
    }

    /// Divides this amount by an integer factor with an explicit rounding rule.
    public func divided(by factor: Int64, rule: RoundingRule) -> Money {
        precondition(factor > 0, "division factor must be positive")
        return Money(minorUnits: roundDivide(minorUnits, by: factor, rule: rule), currency: currency)
    }

    /// Splits this amount into parts proportional to `ratios` such that the
    /// parts sum exactly back to `self` (largest-remainder method).
    ///
    /// Deterministic: residual minor units go to the earliest indices.
    /// - Requires: ratios are non-negative and sum > 0.
    public func allocated(ratios: [Int]) -> [Money] {
        precondition(!ratios.isEmpty, "ratios must not be empty")
        let total = ratios.reduce(0, +)
        precondition(total > 0, "ratios must sum above zero")
        precondition(ratios.allSatisfy { $0 >= 0 }, "ratios must be non-negative")

        let negative = self.minorUnits < 0
        let magnitudeUnits = negative ? -self.minorUnits : self.minorUnits
        var floors = ratios.map { ratio -> Int64 in
            // (magnitudeUnits * ratio) may exceed Int64 only for absurd values;
            // guard the multiplication explicitly.
            let (result, overflow) = magnitudeUnits.multipliedReportingOverflow(by: Int64(ratio))
            precondition(!overflow, "allocation overflow")
            return result / Int64(total)
        }
        let remainder = magnitudeUnits - floors.reduce(Int64(0), +)
        // Hand out leftover minor units one cent at a time, earliest index first.
        var index = 0
        for _ in 0..<remainder {
            floors[index % floors.count] += 1
            index += 1
        }
        return floors.map {
            Money(minorUnits: negative ? -$0 : $0, currency: currency)
        }
    }

    // MARK: - Conversion

    /// Converts through an explicitly supplied rate. There is **no** implicit
    /// FX behavior anywhere in FinanceCore; a conversion event must be stated.
    public func converted(to target: Currency, rate: ExchangeRate, rule: RoundingRule) -> Money {
        rate.convert(self, to: target, rule: rule)
    }

    // MARK: - Description / Codable

    public var description: String { "\(decimalString) \(currency.code)" }

    /// Exact fixed-point rendering, e.g. `-480.00`, honoring minor-unit digits.
    public var decimalString: String {
        let digits = currency.minorUnitDigits
        let negative = minorUnits < 0
        let magnitude = minorUnits.magnitude
        let perMajor = UInt64(currency.minorUnitsPerMajor)
        var major = String(magnitude / perMajor)
        if digits > 0 {
            var minor = String(magnitude % perMajor)
            while minor.count < digits { minor = "0" + minor }
            major += "." + minor
        }
        return negative ? "-" + major : major
    }

    private enum CodingKeys: String, CodingKey { case minorUnits, currency }

    public init(from decoder: Decoder) throws {
        if decoder.userInfo[.financeDocumentMoneyWire] as? InterchangeFormat == .v1 {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let parts = raw.split(separator: " ")
            guard parts.count == 2,
                  let currency = try? Currency.validating(code: String(parts[1]),
                    exponent: Currency.legacyDefaultDigits(String(parts[1]))),
                  let amount = Money(exactDecimal: String(parts[0]), currency: currency) else {
                throw DecodingError.dataCorruptedError(in: container,
                    debugDescription: "Invalid legacy money string")
            }
            self = amount
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(minorUnits: try container.decode(Int64.self, forKey: .minorUnits),
                      currency: try container.decode(Currency.self, forKey: .currency))
        }
    }

    public func encode(to encoder: Encoder) throws {
        if encoder.userInfo[.financeDocumentMoneyWire] as? InterchangeFormat == .v1 {
            guard currency.isRepresentableInV1 else {
                throw InterchangeError.notRepresentableInV1(field: monetaryCodingPath(encoder.codingPath))
            }
            var container = encoder.singleValueContainer()
            try container.encode(description)
        } else {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(minorUnits, forKey: .minorUnits)
            try container.encode(currency, forKey: .currency)
        }
    }
}
