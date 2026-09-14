import Foundation

/// Reconciliation of **expected occurrences** against **actual transactions**.
///
/// Three things are deliberately kept apart, because collapsing any two of
/// them is how one real payment gets counted twice:
///
/// | layer | example | lives in |
/// |---|---|---|
/// | recurring **rule** | "YouTube Premium, monthly, day 26" | `RecurringObligation` |
/// | expected **occurrence** | "the August one, expected 26 Aug" | expanded, never stored |
/// | **actual** transaction | "€7.99 left BNP on the bank's date" | `Transaction` (observed) |
///
/// An actual settles **one occurrence**, never the rule. The rule keeps
/// producing future occurrences; settling August says nothing about September.
///
/// An occurrence has no stored identity of its own — it is a pure function of
/// the rule and the calendar. Its identity is therefore the pair
/// `(obligationID, expectedDay)`, and that pair is what a settlement records.
/// The expected day is the *planned or inferred* day and is never overwritten
/// by the actual transaction's date: an inferred date is a guess, an observed
/// date is evidence, and the two are kept in different places precisely so
/// that neither can quietly become the other.
public struct OccurrenceID: Hashable, Sendable, Codable, CustomStringConvertible {

    public let obligationID: String

    /// The occurrence's own planned/inferred day. Identity, not evidence.
    public let expectedDay: Day

    public init(obligationID: String, expectedDay: Day) {
        self.obligationID = obligationID
        self.expectedDay = expectedDay
    }

    public var description: String { "\(obligationID)@\(expectedDay.isoString)" }
}

/// How one expected occurrence was resolved.
///
/// All three stop the occurrence being forecast as a future outflow, and none
/// of them touches the recurring rule.
public enum OccurrenceResolution: String, Sendable, Codable, CaseIterable {

    /// An observed actual transaction settled it. The money really moved, and
    /// the movement is already carried by that transaction.
    case paid

    /// Deliberately not paid this cycle. No money moves and none is expected
    /// to. The rule stays active and next month is unaffected.
    case skipped

    /// The charge is not coming at all (cancelled mid-cycle, waived, the
    /// provider did not bill). Distinct from `skipped`, which is a decision
    /// the account holder made rather than one the world made.
    case noLongerDue
}

/// The record that one expected occurrence has been resolved.
///
/// Deliberately **not** a mutation of the obligation: cancelling or editing a
/// rule later must not rewrite what was already reconciled, so settlements are
/// their own rows keyed by stable ids.
public struct ObligationSettlement: Identifiable, Hashable, Sendable, Codable {

    public let id: String

    /// The recurring rule whose occurrence this settles.
    public let obligationID: String

    /// The occurrence's planned/inferred day — its identity. Never the actual
    /// transaction's date.
    public let expectedDay: Day

    public let resolution: OccurrenceResolution

    /// The observed transaction that settled it. Present iff `.paid`; the
    /// actual **date** is read from that transaction, never copied here, so
    /// the two dates cannot drift apart.
    public let actualTransactionID: String?

    /// Set when the amounts differ and a person accepted the difference
    /// anyway. Never set implicitly — an inexact match is only ever a
    /// deliberate act (see `MatchCandidate.requiresAmountConfirmation`).
    public let acceptedAmountDifference: Bool

    public let note: String?
    public let provenance: Provenance

    /// The occurrence this settlement resolves.
    public var occurrence: OccurrenceID {
        OccurrenceID(obligationID: obligationID, expectedDay: expectedDay)
    }

    public init(
        id: String,
        obligationID: String,
        expectedDay: Day,
        resolution: OccurrenceResolution,
        actualTransactionID: String? = nil,
        acceptedAmountDifference: Bool = false,
        note: String? = nil,
        provenance: Provenance = .devFixture
    ) {
        self.id = id
        self.obligationID = obligationID
        self.expectedDay = expectedDay
        self.resolution = resolution
        self.actualTransactionID = actualTransactionID
        self.acceptedAmountDifference = acceptedAmountDifference
        self.note = note
        self.provenance = provenance

        precondition(
            resolution != .paid || actualTransactionID != nil,
            "a paid settlement must name the actual transaction that paid it"
        )
        precondition(
            resolution == .paid || actualTransactionID == nil,
            "only a paid settlement may name an actual transaction"
        )
    }

    // MARK: - Factories
    //
    // The app only ever builds settlements through these, so the invariants
    // above are structural rather than a runtime hazard: `.paid` cannot be
    // expressed without a transaction id, and the other two cannot carry one.

    public static func paid(
        id: String,
        obligationID: String,
        expectedDay: Day,
        actualTransactionID: String,
        acceptedAmountDifference: Bool = false,
        note: String? = nil,
        provenance: Provenance = .devFixture
    ) -> ObligationSettlement {
        ObligationSettlement(
            id: id,
            obligationID: obligationID,
            expectedDay: expectedDay,
            resolution: .paid,
            actualTransactionID: actualTransactionID,
            acceptedAmountDifference: acceptedAmountDifference,
            note: note,
            provenance: provenance
        )
    }

    public static func skipped(
        id: String,
        obligationID: String,
        expectedDay: Day,
        note: String? = nil,
        provenance: Provenance = .devFixture
    ) -> ObligationSettlement {
        ObligationSettlement(
            id: id, obligationID: obligationID, expectedDay: expectedDay,
            resolution: .skipped, note: note, provenance: provenance
        )
    }

    public static func noLongerDue(
        id: String,
        obligationID: String,
        expectedDay: Day,
        note: String? = nil,
        provenance: Provenance = .devFixture
    ) -> ObligationSettlement {
        ObligationSettlement(
            id: id, obligationID: obligationID, expectedDay: expectedDay,
            resolution: .noLongerDue, note: note, provenance: provenance
        )
    }

    // MARK: - Codable
    //
    // Interchange input is untrusted, so the invariants that are preconditions
    // above are decoding errors here (the same split `Transaction` uses).

    private enum CodingKeys: String, CodingKey {
        case id, obligationID, expectedDay, resolution
        case actualTransactionID, acceptedAmountDifference, note, provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.obligationID = try container.decode(String.self, forKey: .obligationID)
        self.expectedDay = try container.decode(Day.self, forKey: .expectedDay)
        self.resolution = try container.decode(OccurrenceResolution.self, forKey: .resolution)
        self.actualTransactionID = try container.decodeIfPresent(String.self, forKey: .actualTransactionID)
        self.acceptedAmountDifference =
            try container.decodeIfPresent(Bool.self, forKey: .acceptedAmountDifference) ?? false
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
        self.provenance = try container.decode(Provenance.self, forKey: .provenance)

        if resolution == .paid, actualTransactionID == nil {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "settlement '\(id)': paid without an actual transaction id")
            )
        }
        if resolution != .paid, actualTransactionID != nil {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "settlement '\(id)': \(resolution.rawValue) must not name an actual transaction")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(obligationID, forKey: .obligationID)
        try container.encode(expectedDay, forKey: .expectedDay)
        try container.encode(resolution, forKey: .resolution)
        try container.encodeIfPresent(actualTransactionID, forKey: .actualTransactionID)
        try container.encode(acceptedAmountDifference, forKey: .acceptedAmountDifference)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(provenance, forKey: .provenance)
    }
}

/// Why a reconciliation was refused.
///
/// Reconciliation is conservative by construction: anything ambiguous is an
/// error a person resolves, never a guess the model makes.
public enum ReconciliationError: Error, Hashable, Sendable, CustomStringConvertible {

    case duplicateSettlementID(String)

    /// Test 9: an occurrence already resolved cannot be resolved again. There
    /// are no partial-payment semantics in this phase, so two actuals against
    /// one occurrence is rejected rather than silently summed.
    case occurrenceAlreadyResolved(obligationID: String, expectedDay: Day, existingSettlementID: String)

    /// Test 8: one actual cannot settle two occurrences.
    case actualAlreadyReconciled(transactionID: String, existingSettlementID: String)

    case unknownObligation(settlementID: String, obligationID: String)
    case unknownTransaction(settlementID: String, transactionID: String)

    /// Only an observed fact can settle an expectation. An expected
    /// transaction settling an expected occurrence would be a plan agreeing
    /// with itself.
    case actualIsNotObserved(transactionID: String)

    /// A reversed debit never economically happened, so it settles nothing.
    case actualIsReversed(transactionID: String)

    /// The settled day is not one the rule actually produces. Prevents
    /// settlements attaching to occurrences that never existed.
    case notAnOccurrenceOfRule(obligationID: String, expectedDay: Day)

    /// Test 7: currencies never match implicitly.
    case currencyMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case let .duplicateSettlementID(id):
            return "duplicate settlement id '\(id)'"
        case let .occurrenceAlreadyResolved(obligation, day, existing):
            return "occurrence \(obligation)@\(day.isoString) is already resolved by settlement '\(existing)'"
        case let .actualAlreadyReconciled(transaction, existing):
            return "transaction '\(transaction)' already settles an occurrence via settlement '\(existing)'"
        case let .unknownObligation(settlement, obligation):
            return "settlement '\(settlement)' references unknown obligation '\(obligation)'"
        case let .unknownTransaction(settlement, transaction):
            return "settlement '\(settlement)' references unknown transaction '\(transaction)'"
        case let .actualIsNotObserved(transaction):
            return "transaction '\(transaction)' is not an observed fact and cannot settle an expectation"
        case let .actualIsReversed(transaction):
            return "transaction '\(transaction)' is reversed and settles nothing"
        case let .notAnOccurrenceOfRule(obligation, day):
            return "\(day.isoString) is not an occurrence of rule '\(obligation)'"
        case let .currencyMismatch(expected, actual):
            return "expected \(expected) cannot be settled by an actual in \(actual)"
        }
    }
}

/// Indexed, deterministic access to a document's settlements.
///
/// Construction is total and never throws: the forecast must compose from
/// whatever is stored, and a lookup structure is not the place to reject data.
/// Rule enforcement lives in `validate(_:against:)`, which runs where new
/// reconciliations are *made* (app writes) and where untrusted documents are
/// *read* (import).
///
/// Determinism: when duplicates exist despite validation, the settlement with
/// the lowest id wins, so the same stored rows always produce the same
/// forecast on every machine.
public struct ReconciliationLedger: Hashable, Sendable {

    public let settlements: [ObligationSettlement]

    private let byOccurrence: [OccurrenceID: ObligationSettlement]
    private let byTransaction: [String: ObligationSettlement]

    public init(_ settlements: [ObligationSettlement] = []) {
        let ordered = settlements.sorted { $0.id < $1.id }
        self.settlements = ordered
        self.byOccurrence = Dictionary(
            ordered.map { ($0.occurrence, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.byTransaction = Dictionary(
            ordered.compactMap { settlement in
                settlement.actualTransactionID.map { ($0, settlement) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public func settlement(for occurrence: OccurrenceID) -> ObligationSettlement? {
        byOccurrence[occurrence]
    }

    public func settlement(forActual transactionID: String) -> ObligationSettlement? {
        byTransaction[transactionID]
    }

    /// Whether this occurrence is resolved, and therefore contributes no
    /// forecast outflow. True for every resolution — paid, skipped and no
    /// longer due all mean "no money is expected to leave for this one".
    public func isResolved(obligationID: String, day: Day) -> Bool {
        byOccurrence[OccurrenceID(obligationID: obligationID, expectedDay: day)] != nil
    }

    public var isEmpty: Bool { settlements.isEmpty }

    // MARK: - Validation

    /// Enforces the reconciliation rules against a document.
    ///
    /// Called where reconciliations are created and where documents are
    /// imported — never from the forecast path, which must stay total.
    public static func validate(
        _ settlements: [ObligationSettlement],
        against document: FinanceDocument
    ) throws {
        let obligations = Dictionary(
            document.planning.recurringObligations.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let transactions = Dictionary(
            document.transactions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var seenIDs = Set<String>()
        var seenOccurrences = [OccurrenceID: String]()
        var seenTransactions = [String: String]()

        for settlement in settlements.sorted(by: { $0.id < $1.id }) {
            guard seenIDs.insert(settlement.id).inserted else {
                throw ReconciliationError.duplicateSettlementID(settlement.id)
            }

            if let existing = seenOccurrences[settlement.occurrence] {
                throw ReconciliationError.occurrenceAlreadyResolved(
                    obligationID: settlement.obligationID,
                    expectedDay: settlement.expectedDay,
                    existingSettlementID: existing
                )
            }
            seenOccurrences[settlement.occurrence] = settlement.id

            guard let obligation = obligations[settlement.obligationID] else {
                throw ReconciliationError.unknownObligation(
                    settlementID: settlement.id, obligationID: settlement.obligationID
                )
            }

            // The day must be one the rule actually produces. Checked over the
            // occurrence's own month so a cancelled/limited rule still
            // validates its historical settlements (test 12).
            let month = settlement.expectedDay.monthKey
            let produced = obligation.spec.occurrences(
                from: month.firstDay, to: month.firstDay.lastDayOfMonth
            )
            guard produced.contains(settlement.expectedDay) else {
                throw ReconciliationError.notAnOccurrenceOfRule(
                    obligationID: settlement.obligationID, expectedDay: settlement.expectedDay
                )
            }

            guard let actualID = settlement.actualTransactionID else { continue }

            if let existing = seenTransactions[actualID] {
                throw ReconciliationError.actualAlreadyReconciled(
                    transactionID: actualID, existingSettlementID: existing
                )
            }
            seenTransactions[actualID] = settlement.id

            guard let actual = transactions[actualID] else {
                throw ReconciliationError.unknownTransaction(
                    settlementID: settlement.id, transactionID: actualID
                )
            }
            guard actual.factivity == .observed else {
                throw ReconciliationError.actualIsNotObserved(transactionID: actualID)
            }
            guard actual.lifecycle != .reversed else {
                throw ReconciliationError.actualIsReversed(transactionID: actualID)
            }

            // Currency is never bridged implicitly: an MAD cash expense can
            // never settle a EUR subscription, however close the numbers look.
            let actualCurrencies = Set(actual.legs.map(\.amount.currency))
            guard actualCurrencies.contains(obligation.amount.currency) else {
                throw ReconciliationError.currencyMismatch(
                    expected: obligation.amount.currency.code,
                    actual: actualCurrencies.map(\.code).sorted().joined(separator: "+")
                )
            }
        }
    }
}

// MARK: - Expanding rules into occurrences

/// Where one expected occurrence stands right now.
public enum OccurrenceStatus: Hashable, Sendable {

    /// Not yet due, not yet resolved.
    case due

    /// Its day has passed and nothing settled it. Stays visible: an
    /// unreconciled occurrence is a question, never an assumption that it was
    /// paid (and never an assumption that it was not).
    case overdue

    /// Settled by an observed transaction.
    case paid(actualTransactionID: String)

    case skipped
    case noLongerDue

    /// Whether the forecast should stop treating this as a future outflow.
    public var suppressesForecast: Bool {
        switch self {
        case .due, .overdue: return false
        case .paid, .skipped, .noLongerDue: return true
        }
    }

    public var isResolved: Bool { suppressesForecast }
}

/// One dated instance of a recurring rule, with its current standing.
///
/// Expanded on demand and never stored: the rule and the calendar are the
/// truth, and materialising occurrences would create a second place for them
/// to disagree.
public struct ExpectedOccurrence: Identifiable, Hashable, Sendable {

    public var id: OccurrenceID { OccurrenceID(obligationID: obligationID, expectedDay: expectedDay) }

    public let obligationID: String
    public let name: String

    /// Planned/inferred day. Evidence for what actually happened lives on the
    /// actual transaction, reachable through `status`.
    public let expectedDay: Day

    public let amount: Money
    public let requirement: PaymentRequirement
    public let spendingClass: SpendingClass
    public let status: OccurrenceStatus

    public init(
        obligationID: String,
        name: String,
        expectedDay: Day,
        amount: Money,
        requirement: PaymentRequirement,
        spendingClass: SpendingClass,
        status: OccurrenceStatus
    ) {
        self.obligationID = obligationID
        self.name = name
        self.expectedDay = expectedDay
        self.amount = amount
        self.requirement = requirement
        self.spendingClass = spendingClass
        self.status = status
    }

    public var settledTransactionID: String? {
        if case let .paid(id) = status { return id }
        return nil
    }
}

/// Expands recurring rules into dated occurrences and applies settlements.
public enum OccurrenceExpander {

    /// Every occurrence of every **committed** rule in `[start, end]`, with the
    /// standing each one currently has.
    ///
    /// Hypothetical rules are skipped for the same reason the composer skips
    /// them: they are explorations, and an exploration has nothing to
    /// reconcile.
    public static func occurrences(
        in document: FinanceDocument,
        from start: Day,
        to end: Day,
        asOf today: Day,
        ledger: ReconciliationLedger? = nil
    ) -> [ExpectedOccurrence] {
        let ledger = ledger ?? ReconciliationLedger(document.planning.settlements)
        var result: [ExpectedOccurrence] = []

        for obligation in document.planning.recurringObligations.sorted(by: { $0.id < $1.id })
        where obligation.commitmentStatus == .committed {
            for day in obligation.spec.occurrences(from: start, to: end) {
                let key = OccurrenceID(obligationID: obligation.id, expectedDay: day)
                let status: OccurrenceStatus
                switch ledger.settlement(for: key)?.resolution {
                case .paid:
                    // The id is guaranteed by the settlement's own invariant.
                    status = .paid(actualTransactionID: ledger.settlement(for: key)?.actualTransactionID ?? "")
                case .skipped:
                    status = .skipped
                case .noLongerDue:
                    status = .noLongerDue
                case nil:
                    status = day < today ? .overdue : .due
                }
                result.append(
                    ExpectedOccurrence(
                        obligationID: obligation.id,
                        name: obligation.name,
                        expectedDay: day,
                        amount: obligation.amount,
                        requirement: obligation.requirement,
                        spendingClass: obligation.spendingClass,
                        status: status
                    )
                )
            }
        }

        return result.sorted {
            ($0.expectedDay, $0.obligationID) < ($1.expectedDay, $1.obligationID)
        }
    }

    /// Occurrences still awaiting an answer — the reconciliation inbox.
    public static func unresolved(
        in document: FinanceDocument,
        from start: Day,
        to end: Day,
        asOf today: Day,
        ledger: ReconciliationLedger? = nil
    ) -> [ExpectedOccurrence] {
        occurrences(in: document, from: start, to: end, asOf: today, ledger: ledger)
            .filter { !$0.status.isResolved }
    }
}
