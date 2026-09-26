/// Whether a scheduled outflow is a real commitment or a planning artifact.
///
/// The arrears policy (defect/policy C2) is the canonical example: a debt can
/// **exist** (960.00 EUR owed) while having **zero committed repayment events** —
/// there is no agreed schedule with the creditor. A hypothetical recovery
/// schedule lives in a document only as `hypothetical`, and hypothetical
/// commitments never enter a forecast as committed outflows. When a real
/// agreement exists, the status is promoted to `committed` and the payments
/// become obligations like any other.
public enum CommitmentStatus: String, Sendable, Codable, CaseIterable {
    /// Real, agreed, will happen. Enters forecasts as committed outflows.
    case committed
    /// A planning exploration ("what if I repaid 4 × €218.22?"). Never a
    /// committed outflow; the composer skips it entirely.
    case hypothetical
}

/// A prospective (or received) resource stream with an explicit certainty.
///
/// Examples:
/// - internship gratification €292.50/month, `expected`
/// - student job €253/month net, `target` (unsigned — not income until it exists)
/// - CAF housing aid €190/month, `target` (blocked behind the job)
/// - CROUS emergency aid, `possible` (nothing applied for)
/// - a one-shot €400 shared-pot share, `guaranteed` (committed future
///   resource — not received, not liquidity, but secured)
/// - electricity at €0.00/month while the chèque énergie covers it — a
///   **zero-amount tracked stream**: named, visible, economically silent
public struct IncomeSource: Identifiable, Hashable, Sendable, Codable {

    public let id: String
    public var name: String
    public var amount: Money
    public var certainty: IncomeCertainty
    public var schedule: RecurrenceSpec

    /// Other income sources this one depends on (by id), e.g. CAF housing aid
    /// depends on the qualifying student job. Certainty propagates **down**:
    /// a source can never be more certain than its weakest dependency
    /// (transitively, cycle-safe).
    public var dependsOn: [String]

    /// The account the money is expected to land in. nil means the engine
    /// picks an active account in the source's currency.
    public var arrivesOnAccount: String?

    public var note: String?

    public init(
        id: String,
        name: String,
        amount: Money,
        certainty: IncomeCertainty,
        schedule: RecurrenceSpec,
        dependsOn: [String] = [],
        arrivesOnAccount: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.certainty = certainty
        self.schedule = schedule
        self.dependsOn = dependsOn
        self.arrivesOnAccount = arrivesOnAccount
        self.note = note
    }

    /// The effective certainty after dependency propagation: the minimum of
    /// this source's own certainty and the effective certainty of everything
    /// it (transitively) depends on. An `expected` grant depending on a
    /// `target` job is effectively `target` — it cannot exist before the job
    /// exists. Unknown dependency ids are ignored; cycles terminate.
    public func effectiveCertainty(in sources: [IncomeSource]) -> IncomeCertainty {
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var visited = Set<String>()
        var weakest = certainty

        func walk(_ source: IncomeSource) {
            guard visited.insert(source.id).inserted else { return }
            weakest = min(weakest, source.certainty)
            for dependency in source.dependsOn {
                if let next = byID[dependency] { walk(next) }
            }
        }
        walk(self)
        return weakest
    }

    // MARK: - Codable (dependsOn is additive; pre-1.1.0 documents decode without it)

    private enum SourceCodingKeys: String, CodingKey {
        case id, name, amount, certainty, schedule, dependsOn, arrivesOnAccount, note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SourceCodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.amount = try container.decode(Money.self, forKey: .amount)
        self.certainty = try container.decode(IncomeCertainty.self, forKey: .certainty)
        self.schedule = try container.decode(RecurrenceSpec.self, forKey: .schedule)
        self.dependsOn = try container.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        self.arrivesOnAccount = try container.decodeIfPresent(String.self, forKey: .arrivesOnAccount)
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SourceCodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(amount, forKey: .amount)
        try container.encode(certainty, forKey: .certainty)
        try container.encode(schedule, forKey: .schedule)
        if !dependsOn.isEmpty { try container.encode(dependsOn, forKey: .dependsOn) }
        try container.encodeIfPresent(arrivesOnAccount, forKey: .arrivesOnAccount)
        try container.encodeIfPresent(note, forKey: .note)
    }
}

/// A recurring outgoing obligation (rent, phone plan, insurance, bank fee…).
/// Fixed obligations live here; finite financing schedules live in
/// `InstallmentPlan` and arrears in `Debt`.
public struct RecurringObligation: Identifiable, Hashable, Sendable, Codable {

    public let id: String
    public var name: String
    public var amount: Money
    public var spec: RecurrenceSpec
    public var requirement: PaymentRequirement
    public var spendingClass: SpendingClass
    public var commitmentStatus: CommitmentStatus

    /// The budget line this obligation is committed against, when the plan
    /// says so. `nil` is the honest default: no mapping is inferred from a
    /// name or a spending class, so an unlinked obligation counts only in the
    /// month's committed total and never inside a category.
    public var budgetID: String?

    public var note: String?

    public init(
        id: String,
        name: String,
        amount: Money,
        spec: RecurrenceSpec,
        requirement: PaymentRequirement,
        spendingClass: SpendingClass,
        commitmentStatus: CommitmentStatus = .committed,
        budgetID: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.spec = spec
        self.requirement = requirement
        self.spendingClass = spendingClass
        self.commitmentStatus = commitmentStatus
        self.budgetID = budgetID
        self.note = note
    }

    // MARK: - Codable (commitmentStatus and budgetID are additive)

    private enum CodingKeys: String, CodingKey {
        case id, name, amount, spec, requirement, spendingClass, commitmentStatus, budgetID, note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.amount = try container.decode(Money.self, forKey: .amount)
        self.spec = try container.decode(RecurrenceSpec.self, forKey: .spec)
        self.requirement = try container.decode(PaymentRequirement.self, forKey: .requirement)
        self.spendingClass = try container.decode(SpendingClass.self, forKey: .spendingClass)
        self.commitmentStatus = try container.decodeIfPresent(CommitmentStatus.self, forKey: .commitmentStatus) ?? .committed
        self.budgetID = try container.decodeIfPresent(String.self, forKey: .budgetID)
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(amount, forKey: .amount)
        try container.encode(spec, forKey: .spec)
        try container.encode(requirement, forKey: .requirement)
        try container.encode(spendingClass, forKey: .spendingClass)
        if commitmentStatus != .committed { try container.encode(commitmentStatus, forKey: .commitmentStatus) }
        try container.encodeIfPresent(budgetID, forKey: .budgetID)
        try container.encodeIfPresent(note, forKey: .note)
    }
}
