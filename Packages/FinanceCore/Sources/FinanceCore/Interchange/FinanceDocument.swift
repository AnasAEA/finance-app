import Foundation

/// The versioned interchange document connecting the forensic reconstruction,
/// the workbook and the iOS app.
///
/// Versioning (semver, from day one):
/// - MAJOR: removing/renaming a field, changing semantics of an existing value;
/// - MINOR: adding an optional field;
/// - PATCH: fixture/documentation corrections only.
///
/// See `Interchange/SCHEMA.md` for the full field-by-field contract.
/// Deterministic encoding: encode with `.sortedKeys` and pretty printing; all
/// sets serialize as sorted arrays, so identical documents produce identical
/// bytes on every machine.
public struct FinanceDocument: Codable, Hashable, Sendable {

    /// Interchange schema version of this document, e.g. `"1.0.0"`.
    public var schemaVersion: String

    /// Marks what this document is. Development fixtures carry
    /// `"DEV-FIXTURE — NOT FINANCIAL EVIDENCE"`; canonical exports carry their
    /// export batch id.
    public var documentKind: String

    /// Free-form provenance note (which export, which as-of date).
    public var note: String?

    public var accounts: [Account]
    public var balances: [AccountBalance]

    /// Observed economic events (facts).
    public var transactions: [Transaction]

    /// Expected/planned events (not yet facts).
    public var expectedTransactions: [Transaction]

    public var incomeSources: [IncomeSource]
    public var installments: [InstallmentPlan]
    public var debts: [Debt]

    public var planning: Planning

    /// Additive in 1.3.0: durable provider evidence and the person's explicit
    /// review decisions. These arrays default empty for 1.1/1.2 documents.
    public var externalAccountBindings: [ExternalAccountBinding]
    public var externalObservations: [ExternalObservation]
    public var providerBalanceSnapshots: [ProviderBalanceSnapshot]
    public var externalEvidenceLinks: [ExternalEvidenceLink]
    public var observationResolutions: [ExternalObservationResolution]
    public var crossProviderCandidates: [CrossProviderCandidate]

    /// Additive in 1.5.0: user-approved trusted rules, append-only lifecycle /
    /// application audit, and durable reversal suppressions. Provider
    /// observations remain unchanged.
    public var trustedRules: [TrustedRule]
    public var trustedRuleAuditEvents: [TrustedRuleAuditEvent]
    public var trustedRuleObservationSuppressions: [TrustedRuleObservationSuppression]

    public struct Planning: Codable, Hashable, Sendable {
        /// Which scenario the plan is normally read in.
        public var defaultScenario: Scenario?
        /// Operating floor for the euro spendable pool.
        public var safetyFloor: Money?

        /// The gross monthly economic-spending ceiling: everything consumed in
        /// a month, housing included, measured before any assistance.
        ///
        /// Deliberately gross. Funding that has not arrived — a housing
        /// allowance still conditional, for instance — is income to be
        /// represented as income, never a discount applied to an obligation to
        /// make the month fit. Nothing in this type reduces it.
        public var monthlyEconomicCeiling: Money?

        /// Monthly spending envelopes.
        public var budgets: [BudgetAllocation]
        /// Fixed recurring obligations.
        public var recurringObligations: [RecurringObligation]
        /// Carried EUR value of foreign-currency holdings, keyed by account id
        /// (physical cash carried at what the withdrawal actually cost).
        public var carriedEURValues: [String: Money]

        /// Which expected occurrences of the recurring rules above have been
        /// resolved, and by what. Keyed to `(obligationID, expectedDay)` pairs
        /// rather than to the rules themselves: an actual settles one month,
        /// never the rule (see `ObligationSettlement`).
        public var settlements: [ObligationSettlement]

        /// Additive in 1.6.0: durable planned purchases. Empty on older
        /// documents. These are planning rows, not transactions.
        public var plannedPurchases: [PlannedPurchase]

        /// Additive in 1.6.0: durable sinking-fund reservations. Empty on
        /// older documents. A contribution is not economic spending.
        public var sinkingFunds: [SinkingFund]

        public var containsDurablePlanningState: Bool {
            !plannedPurchases.isEmpty || !sinkingFunds.isEmpty
        }

        public init(
            defaultScenario: Scenario? = nil,
            safetyFloor: Money? = nil,
            monthlyEconomicCeiling: Money? = nil,
            budgets: [BudgetAllocation] = [],
            recurringObligations: [RecurringObligation] = [],
            carriedEURValues: [String: Money] = [:],
            settlements: [ObligationSettlement] = [],
            plannedPurchases: [PlannedPurchase] = [],
            sinkingFunds: [SinkingFund] = []
        ) {
            self.defaultScenario = defaultScenario
            self.safetyFloor = safetyFloor
            self.monthlyEconomicCeiling = monthlyEconomicCeiling
            self.budgets = budgets
            self.recurringObligations = recurringObligations
            self.carriedEURValues = carriedEURValues
            self.settlements = settlements
            self.plannedPurchases = plannedPurchases
            self.sinkingFunds = sinkingFunds
        }

        // MARK: - Codable (carried values as a sorted array)

        private struct CarriedEntry: Codable {
            let accountID: String
            let value: Money
        }

        private enum CodingKeys: String, CodingKey {
            case defaultScenario, safetyFloor, monthlyEconomicCeiling
            case budgets, recurringObligations, carriedEURValues, settlements
            case plannedPurchases, sinkingFunds
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.defaultScenario = try container.decodeIfPresent(Scenario.self, forKey: .defaultScenario)
            self.safetyFloor = try container.decodeIfPresent(Money.self, forKey: .safetyFloor)
            // Additive in 1.4.0: an older document simply states no ceiling.
            self.monthlyEconomicCeiling = try container.decodeIfPresent(Money.self, forKey: .monthlyEconomicCeiling)
            self.budgets = try container.decode([BudgetAllocation].self, forKey: .budgets)
            self.recurringObligations = try container.decode([RecurringObligation].self, forKey: .recurringObligations)
            let entries = try container.decode([CarriedEntry].self, forKey: .carriedEURValues)
            self.carriedEURValues = Dictionary(entries.map { ($0.accountID, $0.value) }, uniquingKeysWith: { a, _ in a })
            // Additive in 1.2.0: a 1.1.0 document simply has nothing reconciled.
            self.settlements = try container.decodeIfPresent([ObligationSettlement].self, forKey: .settlements) ?? []
            // Additive in 1.6.0: older documents have no goals or funds.
            self.plannedPurchases = try container.decodeIfPresent([PlannedPurchase].self, forKey: .plannedPurchases) ?? []
            self.sinkingFunds = try container.decodeIfPresent([SinkingFund].self, forKey: .sinkingFunds) ?? []
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(defaultScenario, forKey: .defaultScenario)
            try container.encodeIfPresent(safetyFloor, forKey: .safetyFloor)
            try container.encodeIfPresent(monthlyEconomicCeiling, forKey: .monthlyEconomicCeiling)
            try container.encode(budgets, forKey: .budgets)
            try container.encode(recurringObligations, forKey: .recurringObligations)
            try container.encode(
                carriedEURValues
                    .map { CarriedEntry(accountID: $0.key, value: $0.value) }
                    .sorted { $0.accountID < $1.accountID },
                forKey: .carriedEURValues
            )
            try container.encode(settlements.sorted { $0.id < $1.id }, forKey: .settlements)
            try container.encode(plannedPurchases.sorted { $0.id < $1.id }, forKey: .plannedPurchases)
            try container.encode(sinkingFunds.sorted { $0.id < $1.id }, forKey: .sinkingFunds)
        }
    }

    public init(
        schemaVersion: String,
        documentKind: String,
        note: String? = nil,
        accounts: [Account],
        balances: [AccountBalance],
        transactions: [Transaction] = [],
        expectedTransactions: [Transaction] = [],
        incomeSources: [IncomeSource] = [],
        installments: [InstallmentPlan] = [],
        debts: [Debt] = [],
        planning: Planning = Planning(),
        externalAccountBindings: [ExternalAccountBinding] = [],
        externalObservations: [ExternalObservation] = [],
        providerBalanceSnapshots: [ProviderBalanceSnapshot] = [],
        externalEvidenceLinks: [ExternalEvidenceLink] = [],
        observationResolutions: [ExternalObservationResolution] = [],
        crossProviderCandidates: [CrossProviderCandidate] = [],
        trustedRules: [TrustedRule] = [],
        trustedRuleAuditEvents: [TrustedRuleAuditEvent] = [],
        trustedRuleObservationSuppressions: [TrustedRuleObservationSuppression] = []
    ) {
        self.schemaVersion = schemaVersion
        self.documentKind = documentKind
        self.note = note
        self.accounts = accounts
        self.balances = balances
        self.transactions = transactions
        self.expectedTransactions = expectedTransactions
        self.incomeSources = incomeSources
        self.installments = installments
        self.debts = debts
        self.planning = planning
        self.externalAccountBindings = externalAccountBindings
        self.externalObservations = externalObservations
        self.providerBalanceSnapshots = providerBalanceSnapshots
        self.externalEvidenceLinks = externalEvidenceLinks
        self.observationResolutions = observationResolutions
        self.crossProviderCandidates = crossProviderCandidates
        self.trustedRules = trustedRules
        self.trustedRuleAuditEvents = trustedRuleAuditEvents
        self.trustedRuleObservationSuppressions = trustedRuleObservationSuppressions
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, documentKind, note, accounts, balances
        case transactions, expectedTransactions, incomeSources, installments, debts, planning
        case externalAccountBindings, externalObservations, providerBalanceSnapshots
        case externalEvidenceLinks, observationResolutions, crossProviderCandidates
        case trustedRules, trustedRuleAuditEvents, trustedRuleObservationSuppressions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        documentKind = try container.decode(String.self, forKey: .documentKind)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        accounts = try container.decode([Account].self, forKey: .accounts)
        balances = try container.decode([AccountBalance].self, forKey: .balances)
        transactions = try container.decode([Transaction].self, forKey: .transactions)
        expectedTransactions = try container.decode([Transaction].self, forKey: .expectedTransactions)
        incomeSources = try container.decode([IncomeSource].self, forKey: .incomeSources)
        installments = try container.decode([InstallmentPlan].self, forKey: .installments)
        debts = try container.decode([Debt].self, forKey: .debts)
        planning = try container.decode(Planning.self, forKey: .planning)
        externalAccountBindings = try container.decodeIfPresent(
            [ExternalAccountBinding].self, forKey: .externalAccountBindings
        ) ?? []
        externalObservations = try container.decodeIfPresent(
            [ExternalObservation].self, forKey: .externalObservations
        ) ?? []
        providerBalanceSnapshots = try container.decodeIfPresent(
            [ProviderBalanceSnapshot].self, forKey: .providerBalanceSnapshots
        ) ?? []
        externalEvidenceLinks = try container.decodeIfPresent(
            [ExternalEvidenceLink].self, forKey: .externalEvidenceLinks
        ) ?? []
        observationResolutions = try container.decodeIfPresent(
            [ExternalObservationResolution].self, forKey: .observationResolutions
        ) ?? []
        crossProviderCandidates = try container.decodeIfPresent(
            [CrossProviderCandidate].self, forKey: .crossProviderCandidates
        ) ?? []
        trustedRules = try container.decodeIfPresent([TrustedRule].self, forKey: .trustedRules) ?? []
        trustedRuleAuditEvents = try container.decodeIfPresent(
            [TrustedRuleAuditEvent].self, forKey: .trustedRuleAuditEvents
        ) ?? []
        trustedRuleObservationSuppressions = try container.decodeIfPresent(
            [TrustedRuleObservationSuppression].self,
            forKey: .trustedRuleObservationSuppressions
        ) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        let selected = encoder.userInfo[.financeDocumentMoneyWire] as? InterchangeFormat ?? .v2
        guard try Interchange.format(for: schemaVersion) == selected else {
            throw InterchangeError.inconsistentFormatAndVersion
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(documentKind, forKey: .documentKind)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(balances, forKey: .balances)
        try container.encode(transactions, forKey: .transactions)
        try container.encode(expectedTransactions, forKey: .expectedTransactions)
        try container.encode(incomeSources, forKey: .incomeSources)
        try container.encode(installments, forKey: .installments)
        try container.encode(debts, forKey: .debts)
        try container.encode(planning, forKey: .planning)
        try container.encode(externalAccountBindings.sorted { $0.id < $1.id }, forKey: .externalAccountBindings)
        try container.encode(externalObservations.sorted { $0.id < $1.id }, forKey: .externalObservations)
        try container.encode(providerBalanceSnapshots.sorted { $0.id < $1.id }, forKey: .providerBalanceSnapshots)
        try container.encode(externalEvidenceLinks.sorted { $0.id < $1.id }, forKey: .externalEvidenceLinks)
        try container.encode(observationResolutions.sorted { $0.id < $1.id }, forKey: .observationResolutions)
        try container.encode(crossProviderCandidates.sorted { $0.id < $1.id }, forKey: .crossProviderCandidates)
        try container.encode(trustedRules.sorted { $0.id < $1.id }, forKey: .trustedRules)
        try container.encode(
            trustedRuleAuditEvents.sorted { $0.id < $1.id }, forKey: .trustedRuleAuditEvents
        )
        try container.encode(
            trustedRuleObservationSuppressions.sorted { $0.id < $1.id },
            forKey: .trustedRuleObservationSuppressions
        )
    }
}

/// Deterministic JSON coding helpers for the interchange format.
public enum Interchange {

    /// 1.0.0 — initial contract.
    /// 1.1.0 — additive: `Transaction.lifecycle` / `bookedDate` /
    ///         `datePrecision` / `incomeSourceID`, `IncomeSource.dependsOn`,
    ///         `CommitmentStatus` on obligations/installments/debts (all
    ///         optional, all with decoding defaults). No field was removed
    /// or resemanticized; 1.0.0 documents decode unchanged.
    /// 1.2.0 — additive: `Planning.settlements`, recording which expected
    ///         occurrences of a recurring rule have been paid, skipped or
    ///         marked no longer due. Optional with an empty default, so a
    ///         1.1.0 document decodes unchanged as "nothing reconciled yet".
    /// 1.3.0 — additive: external account bindings, provider observations,
    ///         independent provider balances, explicit review states,
    ///         evidence links and conservative cross-provider candidates.
    ///         All arrays default empty for 1.1.0 and 1.2.0 imports.
    /// 1.5.0 — additive: trusted rules and append-only rule audit events.
    ///         Rule, audit, and suppression arrays default empty, so older
    ///         documents remain inert.
    /// 1.6.0 — additive: `Planning.plannedPurchases` and `Planning.sinkingFunds`.
    ///         Empty on older documents. A write preserves the document's own
    ///         schema version unless those arrays are non-empty, in which case
    ///         the document must advertise at least 1.6.0. Fresh empty stores
    ///         default to `currentSchemaVersion`.
    public static let currentSchemaVersion = "1.6.0"
    public static let latestSchemaVersion = "2.0.0"
    public static let explicitMonetarySchemaVersion = "2.0.0"

    /// First schema that may carry durable planned purchases / sinking funds.
    public static let planningStateSchemaVersion = "1.6.0"

    /// Document versions this build can *read*. A write preserves the
    /// document's own `schemaVersion` unless the document contains fields that
    /// require a newer minor. Fresh empty stores default to
    /// `currentSchemaVersion`.
    public static let readableSchemaVersions: Set<String> = [
        "1.1.0", "1.2.0", "1.3.0", "1.4.0", "1.5.0", "1.6.0", "2.0.0",
    ]

    /// Semver compare on numeric `major.minor.patch` triples.
    public static func isVersion(_ version: String, atLeast minimum: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.split(separator: ".").compactMap { Int($0) }
        }
        let lhs = parts(version)
        let rhs = parts(minimum)
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return true
    }

    /// Raises `version` to `minimum` when it is older. Never lowers it.
    public static func version(_ version: String, atLeast minimum: String) -> String {
        isVersion(version, atLeast: minimum) ? version : minimum
    }

    /// Encoder producing byte-deterministic output (sorted keys, pretty).
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ document: FinanceDocument, as target: InterchangeTarget = .minimumRequired) throws -> Data {
        let resolved = try resolveEncoding(document, as: target)
        var wireDocument = document
        wireDocument.schemaVersion = resolved.schemaVersion
        try PlanningValidation.validate(wireDocument)
        let encoder = encoder()
        encoder.userInfo[.financeDocumentMoneyWire] = resolved.format
        return try encoder.encode(wireDocument)
    }

    public static func decode(_ data: Data) throws -> FinanceDocument {
        struct SchemaEnvelope: Decodable { let schemaVersion: String }
        let version = try decoder().decode(SchemaEnvelope.self, from: data).schemaVersion
        let selected = try format(for: version)
        let decoder = decoder()
        decoder.userInfo[.financeDocumentMoneyWire] = selected
        return try decoder.decode(FinanceDocument.self, from: data)
    }
}
