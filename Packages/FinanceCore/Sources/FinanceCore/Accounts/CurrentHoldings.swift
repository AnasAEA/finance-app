import Foundation

/// Current holdings are derived. `FinanceDocument.balances` is a carried-forward
/// or manual **anchor**, not a mutable latest-balance cache.
///
/// Anchor semantics: `AccountBalance.asOf` is inclusive through that day.
/// A transaction whose economic `date` is on or before the anchor is already
/// represented by the stored figure and must not be replayed.
///
/// Provider-synced accounts prefer the provider's canonical current figure
/// when one is usable. Review, classification, and transaction CRUD never
/// write provider cash and never advance the stored anchor.
public enum CurrentHoldings {

    /// App-local marker. Stores opened by this model persist this version so
    /// later code can tell a post-fix store from an unknown legacy cache.
    /// Unknown legacy stores are not reconstructed: their stored `asOf` stays
    /// the inclusive cutoff, which prevents double replay of already-applied
    /// legs.
    public static let modelVersion = 1

    public enum Source: Hashable, Sendable {
        case provider(provider: ExternalProvider, balanceType: String, snapshotID: String)
        case ledgerFallback
        case missing
    }

    public struct Value: Hashable, Sendable {
        public let accountID: String
        public let amount: Money?
        public let asOf: Day?
        public let source: Source
        public let storedAnchor: AccountBalance?
        public let ledgerFallback: Money?
        /// Provider amount minus ledger fallback when both exist in the same
        /// currency. A difference can be legitimate; it is diagnostic state,
        /// never a reason to mutate the anchor.
        public let driftFromLedger: Money?

        public var hasUsableAmount: Bool { amount != nil }
    }

    /// Closing booked cash for BNP; PayPal only exposes expected; Revolut only
    /// exposes interim available. Pinned from provider evidence in
    /// `finance-bank-sync-poc` (Phase 2.4A): BNP `CLBD`+`XPCD`, PayPal `XPCD`,
    /// Revolut `ITAV`. XPCD is not used for BNP current holdings when CLBD is
    /// present because it includes pending.
    public static func preferredBalanceType(for provider: ExternalProvider) -> String? {
        if provider == .bnp { return "CLBD" }
        if provider == .paypal { return "XPCD" }
        if provider == .revolut { return "ITAV" }
        return nil
    }

    public static func storedAnchor(
        accountID: String,
        in document: FinanceDocument
    ) -> AccountBalance? {
        document.balances.first { $0.accountID == accountID }
    }

    /// Anchor plus eligible legs. Eligibility uses `Transaction.date` (the
    /// economic date), never `createdAt`, `reviewedAt`, `importedAt`, or
    /// booking/value/derived evidence dates.
    ///
    /// Returns nil when the account has no stored anchor, the requested day
    /// is before the anchor day, or a currency mismatch would require FX.
    public static func derivedLedgerBalance(
        accountID: String,
        asOf: Day,
        in document: FinanceDocument
    ) -> Money? {
        guard let anchor = storedAnchor(accountID: accountID, in: document) else { return nil }
        guard asOf >= anchor.asOf else { return nil }
        var total = anchor.balance.minorUnits
        for transaction in document.transactions {
            guard transaction.lifecycle != .reversed else { continue }
            guard transaction.date > anchor.asOf, transaction.date <= asOf else { continue }
            for leg in transaction.legs where leg.accountID == accountID {
                guard leg.amount.currency == anchor.balance.currency else { continue }
                total += leg.amount.minorUnits
            }
        }
        return Money(minorUnits: total, currency: anchor.balance.currency)
    }

    /// One canonical provider snapshot for current liquid holdings, or nil
    /// when none is usable. Never converts currency. Never picks MAX across
    /// unlike balance types.
    public static func canonicalProviderSnapshot(
        for accountID: String,
        in document: FinanceDocument
    ) -> ProviderBalanceSnapshot? {
        guard let account = document.accounts.first(where: { $0.id == accountID }) else {
            return nil
        }
        let activeBindingIDs = Set(
            document.externalAccountBindings
                .filter { $0.localAccountID == accountID && $0.isActive }
                .map(\.id)
        )
        guard !activeBindingIDs.isEmpty else { return nil }

        let usable = document.providerBalanceSnapshots.filter {
            activeBindingIDs.contains($0.bindingID) && $0.amount.currency == account.currency
        }
        guard !usable.isEmpty else { return nil }

        let preferred = usable.filter { snapshot in
            preferredBalanceType(for: snapshot.provider) == snapshot.balanceType
        }
        let selected: [ProviderBalanceSnapshot]
        if !preferred.isEmpty {
            selected = preferred
        } else {
            let types = Set(usable.map(\.balanceType))
            guard types.count == 1 else { return nil }
            selected = usable
        }

        return selected.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
            switch ($0.referenceDate, $1.referenceDate) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return $0.id < $1.id
            }
        }.first
    }

    public static func effective(
        accountID: String,
        asOf: Day,
        in document: FinanceDocument
    ) -> Value {
        let anchor = storedAnchor(accountID: accountID, in: document)
        let ledger = derivedLedgerBalance(accountID: accountID, asOf: asOf, in: document)
        if let provider = canonicalProviderSnapshot(for: accountID, in: document) {
            let drift: Money?
            if let ledger, ledger.currency == provider.amount.currency {
                drift = Money(
                    minorUnits: provider.amount.minorUnits - ledger.minorUnits,
                    currency: ledger.currency
                )
            } else {
                drift = nil
            }
            return Value(
                accountID: accountID,
                amount: provider.amount,
                asOf: provider.referenceDate ?? asOf,
                source: .provider(
                    provider: provider.provider,
                    balanceType: provider.balanceType,
                    snapshotID: provider.id
                ),
                storedAnchor: anchor,
                ledgerFallback: ledger,
                driftFromLedger: drift
            )
        }
        if let ledger {
            return Value(
                accountID: accountID,
                amount: ledger,
                asOf: asOf,
                source: .ledgerFallback,
                storedAnchor: anchor,
                ledgerFallback: ledger,
                driftFromLedger: nil
            )
        }
        return Value(
            accountID: accountID,
            amount: anchor?.balance,
            asOf: anchor?.asOf,
            source: .missing,
            storedAnchor: anchor,
            ledgerFallback: nil,
            driftFromLedger: nil
        )
    }

    /// View of current holdings as `AccountBalance` rows. Never persist this
    /// overlay: it is the input to Home, Accounts, Safe to Use, and forecast
    /// starting cash. Stored anchors stay unchanged.
    public static func overlayBalances(
        in document: FinanceDocument,
        asOf: Day
    ) -> [AccountBalance] {
        document.balances.map { stored in
            let value = effective(accountID: stored.accountID, asOf: asOf, in: document)
            let amount = value.amount ?? stored.balance
            let day = value.asOf ?? stored.asOf
            let status: BalanceStatus
            switch value.source {
            case .provider:
                status = .observed
            case .ledgerFallback, .missing:
                status = stored.status
            }
            return AccountBalance(
                accountID: stored.accountID,
                balance: amount,
                asOf: day,
                status: status
            )
        }
    }

    public static func euroFinancialAccountLiquidity(
        in document: FinanceDocument,
        asOf: Day
    ) -> Money {
        var total: Int64 = 0
        let accounts = Dictionary(
            uniqueKeysWithValues: document.accounts.map { ($0.id, $0) }
        )
        for row in overlayBalances(in: document, asOf: asOf) {
            guard let account = accounts[row.accountID],
                  account.kind != .cash,
                  account.currency == .eur,
                  row.balance.currency == .eur else { continue }
            total += row.balance.minorUnits
        }
        return Money(minorUnits: total, currency: .eur)
    }
}
