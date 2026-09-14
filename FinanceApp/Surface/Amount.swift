import Foundation

/// A monetary figure as the product displays it.
///
/// Deliberately not `FinanceCore.Money`. The screens need an amount they can
/// print, sign and compare; they do not need the engine's arithmetic type, and
/// binding them to it means every change to the core — the announced move to
/// `Int64` minor units among them — reaches into the views.
///
/// Minor units, never `Double`: the figures on these screens reconcile to the
/// cent, and the values arrive from a core that is already exact.
struct Amount: Hashable, Sendable, Codable {
    let minorUnits: Int64
    /// ISO-4217 alphabetic code, e.g. `"EUR"`.
    let currencyCode: String
    /// Digits in the minor unit — 2 for EUR and MAD.
    let fractionDigits: Int

    init(minorUnits: Int64, currencyCode: String, fractionDigits: Int = 2) {
        self.minorUnits = minorUnits
        self.currencyCode = currencyCode
        self.fractionDigits = fractionDigits
    }

    static func zero(_ currencyCode: String, fractionDigits: Int = 2) -> Amount {
        Amount(minorUnits: 0, currencyCode: currencyCode, fractionDigits: fractionDigits)
    }

    static let zeroEUR = Amount.zero("EUR")

    /// Euro amount from major units, for fixtures and tests: `.eur(480.00)`.
    static func eur(_ majorUnits: Decimal) -> Amount {
        var scaled = majorUnits * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return Amount(minorUnits: Int64(truncating: NSDecimalNumber(decimal: rounded)), currencyCode: "EUR")
    }

    var isZero: Bool { minorUnits == 0 }
    var isNegative: Bool { minorUnits < 0 }
    var isPositive: Bool { minorUnits > 0 }

    var negated: Amount { Amount(minorUnits: -minorUnits, currencyCode: currencyCode, fractionDigits: fractionDigits) }
    var magnitude: Amount { Amount(minorUnits: abs(minorUnits), currencyCode: currencyCode, fractionDigits: fractionDigits) }

    /// Clamped at zero, keeping the currency. Used where a displayed figure is
    /// defined to be non-negative.
    var clampedToZero: Amount { isNegative ? .zero(currencyCode, fractionDigits: fractionDigits) : self }

    private var minorUnitsPerMajor: Int {
        (0..<fractionDigits).reduce(1) { total, _ in total * 10 }
    }

    /// The plain decimal an editable text field starts from: no symbol, no
    /// grouping, so what is typed back parses without locale guesswork.
    var editingText: String {
        let sign = isNegative ? "-" : ""
        let units = abs(minorUnits)
        guard fractionDigits > 0 else { return sign + String(units) }
        let per = Int64(minorUnitsPerMajor)
        let major = units / per
        let minor = units % per
        return sign + String(major) + "." + String(format: "%0\(fractionDigits)lld", minor)
    }

    var decimalValue: Decimal {
        Decimal(minorUnits) / Decimal(minorUnitsPerMajor)
    }

    /// For the runway chart, which plots in `Double` whatever it is given.
    var chartValue: Double {
        Double(minorUnits) / Double(minorUnitsPerMajor)
    }
}

// MARK: - Arithmetic

/// Defined only within one currency, for the same reason the core defines it
/// that way: adding euros to dirhams produces a number that is wrong in a way
/// nothing downstream can detect.
extension Amount {
    private static func requireSameCurrency(_ a: Amount, _ b: Amount) {
        precondition(
            a.currencyCode == b.currencyCode,
            "cannot combine \(a.currencyCode) with \(b.currencyCode)"
        )
    }

    static func + (a: Amount, b: Amount) -> Amount {
        requireSameCurrency(a, b)
        return Amount(minorUnits: a.minorUnits + b.minorUnits, currencyCode: a.currencyCode, fractionDigits: a.fractionDigits)
    }

    static func - (a: Amount, b: Amount) -> Amount {
        requireSameCurrency(a, b)
        return Amount(minorUnits: a.minorUnits - b.minorUnits, currencyCode: a.currencyCode, fractionDigits: a.fractionDigits)
    }
}

extension Amount: Comparable {
    static func < (a: Amount, b: Amount) -> Bool {
        requireSameCurrency(a, b)
        return a.minorUnits < b.minorUnits
    }
}

// MARK: - Display

extension Amount {
    /// Locale-aware currency text, e.g. `€396.00`, `200 MAD`.
    func formatted(
        locale: Locale = .current,
        showsSign: Bool = false,
        omitsFractionWhenWhole: Bool = false
    ) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = currencyCode
        let dropFraction = omitsFractionWhenWhole && minorUnits % Int64(minorUnitsPerMajor) == 0
        formatter.minimumFractionDigits = dropFraction ? 0 : fractionDigits
        formatter.maximumFractionDigits = dropFraction ? 0 : fractionDigits
        if showsSign { formatter.positivePrefix = "+" + (formatter.positivePrefix ?? "") }

        let number = NSDecimalNumber(decimal: decimalValue)
        return formatter.string(from: number) ?? "\(decimalValue) \(currencyCode)"
    }

    /// A spoken form for VoiceOver.
    func accessibleDescription(locale: Locale = .current) -> String {
        formatted(locale: locale)
    }
}

extension Amount: CustomStringConvertible {
    var description: String { "\(decimalValue) \(currencyCode)" }
}

// MARK: - Typed entry

extension Amount {
    /// Why a typed figure is not an amount in this currency.
    enum ParseFailure: Error, Hashable, Sendable {
        case empty
        case notANumber
        /// More decimals than the currency has minor units for.
        case excessPrecision(allowed: Int)
    }

    /// Reads a hand-typed figure as minor units of `currencyCode`.
    ///
    /// The scale comes from the account the entry is going to, never from a
    /// constant: `12.34` is 1234 minor units in EUR, `123` is 123 in JPY, and
    /// `12.345` is 12345 in KWD. A figure with more decimals than the currency
    /// has is rejected rather than rounded — silently turning ¥123.5 into ¥124
    /// or ¥123 invents a number the person did not type.
    static func parse(
        _ text: String,
        currencyCode: String,
        fractionDigits: Int
    ) throws -> Amount {
        let normalised = text
            .replacingOccurrences(of: ",", with: ".")
            .filter { !$0.isWhitespace }
        guard !normalised.isEmpty else { throw ParseFailure.empty }

        // `Decimal(string:)` happily parses a prefix, so "12abc" would read as
        // 12. Entry has to reject that, not quietly accept part of it.
        var digitsSeen = false
        var separatorsSeen = 0
        for character in normalised {
            if character.isASCII, character.isNumber { digitsSeen = true; continue }
            if character == "." { separatorsSeen += 1; continue }
            throw ParseFailure.notANumber
        }
        guard digitsSeen, separatorsSeen <= 1 else { throw ParseFailure.notANumber }

        guard let value = Decimal(string: normalised, locale: Locale(identifier: "en_US_POSIX")) else {
            throw ParseFailure.notANumber
        }

        var scaled = value * Decimal(sign: .plus, exponent: fractionDigits, significand: 1)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { throw ParseFailure.excessPrecision(allowed: fractionDigits) }

        return Amount(
            minorUnits: Int64(truncating: NSDecimalNumber(decimal: rounded)),
            currencyCode: currencyCode,
            fractionDigits: fractionDigits
        )
    }
}
