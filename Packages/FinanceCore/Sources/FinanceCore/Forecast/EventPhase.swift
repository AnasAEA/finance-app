/// The deterministic same-day ordering rule for forecast events.
///
/// Within one calendar day, events apply in this exact order:
///
/// 1. `scheduledDebit` — obligations, installments, arrears, fees.
///    Debits apply **before** credits: a same-day deposit is never assumed to
///    rescue a same-day debit. This is the conservative **default**.
/// 2. `variableSpending` — budgeted daily spending draws.
/// 3. `credit` — income and pass-through arrivals.
/// 4. `relocation` — value moving between the user's own positions after it
///    arrived (depositing physical cash into the bank, an internal transfer):
///    neither consumption nor income.
/// 5. `dependentDisposal` — money forwarded onward only *after* it arrived
///    (e.g. remitting a co-resident's pass-through share once the parent transfer
///    has landed and been deposited).
///
/// Within a phase, events apply by ascending `priority`, then ascending id
/// (lexicographic). The full sort key (day, phase, priority, id) is a total
/// order: collection iteration order can never influence a result.
///
/// ## Escaping the conservative default (documented, deterministic)
///
/// The phase is a caller-set field, not an engine secret. When the user
/// *knows* a credit lands before a same-day debit (a morning deposit, a
/// landlord agreement), the event may be placed in an earlier phase with an
/// explicit `priority` — the engine applies exactly what it is told. Unknown
/// timing keeps the conservative default. There is deliberately **no
/// timestamp simulation**: day + phase + priority is the whole clock.
public enum EventPhase: Int, Sendable, Codable, Comparable {
    case scheduledDebit = 0
    case variableSpending = 1
    case credit = 2
    case relocation = 3
    case dependentDisposal = 4

    public static func < (lhs: EventPhase, rhs: EventPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// What an outflow event **means** economically (defect D1).
///
/// The distinction that keeps internal movements from poisoning committed
/// outflow / safe-to-spend math:
///
/// - `.economicCommitment` — consumption or an obligation the user's money
///   must cover. Reduces safe-to-spend. (rent, groceries, fees, arrears)
/// - `.financingCommitment` — a committed repayment of already-booked
///   spending. Reduces safe-to-spend (the money will leave) but is never new
///   economic spending. (Pay-in-4 installments)
/// - `.relocation` — value changing location or form between the user's own
///   positions. Never consumption, never reduces total wealth — but it can
///   still change **rail-specific liquidity** (bank → physical cash lowers
///   bank-rail spendability while total wealth is unchanged).
/// - `.disposal` — somebody else's money leaving the accounts (remitting the
///   co-resident's pass-through share). Not the user's commitment in any sense:
///   the corresponding owned-share credit is what counted as income.
public enum OutflowSemantics: String, Sendable, Codable {
    case economicCommitment
    case financingCommitment
    case relocation
    case disposal
}

/// A single dated effect the forecast engine applies.
///
/// Events are *derived* (composed from recurring obligations, installments,
/// debts, income sources, budgets) — they are not persisted in the interchange
/// document.
public struct ForecastEvent: Identifiable, Hashable, Sendable {

    public let id: String
    public let day: Day
    public let phase: EventPhase

    /// Lower runs first inside the phase. Default 0.
    public let priority: Int

    public let effect: Effect

    /// The economic meaning of an outflow event (defect D1). nil for credits;
    /// nil on a debit means `.economicCommitment` (the conservative default —
    /// hand-built debit events keep their old meaning).
    public let outflowSemantics: OutflowSemantics?

    /// Where this event came from (obligation/income/plan id), for debugging
    /// and UI display.
    public let sourceRef: String?

    /// The certainty of an income event that passed scenario filtering;
    /// informational.
    public let certainty: IncomeCertainty?

    public enum Effect: Hashable, Sendable {
        /// Funds arriving on a specific account.
        case credit(Money, toAccount: String)

        /// A payment that must be settled by accounts satisfying the
        /// requirement (currency + at least one acceptable rail).
        case debit(Money, requirement: PaymentRequirement)

        /// A debit against one specific account (e.g. remitting a pass-through
        /// share from the account it landed on).
        case directedDebit(Money, fromAccount: String)
    }

    public init(
        id: String,
        day: Day,
        phase: EventPhase,
        priority: Int = 0,
        effect: Effect,
        outflowSemantics: OutflowSemantics? = nil,
        sourceRef: String? = nil,
        certainty: IncomeCertainty? = nil
    ) {
        self.id = id
        self.day = day
        self.phase = phase
        self.priority = priority
        self.effect = effect
        self.outflowSemantics = outflowSemantics ?? Self.defaultSemantics(for: effect)
        self.sourceRef = sourceRef
        self.certainty = certainty
    }

    /// Conservative default: an unclassified debit is treated as an economic
    /// commitment; credits carry no outflow semantics.
    static func defaultSemantics(for effect: Effect) -> OutflowSemantics? {
        switch effect {
        case .credit: return nil
        case .debit, .directedDebit: return .economicCommitment
        }
    }

    /// The deterministic sort key. A total order over all events.
    public var sortKey: (day: Day, phase: EventPhase, priority: Int, id: String) {
        (day, phase, priority, id)
    }

    /// Whether this event moves funds out of any account.
    public var isOutflow: Bool {
        switch effect {
        case .credit: return false
        case .debit, .directedDebit: return true
        }
    }

    /// Whether this event is a **committed outflow** for safe-to-spend:
    /// economic commitments and financing commitments count; relocations and
    /// disposals never do (defect D1).
    public var isCommittedOutflow: Bool {
        guard isOutflow else { return false }
        switch outflowSemantics {
        case .economicCommitment, .financingCommitment: return true
        case .relocation, .disposal, nil: return false
        }
    }
}
