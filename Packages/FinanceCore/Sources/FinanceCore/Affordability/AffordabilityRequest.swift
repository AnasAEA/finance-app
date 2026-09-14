/// Structural problems with an affordability request — distinct from an
/// economic shortfall, which is a legitimate `AffordabilityVerdict`.
public enum AffordabilityError: Error, Hashable, Sendable {
    case emptyHorizon
    case candidateDateOutsideHorizon
    case candidateAmountNotPositive
    case financingProposalRequired
    case financingCurrencyMismatch
    case duplicatePlannedPurchaseID(String)
    case duplicateSinkingFundID(String)
}

/// Input to one pure affordability evaluation.
///
/// Planned purchases and sinking funds are request fields, not
/// `FinanceDocument` fields: this slice does not bump the interchange schema.
public struct AffordabilityRequest: Hashable, Sendable {

    public var document: FinanceDocument
    public var today: Day
    public var horizonEnd: Day
    public var candidate: AffordabilityCandidate
    public var plannedPurchases: [PlannedPurchase]
    public var sinkingFunds: [SinkingFund]

    /// Optional attribution map for `MonthlyBudgetEngine` (transaction id →
    /// category key). Absent keys leave spending uncategorised.
    public var categoryKeys: [String: String]

    public init(
        document: FinanceDocument,
        today: Day,
        horizonEnd: Day,
        candidate: AffordabilityCandidate,
        plannedPurchases: [PlannedPurchase] = [],
        sinkingFunds: [SinkingFund] = [],
        categoryKeys: [String: String] = [:]
    ) {
        self.document = document
        self.today = today
        self.horizonEnd = horizonEnd
        self.candidate = candidate
        self.plannedPurchases = plannedPurchases
        self.sinkingFunds = sinkingFunds
        self.categoryKeys = categoryKeys
    }

    func validate() throws {
        if today > horizonEnd { throw AffordabilityError.emptyHorizon }
        if candidate.on < today || candidate.on > horizonEnd {
            throw AffordabilityError.candidateDateOutsideHorizon
        }
        if candidate.amount.minorUnits <= 0 {
            throw AffordabilityError.candidateAmountNotPositive
        }
        if candidate.kind == .financingPurchase {
            guard let financing = candidate.financing else {
                throw AffordabilityError.financingProposalRequired
            }
            if financing.originalPurchaseAmount.currency != candidate.amount.currency {
                throw AffordabilityError.financingCurrencyMismatch
            }
            if financing.installments.contains(where: { $0.amount.currency != candidate.amount.currency }) {
                throw AffordabilityError.financingCurrencyMismatch
            }
        }
        let purchaseIDs = plannedPurchases.map(\.id)
        if Set(purchaseIDs).count != purchaseIDs.count {
            let duplicate = purchaseIDs.first { id in purchaseIDs.filter { $0 == id }.count > 1 } ?? ""
            throw AffordabilityError.duplicatePlannedPurchaseID(duplicate)
        }
        let fundIDs = sinkingFunds.map(\.id)
        if Set(fundIDs).count != fundIDs.count {
            let duplicate = fundIDs.first { id in fundIDs.filter { $0 == id }.count > 1 } ?? ""
            throw AffordabilityError.duplicateSinkingFundID(duplicate)
        }
    }
}
