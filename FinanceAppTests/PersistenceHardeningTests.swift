import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

/// Stored data that cannot be read is refused, never reinterpreted.
///
/// Every case here used to decode into a plausible default — `expense`,
/// `observed`, `bank`, `cleared`, `committed`, `scheduled`. That turns a
/// corrupt or future-version row into a *valid* financial statement that is
/// simply not true, which no downstream check can detect. Once real money is
/// in the store, refusing to open is the only safe answer.
@MainActor
@Suite("Unreadable stored data fails loudly")
struct PersistenceHardeningTests {

    private static let today = Day(year: 2026, month: 9, day: 16)

    private static let account = Account(
        id: "bank", name: "Bank", currency: .eur, kind: .bank,
        supportedRails: PaymentRail.euroBankRails
    )

    private static func document(schemaVersion: String = Interchange.currentSchemaVersion) -> FinanceDocument {
        FinanceDocument(
            schemaVersion: schemaVersion,
            documentKind: "TEST",
            accounts: [account],
            balances: [
                AccountBalance(
                    accountID: account.id,
                    balance: Money(minorUnits: 100_000, currency: .eur),
                    asOf: today
                )
            ],
            transactions: [
                Transaction(
                    id: "tx", date: today, kind: .expense,
                    legs: [AccountLeg(accountID: account.id, amount: Money(minorUnits: -1_000, currency: .eur))],
                    factivity: .observed,
                    provenance: Provenance(source: "TEST", evidenceGrade: .userConfirmed)
                )
            ],
            expectedTransactions: [
                Transaction(
                    id: "etx", date: today, kind: .income,
                    legs: [AccountLeg(accountID: account.id, amount: Money(minorUnits: 5_000, currency: .eur))],
                    factivity: .expected,
                    certainty: .guaranteed,
                    provenance: Provenance(source: "TEST", evidenceGrade: .derived)
                )
            ],
            incomeSources: [
                IncomeSource(
                    id: "inc", name: "Stipend",
                    amount: Money(minorUnits: 29_250, currency: .eur),
                    certainty: .expected,
                    schedule: .monthly(onDay: 5, from: today.monthKey, through: nil)
                )
            ],
            installments: [],
            debts: [],
            planning: FinanceDocument.Planning(
                defaultScenario: .base,
                recurringObligations: [
                    RecurringObligation(
                        id: "ob-rent", name: "Rent",
                        amount: Money(minorUnits: 48_000, currency: .eur),
                        spec: .monthly(onDay: 5, from: today.monthKey, through: nil),
                        requirement: PaymentRequirement(currency: .eur, acceptableRails: [.sepaDirectDebit]),
                        spendingClass: .essential,
                        commitmentStatus: .committed
                    )
                ]
            )
        )
    }

    /// The container is held for the lifetime of the test, not just long
    /// enough to hand out its context: a `ModelContext` does not keep its
    /// container alive, and using one whose container has gone traps.
    private let container: ModelContainer

    init() throws {
        container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private var context: ModelContext { container.mainContext }

    private func loaded() throws -> ModelContext {
        try StoredDocumentGraph.replace(with: Self.document(), in: context, writtenOn: Self.today)
        return context
    }

    @Test("Manual entry appends without replacing existing stored rows")
    func manualEntryPreservesStoredRowIdentity() throws {
        _ = try loaded()
        let existing = try #require(try context.fetch(FetchDescriptor<StoredTransaction>())
            .first { $0.identifier == "tx" })
        let persistentID = existing.persistentModelID
        let store = try FinanceStore(context: context, now: fixtureInstant(Self.today))
        try store.add(TransactionDraft(
            day: CalendarDay(year: 2026, month: 9, day: 16), kind: .expense,
            amount: Amount(minorUnits: 100, currencyCode: "EUR"), accountID: "bank"
        ))
        let rows = try context.fetch(FetchDescriptor<StoredTransaction>())
        #expect(rows.count == 3)
        #expect(rows.first { $0.identifier == "tx" }?.persistentModelID == persistentID)
        #expect(try StoredDocumentGraph.load(from: context)?.transactions.count == 2)
    }

    @Test("Manual entry recreates optional preferences in a migrated store")
    func manualEntryAfterMissingPreferences() throws {
        _ = try loaded()
        try context.fetch(FetchDescriptor<StoredEntryPreferences>()).forEach(context.delete)
        try context.save()
        let store = try FinanceStore(context: context, now: fixtureInstant(Self.today))
        try store.add(TransactionDraft(
            day: CalendarDay(year: 2026, month: 9, day: 16), kind: .expense,
            amount: Amount(minorUnits: 100, currencyCode: "EUR"), accountID: "bank"
        ))
        #expect(try context.fetchCount(FetchDescriptor<StoredEntryPreferences>()) == 1)
        #expect(try StoredDocumentGraph.load(from: context)?.transactions.count == 2)
    }

    private func failure(loading context: ModelContext) -> PersistenceMappingError? {
        do { _ = try StoredDocumentGraph.load(from: context); return nil }
        catch let error as PersistenceMappingError { return error }
        catch { return nil }
    }

    /// Corrupts one stored token and asserts the load refuses rather than
    /// producing a document.
    private func expectRefusal<Row: PersistentModel>(
        _ type: Row.Type,
        field: String,
        _ corrupt: (Row) -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let context = try loaded()
        let row = try #require(try context.fetch(FetchDescriptor<Row>()).first, sourceLocation: sourceLocation)
        corrupt(row)
        try context.save()
        #expect(
            failure(loading: context) == .unknownEnumValue(field: field, value: "not-a-real-value"),
            sourceLocation: sourceLocation
        )
    }

    @Test("A malformed persisted day produces the existing corruption error")
    func malformedDayRefusesDocument() throws {
        let context = try loaded()
        let row = try #require(try context.fetch(FetchDescriptor<StoredAccountBalance>()).first)
        row.asOfDay = 20260899
        try context.save()
        #expect(failure(loading: context) == .corruptDay(20260899))
    }

    // MARK: - Closed vocabularies

    @Test("An unknown transaction kind does not become an expense")
    func unknownTransactionKind() throws {
        try expectRefusal(StoredTransaction.self, field: "transaction.kind") {
            $0.kindRaw = "not-a-real-value"
        }
    }

    @Test("An unknown account kind does not become a bank account")
    func unknownAccountKind() throws {
        try expectRefusal(StoredAccount.self, field: "account.kind") {
            $0.kindRaw = "not-a-real-value"
        }
    }

    @Test("An unknown factivity does not turn a plan into a fact")
    func unknownFactivity() throws {
        let context = try loaded()
        let row = try #require(try context.fetch(FetchDescriptor<StoredTransaction>()).first)
        row.factivityRaw = "not-a-real-value"
        try context.save()
        #expect(failure(loading: context) == .unknownEnumValue(field: "transaction.factivity", value: "not-a-real-value"))
        // And it is not simply dropped from both lists either.
        #expect((try? StoredDocumentGraph.load(from: context)) == nil)
    }

    @Test("An unknown lifecycle does not become cleared")
    func unknownLifecycle() throws {
        try expectRefusal(StoredTransaction.self, field: "transaction.lifecycle") {
            $0.lifecycleRaw = "not-a-real-value"
        }
    }

    @Test("An unknown certainty does not become possible")
    func unknownCertainty() throws {
        let context = try loaded()
        let row = try #require(
            try context.fetch(FetchDescriptor<StoredIncomeSource>()).first
        )
        row.certaintyRaw = 99
        try context.save()
        #expect(failure(loading: context) == .unknownEnumValue(field: "income.certainty", value: "99"))
    }

    @Test("An unknown transaction certainty is refused too")
    func unknownTransactionCertainty() throws {
        let context = try loaded()
        let row = try #require(
            try context.fetch(FetchDescriptor<StoredTransaction>())
                .first { $0.certaintyRaw != nil }
        )
        row.certaintyRaw = 99
        try context.save()
        #expect(failure(loading: context) == .unknownEnumValue(field: "transaction.certainty", value: "99"))
    }

    @Test("An unknown commitment status does not become committed")
    func unknownCommitmentStatus() throws {
        try expectRefusal(StoredRecurringObligation.self, field: "obligation.commitmentStatus") {
            $0.commitmentStatusRaw = "not-a-real-value"
        }
    }

    @Test("An unknown balance status does not become observed")
    func unknownBalanceStatus() throws {
        try expectRefusal(StoredAccountBalance.self, field: "balance.status") {
            $0.statusRaw = "not-a-real-value"
        }
    }

    @Test("An unknown spending class and date precision are refused")
    func otherClosedVocabularies() throws {
        try expectRefusal(StoredRecurringObligation.self, field: "obligation.spendingClass") {
            $0.spendingClassRaw = "not-a-real-value"
        }
        try expectRefusal(StoredTransaction.self, field: "transaction.datePrecision") {
            $0.datePrecisionRaw = "not-a-real-value"
        }
        try expectRefusal(StoredTransaction.self, field: "transaction.provenance.evidenceGrade") {
            $0.provenanceEvidenceGradeRaw = "not-a-real-value"
        }
    }

    @Test("An unknown default scenario is refused rather than dropped to nil")
    func unknownScenario() throws {
        let context = try loaded()
        let meta = try #require(try context.fetch(FetchDescriptor<StoredDocumentMeta>()).first)
        meta.defaultScenarioRaw = "not-a-real-value"
        try context.save()
        #expect(failure(loading: context) == .unknownEnumValue(field: "planning.defaultScenario", value: "not-a-real-value"))
    }

    // MARK: - Schema version

    @Test("A stored document from an unsupported schema will not open")
    func unsupportedStoredSchema() throws {
        let context = try loaded()
        let meta = try #require(try context.fetch(FetchDescriptor<StoredDocumentMeta>()).first)
        meta.schemaVersion = "9.9.9"
        try context.save()
        #expect(failure(loading: context)
                == .unsupportedSchemaVersion(found: "9.9.9", supported: PersistedSchema.supported))
    }

    @Test("A document from an unsupported schema will not import")
    func unsupportedImportedSchema() throws {
        let context = self.context
        var error: PersistenceMappingError?
        do {
            try StoredDocumentGraph.replace(
                with: Self.document(schemaVersion: "1.0.0"),
                in: context,
                writtenOn: Self.today
            )
        } catch let thrown as PersistenceMappingError {
            error = thrown
        }
        #expect(error == .unsupportedSchemaVersion(found: "1.0.0", supported: PersistedSchema.supported))
        // Nothing was written on the way to refusing.
        #expect(try context.fetchCount(FetchDescriptor<StoredAccount>()) == 0)
    }

    @Test("The current schema is the one the app writes, and earlier additive minors still read")
    func currentSchemaIsSupported() {
        // Writing produces exactly one version.
        #expect(PersistedSchema.current == Interchange.currentSchemaVersion)
        #expect(throws: Never.self) { try PersistedSchema.validate(Interchange.currentSchemaVersion) }

        // Reading additionally accepts the earlier additive minors, so an
        // export taken before a field existed is not stranded by it.
        #expect(PersistedSchema.supported.contains(Interchange.currentSchemaVersion))
        #expect(PersistedSchema.supported == Interchange.readableSchemaVersions.sorted())
        #expect(throws: Never.self) { try PersistedSchema.validate("1.1.0") }

        // 2.0.0 is the explicit-monetary schema: readable, but never the one
        // the app writes by default — an ordinary store stays on 1.6.0.
        #expect(throws: Never.self) { try PersistedSchema.validate(Interchange.explicitMonetarySchemaVersion) }
        #expect(PersistedSchema.current != Interchange.explicitMonetarySchemaVersion)

        // A version nobody has taught this build about is still refused.
        #expect(throws: PersistenceMappingError.self) { try PersistedSchema.validate("1.0.0") }
        #expect(throws: PersistenceMappingError.self) { try PersistedSchema.validate("9.9.9") }
    }

    @Test("An unreadable store is not replaced by the next entry")
    func unreadableStoreIsNotOverwritten() throws {
        let context = try loaded()
        let meta = try #require(try context.fetch(FetchDescriptor<StoredDocumentMeta>()).first)
        meta.schemaVersion = "9.9.9"
        try context.save()

        let store = try FinanceStore(context: context, now: fixtureInstant(Self.today))
        #expect(store.loadFailure != nil)
        // The rows that could not be read are still there.
        #expect(try context.fetchCount(FetchDescriptor<StoredTransaction>()) == 2)
    }

    // MARK: - One balance per account

    @Test("Two current balances for one account fail the import")
    func duplicateBalanceIsRefused() throws {
        let context = self.context
        var document = Self.document()
        document.balances.append(
            AccountBalance(
                accountID: Self.account.id,
                balance: Money(minorUnits: 1, currency: .eur),
                asOf: Self.today
            )
        )
        var error: PersistenceMappingError?
        do { try StoredDocumentGraph.replace(with: document, in: context, writtenOn: Self.today) }
        catch let thrown as PersistenceMappingError { error = thrown }

        // Not "keep the later one": which of the two is current is not the
        // importer's decision to make.
        #expect(error == .duplicateAccountBalance(accountID: Self.account.id))
        #expect(try context.fetchCount(FetchDescriptor<StoredAccountBalance>()) == 0)
    }

    @Test("Two accounts with one identifier fail the import")
    func duplicateAccountIsRefused() throws {
        let context = self.context
        var document = Self.document()
        document.accounts.append(Self.account)
        var error: PersistenceMappingError?
        do { try StoredDocumentGraph.replace(with: document, in: context, writtenOn: Self.today) }
        catch let thrown as PersistenceMappingError { error = thrown }
        #expect(error == .duplicateAccountIdentifier(id: Self.account.id))
    }

    @Test("A clean document still round-trips")
    func cleanDocumentStillLoads() throws {
        let context = try loaded()
        let loaded = try #require(try StoredDocumentGraph.load(from: context))
        #expect(loaded == Self.document())
    }
}
