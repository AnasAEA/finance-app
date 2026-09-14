/// Deterministic integer rounding rules used for every division in FinanceCore.
///
/// No `Double` and no `Foundation.Decimal` ever decides an authoritative money
/// value; divisions happen on integer minor units with one of these rules so
/// results are reproducible on every platform and run.
public enum RoundingRule: String, Sendable, Codable {

    /// Toward zero (truncation). The conservative rule for spending forecasts:
    /// a truncated remainder can only leave the projection with *less* money.
    case down

    /// Away from zero. The conservative rule for obligations: rounding a
    /// payment up can only require *more* money.
    case up

    /// Half away from zero — the common commercial rounding.
    case halfUp

    /// Ties to even (banker's rounding) — unbiased over many operations.
    case halfEven
}

/// Integer division with an explicit, sign-correct rounding rule.
///
/// - Requires: `divisor > 0`.
/// - Returns: `dividend / divisor` rounded per `rule`.
public func roundDivide(_ dividend: Int64, by divisor: Int64, rule: RoundingRule) -> Int64 {
    precondition(divisor > 0, "roundDivide requires a positive divisor, got \(divisor)")
    let quotient = dividend / divisor            // Swift truncates toward zero
    let remainder = dividend % divisor           // same sign as dividend
    if remainder == 0 { return quotient }

    let negative = dividend < 0
    let magnitude = remainder < 0 ? -remainder : remainder // |remainder|, in (0, divisor)
    let twice = magnitude * 2                     // cannot overflow: < 2*divisor

    var bump = false
    switch rule {
    case .down:
        bump = false
    case .up:
        bump = true
    case .halfUp:
        bump = twice >= divisor
    case .halfEven:
        if twice > divisor {
            bump = true
        } else if twice == divisor {
            bump = quotient % 2 != 0             // tie: choose the even neighbor
        }
    }
    guard bump else { return quotient }
    return negative ? quotient - 1 : quotient + 1
}
