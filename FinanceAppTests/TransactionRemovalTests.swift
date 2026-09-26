import Foundation
import SwiftData
import SwiftUI
import Testing
import FinanceCore
@testable import FinanceApp

// MARK: - Shared shapes

/// Documents whose only interesting property is which durable record names a
/// transaction. Synthetic throughout; no real balance, account or counterparty
/// appears here.
///
/// Outside the `@MainActor` suites on purpose: a default argument is evaluated
/// in a nonisolated context, so an isolated static used as one is an
/// actor-isolation violation.
enum RemovalFixtures {

    static let today = Day(year: 2026, month: 9, day: 20)

    static let bank = Account(
        id: "bank-eur", name: "Bank", currency: .eur, kind: .bank,
        supportedRails: PaymentRail.euroBankRails, drawOrder: 0
    )

    static func euro(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .eur)! }

    /// What the app's own entry path produces: a person said so.
    static func stated(
        id: String,
        on day: Day = today,
        amount: String = "12.34",
        kind: TransactionKind = .expense,
        linkedTransactionID: String? = nil
    ) -> FinanceCore.Transaction {
        FinanceCore.Transaction(
            id: id, date: day, kind: kind,
            legs: [AccountLeg(accountID: bank.id, amount: euro(amount).negated)],
            linkedTransactionID: linkedTransactionID,
            factivity: .observed, lifecycle: .cleared,
            provenance: Provenance(source: "MANUAL-ENTRY", evidenceGrade: .userConfirmed)
        )
    }

    /// What an import of reconstructed bank records carries.
    static func sourced(id: String, on day: Day = today, amount: String = "12.34") -> FinanceCore.Transaction {
        FinanceCore.Transaction(
            id: id, date: day, kind: .expense,
            legs: [AccountLeg(accountID: bank.id, amount: euro(amount).negated)],
            factivity: .observed, lifecycle: .cleared,
            provenance: Provenance(source: "BNP-STATEMENT", evidenceGrade: .primarySource)
        )
    }

    static func document(
        transactions: [FinanceCore.Transaction],
        planning: FinanceDocument.Planning = FinanceDocument.Planning(defaultScenario: .base)
    ) -> FinanceDocument {
        FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [bank],
            balances: [AccountBalance(accountID: bank.id, balance: euro("500.00"), asOf: today)],
            transactions: transactions,
            planning: planning
        )
    }
}

@MainActor
struct RemovalHarness {
    let container: ModelContainer
    let store: FinanceStore

    init(_ document: FinanceDocument, today: Day = RemovalFixtures.today) throws {
        container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        store = try FinanceStore(context: container.mainContext, now: fixtureInstant(today))
        try store.importDocument(document)
    }
}

// MARK: - Removing what a person entered

@MainActor
@Suite("Removing a transaction")
struct TransactionRemovalTests {

    @Test("A transaction nothing else refers to is removable, and removing it recomputes")
    func standaloneStatedTransactionIsRemovable() throws {
        let harness = try RemovalHarness(
            RemovalFixtures.document(transactions: [RemovalFixtures.stated(id: "tx-solo")])
        )
        let store = harness.store
        #expect(store.removalBlocker(forTransaction: "tx-solo") == nil)

        try store.deleteActivityRow(id: "tx-solo")

        // Gone from the document, and gone from what the screen reads.
        #expect(try store.exportDocument().transactions.isEmpty)
        #expect(store.snapshot.activity.flatMap(\.rows).contains { $0.id == "tx-solo" } == false)
        // The balance is derived again without it: 500.00 with no 12.34 debit.
        #expect(store.snapshot.accounts.first { $0.id == "bank-eur" }?.balance == .eur(500.00))
    }

    @Test("Removing one transaction leaves every other record alone")
    func removingOneLeavesTheRestIntact() throws {
        let harness = try RemovalHarness(
            RemovalFixtures.document(transactions: [
                RemovalFixtures.stated(id: "tx-a", amount: "10.00"),
                RemovalFixtures.stated(id: "tx-b", amount: "20.00"),
                RemovalFixtures.sourced(id: "tx-c", amount: "30.00")
            ])
        )
        try harness.store.deleteActivityRow(id: "tx-a")

        let remaining = try harness.store.exportDocument()
        #expect(remaining.transactions.map(\.id).sorted() == ["tx-b", "tx-c"])
        #expect(remaining.accounts.count == 1)
        #expect(remaining.balances.count == 1)
    }

    @Test("A transaction that links outward is still removable")
    func linkingOutwardDoesNotBlockTheLinkingRow() throws {
        // The refund names the expense. Removing the *refund* takes the
        // statement with it and leaves nothing pointing at nothing.
        let harness = try RemovalHarness(
            RemovalFixtures.document(transactions: [
                RemovalFixtures.stated(id: "tx-expense", amount: "40.00"),
                RemovalFixtures.stated(
                    id: "tx-refund", amount: "40.00", kind: .refund,
                    linkedTransactionID: "tx-expense"
                )
            ])
        )
        #expect(harness.store.removalBlocker(forTransaction: "tx-refund") == nil)
        try harness.store.deleteActivityRow(id: "tx-refund")
        #expect(try harness.store.exportDocument().transactions.map(\.id) == ["tx-expense"])
    }

    // MARK: - Refusals

    @Test("Imported source evidence is not removable here")
    func sourceEvidenceIsRefused() throws {
        let harness = try RemovalHarness(
            RemovalFixtures.document(transactions: [RemovalFixtures.sourced(id: "tx-statement")])
        )
        #expect(harness.store.removalBlocker(forTransaction: "tx-statement") == .sourceEvidence)
        #expect(throws: AppRemovalError.sourceEvidence) {
            try harness.store.deleteActivityRow(id: "tx-statement")
        }
        #expect(try harness.store.exportDocument().transactions.count == 1)
    }

    /// The relationship nothing downstream would refuse, which is why it is
    /// checked. A refund whose linked expense disappears silently starts
    /// offsetting spending the reversal had already cancelled.
    @Test("A transaction another one is recorded against is refused")
    func inboundLinkIsRefused() throws {
        let harness = try RemovalHarness(
            RemovalFixtures.document(transactions: [
                RemovalFixtures.stated(id: "tx-expense", amount: "40.00"),
                RemovalFixtures.stated(
                    id: "tx-refund", amount: "40.00", kind: .refund,
                    linkedTransactionID: "tx-expense"
                )
            ])
        )
        #expect(
            harness.store.removalBlocker(forTransaction: "tx-expense")
                == .linkedFromAnotherTransaction
        )
        #expect(throws: AppRemovalError.linkedFromAnotherTransaction) {
            try harness.store.deleteActivityRow(id: "tx-expense")
        }
        #expect(try harness.store.exportDocument().transactions.count == 2)
    }

    @Test("A transaction a goal records as its purchase is refused")
    func goalPurchaseIsRefused() throws {
        let planning = FinanceDocument.Planning(
            defaultScenario: .base,
            plannedPurchases: [
                PlannedPurchase(
                    id: "goal-camera", name: "Camera",
                    targetAmount: RemovalFixtures.euro("400.00"),
                    status: .purchased,
                    purchasedTransactionID: "tx-camera",
                    requirement: .euroBankPayment()
                )
            ]
        )
        let harness = try RemovalHarness(
            RemovalFixtures.document(
                transactions: [RemovalFixtures.stated(id: "tx-camera", amount: "400.00")],
                planning: planning
            )
        )
        #expect(
            harness.store.removalBlocker(forTransaction: "tx-camera") == .recordedAsGoalPurchase
        )
        #expect(throws: AppRemovalError.recordedAsGoalPurchase) {
            try harness.store.deleteActivityRow(id: "tx-camera")
        }
        #expect(try harness.store.exportDocument().transactions.count == 1)
    }

    @Test("A transaction that is not there is refused rather than silently succeeding")
    func missingTransactionIsRefused() throws {
        let harness = try RemovalHarness(
            RemovalFixtures.document(transactions: [RemovalFixtures.stated(id: "tx-solo")])
        )
        #expect(harness.store.removalBlocker(forTransaction: "tx-nothing") == .notFound)
        #expect(throws: AppRemovalError.notFound) {
            try harness.store.deleteActivityRow(id: "tx-nothing")
        }
    }

    /// The read-only facade, which serves a snapshot and owns no document at
    /// all. It refuses before it can even look for the row.
    @Test("A fixed facade store removes nothing")
    func fixedStoreRefuses() throws {
        let store = FinanceStore(
            snapshot: .empty(asOf: DomainMapper.civilDay(RemovalFixtures.today))
        )
        #expect(store.removalBlocker(forTransaction: "tx-anything") == .storeIsReadOnly)
        #expect(throws: AppRemovalError.storeIsReadOnly) {
            try store.deleteActivityRow(id: "tx-anything")
        }
    }

    @Test("A store that could not be read removes nothing")
    func unreadableStoreRefuses() throws {
        let store = try FinanceStore(
            context: nil,
            now: fixtureInstant(RemovalFixtures.today),
            unavailableReason: "Application Support could not be created."
        )
        #expect(store.removalBlocker(forTransaction: "tx-anything") == .storeUnreadable)
        #expect(throws: AppRemovalError.storeUnreadable) {
            try store.deleteActivityRow(id: "tx-anything")
        }
    }

    // MARK: - Nothing is changed by a refusal

    @Test("A refused removal changes nothing at all")
    func refusalMutatesNothing() throws {
        let harness = try RemovalHarness(
            RemovalFixtures.document(transactions: [
                RemovalFixtures.stated(id: "tx-expense", amount: "40.00"),
                RemovalFixtures.stated(
                    id: "tx-refund", amount: "40.00", kind: .refund,
                    linkedTransactionID: "tx-expense"
                ),
                RemovalFixtures.sourced(id: "tx-statement")
            ])
        )
        let before = try harness.store.exportDocument()

        #expect(throws: AppRemovalError.self) {
            try harness.store.deleteActivityRow(id: "tx-expense")
        }
        #expect(throws: AppRemovalError.self) {
            try harness.store.deleteActivityRow(id: "tx-statement")
        }

        #expect(try harness.store.exportDocument() == before)
    }

    // MARK: - No message names a type, a field or an identifier

    @Test("No refusal this path can produce exposes internal vocabulary")
    func refusalsSpeakUserLanguage() {
        let errors: [AppRemovalError] = [
            .storeIsReadOnly, .storeUnreadable, .notFound, .sourceEvidence,
            .settlesExpectedPayment, .linkedToBankEvidence,
            .linkedFromAnotherTransaction, .recordedAsGoalPurchase
        ]
        let forbidden = [
            "ExternalEvidenceLink", "ObligationSettlement", "PlannedPurchase",
            "linkedTransactionID", "transactionID", "FinanceDocument", "nil",
            "Transaction(", "provenance", "evidenceGrade"
        ]
        for error in errors {
            let text = error.message + " " + (error.recoverySuggestion ?? "")
            for token in forbidden {
                #expect(!text.contains(token), "\(error) leaks \(token)")
            }
            #expect(error.message.hasSuffix(".") || error.message.hasSuffix("”"))
        }
    }
}

// MARK: - The relationships the reconciliation and evidence paths create

@MainActor
@Suite("Removal against reconciliation and bank evidence")
struct TransactionRemovalRelationshipTests {

    private var septemberID: String { "ob-streaming@2026-09-26" }

    /// Built through the production matching path, not by hand: the settlement
    /// under test is the one a person actually creates.
    @Test("A transaction that settles an expected payment is refused until unmatched")
    func settlementBlocksRemovalUntilUnmatched() throws {
        let harness = try ReconciliationHarness()
        let store = harness.store
        #expect(store.removalBlocker(forTransaction: "tx-1") == nil)

        try store.matchPayment(expectedPaymentID: septemberID, transactionID: "tx-1")
        #expect(store.removalBlocker(forTransaction: "tx-1") == .settlesExpectedPayment)
        #expect(throws: AppRemovalError.settlesExpectedPayment) {
            try store.deleteActivityRow(id: "tx-1")
        }
        #expect(try store.exportDocument().transactions.contains { $0.id == "tx-1" })

        // The suggestion the refusal makes is one the app can actually carry
        // out, and carrying it out is what unblocks removal.
        let expectedPaymentID = try #require(
            store.snapshot.expectedPayments.first { $0.status.matchedTransactionID == "tx-1" }?.id
        )
        try store.unmatchExpectedPayment(id: expectedPaymentID)

        #expect(store.removalBlocker(forTransaction: "tx-1") == nil)
        try store.deleteActivityRow(id: "tx-1")
        #expect(try store.exportDocument().transactions.isEmpty)
    }

    @Test("A transaction bank evidence is linked to is refused")
    func evidenceLinkBlocksRemoval() throws {
        let harness = try RemovalHarness(try Self.evidenceDocument())
        #expect(
            harness.store.removalBlocker(forTransaction: "economic") == .linkedToBankEvidence
        )
        #expect(throws: AppRemovalError.linkedToBankEvidence) {
            try harness.store.deleteActivityRow(id: "economic")
        }
        #expect(try harness.store.exportDocument().transactions.count == 1)
        #expect(try harness.store.exportDocument().externalEvidenceLinks.count == 1)
    }

    /// The observation is resolved `linkedToTransaction`, which is the state
    /// the link exists to justify. Both halves survive the refusal.
    @Test("The observation's own decision survives a refused removal")
    func observationResolutionSurvivesRefusal() throws {
        let harness = try RemovalHarness(try Self.evidenceDocument())
        let before = try harness.store.exportDocument()
        #expect(before.observationResolutions.first?.state == .linkedToTransaction)

        #expect(throws: AppRemovalError.linkedToBankEvidence) {
            try harness.store.deleteActivityRow(id: "economic")
        }
        #expect(try harness.store.exportDocument() == before)
    }

    private static let timestamp = Date(timeIntervalSince1970: 1_777_680_000)
    private static let boundary = Day(year: 2026, month: 8, day: 22)

    /// One observation, resolved by one user-confirmed transaction it is
    /// linked to — the shape `createExpense(from:)` leaves behind.
    static func evidenceDocument() throws -> FinanceDocument {
        let account = Account(
            id: "local-bank", name: "Synthetic Bank", currency: .eur, kind: .bank,
            supportedRails: [.cardDebit]
        )
        let binding = ExternalAccountBinding(
            id: "binding", provider: .bnp,
            remoteOpaqueAccountID: "acct_00000000000000000000000000000001",
            localAccountID: account.id, syncStartBoundary: boundary, createdAt: timestamp
        )
        let observation = ExternalObservation(
            id: "obs_00000000000000000000000000000001",
            bindingID: binding.id, provider: .bnp, status: .booked,
            creditDebitIndicator: .debit,
            amount: Money(minorUnits: -349, currency: .eur),
            bookingDate: Day(year: 2026, month: 8, day: 23),
            derivedTransactionDate: Day(year: 2026, month: 8, day: 21),
            derivedDateProvenance: .parsedFromProviderRemittance,
            rawMerchantText: "SYNTHETIC PROVIDER TEXT",
            remittance: "SYNTHETIC PROVIDER TEXT",
            eligibleForEconomicActual: true,
            observedAt: timestamp
        )
        var document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account],
            balances: [
                AccountBalance(
                    accountID: account.id,
                    balance: Money(minorUnits: 10_000, currency: .eur),
                    asOf: boundary
                )
            ],
            externalAccountBindings: [binding]
        )
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: [observation], balances: [], candidates: []),
            into: &document
        )
        let transaction = FinanceCore.Transaction(
            id: "economic", date: Day(year: 2026, month: 8, day: 23), kind: .expense,
            legs: [AccountLeg(accountID: account.id, amount: observation.amount)],
            factivity: .observed,
            provenance: Provenance(source: "EXTERNAL-EVIDENCE-REVIEW", evidenceGrade: .userConfirmed)
        )
        try ExternalEvidenceReview.createTransaction(
            transaction,
            evidence: [.init(observationID: observation.id, role: .accountMovement)],
            resolvedAt: timestamp,
            in: &document
        )
        return document
    }
}

// MARK: - The guard is load-bearing

@MainActor
@Suite("Bypassing one removal guard")
struct TransactionRemovalAdversarialTests {

    /// What the guard is actually worth, measured by removing it.
    ///
    /// Two of the four relationships have a second line of defence:
    /// FinanceCore refuses a document whose settlement or evidence link names
    /// a transaction that is not in it, so a removal that slipped past the
    /// eligibility check would still fail on the way to disk. The other two
    /// have none — and this proves the difference rather than assuming it, by
    /// building exactly the document a naive delete would have produced and
    /// asking whether anything objects.
    @Test("FinanceCore independently refuses a dangling settlement or evidence link")
    func domainRefusesDanglingAuthoritativeReferences() throws {
        // A settlement whose actual is gone.
        var reconciled = ReconciliationFixtures.document()
        reconciled.planning.settlements = [
            ObligationSettlement(
                id: "settlement-1", obligationID: "ob-streaming",
                expectedDay: Day(year: 2026, month: 9, day: 26),
                resolution: .paid, actualTransactionID: "tx-1",
                provenance: Provenance(source: "TEST", evidenceGrade: .userConfirmed)
            )
        ]
        reconciled.transactions = []
        #expect(throws: (any Error).self) {
            try StoredDocumentGraph.validate(reconciled)
        }

        // An evidence link whose transaction is gone.
        var evidenced = try TransactionRemovalRelationshipTests.evidenceDocument()
        evidenced.transactions = []
        #expect(throws: (any Error).self) {
            try StoredDocumentGraph.validate(evidenced)
        }
    }

    /// And the two that nothing else would catch. A document missing the
    /// target of an inbound transaction link, or of a goal's purchase, is
    /// rejected at the persistence boundary as well as by removal eligibility.
    @Test("Persistence refuses dangling inbound links and goal purchases")
    func persistenceRefusesBrokenInboundReferences() throws {
        var linked = RemovalFixtures.document(transactions: [
            RemovalFixtures.stated(id: "tx-expense", amount: "40.00"),
            RemovalFixtures.stated(
                id: "tx-refund", amount: "40.00", kind: .refund,
                linkedTransactionID: "tx-expense"
            )
        ])
        linked.transactions.removeAll { $0.id == "tx-expense" }
        // Defense in depth: even a bypass of removal eligibility cannot persist
        // a refund whose original transaction no longer exists.
        #expect(throws: PersistenceMappingError.invalidDocument) { try StoredDocumentGraph.validate(linked) }

        var goal = RemovalFixtures.document(
            transactions: [],
            planning: FinanceDocument.Planning(
                defaultScenario: .base,
                plannedPurchases: [
                    PlannedPurchase(
                        id: "goal-camera", name: "Camera",
                        targetAmount: RemovalFixtures.euro("400.00"),
                        status: .purchased, purchasedTransactionID: "tx-gone",
                        requirement: .euroBankPayment()
                    )
                ]
            )
        )
        goal.transactions = []
        #expect(throws: PersistenceMappingError.invalidDocument) { try StoredDocumentGraph.validate(goal) }
    }

    /// The screen's answer is a courtesy; the store's is the guarantee.
    ///
    /// Eligibility is sampled while the row is removable, the situation then
    /// changes underneath it, and the removal that follows is refused on the
    /// state as it is rather than carried out on the strength of the earlier
    /// answer.
    @Test("An eligibility answer that went stale does not authorise the removal")
    func staleEligibilityDoesNotAuthoriseRemoval() throws {
        let harness = try ReconciliationHarness()
        let store = harness.store

        // What the screen would have read when it drew the button.
        #expect(store.removalBlocker(forTransaction: "tx-1") == nil)

        // The row becomes the settlement of an expected payment while that
        // screen is still open.
        try store.matchPayment(expectedPaymentID: "ob-streaming@2026-09-26", transactionID: "tx-1")

        // The action re-asks, and refuses.
        #expect(throws: AppRemovalError.settlesExpectedPayment) {
            try store.deleteActivityRow(id: "tx-1")
        }
        #expect(try store.exportDocument().transactions.contains { $0.id == "tx-1" })
    }
}

// MARK: - What the person sees

@MainActor
@Suite("The transaction screen offers removal by eligibility")
struct TransactionRemovalPresentationTests {

    private func row(_ store: FinanceStore, id: String) throws -> ActivityRow {
        try #require(store.snapshot.activity.flatMap(\.rows).first { $0.id == id })
    }

    /// The two controls this feature adds are not rows, and must not answer a
    /// search for one — the same hazard `pendingSection` was moved out of the
    /// row namespace to avoid.
    @Test("The removal identifiers stay outside every row namespace")
    func removalIdentifiersAreNotRowIdentities() {
        let added = [ActivityID.removeTransaction, ActivityID.removeBlocked]
        #expect(Set(added).count == added.count)
        for identifier in added {
            for prefix in ActivityID.rowPrefixes {
                #expect(!identifier.hasPrefix(prefix), "\(identifier) answers to \(prefix)")
            }
        }
    }

    @Test("The removable and the blocked screens both render")
    func bothRemovalStatesRender() throws {
        let harness = try RemovalHarness(
            RemovalFixtures.document(transactions: [
                RemovalFixtures.stated(id: "tx-expense", amount: "40.00"),
                RemovalFixtures.stated(
                    id: "tx-refund", amount: "40.00", kind: .refund,
                    linkedTransactionID: "tx-expense"
                ),
                RemovalFixtures.sourced(id: "tx-statement")
            ])
        )
        let store = harness.store
        // Removable, blocked by an inbound link, and blocked as source evidence.
        #expect(store.removalBlocker(forTransaction: "tx-refund") == nil)
        #expect(store.removalBlocker(forTransaction: "tx-expense") == .linkedFromAnotherTransaction)
        #expect(store.removalBlocker(forTransaction: "tx-statement") == .sourceEvidence)

        for scheme in [ColorScheme.light, .dark] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                for id in ["tx-refund", "tx-expense", "tx-statement"] {
                    let view = TransactionDetailView(
                        row: try row(store, id: id),
                        date: DomainMapper.civilDay(RemovalFixtures.today)
                    )
                    #expect(
                        RenderCheck.image(
                            NavigationStack { view },
                            store: store, scheme: scheme, typeSize: size
                        ) != nil
                    )
                }
            }
        }
    }
}
