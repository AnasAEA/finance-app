#if DEBUG
import Foundation
import SwiftData
import FinanceCore

/// Synthetic, memory-only launch state for recovery and foreign Plan UI tests.
@MainActor enum AuditRecoveryPreview {
    static func make(includeSecondAccount: Bool = false, includeBankEvidence: Bool = false) throws -> (ModelContainer, FinanceStore) {
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
        if includeBankEvidence {
            let anchorDay = Day(year: 2026, month: 9, day: 25)
            document.balances = [.init(accountID: account.id, balance: Money(minorUnits: 10000, currency: .eur), asOf: anchorDay)]
            document.externalAccountBindings = [.init(id: "audit-ui-binding", provider: .bnp,
                remoteOpaqueAccountID: "synthetic-remote", localAccountID: account.id,
                syncStartBoundary: anchorDay, createdAt: Date(timeIntervalSince1970: 1_790_424_000))]
            document.providerBalanceSnapshots = ["CLBD", "XPCD"].map { type in
                .init(id: "audit-ui-balance-\(type)", bindingID: "audit-ui-binding", provider: .bnp,
                    balanceType: type, amount: Money(minorUnits: type == "CLBD" ? 9000 : 8700, currency: .eur),
                    referenceDate: day, observedAt: Date(timeIntervalSince1970: 1_790_424_000))
            }
            document.externalObservations = [.init(id: "audit-ui-booked", bindingID: "audit-ui-binding", provider: .bnp,
                status: .booked, creditDebitIndicator: .debit, amount: Money(minorUnits: -1000, currency: .eur),
                bookingDate: day, structuredMerchantName: "SYNTHETIC bank debit", eligibleForEconomicActual: true,
                observedAt: Date(timeIntervalSince1970: 1_790_424_000))]
            document.observationResolutions = [.init(observationID: "audit-ui-booked", state: .unreviewed)]
        }
        let store = try FinanceStore(context: container.mainContext, now: Date(timeIntervalSince1970: 1_790_424_000))
        try store.importDocument(document)
        return (container, store)
    }
}
#endif
