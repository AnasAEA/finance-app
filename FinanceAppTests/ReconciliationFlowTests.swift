import Foundation
import SwiftUI
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

// Phase 2.3 through the store: the product flow, the forecast effect, and the
// refusals a person can actually hit.
//
// Synthetic throughout. The rules are named for their shape at analogous
// amounts; no real balance, date or account belonging to anybody appears here.

/// Accounts, rules and drafts the reconciliation suite shares.
///
/// Outside the `@MainActor` suite on purpose: a default argument is evaluated
/// in a nonisolated context, so `_ document: FinanceDocument = document()`
/// against an isolated static is an actor-isolation violation — and enough to
/// stop the testing macro registering the suite's tests at all.
enum ReconciliationFixtures {

    /// Before the 26th, so the September occurrence is still ahead of the
    /// forecast start: an occurrence already in the past is not forecast at
    /// all, and suppressing it could not change a projection it never entered.
    static let today = Day(year: 2026, month: 9, day: 20)

    /// After it, for the cases about a payment whose day has gone by.
    static let afterTheDate = Day(year: 2026, month: 9, day: 30)

    /// Deliberately without `.electronicPayment`: the rail-mismatch case needs
    /// an account the wallet-only template genuinely does not anticipate.
    static let bank = Account(
        id: "bank-eur", name: "Bank", currency: .eur, kind: .bank,
        supportedRails: [.cardDebit, .sepaCreditTransfer, .sepaDirectDebit], drawOrder: 0
    )
    static let wallet = Account(
        id: "wallet-eur", name: "Wallet", currency: .eur, kind: .wallet,
        supportedRails: PaymentRail.euroWalletRails, drawOrder: 1
    )

    static func euro(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .eur)! }

    /// A monthly subscription billed on the 26th.
    static func rule(
        amount: String = "7.99",
        requirement: PaymentRequirement = PaymentRequirement.euroBankPayment()
    ) -> RecurringObligation {
        RecurringObligation(
            id: "ob-streaming", name: "Streaming Premium", amount: euro(amount),
            spec: .monthly(onDay: 26, from: MonthKey(year: 2026, month: 9), through: nil),
            requirement: requirement, spendingClass: .optional
        )
    }

    /// An observed debit.
    static func actual(
        id: String = "tx-1", on day: Day = Day(year: 2026, month: 9, day: 26),
        amount: String = "7.99", account: String = "bank-eur"
    ) -> FinanceCore.Transaction {
        FinanceCore.Transaction(
            id: id, date: day, kind: .expense,
            legs: [AccountLeg(accountID: account, amount: euro(amount).negated)],
            factivity: .observed, lifecycle: .cleared,
            provenance: Provenance(source: "TEST", evidenceGrade: .userConfirmed)
        )
    }

    static func document(
        obligations: [RecurringObligation] = [rule()],
        transactions: [FinanceCore.Transaction] = [actual()]
    ) -> FinanceDocument {
        let accounts = [bank, wallet]
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: accounts,
            balances: accounts.map {
                AccountBalance(accountID: $0.id, balance: euro("500.00"), asOf: today)
            },
            transactions: transactions,
            planning: FinanceDocument.Planning(recurringObligations: obligations)
        )
    }
}

/// A container plus the store that lives on it, kept together so the container
/// outlives the context.
@MainActor
struct ReconciliationHarness {
    let container: ModelContainer
    let store: FinanceStore

    init(
        _ document: FinanceDocument = ReconciliationFixtures.document(),
        today: Day = ReconciliationFixtures.today
    ) throws {
        container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        store = try FinanceStore(context: container.mainContext, now: fixtureInstant(today))
        try store.importDocument(document)
    }
}

@MainActor
@Suite("Reconciling an expected payment with an actual one")
struct ReconciliationFlowTests {

    /// The September occurrence's product id.
    private var septemberID: String { "ob-streaming@2026-09-26" }

    // MARK: - The double count, and its removal

    @Test("Matching frees exactly one payment from the projection")
    func matchingChangesTheProjectionOnce() throws {
        let harness = try ReconciliationHarness()
        let store = harness.store

        let before = store.snapshot
        #expect(before.expectedPayments.contains { $0.id == septemberID })
        let beforeSafe = before.safeToSpend
        let beforeClosing = before.currentMonth?.closing

        try store.matchPayment(expectedPaymentID: septemberID, transactionID: "tx-1")

        let after = store.snapshot
        #expect((after.safeToSpend - beforeSafe) == .eur(7.99),
                "the payment stops being expected on top of the balance it already left")
        if let beforeClosing, let afterClosing = after.currentMonth?.closing {
            #expect((afterClosing - beforeClosing) == .eur(7.99))
        }

        // And only once: matching does not keep giving.
        #expect(after.expectedPayments.first { $0.id == septemberID }?.status
                == .paid(transactionID: "tx-1"))
        #expect(after.reconciliations["tx-1"]?.ruleName == "Streaming Premium")
    }

    @Test("The recurring rule keeps running after one of its payments is settled")
    func futureOccurrencesSurvive() throws {
        let harness = try ReconciliationHarness()
        try harness.store.matchPayment(expectedPaymentID: septemberID, transactionID: "tx-1")

        let october = harness.store.snapshot.expectedPayments.first {
            $0.ruleID == "ob-streaming" && $0.expectedDate.month == 10
        }
        #expect(october != nil, "October is still expected")
        #expect(october?.status == .due)
    }

    // MARK: - Two dates, never merged

    @Test("The expected date and the paid date are both kept")
    func bothDatesSurvive() throws {
        // Expected on the 26th, actually taken on the 29th.
        let late = ReconciliationFixtures.actual(on: Day(year: 2026, month: 9, day: 29))
        let harness = try ReconciliationHarness(ReconciliationFixtures.document(transactions: [late]))
        try harness.store.matchPayment(expectedPaymentID: septemberID, transactionID: "tx-1")

        let summary = try #require(harness.store.snapshot.reconciliations["tx-1"])
        #expect(summary.expectedDate == CalendarDay(year: 2026, month: 9, day: 26))
        #expect(summary.actualDate == CalendarDay(year: 2026, month: 9, day: 29))

        let occurrence = try #require(
            harness.store.snapshot.expectedPayments.first { $0.id == septemberID }
        )
        #expect(occurrence.expectedDate == CalendarDay(year: 2026, month: 9, day: 26),
                "the inferred expectation is never rewritten to the observed date")
    }

    // MARK: - Rail mismatch

    @Test("A payment made from an unplanned account still settles its expectation")
    func railMismatchIsAllowedAndAttributedToTheRealAccount() throws {
        // Planned as an electronic wallet payment; actually taken from the bank.
        let walletOnly = PaymentRequirement(currency: .eur, acceptableRails: [.electronicPayment])
        let harness = try ReconciliationHarness(ReconciliationFixtures.document(obligations: [ReconciliationFixtures.rule(requirement: walletOnly)]))
        let store = harness.store

        let candidates = store.matches(forTransaction: "tx-1")
        #expect(candidates.count == 1)
        #expect(candidates[0].strength == .strong)
        #expect(candidates[0].accountLabel == "Bank")
        #expect(candidates[0].reasons.contains { $0.contains("different account") })

        try store.matchPayment(expectedPaymentID: septemberID, transactionID: "tx-1")
        #expect(store.snapshot.reconciliations["tx-1"]?.accountLabel == "Bank",
                "the account that really paid is the account shown")
    }

    // MARK: - Amounts

    @Test("An inexact amount is refused until the difference is accepted")
    func inexactAmountNeedsExplicitConfirmation() throws {
        // The rule still says €4.00; the charge was €3.49.
        let harness = try ReconciliationHarness(ReconciliationFixtures.document(
            obligations: [ReconciliationFixtures.rule(amount: "4.00")],
            transactions: [ReconciliationFixtures.actual(amount: "3.49")]
        ))
        let store = harness.store

        let candidate = try #require(store.matches(forTransaction: "tx-1").first)
        #expect(candidate.requiresAmountConfirmation)
        #expect(candidate.strength != .strong)

        #expect(throws: AppReconciliationError.amountDiffersWithoutConfirmation) {
            try store.matchPayment(expectedPaymentID: septemberID, transactionID: "tx-1")
        }
        #expect(store.snapshot.expectedPayments.first { $0.id == septemberID }?.isResolved == false)

        try store.matchPayment(
            expectedPaymentID: septemberID, transactionID: "tx-1", acceptingAmountDifference: true
        )
        #expect(store.snapshot.reconciliations["tx-1"]?.amountDifferenceAccepted == true)
    }

    @Test("An exact amount needs no confirmation")
    func exactAmountJustMatches() throws {
        let harness = try ReconciliationHarness(ReconciliationFixtures.document(
            obligations: [ReconciliationFixtures.rule(amount: "3.49")],
            transactions: [ReconciliationFixtures.actual(amount: "3.49", account: ReconciliationFixtures.bank.id)]
        ))
        let candidate = try #require(harness.store.matches(forTransaction: "tx-1").first)
        #expect(!candidate.requiresAmountConfirmation)
        #expect(candidate.strength == .strong)
        #expect(throws: Never.self) {
            try harness.store.matchPayment(expectedPaymentID: septemberID, transactionID: "tx-1")
        }
    }

    // MARK: - Refusals

    @Test("One transaction cannot settle two expected payments")
    func oneActualSettlesOneOccurrence() throws {
        let second = RecurringObligation(
            id: "ob-membership", name: "Retail Membership", amount: ReconciliationFixtures.euro("7.99"),
            spec: .monthly(onDay: 27, from: MonthKey(year: 2026, month: 9), through: nil),
            requirement: PaymentRequirement.euroBankPayment(), spendingClass: .optional
        )
        let harness = try ReconciliationHarness(ReconciliationFixtures.document(obligations: [ReconciliationFixtures.rule(), second]))
        let store = harness.store

        try store.matchPayment(expectedPaymentID: septemberID, transactionID: "tx-1")
        #expect(throws: AppReconciliationError.transactionAlreadyMatched) {
            try store.matchPayment(expectedPaymentID: "ob-membership@2026-09-27", transactionID: "tx-1")
        }
    }

    @Test("One expected payment cannot be settled twice")
    func oneOccurrenceTakesOneActual() throws {
        let harness = try ReconciliationHarness(ReconciliationFixtures.document(transactions: [
            ReconciliationFixtures.actual(id: "tx-1"),
            ReconciliationFixtures.actual(id: "tx-2", on: Day(year: 2026, month: 9, day: 27)),
        ]))
        let store = harness.store

        try store.matchPayment(expectedPaymentID: septemberID, transactionID: "tx-1")
        #expect(throws: AppReconciliationError.alreadyResolved) {
            try store.matchPayment(expectedPaymentID: septemberID, transactionID: "tx-2")
        }
    }

    @Test("An implausible pairing is not offered and not accepted")
    func implausiblePairingIsRefused() throws {
        let harness = try ReconciliationHarness(ReconciliationFixtures.document(transactions: [ReconciliationFixtures.actual(amount: "54.00")]))
        let store = harness.store
        #expect(store.matches(forTransaction: "tx-1").isEmpty)
        #expect(throws: (any Error).self) {
            try store.matchPayment(expectedPaymentID: septemberID, transactionID: "tx-1")
        }
    }

    // MARK: - Skipping, and undoing

    @Test("Skipping one payment leaves the commitment running")
    func skippingDoesNotCancel() throws {
        let harness = try ReconciliationHarness(ReconciliationFixtures.document(transactions: []))
        let store = harness.store

        let before = store.snapshot.safeToSpend
        try store.skipExpectedPayment(id: septemberID)

        #expect(store.snapshot.expectedPayments.first { $0.id == septemberID }?.status == .skipped)
        #expect((store.snapshot.safeToSpend - before) == .eur(7.99),
                "a skipped payment stops being expected")
        #expect(store.snapshot.expectedPayments.contains {
            $0.ruleID == "ob-streaming" && $0.expectedDate.month == 10 && $0.status == .due
        }, "October is untouched")
    }

    @Test("Marking a payment no longer due is not the same as skipping it")
    func noLongerDueIsItsOwnAnswer() throws {
        let harness = try ReconciliationHarness(ReconciliationFixtures.document(transactions: []))
        try harness.store.markExpectedPaymentNoLongerDue(id: septemberID)
        #expect(harness.store.snapshot.expectedPayments.first { $0.id == septemberID }?.status
                == .noLongerDue)
    }

    @Test("Undoing a match restores the question without touching either side")
    func undoRestoresTheOccurrence() throws {
        let harness = try ReconciliationHarness()
        let store = harness.store
        let originalSafe = store.snapshot.safeToSpend

        try store.matchPayment(expectedPaymentID: septemberID, transactionID: "tx-1")
        try store.unmatchExpectedPayment(id: septemberID)

        #expect(store.snapshot.expectedPayments.first { $0.id == septemberID }?.status == .due)
        #expect(store.snapshot.reconciliations["tx-1"] == nil)
        #expect(store.snapshot.safeToSpend == originalSafe)
        // The transaction itself is still there, unchanged.
        #expect(store.snapshot.activity.flatMap(\.rows).contains { $0.id == "tx-1" })
    }

    @Test("An unmatched payment whose day has passed stays a question")
    func overdueStaysVisible() throws {
        let harness = try ReconciliationHarness(
            ReconciliationFixtures.document(transactions: []),
            today: ReconciliationFixtures.afterTheDate
        )
        let payment = try #require(
            harness.store.snapshot.expectedPayments.first { $0.id == septemberID }
        )
        #expect(payment.status == .overdue)
        #expect(payment.status.label == "Expected")
        #expect(harness.store.snapshot.overdueExpectedPayments.contains { $0.id == septemberID })
    }

    // MARK: - Persistence

    @Test("A match survives being written and read back")
    func matchSurvivesTheStore() throws {
        let harness = try ReconciliationHarness()
        try harness.store.matchPayment(expectedPaymentID: septemberID, transactionID: "tx-1")

        // Re-open the same container with a new store: nothing in memory helps.
        let reopened = try FinanceStore(
            context: harness.container.mainContext,
            now: fixtureInstant(ReconciliationFixtures.today)
        )
        #expect(reopened.loadFailure == nil)
        #expect(reopened.snapshot.expectedPayments.first { $0.id == septemberID }?.status
                == .paid(transactionID: "tx-1"))
        #expect(reopened.snapshot.reconciliations["tx-1"] != nil)

        // And through the document spine.
        let exported = try reopened.exportDocument()
        #expect(exported.planning.settlements.count == 1)
        #expect(exported.planning.settlements[0].actualTransactionID == "tx-1")
        #expect(exported.planning.settlements[0].expectedDay == Day(year: 2026, month: 9, day: 26))

        let reDecoded = try Interchange.decode(Interchange.encode(exported))
        #expect(reDecoded.planning.settlements == exported.planning.settlements)
    }

    @Test("A document from before reconciliation existed still imports")
    func olderSchemaStillImports() throws {
        var older = ReconciliationFixtures.document()
        older.schemaVersion = "1.1.0"
        let harness = try ReconciliationHarness(older)
        // Stored as what this build writes, with nothing reconciled.
        #expect(try harness.store.exportDocument().schemaVersion == Interchange.currentSchemaVersion)
        #expect(try harness.store.exportDocument().planning.settlements.isEmpty)
        #expect(harness.store.snapshot.expectedPayments.isEmpty == false)
    }

    @Test("A document carrying a broken reconciliation is refused whole")
    func brokenReconciliationIsRefused() throws {
        var broken = ReconciliationFixtures.document()
        broken.planning.settlements = [
            .paid(id: "s-1", obligationID: "ob-streaming",
                  expectedDay: Day(year: 2026, month: 9, day: 26), actualTransactionID: "tx-1"),
            .paid(id: "s-2", obligationID: "ob-streaming",
                  expectedDay: Day(year: 2026, month: 9, day: 26), actualTransactionID: "tx-1"),
        ]
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = try FinanceStore(context: container.mainContext, now: fixtureInstant(ReconciliationFixtures.today))
        #expect(throws: (any Error).self) { try store.importDocument(broken) }
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredAccount>()) == 0,
                "nothing is written on the way to refusing")
    }
}

// MARK: - Rendering

/// Every reconciliation state renders, in both schemes and at accessibility
/// type sizes. A flow whose middle screens are only reachable by tapping
/// through a picker is a flow whose middle screens are never looked at.
@MainActor
@Suite("Reconciliation screens render")
struct ReconciliationRenderingTests {

    private var septemberID: String { "ob-streaming@2026-09-26" }

    private func settledHarness() throws -> ReconciliationHarness {
        let harness = try ReconciliationHarness()
        try harness.store.matchPayment(expectedPaymentID: septemberID, transactionID: "tx-1")
        return harness
    }

    @Test("The expected payments list renders in both schemes and at accessibility sizes")
    func listRenders() throws {
        let harness = try settledHarness()
        for scheme in [ColorScheme.light, .dark] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                #expect(
                    RenderCheck.image(
                        NavigationStack { ExpectedPaymentsView() },
                        store: harness.store, scheme: scheme, typeSize: size
                    ) != nil
                )
            }
        }
    }

    @Test("An unresolved expected payment renders with its three answers")
    func unresolvedDetailRenders() throws {
        let harness = try ReconciliationHarness()
        let payment = try #require(
            harness.store.snapshot.expectedPayments.first { $0.id == septemberID }
        )
        #expect(payment.isResolved == false)
        for scheme in [ColorScheme.light, .dark] {
            #expect(
                RenderCheck.image(
                    NavigationStack { ExpectedPaymentDetailView(payment: payment) },
                    store: harness.store, scheme: scheme
                ) != nil
            )
        }
        #expect(
            RenderCheck.image(
                NavigationStack { ExpectedPaymentDetailView(payment: payment) },
                store: harness.store, typeSize: .accessibility3
            ) != nil
        )
    }

    @Test("A matched expected payment renders its transaction and its undo")
    func matchedDetailRenders() throws {
        let harness = try settledHarness()
        let payment = try #require(
            harness.store.snapshot.expectedPayments.first { $0.id == septemberID }
        )
        #expect(payment.status == .paid(transactionID: "tx-1"))
        for scheme in [ColorScheme.light, .dark] {
            #expect(
                RenderCheck.image(
                    NavigationStack { ExpectedPaymentDetailView(payment: payment) },
                    store: harness.store, scheme: scheme
                ) != nil
            )
        }
    }

    @Test("An overdue expected payment renders as a question")
    func overdueRenders() throws {
        let harness = try ReconciliationHarness(
            ReconciliationFixtures.document(transactions: []),
            today: ReconciliationFixtures.afterTheDate
        )
        let payment = try #require(
            harness.store.snapshot.expectedPayments.first { $0.id == septemberID }
        )
        #expect(payment.status == .overdue)
        #expect(
            RenderCheck.image(
                NavigationStack { ExpectedPaymentsView() },
                store: harness.store, scheme: .dark, typeSize: .accessibility3
            ) != nil
        )
    }

    @Test("The candidate picker renders, with candidates and without")
    func pickerRenders() throws {
        let harness = try ReconciliationHarness()
        let matches = harness.store.matches(forExpectedPayment: septemberID)
        #expect(!matches.isEmpty)

        for scheme in [ColorScheme.light, .dark] {
            #expect(
                RenderCheck.image(
                    MatchPickerView(
                        title: "Match a transaction",
                        explanation: "Choose the transaction that paid Streaming Premium.",
                        matches: matches, side: .actual
                    ) { _, _ in },
                    store: harness.store, scheme: scheme
                ) != nil
            )
        }
        // The empty state is a screen too.
        #expect(
            RenderCheck.image(
                MatchPickerView(
                    title: "Match a transaction", explanation: "",
                    matches: [], side: .expected
                ) { _, _ in },
                store: harness.store, typeSize: .accessibility3
            ) != nil
        )
    }

    @Test("A matched transaction's detail renders its recurring section")
    func transactionDetailRenders() throws {
        let harness = try settledHarness()
        let row = try #require(
            harness.store.snapshot.activity.flatMap(\.rows).first { $0.id == "tx-1" }
        )
        #expect(harness.store.snapshot.reconciliations["tx-1"] != nil)
        for scheme in [ColorScheme.light, .dark] {
            #expect(
                RenderCheck.image(
                    NavigationStack {
                        TransactionDetailView(
                            row: row,
                            date: DomainMapper.civilDay(Day(year: 2026, month: 9, day: 26))
                        )
                    },
                    store: harness.store, scheme: scheme
                ) != nil
            )
        }
    }
}
