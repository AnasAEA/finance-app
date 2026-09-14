import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

/// A plan containing money the plan is not denominated in.
///
/// The month projection used to sum every planned event into euros with
/// `Money.sum(currency: .eur)`, which traps on the first dirham or dinar. Valid
/// imported data must not be able to bring the app down, and the alternative —
/// converting at some rate nobody recorded — would be worse than the crash.
///
/// Product policy, until an explicit conversion event exists: **the month
/// headline is euro-only.** Foreign obligations are listed, kept, and left out
/// of the totals.
@MainActor
@Suite("A foreign-currency obligation is listed, not converted, not fatal")
struct MultiCurrencyPlanTests {

    private static let today = Day(year: 2026, month: 9, day: 1)

    private static let bank = Account(
        id: "bank-eur", name: "Bank", currency: .eur, kind: .bank,
        supportedRails: PaymentRail.euroBankRails, drawOrder: 0
    )
    private static let dinar = Account(
        id: "wallet-kwd", name: "Dinar wallet", currency: .kwd, kind: .wallet,
        supportedRails: [.electronicPayment], drawOrder: 1
    )
    private static let dirham = Account(
        id: "cash-mad", name: "Dirham cash", currency: .mad, kind: .cash,
        supportedRails: PaymentRail.cashOnlyRails, drawOrder: 2
    )

    private static func document() -> FinanceDocument {
        let accounts = [bank, dinar, dirham]
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: accounts,
            balances: [
                // Funded across the whole horizon in every currency, so the
                // subject of this suite is the projection arithmetic and not a
                // settlement shortfall.
                AccountBalance(accountID: bank.id, balance: Money(minorUnits: 500_000, currency: .eur), asOf: today),
                AccountBalance(accountID: dinar.id, balance: Money(minorUnits: 500_000, currency: .kwd), asOf: today),
                AccountBalance(accountID: dirham.id, balance: Money(minorUnits: 200_000, currency: .mad), asOf: today)
            ],
            planning: FinanceDocument.Planning(
                defaultScenario: .base,
                recurringObligations: [
                    RecurringObligation(
                        id: "ob-rent", name: "Rent",
                        amount: Money(minorUnits: 48_000, currency: .eur),
                        spec: .monthly(onDay: 5, from: today.monthKey, through: nil),
                        requirement: PaymentRequirement(currency: .eur, acceptableRails: [.sepaDirectDebit]),
                        spendingClass: .essential
                    ),
                    RecurringObligation(
                        id: "ob-dinar", name: "Dinar subscription",
                        amount: Money(minorUnits: 12_345, currency: .kwd),
                        spec: .monthly(onDay: 9, from: today.monthKey, through: nil),
                        requirement: PaymentRequirement(currency: .kwd, acceptableRails: [.electronicPayment]),
                        spendingClass: .flexible
                    ),
                    RecurringObligation(
                        id: "ob-dirham", name: "Dirham market money",
                        amount: Money(minorUnits: 15_000, currency: .mad),
                        spec: .monthly(onDay: 12, from: today.monthKey, through: nil),
                        requirement: PaymentRequirement(currency: .mad, acceptableRails: [.physicalCash]),
                        spendingClass: .flexible
                    )
                ]
            )
        )
    }

    /// App-level integration fixture for monthly settlement failures. It is
    /// imported into normalized SwiftData by `Harness`, then FinanceStore
    /// composes and runs the forecast and maps it back to the product facade.
    private static func shortfallDocument(includeKWD: Bool) -> FinanceDocument {
        let month = today.monthKey
        var obligations = [
            RecurringObligation(
                id: "unfunded-eur", name: "Euro settlement failure",
                amount: Money(minorUnits: 1_250, currency: .eur),
                spec: .monthly(onDay: 4, from: month, through: month),
                requirement: .euroBankPayment(rails: [.sepaDirectDebit]),
                spendingClass: .essential
            ),
            RecurringObligation(
                id: "unfunded-mad", name: "Dirham settlement failure",
                amount: Money(minorUnits: 10_000, currency: .mad),
                spec: .monthly(onDay: 15, from: month, through: month),
                requirement: PaymentRequirement(currency: .mad, acceptableRails: [.physicalCash]),
                spendingClass: .essential
            )
        ]
        if includeKWD {
            obligations.append(
                RecurringObligation(
                    id: "unfunded-kwd", name: "Dinar settlement failure",
                    amount: Money(minorUnits: 3_750, currency: .kwd),
                    spec: .monthly(onDay: 28, from: month, through: month),
                    requirement: PaymentRequirement(currency: .kwd, acceptableRails: [.electronicPayment]),
                    spendingClass: .essential
                )
            )
        }

        let accounts = [bank, dinar, dirham]
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "MULTI-CURRENCY-SHORTFALL-INTEGRATION-TEST",
            accounts: accounts,
            balances: accounts.map {
                AccountBalance(
                    accountID: $0.id,
                    balance: Money(minorUnits: 0, currency: $0.currency),
                    asOf: today
                )
            },
            planning: FinanceDocument.Planning(
                defaultScenario: .base,
                recurringObligations: obligations
            )
        )
    }

    /// Container and store together: a `ModelContext` does not keep its
    /// container alive, and a store built on a deallocated one traps.
    @MainActor
    private final class Harness {
        let container: ModelContainer
        let store: FinanceStore

        init(_ document: FinanceDocument) throws {
            container = try ModelContainer(
                for: Schema(FinanceSchema.models),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            let importer = try FinanceStore(
                context: container.mainContext,
                now: fixtureInstant(MultiCurrencyPlanTests.today)
            )
            try importer.importDocument(document)
            // Reload from the normalized rows before asserting the facade, so
            // these are persistence-to-forecast integration tests rather than
            // tests of the importer's retained in-memory document.
            store = try FinanceStore(
                context: container.mainContext,
                now: fixtureInstant(MultiCurrencyPlanTests.today)
            )
        }
    }

    private static func harness() throws -> Harness { try Harness(document()) }

    @Test("A KWD and a MAD obligation produce a plan instead of a trap")
    func foreignObligationsDoNotCrash() throws {
        let harness = try Self.harness()
        let store = harness.store
        let month = try #require(store.snapshot.monthProjections.first)
        #expect(!store.snapshot.monthProjections.isEmpty)
        #expect(month.plannedSpending.currencyCode == "EUR")
        #expect(month.plannedIncome.currencyCode == "EUR")
    }

    @Test("The euro headline counts euro events only")
    func totalsAreEuroOnly() throws {
        let harness = try Self.harness()
        let store = harness.store
        let month = try #require(store.snapshot.monthProjections.first)
        // Rent alone. Not rent + 12.345 KWD + 150 MAD read as euros.
        #expect(month.plannedSpending == .eur(480.00))
        #expect(month.events.allSatisfy { $0.amount.currencyCode == "EUR" })
    }

    @Test("Foreign obligations are kept, in their own currency")
    func foreignEventsArePreserved() throws {
        let harness = try Self.harness()
        let store = harness.store
        let month = try #require(store.snapshot.monthProjections.first)
        let foreign = month.eventsInOtherCurrencies

        let dinar = try #require(foreign.first { $0.amount.currencyCode == "KWD" })
        #expect(dinar.amount.minorUnits == -12_345)
        #expect(dinar.amount.fractionDigits == 3)

        let dirham = try #require(foreign.first { $0.amount.currencyCode == "MAD" })
        #expect(dirham.amount.minorUnits == -15_000)

        // Kept apart from the euro list, never both.
        #expect(!month.events.contains { foreign.contains($0) })
    }

    @Test("The upcoming list still shows every currency")
    func upcomingKeepsEverything() throws {
        let harness = try Self.harness()
        let store = harness.store
        let codes = Set(store.snapshot.upcomingEvents.map(\.amount.currencyCode))
        #expect(codes.isSuperset(of: ["EUR", "KWD", "MAD"]))
    }

    @Test("A foreign budget does not trap the everyday total either")
    func foreignBudgetIsNotSummedIntoEuros() throws {
        var document = Self.document()
        document.planning.budgets = [
            BudgetAllocation(
                id: "budget-eur", name: "Groceries", spendingClass: .flexible,
                monthlyAmount: Money(minorUnits: 17_000, currency: .eur),
                effectiveFrom: Self.today.monthKey
            ),
            BudgetAllocation(
                id: "budget-mad", name: "Market", spendingClass: .flexible,
                monthlyAmount: Money(minorUnits: 30_000, currency: .mad),
                effectiveFrom: Self.today.monthKey
            )
        ]
        let store = try Harness(document).store

        #expect(store.snapshot.budgetLines.count == 2)
        #expect(store.snapshot.everydayBudget.limit == .eur(170))
    }

    @Test("EUR and MAD settlement failures survive persistence, forecast, and facade mapping")
    func eurAndMADShortfallsSurviveTheAppPipeline() throws {
        let document = Self.shortfallDocument(includeKWD: false)
        let harness = try Harness(document)
        let month = try #require(harness.store.snapshot.currentMonth)

        #expect(try harness.store.exportDocument() == document)
        #expect(month.unfundedEUR == Amount(minorUnits: 1_250, currencyCode: "EUR"))
        #expect(month.unfundedInOtherCurrencies == [
            Amount(minorUnits: 10_000, currencyCode: "MAD")
        ])
        #expect(month.unfundedEUR?.decimalValue == Decimal(string: "12.50"))
        #expect(month.unfundedInOtherCurrencies[0].decimalValue == Decimal(100))
    }

    @Test("EUR, MAD, and three-decimal KWD shortfalls stay separate and deterministic")
    func threeCurrencyShortfallsKeepExactExponents() throws {
        let document = Self.shortfallDocument(includeKWD: true)
        let harness = try Harness(document)
        let month = try #require(harness.store.snapshot.currentMonth)
        let foreign = month.unfundedInOtherCurrencies

        #expect(try harness.store.exportDocument() == document)
        #expect(month.unfundedEUR == Amount(minorUnits: 1_250, currencyCode: "EUR"))
        #expect(foreign.map(\.currencyCode) == ["KWD", "MAD"])
        #expect(foreign == [
            Amount(minorUnits: 3_750, currencyCode: "KWD", fractionDigits: 3),
            Amount(minorUnits: 10_000, currencyCode: "MAD")
        ])
        #expect(foreign[0].decimalValue == Decimal(string: "3.750"))
        #expect(foreign[0].fractionDigits == 3)
    }
}
