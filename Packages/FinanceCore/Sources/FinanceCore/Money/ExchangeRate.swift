/// An exchange rate expressed as an **exact rational number** between the
/// minor units of two currencies.
///
/// FinanceCore never performs automatic FX conversion and never invents a
/// market rate. A rate is always supplied explicitly — typically *observed*
/// from a real conversion event (`ExchangeRate.observed(fromAmount:toAmount:)`),
/// e.g. the ATM withdrawal that turned €30.00 into 200 MAD.
///
/// `to = from × numerator / denominator`, computed in integer arithmetic with
/// an explicit rounding rule.
public struct ExchangeRate: Hashable, Sendable, Codable {

    public let from: Currency
    public let to: Currency

    /// Positive rational multiplier in minor units (e.g. 20000/3000 for the
    /// observed €30.00 → 200 MAD withdrawal).
    public let numerator: Int64
    public let denominator: Int64

    /// Creates a rate from a rational multiplier in minor units.
    /// - Requires: numerator and denominator are strictly positive.
    public init(from: Currency, to: Currency, numerator: Int64, denominator: Int64) {
        precondition(numerator > 0 && denominator > 0, "rate terms must be strictly positive")
        self.from = from
        self.to = to
        self.numerator = numerator
        self.denominator = denominator
    }

    /// Records the rate actually observed when one real amount became another
    /// (e.g. an ATM withdrawal or an explicit currency exchange).
    /// This is an *observation*, never an assumption.
    public static func observed(fromAmount: Money, toAmount: Money) -> ExchangeRate {
        precondition(fromAmount.isPositive && toAmount.isPositive, "observed amounts must be positive")
        return ExchangeRate(from: fromAmount.currency, to: toAmount.currency,
                            numerator: toAmount.minorUnits, denominator: fromAmount.minorUnits)
    }

    public var inverted: ExchangeRate {
        ExchangeRate(from: to, to: from, numerator: denominator, denominator: numerator)
    }

    /// Applies the rate. Traps if `money.currency != from` (a conversion must
    /// never be applied to the wrong side of the rate).
    public func convert(_ money: Money, to target: Currency, rule: RoundingRule) -> Money {
        precondition(money.currency == from, "conversion direction mismatch: rate converts \(from) but got \(money.currency)")
        precondition(target == to, "conversion target mismatch: rate converts to \(to) but got \(target)")
        let (scaled, overflow) = money.minorUnits.multipliedReportingOverflow(by: numerator)
        precondition(!overflow, "exchange conversion overflows Int64")
        return Money(minorUnits: roundDivide(scaled, by: denominator, rule: rule), currency: target)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case from, to, numerator, denominator
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.from = try container.decode(Currency.self, forKey: .from)
        self.to = try container.decode(Currency.self, forKey: .to)
        self.numerator = try container.decode(Int64.self, forKey: .numerator)
        self.denominator = try container.decode(Int64.self, forKey: .denominator)
        precondition(numerator > 0 && denominator > 0, "rate terms must be strictly positive")
    }
}
