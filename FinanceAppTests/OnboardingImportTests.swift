import Testing
import Foundation
import SwiftData
import SwiftUI
import FinanceCore
@testable import FinanceApp

// MARK: - A current-state export, in the shape a real one has

/// A document shaped like the export the app is being built to accept: several
/// accounts with balances observed on different days, euro liquidity separate
/// from pocket cash, a guaranteed arrival that has not happened, commitments
/// that are and are not committed, and an arrear with no agreed schedule.
///
/// The figures are structural, not financial evidence. They exist to prove the
/// import path keeps distinctions that matter, and nothing here ships.
enum CurrentStateExport {

    static let today = Day(year: 2026, month: 8, day: 28)
    static let todayCivil = DomainMapper.civilDay(today)
    static let todayDate = fixtureInstant(today)

    /// A string that appears in the document's free text. Nothing the import
    /// path says about a rejected file may contain it.
    static let privateMarker = "counterparty-Q7X-marker"

    static let accounts: [Account] = [
        Account(id: "revolut-eur", name: "Revolut", currency: .eur, kind: .wallet,
                supportedRails: PaymentRail.euroWalletRails, drawOrder: 0),
        Account(id: "bank-main", name: "BNP", currency: .eur, kind: .bank,
                supportedRails: PaymentRail.euroBankRails, drawOrder: 1),
        Account(id: "paypal-eur", name: "PayPal", currency: .eur, kind: .wallet,
                supportedRails: PaymentRail.euroWalletRails, drawOrder: 2),
        Account(id: "cash-eur", name: "Cash", currency: .eur, kind: .cash,
                supportedRails: PaymentRail.cashOnlyRails, drawOrder: 3),
        Account(id: "cash-mad", name: "Cash MAD", currency: Currency(code: "MAD"), kind: .cash,
                supportedRails: PaymentRail.cashOnlyRails, drawOrder: 4)
    ]

    /// Observed on three different days. Two are stale on `today`.
    static let balances: [AccountBalance] = [
        AccountBalance(accountID: "revolut-eur", balance: Money(minorUnits: 9_600, currency: .eur),
                       asOf: Day(year: 2026, month: 8, day: 17), status: .observed),
        AccountBalance(accountID: "bank-main", balance: Money(minorUnits: 30_000, currency: .eur),
                       asOf: Day(year: 2026, month: 8, day: 20), status: .observed),
        AccountBalance(accountID: "paypal-eur", balance: Money(minorUnits: 0, currency: .eur),
                       asOf: today, status: .observed),
        AccountBalance(accountID: "cash-eur", balance: Money(minorUnits: 1_500, currency: .eur),
                       asOf: today, status: .observed),
        AccountBalance(accountID: "cash-mad", balance: Money(minorUnits: 20_000, currency: Currency(code: "MAD")),
                       asOf: Day(year: 2026, month: 8, day: 10), status: .observed)
    ]

    /// €377.60 — current euro that can settle a euro obligation after the
    /// 17 August Revolut observation plus the 26 August grocery. Pocket cash
    /// is deliberately not in it.
    static let expectedElectronicLiquidity = Amount(minorUnits: 37_760, currencyCode: "EUR")

    static func document(
        schemaVersion: String = Interchange.currentSchemaVersion,
        balances: [AccountBalance] = CurrentStateExport.balances
    ) -> FinanceDocument {
        FinanceDocument(
            schemaVersion: schemaVersion,
            documentKind: "CURRENT-STATE-EXPORT-2026-08-28",
            note: "Reconstructed state, \(privateMarker).",
            accounts: accounts,
            balances: balances,
            transactions: [
                Transaction(
                    id: "tx-groceries", date: Day(year: 2026, month: 8, day: 26), kind: .expense,
                    legs: [AccountLeg(accountID: "revolut-eur", amount: Money(minorUnits: -1_840, currency: .eur))],
                    factivity: .observed, lifecycle: .cleared,
                    note: privateMarker,
                    provenance: Provenance(source: "STATEMENT", evidenceGrade: .primarySource)
                )
            ],
            expectedTransactions: [
                Transaction(
                    id: "etx-flight", date: Day(year: 2026, month: 9, day: 10), kind: .expense,
                    legs: [AccountLeg(accountID: "bank-main", amount: Money(minorUnits: -5_125, currency: .eur))],
                    factivity: .expected, lifecycle: .pending,
                    provenance: Provenance(source: "STATEMENT", evidenceGrade: .userConfirmed)
                )
            ],
            incomeSources: [
                IncomeSource(
                    id: "inc-parents", name: "Parents",
                    amount: Money(minorUnits: 80_000, currency: .eur),
                    certainty: .guaranteed,
                    schedule: .oneShot(on: Day(year: 2026, month: 9, day: 16)),
                    arrivesOnAccount: "bank-main",
                    note: "Committed for 16 September. Not received yet."
                )
            ],
            installments: [
                InstallmentPlan(
                    id: "ip-phone", provider: "PayPal Pay-in-4",
                    purchaseDescription: "Phone",
                    purchaseDate: Day(year: 2026, month: 7, day: 2),
                    originalPurchaseAmount: Money(minorUnits: 32_488, currency: .eur),
                    installments: (0..<4).map { index in
                        Installment(
                            sequence: index,
                            dueDate: Day(year: 2026, month: 7 + index, day: 2),
                            amount: Money(minorUnits: 8_122, currency: .eur),
                            status: index < 2 ? .paid : .scheduled
                        )
                    },
                    paymentRequirement: PaymentRequirement(currency: .eur, acceptableRails: PaymentRail.euroWalletRails)
                ),
                InstallmentPlan(
                    id: "ip-cancelled", provider: "Klarna",
                    purchaseDescription: "Returned jacket",
                    originalPurchaseAmount: Money(minorUnits: 12_000, currency: .eur),
                    installments: [
                        Installment(sequence: 0, dueDate: Day(year: 2026, month: 9, day: 1),
                                    amount: Money(minorUnits: 4_000, currency: .eur), status: .cancelled)
                    ],
                    paymentRequirement: PaymentRequirement(currency: .eur, acceptableRails: PaymentRail.euroWalletRails),
                    status: .cancelled
                )
            ],
            debts: [
                // Owed, acknowledged, and committing no dated payment: there is
                // no agreement, so there is no schedule to invent.
                Debt(
                    id: "debt-arrears", name: "Rent arrears",
                    note: "No repayment agreement yet.",
                    originalAmount: Money(minorUnits: 96_000, currency: .eur),
                    paymentSchedule: [],
                    paymentRequirement: PaymentRequirement(currency: .eur, acceptableRails: [.sepaCreditTransfer])
                )
            ],
            planning: FinanceDocument.Planning(
                defaultScenario: .base,
                safetyFloor: Money(minorUnits: 5_000, currency: .eur),
                budgets: [
                    BudgetAllocation(
                        id: "bud-food", name: "Food", spendingClass: .essential,
                        monthlyAmount: Money(minorUnits: 12_000, currency: .eur),
                        effectiveFrom: MonthKey(year: 2026, month: 8)
                    )
                ],
                recurringObligations: [
                    RecurringObligation(
                        id: "ob-rent", name: "Rent",
                        amount: Money(minorUnits: 48_000, currency: .eur),
                        spec: .monthly(onDay: 5, from: MonthKey(year: 2026, month: 9), through: nil),
                        requirement: PaymentRequirement(currency: .eur, acceptableRails: [.sepaDirectDebit]),
                        spendingClass: .essential
                    ),
                    RecurringObligation(
                        id: "ob-insurance", name: "Insurance",
                        amount: Money(minorUnits: 613, currency: .eur),
                        spec: .monthly(onDay: 8, from: MonthKey(year: 2026, month: 9), through: nil),
                        requirement: PaymentRequirement(currency: .eur, acceptableRails: [.sepaDirectDebit]),
                        spendingClass: .essential
                    ),
                    // A what-if. It must never charge cash.
                    RecurringObligation(
                        id: "ob-proposed-gym", name: "Gym (proposed)",
                        amount: Money(minorUnits: 2_990, currency: .eur),
                        spec: .monthly(onDay: 12, from: MonthKey(year: 2026, month: 9), through: nil),
                        requirement: PaymentRequirement(currency: .eur, acceptableRails: [.cardDebit]),
                        spendingClass: .optional,
                        commitmentStatus: .hypothetical
                    )
                ],
                carriedEURValues: ["cash-mad": Money(minorUnits: 1_842, currency: .eur)]
            )
        )
    }

    static func data(_ document: FinanceDocument = CurrentStateExport.document()) throws -> Data {
        try Interchange.encode(document)
    }

    /// The encoded document with one JSON value replaced, for the malformed
    /// cases the domain types refuse to construct at all.
    static func mutatedJSON(
        _ mutate: (inout [String: Any]) -> Void,
        of document: FinanceDocument = CurrentStateExport.document()
    ) throws -> Data {
        var object = try #require(
            JSONSerialization.jsonObject(with: try data(document)) as? [String: Any]
        )
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: Stores

    /// A container has to outlive the context it hands out, so both travel
    /// together.
    struct Harness {
        let container: ModelContainer
        let store: FinanceStore
    }

    @MainActor
    static func harness(writer: DocumentWriter = .live) throws -> Harness {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return Harness(
            container: container,
            store: try FinanceStore(context: container.mainContext, now: todayDate, writer: writer)
        )
    }

    @MainActor
    static func reopened(_ harness: Harness) throws -> FinanceStore {
        try FinanceStore(context: harness.container.mainContext, now: todayDate)
    }
}

// MARK: - First launch

@MainActor
@Suite("A fresh install offers two ways in and no data")
struct FirstLaunchTests {

    @Test("An untouched store is empty and may be imported into")
    func emptyStoreAcceptsImport() throws {
        let harness = try CurrentStateExport.harness()

        #expect(harness.store.isEmpty)
        #expect(harness.store.storeIsUnreadable == false)
        #expect(harness.store.canImportCurrentState)
        #expect(harness.store.importBlocker == nil)
        // No fixture, no sample history.
        #expect(harness.store.snapshot.accounts.isEmpty)
        #expect(harness.store.snapshot.activity.isEmpty)
    }

    @Test("First launch renders the two choices, light and dark, at any type size")
    func onboardingRenders() throws {
        let harness = try CurrentStateExport.harness()
        for scheme in [ColorScheme.light, .dark] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                #expect(
                    RenderCheck.image(
                        NavigationStack {
                            ScrollView { OnboardingView().padding() }
                        },
                        store: harness.store,
                        scheme: scheme,
                        typeSize: size
                    ) != nil
                )
            }
        }
    }

    @Test("Manual setup still reaches the Phase 2.1 account editor")
    func manualSetupUsesTheAccountEditor() throws {
        let harness = try CurrentStateExport.harness()
        #expect(RenderCheck.image(NavigationStack { AccountEditorView() }, store: harness.store) != nil)

        // The manual path is add-account, and it persists through the same
        // facade the editor already used.
        try harness.store.saveAccount(
            AccountDraft(
                id: nil, name: "BNP", kind: .bank, currencyCode: "EUR", fractionDigits: 2,
                openingBalance: .eur(120), openingBalanceDay: CurrentStateExport.todayCivil,
                isActive: true
            )
        )
        #expect(harness.store.snapshot.accounts.count == 1)
        #expect(harness.store.isEmpty == false)
    }

    @Test("A store that could not be read is not treated as a fresh install")
    func unreadableStoreDoesNotOfferImport() throws {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        // A document meta row this build's schema list does not contain: the
        // store opens read-only rather than pretending to be empty.
        let context = container.mainContext
        try StoredDocumentGraph.replace(
            with: CurrentStateExport.document(),
            in: context,
            writtenOn: CurrentStateExport.today
        )
        let meta = try #require(try context.fetch(FetchDescriptor<StoredDocumentMeta>()).first)
        meta.schemaVersion = "9.9.9"
        try context.save()

        let store = try FinanceStore(context: context, now: CurrentStateExport.todayDate)
        #expect(store.storeIsUnreadable)
        #expect(store.canImportCurrentState == false)
        #expect(store.importBlocker == .storeUnreadable)
        #expect(RenderCheck.image(ScrollView { UnreadableStoreView() }, store: store) != nil)
    }
}

// MARK: - Importing

@MainActor
@Suite("Import current state")
struct ImportCurrentStateTests {

    @Test("A valid export imports, and survives reopening the store")
    func validDocumentImports() throws {
        let harness = try CurrentStateExport.harness()

        let preview = try harness.store.prepareImport(from: try CurrentStateExport.data())
        // Previewing writes nothing.
        #expect(harness.store.isEmpty)
        #expect(preview.accounts.count == 5)

        let summary = try harness.store.confirmImport()
        #expect(summary.accountCount == 5)
        #expect(harness.store.isEmpty == false)

        let reopened = try CurrentStateExport.reopened(harness)
        #expect(reopened.storeIsUnreadable == false)
        #expect(reopened.snapshot.accounts.count == 5)
        #expect(reopened.snapshot.accountCash == CurrentStateExport.expectedElectronicLiquidity)
        #expect(reopened.snapshot.debts.count == 1)
        #expect(reopened.snapshot.commitments.flatMap(\.lines).count == 3)
        #expect(reopened.snapshot.safetyReserve == Amount(minorUnits: 5_000, currencyCode: "EUR"))
    }

    @Test("An export written to another schema version is refused")
    func unsupportedSchemaIsRefused() throws {
        let harness = try CurrentStateExport.harness()
        // 2.0.0 is readable now, so the refusal has to be proved against a
        // version this build genuinely does not know.
        let data = try CurrentStateExport.mutatedJSON { $0["schemaVersion"] = "9.9.9" }

        do {
            _ = try harness.store.prepareImport(from: data)
            Issue.record("a 9.9.9 document must not import")
        } catch let error as AppImportError {
            #expect(error == .unsupportedSchemaVersion(found: "9.9.9", supported: PersistedSchema.supported))
        }
        #expect(harness.store.isEmpty)
        #expect(harness.store.pendingImportPreview == nil)
    }

    @Test("Bytes that are not a finance document are refused")
    func nonDocumentIsRefused() throws {
        let harness = try CurrentStateExport.harness()

        do {
            _ = try harness.store.prepareImport(from: Data("not json at all".utf8))
            Issue.record("arbitrary bytes must not import")
        } catch let error as AppImportError {
            guard case .notAFinanceDocument = error else {
                Issue.record("expected a decode refusal, got \(error)")
                return
            }
        }
        #expect(harness.store.isEmpty)
    }

    @Test("Ownership shares that do not add up are refused at the door")
    func malformedOwnershipIsRefused() throws {
        let harness = try CurrentStateExport.harness()

        // €1,000 arrives; the shares claim €1,100 of it. The domain type traps
        // on this, so it can only be written as JSON.
        let data = try CurrentStateExport.mutatedJSON { object in
            var expected = object["expectedTransactions"] as! [[String: Any]]
            expected.append([
                "id": "etx-family-transfer",
                "date": "2026-09-16",
                "kind": "passThrough",
                "legs": [["accountID": "bank-main", "amount": "1000.00 EUR"]],
                "ownership": [
                    ["ownerID": "self", "isSelf": true, "amount": "600.00 EUR"],
                    ["ownerID": "co-resident", "isSelf": false, "amount": "500.00 EUR"]
                ],
                "factivity": "expected",
                "provenance": ["source": "STATEMENT", "evidenceGrade": "derived"]
            ])
            object["expectedTransactions"] = expected
        }

        do {
            _ = try harness.store.prepareImport(from: data)
            Issue.record("an over-allocated ownership split must not import")
        } catch let error as AppImportError {
            guard case let .notAFinanceDocument(field, reason) = error else {
                Issue.record("expected a decode refusal, got \(error)")
                return
            }
            #expect(reason == .unreadableValue)
            #expect(field?.contains("expectedTransactions") == true)
            // The core's own message quotes both money figures. Ours may not.
            #expect(!error.message.contains("900"))
            #expect(!error.message.contains("1600"))
        }
        #expect(harness.store.isEmpty)
    }

    @Test("Two balances for one account are refused rather than silently halved")
    func duplicateBalanceIsRefused() throws {
        let harness = try CurrentStateExport.harness()
        let doubled = CurrentStateExport.balances + [
            AccountBalance(
                accountID: "bank-main",
                balance: Money(minorUnits: 9_999, currency: .eur),
                asOf: CurrentStateExport.today,
                status: .observed
            )
        ]
        let data = try CurrentStateExport.data(CurrentStateExport.document(balances: doubled))

        do {
            _ = try harness.store.prepareImport(from: data)
            Issue.record("two balances for one account must not import")
        } catch let error as AppImportError {
            #expect(error == .inconsistentDocument(.duplicateBalance(accountID: "bank-main")))
        }
        #expect(harness.store.isEmpty)
        #expect(harness.store.snapshot.accounts.isEmpty)
    }

    @Test("A balance for an account the export does not contain is refused")
    func orphanBalanceIsRefused() throws {
        let harness = try CurrentStateExport.harness()
        let orphaned = CurrentStateExport.balances + [
            AccountBalance(
                accountID: "ghost-account",
                balance: Money(minorUnits: 100, currency: .eur),
                asOf: CurrentStateExport.today,
                status: .observed
            )
        ]
        let data = try CurrentStateExport.data(CurrentStateExport.document(balances: orphaned))

        do {
            _ = try harness.store.prepareImport(from: data)
            Issue.record("a balance with no account must not import")
        } catch let error as AppImportError {
            #expect(error == .inconsistentDocument(.balanceForUnknownAccount(accountID: "ghost-account")))
        }
    }

    @Test("An import into a store that already has history is refused")
    func nonEmptyStoreBlocksImport() throws {
        let harness = try CurrentStateExport.harness()
        try harness.store.prepareImport(from: try CurrentStateExport.data())
        try harness.store.confirmImport()
        #expect(harness.store.isEmpty == false)

        // Same store, and a store reopened on the same container: both refuse.
        for store in [harness.store, try CurrentStateExport.reopened(harness)] {
            #expect(store.canImportCurrentState == false)
            #expect(store.importBlocker == .storeNotEmpty)
            do {
                _ = try store.prepareImport(from: try CurrentStateExport.data())
                Issue.record("a second import must not be accepted")
            } catch let error as AppImportError {
                #expect(error == .storeNotEmpty)
                #expect(error.message == "Import into an existing account history is not supported yet.")
            }
        }
        // Nothing was duplicated.
        #expect(harness.store.snapshot.accounts.count == 5)
    }

    @Test("A single manually added account is enough to block an import")
    func anyExistingDataBlocksImport() throws {
        let harness = try CurrentStateExport.harness()
        try harness.store.saveAccount(
            AccountDraft(
                id: nil, name: "BNP", kind: .bank, currencyCode: "EUR", fractionDigits: 2,
                openingBalance: .eur(10), openingBalanceDay: CurrentStateExport.todayCivil,
                isActive: true
            )
        )
        #expect(harness.store.importBlocker == .storeNotEmpty)
    }

    @Test("Cancelling a review forgets the staged document")
    func cancelDiscardsTheStagedDocument() throws {
        let harness = try CurrentStateExport.harness()
        try harness.store.prepareImport(from: try CurrentStateExport.data())
        #expect(harness.store.pendingImportPreview != nil)

        harness.store.cancelImport()
        #expect(harness.store.pendingImportPreview == nil)
        #expect(harness.store.isEmpty)

        do {
            _ = try harness.store.confirmImport()
            Issue.record("confirming with nothing staged must not import")
        } catch let error as AppImportError {
            #expect(error == .noDocumentStaged)
        }
    }
}

// MARK: - Atomicity

@MainActor
@Suite("An import lands whole or not at all")
struct ImportAtomicityTests {

    /// A writer that fails the way a real one can: after the graph it was
    /// replacing has already been torn down, and before the replacement is
    /// committed. Nothing else can produce that state on demand.
    private static func failingWriter() -> DocumentWriter {
        DocumentWriter { _, context, _, _, _ in
            try context.fetch(FetchDescriptor<StoredAccount>()).forEach(context.delete)
            try context.fetch(FetchDescriptor<StoredAccountBalance>()).forEach(context.delete)
            try context.fetch(FetchDescriptor<StoredDocumentMeta>()).forEach(context.delete)
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    @Test("A write that fails leaves an empty store empty")
    func failedImportLeavesNothingBehind() throws {
        let harness = try CurrentStateExport.harness(writer: Self.failingWriter())
        try harness.store.prepareImport(from: try CurrentStateExport.data())

        do {
            _ = try harness.store.confirmImport()
            Issue.record("a failing write must not report success")
        } catch let error as AppImportError {
            guard case .persistenceFailed = error else {
                Issue.record("expected a persistence refusal, got \(error)")
                return
            }
            // The reason names the failure type, never a row the write choked on.
            #expect(!error.message.contains(CurrentStateExport.privateMarker))
        }

        #expect(harness.store.isEmpty)
        #expect(harness.store.snapshot.accounts.isEmpty)
        // Nothing partial reached disk either.
        #expect(try CurrentStateExport.reopened(harness).snapshot.accounts.isEmpty)
    }

    @Test("A write that fails does not destroy the data it was replacing")
    func failedImportPreservesExistingData() throws {
        let harness = try CurrentStateExport.harness()
        try harness.store.prepareImport(from: try CurrentStateExport.data())
        try harness.store.confirmImport()
        #expect(harness.store.snapshot.accounts.count == 5)

        // A second store on the same container, whose write fails mid-replace.
        let failing = try FinanceStore(
            context: harness.container.mainContext,
            now: CurrentStateExport.todayDate,
            writer: Self.failingWriter()
        )
        #expect(failing.snapshot.accounts.count == 5)

        var replacement = CurrentStateExport.document()
        replacement.accounts = Array(replacement.accounts.prefix(1))
        replacement.balances = Array(replacement.balances.filter { $0.accountID == "revolut-eur" })
        replacement.transactions = []
        replacement.expectedTransactions = []
        replacement.installments = []
        replacement.planning.carriedEURValues = [:]

        #expect(throws: (any Error).self) { try failing.importDocument(replacement) }

        // The in-memory document did not move, and neither did the store.
        #expect(failing.snapshot.accounts.count == 5)
        #expect(try CurrentStateExport.reopened(harness).snapshot.accounts.count == 5)
        #expect(try CurrentStateExport.reopened(harness).snapshot.accountCash
                == CurrentStateExport.expectedElectronicLiquidity)
    }
}

// MARK: - Balance freshness

@MainActor
@Suite("A balance is shown with the day it was observed")
struct BalanceFreshnessTests {

    @Test("Stale balances are marked, and dated ones say when")
    func staleBalancesAreDated() throws {
        let harness = try CurrentStateExport.harness()
        let preview = try harness.store.prepareImport(from: try CurrentStateExport.data())

        #expect(preview.hasStaleBalances)
        #expect(preview.staleAccounts.count == 3)

        let bnp = try #require(preview.accounts.first { $0.id == "bank-main" })
        #expect(bnp.freshness == .daysOld(8))
        #expect(bnp.asOf == CalendarDay(year: 2026, month: 8, day: 20))

        let paypal = try #require(preview.accounts.first { $0.id == "paypal-eur" })
        #expect(paypal.freshness == .today)
        #expect(paypal.freshness.isStale == false)
    }

    @Test("A dated balance is never labelled a current one")
    func staleBalanceIsNotCalledCurrent() throws {
        let harness = try CurrentStateExport.harness()
        let preview = try harness.store.prepareImport(from: try CurrentStateExport.data())

        for account in preview.accounts {
            let caption = ImportBalanceRow.caption(for: account)
            #expect(!caption.localizedCaseInsensitiveContains("current balance"))
            #expect(caption.hasPrefix("As of"))
        }

        let revolut = try #require(preview.accounts.first { $0.id == "revolut-eur" })
        let caption = ImportBalanceRow.caption(for: revolut)
        // The day the figure was observed, spoken on the row itself.
        #expect(caption.contains("17"))
        #expect(caption != "As of today")

        // And it reaches VoiceOver as one statement, figure and date together.
        let spoken = ImportBalanceRow(account: revolut).accessibilityLabel
        #expect(spoken.contains(caption))
        #expect(spoken.contains(revolut.balance.accessibleDescription()))
    }

    @Test("A balance corrected during review is what gets persisted")
    func correctedBalanceIsPersisted() throws {
        let harness = try CurrentStateExport.harness()
        let preview = try harness.store.prepareImport(from: try CurrentStateExport.data())
        let bnp = try #require(preview.accounts.first { $0.id == "bank-main" })
        #expect(bnp.balance == .eur(300.00))

        let summary = try harness.store.confirmImport(
            balanceCorrections: [
                ImportBalanceCorrection(
                    accountID: "bank-main",
                    balance: .eur(300),
                    asOf: CalendarDay(year: 2026, month: 8, day: 28)
                )
            ]
        )

        let account = try #require(harness.store.snapshot.accounts.first { $0.id == "bank-main" })
        #expect(account.balance == .eur(300))
        #expect(account.balanceAsOf == CalendarDay(year: 2026, month: 8, day: 28))
        // Stored Revolut observation is unchanged; displayed current replays
        // the later grocery against that inclusive-through-day anchor.
        let revolut = try #require(harness.store.snapshot.accounts.first { $0.id == "revolut-eur" })
        #expect(revolut.balance == .eur(77.60))
        let storedRevolut = try #require(
            harness.store.exportDocument().balances.first { $0.accountID == "revolut-eur" }
        )
        #expect(storedRevolut.balance.minorUnits == 9_600)
        #expect(storedRevolut.asOf == Day(year: 2026, month: 8, day: 17))
        // Displayed: €300.00 + €77.60 + €0.00
        #expect(summary.electronicLiquidity == .eur(377.60))
        #expect(harness.store.snapshot.accountCash == .eur(377.60))
    }

    @Test("Every step of the flow renders in both schemes at accessibility sizes")
    func importScreensRender() throws {
        let harness = try CurrentStateExport.harness()
        let preview = try harness.store.prepareImport(from: try CurrentStateExport.data())
        var edits = Dictionary(
            uniqueKeysWithValues: preview.accounts.map { ($0.id, BalanceEdit($0)) }
        )
        let summary = ImportSummary(
            accountCount: 5, recurringCommitmentCount: 3, incomeSourceCount: 1,
            installmentCount: 2, expectedTransactionCount: 1, observedTransactionCount: 1,
            debtOutstanding: .eur(960.00),
            electronicLiquidity: CurrentStateExport.expectedElectronicLiquidity,
            physicalCash: preview.physicalCash
        )

        for scheme in [ColorScheme.light, .dark] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                func renders(_ view: some View) -> Bool {
                    RenderCheck.image(
                        NavigationStack { view },
                        store: harness.store, scheme: scheme, typeSize: size
                    ) != nil
                }
                // The picker state, including the refusal it shows when the
                // store already holds a history.
                #expect(renders(ChooseFileStep(blocker: nil) {}))
                #expect(renders(ChooseFileStep(blocker: .storeNotEmpty) {}))
                // The preview, the stale-balance review, and the confirmation.
                #expect(renders(PreviewStep(preview: preview) {}))
                #expect(
                    renders(
                        BalanceReviewStep(
                            preview: preview,
                            edits: Binding(get: { edits }, set: { edits = $0 }),
                            onConfirm: {}
                        )
                    )
                )
                #expect(renders(ImportResultStep(summary: summary) {}))
                #expect(renders(DataAndBackupView()))
            }
        }

        // And Home, once there is something real behind it.
        try harness.store.confirmImport()
        #expect(RenderCheck.image(HomeView(), store: harness.store, scheme: .dark) != nil)
        #expect(RenderCheck.image(HomeView(), store: harness.store, typeSize: .accessibility3) != nil)
    }
}

// MARK: - What the imported plan is allowed to claim

@MainActor
@Suite("The imported plan keeps the distinctions the export made")
struct ImportedPlanClaimTests {

    private func imported() throws -> FinanceStore {
        let harness = try CurrentStateExport.harness()
        try harness.store.prepareImport(from: try CurrentStateExport.data())
        try harness.store.confirmImport()
        return harness.store
    }

    @Test("Pocket cash is listed apart from the money that can pay a bill")
    func physicalCashIsSeparate() throws {
        let store = try imported()
        let snapshot = store.snapshot

        #expect(snapshot.accountCash == CurrentStateExport.expectedElectronicLiquidity)

        // Both pockets are listed; neither is in the headline.
        let currencies = Set(snapshot.physicalCash.map(\.balance.currencyCode))
        #expect(currencies == ["EUR", "MAD"])
        #expect(snapshot.physicalCash.allSatisfy { !$0.isSpendableHere })

        let euroAccounts: Amount = snapshot.trackedHoldings
            .filter(\.isSpendableHere)
            .reduce(Amount.zeroEUR) { $0 + $1.balance }
        #expect(snapshot.accountCash == euroAccounts)
        // €15 of euro notes exists and is deliberately not in the €377.60.
        #expect(snapshot.trackedHoldings.contains { $0.id == "cash-eur" && $0.balance == .eur(15) })
        #expect(snapshot.accountCash.minorUnits == 37_760)
    }

    @Test("Guaranteed support is still money that has not arrived")
    func guaranteedIncomeIsNotABalance() throws {
        let store = try imported()
        let arrival = try #require(
            store.snapshot.upcomingEvents.first { $0.isInflow }
        )

        #expect(arrival.isGuaranteedButNotReceived)
        #expect(arrival.certaintyLabel == nil)
        #expect(UpcomingRow(event: arrival).accessibilityLabel.contains("not received yet"))

        // It is a promise, so it is not in the money on hand.
        #expect(store.snapshot.accountCash == CurrentStateExport.expectedElectronicLiquidity)
        #expect(!store.snapshot.activity.flatMap(\.rows).contains { $0.amount.magnitude == .eur(800) })
    }

    @Test("Cancelled and hypothetical commitments do not charge cash")
    func cancelledCommitmentsAreNotActive() throws {
        let store = try imported()

        // A cancelled instalment plan is not a live plan.
        #expect(!store.snapshot.instalments.contains { $0.id == "ip-cancelled" })
        #expect(store.snapshot.instalments.map(\.id) == ["ip-phone"])

        let lines = store.snapshot.commitments.flatMap(\.lines)
        let gym = try #require(lines.first { $0.id == "ob-proposed-gym" })
        #expect(gym.chargesCashNow == false)
        #expect(gym.statusLabel == "Hypothetical")

        let rent = try #require(lines.first { $0.id == "ob-rent" })
        #expect(rent.chargesCashNow)
        #expect(rent.statusLabel == nil)

        // And the hypothetical one never lands as a dated obligation.
        #expect(!store.snapshot.monthProjections.flatMap(\.events).contains {
            $0.label.localizedCaseInsensitiveContains("Gym")
        })
    }

    @Test("An arrear with no agreed schedule imports, owing everything and committing nothing")
    func debtWithEmptyScheduleImports() throws {
        let store = try imported()

        let debt = try #require(store.snapshot.debts.first { $0.id == "debt-arrears" })
        #expect(debt.outstanding == .eur(960.00))
        // No agreement, so no monthly figure and no clearing date is invented.
        #expect(debt.monthlyRepayment.isZero)
        #expect(debt.monthsToClear == nil)

        // And nothing in the projection pretends a payment is due.
        #expect(!store.snapshot.upcomingEvents.contains { $0.isRecovery })
    }

    @Test("Home is correct on the next frame, with no relaunch")
    func homeRecalculatesImmediately() throws {
        let harness = try CurrentStateExport.harness()
        #expect(harness.store.snapshot.accounts.isEmpty)
        #expect(harness.store.snapshot.accountCash.isZero)
        #expect(harness.store.snapshot.horizonDays == 120)

        try harness.store.prepareImport(from: try CurrentStateExport.data())
        // Still nothing: previewing is not importing.
        #expect(harness.store.snapshot.accounts.isEmpty)

        try harness.store.confirmImport()

        // The same store instance, without reloading anything.
        let snapshot = harness.store.snapshot
        #expect(snapshot.accounts.count == 5)
        #expect(snapshot.accountCash == CurrentStateExport.expectedElectronicLiquidity)
        #expect(!snapshot.physicalCash.isEmpty)
        #expect(!snapshot.upcomingEvents.isEmpty)
        #expect(!snapshot.monthProjections.isEmpty)
        #expect(snapshot.runwayPoints.isEmpty == false)
        // Rent lands on 5 September against €377.60, so the plan has a risk to
        // name — the projection is real, not a zeroed placeholder.
        #expect(snapshot.firstRisk != nil || snapshot.lowestPoint.projectedBalance.minorUnits < 37_760)
        #expect(RenderCheck.image(HomeView(), store: harness.store) != nil)
    }

    @Test("What the preview promised is what the store holds")
    func previewMatchesPersistedResult() throws {
        let harness = try CurrentStateExport.harness()
        let preview = try harness.store.prepareImport(from: try CurrentStateExport.data())
        let summary = try harness.store.confirmImport()
        let snapshot = harness.store.snapshot

        #expect(preview.accounts.count == summary.accountCount)
        #expect(preview.accounts.count == snapshot.accounts.count)
        #expect(preview.electronicLiquidity == summary.electronicLiquidity)
        #expect(preview.electronicLiquidity == snapshot.accountCash)
        #expect(preview.physicalCash == summary.physicalCash)

        let previewedPockets: [Amount] = preview.physicalCash
            .map(\.amount)
            .sorted { $0.currencyCode < $1.currencyCode }
        let storedPockets: [Amount] = snapshot.physicalCash
            .map(\.balance)
            .sorted { $0.currencyCode < $1.currencyCode }
        #expect(previewedPockets == storedPockets)

        #expect(preview.debtOutstanding == summary.debtOutstanding)
        let storedDebt: Amount = snapshot.debts.reduce(Amount.zeroEUR) { $0 + $1.outstanding }
        #expect(preview.debtOutstanding == storedDebt)

        #expect(preview.incomeSourceCount == snapshot.incomeSources.count)
        #expect(preview.installmentCount == snapshot.instalments.count)
        let chargingLines: Int = snapshot.commitments
            .flatMap(\.lines)
            .filter(\.chargesCashNow)
            .count
        #expect(preview.recurringCommitmentCount == chargingLines)
        #expect(summary.expectedTransactionCount == preview.expectedTransactionCount)

        // Import rows are the stored observed anchors; Home rows are derived
        // current holdings. Headline liquidity is the derived figure both ways.
        let exported = try harness.store.exportDocument()
        for account in preview.accounts {
            let stored = try #require(exported.balances.first { $0.accountID == account.id })
            #expect(account.balance.minorUnits == stored.balance.minorUnits)
            #expect(account.asOf == DomainMapper.civilDay(stored.asOf))
        }
    }
}

// MARK: - Privacy

@MainActor
@Suite("A rejected file says nothing about what was in it")
struct ImportPrivacyTests {

    @Test("A malformed value is reported by field, never by value")
    func rejectionNamesTheFieldNotTheValue() throws {
        let harness = try CurrentStateExport.harness()
        let secret = "9182.73"
        let data = try CurrentStateExport.mutatedJSON { object in
            var balances = object["balances"] as! [[String: Any]]
            balances[0]["balance"] = "\(secret) NOTACURRENCY EUR"
            object["balances"] = balances
        }

        do {
            _ = try harness.store.prepareImport(from: data)
            Issue.record("a malformed money value must not import")
        } catch let error as AppImportError {
            guard case let .notAFinanceDocument(field, reason) = error else {
                Issue.record("expected a decode refusal, got \(error)")
                return
            }
            #expect(reason == .unreadableValue)
            // Structure is named…
            #expect(field?.contains("balances") == true)
            // …and content is not. The core's own message quotes the string.
            #expect(!error.message.contains(secret))
            #expect(!"\(error)".contains(secret))
        }
    }

    @Test("A semantic refusal names records by identifier, never by amount")
    func semanticRefusalCarriesNoFigures() throws {
        let harness = try CurrentStateExport.harness()
        let doubled = CurrentStateExport.balances + [
            AccountBalance(
                accountID: "bank-main",
                balance: Money(minorUnits: 9_999, currency: .eur),
                asOf: CurrentStateExport.today, status: .observed
            )
        ]
        let data = try CurrentStateExport.data(CurrentStateExport.document(balances: doubled))

        do {
            _ = try harness.store.prepareImport(from: data)
            Issue.record("a duplicate balance must not import")
        } catch let error as AppImportError {
            #expect(error.message.contains("bank-main"))
            #expect(!error.message.contains("99.99"))
            #expect(!error.message.contains("300.00"))
            #expect(!error.message.contains(CurrentStateExport.privateMarker))
        }
    }

    @Test("No error message this path can produce quotes the document")
    func noImportErrorLeaksDocumentContent() throws {
        // Every case, including the ones a person is most likely to see.
        let errors: [AppImportError] = [
            .storeIsReadOnly, .storeNotEmpty, .storeUnreadable, .fileUnreadable,
            .noDocumentStaged,
            .notAFinanceDocument(field: "balances[0].balance", reason: .unreadableValue),
            .unsupportedSchemaVersion(found: "2.0.0", supported: ["1.1.0"]),
            .inconsistentDocument(.duplicateBalance(accountID: "bank-main")),
            .persistenceFailed("CocoaError")
        ]
        for error in errors {
            #expect(!error.message.contains(CurrentStateExport.privateMarker))
            #expect(!error.message.contains("960.00"))
            #expect(!error.message.contains("396.00"))
        }
    }

    @Test("Importing keeps no second copy of the file")
    func noRawDocumentIsRetained() throws {
        let harness = try CurrentStateExport.harness()
        try harness.store.prepareImport(from: try CurrentStateExport.data())
        try harness.store.confirmImport()

        // The staged document is released once it is persisted.
        #expect(harness.store.pendingImportPreview == nil)

        // What was stored is the normalized graph, not a blob of the file. The
        // document meta row keeps provenance, and nothing keeps the bytes.
        let context = harness.container.mainContext
        let meta = try #require(try context.fetch(FetchDescriptor<StoredDocumentMeta>()).first)
        #expect(meta.documentKind == "CURRENT-STATE-EXPORT-2026-08-28")
        #expect(try context.fetch(FetchDescriptor<StoredAccount>()).count == 5)
    }
}

// MARK: - The boundary, still

@Suite("SwiftUI does not learn about FinanceCore")
struct ImportBoundaryTests {

    /// The product source tree, found from this file's own compiled-in path.
    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)      // …/FinanceAppTests/OnboardingImportTests.swift
            .deletingLastPathComponent()     // …/FinanceAppTests
            .deletingLastPathComponent()     // …/finance-app
            .appendingPathComponent("FinanceApp")
    }

    @Test("No screen, component or surface type imports the engine")
    func noSwiftUILayerImportsFinanceCore() throws {
        let manager = FileManager.default
        #expect(manager.fileExists(atPath: Self.sourceRoot.path))

        var offenders: [String] = []
        var scanned = 0
        for layer in ["App", "Components", "Features", "Surface"] {
            let directory = Self.sourceRoot.appendingPathComponent(layer)
            let enumerator = try #require(manager.enumerator(atPath: directory.path))
            for case let relative as String in enumerator where relative.hasSuffix(".swift") {
                let file = directory.appendingPathComponent(relative)
                let source = try String(contentsOf: file, encoding: .utf8)
                scanned += 1
                if source.contains("import FinanceCore") {
                    offenders.append("\(layer)/\(relative)")
                }
            }
        }

        // If this scanned nothing, it is proving nothing.
        #expect(scanned > 10)
        #expect(offenders.isEmpty, "these files import the engine: \(offenders)")
    }

    @Test("The import surface types are Foundation-shaped")
    func importSurfaceTypesCarryNoEngineValues() {
        // Built here, in a suite that could not name a FinanceCore type if it
        // wanted to: this file's product half compiles without the engine.
        let preview = ImportAccountPreview(
            id: "bank-main", name: "BNP", kind: .bank, currencyCode: "EUR", fractionDigits: 2,
            balance: .eur(300.00), asOf: CalendarDay(year: 2026, month: 8, day: 20),
            freshness: .daysOld(8), isSpendableHere: true, isActive: true
        )
        #expect(preview.freshness.isStale)
        #expect(ImportBalanceRow.caption(for: preview).hasPrefix("As of"))
    }
}

// MARK: - Rendering helper

@MainActor
enum RenderCheck {
    static func image(
        _ view: some View,
        store: FinanceStore,
        scheme: ColorScheme = .light,
        typeSize: DynamicTypeSize = .large
    ) -> UIImage? {
        let renderer = ImageRenderer(
            content: view
                .environment(store)
                .environment(AppNavigation())
                .environment(\.dynamicTypeSize, typeSize)
                .preferredColorScheme(scheme)
                .frame(width: 393, height: 852)
        )
        renderer.scale = 1
        return renderer.uiImage
    }
}
