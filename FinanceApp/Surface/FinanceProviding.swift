import Foundation

/// The contract between the app and whatever engine is installed underneath it.
///
/// One protocol, five members. The screens read `snapshot`, set `scenario`,
/// ask for a projection under a different scenario, and add or delete a
/// transaction. Nothing else about the engine is visible to them.
///
/// `FinanceStore` is the shipping conformance. A preview or a test can supply a
/// fixed snapshot instead, which is what lets a UI test assert on presentation
/// without running an engine at all.
@MainActor
protocol FinanceProviding: AnyObject, Observable {
    /// Everything on screen right now.
    var snapshot: FinanceAppSnapshot { get }

    /// The scenario the plan is shown under. Setting it recomputes `snapshot`.
    var scenario: PlanScenario { get set }

    /// Current operational day, unavailable when the configured clock cannot be read.
    func currentDay() -> CalendarDay?

    /// A projection under a different scenario, without disturbing the one on
    /// screen. Used by the Plan screen to compare.
    func snapshot(under scenario: PlanScenario) -> FinanceAppSnapshot

    /// Records an entry, or throws `AppEntryError` saying why it could not be.
    /// There is no success-shaped no-op: a return means it is persisted.
    func add(_ draft: TransactionDraft) throws
    func deleteActivityRow(id: String) throws
    func saveAccount(_ draft: AccountDraft) throws
    func saveIncomeSource(_ draft: IncomeSourceDraft) throws
}
