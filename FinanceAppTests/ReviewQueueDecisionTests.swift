import FinanceCore
import Foundation
import Testing
@testable import FinanceApp

/// The To Review queue says what each decision is, not only what the bank
/// called it.
///
/// The rows are built by `AttentionPresentationMapper` from facts the banking
/// surface already carries: the engine's own primary suggestion, its duplicate
/// conflict, and its provider-status warning. Nothing here classifies evidence,
/// resolves anything, or reads meaning out of a merchant name or an amount.
///
/// The semantic cases drive a real document through the real store so that a
/// suggestion has to survive `ExternalEvidenceReview`, `DomainMapper` and the
/// attention layer to reach a row. All values and identities are synthetic.
@MainActor
@Suite("Review queue decisions")
struct ReviewQueueDecisionTests {

    private static let today = Day(year: 2026, month: 9, day: 10)
    private static let boundary = Day(year: 2026, month: 8, day: 1)
    private static let observedAt = Date(timeIntervalSince1970: 1_788_000_000)

    private func euro(_ minorUnits: Int64) -> Money {
        Money(minorUnits: minorUnits, currency: .eur)
    }

    private func account() -> Account {
        Account(
            id: "local-bank", name: "Everyday bank", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 0
        )
    }

    private func binding() -> ExternalAccountBinding {
        ExternalAccountBinding(
            id: "binding", provider: .bnp,
            remoteOpaqueAccountID: "acct_synthetic",
            localAccountID: "local-bank",
            syncStartBoundary: Self.boundary,
            createdAt: Self.observedAt
        )
    }

    private func observation(
        _ id: String,
        minorUnits: Int64,
        merchant: String,
        code: String,
        day: Int
    ) -> ExternalObservation {
        ExternalObservation(
            id: id,
            bindingID: "binding",
            provider: .bnp,
            status: .booked,
            creditDebitIndicator: .debit,
            amount: euro(minorUnits),
            bookingDate: Day(year: 2026, month: 9, day: day),
            structuredMerchantName: merchant,
            bankTransactionCode: code,
            eligibleForEconomicActual: true,
            observedAt: Self.observedAt
        )
    }

    /// A confirmed expense a person entered themselves, so an observation of
    /// the same money is a genuine duplicate rather than a first sighting.
    private func confirmedExpense(_ id: String, minorUnits: Int64, day: Int) -> Transaction {
        Transaction(
            id: id,
            date: Day(year: 2026, month: 9, day: day),
            kind: .expense,
            legs: [AccountLeg(accountID: "local-bank", amount: euro(minorUnits))],
            factivity: .observed,
            lifecycle: .cleared,
            provenance: Provenance(source: "TEST", evidenceGrade: .userConfirmed)
        )
    }

    private func store(
        observations: [ExternalObservation],
        transactions: [Transaction] = []
    ) -> FinanceStore {
        var document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account()],
            balances: [
                AccountBalance(
                    accountID: "local-bank", balance: euro(500_00), asOf: Self.today
                )
            ],
            transactions: transactions,
            planning: FinanceDocument.Planning(defaultScenario: .base)
        )
        document.externalAccountBindings = [binding()]
        document.externalObservations = observations
        // An observation with no explicit resolution row is not "unreviewed",
        // it is unstated — and the mapper refuses to surface it at all. Sync
        // writes these; a hand-built document has to as well.
        document.observationResolutions = observations.map {
            ExternalObservationResolution(observationID: $0.id, state: .unreviewed)
        }
        return FinanceStore(document: document, today: Self.today, scenario: .base)
    }

    private func rows(in store: FinanceStore) -> [ActivityAttentionRow] {
        store.attentionPresentation.activity.decisions
    }

    private func row(_ id: String, in store: FinanceStore) throws -> ActivityAttentionRow {
        try #require(rows(in: store).first { $0.id == id })
    }

    // MARK: - The row states the decision

    @Test("Cash out of a machine is named as a cash movement, not as a purchase")
    func atmEvidenceNamesItsOwnKind() throws {
        let store = store(observations: [
            observation("obs-atm", minorUnits: -30_00, merchant: "CASH MACHINE",
                        code: "ATM", day: 5)
        ])
        let row = try row("obs-atm", in: store)

        // The engine's title, carried verbatim. Account movement is not
        // spending, and this is the only thing on the row that says so before
        // it is opened.
        #expect(row.decision == "ATM / cash movement")
        #expect(row.caution == nil)
        // The evidence is still unreviewed: naming a decision is not making one.
        #expect(store.snapshot.syncedObservations.first { $0.id == "obs-atm" }?.resolution == .unreviewed)
    }

    @Test("Evidence for money already recorded is flagged before it is opened")
    func duplicateEvidenceCarriesItsWarning() throws {
        let store = store(
            observations: [
                observation("obs-dup", minorUnits: -12_50, merchant: "CORNER SHOP",
                            code: "CARD_PURCHASE", day: 6)
            ],
            transactions: [confirmedExpense("tx-existing", minorUnits: -12_50, day: 6)]
        )
        let row = try row("obs-dup", in: store)
        let observation = try #require(
            store.snapshot.syncedObservations.first { $0.id == "obs-dup" }
        )

        // The conflict is the engine's, and the row restates that it exists
        // rather than re-deriving one from the amount matching.
        #expect(observation.duplicateConflict != nil)
        #expect(row.caution == .mayAlreadyBeRecorded)
        #expect(row.caution?.label == "May already be recorded")
        // Flagging is not resolving. The person still has to decide, and the
        // queue still holds the item.
        #expect(observation.resolution == .unreviewed)
        #expect(rows(in: store).contains { $0.id == "obs-dup" })
    }

    @Test("Evidence the app cannot interpret says nothing rather than something")
    func uninterpretableEvidenceInventsNoDecision() throws {
        let store = store(observations: [
            observation("obs-plain", minorUnits: -8_40, merchant: "UNKNOWN SHOP",
                        code: "CARD_PURCHASE", day: 7)
        ])
        let row = try row("obs-plain", in: store)

        // No suggestion exists, so no line is printed. A queue that always
        // filled this line would have to invent a reading for exactly the
        // evidence a person most needs to look at themselves.
        #expect(row.decision == nil)
        #expect(row.caution == nil)
        // The row is still there, and still says what the bank said.
        #expect(row.title == "UNKNOWN SHOP")
        #expect(row.amount == Amount(minorUnits: -8_40, currencyCode: "EUR"))
    }

    // MARK: - Which warning wins

    @Test("A record the bank has changed outranks a possible duplicate")
    func providerWarningOutranksDuplicate() {
        // Both flags on one item. The order follows `inboxPriority`, which
        // tests the provider warning first: evidence the bank is no longer
        // sure about makes the duplicate question premature.
        let conflicted = observationItem(
            hasProviderStatusWarning: true,
            duplicateConflict: ObservationDuplicateConflict(
                kind: .exactExisting, transactionIDs: ["tx"], relatedObservationID: nil
            )
        )
        let presentation = present(conflicted)

        #expect(presentation?.caution == .providerChangedRecord)
        #expect(presentation?.caution != .mayAlreadyBeRecorded)
    }

    @Test("Ordinary evidence carries no warning at all")
    func cleanEvidenceIsNotDecorated() {
        let presentation = present(
            observationItem(hasProviderStatusWarning: false, duplicateConflict: nil)
        )
        #expect(presentation?.caution == nil)
    }

    // MARK: - Resolving quiets the queue

    @Test("Deciding an item removes it from the queue")
    func aResolvedItemLeavesTheQueue() throws {
        let store = store(observations: [
            observation("obs-atm", minorUnits: -30_00, merchant: "CASH MACHINE",
                        code: "ATM", day: 5),
            observation("obs-plain", minorUnits: -8_40, merchant: "UNKNOWN SHOP",
                        code: "CARD_PURCHASE", day: 7)
        ])
        #expect(rows(in: store).count == 2)

        try store.markObservationNoEconomicEffect("obs-atm")

        let remaining = rows(in: store)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == "obs-plain")
        // The other item is untouched by the decision made about its neighbour.
        #expect(remaining.first?.decision == nil)
        #expect(remaining.first?.caution == nil)
    }

    // MARK: - What the row must not change

    @Test("The row quotes the candidate's amount and never a recomputed one")
    func theAmountIsCarriedNotDerived() throws {
        let store = store(observations: [
            observation("obs-atm", minorUnits: -30_00, merchant: "CASH MACHINE",
                        code: "ATM", day: 5)
        ])
        let row = try row("obs-atm", in: store)
        let observation = try #require(
            store.snapshot.syncedObservations.first { $0.id == "obs-atm" }
        )

        #expect(row.amount == observation.amount)
        // Booked provider evidence is not economic activity, and describing it
        // better does not make it any. Nothing was recorded as spending.
        #expect(store.snapshot.activity.flatMap(\.rows).isEmpty)
    }

    @Test("Payments waiting to be confirmed are left as they were")
    func overduePaymentRowsAreUnaffected() {
        let expectedDay = CalendarDay(year: 2026, month: 9, day: 2)
        let payment = ExpectedPayment(
            id: "obligation-test@2026-09-02",
            ruleID: "obligation-test",
            ruleName: "Test subscription",
            expectedDate: expectedDay,
            amount: .eur(12),
            status: .overdue,
            expectedAccountLabel: "Everyday bank"
        )
        var snapshot = FinanceAppSnapshot.empty(asOf: expectedDay)
        snapshot.expectedPayments = [payment]
        let state = AttentionCoordinator.evaluate(
            proposals: [
                AttentionCandidateProposal(
                    kind: .overdueExpectedOccurrence,
                    identity: payment.id,
                    subject: .expectedOccurrence(
                        obligationID: payment.ruleID, name: payment.ruleName
                    ),
                    detail: .overdueOccurrence(amount: payment.amount, expectedDay: expectedDay),
                    dependencies: [.expectedOccurrenceLedger]
                )
            ],
            availability: availability
        )
        let presentation = AttentionPresentationMapper.present(
            state, snapshot: snapshot, heroIsAvailable: true,
            planFundingIsEstablished: true
        )
        let row = presentation.activity.paymentsToConfirm.first

        // This row already said what it was. It gains nothing and keeps its
        // own sentence — spelled the way the reader's locale spells a date.
        let dueText = expectedDay.formatted(.dateTime.day().month(.abbreviated))
        #expect(row?.subtitle == "Was due \(dueText) · nothing matched")
        #expect(row?.decision == nil)
        #expect(row?.caution == nil)
    }

    // MARK: - Helpers for the mapper-level cases

    private var availability: AttentionSourceAvailability {
        AttentionSourceAvailability([
            .currentAccountTruth: .available,
            .providerAuthority: .available,
            .forecastProjection: .available,
            .evidenceReviewQueue: .available,
            .expectedOccurrenceLedger: .available,
            .periodReview: .available,
            .periodCheckpointBaseline: .unavailable(.notEvaluated),
        ])
    }

    private func observationItem(
        hasProviderStatusWarning: Bool,
        duplicateConflict: ObservationDuplicateConflict?
    ) -> SyncedObservationItem {
        SyncedObservationItem(
            id: "observation-1",
            providerName: "Test Bank",
            providerAccountName: "Everyday bank",
            isAccountBindingActive: true,
            amount: Amount(minorUnits: -1_250, currencyCode: "EUR"),
            status: .booked,
            resolution: .unreviewed,
            displayMerchant: "Test item",
            observedMerchant: nil,
            rawMerchantText: nil,
            remittance: nil,
            merchantEmail: nil,
            bankTransactionCode: nil,
            dates: ObservationDates(
                booking: CalendarDay(year: 2026, month: 9, day: 5),
                transaction: nil,
                value: nil,
                derivedTransaction: nil,
                derivedProvenanceLabel: nil,
                economicPeriod: CalendarDay(year: 2026, month: 9, day: 5)
            ),
            observedAt: Self.observedAt,
            suggestions: [],
            duplicateConflict: duplicateConflict,
            hasProviderStatusWarning: hasProviderStatusWarning
        )
    }

    private func present(_ item: SyncedObservationItem) -> ActivityAttentionRow? {
        var snapshot = FinanceAppSnapshot.empty(
            asOf: CalendarDay(year: 2026, month: 9, day: 10)
        )
        snapshot.syncedObservations = [item]
        let state = AttentionCoordinator.evaluate(
            proposals: AttentionFactAdapters.bookedEvidence(from: [item]),
            availability: availability
        )
        return AttentionPresentationMapper.present(
            state, snapshot: snapshot, heroIsAvailable: true,
            planFundingIsEstablished: true
        ).activity.decisions.first
    }
}
