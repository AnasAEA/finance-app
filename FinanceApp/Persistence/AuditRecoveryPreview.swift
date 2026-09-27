#if DEBUG
import Foundation
import SwiftData
import FinanceCore

/// Synthetic, memory-only launch state for recovery and foreign Plan UI tests.
@MainActor enum AuditRecoveryPreview {
    static func make(includeSecondAccount: Bool = false) throws -> (ModelContainer, FinanceStore) {
        let container = try ModelContainer(for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let day = Day(year: 2026, month: 9, day: 26)
        let account = Account(id: "audit-ui-bank", name: "Synthetic account", currency: .eur,
            kind: .bank, supportedRails: PaymentRail.euroBankRails, drawOrder: 0)
        var document = FinanceDocument(schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "SYNTHETIC-AUDIT", accounts: [account],
            balances: [.init(accountID: account.id, balance: Money(minorUnits: 10000, currency: .eur), asOf: day)],
            transactions: [.init(id: "audit-ui-expense", date: day, kind: .expense,
                legs: [.init(accountID: account.id, amount: Money(minorUnits: -100, currency: .eur))],
                factivity: .observed, lifecycle: .cleared,
                provenance: .init(source: "SYNTHETIC-AUDIT", evidenceGrade: .userConfirmed))],
            planning: .init(defaultScenario: .base, sinkingFunds: [
                .init(id: "audit-ui-usd", name: "Synthetic foreign fund",
                    targetAmount: Money(minorUnits: 10000, currency: .usd),
                    reservedAmount: Money(minorUnits: 100, currency: .usd))]))
        if includeSecondAccount {
            let other = Account(id: "audit-ui-wallet", name: "Synthetic wallet", currency: .eur,
                kind: .wallet, supportedRails: PaymentRail.euroWalletRails, drawOrder: 1)
            document.accounts.append(other)
            let anchorDay = Day(year: 2026, month: 9, day: 25)
            document.balances = [.init(accountID: account.id, balance: Money(minorUnits: 10000, currency: .eur), asOf: anchorDay),
                .init(accountID: other.id, balance: Money(minorUnits: 20000, currency: .eur), asOf: anchorDay)]
        }
        let store = try FinanceStore(context: container.mainContext, now: Date(timeIntervalSince1970: 1_790_424_000))
        try store.importDocument(document)
        return (container, store)
    }
}
#endif
