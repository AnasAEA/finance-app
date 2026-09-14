import Foundation

// Explicit V1 tokens are a wire contract, not derived Swift property/case names.
// A source rename must preserve these literals and the golden vector.
enum CanonicalProjectionV1 {
    typealias W = CheckpointWire
    static func node(_ value: ReviewPeriodKind) -> W {
        switch value {
        case .weekly: return .record("weekly", [])
        case .monthly: return .record("monthly", [])
        }
    }
    static func readReviewPeriodKind(_ value: W) throws -> ReviewPeriodKind {
        guard case let .record(token, fields) = value, fields.isEmpty else { throw SemanticProjectionFormatError.unknownToken }
        switch token {
        case "weekly": return .weekly
        case "monthly": return .monthly
        default: throw SemanticProjectionFormatError.unknownToken
        }
    }

    static func node(_ value: TransactionKind) -> W {
        switch value {
        case .expense: return .record("expense", [])
        case .income: return .record("income", [])
        case .transfer: return .record("transfer", [])
        case .refund: return .record("refund", [])
        case .financingRepayment: return .record("financingRepayment", [])
        case .passThrough: return .record("passThrough", [])
        case .cashWithdrawal: return .record("cashWithdrawal", [])
        case .currencyConversion: return .record("currencyConversion", [])
        }
    }
    static func readTransactionKind(_ value: W) throws -> TransactionKind {
        guard case let .record(token, fields) = value, fields.isEmpty else { throw SemanticProjectionFormatError.unknownToken }
        switch token {
        case "expense": return .expense
        case "income": return .income
        case "transfer": return .transfer
        case "refund": return .refund
        case "financingRepayment": return .financingRepayment
        case "passThrough": return .passThrough
        case "cashWithdrawal": return .cashWithdrawal
        case "currencyConversion": return .currencyConversion
        default: throw SemanticProjectionFormatError.unknownToken
        }
    }

    static func node(_ value: TransactionLifecycle) -> W {
        switch value {
        case .pending: return .record("pending", [])
        case .cleared: return .record("cleared", [])
        case .reconciled: return .record("reconciled", [])
        case .reversed: return .record("reversed", [])
        }
    }
    static func readTransactionLifecycle(_ value: W) throws -> TransactionLifecycle {
        guard case let .record(token, fields) = value, fields.isEmpty else { throw SemanticProjectionFormatError.unknownToken }
        switch token {
        case "pending": return .pending
        case "cleared": return .cleared
        case "reconciled": return .reconciled
        case "reversed": return .reversed
        default: throw SemanticProjectionFormatError.unknownToken
        }
    }

    static func node(_ value: Factivity) -> W {
        switch value {
        case .observed: return .record("observed", [])
        case .expected: return .record("expected", [])
        }
    }
    static func readFactivity(_ value: W) throws -> Factivity {
        guard case let .record(token, fields) = value, fields.isEmpty else { throw SemanticProjectionFormatError.unknownToken }
        switch token {
        case "observed": return .observed
        case "expected": return .expected
        default: throw SemanticProjectionFormatError.unknownToken
        }
    }

    static func node(_ value: ExternalObservationIdentity) -> W {
        switch value {
        case .durable: return .record("durable", [])
        case .provisionalSnapshot: return .record("provisionalSnapshot", [])
        }
    }
    static func readExternalObservationIdentity(_ value: W) throws -> ExternalObservationIdentity {
        guard case let .record(token, fields) = value, fields.isEmpty else { throw SemanticProjectionFormatError.unknownToken }
        switch token {
        case "durable": return .durable
        case "provisionalSnapshot": return .provisionalSnapshot
        default: throw SemanticProjectionFormatError.unknownToken
        }
    }

    static func node(_ value: ObservationResolutionState) -> W {
        switch value {
        case .unreviewed: return .record("unreviewed", [])
        case .linkedToTransaction: return .record("linkedToTransaction", [])
        case .noEconomicEffect: return .record("noEconomicEffect", [])
        case .outsideSyncBoundary: return .record("outsideSyncBoundary", [])
        case .provisional: return .record("provisional", [])
        case .economicallyIneligible: return .record("economicallyIneligible", [])
        }
    }
    static func readObservationResolutionState(_ value: W) throws -> ObservationResolutionState {
        guard case let .record(token, fields) = value, fields.isEmpty else { throw SemanticProjectionFormatError.unknownToken }
        switch token {
        case "unreviewed": return .unreviewed
        case "linkedToTransaction": return .linkedToTransaction
        case "noEconomicEffect": return .noEconomicEffect
        case "outsideSyncBoundary": return .outsideSyncBoundary
        case "provisional": return .provisional
        case "economicallyIneligible": return .economicallyIneligible
        default: throw SemanticProjectionFormatError.unknownToken
        }
    }

    static func node(_ value: ExternalEvidenceRole) -> W {
        switch value {
        case .accountMovement: return .record("accountMovement", [])
        case .merchantEnrichment: return .record("merchantEnrichment", [])
        case .supportingEvidence: return .record("supportingEvidence", [])
        }
    }
    static func readExternalEvidenceRole(_ value: W) throws -> ExternalEvidenceRole {
        guard case let .record(token, fields) = value, fields.isEmpty else { throw SemanticProjectionFormatError.unknownToken }
        switch token {
        case "accountMovement": return .accountMovement
        case "merchantEnrichment": return .merchantEnrichment
        case "supportingEvidence": return .supportingEvidence
        default: throw SemanticProjectionFormatError.unknownToken
        }
    }

    static func node(_ value: AggregateEvidenceBasis) -> W {
        switch value {
        case .sourceEstablishedAggregateRelationship: return .record("sourceEstablishedAggregateRelationship", [])
        case .structuralCandidateOnly: return .record("structuralCandidateOnly", [])
        }
    }
    static func readAggregateEvidenceBasis(_ value: W) throws -> AggregateEvidenceBasis {
        guard case let .record(token, fields) = value, fields.isEmpty else { throw SemanticProjectionFormatError.unknownToken }
        switch token {
        case "sourceEstablishedAggregateRelationship": return .sourceEstablishedAggregateRelationship
        case "structuralCandidateOnly": return .structuralCandidateOnly
        default: throw SemanticProjectionFormatError.unknownToken
        }
    }

    static func node(_ value: ReviewCoverageStatus) -> W {
        switch value {
        case .complete: return .record("complete", [])
        case .partial: return .record("partial", [])
        case .insufficient: return .record("insufficient", [])
        }
    }
    static func readReviewCoverageStatus(_ value: W) throws -> ReviewCoverageStatus {
        guard case let .record(token, fields) = value, fields.isEmpty else { throw SemanticProjectionFormatError.unknownToken }
        switch token {
        case "complete": return .complete
        case "partial": return .partial
        case "insufficient": return .insufficient
        default: throw SemanticProjectionFormatError.unknownToken
        }
    }

    static func node(_ value: ReviewCoverageReasonKind) -> W {
        switch value {
        case .coverageMetadataAbsent: return .record("coverageMetadataAbsent", [])
        case .archiveHistoryAbsent: return .record("archiveHistoryAbsent", [])
        case .missingArchiveInterval: return .record("missingArchiveInterval", [])
        case .missingLiveInterval: return .record("missingLiveInterval", [])
        case .sourceGap: return .record("sourceGap", [])
        }
    }
    static func readReviewCoverageReasonKind(_ value: W) throws -> ReviewCoverageReasonKind {
        guard case let .record(token, fields) = value, fields.isEmpty else { throw SemanticProjectionFormatError.unknownToken }
        switch token {
        case "coverageMetadataAbsent": return .coverageMetadataAbsent
        case "archiveHistoryAbsent": return .archiveHistoryAbsent
        case "missingArchiveInterval": return .missingArchiveInterval
        case "missingLiveInterval": return .missingLiveInterval
        case "sourceGap": return .sourceGap
        default: throw SemanticProjectionFormatError.unknownToken
        }
    }

    static func node(_ value: SemanticInterval) throws -> W {
        let start = try node(value.start)
        let end = try node(value.end)
        guard value.start <= value.end else { throw SemanticProjectionFormatError.invalidInterval }
        return .record("interval", [start, end])
    }
    static func readSemanticInterval(_ value: W) throws -> SemanticInterval {
        let f = try value.fields("interval", 2)
        let result = SemanticInterval(
            start: try readDay(f[0]),
            end: try readDay(f[1])
        )
        guard result.start <= result.end else { throw SemanticProjectionFormatError.invalidInterval }
        return result
    }

    static func node(_ value: SemanticLegFact) throws -> W {
        return .record("leg", [
            .string(value.accountID),
            .integer(value.minorUnits),
            try code(value.currencyCode)
        ])
    }
    static func readSemanticLegFact(_ value: W) throws -> SemanticLegFact {
        let f = try value.fields("leg", 3)
        let result = SemanticLegFact(
            accountID: try f[0].text(),
            minorUnits: try f[1].int(),
            currencyCode: try readCode(f[2])
        )
        return result
    }

    static func node(_ value: SemanticTransactionFact) throws -> W {
        return .record("transaction", [
            .string(value.id),
            try node(value.day),
            node(value.kind),
            node(value.lifecycle),
            node(value.factivity),
            try .sorted(value.legs.map(node)),
            .optional(value.incomeSourceID, W.string),
            .optional(value.ownedMinorUnits, W.integer),
            .optional(value.categoryKey, W.string)
        ])
    }
    static func readSemanticTransactionFact(_ value: W) throws -> SemanticTransactionFact {
        let f = try value.fields("transaction", 9)
        let result = SemanticTransactionFact(
            id: try f[0].text(),
            day: try readDay(f[1]),
            kind: try readTransactionKind(f[2]),
            lifecycle: try readTransactionLifecycle(f[3]),
            factivity: try readFactivity(f[4]),
            legs: try f[5].list(readSemanticLegFact),
            incomeSourceID: try f[6].optional { try $0.text() },
            ownedMinorUnits: try f[7].optional { try $0.int() },
            categoryKey: try f[8].optional { try $0.text() }
        )
        return result
    }

    static func node(_ value: SemanticAggregateFact) -> W {
        return .record("aggregate", [
            node(value.basis),
            .sorted(value.pairedTransactionIDs.map(W.string))
        ])
    }
    static func readSemanticAggregateFact(_ value: W) throws -> SemanticAggregateFact {
        let f = try value.fields("aggregate", 2)
        let result = SemanticAggregateFact(
            basis: try readAggregateEvidenceBasis(f[0]),
            pairedTransactionIDs: try f[1].list { try $0.text() }
        )
        return result
    }

    static func node(_ value: SemanticEvidenceLinkFact) -> W {
        return .record("link", [
            .string(value.transactionID),
            node(value.role)
        ])
    }
    static func readSemanticEvidenceLinkFact(_ value: W) throws -> SemanticEvidenceLinkFact {
        let f = try value.fields("link", 2)
        let result = SemanticEvidenceLinkFact(
            transactionID: try f[0].text(),
            role: try readExternalEvidenceRole(f[1])
        )
        return result
    }

    static func node(_ value: SemanticObservationFact) throws -> W {
        return .record("observation", [
            .string(value.id),
            .string(value.statusToken),
            node(value.identity),
            .bool(value.providerEligibleForEconomicActual),
            .bool(value.bindingIsActive),
            node(value.resolution),
            .integer(value.minorUnits),
            try code(value.currencyCode),
            try .optional(value.economicDay, node),
            .sorted(value.links.map(node)),
            .optional(value.aggregate, node)
        ])
    }
    static func readSemanticObservationFact(_ value: W) throws -> SemanticObservationFact {
        let f = try value.fields("observation", 11)
        let result = SemanticObservationFact(
            id: try f[0].text(),
            statusToken: try f[1].text(),
            identity: try readExternalObservationIdentity(f[2]),
            providerEligibleForEconomicActual: try f[3].boolean(),
            bindingIsActive: try f[4].boolean(),
            resolution: try readObservationResolutionState(f[5]),
            minorUnits: try f[6].int(),
            currencyCode: try readCode(f[7]),
            economicDay: try f[8].optional(readDay),
            links: try f[9].list(readSemanticEvidenceLinkFact),
            aggregate: try f[10].optional(readSemanticAggregateFact)
        )
        return result
    }

    static func node(_ value: SemanticExpectationFact) throws -> W {
        return .record("expectation", [
            .string(value.obligationID),
            try node(value.expectedDay),
            .integer(value.minorUnits),
            try code(value.currencyCode),
            try expectationStatus(value.statusToken),
            .optional(value.settledByTransactionID, W.string)
        ])
    }
    static func readSemanticExpectationFact(_ value: W) throws -> SemanticExpectationFact {
        let f = try value.fields("expectation", 6)
        let result = SemanticExpectationFact(
            obligationID: try f[0].text(),
            expectedDay: try readDay(f[1]),
            minorUnits: try f[2].int(),
            currencyCode: try readCode(f[3]),
            statusToken: try readExpectationStatus(f[4]),
            settledByTransactionID: try f[5].optional { try $0.text() }
        )
        return result
    }

    static func node(_ value: SemanticBudgetAttributionFact) throws -> W {
        return .record("attribution", [
            .string(value.transactionID),
            .optional(value.budgetID, W.string),
            node(value.basis),
            try node(value.amount)
        ])
    }
    static func readSemanticBudgetAttributionFact(_ value: W) throws -> SemanticBudgetAttributionFact {
        let f = try value.fields("attribution", 4)
        let result = SemanticBudgetAttributionFact(
            transactionID: try f[0].text(),
            budgetID: try f[1].optional { try $0.text() },
            basis: try readBasis(f[2]),
            amount: try readMoney(f[3])
        )
        return result
    }

    static func node(_ value: SemanticBudgetFact) throws -> W {
        return .record("budget", [
            try node(value.periodEconomicSpending),
            try node(value.uncategorized),
            try .sorted(value.attributions.map(node))
        ])
    }
    static func readSemanticBudgetFact(_ value: W) throws -> SemanticBudgetFact {
        let f = try value.fields("budget", 3)
        let result = SemanticBudgetFact(
            periodEconomicSpending: try readMoney(f[0]),
            uncategorized: try readMoney(f[1]),
            attributions: try f[2].list(readSemanticBudgetAttributionFact)
        )
        return result
    }

    static func node(_ value: Day) throws -> W {
        // Guard before Day's native-Int civil arithmetic. The wire integer is
        // always Int64; the conversion fails explicitly on a smaller host.
        guard value.year > Int.min / 366 + 2, value.year < Int.max / 366 - 2 else {
            throw SemanticProjectionFormatError.invalidDay
        }
        // The year guard above already keeps the ordinal far inside Int, so
        // this unwrap never narrows what V1 accepts; it only replaces the trap
        // that guard was standing in front of.
        guard let index = value.index, index > Int.min / 2, index < Int.max / 2 else {
            throw SemanticProjectionFormatError.invalidDay
        }
        return .record("day", [.integer(Int64(index))])
    }
    static func readDay(_ value: W) throws -> Day {
        let i = try value.fields("day", 1)[0].int()
        guard let index = Int(exactly: i), index > Int.min / 2, index < Int.max / 2 else {
            throw SemanticProjectionFormatError.invalidDay
        }
        return Day(index: index)
    }
    static func code(_ value: String) throws -> W {
        guard Currency.isValidCode(value) else { throw SemanticProjectionFormatError.invalidCurrency }
        return .string(value)
    }
    static func readCode(_ value: W) throws -> String {
        let code = try value.text()
        guard Currency.isValidCode(code) else { throw SemanticProjectionFormatError.invalidCurrency }
        return code
    }
    static func node(_ value: Money) throws -> W {
        guard (0...6).contains(value.currency.minorUnitDigits) else { throw SemanticProjectionFormatError.invalidCurrency }
        return .record("money", [.integer(value.minorUnits), try code(value.currency.code), .integer(Int64(value.currency.minorUnitDigits))])
    }
    static func readMoney(_ value: W) throws -> Money {
        let f = try value.fields("money", 3)
        let units = try f[0].int()
        let code = try readCode(f[1])
        let digits = try f[2].int()
        guard (0...6).contains(digits) else { throw SemanticProjectionFormatError.invalidCurrency }
        return Money(minorUnits: units, currency: Currency(code: code, minorUnitDigits: Int(digits)))
    }
    static func expectationStatus(_ value: String) throws -> W {
        switch value {
        case "due", "overdue", "paid", "skipped", "noLongerDue": return .record(value, [])
        default: throw SemanticProjectionFormatError.unknownToken
        }
    }
    static func readExpectationStatus(_ value: W) throws -> String {
        guard case let .record(token, fields) = value, fields.isEmpty else { throw SemanticProjectionFormatError.unknownToken }
        _ = try expectationStatus(token)
        return token
    }
    static func node(_ value: MonthlyBudgetEngine.AttributionBasis) -> W {
        switch value {
        case let .settledObligation(id): return .record("settled-obligation", [.string(id)])
        case let .category(key): return .record("category", [.string(key)])
        case let .refundOfLinkedTransaction(id): return .record("linked-refund", [.string(id)])
        case .unattributed: return .record("unattributed", [])
        }
    }
    static func readBasis(_ value: W) throws -> MonthlyBudgetEngine.AttributionBasis {
        guard case let .record(token, fields) = value else { throw SemanticProjectionFormatError.unknownToken }
        switch (token, fields.count) {
        case ("settled-obligation", 1): return .settledObligation(obligationID: try fields[0].text())
        case ("category", 1): return .category(try fields[0].text())
        case ("linked-refund", 1): return .refundOfLinkedTransaction(try fields[0].text())
        case ("unattributed", 0): return .unattributed
        default: throw SemanticProjectionFormatError.unknownToken
        }
    }
    static func node(_ value: SemanticCoverage) throws -> W {
        switch value {
        case .complete: return .record("complete", [])
        case let .incomplete(status, missing, reasons):
            guard status != .complete else { throw SemanticProjectionFormatError.nonCanonical }
            return .record("incomplete", [node(status), try .sorted(missing.map(node)), .sorted(Set(reasons).map(node))])
        }
    }
    static func readCoverage(_ value: W) throws -> SemanticCoverage {
        if value == .record("complete", []) { return .complete }
        let f = try value.fields("incomplete", 3)
        let status = try readReviewCoverageStatus(f[0])
        guard status != .complete else { throw SemanticProjectionFormatError.nonCanonical }
        return .incomplete(status: status, missing: try f[1].list(readSemanticInterval), reasons: try f[2].list(readReviewCoverageReasonKind))
    }
    static func node(_ value: SemanticPeriodProjection) throws -> W {
        .record("semantic-period-projection", [
            .string(SemanticPeriodProjectionFormat.v1.token),
            try node(value.period), node(value.kind), try node(value.coverage),
            try node(value.budget), try .sorted(value.transactions.map(node)),
            try .sorted(value.observations.map(node)), try .sorted(value.expectations.map(node))
        ])
    }
    static func projection(_ value: W) throws -> SemanticPeriodProjection {
        let f = try value.fields("semantic-period-projection", 8)
        guard try f[0].text() == SemanticPeriodProjectionFormat.v1.token else {
            throw SemanticProjectionFormatError.unsupportedVersion
        }
        return SemanticPeriodProjection(
            period: try readSemanticInterval(f[1]), kind: try readReviewPeriodKind(f[2]),
            coverage: try readCoverage(f[3]), budget: try readSemanticBudgetFact(f[4]),
            transactions: try f[5].list(readSemanticTransactionFact),
            observations: try f[6].list(readSemanticObservationFact),
            expectations: try f[7].list(readSemanticExpectationFact)
        )
    }
}
