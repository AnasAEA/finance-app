import Foundation

/// What the entry sheet collects, before any engine sees it.
///
/// The sheet asks a person for a number, a kind and an account. Deciding that a
/// transfer into a cash account is really a withdrawal, that a share makes an
/// inflow partly someone else's, or how any of it is stored, is not the sheet's
/// job — it hands over this draft and `DomainMapper` turns it into whatever the
/// installed core calls a transaction.
struct TransactionDraft: Hashable, Sendable {
    /// The three a person picks from. Everything else is inferred or generated.
    enum Kind: String, Hashable, Sendable, CaseIterable, Identifiable {
        case expense, income, transfer

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .expense: "Expense"
            case .income: "Income"
            case .transfer: "Transfer"
            }
        }

        var requiresCounterAccount: Bool { self == .transfer }

        /// Whether entry may offer an explicit owned share.
        ///
        /// Only an inflow has ownership economics behind it: a part-owned
        /// arrival becomes a pass-through whose unowned share is not income.
        /// There is no equivalent for an expense — FinanceCore has no
        /// partial-consumption model — so the control is not offered rather
        /// than offered and ignored.
        var supportsOwnShareEntry: Bool { self == .income }
    }

    /// The civil date the entry is dated, exactly as it was picked. Never an
    /// absolute `Date`: the day a person selects has no instant, and the app
    /// must not invent one and then read it back in a different zone.
    var day: CalendarDay
    var kind: Kind
    /// Positive magnitude. Direction comes from `kind`.
    var amount: Amount
    var accountID: String
    var counterAccountID: String?
    /// Economic origin of an income transaction. This is independent of the
    /// account the money arrived in and is never inferred from that account.
    var incomeSourceID: String?
    /// A `CategoryOption.key`. `nil` for a transfer, which the core categorises.
    var categoryKey: String?
    var merchant: String?
    /// The part of `amount` that is economically the owner's. `nil` means all
    /// of it; set it to split an inflow that is partly someone else's.
    /// Only `Kind.income` accepts one — see `Kind.supportsOwnShareEntry`.
    var ownShare: Amount?
    var notes: String?

    init(
        day: CalendarDay,
        kind: Kind,
        amount: Amount,
        accountID: String,
        counterAccountID: String? = nil,
        incomeSourceID: String? = nil,
        categoryKey: String? = nil,
        merchant: String? = nil,
        ownShare: Amount? = nil,
        notes: String? = nil
    ) {
        self.day = day
        self.kind = kind
        self.amount = amount
        self.accountID = accountID
        self.counterAccountID = counterAccountID
        self.incomeSourceID = incomeSourceID
        self.categoryKey = categoryKey
        self.merchant = merchant
        self.ownShare = ownShare
        self.notes = notes
    }
}

extension TransactionDraft {
    /// Convenience for a draft whose date came from a `DatePicker`: the picked
    /// instant is read as the civil date it is in `timeZone`, which on a device
    /// is the only reading that matches what the person saw.
    init?(
        date: Date,
        timeZone: TimeZone = .current,
        kind: Kind,
        amount: Amount,
        accountID: String,
        counterAccountID: String? = nil,
        incomeSourceID: String? = nil,
        categoryKey: String? = nil,
        merchant: String? = nil,
        ownShare: Amount? = nil,
        notes: String? = nil
    ) {
        guard let day = CalendarDay(date, in: timeZone) else { return nil }
        self.init(
            day: day,
            kind: kind,
            amount: amount,
            accountID: accountID,
            counterAccountID: counterAccountID,
            incomeSourceID: incomeSourceID,
            categoryKey: categoryKey,
            merchant: merchant,
            ownShare: ownShare,
            notes: notes
        )
    }
}
