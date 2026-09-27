import Foundation
import FinanceCore

extension DomainMapper {
    /// Same ledger inclusion rules as CurrentHoldings, with checked arithmetic,
    /// queried at the bank's explicit reference day rather than today's cash.
    static func balanceReconciliation(_ provider: ProviderBalanceSnapshot,
        binding: ExternalAccountBinding, account: Account, providerLabel: String, document: FinanceDocument,
        asOf: Day?, currentPendingIDs: Set<String>) -> ProviderBalanceStatus {
        let meaning: String
        let explanation: String
        switch provider.balanceType {
        case "CLBD":
            meaning = "Closing booked balance"
            explanation = "Booked cash at the bank's reference date. Pending authorizations may not be included."
        case "XPCD":
            meaning = "Expected balance"
            explanation = "The provider's expected balance may include pending movements. It is not a booked statement balance."
        case "ITAV":
            meaning = "Interim available balance"
            explanation = "Available cash can reflect holds and provider limits. It is not a closing booked balance."
        default:
            meaning = "Unrecognized balance type"
            explanation = "The original provider type is retained without assigning it a meaning."
        }
        let anchor = document.balances.first { $0.accountID == account.id }
        var blocker: BalanceReconciliation.Blocker?
        var ledger: Amount?
        var movementNet: Amount?
        var movements: [Transaction] = []
        if !binding.isActive { blocker = .inactiveBinding }
        else if provider.provider != binding.provider { blocker = .identityMismatch }
        else if provider.amount.currency != account.currency ||
            anchor.map({ $0.balance.currency != account.currency }) == true { blocker = .currencyMismatch }
        else if !["CLBD", "XPCD", "ITAV"].contains(provider.balanceType) { blocker = .unsupportedType }
        else if asOf == nil { blocker = .missingCurrentDay }
        else if provider.referenceDate == nil { blocker = .missingDate }
        else if let day = provider.referenceDate, (try? PersistenceCoding.ordinal(day)) == nil { blocker = .invalidDate }
        else if let day = provider.referenceDate, asOf.map({ day > $0 }) == true { blocker = .futureDate }
        else if anchor == nil { blocker = .missingAnchor }
        else if let day = provider.referenceDate, let anchor, day < anchor.asOf { blocker = .beforeAnchor }
        else if let day = provider.referenceDate, let anchor {
            movements = document.transactions.filter {
                $0.lifecycle != .reversed && $0.date > anchor.asOf && $0.date <= day &&
                $0.legs.contains { $0.accountID == account.id }
            }.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
            var total = anchor.balance.minorUnits
            var net: Int64 = 0
            for transaction in movements {
                for leg in transaction.legs where leg.accountID == account.id {
                    guard leg.amount.currency == account.currency else { blocker = .currencyMismatch; break }
                    let addition = total.addingReportingOverflow(leg.amount.minorUnits)
                    let netAddition = net.addingReportingOverflow(leg.amount.minorUnits)
                    guard !addition.overflow, !netAddition.overflow else { blocker = .unsafeArithmetic; break }
                    total = addition.partialValue
                    net = netAddition.partialValue
                }
                if blocker != nil { break }
            }
            if blocker == nil {
                ledger = amount(Money(minorUnits: total, currency: account.currency))
                movementNet = amount(Money(minorUnits: net, currency: account.currency))
            }
        }
        var difference: Amount?
        if let ledger {
            let delta = provider.amount.minorUnits.subtractingReportingOverflow(ledger.minorUnits)
            if delta.overflow { blocker = .unsafeArithmetic }
            else { difference = amount(Money(minorUnits: delta.partialValue, currency: account.currency)) }
        }
        let resolutions = Dictionary(document.observationResolutions.map { ($0.observationID, $0.state) }, uniquingKeysWith: { first, _ in first })
        let observations = document.externalObservations.filter { $0.bindingID == binding.id }
        let unreviewed = observations.filter { observation in
            guard binding.isActive, observation.status == .booked,
                  resolutions[observation.id] == .unreviewed else { return false }
            if let date = observation.bookingDate {
                if let reference = provider.referenceDate, date > reference { return false }
                if let anchor, date <= anchor.asOf { return false }
            }
            return true
        }.map(\.id).sorted()
        let pending = observations.filter { binding.isActive && $0.status == .pending && currentPendingIDs.contains($0.id) }.map(\.id).sorted()
        let report = BalanceReconciliation(accountID: account.id, balanceMeaning: meaning,
            balanceExplanation: explanation, openingAmount: anchor.map { amount($0.balance) },
            openingDay: anchor.map { civilDay($0.asOf) }, movementNet: movementNet,
            movementIDs: movements.map(\.id), pendingMovementCount: movements.filter { $0.lifecycle == .pending }.count,
            unreviewedObservationIDs: unreviewed, currentPendingObservationIDs: pending, blocker: blocker)
        return ProviderBalanceStatus(id: provider.id, providerName: providerLabel, accountName: account.name,
            balanceType: provider.balanceType, ledgerBalance: ledger, providerBalance: amount(provider.amount),
            difference: difference, referenceDate: provider.referenceDate.map(civilDay), observedAt: provider.observedAt,
            reconciliation: report)
    }
}
