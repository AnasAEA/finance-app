import FinanceCore
import Foundation
import Testing
@testable import FinanceApp

/// A transaction can say where it came from.
///
/// The relationship is `ExternalEvidenceLink`, and it is the only thing these
/// tests allow to produce a source row. Links are made through the real store
/// action a person uses, so the document is validated on the way in and the
/// provenance shown afterwards is the same relationship review recorded.
///
/// All values and identities are synthetic.
@MainActor
@Suite("Transaction evidence provenance")
struct TransactionEvidenceProvenanceTests {

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
            bankTransactionCode: "CARD_PURCHASE",
            eligibleForEconomicActual: true,
            observedAt: Self.observedAt
        )
    }

    /// A row a person entered. `userConfirmed` is what both entry paths in the
    /// app produce, and what safe removal requires, so this is the transaction
    /// shape the removal question is actually asked about.
    private func expense(_ id: String, minorUnits: Int64, day: Int) -> Transaction {
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
        transactions: [Transaction]
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
        document.observationResolutions = observations.map {
            ExternalObservationResolution(observationID: $0.id, state: .unreviewed)
        }
        return FinanceStore(document: document, today: Self.today, scenario: .base)
    }

    /// One observation, one transaction, linked the way review links them.
    private func linkedStore() throws -> FinanceStore {
        let store = store(
            observations: [
                observation("obs-card", minorUnits: -12_50, merchant: "CORNER SHOP", day: 6)
            ],
            transactions: [expense("tx-shop", minorUnits: -12_50, day: 6)]
        )
        try store.matchObservation("obs-card", toTransaction: "tx-shop")
        return store
    }

    // MARK: - The section appears only from a link

    @Test("A transaction decided from bank evidence says so")
    func linkedTransactionShowsItsSource() throws {
        let store = try linkedStore()
        let evidence = store.linkedEvidence(forTransaction: "tx-shop")
        let source = try #require(evidence.first)

        #expect(evidence.count == 1)
        // Every field is the observation's, and the row addresses the
        // observation so the canonical evidence screen can be opened.
        #expect(source.id == "obs-card")
        #expect(source.title == "CORNER SHOP")
        #expect(source.amount == Amount(minorUnits: -12_50, currencyCode: "EUR"))
        #expect(source.role == .bankMovement)
        #expect(source.role.label == "Bank movement")
    }

    @Test("A transaction nobody linked shows no source at all")
    func unlinkedTransactionFabricatesNothing() {
        let store = store(
            observations: [
                observation("obs-card", minorUnits: -12_50, merchant: "CORNER SHOP", day: 6)
            ],
            transactions: [expense("tx-shop", minorUnits: -12_50, day: 6)]
        )

        // The observation and the transaction agree about the money and the
        // day, and the merchant is the same shop. None of that is provenance,
        // and the app does not pretend otherwise.
        #expect(store.linkedEvidence(forTransaction: "tx-shop").isEmpty)
    }

    @Test("Resemblance is never promoted to a source once a real link exists")
    func matchingAmountsDoNotJoinTheLinkedRow() throws {
        let store = store(
            observations: [
                observation("obs-card", minorUnits: -12_50, merchant: "CORNER SHOP", day: 6),
                // Same money, same day, same shop, never linked to anything.
                observation("obs-twin", minorUnits: -12_50, merchant: "CORNER SHOP", day: 6)
            ],
            transactions: [expense("tx-shop", minorUnits: -12_50, day: 6)]
        )
        try store.matchObservation("obs-card", toTransaction: "tx-shop")
        let evidence = store.linkedEvidence(forTransaction: "tx-shop")

        // A fuzzy rule would have found two. The link found one.
        #expect(evidence.count == 1)
        #expect(evidence.first?.id == "obs-card")
        #expect(!evidence.contains { $0.id == "obs-twin" })
    }

    @Test("The row reads the observation, not the transaction")
    func metadataComesFromTheEvidence() throws {
        // The bank's own merchant text is the raw acquirer string, which is
        // not what the app calls this row. A source line built from the
        // transaction would be visibly the wrong one.
        let store = store(
            observations: [
                observation("obs-card", minorUnits: -12_50, merchant: "SUMUP *CORNER", day: 6)
            ],
            transactions: [expense("tx-shop", minorUnits: -12_50, day: 6)]
        )
        try store.matchObservation("obs-card", toTransaction: "tx-shop")
        let source = try #require(store.linkedEvidence(forTransaction: "tx-shop").first)
        // Required, not optional-chained: a missing row would make the
        // inequality below true for the wrong reason.
        let transactionRow = try #require(
            store.snapshot.activity.flatMap(\.rows).first { $0.id == "tx-shop" }
        )

        #expect(source.title == "SUMUP *CORNER")
        #expect(source.providerLabel.contains("Everyday bank"))
        // The two describe the same money and do not read the same, which is
        // the point of showing the evidence rather than restating the row.
        #expect(transactionRow.title != source.title)
    }

    // MARK: - More than one source

    @Test("Two observations of one movement are both shown")
    func multipleLinksAreReportedHonestly() throws {
        // Cross-provider review links a second observation to the same row.
        // The document permits it — an observation is held to one transaction,
        // a transaction is not held to one observation — so a caller that took
        // the first would hide half the answer.
        let store = store(
            observations: [
                observation("obs-card", minorUnits: -12_50, merchant: "CORNER SHOP", day: 6),
                observation("obs-wallet", minorUnits: -12_50, merchant: "WALLET TOPUP", day: 5)
            ],
            transactions: [expense("tx-shop", minorUnits: -12_50, day: 6)]
        )
        try store.matchObservation("obs-card", toTransaction: "tx-shop")
        try store.matchObservation("obs-wallet", toTransaction: "tx-shop")
        let evidence = store.linkedEvidence(forTransaction: "tx-shop")

        #expect(evidence.count == 2)
        #expect(Set(evidence.map(\.id)) == ["obs-card", "obs-wallet"])
        // The bank's record of the money leads, and the order is the same on
        // every read rather than the hash seed's choice.
        #expect(evidence.first?.role == .bankMovement)
        #expect(store.linkedEvidence(forTransaction: "tx-shop").map(\.id) == evidence.map(\.id))
    }

    @Test("Evidence belongs to the transaction it names and to no other")
    func unrelatedTransactionsAreUnaffected() throws {
        let store = store(
            observations: [
                observation("obs-card", minorUnits: -12_50, merchant: "CORNER SHOP", day: 6)
            ],
            transactions: [
                expense("tx-shop", minorUnits: -12_50, day: 6),
                expense("tx-other", minorUnits: -12_50, day: 6)
            ]
        )
        try store.matchObservation("obs-card", toTransaction: "tx-shop")

        #expect(store.linkedEvidence(forTransaction: "tx-shop").count == 1)
        #expect(store.linkedEvidence(forTransaction: "tx-other").isEmpty)
        #expect(store.linkedEvidence(forTransaction: "tx-missing").isEmpty)
    }

    // MARK: - Reading provenance decides nothing

    @Test("Looking at the source leaves the evidence exactly as it was")
    func readingProvenanceMutatesNothing() throws {
        let store = try linkedStore()
        let before = store.snapshot.syncedObservations.first { $0.id == "obs-card" }
        let beforeRows = store.snapshot.activity.flatMap(\.rows)
        let beforeEvidence = store.linkedEvidence(forTransaction: "tx-shop")

        _ = store.linkedEvidence(forTransaction: "tx-shop")
        _ = store.linkedEvidence(forTransaction: "tx-shop")

        let after = store.snapshot.syncedObservations.first { $0.id == "obs-card" }
        #expect(before == after)
        // Resolved evidence stays resolved. Reaching it from a transaction is
        // not a reason to ask the question again.
        #expect(after?.resolution == .linked)
        #expect(after?.resolution != .unreviewed)
        #expect(store.snapshot.activity.flatMap(\.rows) == beforeRows)
        #expect(store.linkedEvidence(forTransaction: "tx-shop") == beforeEvidence)
        #expect(store.removalBlocker(forTransaction: "tx-shop") == .linkedToBankEvidence)
    }

    @Test("Linked evidence is resolved by the document's own rule")
    func aLinkImpliesAResolvedObservation() throws {
        let store = try linkedStore()
        let observation = try #require(
            store.snapshot.syncedObservations.first { $0.id == "obs-card" }
        )

        // `validate` holds links and `linkedToTransaction` to each other, so
        // anything reachable as provenance has already been decided. Nothing
        // in the UI needs a second flag to know that.
        #expect(observation.resolution == .linked)
        #expect(observation.resolution.isResolved)
        // Unreviewed evidence keeps its own screen and its own actions; it is
        // simply never reachable from a transaction, because it has no link.
        #expect(store.linkedEvidence(forTransaction: "tx-shop").count == 1)
    }

    // MARK: - Failing safely

    @Test("No source row is ever half-rendered")
    func everyRowIsFullyBackedByEvidence() throws {
        let store = try linkedStore()
        let evidence = store.linkedEvidence(forTransaction: "tx-shop")

        // A link carries identifiers and nothing a person could read, so a row
        // has to come from the observation it names. `validate` refuses a link
        // to an unknown observation, and the mapping drops any that does not
        // reach the surface — between them, a row with an empty merchant or an
        // empty provider cannot be produced.
        #expect(!evidence.isEmpty)
        for row in evidence {
            #expect(!row.title.isEmpty)
            #expect(!row.providerLabel.isEmpty)
            #expect(store.snapshot.syncedObservations.contains { $0.id == row.id })
        }
    }

    @Test("A transaction that is not there answers with nothing")
    func missingTransactionFailsSafely() throws {
        let store = try linkedStore()
        #expect(store.linkedEvidence(forTransaction: "tx-never-existed").isEmpty)
        #expect(store.linkedEvidence(forTransaction: "").isEmpty)
    }

    // MARK: - Removal

    @Test("The source section explains the removal blocker without weakening it")
    func removalStaysBlockedAndNowHasAnExplanation() throws {
        let store = try linkedStore()

        // Unchanged: linked bank evidence still refuses removal, and reading
        // the provenance does not unlink anything to make it possible.
        #expect(store.removalBlocker(forTransaction: "tx-shop") == .linkedToBankEvidence)
        #expect(!store.linkedEvidence(forTransaction: "tx-shop").isEmpty)

        #expect(throws: AppRemovalError.self) {
            try store.deleteActivityRow(id: "tx-shop")
        }
        // The row and its evidence both survive the refusal: nothing was
        // unlinked to make the deletion possible.
        #expect(store.snapshot.activity.flatMap(\.rows).contains { $0.id == "tx-shop" })
        #expect(store.linkedEvidence(forTransaction: "tx-shop").count == 1)
    }

    @Test("A transaction with no evidence is still removable")
    func unlinkedTransactionsKeepTheirRemoval() throws {
        let store = store(
            observations: [],
            transactions: [expense("tx-shop", minorUnits: -12_50, day: 6)]
        )
        #expect(store.removalBlocker(forTransaction: "tx-shop") == nil)
        #expect(store.linkedEvidence(forTransaction: "tx-shop").isEmpty)

        try store.deleteActivityRow(id: "tx-shop")
        #expect(!store.snapshot.activity.flatMap(\.rows).contains { $0.id == "tx-shop" })
    }

    // MARK: - The round trip

    @Test("Resolving quiets the queue and leaves the transaction able to explain itself")
    func theQueueEmptiesAndTheProvenanceRemains() throws {
        let store = store(
            observations: [
                observation("obs-card", minorUnits: -12_50, merchant: "CORNER SHOP", day: 6)
            ],
            transactions: [expense("tx-shop", minorUnits: -12_50, day: 6)]
        )
        // Before: the evidence is work, and the transaction explains nothing.
        #expect(store.attentionPresentation.activity.decisions.contains { $0.id == "obs-card" })
        #expect(store.linkedEvidence(forTransaction: "tx-shop").isEmpty)

        try store.matchObservation("obs-card", toTransaction: "tx-shop")

        // After: the queue is quiet, and the same evidence is inspectable from
        // the row it was decided to mean.
        #expect(!store.attentionPresentation.activity.decisions.contains { $0.id == "obs-card" })
        #expect(store.linkedEvidence(forTransaction: "tx-shop").count == 1)
    }
}
