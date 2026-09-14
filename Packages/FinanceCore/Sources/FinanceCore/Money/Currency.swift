import Foundation

/// A currency identified by its ISO-4217-style alphabetic code, together with
/// the number of minor-unit digits it uses for authoritative money arithmetic.
///
/// The type is deliberately not an enum: the system must not be hardcoded to
/// EUR/MAD. Well-known instances are provided as constants; unknown codes
/// are allowed with an explicit exponent in the lossless default wire format.
///
/// Equality and hashing consider **both** the code and the minor-unit digits,
/// so two values that disagree about digits can never quietly compare equal.
public struct Currency: Hashable, Sendable, CustomStringConvertible, Codable {

    public let code: String
    public let minorUnitDigits: Int

    /// Creates a currency.
    ///
    /// - Requires: `code` is exactly three uppercase ASCII letters and
    ///   `minorUnitDigits` is in `0...6`.
    public init(code: String, minorUnitDigits: Int) {
        precondition(Self.isValidCode(code), "Currency code must be exactly 3 uppercase ASCII letters, got '\(code)'")
        precondition((0...6).contains(minorUnitDigits), "minorUnitDigits must be in 0...6, got \(minorUnitDigits)")
        self.code = code
        self.minorUnitDigits = minorUnitDigits
    }

    /// Creates a currency using the built-in minor-unit table, defaulting to 2.
    public init(code: String) {
        self.init(code: code, minorUnitDigits: Currency.knownMinorUnitDigits(code) ?? 2)
    }

    /// The number of minor units in one major unit, e.g. `100` for EUR.
    public var minorUnitsPerMajor: Int64 {
        var result: Int64 = 1
        for _ in 0..<minorUnitDigits { result *= 10 }
        return result
    }

    public var description: String { code }

    // MARK: - Well-known instances (convenience only, not an exhaustive list)

    public static let eur = Currency(code: "EUR", minorUnitDigits: 2)
    public static let mad = Currency(code: "MAD", minorUnitDigits: 2)
    public static let usd = Currency(code: "USD", minorUnitDigits: 2)
    public static let gbp = Currency(code: "GBP", minorUnitDigits: 2)
    public static let chf = Currency(code: "CHF", minorUnitDigits: 2)
    public static let dzd = Currency(code: "DZD", minorUnitDigits: 2)
    public static let jpy = Currency(code: "JPY", minorUnitDigits: 0)
    public static let kwd = Currency(code: "KWD", minorUnitDigits: 3)

    // MARK: - Validation helpers

    static func isValidCode(_ code: String) -> Bool {
        guard code.count == 3 else { return false }
        return code.allSatisfy { c in c.isASCII && c.isUppercase && c.isLetter }
    }

    /// Minor-unit digits for a small set of well-known ISO-4217 currencies that
    /// deviate from two. Anything else defaults to two digits at `init(code:)`.
    static func knownMinorUnitDigits(_ code: String) -> Int? {
        switch code {
        case "JPY", "KRW", "VND", "CLP": return 0
        case "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND": return 3
        default: return nil
        }
    }

    /// Historical V1 interpretation. Never extend this table for new support.
    public static func legacyDefaultDigits(_ code: String) -> Int {
        switch code {
        case "JPY", "KRW", "VND", "CLP": return 0
        case "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND": return 3
        default: return 2
        }
    }

    public enum ValidationError: Error, Equatable { case invalidCode, invalidExponent }

    public static func validating(code: String, exponent: Int) throws -> Currency {
        guard isValidCode(code) else { throw ValidationError.invalidCode }
        guard (0...6).contains(exponent) else { throw ValidationError.invalidExponent }
        return Currency(code: code, minorUnitDigits: exponent)
    }

    public var isRepresentableInV1: Bool {
        minorUnitDigits == Self.legacyDefaultDigits(code)
    }

    private enum CodingKeys: String, CodingKey { case code, exponent }

    public init(from decoder: Decoder) throws {
        do {
            if decoder.userInfo[.financeDocumentMoneyWire] as? InterchangeFormat == .v1 {
                let code = try decoder.singleValueContainer().decode(String.self)
                self = try Self.validating(code: code, exponent: Self.legacyDefaultDigits(code))
            } else {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self = try Self.validating(
                    code: container.decode(String.self, forKey: .code),
                    exponent: container.decode(Int.self, forKey: .exponent)
                )
            }
        } catch is ValidationError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid currency metadata"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        if encoder.userInfo[.financeDocumentMoneyWire] as? InterchangeFormat == .v1 {
            guard isRepresentableInV1 else {
                throw InterchangeError.notRepresentableInV1(field: monetaryCodingPath(encoder.codingPath))
            }
            var container = encoder.singleValueContainer()
            try container.encode(code)
        } else {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(code, forKey: .code)
            try container.encode(minorUnitDigits, forKey: .exponent)
        }
    }
}
