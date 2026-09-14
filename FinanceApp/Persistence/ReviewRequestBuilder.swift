import FinanceCore
import Foundation

/// Which period a review is about, as a scope plus a whole-period offset from
/// the one containing `asOf`. `0` is the current period, `-1` the one before.
struct ReviewPeriodSelection: Hashable, Sendable {
    var scope: ReviewPeriodScope
    var offset: Int

    init(scope: ReviewPeriodScope = .month, offset: Int = 0) {
        self.scope = scope
        self.offset = offset
    }
}

/// Turns app state into a `ReviewRequest`.
///
/// Pure and explicit: every input is a parameter, nothing reads the clock, and
/// no engine rule is re-decided here. The builder's whole job is to say what
/// the app knows; `ReviewEngine` decides what it means.
enum ReviewRequestBuilder {

    // MARK: - Period arithmetic

    /// Weeks start on **Monday**. FinanceCore deliberately leaves the origin to
    /// the caller, and Monday is the convention where this ledger's banks and
    /// statements live.
    ///
    /// 1970-01-01 has index 0 and was a Thursday, three days after a Monday,
    /// which is where the `+ 3` comes from.
    ///
    /// This adapter requires a representable epoch ordinal; otherwise it
    /// returns nil rather than selecting a substitute week.
    static func startOfWeek(containing day: Day) -> Day? {
        guard let index = day.index else { return nil }
        // Reduce first: Swift's remainder is in -6...6, so the weekday
        // adjustment stays small even at either Int endpoint.
        let daysSinceMonday = ((index % 7 + 3) % 7 + 7) % 7
        return day.advanced(by: -daysSinceMonday)
    }

    /// The period's full calendar extent, before any clamping.
    ///
    /// Nil when the requested period lies outside the representable day
    /// domain. The screen then reports that it cannot show that period; it
    /// never navigates to a nearer one it can.
    static func calendarInterval(_ selection: ReviewPeriodSelection, asOf: Day) -> ReviewInterval? {
        switch selection.scope {
        case .week:
            // Whole weeks, as days: `7 * offset` overflows long before the
            // day domain does, so the multiplication is checked too.
            let (days, overflow) = selection.offset.multipliedReportingOverflow(by: 7)
            guard !overflow,
                  let origin = startOfWeek(containing: asOf),
                  let start = origin.advanced(by: days)
            else { return nil }
            return .weekStarting(start)
        case .month:
            // One checked movement, not `abs(offset)` single steps: `abs`
            // cannot express `Int.min` and the loop was quadratic in the
            // offset for no reason.
            guard let month = asOf.monthKey.advanced(byMonths: selection.offset) else { return nil }
            return .month(month)
        }
    }

    /// The days actually reviewed.
    ///
    /// A current period is clamped to `asOf`: the rest of this week has not
    /// happened, and reporting days in the future as "missing records" would
    /// be a coverage complaint about time rather than about evidence. Past
    /// periods keep their full extent.
    static func reviewedInterval(_ selection: ReviewPeriodSelection, asOf: Day) -> ReviewInterval? {
        guard let calendar = calendarInterval(selection, asOf: asOf) else { return nil }
        guard calendar.contains(asOf) else { return calendar }
        return ReviewInterval(start: calendar.start, end: asOf)
    }

    /// How far back review can go.
    ///
    /// Archive-era periods are not offered: reconstructing archive records into
    /// the engine's history input is not wired, and presenting an archive month
    /// with no records would read as a month in which nothing happened. The
    /// bound is therefore the first period lying wholly after the cutoff.
    static func earliestOffset(
        scope: ReviewPeriodScope,
        asOf: Day,
        archiveCutoff: Day?
    ) -> Int {
        guard let archiveCutoff else { return -24 }
        var offset = 0
        while offset > -240 {
            // A period that cannot be constructed cannot be offered either,
            // so the bound stops at the last one that can.
            guard let candidate = calendarInterval(
                ReviewPeriodSelection(scope: scope, offset: offset - 1), asOf: asOf
            ) else { return offset }
            if candidate.start <= archiveCutoff { return offset }
            offset -= 1
        }
        return offset
    }

    // MARK: - Request

    /// Assembles the request.
    ///
    /// - Parameters:
    ///   - document: the live ledger.
    ///   - categoryKeys: the app's own transaction → budget-category mapping,
    ///     the same one the month budget already uses.
    ///   - incomeSources: live income streams, used only through the existing
    ///     id-and-name bridge onto the canonical economic-source vocabulary.
    ///     Merchant text, counterparty and description never classify income.
    ///   - coverage: affirmative coverage, built by `ReviewCoverageAdapter`.
    static func makeRequest(
        document: FinanceDocument,
        selection: ReviewPeriodSelection,
        asOf: Day,
        categoryKeys: [String: String],
        incomeSources: [IncomeSource],
        coverage: ReviewCoverageInput,
        currency: Currency = .eur
    ) -> ReviewRequest? {
        guard let interval = reviewedInterval(selection, asOf: asOf) else { return nil }
        return ReviewRequest(
            document: document,
            kind: selection.scope == .week ? .weekly : .monthly,
            interval: interval,
            asOf: asOf,
            currency: currency,
            categoryKeys: categoryKeys,
            comparePreviousPeriod: true,
            coverage: coverage,
            // Exceptional is a user judgement the ledger does not record, and
            // an amount must never imply it. Leaving this empty means the
            // engine classifies from settlement and budget attribution alone.
            spendingNatures: [:],
            incomeClasses: [:],
            economicSources: economicSources(for: incomeSources),
            findingPolicy: .standard,
            forecastHorizonEnd: nil
        )
    }

    /// Canonical economic-source tokens for live income streams.
    ///
    /// This reuses the one accepted bridge between the live income-source
    /// dimension and the archive's canonical vocabulary: a stream qualifies
    /// through its own id and name and nothing else. A stream that matches no
    /// canonical token contributes none, which leaves its inflows unresolved
    /// rather than defaulted into earnings.
    static func economicSources(for incomeSources: [IncomeSource]) -> [String: String] {
        var result: [String: String] = [:]
        for source in incomeSources {
            guard let token = HistoryEconomicSource.canonicalSource(
                forLiveIncomeSourceID: source.id, name: source.name
            ) else { continue }
            result[source.id] = token
        }
        return result
    }
}
