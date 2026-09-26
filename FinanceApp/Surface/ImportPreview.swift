import Foundation

/// How old a balance is, measured against the day the import is being reviewed.
///
/// A balance is a dated observation, not a live reading. The distinction has to
/// survive all the way to the screen, because "€361.95" and "€361.95 as of 20
/// August" are different claims and only one of them is true.
enum BalanceFreshness: Hashable, Sendable {
    case today
    case daysOld(Int)
    /// Dated after today. Not corrected silently — a future observation is a
    /// mistake somewhere, and the reviewer is the one who can say where.
    case dated(daysAhead: Int)

    var isStale: Bool {
        if case .today = self { return false }
        return true
    }

    /// The words shown beside the figure. Never the word "current".
    func caption(asOf day: CalendarDay, formatter: (CalendarDay) -> String) -> String {
        switch self {
        case .today: "As of today"
        case .daysOld: "As of \(formatter(day))"
        case .dated: "Dated \(formatter(day)) — after today"
        }
    }
}

/// One account as the preview describes it, before anything is written.
struct ImportAccountPreview: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: HoldingKind
    let currencyCode: String
    let fractionDigits: Int
    let balance: Amount
    let asOf: CalendarDay
    let freshness: BalanceFreshness
    /// Whether this balance could meet a home-currency obligation. Mirrors what
    /// Home will say once the import lands, so the preview does not promise a
    /// spendable figure the app will then refuse to spend.
    let isSpendableHere: Bool
    let isActive: Bool
}

/// A per-currency total, for the figures that must never be summed together.
struct CurrencyTotal: Identifiable, Hashable, Sendable {
    var id: String { "\(amount.currencyCode)/\(amount.fractionDigits)" }
    let amount: Amount
}

/// What a candidate file contains, in product terms.
///
/// Built from a decoded, schema-validated and semantically-validated document.
/// It carries no engine type, no file bytes and no raw JSON: everything on it
/// is a figure or a count that a person can check against what they expect to
/// be importing.
struct ImportPreview: Hashable, Sendable {

    /// The export's own label for itself (`documentKind`), shown so the person
    /// can tell one export from another.
    let sourceLabel: String
    let schemaVersion: String
    /// The export's provenance note, when it carries one.
    let note: String?

    let accounts: [ImportAccountPreview]

    /// Euro held in accounts that can actually settle a euro obligation.
    let electronicLiquidity: Amount
    /// Notes and coins, one exact total per currency. Never added to
    /// `electronicLiquidity`: 200 MAD in a pocket cannot pay a French direct
    /// debit, and a combined total would claim it can.
    let physicalCash: [CurrencyTotal]

    var foreignDebtOutstanding: [CurrencyTotal] = []
    let debtOutstanding: Amount
    let debtCount: Int
    /// Debts that arrived with no agreed repayment schedule. They are owed and
    /// they are imported; they commit no dated cash.
    let unscheduledDebtCount: Int

    let installmentCount: Int
    var foreignInstallmentRemaining: [CurrencyTotal] = []
    let installmentRemaining: Amount

    let recurringCommitmentCount: Int
    /// Recurring items marked hypothetical or otherwise not committed.
    let uncommittedCommitmentCount: Int

    let incomeSourceCount: Int
    let observedTransactionCount: Int
    let expectedTransactionCount: Int
    let budgetCount: Int

    var staleAccounts: [ImportAccountPreview] { accounts.filter { $0.freshness.isStale } }
    var hasStaleBalances: Bool { !staleAccounts.isEmpty }
}

/// A balance the reviewer corrected before confirming the import.
///
/// Correcting is editing the document that is about to be written, not patching
/// one that already is: nothing has been persisted at the point this is made.
struct ImportBalanceCorrection: Hashable, Sendable {
    let accountID: String
    let balance: Amount
    let asOf: CalendarDay
}

/// What was actually written, reported after the fact.
///
/// Built by re-reading the persisted store, not by echoing the preview back —
/// a confirmation assembled from the input would say "imported" about rows that
/// were never written.
struct ImportSummary: Hashable, Sendable {
    let accountCount: Int
    let recurringCommitmentCount: Int
    let incomeSourceCount: Int
    let installmentCount: Int
    let expectedTransactionCount: Int
    let observedTransactionCount: Int
    var foreignDebtOutstanding: [CurrencyTotal] = []
    let debtOutstanding: Amount
    let electronicLiquidity: Amount
    let physicalCash: [CurrencyTotal]
}
