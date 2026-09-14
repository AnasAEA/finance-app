import Foundation

public enum InterchangeFormat: String, Hashable, Sendable { case v1, v2 }
public enum InterchangeTarget: Hashable, Sendable {
    case minimumRequired
    case format(InterchangeFormat)
}
public extension CodingUserInfoKey {
    static let financeDocumentMoneyWire = CodingUserInfoKey(rawValue: "financeDocumentMoneyWire")!
}
public enum InterchangeError: Error, Equatable {
    case unsupportedSchemaVersion(found: String)
    case notRepresentableInV1(field: String)
    case inconsistentFormatAndVersion
}

public struct ResolvedInterchangeEncoding: Hashable, Sendable {
    public let format: InterchangeFormat
    public let schemaVersion: String

    fileprivate init(format: InterchangeFormat, schemaVersion: String) throws {
        guard try Interchange.format(for: schemaVersion) == format else {
            throw InterchangeError.inconsistentFormatAndVersion
        }
        self.format = format
        self.schemaVersion = schemaVersion
    }
}

// Domain field names and indices only. Dictionary payload keys never belong in
// refusal diagnostics; the document preflight uses sorted positional indices.
func monetaryCodingPath(_ keys: [any CodingKey]) -> String {
    keys.reduce("") { result, key in
        if let index = key.intValue { return result + "[\(index)]" }
        return result + (result.isEmpty ? "" : ".") + key.stringValue
    }
}

public extension Interchange {
    static func format(for version: String) throws -> InterchangeFormat {
        switch version {
        case "1.1.0", "1.2.0", "1.3.0", "1.4.0", "1.5.0", "1.6.0": return .v1
        case "2.0.0": return .v2
        default: throw InterchangeError.unsupportedSchemaVersion(found: version)
        }
    }

    static func resolveEncoding(_ document: FinanceDocument,
                                as target: InterchangeTarget = .minimumRequired) throws -> ResolvedInterchangeEncoding {
        let source = try format(for: document.schemaVersion)
        let incompatible = firstV1IncompatibleField(in: document)
        switch target {
        case .format(.v2):
            return try ResolvedInterchangeEncoding(format: .v2, schemaVersion: explicitMonetarySchemaVersion)
        case .minimumRequired where source == .v2 || incompatible != nil:
            return try ResolvedInterchangeEncoding(format: .v2, schemaVersion: explicitMonetarySchemaVersion)
        case .format(.v1):
            if let incompatible { throw InterchangeError.notRepresentableInV1(field: incompatible) }
        case .minimumRequired: break
        }
        // Downgrading a V2 source targets the newest V1 this build writes,
        // never a literal that can drift away from `currentSchemaVersion`.
        let base = source == .v1 ? document.schemaVersion : currentSchemaVersion
        let emitted = document.planning.containsDurablePlanningState
            ? version(base, atLeast: planningStateSchemaVersion) : base
        return try ResolvedInterchangeEncoding(format: .v1, schemaVersion: emitted)
    }

    static func documentRequiresV2(_ document: FinanceDocument) -> Bool {
        firstV1IncompatibleField(in: document) != nil
    }

    /// Exhaustive stored monetary fields of FinanceDocument, in fixed domain
    /// order. Dictionary entries are sorted and identified by position only.
    static func firstV1IncompatibleField(in d: FinanceDocument) -> String? {
        var first: String?
        func currency(_ value: Currency, _ path: String) {
            if first == nil && !value.isRepresentableInV1 { first = path }
        }
        func money(_ value: Money?, _ path: String) {
            if let value { currency(value.currency, path) }
        }
        for (i, a) in d.accounts.enumerated() { currency(a.currency, "accounts[\(i)].currency") }
        for (i, b) in d.balances.enumerated() { money(b.balance, "balances[\(i)].balance") }
        for (name, transactions) in [("transactions", d.transactions), ("expectedTransactions", d.expectedTransactions)] {
            for (i, t) in transactions.enumerated() {
                for (j, leg) in t.legs.enumerated() { money(leg.amount, "\(name)[\(i)].legs[\(j)].amount") }
                for (j, split) in (t.ownership ?? []).enumerated() { money(split.amount, "\(name)[\(i)].ownership[\(j)].amount") }
            }
        }
        for (i, s) in d.incomeSources.enumerated() { money(s.amount, "incomeSources[\(i)].amount") }
        for (i, p) in d.installments.enumerated() {
            money(p.originalPurchaseAmount, "installments[\(i)].originalPurchaseAmount")
            currency(p.paymentRequirement.currency, "installments[\(i)].paymentRequirement.currency")
            for (j, v) in p.installments.enumerated() { money(v.amount, "installments[\(i)].installments[\(j)].amount") }
        }
        for (i, p) in d.debts.enumerated() {
            money(p.originalAmount, "debts[\(i)].originalAmount")
            currency(p.paymentRequirement.currency, "debts[\(i)].paymentRequirement.currency")
            for (j, v) in p.paymentSchedule.enumerated() { money(v.amount, "debts[\(i)].paymentSchedule[\(j)].amount") }
        }
        money(d.planning.safetyFloor, "planning.safetyFloor")
        money(d.planning.monthlyEconomicCeiling, "planning.monthlyEconomicCeiling")
        for (i, b) in d.planning.budgets.enumerated() {
            money(b.monthlyAmount, "planning.budgets[\(i)].monthlyAmount")
            for (j, key) in b.monthlyOverrides.keys.sorted().enumerated() {
                money(b.monthlyOverrides[key], "planning.budgets[\(i)].monthlyOverrides[\(j)].amount")
            }
        }
        for (i, r) in d.planning.recurringObligations.enumerated() {
            money(r.amount, "planning.recurringObligations[\(i)].amount")
            currency(r.requirement.currency, "planning.recurringObligations[\(i)].requirement.currency")
        }
        for (i, key) in d.planning.carriedEURValues.keys.sorted().enumerated() {
            money(d.planning.carriedEURValues[key], "planning.carriedEURValues[\(i)].value")
        }
        for (i, p) in d.planning.plannedPurchases.enumerated() {
            money(p.targetAmount, "planning.plannedPurchases[\(i)].targetAmount")
            money(p.reservedAmount, "planning.plannedPurchases[\(i)].reservedAmount")
            currency(p.requirement.currency, "planning.plannedPurchases[\(i)].requirement.currency")
        }
        for (i, f) in d.planning.sinkingFunds.enumerated() {
            money(f.targetAmount, "planning.sinkingFunds[\(i)].targetAmount")
            money(f.reservedAmount, "planning.sinkingFunds[\(i)].reservedAmount")
            money(f.contributionAmount, "planning.sinkingFunds[\(i)].contributionAmount")
        }
        for (i, o) in d.externalObservations.enumerated() { money(o.amount, "externalObservations[\(i)].amount") }
        for (i, b) in d.providerBalanceSnapshots.enumerated() { money(b.amount, "providerBalanceSnapshots[\(i)].amount") }
        for (i, c) in d.crossProviderCandidates.enumerated() { money(c.amount, "crossProviderCandidates[\(i)].amount") }
        return first
    }
}
