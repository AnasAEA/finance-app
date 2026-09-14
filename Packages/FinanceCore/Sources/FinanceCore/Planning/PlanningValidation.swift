/// Structural checks on persisted planning state.
///
/// These are document-integrity rules, not affordability. A reserved amount
/// larger than today's cash is a live shortfall, not corruption.
public enum PlanningValidationError: Error, Hashable, Sendable {
    case duplicatePlannedPurchaseID(String)
    case duplicateSinkingFundID(String)
    case purchaseReferencesMissingFund(purchaseID: String, fundID: String)
    case dedicatedFundReferencesMissingAccount(fundID: String, accountID: String)
    case dedicatedFundAccountCurrencyMismatch(fundID: String)
    case negativeReservedAmount(id: String)
    case reservedCurrencyMismatch(id: String)
    case sinkingFundedPurchaseCarriesOwnReservation(purchaseID: String)
    case purchaseReferencesMissingInstallmentPlan(purchaseID: String, planID: String)
    case purchaseReferencesMissingBudget(purchaseID: String, budgetID: String)
    case fundReferencesMissingGoal(fundID: String, goalID: String)
    case installmentPlanOnNonFinancedPurchase(purchaseID: String)
    case schemaVersionTooOldForPlanningState(found: String)
}

public enum PlanningValidation {

    /// True when the document carries durable Phase 2.7 rows that 1.5 cannot
    /// represent. Empty arrays are not 1.6 data.
    public static func containsDurablePlanningState(_ planning: FinanceDocument.Planning) -> Bool {
        !planning.plannedPurchases.isEmpty || !planning.sinkingFunds.isEmpty
    }

    public static func validate(_ document: FinanceDocument) throws {
        let planning = document.planning
        if containsDurablePlanningState(planning),
           !Interchange.isVersion(document.schemaVersion, atLeast: Interchange.planningStateSchemaVersion) {
            throw PlanningValidationError.schemaVersionTooOldForPlanningState(found: document.schemaVersion)
        }

        var purchaseIDs: Set<String> = []
        for purchase in planning.plannedPurchases {
            guard purchaseIDs.insert(purchase.id).inserted else {
                throw PlanningValidationError.duplicatePlannedPurchaseID(purchase.id)
            }
            if purchase.reservedAmount.isNegative {
                throw PlanningValidationError.negativeReservedAmount(id: purchase.id)
            }
            if purchase.reservedAmount.currency != purchase.targetAmount.currency {
                throw PlanningValidationError.reservedCurrencyMismatch(id: purchase.id)
            }
            switch purchase.funding {
            case let .sinkingFund(fundID):
                if purchase.reservedAmount.isPositive {
                    throw PlanningValidationError.sinkingFundedPurchaseCarriesOwnReservation(purchaseID: purchase.id)
                }
                guard planning.sinkingFunds.contains(where: { $0.id == fundID }) else {
                    throw PlanningValidationError.purchaseReferencesMissingFund(
                        purchaseID: purchase.id, fundID: fundID
                    )
                }
                if purchase.installmentPlanID != nil {
                    throw PlanningValidationError.installmentPlanOnNonFinancedPurchase(purchaseID: purchase.id)
                }
            case .cashOnPurchase:
                if purchase.installmentPlanID != nil {
                    throw PlanningValidationError.installmentPlanOnNonFinancedPurchase(purchaseID: purchase.id)
                }
            case .financing:
                if let planID = purchase.installmentPlanID {
                    guard document.installments.contains(where: { $0.id == planID }) else {
                        throw PlanningValidationError.purchaseReferencesMissingInstallmentPlan(
                            purchaseID: purchase.id, planID: planID
                        )
                    }
                }
            }
            if let budgetID = purchase.budgetID {
                guard planning.budgets.contains(where: { $0.id == budgetID }) else {
                    throw PlanningValidationError.purchaseReferencesMissingBudget(
                        purchaseID: purchase.id, budgetID: budgetID
                    )
                }
            }
        }

        var fundIDs: Set<String> = []
        let accountsByID = Dictionary(document.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for fund in planning.sinkingFunds {
            guard fundIDs.insert(fund.id).inserted else {
                throw PlanningValidationError.duplicateSinkingFundID(fund.id)
            }
            if fund.reservedAmount.isNegative {
                throw PlanningValidationError.negativeReservedAmount(id: fund.id)
            }
            if fund.reservedAmount.currency != fund.targetAmount.currency {
                throw PlanningValidationError.reservedCurrencyMismatch(id: fund.id)
            }
            if let contribution = fund.contributionAmount, contribution.currency != fund.targetAmount.currency {
                throw PlanningValidationError.reservedCurrencyMismatch(id: fund.id)
            }
            if let goalID = fund.goalID {
                guard purchaseIDs.contains(goalID) else {
                    throw PlanningValidationError.fundReferencesMissingGoal(fundID: fund.id, goalID: goalID)
                }
            }
            if case let .dedicatedAccount(accountID) = fund.custody {
                guard let account = accountsByID[accountID] else {
                    throw PlanningValidationError.dedicatedFundReferencesMissingAccount(
                        fundID: fund.id, accountID: accountID
                    )
                }
                guard account.currency == fund.targetAmount.currency else {
                    throw PlanningValidationError.dedicatedFundAccountCurrencyMismatch(fundID: fund.id)
                }
            }
        }
    }
}
