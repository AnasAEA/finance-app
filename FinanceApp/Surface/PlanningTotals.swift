import Foundation

/// Totals Home and the Plan hub quote, derived from the snapshot and nothing
/// else.
///
/// They are summaries of figures the engine already produced, never a second
/// opinion about them: no threshold, no rounding, no rule that could disagree
/// with the canonical destination the row leads to.
enum PlanningTotals {
    /// Money protected for something. Fund reservations, plus reservations held
    /// directly against a goal that is not funded by a fund — never both, so a
    /// linked pair is not counted twice.
    ///
    /// This total is *not* subtracted from `safeToSpend`, and Home does not
    /// print it beside that figure: two available-money numbers side by side
    /// would imply the first already excluded the second.
    static func setAside(from snapshot: FinanceAppSnapshot) -> Amount {
        let zero = Amount.zero(snapshot.currencyCode)
        let fundTotal = snapshot.sinkingFunds.reduce(zero) { $0 + $1.reserved }
        let directGoal = snapshot.plannedPurchases.reduce(zero) { running, goal in
            guard goal.funding != .sinkingFund else { return running }
            return running + goal.reserved
        }
        return fundTotal + directGoal
    }

    /// What is worth naming on Home for the week ahead.
    ///
    /// Ranked by how much it matters, not by date: a rent payment four days out
    /// outranks a €15 phone bill tomorrow. `limit` is what actually fits under
    /// the hero, which is fewer rows when a shortfall line is also there.
    static func nextSevenDays(
        from snapshot: FinanceAppSnapshot,
        limit: Int,
        excludingEventID: String? = nil,
        calendar: Calendar = .current
    ) -> [PlannedEvent] {
        guard limit > 0 else { return [] }
        guard let end = sevenDayWindowEnd(from: snapshot) else { return [] }
        let window = snapshot.upcomingEvents.filter { event in
            event.date >= snapshot.asOf && event.date <= end
                && event.id != excludingEventID
        }
        return Array(
            window.sorted { first, second in
                let scoreA = relevance(of: first, from: snapshot.asOf)
                let scoreB = relevance(of: second, from: snapshot.asOf)
                if scoreA != scoreB { return scoreA > scoreB }
                return first.date < second.date
            }
            .prefix(limit)
        )
    }

    static func sevenDayWindowEnd(
        from snapshot: FinanceAppSnapshot,
        calendar: Calendar = .current
    ) -> CalendarDay? {
        _ = calendar
        guard let start = DomainMapper.day(snapshot.asOf),
              let end = start.advanced(by: 7)
        else { return nil }
        return DomainMapper.civilDay(end)
    }

    private static func relevance(
        of event: PlannedEvent,
        from asOf: CalendarDay
    ) -> Int64 {
        guard let start = DomainMapper.day(asOf),
              let finish = DomainMapper.day(event.date),
              let distance = start.days(until: finish)
        else { return 0 }
        let days = min(max(distance, 0), 7)
        return event.amount.magnitude.minorUnits / Int64(days + 1)
    }

    /// How many pieces of bank activity are waiting for a decision.
    static func reviewCount(from snapshot: FinanceAppSnapshot) -> Int {
        snapshot.syncedObservations.filter { $0.resolution == .unreviewed }.count
    }

    /// How many rows of the week ahead fit on Home under the hero.
    ///
    /// A shortfall hero is two lines taller, and pushing "View all" off the
    /// first screen to keep a third row would trade the way out for one more
    /// item.
    static func homeUpcomingLimit(hasShortfall: Bool) -> Int {
        hasShortfall ? 2 : 3
    }

    // MARK: - Shortfall

    /// What Home is entitled to say under "Safe to use" when money runs short.
    ///
    /// The amount and the day must come from the same computation. Home used to
    /// print a 30-day headroom deficit next to a date read off a 120-day
    /// forecast — two true numbers making one false sentence, because the gap
    /// quoted was never the gap on the day named. So either the forecast's own
    /// risk point supplies both, or the sentence names no day at all.
    static func shortfall(from snapshot: FinanceAppSnapshot) -> ShortfallStatement? {
        guard snapshot.safeToSpendReason.isShortfall else { return nil }
        // The forecast found the day, and reported what was missing when it
        // arrived. One object, one moment, one sentence.
        if let risk = snapshot.firstRisk, let missing = risk.shortfall {
            return .dated(amount: missing, date: risk.date)
        }
        // No risk day inside the horizon: committed payments still outrun the
        // money available, and that is worth saying — with its own window, and
        // deliberately without a date rather than borrowing one.
        guard let deficit = snapshot.safeToSpendReason.shortfallAmount else { return nil }
        return .undated(amount: deficit, withinDays: snapshot.safeToSpendWindowDays)
    }

    /// Whether the scenario switch can change what this month's plan expects.
    ///
    /// True only when every payment coming in is guaranteed, because the
    /// scenarios differ in exactly one way: how certain an expected inflow has
    /// to be to be counted. Guaranteed income clears every one of them, so the
    /// three plans are reading the same arrivals — which is worth a line when
    /// switching scenario visibly changes nothing.
    static func incomeIsScenarioIndependent(in month: MonthProjection) -> Bool {
        let inflows = month.events.filter(\.isInflow)
        guard !inflows.isEmpty else { return false }
        return inflows.allSatisfy(\.isGuaranteedButNotReceived)
    }
}

/// The one sentence Home says about running short, as a value rather than a
/// string, so that what it claims can be tested without a screen.
enum ShortfallStatement: Hashable, Sendable {
    /// The forecast reached a risk on a known day and reported the gap at that
    /// moment. Both halves come from that one risk point.
    case dated(amount: Amount, date: CalendarDay)
    /// A deficit over a window, with no day named. Carries the window's own
    /// length so the sentence can be specific about what it measured.
    case undated(amount: Amount, withinDays: Int)

    var amount: Amount {
        switch self {
        case .dated(let amount, _), .undated(let amount, _): amount
        }
    }

    var date: CalendarDay? {
        if case .dated(_, let date) = self { return date }
        return nil
    }
}
