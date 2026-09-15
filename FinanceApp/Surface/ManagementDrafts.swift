import Foundation

/// A user-managed account edit. `id == nil` creates a new stable identity;
/// editing keeps that identity and never rewrites historical transaction legs.
struct AccountDraft: Hashable, Sendable {
    var id: String?
    var name: String
    var kind: HoldingKind
    var currencyCode: String
    var fractionDigits: Int
    var openingBalance: Amount
    var openingBalanceDay: CalendarDay
    var isActive: Bool
}

/// Product-facing income-source fields. The core-owned amount, schedule and
/// dependency graph are preserved when an existing planning source is edited.
struct IncomeSourceDraft: Hashable, Sendable {
    var id: String?
    var name: String
    var certainty: IncomeCertaintyOption
    var isActive: Bool
    var preferredAccountID: String?
    var note: String?
}

struct CurrencyOption: Identifiable, Hashable, Sendable {
    var id: String { code }
    let code: String
    let name: String
    let fractionDigits: Int

    /// Common choices, not an exhaustive statement of supported accounts.
    /// The domain remains code/exponent based and imported currencies retain
    /// their recorded exponent even when absent from this convenience list.
    static let common: [CurrencyOption] = [
        .init(code: "EUR", name: "Euro", fractionDigits: 2),
        .init(code: "MAD", name: "Moroccan dirham", fractionDigits: 2),
        .init(code: "USD", name: "US dollar", fractionDigits: 2),
        .init(code: "GBP", name: "Pound sterling", fractionDigits: 2),
        .init(code: "CHF", name: "Swiss franc", fractionDigits: 2),
        .init(code: "DZD", name: "Algerian dinar", fractionDigits: 2),
        .init(code: "JPY", name: "Japanese yen", fractionDigits: 0),
        .init(code: "KWD", name: "Kuwaiti dinar", fractionDigits: 3)
    ]
}

enum AppManagementError: Error, Hashable, Sendable {
    case storeIsReadOnly
    case nameRequired
    case invalidCurrency
    case openingBalanceCurrencyMismatch
    case unknownAccount
    case unknownIncomeSource
    case inactivePreferredAccount
    case unknownBudget
    case invalidBudgetAmount
    case invalidSafetyReserve
    case duplicateBudgetCategory(String)
    case unknownPlannedPurchase
    case unknownSinkingFund
    case sinkingFundStillReferenced
    case plannedPurchaseStillReferenced
    case invalidDate
    case invalidAmount
    case planningInvalid(String)
    case affordability(String)
    case persistenceFailed(String)

    var message: String {
        switch self {
        case .storeIsReadOnly: "This is a preview. Changes are not saved here."
        case .nameRequired: "Enter a name."
        case .invalidCurrency: "Choose a valid three-letter currency and exponent."
        case .openingBalanceCurrencyMismatch: "The opening balance must use the account currency."
        case .unknownAccount: "That account is no longer available."
        case .unknownIncomeSource: "That income source is no longer available."
        case .inactivePreferredAccount: "Choose an active preferred receiving account."
        case .unknownBudget: "That budget line is no longer available."
        case .invalidBudgetAmount: "Enter a target of zero or more, in euro."
        case .invalidSafetyReserve: "Enter a reserve of zero or more, in euro."
        case let .duplicateBudgetCategory(name):
            "\(name) already counts towards another budget line. A category can only feed one."
        case .unknownPlannedPurchase: "That planned purchase is no longer available."
        case .unknownSinkingFund: "That sinking fund is no longer available."
        case .sinkingFundStillReferenced:
            "A planned purchase still uses this sinking fund. Remove that link first."
        case .plannedPurchaseStillReferenced:
            "A sinking fund still names this planned purchase. Remove that link first."
        case .invalidDate: "Choose a real calendar date."
        case .invalidAmount:
            "Enter an amount greater than zero, using the currency's decimal places."
        case let .planningInvalid(reason): reason
        case let .affordability(reason): reason
        case let .persistenceFailed(reason): "The change could not be saved: \(reason)"
        }
    }
}

/// What the budget editor sends back for one line.
///
/// Editing a line is an act of agreement: a target the person typed or
/// accepted stops being a suggestion. That is why there is no "confirmed"
/// field here for the UI to forget to set — saving a draft *is* the
/// confirmation.
struct BudgetLineDraft: Hashable, Sendable, Identifiable {
    /// `nil` creates a new line.
    var id: String?
    var name: String
    var monthlyTarget: Amount
    var spendingClass: BudgetSpendingClass
    /// The app category keys whose spending counts against this line.
    var categoryKeys: [String]

    init(
        id: String? = nil,
        name: String = "",
        monthlyTarget: Amount = .zeroEUR,
        spendingClass: BudgetSpendingClass = .flexible,
        categoryKeys: [String] = []
    ) {
        self.id = id
        self.name = name
        self.monthlyTarget = monthlyTarget
        self.spendingClass = spendingClass
        self.categoryKeys = categoryKeys
    }
}

struct PlannedPurchaseDraft: Hashable, Sendable, Identifiable {
    var id: String?
    var name: String = ""
    var amountText: String = ""
    var currencyCode: String = "EUR"
    var fractionDigits: Int = 2
    var hasTargetDate: Bool = false
    var targetDate: CalendarDay?
    var status: GoalStatus = .wishlist
    var funding: GoalFundingKind = .cash
    var sinkingFundID: String?
    var installmentPlanID: String?
    var note: String = ""
}

struct SinkingFundDraft: Hashable, Sendable, Identifiable {
    var id: String?
    var name: String = ""
    var targetText: String = ""
    var reservedText: String = "0"
    var currencyCode: String = "EUR"
    var fractionDigits: Int = 2
    var custody: FundCustodyKind = .virtual
    var dedicatedAccountID: String?
    var goalID: String?
    var contributionText: String = ""
    var status: FundStatusOption = .active
    var note: String = ""
}

/// The app's mirror of the engine's spending class. The editor names this
/// one, so no screen has to reach across the facade for a vocabulary.
enum BudgetSpendingClass: String, CaseIterable, Hashable, Sendable, Identifiable {
    case essential, flexible, optional

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .essential: "Essential"
        case .flexible: "Flexible"
        case .optional: "Optional"
        }
    }
}

/// A recurring charge, as the budget editor lists it.
struct CommitmentOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let amount: Amount
}
