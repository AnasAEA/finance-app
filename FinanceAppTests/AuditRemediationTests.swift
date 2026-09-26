import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

@MainActor
@Suite("Audit remediation regressions")
struct AuditRemediationTests {
    @Test func encryptedRecoveryRoundTripsAndWrongPasswordWritesNothing() async throws {
        let h = try EntryFixtures.Harness()
        try h.store.add(EntryFixtures.draft(merchant: "SYNTHETIC PRIVATE LABEL"))
        let backup = try h.store.exportBackup()
        let password = "synthetic audit recovery password"
        let sealed = try await backup.encrypted(password: password)
        #expect(BackupProtection.isEncrypted(sealed))
        #expect(String(data: sealed, encoding: .utf8)?.contains("SYNTHETIC PRIVATE LABEL") == false)
        #expect(throws: AppImportError.backupPasswordRequired) { _ = try DocumentImporter.decode(sealed) }
        let container = try ModelContainer(for: Schema(FinanceSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let restored = try FinanceStore(context: container.mainContext, now: fixtureInstant(EntryFixtures.today))
        await #expect(throws: AppImportError.backupPasswordInvalid) {
            _ = try await restored.prepareEncryptedImport(from: sealed, password: "wrong password")
        }
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredTransaction>()) == 0)
        _ = try await restored.prepareEncryptedImport(from: sealed, password: password)
        _ = try restored.confirmImport()
        #expect(try container.mainContext.fetch(FetchDescriptor<StoredTransaction>()).first?.appMerchant == "SYNTHETIC PRIVATE LABEL")
        var object = try #require(try JSONSerialization.jsonObject(with: sealed) as? [String: Any])
        var envelope = try #require(object[EncryptedBackup.key] as? [String: Any])
        let encodedPayload = try #require(envelope["sealed"] as? String)
        var payload = try #require(Data(base64Encoded: encodedPayload))
        payload[payload.count - 1] ^= 1
        envelope["sealed"] = payload.base64EncodedString()
        object[EncryptedBackup.key] = envelope
        let tampered = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: AppImportError.backupPasswordInvalid) { _ = try EncryptedBackup.decrypt(tampered, password: password) }
    }
    @Test func completeCandidateSnapshotRetiresOnlyItsMappedScope() throws {
        var d = EntryFixtures.document()
        let now = fixtureInstant(EntryFixtures.today)
        let binding = ExternalAccountBinding(id: "audit-binding", provider: .bnp, remoteOpaqueAccountID: "audit-remote", localAccountID: EntryFixtures.bank.id, syncStartBoundary: EntryFixtures.today, createdAt: now)
        d.externalAccountBindings = [binding]
        let observation = ExternalObservation(id: "audit-observation", bindingID: binding.id, provider: .bnp, status: .booked, creditDebitIndicator: .debit, amount: Money(minorUnits: -100, currency: .eur), bookingDate: EntryFixtures.today, eligibleForEconomicActual: true, observedAt: now)
        let candidate = CrossProviderCandidate(id: "audit-candidate", bankObservationID: observation.id, walletObservationID: nil, state: .unresolved, candidateCount: 0, amount: observation.amount, rule: "SYNTHETIC", computedAt: now)
        try ExternalEvidenceReview.importBatch(.init(observations: [observation], candidates: [candidate]), into: &d)
        let h = try EntryFixtures.Harness(d)
        _ = try h.store.importBankEvidence(.init())
        #expect(try h.store.exportDocument().crossProviderCandidates.count == 1)
        _ = try h.store.importBankEvidence(.init(), authoritativeCandidateBindingIDs: ["different-binding"])
        #expect(try h.store.exportDocument().crossProviderCandidates.count == 1)
        _ = try h.store.importBankEvidence(.init(), authoritativeCandidateBindingIDs: [binding.id])
        #expect(try h.store.exportDocument().crossProviderCandidates.isEmpty)
        #expect(try h.store.exportDocument().externalObservations.count == 1)
    }
    @Test func transportRejectsRedirectsAndIdentityUpdatesStayReadable() throws {
        let policy = BankSyncTransport()
        let url = try #require(URL(string: "https://synthetic.invalid/start"))
        let request = URLRequest(url: url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil))
        var redirected = true
        policy.urlSession(BankSyncTransport.session, task: BankSyncTransport.session.dataTask(with: request), willPerformHTTPRedirection: response, newRequest: request) { redirected = $0 != nil }
        #expect(!redirected)
        let identity = DeviceIdentityStore(service: "test.audit.identity.\(UUID().uuidString)", forcesSoftwareKey: true)
        defer { try? identity.clear() }
        let key = try identity.loadOrCreateKey()
        try identity.storePairedDeviceID("dev_synthetic_first")
        try identity.storePairedDeviceID("dev_synthetic_second")
        #expect(identity.pairedDeviceID == "dev_synthetic_second")
        #expect(try identity.loadKey()?.publicKeyX963 == key.publicKeyX963)
    }
    @Test func recoveryPreservesClassificationAndSourceActivation() throws {
        let h = try EntryFixtures.Harness()
        try h.store.add(EntryFixtures.draft(merchant: "SYNTHETIC AUDIT SHOP"))
        let source = try #require(try h.container.mainContext.fetch(FetchDescriptor<StoredIncomeSource>()).first)
        source.appIsActive = false
        try h.container.mainContext.save()
        let loaded = try FinanceStore(context: h.container.mainContext, now: fixtureInstant(EntryFixtures.today))
        let backup = try loaded.exportBackup()
        // Portable readers still see the original FinanceDocument.
        #expect(try Interchange.decode(backup.data).transactions.count == 1)
        let container = try ModelContainer(for: Schema(FinanceSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let restored = try FinanceStore(context: container.mainContext, now: fixtureInstant(EntryFixtures.today))
        _ = try restored.prepareImport(from: backup.data)
        _ = try restored.confirmImport()
        let transaction = try #require(try container.mainContext.fetch(FetchDescriptor<StoredTransaction>()).first)
        #expect(transaction.appCategoryKey == "food")
        #expect(transaction.appMerchant == "SYNTHETIC AUDIT SHOP")
        #expect(try container.mainContext.fetch(FetchDescriptor<StoredIncomeSource>()).first?.appIsActive == false)
        #expect(restored.trustedAutomationEnabled == false)
        #expect(try restored.exportBackup().data == backup.data)
    }
    @Test func unsupportedBackupMetadataRefusesBeforeWrite() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Interchange.encode(EntryFixtures.document())) as? [String: Any])
        object[AppBackupMetadata.key] = ["version": 99, "transactionPresentation": [:], "incomeSourceActive": [:]] as [String: Any]
        #expect(throws: AppImportError.invalidBackupMetadata) { _ = try DocumentImporter.decode(JSONSerialization.data(withJSONObject: object)) }
    }
    @Test func foreignReservationCanBeSummarizedWithoutConversion() throws {
        var d = EntryFixtures.document()
        d.planning.sinkingFunds = [SinkingFund(id: "audit-usd", name: "USD fund", targetAmount: Money(minorUnits: 10000, currency: .usd), reservedAmount: Money(minorUnits: 100, currency: .usd))]
        let h = try EntryFixtures.Harness(d)
        #expect(PlanningTotals.setAside(from: h.store.snapshot) == .zeroEUR)
        let totals = PlanningTotals.setAsideTotals(from: h.store.snapshot)
        #expect(totals.count == 1)
        #expect(totals.first?.amount == Amount(minorUnits: 100, currencyCode: "USD"))
    }
    @Test func restoreDebtStaysInItsCurrencyAndSubtractsPaidItems() throws {
        var d = EntryFixtures.document()
        d.debts = [Debt(id: "audit-usd-debt", name: "USD debt", originalAmount: Money(minorUnits: 10000, currency: .usd), paymentSchedule: [.init(day: EntryFixtures.today, amount: Money(minorUnits: 2500, currency: .usd), status: .paid, paidOn: EntryFixtures.today)], paymentRequirement: .init(currency: .usd, acceptableRails: [.electronicPayment]))]
        try DocumentImporter.semanticValidate(d)
        let preview = try DocumentImporter.preview(of: d, today: EntryFixtures.today)
        #expect(preview.debtOutstanding == .zeroEUR)
        #expect(preview.foreignDebtOutstanding.first?.amount == Amount(minorUnits: 7500, currencyCode: "USD"))
    }
    @Test func inconsistentLegAndAggregateOverflowAreRefused() throws {
        var d = EntryFixtures.document()
        d.transactions = [Transaction(id: "audit-bad", date: EntryFixtures.today, kind: .expense, legs: [.init(accountID: EntryFixtures.bank.id, amount: Money(minorUnits: -100, currency: .usd))], factivity: .observed, lifecycle: .cleared, provenance: .init(source: "SYNTHETIC", evidenceGrade: .userConfirmed))]
        #expect(throws: AppImportError.inconsistentDocument(.invalidLedger)) { try DocumentImporter.semanticValidate(d) }
        d = EntryFixtures.document()
        d.balances = d.balances.map { .init(accountID: $0.accountID, balance: Money(minorUnits: Int64.max / 2, currency: $0.balance.currency), asOf: $0.asOf) }
        #expect(throws: AppImportError.inconsistentDocument(.unrepresentableAmount)) { try DocumentImporter.semanticValidate(d) }
    }
    @Test func groupingRetainsCurrencyExponentIdentity() {
        let totals = PlanningTotals.totals([.init(minorUnits: 100, currencyCode: "EUR", fractionDigits: 2), .init(minorUnits: 100, currencyCode: "EUR", fractionDigits: 4)])
        #expect(totals.count == 2)
        #expect(Set(totals.map(\.id)).count == 2)
    }
    @Test func malformedNetworkMoneyDoesNotTrap() {
        #expect(MobileSnapshotMapper.signedMoney("1.00", "eur", "DBIT") == nil)
        #expect(MobileSnapshotMapper.signedMoney("1.00", "", "CRDT") == nil)
        #expect(MobileSnapshotMapper.signedMoney("-92233720368547758.08", "EUR", "CRDT") == nil)
        #expect(MobileSnapshotMapper.signedMoney("1.25", "EUR", "DBIT")?.minorUnits == -125)
    }
}
