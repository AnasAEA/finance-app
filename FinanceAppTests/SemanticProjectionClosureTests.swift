import FinanceCore
import Foundation
import Testing
@testable import FinanceApp

/// Synthetic, round-tripped documents through the production request, mapper
/// and attention composition. The oracle never reads projected facts.
/// The first four tests were run before production changes at ea2d380:
/// all four failed projection inequality (five issues including restoration).
struct SemanticProjectionClosureTests {
    private func day(_ s: String) -> Day { Day(isoString: s)! }
    private func money(_ n: Int64) -> Money { Money(minorUnits: n, currency: .eur) }
    private var month: MonthKey { MonthKey(year: 2026, month: 8) }
    private var period: ReviewInterval { .month(month) }
    private var asOf: Day { day("2026-09-01") }
    private var line: BudgetAllocation {
        BudgetAllocation(id: "budget", name: "Synthetic line", spendingClass: .flexible,
                         monthlyAmount: money(20_000), effectiveFrom: month,
                         categoryKeys: ["food"])
    }
    private func tx(_ id: String, _ date: String = "2026-08-15", amount: Int64 = -1_000,
                    kind: TransactionKind = .expense, lifecycle: TransactionLifecycle = .cleared,
                    linked: String? = nil, note: String? = nil) -> Transaction {
        Transaction(id: id, date: day(date), kind: kind,
                    legs: [AccountLeg(accountID: "bank", amount: money(amount))],
                    linkedTransactionID: linked, factivity: .observed,
                    lifecycle: lifecycle, note: note)
    }
    private func doc(_ transactions: [Transaction], budgets: [BudgetAllocation] = []) -> FinanceDocument {
        FinanceDocument(schemaVersion: Interchange.currentSchemaVersion, documentKind: "TEST",
                        accounts: [Account(id: "bank", name: "Synthetic bank", currency: .eur,
                                           kind: .bank, supportedRails: PaymentRail.euroBankRails, drawOrder: 0)],
                        balances: [AccountBalance(accountID: "bank", balance: money(100_000), asOf: day("2026-01-01"))],
                        transactions: transactions,
                        planning: FinanceDocument.Planning(defaultScenario: .base, budgets: budgets))
    }
    private struct Outcome {
        let projection: SemanticPeriodProjection
        let spending: Money
        let uncategorized: Money
        let attributions: [MonthlyBudgetEngine.Attribution]
        let exceptions: [PeriodCheckpointException]
        let claims: PeriodCheckpointSafeClaims
        let evidence: [EvidenceRelationship]
        func differs(from other: Outcome) -> Bool {
            spending != other.spending || uncategorized != other.uncategorized
                || attributions != other.attributions || exceptions != other.exceptions
                || claims != other.claims || evidence != other.evidence
        }
    }
    private struct EvidenceRelationship: Equatable {
        let observationID: String
        let transactionID: String
        let role: ExternalEvidenceRole
    }
    private func outcome(_ document: FinanceDocument, categories: [String: String] = [:],
                         merchant: String? = nil, widerCoverage: Bool = false) throws -> Outcome {
        let document = try Interchange.decode(Interchange.encode(document))
        try ExternalEvidenceReview.validate(document)
        let coverage = ReviewCoverageInput(liveCoveredIntervals: [widerCoverage
            ? ReviewInterval(start: day("2026-01-01"), end: asOf) : period])
        let request = try #require(ReviewRequestBuilder.makeRequest(
            document: document, selection: ReviewPeriodSelection(scope: .month, offset: -1),
            asOf: asOf, categoryKeys: categories, incomeSources: document.incomeSources,
            coverage: coverage))
        let review = try ReviewEngine.review(request)
        let presentation = Dictionary(uniqueKeysWithValues: document.transactions.map {
            ($0.id, DomainMapper.TransactionPresentation(categoryKey: categories[$0.id], merchant: merchant))
        })
        let observations = DomainMapper().bankingSurface(document: document, transactionPresentation: presentation).observations
        let occurrences = OccurrenceExpander.occurrences(in: document, from: period.start, to: period.end,
            asOf: asOf, ledger: ReconciliationLedger(document.planning.settlements))
        let readiness = AttentionComposition.readiness(for: AttentionComposition.Input(
            document: document, asOf: asOf, review: review, occurrences: occurrences,
            observations: observations, categoryKeys: categories, period: period))
        let projection = try #require(readiness.projection)
        let acknowledged = PeriodCheckpointEvaluator.evaluate(PeriodCheckpointRequest(
            period: period, kind: .monthly, asOf: asOf, review: review,
            exceptions: readiness.exceptions,
            confirmedAcknowledgments: try PeriodCheckpointAcknowledgmentConfirmation.confirm(
                decisions: readiness.exceptions, carriedExceptions: readiness.exceptions
            ),
            projection: projection, requiresSemanticProjection: true))
        #expect(review.coverage.status == .complete)
        #expect(acknowledged.disposition.isReady)
        // Independent existing authority, not the semantic adapter under test.
        let attributions = MonthlyBudgetEngine.attributions(month: month, document: document,
            lines: document.planning.budgets.filter { $0.amount(for: month) != nil },
            ledger: ReconciliationLedger(document.planning.settlements), categoryKeys: categories)
        #expect(review.budget.attributions == attributions)
        // Evidence audit meaning includes which actual an observation supports,
        // even when both actuals happen to have identical economics. Read the
        // existing evidence model, never the projection's evidence facts.
        let periodObservationIDs = Set(document.externalObservations.filter {
            $0.economicPeriodDay.map { period.contains($0) } ?? false
        }.map(\.id))
        let evidence = document.externalEvidenceLinks.filter { periodObservationIDs.contains($0.observationID) }
            .sorted { ($0.observationID, $0.transactionID, $0.role.rawValue)
                < ($1.observationID, $1.transactionID, $1.role.rawValue) }
            .map { EvidenceRelationship(observationID: $0.observationID, transactionID: $0.transactionID, role: $0.role) }
        return Outcome(projection: projection, spending: review.budget.periodEconomicSpending,
            uncategorized: review.budget.uncategorized, attributions: attributions,
            exceptions: readiness.exceptions, claims: readiness.safeClaims, evidence: evidence)
    }
    private func assertClosure(_ a: Outcome, _ b: Outcome, sourceLocation: SourceLocation = #_sourceLocation) {
        let changed = a.differs(from: b)
        #expect(changed, "mutation must change the independent oracle", sourceLocation: sourceLocation)
        if changed { #expect(a.projection != b.projection, sourceLocation: sourceLocation) }
    }

    @Test("Closure: removing and restoring the claiming budget line")
    func budgetLineRemoval() throws {
        let categories = ["expense": "food"]
        let categorized = try outcome(doc([tx("expense")], budgets: [line]), categories: categories)
        let uncategorized = try outcome(doc([tx("expense")]), categories: categories)
        #expect(categorized.exceptions.isEmpty)
        #expect(uncategorized.exceptions.map(\.kind) == [.uncategorizedEconomicSpending])
        assertClosure(categorized, uncategorized)
        assertClosure(uncategorized, categorized)
    }
    @Test("Closure: refund relink between cleared and reversed originals")
    func refundRelink() throws {
        let originals = [tx("cleared", "2026-07-28"), tx("reversed", "2026-07-28", lifecycle: .reversed)]
        let before = try outcome(doc(originals + [tx("refund", "2026-08-01", amount: 1_000, kind: .refund, linked: "cleared")]))
        let after = try outcome(doc(originals + [tx("refund", "2026-08-01", amount: 1_000, kind: .refund, linked: "reversed")]))
        #expect(before.spending == money(-1_000))
        #expect(after.spending == money(0))
        assertClosure(before, after)
    }
    @Test("Closure: cross-period original lifecycle changes refund treatment")
    func originalLifecycle() throws {
        let refund = tx("refund", "2026-08-01", amount: 1_000, kind: .refund, linked: "original")
        assertClosure(try outcome(doc([tx("original", "2026-07-28"), refund])),
                      try outcome(doc([tx("original", "2026-07-28", lifecycle: .reversed), refund])))
    }
    @Test("Closure: cross-period original recategorization changes refund attribution")
    func originalRecategorization() throws {
        let document = doc([tx("original", "2026-07-28"),
                            tx("refund", "2026-08-01", amount: 1_000, kind: .refund, linked: "original")], budgets: [line])
        assertClosure(try outcome(document, categories: ["original": "food"]), try outcome(document))
    }

    @Test("Closure: changing category membership without changing transaction categories")
    func categoryMembership() throws {
        var unclaimed = line
        unclaimed.categoryKeys = []
        let a = try outcome(doc([tx("expense")], budgets: [line]), categories: ["expense": "food"])
        let b = try outcome(doc([tx("expense")], budgets: [unclaimed]), categories: ["expense": "food"])
        assertClosure(a, b)
        assertClosure(b, a)
    }

    private func observation(identity: ExternalObservationIdentity = .durable,
                             status: ExternalObservationStatus = .booked, eligible: Bool = true,
                             amount: Int64 = -1_000, date: String = "2026-08-15",
                             clock: Double = 1_000, id: String = "observation") -> ExternalObservation {
        ExternalObservation(id: id, bindingID: "binding", provider: .bnp, identity: identity,
            status: status, creditDebitIndicator: .debit, amount: money(amount), bookingDate: day(date),
            eligibleForEconomicActual: eligible, observedAt: Date(timeIntervalSince1970: clock))
    }
    private func evidenceDoc(_ observation: ExternalObservation,
                             resolution: ObservationResolutionState = .noEconomicEffect,
                             transactions: [Transaction] = []) -> FinanceDocument {
        var document = doc(transactions)
        document.externalAccountBindings = [ExternalAccountBinding(id: "binding", provider: .bnp,
            remoteOpaqueAccountID: "synthetic-remote", localAccountID: "bank",
            syncStartBoundary: day("2026-01-01"), createdAt: Date(timeIntervalSince1970: 0))]
        document.externalObservations = [observation]
        document.observationResolutions = [ExternalObservationResolution(observationID: observation.id, state: resolution)]
        return document
    }

    enum EvidenceMutation: CaseIterable { case eligibility, identity, binding, resolution }
    @Test("Closure: provider, binding and resolution state", arguments: EvidenceMutation.allCases)
    func evidenceState(_ mutation: EvidenceMutation) throws {
        var before = evidenceDoc(observation())
        var after = before
        switch mutation {
        case .eligibility:
            after.externalObservations = [observation(eligible: false)]
        case .identity:
            after.externalObservations = [observation(identity: .provisionalSnapshot)]
        case .binding:
            before.observationResolutions[0].state = .unreviewed
            after = before
            after.externalAccountBindings[0].isActive = false
        case .resolution:
            before.observationResolutions[0].state = .unreviewed
        }
        assertClosure(try outcome(before), try outcome(after))
    }

    @Test("Closure: evidence relationship alone, with identical unchanged transactions")
    func isolatedEvidenceRelationship() throws {
        var before = evidenceDoc(observation(), resolution: .linkedToTransaction,
                                 transactions: [tx("actual-a"), tx("actual-b")])
        before.externalEvidenceLinks = [ExternalEvidenceLink(id: "link", observationID: "observation",
                                                             transactionID: "actual-a", role: .accountMovement)]
        var after = before
        after.externalEvidenceLinks = [ExternalEvidenceLink(id: "link", observationID: "observation",
                                                            transactionID: "actual-b", role: .accountMovement)]
        #expect(before.transactions == after.transactions)
        let a = try outcome(before), b = try outcome(after)
        #expect(a.spending == b.spending && a.attributions == b.attributions)
        #expect(a.exceptions == b.exceptions && a.claims == b.claims)
        assertClosure(a, b)
    }

    @Test("Closure: dissolving a cross-period aggregate changes the observation period")
    func aggregateRelationship() throws {
        let observation = observation(amount: -3_000, date: "2026-08-31")
        let before = evidenceDoc(observation, resolution: .unreviewed,
            transactions: [tx("part-a", "2026-09-02"), tx("part-b", "2026-09-03", amount: -2_000)])
        var after = before
        after.transactions = [tx("part-a", "2026-09-02"),
                              tx("part-b", "2026-09-03", amount: -2_000, lifecycle: .reversed)]
        let a = try outcome(before), b = try outcome(after)
        #expect(a.exceptions.contains { $0.kind == .aggregateEvidenceModelLimitation })
        #expect(!b.exceptions.contains { $0.kind == .aggregateEvidenceModelLimitation })
        #expect(a.projection.transactions == b.projection.transactions)
        assertClosure(a, b)
    }

    private func assertStable(_ a: Outcome, _ b: Outcome, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!a.differs(from: b), "negative control must preserve the independent oracle", sourceLocation: sourceLocation)
        #expect(a.projection == b.projection, sourceLocation: sourceLocation)
    }
    enum Noise: CaseIterable { case merchant, originalNote, refundNote, order, clocks, pending, coverage, budgetName }
    @Test("Noise: resolved meaning is unchanged", arguments: Noise.allCases)
    func noise(_ noise: Noise) throws {
        var before = evidenceDoc(observation(), transactions: [tx("original", "2026-07-28"),
            tx("refund", "2026-08-01", amount: 1_000, kind: .refund, linked: "original"), tx("expense")])
        before.planning.budgets = [line]
        let categories = ["original": "food", "expense": "food"]
        var after = before
        switch noise {
        case .merchant, .coverage: break
        case .originalNote:
            after.transactions[0] = tx("original", "2026-07-28", note: "Different synthetic free text")
        case .refundNote:
            after.transactions[1] = tx("refund", "2026-08-01", amount: 1_000, kind: .refund,
                                       linked: "original", note: "Different synthetic note")
        case .order:
            after.transactions.reverse()
        case .clocks:
            after.externalObservations = [observation(clock: 20_000)]
            after.observationResolutions[0].resolvedAt = Date(timeIntervalSince1970: 30_000)
        case .pending:
            for run in 1...3 {
                let id = "pend_run_\(run)"
                after.externalObservations.append(observation(identity: .provisionalSnapshot,
                    status: .pending, eligible: false, clock: Double(run * 5_000), id: id))
                after.observationResolutions.append(ExternalObservationResolution(observationID: id, state: .provisional))
            }
        case .budgetName:
            // MonthlyBudgetEngine matches only IDs/categories/settlements;
            // Review's category exception reads uncategorized, never a name.
            after.planning.budgets[0].name = "Renamed presentation only"
        }
        assertStable(try outcome(before, categories: categories),
                     try outcome(after, categories: categories,
                                 merchant: noise == .merchant ? "Synthetic merchant enrichment" : nil,
                                 widerCoverage: noise == .coverage))
    }
}
