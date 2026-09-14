/// The economic meaning of a transaction.
///
/// **A transaction kind is never the same thing as an account movement.**
/// An account movement is "€X left account Y on date Z". A transaction is an
/// economic event, which may create several account legs and whose economic
/// effect may be zero even when the account movement is large:
///
/// - a transfer moves value between owned accounts → spending €0
/// - an ATM withdrawal changes the *form* of an asset → spending €0
/// - a financing repayment settles a purchase already booked → spending €0
/// - a refund reverses an expense → income €0
/// - a pass-through inflow is economically somebody else's money → income €0
///   (except the explicitly owned share)
public enum TransactionKind: String, Sendable, Codable, CaseIterable {

    /// New economic consumption: buying goods/services, paying fees, settling
    /// arrears for past consumption.
    case expense

    /// Economic income: resources that become mine.
    case income

    /// Value moved between accounts I own. Not spending, not income.
    case transfer

    /// Money returned for a previously booked expense. Offsets that expense;
    /// is **never** ordinary income.
    case refund

    /// Repayment of a financing advance (pay-in-4, installment, credit) whose
    /// original purchase was already booked as an expense at purchase time.
    /// Reduces liquidity; creates **no** new economic spending.
    case financingRepayment

    /// Money that physically enters or leaves my accounts while economically
    /// belonging to somebody else (inflow or the later disposal to its owner).
    /// Contributes only its explicitly-owned share to personal income.
    case passThrough

    /// Withdrawal of physical cash from an account: value changes form
    /// (and possibly currency at the observed ATM rate). Spending €0, income €0,
    /// and no fee is ever invented by the model.
    case cashWithdrawal

    /// An explicit currency exchange between two of my holdings, at an
    /// observed/stated rate. Not spending, not income.
    case currencyConversion
}

/// Whether a recorded item is an observed fact or an expectation.
///
/// The historical/observed layer and the planning layer must never mix: no
/// scenario, no forecast and no later planning decision rewrites an observed
/// fact, and no expectation silently becomes one.
public enum Factivity: String, Sendable, Codable {
    /// It actually happened — bank/statement/observed evidence.
    case observed
    /// It is planned/expected and has not settled yet.
    case expected
}

/// Where a transaction sits in its settlement lifecycle.
///
/// Orthogonal to `Factivity`: an observed card payment can still be `pending`
/// (a hold, not yet cleared), and an observed rent debit can be `reversed`
/// (the creditor pulled it back — e.g. a landlord reversing a monthly direct debit).
///
/// Economic semantics: `reversed` transactions contribute **zero** to
/// `Economics.totals` — a reversed debit never economically happened, so a
/// reversal is modelled directly on its own transaction instead of forcing a
/// fake "income" entry to cancel it. The still-owed obligation, if any, lives
/// in the planning layer (`Debt`), never in a synthetic transaction.
public enum TransactionLifecycle: String, Sendable, Codable, CaseIterable {
    /// Authorized/held but not yet settled (card hold, pending transfer).
    case pending
    /// Settled on the account; the normal state of an observed fact.
    case cleared
    /// Settled and confirmed against a statement/reconciliation pass.
    case reconciled
    /// Pulled back or voided. Economically never happened.
    case reversed
}

/// How precisely the recorded `date` is known.
///
/// `exact` — the day is known from evidence (statement line, dated contract).
/// `estimated` — the day is a plausible placement (recalled, pattern-derived);
/// forecasts keep using it as-is (conservative placement is a recurrence-level
/// concern — see `monthlyWindow`), but the UI may render estimated dates
/// differently. Carried, never flattened.
public enum DatePrecision: String, Sendable, Codable, CaseIterable {
    case exact
    case estimated
}

/// How a piece of financial knowledge came to be known. Provenance is carried,
/// never flattened: a value's grade may inform confidence, but grades are
/// never silently promoted.
public struct Provenance: Hashable, Sendable, Codable {

    public enum EvidenceGrade: String, Sendable, Codable, Comparable {
        case primarySource
        case userConfirmed
        case derived
        case inferred
        case unresolved

        /// Higher = stronger. Ordering of evidence strength.
        var rank: Int {
            switch self {
            case .primarySource: return 5
            case .userConfirmed: return 4
            case .derived: return 3
            case .inferred: return 2
            case .unresolved: return 1
            }
        }

        public static func < (lhs: EvidenceGrade, rhs: EvidenceGrade) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    /// Where this came from, e.g. `"BNP-STATEMENT"`, `"DEV-FIXTURE"`,
    /// `"USER-CONFIRMED"`.
    public let source: String

    public let evidenceGrade: EvidenceGrade

    /// Optional precise pointer (transaction id, statement reference…).
    public let reference: String?

    public init(source: String, evidenceGrade: EvidenceGrade, reference: String? = nil) {
        self.source = source
        self.evidenceGrade = evidenceGrade
        self.reference = reference
    }

    /// Provenance used by development fixtures — clearly not financial evidence.
    public static let devFixture = Provenance(source: "DEV-FIXTURE", evidenceGrade: .unresolved, reference: nil)
}

/// One account movement inside a transaction. Signed: positive = funds into
/// the account, negative = funds out.
public struct AccountLeg: Hashable, Sendable, Codable {
    public let accountID: String
    public let amount: Money

    public init(accountID: String, amount: Money) {
        self.accountID = accountID
        self.amount = amount
    }

    public var isInflow: Bool { amount.isPositive }
    public var isOutflow: Bool { amount.isNegative }
}

/// An explicit statement of who owns part of a pass-through movement.
/// The model never invents a split: a pass-through without ownership splits
/// contributes **zero** to personal income, even when the bank balance moved.
public struct OwnershipSplit: Hashable, Sendable, Codable {
    /// Stable owner identifier, e.g. `"holder"`, `"co-resident"`.
    public let ownerID: String
    /// Whether this owner is the account holder (economic "me").
    public let isSelf: Bool
    public let amount: Money

    public init(ownerID: String, isSelf: Bool, amount: Money) {
        precondition(amount.isPositive, "ownership splits carry positive magnitudes")
        self.ownerID = ownerID
        self.isSelf = isSelf
        self.amount = amount
    }
}

/// Why an ownership allocation was rejected (defect D5).
///
/// Financial ownership is never silently normalized: an allocation that does
/// not exactly account for the economic base is malformed data, not a
/// rounding problem. All arithmetic is exact integer `Money` arithmetic.
public enum OwnershipError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The shares sum to less than the economic base — money with no owner.
    case underAllocation(allocated: Money, base: Money)
    /// The shares sum to more than the economic base — ownership invented
    /// out of thin air.
    case overAllocation(allocated: Money, base: Money)
    /// A split is denominated in a currency the movement never had.
    case currencyMismatch(splitCurrency: String, baseCurrency: String)

    public var description: String {
        switch self {
        case let .underAllocation(allocated, base):
            return "ownership under-allocation: \(allocated) allocated against \(base) economic base"
        case let .overAllocation(allocated, base):
            return "ownership over-allocation: \(allocated) allocated against \(base) economic base"
        case let .currencyMismatch(split, base):
            return "ownership split currency \(split) does not match economic base \(base)"
        }
    }
}

/// Validation of explicit ownership splits (defect D5).
///
/// The **documented relevant economic base** for a pass-through arrival is the
/// total inflow of the event in the arrival currency. Every explicit split
/// list must satisfy, exactly:
///
///     sum(shares) == economic base        (in the base currency)
///
/// Under-allocation, over-allocation and wrong-currency allocations are
/// rejected. Negative/zero shares are rejected structurally by `OwnershipSplit`
/// itself (positive magnitudes only).
public enum OwnershipValidation {

    /// The economic base an ownership split list must account for: the total
    /// inflow of `transaction` in `currency` (zero when there is no inflow).
    public static func economicBase(of transaction: Transaction, currency: Currency) -> Money {
        Money.sum(
            transaction.legs
                .filter { $0.isInflow && $0.amount.currency == currency }
                .map { $0.amount },
            currency: currency
        )
    }

    /// Throws `OwnershipError` unless `splits` account for `base` exactly.
    public static func validate(splits: [OwnershipSplit], against base: Money) throws {
        for split in splits where split.amount.currency != base.currency {
            throw OwnershipError.currencyMismatch(splitCurrency: split.amount.currency.code, baseCurrency: base.currency.code)
        }
        let allocated = Money.sum(splits.map(\.amount), currency: base.currency)
        if allocated.minorUnits < base.minorUnits {
            throw OwnershipError.underAllocation(allocated: allocated, base: base)
        }
        if allocated.minorUnits > base.minorUnits {
            throw OwnershipError.overAllocation(allocated: allocated, base: base)
        }
    }

    /// Validates the ownership of a pass-through arrival against its inflow.
    /// No-ops for transactions without splits or without inflow legs.
    public static func validateOwnership(of transaction: Transaction) throws {
        guard transaction.kind == .passThrough, let splits = transaction.ownership, !splits.isEmpty else { return }
        try validate(splits: splits, legs: transaction.legs)
    }

    /// Validates `splits` against the inflow of `legs` (the economic base),
    /// without needing a fully constructed transaction.
    public static func validate(splits: [OwnershipSplit], legs: [AccountLeg]) throws {
        // The base currency is taken from the splits; the legs must actually
        // carry inflow in that currency for the base to be non-zero.
        guard let baseCurrency = splits.map(\.amount.currency).min(by: { $0.code < $1.code }) else { return }
        let base = Money.sum(
            legs.filter { $0.isInflow && $0.amount.currency == baseCurrency }.map(\.amount),
            currency: baseCurrency
        )
        try validate(splits: splits, against: base)
    }

    /// The first validation problem in `splits` against `legs`, or nil when
    /// the allocation is exact. Used by `Transaction.init`'s precondition and
    /// by the interchange decoder (which throws instead of trapping).
    public static func validationProblem(splits: [OwnershipSplit], legs: [AccountLeg]) -> OwnershipError? {
        do {
            try validate(splits: splits, legs: legs)
            return nil
        } catch let problem as OwnershipError {
            return problem
        } catch {
            return nil
        }
    }
}

/// An economic event expressed over one or more account legs.
///
/// One event, many legs: an ATM withdrawal is one transaction with a bank leg
/// and a cash leg; a financing purchase plus its repayment schedule are
/// distinct transactions linked through an `InstallmentPlan`.
public struct Transaction: Identifiable, Hashable, Sendable, Codable {

    public let id: String
    public let date: Day
    public let kind: TransactionKind

    /// The account movements this event produced. Legs may carry different
    /// currencies (ATM withdrawal, explicit conversion).
    public let legs: [AccountLeg]

    /// Required context for pass-through transactions with mixed ownership;
    /// informational elsewhere. Validated at construction (defect D5): the
    /// shares must account for the event's inflow exactly.
    public let ownership: [OwnershipSplit]?

    /// Links: refund → the expense it reverses; financing repayment → the
    /// financed purchase; disposal → the arrival it disposes of.
    public let linkedTransactionID: String?

    /// For an expected pass-through arrival: the income source that states the
    /// owned share (e.g. `inc-parents-september`). When set, the composer
    /// represents the whole chain (arrival + disposal) from this transaction
    /// and **suppresses** the linked source, so the own share is never counted
    /// twice.
    public let incomeSourceID: String?

    /// The financing plan this repayment belongs to (if any).
    public let installmentPlanID: String?

    public let factivity: Factivity

    /// Settlement lifecycle (pending / cleared / reconciled / reversed).
    /// Reversed transactions contribute zero economics. Defaults to
    /// `.cleared` for observed facts and `.pending` for expected ones.
    public let lifecycle: TransactionLifecycle

    /// Booking date when it differs from the economic `date` (value date vs
    /// posting date). nil = same day.
    public let bookedDate: Day?

    /// How precisely `date` is known (exact vs estimated placement).
    public let datePrecision: DatePrecision

    /// For expected inflows: how certain this money is. Observed transactions
    /// are `.received` by definition.
    public let certainty: IncomeCertainty?

    public let note: String?
    public let provenance: Provenance

    public init(
        id: String,
        date: Day,
        kind: TransactionKind,
        legs: [AccountLeg],
        ownership: [OwnershipSplit]? = nil,
        linkedTransactionID: String? = nil,
        incomeSourceID: String? = nil,
        installmentPlanID: String? = nil,
        factivity: Factivity,
        lifecycle: TransactionLifecycle? = nil,
        bookedDate: Day? = nil,
        datePrecision: DatePrecision = .exact,
        certainty: IncomeCertainty? = nil,
        note: String? = nil,
        provenance: Provenance = .devFixture
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.legs = legs
        self.ownership = ownership
        self.linkedTransactionID = linkedTransactionID
        self.incomeSourceID = incomeSourceID
        self.installmentPlanID = installmentPlanID
        self.factivity = factivity
        self.lifecycle = lifecycle ?? (factivity == .observed ? .cleared : .pending)
        self.bookedDate = bookedDate
        self.datePrecision = datePrecision
        self.certainty = factivity == .observed ? .received : certainty
        self.note = note
        self.provenance = provenance

        if kind == .passThrough {
            precondition(Set(legs.map { $0.amount.currency }).count <= 1,
                         "pass-through legs must share one currency; use currencyConversion for exchanges")
        }
        // Defect D5: malformed financial ownership is a construction error.
        if let ownership, !ownership.isEmpty,
           let problem = OwnershipValidation.validationProblem(splits: ownership, legs: legs) {
            preconditionFailure("\(problem)")
        }
    }

    // MARK: - Codable
    //
    // Custom implementation keeps the decode path consistent with the init
    // path: an observed transaction always carries certainty `received`
    // (a fact is a fact), lifecycle/bookedDate/precision default sensibly for
    // pre-1.1.0 documents, and malformed ownership throws a decoding error
    // instead of trapping (interchange input is untrusted).

    private enum CodingKeys: String, CodingKey {
        case id, date, kind, legs, ownership
        case linkedTransactionID, incomeSourceID, installmentPlanID
        case factivity, lifecycle, bookedDate, datePrecision, certainty
        case note, provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.date = try container.decode(Day.self, forKey: .date)
        self.kind = try container.decode(TransactionKind.self, forKey: .kind)
        self.legs = try container.decode([AccountLeg].self, forKey: .legs)
        let ownership = try container.decodeIfPresent([OwnershipSplit].self, forKey: .ownership)
        self.ownership = ownership
        self.linkedTransactionID = try container.decodeIfPresent(String.self, forKey: .linkedTransactionID)
        self.incomeSourceID = try container.decodeIfPresent(String.self, forKey: .incomeSourceID)
        self.installmentPlanID = try container.decodeIfPresent(String.self, forKey: .installmentPlanID)
        let factivity = try container.decode(Factivity.self, forKey: .factivity)
        self.factivity = factivity
        self.lifecycle = try container.decodeIfPresent(TransactionLifecycle.self, forKey: .lifecycle)
            ?? (factivity == .observed ? .cleared : .pending)
        self.bookedDate = try container.decodeIfPresent(Day.self, forKey: .bookedDate)
        self.datePrecision = try container.decodeIfPresent(DatePrecision.self, forKey: .datePrecision) ?? .exact
        let certainty = try container.decodeIfPresent(IncomeCertainty.self, forKey: .certainty)
        self.certainty = factivity == .observed ? .received : certainty
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
        self.provenance = try container.decode(Provenance.self, forKey: .provenance)

        if kind == .passThrough {
            guard Set(legs.map { $0.amount.currency }).count <= 1 else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath,
                          debugDescription: "pass-through legs must share one currency; use currencyConversion for exchanges")
                )
            }
        }
        // Defect D5: reject malformed ownership with a decoding error.
        if let ownership, !ownership.isEmpty {
            do {
                try OwnershipValidation.validate(splits: ownership, legs: legs)
            } catch let problem as OwnershipError {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath,
                          debugDescription: "transaction '\(id)': \(problem)")
                )
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(kind, forKey: .kind)
        try container.encode(legs, forKey: .legs)
        try container.encodeIfPresent(ownership, forKey: .ownership)
        try container.encodeIfPresent(linkedTransactionID, forKey: .linkedTransactionID)
        try container.encodeIfPresent(incomeSourceID, forKey: .incomeSourceID)
        try container.encodeIfPresent(installmentPlanID, forKey: .installmentPlanID)
        try container.encode(factivity, forKey: .factivity)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encodeIfPresent(bookedDate, forKey: .bookedDate)
        try container.encode(datePrecision, forKey: .datePrecision)
        try container.encodeIfPresent(certainty, forKey: .certainty)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(provenance, forKey: .provenance)
    }
}
