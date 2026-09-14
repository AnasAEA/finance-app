import Foundation

/// One reason a pairing looks (or does not look) like a match.
///
/// Signals are carried rather than collapsed into the score alone, so a screen
/// can say *why* something is being suggested instead of showing a number a
/// person has no way to argue with.
public enum MatchSignal: Hashable, Sendable {

    /// Same currency, same amount, to the minor unit.
    case exactAmount

    /// Same currency, different amount. Never silently accepted: a candidate
    /// carrying this can only be linked by explicit confirmation.
    case amountDiffers(expected: Money, actual: Money)

    /// The actual fell on the expected day itself.
    case sameDay

    /// Signed distance in days: negative = the actual came early.
    case daysApart(Int)

    /// The actual's title and the rule's name describe the same thing.
    case titleMatch

    /// The actual's title and the rule's name partly overlap.
    case titlePartialMatch

    /// The actual was paid from an account the rule's template did not
    /// anticipate. **Informational only** — it costs no score and never
    /// disqualifies. The rule says where money was expected to come from; the
    /// bank says where it actually came from, and the bank is right.
    case paidFromUnexpectedAccount(accountID: String)
}

/// How much the model is willing to say about a pairing.
///
/// Nothing here authorises an automatic link. Even `.strong` is a suggestion a
/// person confirms — the model proposes, the account holder disposes.
public enum MatchConfidence: String, Sendable, Comparable, CaseIterable {
    case weak
    case plausible
    case strong

    private var rank: Int {
        switch self {
        case .weak: return 0
        case .plausible: return 1
        case .strong: return 2
        }
    }

    public static func < (lhs: MatchConfidence, rhs: MatchConfidence) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A proposed pairing of one expected occurrence with one actual transaction.
public struct MatchCandidate: Identifiable, Hashable, Sendable {

    public var id: String { "\(occurrence.description)->\(actualTransactionID)" }

    public let occurrence: OccurrenceID
    public let obligationName: String
    public let expectedDay: Day
    public let expectedAmount: Money

    public let actualTransactionID: String
    /// The observed date. Evidence — never written back onto `expectedDay`.
    public let actualDay: Day
    public let actualAmount: Money
    public let actualAccountID: String
    public let actualTitle: String?

    /// Signed day distance, negative when the actual came early.
    ///
    /// Stored, not recomputed: a candidate only exists because its distance
    /// was already measured inside the finite matching window, so the value is
    /// exact by construction rather than optional at every read.
    public let daysApart: Int

    /// 0...100. Ordering aid only; it never authorises a link.
    public let score: Int
    public let confidence: MatchConfidence
    public let signals: [MatchSignal]

    /// True when the amounts differ. Such a link is only ever made through an
    /// explicit acceptance of the difference — €4.00 expected is never
    /// silently treated as €3.49 actual.
    public var requiresAmountConfirmation: Bool {
        !signals.contains(.exactAmount)
    }
}

/// Everything matching needs, gathered once.
///
/// `titles` exists because a merchant name is presentation the app owns, not
/// domain the core stores: `Transaction` has no merchant field, so the caller
/// supplies the display titles it holds. The core stays pure and still gets to
/// use the strongest human signal there is.
public struct ReconciliationContext: Sendable {

    public let document: FinanceDocument
    public let ledger: ReconciliationLedger
    public let today: Day

    /// transaction id → merchant/title, as the app shows it.
    public let titles: [String: String]

    /// How far either side of the expected day a match may be considered.
    public let windowDays: Int

    public init(
        document: FinanceDocument,
        ledger: ReconciliationLedger? = nil,
        today: Day,
        titles: [String: String] = [:],
        windowDays: Int = ReconciliationMatcher.defaultWindowDays
    ) {
        self.document = document
        self.ledger = ledger ?? ReconciliationLedger(document.planning.settlements)
        self.today = today
        self.titles = titles
        self.windowDays = windowDays
    }
}

/// Proposes pairings between expected occurrences and actual transactions.
///
/// Conservative by construction:
///
/// - a different **currency** is never a candidate, at any score;
/// - an amount outside a narrow tolerance is never a candidate;
/// - an amount inside the tolerance but not exact is a candidate that
///   **requires explicit confirmation**;
/// - a different **account or rail** never disqualifies anything, because the
///   planning template describes an intention and the bank describes a fact.
///
/// Nothing here writes. Every function returns suggestions, ordered
/// deterministically, for a person to accept or ignore.
public enum ReconciliationMatcher {

    /// ± days around the expected day that a match may be considered within.
    /// Wide enough for a subscription that bills a few days late, narrow
    /// enough that next month's charge is never a candidate for this month.
    public static let defaultWindowDays = 10

    /// The largest amount difference that may still be *offered* (never
    /// accepted silently): a fifth of the expected amount, or two major units,
    /// whichever is larger. Exact integer arithmetic, like all money here —
    /// a tolerance computed in floating point would be a tolerance that
    /// disagrees with itself across machines.
    static func tolerance(for expected: Money) -> Int64 {
        let proportional = abs(expected.minorUnits) / 5
        let floor = 2 * expected.currency.minorUnitsPerMajor
        return max(proportional, floor)
    }

    // MARK: - Actual → expected occurrences

    /// Plausible expected occurrences for one actual transaction.
    ///
    /// The flow behind "open an actual expense → see plausible expected
    /// matches → choose *Matches expected payment*".
    public static func candidates(
        forActual transactionID: String,
        in context: ReconciliationContext
    ) -> [MatchCandidate] {
        guard let actual = context.document.transactions.first(where: { $0.id == transactionID }),
              isEligibleActual(actual, in: context)
        else { return [] }

        // The advisory expansion window. A window edge that leaves the day
        // domain yields no candidate: this expansion is an aid to matching,
        // and failing to build it proposes no candidate. It never changes what
        // is owed — the obligation and its ledger are untouched either way.
        let horizon = context.windowDays
        // A negative radius is invalid. Reject before negating it, since
        // Int.min has no representable positive counterpart.
        guard horizon >= 0 else { return [] }
        guard let windowStart = actual.date.advanced(by: -horizon),
              let windowEnd = actual.date.advanced(by: horizon)
        else { return [] }
        let occurrences = OccurrenceExpander.occurrences(
            in: context.document,
            from: windowStart,
            to: windowEnd,
            asOf: context.today,
            ledger: context.ledger
        )

        return occurrences
            .filter { !$0.status.isResolved }
            .compactMap { candidate(occurrence: $0, actual: actual, in: context) }
            .sorted(by: ordering)
    }

    // MARK: - Expected occurrence → actuals

    /// Plausible actual transactions for one expected occurrence.
    ///
    /// The flow behind "open an expected occurrence → *Mark as paid* → select
    /// an actual transaction".
    public static func candidates(
        forOccurrence occurrence: OccurrenceID,
        in context: ReconciliationContext
    ) -> [MatchCandidate] {
        let month = occurrence.expectedDay.monthKey
        let expanded = OccurrenceExpander.occurrences(
            in: context.document,
            from: month.firstDay,
            to: month.firstDay.lastDayOfMonth,
            asOf: context.today,
            ledger: context.ledger
        )
        guard let expected = expanded.first(where: { $0.id == occurrence }),
              !expected.status.isResolved
        else { return [] }

        return context.document.transactions
            .filter { isEligibleActual($0, in: context) }
            .compactMap { candidate(occurrence: expected, actual: $0, in: context) }
            .sorted(by: ordering)
    }

    // MARK: - Scoring one pairing

    /// Whether an actual is even allowed to settle something.
    ///
    /// Only an observed, non-reversed transaction that is already reconciled
    /// to nothing else qualifies. An expectation cannot settle an expectation,
    /// and a reversed debit never economically happened.
    static func isEligibleActual(_ actual: Transaction, in context: ReconciliationContext) -> Bool {
        actual.factivity == .observed
            && actual.lifecycle != .reversed
            && context.ledger.settlement(forActual: actual.id) == nil
    }

    static func candidate(
        occurrence: ExpectedOccurrence,
        actual: Transaction,
        in context: ReconciliationContext
    ) -> MatchCandidate? {
        let currency = occurrence.amount.currency

        // Currency is a hard wall (test 7). An outflow leg must exist in the
        // very currency the obligation is owed in; 50 MAD never settles €7.99,
        // whatever the numbers look like once converted.
        let outflows = actual.legs.filter { $0.isOutflow && $0.amount.currency == currency }
        guard !outflows.isEmpty else { return nil }

        let actualAmount = Money.sum(outflows.map { $0.amount.magnitude }, currency: currency)
        let expectedAmount = occurrence.amount.magnitude

        let difference = abs(actualAmount.minorUnits - expectedAmount.minorUnits)
        guard difference <= tolerance(for: expectedAmount) else { return nil }

        // Asked as a bounded distance: a separation too large to express as
        // an Int is outside every finite window, so it is simply not a
        // candidate. Nothing here negates a distance.
        guard occurrence.expectedDay.isWithin(days: context.windowDays, of: actual.date),
              let distance = occurrence.expectedDay.days(until: actual.date)
        else { return nil }

        var signals: [MatchSignal] = []
        var score = 0

        // Amount.
        let isExact = difference == 0
        if isExact {
            signals.append(.exactAmount)
            score += 60
        } else {
            signals.append(.amountDiffers(expected: expectedAmount, actual: actualAmount))
            score += 20
        }

        // Date proximity. The expected day may be inferred; the actual day is
        // evidence. Proximity is a hint, never a rewrite of either.
        if distance == 0 {
            signals.append(.sameDay)
            score += 30
        } else {
            signals.append(.daysApart(distance))
            switch distance.magnitude {
            case ...3: score += 22
            case ...7: score += 14
            default: score += 6
            }
        }

        // Title.
        let title = context.titles[actual.id]?.nilWhenBlank ?? actual.note?.nilWhenBlank
        switch titleAffinity(ruleName: occurrence.name, actualTitle: title) {
        case .strong:
            signals.append(.titleMatch)
            score += 10
        case .partial:
            signals.append(.titlePartialMatch)
            score += 5
        case .none:
            break
        }

        // Account/rail: recorded, never penalised.
        let accountID = outflows[0].accountID
        if let account = context.document.accounts.first(where: { $0.id == accountID }),
           !account.satisfies(occurrence.requirement) {
            signals.append(.paidFromUnexpectedAccount(accountID: accountID))
        }

        let confidence: MatchConfidence
        if isExact && distance.magnitude <= 7 {
            confidence = .strong
        } else if isExact || (signals.contains(.titleMatch) && distance.magnitude <= 7) {
            confidence = .plausible
        } else {
            confidence = .weak
        }

        return MatchCandidate(
            occurrence: occurrence.id,
            obligationName: occurrence.name,
            expectedDay: occurrence.expectedDay,
            expectedAmount: expectedAmount,
            actualTransactionID: actual.id,
            actualDay: actual.date,
            actualAmount: actualAmount,
            actualAccountID: accountID,
            actualTitle: title,
            daysApart: distance,
            score: score,
            confidence: confidence,
            signals: signals
        )
    }

    /// Deterministic ordering: best score first, then the closest date, then
    /// id — so the same data always proposes the same list in the same order.
    static func ordering(_ lhs: MatchCandidate, _ rhs: MatchCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.daysApart.magnitude != rhs.daysApart.magnitude {
            return lhs.daysApart.magnitude < rhs.daysApart.magnitude
        }
        return lhs.id < rhs.id
    }

    // MARK: - Title similarity

    enum TitleAffinity { case strong, partial, none }

    /// Token-overlap similarity, deliberately crude.
    ///
    /// "YouTube Premium via PayPal" and "YouTube Premium" share every word
    /// that carries meaning, which is all the signal needed. Words that only
    /// describe plumbing ("via", "the") are ignored so a rule naming its rail
    /// is not punished for it.
    static func titleAffinity(ruleName: String, actualTitle: String?) -> TitleAffinity {
        guard let actualTitle else { return .none }
        let ruleTokens = tokens(ruleName)
        let actualTokens = tokens(actualTitle)
        guard !ruleTokens.isEmpty, !actualTokens.isEmpty else { return .none }

        let shared = ruleTokens.intersection(actualTokens)
        guard !shared.isEmpty else { return .none }

        let coverage = Double(shared.count) / Double(min(ruleTokens.count, actualTokens.count))
        return coverage >= 0.6 ? .strong : .partial
    }

    /// Words that describe plumbing rather than the thing being paid for.
    /// Kept small on purpose: dropping a real merchant word would lose signal.
    private static let ignoredTokens: Set<String> = [
        "via", "the", "and", "for", "from", "payment", "monthly", "subscription"
    ]

    static func tokens(_ value: String) -> Set<String> {
        let lowered = value.lowercased()
        let parts = lowered.split { !$0.isLetter && !$0.isNumber }
        return Set(
            parts
                .map(String.init)
                .filter { $0.count > 1 && !ignoredTokens.contains($0) }
        )
    }
}

extension String {
    /// nil when the string is empty or only whitespace.
    var nilWhenBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
