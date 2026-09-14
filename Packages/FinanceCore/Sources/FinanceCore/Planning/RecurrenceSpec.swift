import Foundation

/// When something happens repeatedly (or once).
///
/// Deliberately minimal: exact monthly day, an observed monthly window
/// (forecast on the **earliest** day — conservative), or a one-shot date.
/// No ported Excel formula weirdness.
public enum RecurrenceSpec: Hashable, Sendable, Codable {

    /// Happens once, on this day.
    case oneShot(on: Day)

    /// Happens every month on `dayOfMonth` (clamped to shorter months:
    /// day 31 in April becomes April 30), from `from` through `through`
    /// (inclusive; nil = open-ended).
    case monthly(onDay: Int, from: MonthKey, through: MonthKey?)

    /// Happens every month inside `[earliestDay, latestDay]`. The forecast
    /// places it on `earliestDay` — money is planned to be ready at the
    /// earliest plausible moment, never the latest.
    case monthlyWindow(earliestDay: Int, latestDay: Int, from: MonthKey, through: MonthKey?)

    /// Expands this spec to all occurrence days inside `[start, end]`
    /// (inclusive). Deterministic, ascending.
    public func occurrences(from start: Day, to end: Day) -> [Day] {
        guard start <= end else { return [] }
        var result: [Day] = []
        switch self {
        case let .oneShot(on):
            if on >= start && on <= end { result.append(on) }
        case let .monthly(onDay, from, through):
            var month = max(from, start.monthKey)
            while month <= end.monthKey {
                if let through, month > through { break }
                let day = month.firstDay.clampedDay(onDay)
                if day >= start && day <= end { result.append(day) }
                // The requested final month is emitted before any advance, so
                // the schedule never asks for a month past the window's end.
                guard month < end.monthKey, let following = month.next else { break }
                month = following
            }
        case let .monthlyWindow(earliestDay, _, from, through):
            var month = max(from, start.monthKey)
            while month <= end.monthKey {
                if let through, month > through { break }
                let day = month.firstDay.clampedDay(earliestDay)
                if day >= start && day <= end { result.append(day) }
                guard month < end.monthKey, let following = month.next else { break }
                month = following
            }
        }
        return result
    }

    // MARK: - Codable (tagged object)

    private enum CodingKeys: String, CodingKey {
        case kind, day, from, through, earliestDay, latestDay
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "one_shot":
            self = .oneShot(on: try container.decode(Day.self, forKey: .day))
        case "monthly":
            self = .monthly(
                onDay: try container.decode(Int.self, forKey: .day),
                from: try container.decode(MonthKey.self, forKey: .from),
                through: try container.decodeIfPresent(MonthKey.self, forKey: .through)
            )
        case "monthly_window":
            self = .monthlyWindow(
                earliestDay: try container.decode(Int.self, forKey: .earliestDay),
                latestDay: try container.decode(Int.self, forKey: .latestDay),
                from: try container.decode(MonthKey.self, forKey: .from),
                through: try container.decodeIfPresent(MonthKey.self, forKey: .through)
            )
        case let other:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown recurrence kind '\(other)'")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .oneShot(on):
            try container.encode("one_shot", forKey: .kind)
            try container.encode(on, forKey: .day)
        case let .monthly(onDay, from, through):
            try container.encode("monthly", forKey: .kind)
            try container.encode(onDay, forKey: .day)
            try container.encode(from, forKey: .from)
            try container.encodeIfPresent(through, forKey: .through)
        case let .monthlyWindow(earliestDay, latestDay, from, through):
            try container.encode("monthly_window", forKey: .kind)
            try container.encode(earliestDay, forKey: .earliestDay)
            try container.encode(latestDay, forKey: .latestDay)
            try container.encode(from, forKey: .from)
            try container.encodeIfPresent(through, forKey: .through)
        }
    }
}

/// How essential a class of spending is. Used for budgeting and for what a
/// "safety floor" protects.
public enum SpendingClass: String, Sendable, Codable, CaseIterable {
    /// Must be paid: rent, utilities, food floor, arrears.
    case essential
    /// Real but adjustable: groceries above the floor, transport, social food.
    case flexible
    /// Optional subscriptions and discretionary spending.
    case optional
}

/// Whether a budget target is the person's own decision or something the app
/// worked out and is still only proposing.
///
/// The distinction is load-bearing, not cosmetic: a suggested split derived
/// from past behaviour must never be displayed, exported, or reasoned about as
/// though the person had agreed to it.
public enum BudgetConfirmation: String, Codable, Hashable, Sendable, CaseIterable {
    /// Proposed by the app from evidence. Awaiting a decision.
    case suggested
    /// Explicitly set or accepted by the person.
    case userConfirmed
}

/// A named monthly spending envelope with an effective date range and optional
/// per-month overrides.
public struct BudgetAllocation: Hashable, Sendable, Codable {

    public let id: String
    public var name: String
    public var spendingClass: SpendingClass

    /// Monthly amount while in effect (before any override).
    public var monthlyAmount: Money

    public var effectiveFrom: MonthKey
    public var effectiveThrough: MonthKey?

    /// Explicit per-month exceptions (e.g. a half month at €85 before the full
    /// €170 starts). Serialized sorted for deterministic output.
    public var monthlyOverrides: [MonthKey: Money]

    /// Whether this target is the person's decision or still a proposal.
    public var confirmation: BudgetConfirmation

    /// The spending categories whose transactions count against this line.
    ///
    /// Kept explicit and disjoint across lines. Nothing is matched by name:
    /// a category absent from every line leaves its spending uncategorised,
    /// which the month report reports rather than hides.
    public var categoryKeys: [String]

    public init(
        id: String,
        name: String,
        spendingClass: SpendingClass,
        monthlyAmount: Money,
        effectiveFrom: MonthKey,
        effectiveThrough: MonthKey? = nil,
        monthlyOverrides: [MonthKey: Money] = [:],
        confirmation: BudgetConfirmation = .suggested,
        categoryKeys: [String] = []
    ) {
        self.id = id
        self.name = name
        self.spendingClass = spendingClass
        self.monthlyAmount = monthlyAmount
        self.effectiveFrom = effectiveFrom
        self.effectiveThrough = effectiveThrough
        self.monthlyOverrides = monthlyOverrides
        self.confirmation = confirmation
        self.categoryKeys = categoryKeys
    }

    /// The budgeted amount for a month, or nil when the allocation is not in
    /// effect then. An override beats the base amount.
    public func amount(for month: MonthKey) -> Money? {
        guard month >= effectiveFrom else { return nil }
        if let through = effectiveThrough, month > through { return nil }
        return monthlyOverrides[month] ?? monthlyAmount
    }

    // MARK: - Codable (overrides as a sorted array)

    private struct OverrideEntry: Codable {
        let month: MonthKey
        let amount: Money
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, spendingClass, monthlyAmount, effectiveFrom, effectiveThrough, monthlyOverrides
        case confirmation, categoryKeys
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.spendingClass = try container.decode(SpendingClass.self, forKey: .spendingClass)
        self.monthlyAmount = try container.decode(Money.self, forKey: .monthlyAmount)
        self.effectiveFrom = try container.decode(MonthKey.self, forKey: .effectiveFrom)
        self.effectiveThrough = try container.decodeIfPresent(MonthKey.self, forKey: .effectiveThrough)
        let entries = try container.decode([OverrideEntry].self, forKey: .monthlyOverrides)
        self.monthlyOverrides = Dictionary(entries.map { ($0.month, $0.amount) }, uniquingKeysWith: { a, _ in a })
        // Additive in 1.4.0. A document written before budget confirmation
        // existed cannot claim the person agreed to its numbers, so an absent
        // field reads as `suggested` rather than as consent.
        self.confirmation = try container.decodeIfPresent(BudgetConfirmation.self, forKey: .confirmation) ?? .suggested
        self.categoryKeys = try container.decodeIfPresent([String].self, forKey: .categoryKeys) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(spendingClass, forKey: .spendingClass)
        try container.encode(monthlyAmount, forKey: .monthlyAmount)
        try container.encode(effectiveFrom, forKey: .effectiveFrom)
        try container.encodeIfPresent(effectiveThrough, forKey: .effectiveThrough)
        try container.encode(
            monthlyOverrides
                .map { OverrideEntry(month: $0.key, amount: $0.value) }
                .sorted { ($0.month.year, $0.month.month) < ($1.month.year, $1.month.month) },
            forKey: .monthlyOverrides
        )
        if confirmation != .suggested { try container.encode(confirmation, forKey: .confirmation) }
        if !categoryKeys.isEmpty { try container.encode(categoryKeys.sorted(), forKey: .categoryKeys) }
    }
}
