import Foundation

/// Why an entry could not be recorded.
///
/// Every rejection the entry path can produce is named here, in product terms,
/// so the sheet can say what is wrong instead of closing over a save that never
/// happened. There is no "it quietly did nothing" case: `add` either persists
/// the entry or throws one of these.
enum AppEntryError: Error, Hashable, Sendable {
    /// A fixed preview/test store was asked to record something.
    case storeIsReadOnly
    /// The amount is missing, unreadable, or not a positive figure.
    case invalidAmount
    /// The figure carries more decimals than the currency has.
    case excessPrecision(currencyCode: String, allowedFractionDigits: Int)
    /// The chosen account is not in the document any more.
    case unknownAccount(id: String)
    /// An inactive account remains visible in history but cannot receive a new
    /// transaction leg.
    case inactiveAccount(id: String)
    /// The amount is denominated in something the account does not hold.
    case amountCurrencyMismatch(amountCurrency: String, accountCurrency: String)
    /// A transfer without a destination.
    case missingCounterAccount
    /// Source and destination are the same account.
    case counterAccountIsSource
    case unknownCounterAccount(id: String)
    case inactiveCounterAccount(id: String)
    /// A plain transfer between two different currencies. Converting is a
    /// separate, explicitly-rated event, not something entry may assume.
    case transferCurrencyMismatch(from: String, to: String)
    case missingIncomeSource
    case unknownIncomeSource(id: String)
    case inactiveIncomeSource(id: String)
    /// A share that is not a positive amount of the same currency, or is larger
    /// than the sum it is a share of.
    case invalidOwnShare
    /// Partial ownership of an expense has no economics behind it yet, so the
    /// app refuses to record one rather than store a figure it cannot honour.
    case sharedExpenseNotSupported
    /// The supplied civil date is not a real calendar day.
    case invalidDate
    case currentDayUnavailable

    /// A date the calculation needed — a forecast horizon, a period edge —
    /// lies outside the range this build can express. Answering with a shorter
    /// horizon would answer a different question.
    case forecastUnavailable

    /// The entry mapped cleanly but the store could not be written.
    case persistenceFailed(String)

    /// One sentence, addressed to the person who just tapped Save.
    var message: String {
        switch self {
        case .storeIsReadOnly:
            "This is a preview. Entries are not saved here."
        case .invalidAmount:
            "Enter an amount greater than zero."
        case let .excessPrecision(currencyCode, digits):
            digits == 0
                ? "\(currencyCode) amounts have no decimals."
                : "\(currencyCode) amounts have at most \(digits) decimals."
        case .unknownAccount:
            "That account is no longer available. Choose another one."
        case .inactiveAccount:
            "That account is inactive. Choose an active account."
        case let .amountCurrencyMismatch(amountCurrency, accountCurrency):
            "This account holds \(accountCurrency), not \(amountCurrency)."
        case .missingCounterAccount:
            "Choose the account the money goes to."
        case .counterAccountIsSource:
            "A transfer needs two different accounts."
        case .unknownCounterAccount:
            "That destination account is no longer available."
        case .inactiveCounterAccount:
            "That destination account is inactive. Choose an active account."
        case let .transferCurrencyMismatch(from, to):
            "A transfer cannot move \(from) into a \(to) account. Recording the exchange rate is a separate step."
        case .missingIncomeSource:
            "Choose the economic income source."
        case .unknownIncomeSource:
            "That income source is no longer available. Choose another one."
        case .inactiveIncomeSource:
            "That income source is inactive. Choose an active source."
        case .invalidOwnShare:
            "Your share has to be a positive amount, no larger than the total."
        case .sharedExpenseNotSupported:
            "Splitting an expense is not supported yet. Record what you actually paid."
        case .invalidDate:
            "Choose a real calendar date."
        case .currentDayUnavailable:
            "The current day could not be read. Try again."
        case .forecastUnavailable:
            "This cannot be worked out: the dates involved fall outside the range this app can calculate."
        case let .persistenceFailed(reason):
            "The entry could not be saved: \(reason)"
        }
    }
}
