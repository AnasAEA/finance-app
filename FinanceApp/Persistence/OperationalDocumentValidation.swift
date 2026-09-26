import Foundation
import FinanceCore

/// Operational headroom is separate from the lossless interchange wire range.
/// A million-fold margin protects repeated forecast events and derived totals.
enum OperationalDocumentValidation {
    static let maximumAggregateMagnitude = UInt64(Int64.max / 1_000_000)

    static func moneyIsSafe(_ value: Any) -> Bool {
        var magnitude: UInt64 = 0
        func visit(_ value: Any) -> Bool {
            if let money = value as? Money {
                let (sum, overflow) = magnitude.addingReportingOverflow(money.minorUnits.magnitude)
                guard !overflow, sum <= maximumAggregateMagnitude else { return false }
                magnitude = sum
                return true
            }
            if let bag = value as? MoneyBag {
                return bag.currencies.allSatisfy { visit(bag.amount(in: $0)) }
            }
            let mirror = Mirror(reflecting: value)
            guard mirror.displayStyle != .class else { return true }
            return mirror.children.allSatisfy { visit($0.value) }
        }
        return visit(value)
    }

    static func validate(_ document: FinanceDocument) throws {
        guard moneyIsSafe(document) else { throw PersistenceMappingError.unrepresentableOperationalMoney }
        func unique(_ ids: [String]) -> Bool { Set(ids).count == ids.count }
        let transactions = document.transactions + document.expectedTransactions
        guard unique(document.accounts.map(\.id)), unique(transactions.map(\.id)),
              unique(document.incomeSources.map(\.id)), unique(document.installments.map(\.id)),
              unique(document.debts.map(\.id)), unique(document.planning.budgets.map(\.id)),
              unique(document.planning.recurringObligations.map(\.id)) else {
            throw PersistenceMappingError.invalidDocument
        }
        let accounts = Dictionary(uniqueKeysWithValues: document.accounts.map { ($0.id, $0.currency) })
        guard document.balances.allSatisfy({ accounts[$0.accountID] == $0.balance.currency }) else {
            throw PersistenceMappingError.invalidDocument
        }
        let transactionIDs = Set(transactions.map(\.id))
        let sourceIDs = Set(document.incomeSources.map(\.id))
        let planIDs = Set(document.installments.map(\.id))
        for transaction in transactions {
            guard transaction.legs.allSatisfy({ accounts[$0.accountID] == $0.amount.currency }),
                  transaction.linkedTransactionID.map({ transactionIDs.contains($0) && $0 != transaction.id }) ?? true,
                  transaction.incomeSourceID.map(sourceIDs.contains) ?? true,
                  transaction.installmentPlanID.map(planIDs.contains) ?? true else {
                throw PersistenceMappingError.invalidDocument
            }
        }
        for purchase in document.planning.plannedPurchases {
            guard purchase.purchasedTransactionID.map(transactionIDs.contains) ?? true else {
                throw PersistenceMappingError.invalidDocument
            }
        }
        for debt in document.debts {
            guard debt.paymentSchedule.allSatisfy({ $0.amount.currency == debt.originalAmount.currency && !$0.amount.isNegative }),
                  debt.paymentRequirement.currency == debt.originalAmount.currency else {
                throw PersistenceMappingError.invalidDocument
            }
        }
        for plan in document.installments {
            guard plan.installments.allSatisfy({ $0.amount.currency == plan.originalPurchaseAmount.currency && !$0.amount.isNegative }),
                  plan.paymentRequirement.currency == plan.originalPurchaseAmount.currency else {
                throw PersistenceMappingError.invalidDocument
            }
        }
    }
}
