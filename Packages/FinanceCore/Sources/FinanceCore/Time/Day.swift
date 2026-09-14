import Foundation

/// A calendar day in the proleptic Gregorian calendar, implemented from first
/// principles with **no Foundation `Date`, `Calendar` or time-zone** anywhere.
///
/// A day-level forecast engine must be deterministic: "2026-09-11" means the
/// same instant-independent day on every machine, every run, every time zone.
/// Comparison and civil formatting support every Int year.
///
/// Ordinal arithmetic is **checked**. The structural year domain is the whole
/// of `Int`, so a day's epoch ordinal — roughly `year * 365.2425` — does not
/// always fit in `Int`. Every narrower operation therefore represents its own
/// failure rather than trapping: `index` and `days(until:)` are optional, and
/// `advanced(by:)` returns nil only when the *result* leaves the structural
/// domain. None of them clamps, wraps, or substitutes a nearby day.
///
/// Codable retains the four-digit-year string `"2026-09-11"`; expanded civil
/// years can be formatted but cannot be encoded in that interchange format.
public struct Day: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {

    public let year: Int
    public let month: Int     // 1...12
    public let day: Int       // 1...daysInMonth(year:month:)

    public init(year: Int, month: Int, day: Int) {
        precondition(Self.validComponents(year: year, month: month, day: day), "invalid civil day components")
        self.year = year
        self.month = month
        self.day = day
    }

    /// Runtime component validation. Every Int year is structurally valid.
    public init?(validatingYear year: Int, month: Int, day: Int) {
        guard Self.validComponents(year: year, month: month, day: day) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    private static func validComponents(year: Int, month: Int, day: Int) -> Bool {
        guard (1...12).contains(month) else { return false }
        return (1...daysInMonth(year: year, month: month)).contains(day)
    }

    /// Signed number of civil days relative to 1970-01-01, which is index 0.
    ///
    /// Nil **exactly** when the mathematical ordinal does not fit in `Int`.
    /// The determination is exact: the era product is evaluated at full width
    /// with the day-of-era offset folded in, so a value whose final ordinal
    /// fits is never rejected because an intermediate step would have
    /// overflowed. Ordinary days return the same `Int` they always did.
    public var index: Int? {
        let (era, doe) = Day.eraDecomposition(year, month, day)
        return Day.exactProduct(era, 146_097, plus: doe - 719_468)
    }

    /// Total for every `Int`: each epoch-day ordinal names one civil day whose
    /// year fits in `Int` (the extremes reach |year| ≈ 2.53e16, far inside the
    /// structural domain), so this initializer cannot fail.
    public init(index: Int) {
        let (y, m, d) = Day.civilFromDays(index)
        self.init(year: y, month: m, day: d)
    }

    // MARK: - Ordering

    public static func < (lhs: Day, rhs: Day) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }

    /// Exact signed day distance from `self` to `other`, negative when `other`
    /// is earlier. Nil **only** when that exact difference does not fit `Int`.
    ///
    /// Deliberately not `other.index - index`: two days whose absolute
    /// ordinals are both unrepresentable can still be zero or one day apart.
    /// The era decomposition is subtracted first, so the distance is exact
    /// wherever it is representable, at every structural year.
    public func days(until other: Day) -> Int? {
        let lhs = Day.eraDecomposition(year, month, day)
        let rhs = Day.eraDecomposition(other.year, other.month, other.day)
        // |era| <= |Int.min| / 400, so this difference cannot overflow.
        return Day.exactProduct(rhs.era - lhs.era, 146_097, plus: rhs.doe - lhs.doe)
    }

    /// Whether `other` lies within `limit` days of `self`, in either direction.
    ///
    /// The bounded-distance predicate finite-window callers want. A negative
    /// limit contains nothing. A separation too large to express as an `Int`
    /// is outside every finite window, so it is false for every nonnegative
    /// limit — and no step ever negates `Int.min`.
    public func isWithin(days limit: Int, of other: Day) -> Bool {
        guard limit >= 0, let distance = days(until: other) else { return false }
        // `limit >= 0`, so `-limit` is always representable.
        return distance >= -limit && distance <= limit
    }

    /// The day `days` after `self` (before, when negative).
    ///
    /// Nil when the resulting civil date would leave the structural `Int`-year
    /// domain — never a clamp to the boundary. Computed in era space rather
    /// than through `index`, so a day in an extreme structural year still
    /// advances locally: `advanced(by: 0)` is always `self`.
    public func advanced(by days: Int) -> Day? {
        let (era, doe) = Day.eraDecomposition(year, month, day)
        // Reduce the offset first so `doe + days` cannot overflow.
        let eras = Day.floorDiv(days, 146_097)
        var dayOfEra = doe + Day.floorMod(days, 146_097)   // [0, 292_192]
        var carry = eras
        if dayOfEra >= 146_097 { dayOfEra -= 146_097; carry += 1 }
        let (shifted, overflow) = era.addingReportingOverflow(carry)
        guard !overflow else { return nil }
        let (y, m, d) = Day.civilFromEra(era: shifted, dayOfEra: dayOfEra)
        guard let year = y else { return nil }
        return Day(year: year, month: m, day: d)
    }

    // MARK: - Month helpers

    public var monthKey: MonthKey { MonthKey(year: year, month: month) }

    public var firstDayOfMonth: Day { Day(year: year, month: month, day: 1) }

    public var lastDayOfMonth: Day { Day(year: year, month: month, day: Day.daysInMonth(year: year, month: month)) }

    /// The day-of-month clamped into this day's month length (e.g. day 31 → 30
    /// in April). Used by monthly recurrence expansion.
    public func clampedDay(_ dayOfMonth: Int) -> Day {
        precondition(dayOfMonth >= 1, "dayOfMonth must be >= 1")
        let length = Day.daysInMonth(year: year, month: month)
        return Day(year: year, month: month, day: min(dayOfMonth, length))
    }

    // MARK: - Calendar math (exact, Foundation-free)

    public static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: preconditionFailure("month must be 1...12, got \(month)")
        }
    }

    // Howard Hinnant's public-domain `days_from_civil` / `civil_from_days`,
    // rearranged so no step overflows for any Int year. The 400-year era is
    // entered through floored division and remainder instead of the published
    // `yy - 399` and `yy - era * 400` forms, both of which trap near `Int.min`;
    // the era product is then evaluated once, at full width.

    /// Floored quotient. `divisor` is always a positive literal here, so the
    /// `Int.min / -1` trap cannot arise.
    static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        let remainder = value % divisor
        return (remainder != 0 && (remainder < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    /// Floored remainder, always in `0..<divisor` for a positive divisor.
    static func floorMod(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return (remainder != 0 && (remainder < 0) != (divisor < 0)) ? remainder + divisor : remainder
    }

    /// Exactly `value * multiplier + offset`, or nil when that mathematical
    /// value does not fit in `Int`.
    ///
    /// Evaluated at 128-bit width. Checking the product alone would reject
    /// values a negative offset brings back into range, and checking left to
    /// right would reject `product + doe` for a `doe - 719_468` that lands
    /// inside it — both are false negatives this avoids.
    static func exactProduct(_ value: Int, _ multiplier: Int, plus offset: Int) -> Int? {
        let (high, low) = value.multipliedFullWidth(by: multiplier)
        // `offset` sign-extends into the high word; the low word carries.
        let (sumLow, carry) = low.addingReportingOverflow(UInt(bitPattern: offset))
        let (signed, signOverflow) = high.addingReportingOverflow(offset < 0 ? -1 : 0)
        guard !signOverflow else { return nil }
        let (sumHigh, carryOverflow) = signed.addingReportingOverflow(carry ? 1 : 0)
        guard !carryOverflow else { return nil }
        let result = Int(bitPattern: sumLow)
        // The 128-bit value fits in Int exactly when its high word is the sign
        // extension of the low word.
        guard (result < 0 ? -1 : 0) == sumHigh else { return nil }
        return result
    }

    /// Era and day-of-era for a civil date. Exact for every `Int` year: the
    /// March-based year shift is applied to the decomposition rather than to
    /// `year` itself, which would trap at `Int.min`.
    static func eraDecomposition(_ y: Int, _ m: Int, _ d: Int) -> (era: Int, doe: Int) {
        var era = floorDiv(y, 400)
        var yoe = floorMod(y, 400)                                 // [0, 399]
        if m <= 2 {                                                // civil year starts in March
            if yoe == 0 { yoe = 399; era -= 1 } else { yoe -= 1 }
        }
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1   // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy            // [0, 146096]
        return (era, doe)
    }

    /// Civil date for an era and day-of-era. The year is nil when it leaves
    /// the structural `Int` domain; month and day are always valid.
    static func civilFromEra(era: Int, dayOfEra doe: Int) -> (year: Int?, month: Int, day: Int) {
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 // [0, 399]
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)          // [0, 365]
        let mp = (5 * doy + 2) / 153                               // [0, 11]
        let d = doy - (153 * mp + 2) / 5 + 1                       // [1, 31]
        let m = mp + (mp < 10 ? 3 : -9)                            // [1, 12]
        return (exactProduct(era, 400, plus: yoe + (m <= 2 ? 1 : 0)), m, d)
    }

    /// Days from 1970-01-01 to the given civil date, when representable.
    static func daysFromCivil(_ y: Int, _ m: Int, _ d: Int) -> Int? {
        let (era, doe) = eraDecomposition(y, m, d)
        return exactProduct(era, 146_097, plus: doe - 719_468)
    }

    /// Inverse of `daysFromCivil`, total for every `Int` ordinal.
    ///
    /// The epoch shift is folded into the era decomposition — `719_468`
    /// is `4 * 146_097 + 135_080` — because adding it to `z` directly
    /// overflows near `Int.max`. The reconstructed year is bounded by
    /// `Int.max / 146_097 * 400`, so it always fits.
    static func civilFromDays(_ z: Int) -> (year: Int, month: Int, day: Int) {
        var era = floorDiv(z, 146_097) + 4
        var doe = floorMod(z, 146_097) + 135_080                   // [135_080, 281_176]
        if doe >= 146_097 { doe -= 146_097; era += 1 }
        let (y, m, d) = civilFromEra(era: era, dayOfEra: doe)
        guard let year = y else {
            preconditionFailure("civil year is bounded by Int.max / 146097 * 400 and always fits")
        }
        return (year, m, d)
    }

    // MARK: - Description / Codable

    public var description: String { isoString }

    /// Civil text uses signed expanded years outside 0000...9999. The parser
    /// and Codable intentionally retain the narrower four-digit wire grammar.
    public var isoString: String {
        formatYear(year) + "-" + format2(month) + "-" + format2(day)
    }

    /// Parses strict `"YYYY-MM-DD"`.
    public init?(isoString: String) {
        let parts = isoString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let value = Day(validatingYear: y, month: m, day: d)
        else { return nil }
        self = value
    }

    /// Parses the structural civil text `isoString` emits, including expanded
    /// signed years. Distinct from the four-digit Codable/`init?(isoString:)`
    /// interchange parser, which is intentionally narrower.
    public init?(structuralISOString raw: String) {
        if let day = Day(isoString: raw), day.isoString == raw {
            self = day
            return
        }
        guard raw.first == "+" || raw.first == "-", raw.count >= 11 else { return nil }
        let suffix = raw.suffix(6)
        guard suffix.first == "-" else { return nil }
        let monthDay = suffix.dropFirst()
        guard monthDay.count == 5 else { return nil }
        let monthSep = monthDay.index(monthDay.startIndex, offsetBy: 2)
        guard monthDay[monthSep] == "-" else { return nil }
        let monthText = monthDay[..<monthSep]
        let dayText = monthDay[monthDay.index(after: monthSep)...]
        guard monthText.utf8.allSatisfy({ (48...57).contains($0) }),
              dayText.utf8.allSatisfy({ (48...57).contains($0) }),
              monthText.count == 2, dayText.count == 2,
              let year = Int(raw.dropLast(6)),
              let month = Int(monthText),
              let day = Int(dayText),
              let value = Day(validatingYear: year, month: month, day: day),
              value.isoString == raw
        else { return nil }
        self = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let day = Day(isoString: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid day '\(raw)' — expected YYYY-MM-DD")
        }
        self = day
    }

    public func encode(to encoder: Encoder) throws {
        guard (0...9999).contains(year) else {
            throw EncodingError.invalidValue(self, .init(
                codingPath: encoder.codingPath,
                debugDescription: "Day interchange encoding requires a four-digit year"
            ))
        }
        var container = encoder.singleValueContainer()
        try container.encode(isoString)
    }
}

/// A calendar month identity, `"2026-09"`. Used by recurrence windows, budget
/// effective ranges and fixture overrides.
public struct MonthKey: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {

    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        precondition(Self.validMonth(month), "month must be 1...12, got \(month)")
        self.year = year
        self.month = month
    }

    public init?(validatingYear year: Int, month: Int) {
        guard Self.validMonth(month) else { return nil }
        self.init(year: year, month: month)
    }

    private static func validMonth(_ month: Int) -> Bool { (1...12).contains(month) }

    public init?(isoString: String) {
        let parts = isoString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let y = Int(parts[0]), let m = Int(parts[1]),
              let value = MonthKey(validatingYear: y, month: m)
        else { return nil }
        self = value
    }

    /// Parses the structural civil month text `isoString` emits, including
    /// expanded signed years. Distinct from the four-digit Codable parser.
    public init?(structuralISOString raw: String) {
        if let month = MonthKey(isoString: raw), month.isoString == raw {
            self = month
            return
        }
        guard raw.first == "+" || raw.first == "-", raw.count >= 8 else { return nil }
        let suffix = raw.suffix(3)
        guard suffix.first == "-" else { return nil }
        let monthText = suffix.dropFirst()
        guard monthText.count == 2,
              monthText.utf8.allSatisfy({ (48...57).contains($0) }),
              let year = Int(raw.dropLast(3)),
              let month = Int(monthText),
              let value = MonthKey(validatingYear: year, month: month),
              value.isoString == raw
        else { return nil }
        self = value
    }

    /// The following month, or nil at the end of the structural year domain.
    public var next: MonthKey? { advanced(byMonths: 1) }

    /// The preceding month, or nil at the start of the structural year domain.
    public var previous: MonthKey? { advanced(byMonths: -1) }

    /// This month moved by `offset` whole months, or nil when the result would
    /// leave the structural `Int`-year domain.
    ///
    /// Never `year * 12`: that overflows long before the year itself does. The
    /// offset is reduced into whole years plus a residue first, so only the
    /// final year addition can fail. `advanced(byMonths: 0)` is always `self`.
    public func advanced(byMonths offset: Int) -> MonthKey? {
        var index = (month - 1) + Day.floorMod(offset, 12)         // [0, 22]
        var years = Day.floorDiv(offset, 12)
        if index >= 12 { index -= 12; years += 1 }
        let (movedYear, overflow) = year.addingReportingOverflow(years)
        guard !overflow else { return nil }
        return MonthKey(year: movedYear, month: index + 1)
    }

    /// Total calendar ordering by (year, month).
    public static func < (lhs: MonthKey, rhs: MonthKey) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    public var firstDay: Day { Day(year: year, month: month, day: 1) }

    public func contains(_ day: Day) -> Bool { day.year == year && day.month == month }

    public var description: String { isoString }

    public var isoString: String { formatYear(year) + "-" + format2(month) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let key = MonthKey(isoString: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid month '\(raw)' — expected YYYY-MM")
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        guard (0...9999).contains(year) else {
            throw EncodingError.invalidValue(self, .init(
                codingPath: encoder.codingPath,
                debugDescription: "Month interchange encoding requires a four-digit year"
            ))
        }
        var container = encoder.singleValueContainer()
        try container.encode(isoString)
    }
}

// MARK: - Locale-independent civil formatting (no Foundation String(format:))

private func formatYear(_ value: Int) -> String {
    if (0...9999).contains(value) { return format4(value) }
    var digits = String(value.magnitude)
    while digits.count < 4 { digits = "0" + digits }
    return (value < 0 ? "-" : "+") + digits
}

func format2(_ value: Int) -> String {
    precondition((0...99).contains(value))
    return value < 10 ? "0" + String(value) : String(value)
}

func format4(_ value: Int) -> String {
    precondition((0...9999).contains(value))
    var out = String(value)
    while out.count < 4 { out = "0" + out }
    return out
}
