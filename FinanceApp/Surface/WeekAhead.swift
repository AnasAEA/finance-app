import Foundation

/// What the projection already says about the week ahead, read as one answer.
///
/// **This is projected cash, and nothing else.** A `RunwayPoint` is the
/// spendable euro pool at the *close* of one calendar day, after every event
/// that day has been applied — so it is a state at a date, never a position
/// before or after one particular payment. Several events routinely share a
/// day and are folded into the same point, and the point carries no link back
/// to any of them. Nothing here may therefore attribute the week's low to an
/// event: the model does not know which one it was.
///
/// It is also **not** `safeToSpend`, not `accountCash`, and not an
/// affordability verdict. `safeToSpend` is liquidity less committed outflows
/// over its own 30-day window, clamped at zero; `accountCash` counts every
/// euro non-cash balance; the pool counts only *active* accounts that satisfy
/// the euro bank-rail requirement. Three different aggregates measuring three
/// different things. None of them is expected to reconcile with the others,
/// and this type never subtracts one from another.
///
/// The only arithmetic performed is a minimum over values the engine already
/// produced.
struct WeekAheadSummary: Hashable, Sendable {

    /// The lowest projected end-of-day cash inside the window.
    let low: Amount
    /// The day that close falls on. The earliest, when several days tie —
    /// see `make(from:isAvailable:)`.
    let day: CalendarDay
    /// The window's inclusive bounds, the same ones the event list beside this
    /// row uses. Carried so a sentence about the week cannot quietly measure a
    /// different week from the rows underneath it.
    let windowStart: CalendarDay
    let windowEnd: CalendarDay
    /// How many days of projection the minimum was taken over. A partial
    /// window is reported as it is rather than padded.
    let dayCount: Int
    /// Facts that qualify the figure without changing it.
    let notes: [WeekAheadNote]
}

/// Something the projection itself establishes about this week. Never a
/// threshold, classification or causal claim invented here.
enum WeekAheadNote: Hashable, Sendable {
    /// The plan already reports its first cash risk on this same day, and it
    /// is a projected shortfall. Restated, deliberately without its amount:
    /// the attention card owns that figure, and a second copy on Home would
    /// be a second risk system.
    case shortfallOnThisDay
    /// As above, but the plan stays funded and crosses the safety reserve.
    /// A different problem with a different answer, which is why the row is
    /// not allowed to say "cash risk" for both.
    case belowReserveOnThisDay
    /// The window admits an inflow the plan does not treat as certain, so the
    /// low could be worse than shown. `PlannedEvent.certaintyLabel` is the
    /// model's own flag for this; nothing is inferred from an amount.
    case includesUncertainIncome

    var sentence: String {
        switch self {
        case .shortfallOnThisDay:
            "The plan projects a cash shortfall on this day."
        case .belowReserveOnThisDay:
            "The plan projects cash below your safety reserve on this day."
        case .includesUncertainIncome:
            "It counts income the plan doesn't treat as certain, so it could be lower."
        }
    }
}

extension WeekAheadSummary {

    /// The row's own label. Says *cash*, because that is what the series is.
    static let title = "Lowest projected cash"

    /// Weekday and date together: inside seven days the weekday is what a
    /// person plans around, and the date is what makes it unambiguous.
    var dayText: String {
        day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    /// Builds the summary, or nothing at all.
    ///
    /// Returning `nil` is the conservative outcome and is used for every case
    /// where a weekly minimum would be a claim the data does not support: no
    /// projection, no points inside the window, or points that do not share
    /// one currency. Nothing is padded, substituted or assumed to be zero.
    ///
    /// - Parameter isAvailable: `FinanceStore.safeToUseIsAvailable`, which is
    ///   the store's test for *the projection having run* — the same gate Home
    ///   uses before showing any projected figure. A snapshot retained from an
    ///   earlier day still carries plausible-looking points, so the gate is
    ///   passed in rather than guessed from the array being non-empty.
    static func make(
        from snapshot: FinanceAppSnapshot,
        isAvailable: Bool
    ) -> WeekAheadSummary? {
        guard isAvailable else { return nil }
        // The same window the seven-day event list is built over, taken from
        // the one place that defines it: inclusive of today and of day seven.
        guard let end = PlanningTotals.sevenDayWindowEnd(from: snapshot) else { return nil }
        let start = snapshot.asOf

        // Sorted here rather than trusted to arrive ascending, so "earliest
        // day wins a tie" is true by construction and not by assumption about
        // the producer.
        let window = snapshot.runwayPoints
            .filter { $0.date >= start && $0.date <= end }
            .sorted { $0.date < $1.date }
        guard let first = window.first else { return nil }

        // The pool is single-currency by construction — foreign holdings are
        // tracked outside it and never converted — so disagreement here means
        // something upstream changed, and a minimum across currencies would be
        // a number nothing could check.
        guard window.allSatisfy({ $0.balance.currencyCode == first.balance.currencyCode })
        else { return nil }

        // Strictly-less keeps the first of equal minima, which after the sort
        // above is the earliest day. A tie is the same amount on two days, so
        // choosing between them has no financial consequence; only the date
        // shown changes, and it is the nearer one.
        var lowest = first
        for point in window.dropFirst() where point.balance.minorUnits < lowest.balance.minorUnits {
            lowest = point
        }

        return WeekAheadSummary(
            low: lowest.balance,
            day: lowest.date,
            windowStart: start,
            windowEnd: end,
            dayCount: window.count,
            notes: notes(from: snapshot, on: lowest.date, start: start, end: end)
        )
    }

    private static func notes(
        from snapshot: FinanceAppSnapshot,
        on day: CalendarDay,
        start: CalendarDay,
        end: CalendarDay
    ) -> [WeekAheadNote] {
        var notes: [WeekAheadNote] = []

        // The engine attributed this day to a trigger event; this row does
        // not. All that is said is that the day the plan already flags and the
        // day of the week's low are the same day — and which of the engine's
        // two risks it reported, which it also already decided.
        //
        // An unclassified risk says nothing at all rather than something
        // vague: "below zero" and "below your reserve" are not interchangeable
        // and neither may stand in for an unknown.
        if let risk = snapshot.firstRisk, risk.date == day, let kind = risk.kind {
            switch kind {
            case .hardDeficit: notes.append(.shortfallOnThisDay)
            case .reserveWarning: notes.append(.belowReserveOnThisDay)
            }
        }

        let admitsUncertainIncome = snapshot.upcomingEvents.contains { event in
            event.isInflow && event.certaintyLabel != nil
                && event.date >= start && event.date <= end
        }
        if admitsUncertainIncome { notes.append(.includesUncertainIncome) }

        return notes
    }
}
