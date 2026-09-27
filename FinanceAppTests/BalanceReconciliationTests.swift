import Foundation
import SwiftUI
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

@MainActor
@Suite("Guided dated balance reconciliation")
struct BalanceReconciliationTests {
    private let day = Day(year: 2026, month: 9, day: 20)
    private let anchorDay = Day(year: 2026, month: 9, day: 1)
    private var account: Account { EntryFixtures.bank }
    private var binding: ExternalAccountBinding {
        .init(id: "synthetic-binding", provider: .bnp, remoteOpaqueAccountID: "synthetic-remote",
              localAccountID: account.id, syncStartBoundary: anchorDay, createdAt: fixtureInstant(day))
    }
    private func document(reference: Day? = Day(year: 2026, month: 9, day: 10), type: String = "CLBD") -> FinanceDocument {
        FinanceDocument(schemaVersion: Interchange.currentSchemaVersion, documentKind: "SYNTHETIC",
            accounts: [account], balances: [.init(accountID: account.id, balance: money(10000), asOf: anchorDay)],
            externalAccountBindings: [binding], providerBalanceSnapshots: [.init(id: "synthetic-balance", bindingID: binding.id,
                provider: .bnp, balanceType: type, amount: money(9000), referenceDate: reference, observedAt: fixtureInstant(day))])
    }
    private func money(_ units: Int64) -> Money { .init(minorUnits: units, currency: .eur) }
    private func transaction(_ id: String, on date: Day, amount: Int64, lifecycle: TransactionLifecycle = .cleared) -> FinanceCore.Transaction {
        .init(id: id, date: date, kind: amount < 0 ? .expense : .income,
            legs: [.init(accountID: account.id, amount: money(amount))], factivity: .observed, lifecycle: lifecycle,
            provenance: .init(source: "SYNTHETIC", evidenceGrade: .userConfirmed))
    }
    private func status(_ doc: FinanceDocument, pending: Set<String> = []) throws -> ProviderBalanceStatus {
        try #require(DomainMapper().bankingSurface(document: doc, transactionPresentation: [:], asOf: day,
            currentPendingIDs: pending).balances.first)
    }

    @Test func bankReferenceDateControlsReplayRatherThanTodaysCash() throws {
        var doc = document()
        doc.transactions = [transaction("included", on: Day(year: 2026, month: 9, day: 10), amount: -1000),
            transaction("later", on: Day(year: 2026, month: 9, day: 11), amount: -3000),
            transaction("anchor", on: anchorDay, amount: -5000),
            transaction("reversed", on: Day(year: 2026, month: 9, day: 5), amount: -2000, lifecycle: .reversed)]
        let result = try status(doc)
        #expect(result.ledgerBalance?.minorUnits == 9000 && result.difference?.isZero == true)
        #expect(result.reconciliation?.movementIDs == ["included"])
        #expect(result.reconciliation?.movementNet?.minorUnits == -1000)
        #expect(CurrentHoldings.derivedLedgerBalance(accountID: account.id, asOf: day, in: doc)?.minorUnits == 6000)
        #expect(result.reconciliation?.comparisonCaution.contains("does not verify") == true)
    }

    @Test func missingAnchorRetainsEvidenceAndCannotBecomeZero() throws {
        var doc = document(); doc.balances = []
        let result = try status(doc)
        #expect(result.providerBalance.minorUnits == 9000)
        #expect(result.ledgerBalance == nil && result.difference == nil)
        #expect(result.reconciliation?.blocker == .missingAnchor)
    }

    @Test func unknownCurrentDayCannotAdmitFutureDatedComparison() throws {
        for reference in [day, Day(year: 2026, month: 9, day: 21)] {
            let result = try #require(DomainMapper().bankingSurface(document: document(reference: reference),
                transactionPresentation: [:]).balances.first)
            #expect(result.ledgerBalance == nil && result.difference == nil)
            #expect(result.reconciliation?.blocker == .missingCurrentDay)
            #expect(result.providerBalance.minorUnits == 9000)
        }
    }

    @Test func observationTimestampNeverSubstitutesForMissingReferenceDate() throws {
        let result = try status(document(reference: nil))
        #expect(result.referenceDate == nil && result.ledgerBalance == nil && result.difference == nil)
        #expect(result.reconciliation?.blocker == .missingDate)
    }

    @Test func datesBeforeAnchorFutureAndInvalidRefuseComparison() throws {
        for (date, blocker) in [(Day(year: 2026, month: 8, day: 31), BalanceReconciliation.Blocker.beforeAnchor),
                               (Day(year: 2026, month: 9, day: 21), .futureDate),
                               (Day(year: Int.max, month: 1, day: 1), .invalidDate)] {
            let result = try status(document(reference: date))
            #expect(result.difference == nil && result.reconciliation?.blocker == blocker)
        }
    }

    @Test func typesRemainDistinctAndUnknownTypeFailsClosed() throws {
        for (type, meaning) in [("CLBD", "Closing booked balance"), ("XPCD", "Expected balance"), ("ITAV", "Interim available balance")] {
            let result = try status(document(type: type))
            #expect(result.reconciliation?.balanceMeaning == meaning && result.reconciliation?.blocker == nil)
        }
        let unknown = try status(document(type: "SYNTHETIC-UNKNOWN"))
        #expect(unknown.providerBalance.minorUnits == 9000 && unknown.difference == nil)
        #expect(unknown.reconciliation?.blocker == .unsupportedType)
    }

    @Test func currencyAndPrecisionMismatchNeverConvert() throws {
        var doc = document()
        doc.providerBalanceSnapshots = [.init(id: "synthetic-balance", bindingID: binding.id, provider: .bnp,
            balanceType: "CLBD", amount: Money(minorUnits: 9000, currency: .kwd), referenceDate: day, observedAt: fixtureInstant(day))]
        let result = try status(doc)
        #expect(result.providerBalance.fractionDigits == 3 && result.difference == nil)
        #expect(result.reconciliation?.blocker == .currencyMismatch)
    }

    @Test func sameCodeDifferentPrecisionIsRefusedAndThreeDigitComparisonStaysExact() throws {
        var doc = document()
        doc.providerBalanceSnapshots = [.init(id: "synthetic-balance", bindingID: binding.id, provider: .bnp,
            balanceType: "CLBD", amount: Money(minorUnits: 9000, currency: Currency(code: "EUR", minorUnitDigits: 3)),
            referenceDate: day, observedAt: fixtureInstant(day))]
        #expect(try status(doc).reconciliation?.blocker == .currencyMismatch)
        doc.accounts = [.init(id: account.id, name: "Synthetic KWD", currency: .kwd, kind: .bank, supportedRails: [])]
        doc.balances = [.init(accountID: account.id, balance: Money(minorUnits: 10000, currency: .kwd), asOf: anchorDay)]
        doc.providerBalanceSnapshots = [.init(id: "synthetic-balance", bindingID: binding.id, provider: .bnp,
            balanceType: "CLBD", amount: Money(minorUnits: 9000, currency: .kwd), referenceDate: day, observedAt: fixtureInstant(day))]
        let result = try status(doc)
        #expect(result.ledgerBalance?.fractionDigits == 3 && result.difference?.fractionDigits == 3)
        #expect(result.difference?.minorUnits == -1000 && result.reconciliation?.blocker == nil)
    }

    @Test func inactiveBindingAndWrongProviderRemainEvidenceWithoutComparison() throws {
        var doc = document()
        doc.externalAccountBindings = [.init(id: binding.id, provider: .bnp, remoteOpaqueAccountID: "synthetic-remote",
            localAccountID: account.id, syncStartBoundary: anchorDay, isActive: false, createdAt: fixtureInstant(day))]
        #expect(try status(doc).reconciliation?.blocker == .inactiveBinding)
        doc.externalAccountBindings = [binding]
        doc.providerBalanceSnapshots = [.init(id: "synthetic-balance", bindingID: binding.id, provider: .paypal,
            balanceType: "CLBD", amount: money(9000), referenceDate: day, observedAt: fixtureInstant(day))]
        #expect(try status(doc).reconciliation?.blocker == .identityMismatch)
    }

    @Test func accountMovementIncludesTransfersAndNamesRecordedPending() throws {
        var doc = document()
        doc.accounts.append(EntryFixtures.wallet)
        doc.transactions = [transaction("pending", on: Day(year: 2026, month: 9, day: 2), amount: -500, lifecycle: .pending),
            .init(id: "transfer", date: Day(year: 2026, month: 9, day: 3), kind: .transfer,
                legs: [.init(accountID: account.id, amount: money(-500)), .init(accountID: EntryFixtures.wallet.id, amount: money(500))], factivity: .observed)]
        let result = try status(doc)
        #expect(result.ledgerBalance?.minorUnits == 9000)
        #expect(result.reconciliation?.movementNet?.minorUnits == -1000)
        #expect(result.reconciliation?.pendingMovementCount == 1)
    }

    @Test func arithmeticOverflowIsUnavailableRatherThanTrapOrClipping() throws {
        var doc = document()
        doc.balances = [.init(accountID: account.id, balance: money(Int64.max), asOf: anchorDay)]
        doc.transactions = [transaction("overflow", on: Day(year: 2026, month: 9, day: 2), amount: 1)]
        let addition = try status(doc)
        #expect(addition.ledgerBalance == nil && addition.reconciliation?.blocker == .unsafeArithmetic)
        doc.transactions = []
        doc.providerBalanceSnapshots = [.init(id: "synthetic-balance", bindingID: binding.id, provider: .bnp,
            balanceType: "CLBD", amount: money(-1), referenceDate: day, observedAt: fixtureInstant(day))]
        #expect(try status(doc).difference?.minorUnits == Int64.min)
        doc.providerBalanceSnapshots = [.init(id: "synthetic-balance", bindingID: binding.id, provider: .bnp,
            balanceType: "CLBD", amount: money(-2), referenceDate: day, observedAt: fixtureInstant(day))]
        let subtraction = try status(doc)
        #expect(subtraction.difference == nil && subtraction.reconciliation?.blocker == .unsafeArithmetic)
    }

    @Test func guideScopesBookedReviewAndCurrentPendingWithoutSummingEvidence() throws {
        var doc = document()
        func observation(_ id: String, _ status: ExternalObservationStatus, _ date: Day, _ bindingID: String = "synthetic-binding") -> ExternalObservation {
            .init(id: id, bindingID: bindingID, provider: .bnp, status: status,
                creditDebitIndicator: .debit, amount: money(-500), bookingDate: date,
                eligibleForEconomicActual: status == .booked, observedAt: fixtureInstant(day))
        }
        doc.externalObservations = [observation("booked", .booked, Day(year: 2026, month: 9, day: 2)),
            observation("before", .booked, anchorDay), observation("later", .booked, day),
            observation("pending", .pending, day), observation("retired", .pending, day),
            observation("other-account", .booked, anchorDay, "other-binding")]
        doc.observationResolutions = doc.externalObservations.map { .init(observationID: $0.id, state: $0.status == .pending ? .provisional : .unreviewed) }
        let result = try status(doc, pending: ["pending"])
        #expect(result.reconciliation?.unreviewedObservationIDs == ["booked"])
        #expect(result.reconciliation?.currentPendingObservationIDs == ["pending"])
        #expect(result.ledgerBalance?.minorUnits == 10000 && result.reconciliation?.movementNet?.isZero == true)
    }

    @Test func foreignMovementDestinationKeepsNativeAmountAndPrecisionWithoutChangingEuroTotals() throws {
        for currency in [Currency.mad, .kwd] {
            for kind in [TransactionKind.expense, .income, .refund] {
                var doc = document()
                doc.accounts = [.init(id: account.id, name: "Synthetic foreign account", currency: currency, kind: .bank, supportedRails: [])]
                doc.balances = [.init(accountID: account.id, balance: Money(minorUnits: 10000, currency: currency), asOf: anchorDay)]
                doc.providerBalanceSnapshots = [.init(id: "synthetic-balance", bindingID: binding.id, provider: .bnp,
                    balanceType: "CLBD", amount: Money(minorUnits: 9000, currency: currency), referenceDate: Day(year: 2026, month: 9, day: 10), observedAt: fixtureInstant(day))]
                let units: Int64 = kind == .expense ? -1234 : 1234
                doc.transactions = [.init(id: "synthetic-foreign", date: Day(year: 2026, month: 9, day: 2), kind: kind,
                    legs: [.init(accountID: account.id, amount: Money(minorUnits: units, currency: currency))], factivity: .observed,
                    lifecycle: .cleared, provenance: .init(source: "SYNTHETIC", evidenceGrade: .userConfirmed))]
                let h = try EntryFixtures.Harness(doc)
                let group = try #require(h.store.snapshot.activity.first)
                let row = try #require(group.rows.first)
                #expect(row.amount.minorUnits == units && row.amount.currencyCode == currency.code)
                #expect(row.amount.fractionDigits == currency.minorUnitDigits)
                #expect(group.net == .zeroEUR)
                #expect(h.store.snapshot.providerBalanceStatuses.first?.reconciliation?.movementIDs == [row.id])
            }
        }
    }

    @Test func readingAndRenderingGuideDoesNotChangeLedgerEvidenceAuditOrBackup() throws {
        let h = try EntryFixtures.Harness(document())
        let before = try h.store.exportBackup().data
        #expect(h.store.snapshot.providerBalanceStatuses.count == 1)
        for scheme in [ColorScheme.light, .dark] {
            #expect(RenderCheck.image(NavigationStack { ProviderBalanceDetailView(balanceID: "synthetic-balance") },
                store: h.store, scheme: scheme, typeSize: .accessibility3) != nil)
        }
        #expect(try h.store.exportBackup().data == before && !h.container.mainContext.hasChanges)
    }
}
