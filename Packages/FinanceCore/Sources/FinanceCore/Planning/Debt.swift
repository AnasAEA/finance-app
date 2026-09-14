/// Status of a scheduled payment.
public enum PaymentStatus: String, Sendable, Codable {
    case scheduled
    case paid
    case cancelled
    case reversed
}

/// A debt being repaid on a schedule — e.g. rent arrears.
///
/// Paying an arrear **is** economic spending: it settles real consumption that
/// was never paid (a reversed rent debit is still owed housing). That is the
/// crucial difference from `InstallmentPlan`, whose repayments settle a
/// purchase that was already booked in full.
///
/// A debt can equally be **acknowledged but unscheduled** (policy C2): the
/// 960.00 EUR rent arrears exist, but with no agreed repayment schedule there
/// are zero committed repayment events — `paymentSchedule` is empty, the
/// outstanding balance lives in `unscheduledBalance`, and no forecast ever
/// invents a recovery payment. When the creditor agrees a schedule, the payments
/// are added and the debt does the work of any other obligation.
public struct Debt: Identifiable, Hashable, Sendable, Codable {

    public let id: String
    public var name: String
    public var note: String?

    /// What is owed in total before any further payments.
    public var originalAmount: Money

    /// The **committed** repayment events. Empty when no agreement exists —
    /// a hypothetical recovery plan is carried at `commitmentStatus ==
    /// .hypothetical` and never enters a forecast.
    public var paymentSchedule: [ScheduledPayment]

    public var paymentRequirement: PaymentRequirement

    /// Whether the schedule above is a real commitment or a what-if.
    public var commitmentStatus: CommitmentStatus

    public enum Status: String, Sendable, Codable {
        case active
        case repaid
        case disputed
    }
    public var status: Status

    public init(
        id: String,
        name: String,
        note: String? = nil,
        originalAmount: Money,
        paymentSchedule: [ScheduledPayment],
        paymentRequirement: PaymentRequirement,
        commitmentStatus: CommitmentStatus = .committed,
        status: Status = .active
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.originalAmount = originalAmount
        self.paymentSchedule = paymentSchedule
        self.paymentRequirement = paymentRequirement
        self.commitmentStatus = commitmentStatus
        self.status = status
    }

    /// What remains unpaid on the committed schedule: the sum of scheduled
    /// payments. Zero when the debt is acknowledged but unscheduled.
    public var remainingAmount: Money {
        Money.sum(paymentSchedule.filter { $0.status == .scheduled }.map(\.amount), currency: originalAmount.currency)
    }

    /// Owed money with no committed repayment events:
    /// `originalAmount − remainingAmount`. For the unscheduled arrears case
    /// this is the full debt — real, acknowledged, and invisible to cash-flow
    /// forecasts until an agreement promotes it onto the schedule.
    public var unscheduledBalance: Money {
        Money(
            minorUnits: originalAmount.minorUnits - remainingAmount.minorUnits,
            currency: originalAmount.currency
        )
    }

    // MARK: - Codable (commitmentStatus is additive, default committed)

    private enum CodingKeys: String, CodingKey {
        case id, name, note, originalAmount, paymentSchedule, paymentRequirement, commitmentStatus, status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
        self.originalAmount = try container.decode(Money.self, forKey: .originalAmount)
        self.paymentSchedule = try container.decode([ScheduledPayment].self, forKey: .paymentSchedule)
        self.paymentRequirement = try container.decode(PaymentRequirement.self, forKey: .paymentRequirement)
        self.commitmentStatus = try container.decodeIfPresent(CommitmentStatus.self, forKey: .commitmentStatus) ?? .committed
        self.status = try container.decode(Status.self, forKey: .status)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(originalAmount, forKey: .originalAmount)
        try container.encode(paymentSchedule, forKey: .paymentSchedule)
        try container.encode(paymentRequirement, forKey: .paymentRequirement)
        if commitmentStatus != .committed { try container.encode(commitmentStatus, forKey: .commitmentStatus) }
        try container.encode(status, forKey: .status)
    }
}

/// One scheduled payment inside a debt or installment plan.
public struct ScheduledPayment: Hashable, Sendable, Codable {

    public let day: Day
    public let amount: Money
    public let status: PaymentStatus
    public let paidOn: Day?

    public init(day: Day, amount: Money, status: PaymentStatus = .scheduled, paidOn: Day? = nil) {
        self.day = day
        self.amount = amount
        self.status = status
        self.paidOn = paidOn
    }
}

/// A finite financing plan (pay-in-4, 4× CB…) for a purchase whose **full
/// economic cost was booked once, at purchase time**.
///
/// Consequences the model enforces:
/// - the purchase transaction is the expense;
/// - each installment repayment is a `financingRepayment` — a liquidity event,
///   never new economic spending;
/// - the remaining balance is simply the sum of unpaid installments.
public struct InstallmentPlan: Identifiable, Hashable, Sendable, Codable {

    public let id: String
    public var provider: String
    public var purchaseDescription: String
    public var note: String?

    public var purchaseDate: Day?

    /// The full economic cost booked at purchase time.
    public var originalPurchaseAmount: Money

    public var installments: [Installment]

    /// How installment debits settle (rail + currency).
    public var paymentRequirement: PaymentRequirement

    /// Whether this plan's remaining installments are real commitments
    /// (default) or a what-if reconstruction.
    public var commitmentStatus: CommitmentStatus

    public enum Status: String, Sendable, Codable {
        case active
        case completed
        case cancelled
    }
    public var status: Status

    public init(
        id: String,
        provider: String,
        purchaseDescription: String,
        note: String? = nil,
        purchaseDate: Day? = nil,
        originalPurchaseAmount: Money,
        installments: [Installment],
        paymentRequirement: PaymentRequirement,
        commitmentStatus: CommitmentStatus = .committed,
        status: Status = .active
    ) {
        self.id = id
        self.provider = provider
        self.purchaseDescription = purchaseDescription
        self.note = note
        self.purchaseDate = purchaseDate
        self.originalPurchaseAmount = originalPurchaseAmount
        self.installments = installments
        self.paymentRequirement = paymentRequirement
        self.commitmentStatus = commitmentStatus
        self.status = status
    }

    /// Unpaid balance = sum of scheduled installments.
    public var remainingAmount: Money {
        Money.sum(installments.filter { $0.status == .scheduled }.map(\.amount), currency: originalPurchaseAmount.currency)
    }

    // MARK: - Codable (commitmentStatus is additive, default committed)

    private enum CodingKeys: String, CodingKey {
        case id, provider, purchaseDescription, note, purchaseDate
        case originalPurchaseAmount, installments, paymentRequirement, commitmentStatus, status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.provider = try container.decode(String.self, forKey: .provider)
        self.purchaseDescription = try container.decode(String.self, forKey: .purchaseDescription)
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
        self.purchaseDate = try container.decodeIfPresent(Day.self, forKey: .purchaseDate)
        self.originalPurchaseAmount = try container.decode(Money.self, forKey: .originalPurchaseAmount)
        self.installments = try container.decode([Installment].self, forKey: .installments)
        self.paymentRequirement = try container.decode(PaymentRequirement.self, forKey: .paymentRequirement)
        self.commitmentStatus = try container.decodeIfPresent(CommitmentStatus.self, forKey: .commitmentStatus) ?? .committed
        self.status = try container.decode(Status.self, forKey: .status)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(purchaseDescription, forKey: .purchaseDescription)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(purchaseDate, forKey: .purchaseDate)
        try container.encode(originalPurchaseAmount, forKey: .originalPurchaseAmount)
        try container.encode(installments, forKey: .installments)
        try container.encode(paymentRequirement, forKey: .paymentRequirement)
        if commitmentStatus != .committed { try container.encode(commitmentStatus, forKey: .commitmentStatus) }
        try container.encode(status, forKey: .status)
    }
}

/// One installment inside an `InstallmentPlan`.
public struct Installment: Hashable, Sendable, Codable {

    /// 1-based position in the plan.
    public let sequence: Int
    public let dueDate: Day
    public let amount: Money
    public let status: PaymentStatus
    public let paidOn: Day?

    public init(sequence: Int, dueDate: Day, amount: Money, status: PaymentStatus = .scheduled, paidOn: Day? = nil) {
        self.sequence = sequence
        self.dueDate = dueDate
        self.amount = amount
        self.status = status
        self.paidOn = paidOn
    }
}
