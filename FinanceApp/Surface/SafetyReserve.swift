import Foundation

/// What the person configured as a cash floor, and how the projection sits
/// against it.
///
/// This is a **planning policy**, not a balance. The amount is copied from
/// `document.planning.safetyFloor` via the snapshot; the comparison is copied
/// from the same projection that already detects a reserve warning. Nothing
/// here recomputes a forecast, subtracts the reserve from Safe to Use, or
/// treats a breach as money that is missing.
enum SafetyReserveExplanation: Hashable, Sendable {
    /// No floor is configured. The plan does not warn about dipping into a
    /// buffer, because there is none.
    case none
    case configured(SafetyReserveBreakdown)
}

/// The configured floor, what it means, and — when the projection can say —
/// how projected cash sits against it.
struct SafetyReserveBreakdown: Hashable, Sendable {
    /// `FinanceAppSnapshot.safetyReserve`, copied. Never derived here.
    let amount: Amount
    let comparison: SafetyReserveComparison
}

/// How projected cash sits against the configured floor.
///
/// The lowest figure is `FinanceAppSnapshot.lowestPoint`: the true minimum of
/// the spendable pool, measured after every event, which is the same series
/// the floor itself is checked against. End-of-day weekly lows are a different
/// measurement and are not used here.
enum SafetyReserveComparison: Hashable, Sendable {
    /// Today's projection did not complete, or the figures are not in one
    /// currency. Nothing is invented.
    case unavailable
    /// The projected minimum stays on or above the floor.
    case staysAbove(lowest: Amount, headroom: Amount)
    /// The projected minimum is strictly below the floor. `firstDate` is the
    /// engine's first below-floor day when it has one; it is not inferred
    /// from the lowest point's date.
    case dipsBelow(lowest: Amount, gap: Amount, firstDate: CalendarDay?)
}

// MARK: - What the screen says

extension SafetyReserveBreakdown {

    static let meaning = "Cash you want to keep untouched as a buffer."

    static let distinction =
        "This is a planning floor on spendable cash, not money set aside for a goal and not Safe to Use. Changing it does not move money or rewrite what already happened."

    var summary: String {
        switch comparison {
        case .unavailable:
            return "Today's projection hasn't finished, so this screen won't guess how cash sits against the reserve."
        case let .staysAbove(_, headroom):
            if headroom.isZero {
                return "Projected cash stays at the reserve. It does not dip below it."
            }
            return "Projected cash stays \(headroom.formatted()) above the reserve."
        case let .dipsBelow(_, gap, firstDate):
            if let firstDate {
                return "Projected cash dips \(gap.formatted()) below the reserve, first on \(firstDate.formatted(.dateTime.day().month(.wide)))."
            }
            return "Projected cash dips \(gap.formatted()) below the reserve."
        }
    }
}

extension SafetyReserveExplanation {

    /// Builds the explanation from the published snapshot.
    ///
    /// - Parameter isAvailable: `FinanceStore.safeToUseIsAvailable` — the same
    ///   gate Home uses before showing any projected figure. A snapshot
    ///   retained from an earlier day still carries plausible-looking numbers,
    ///   so the gate is passed in rather than guessed from the array being
    ///   non-empty.
    static func make(
        from snapshot: FinanceAppSnapshot,
        isAvailable: Bool
    ) -> SafetyReserveExplanation {
        guard let amount = snapshot.safetyReserve else { return .none }

        return .configured(
            SafetyReserveBreakdown(
                amount: amount,
                comparison: comparison(
                    amount: amount,
                    lowest: snapshot.lowestPoint.projectedBalance,
                    firstBelowDate: snapshot.firstBelowReserveDate,
                    isAvailable: isAvailable
                )
            )
        )
    }

    /// Exposed for tests that pin the comparison rule without a store.
    static func comparison(
        amount: Amount,
        lowest: Amount,
        firstBelowDate: CalendarDay?,
        isAvailable: Bool
    ) -> SafetyReserveComparison {
        guard isAvailable else { return .unavailable }
        guard amount.currencyCode == lowest.currencyCode else { return .unavailable }

        if lowest.minorUnits >= amount.minorUnits {
            return .staysAbove(lowest: lowest, headroom: lowest - amount)
        }
        return .dipsBelow(
            lowest: lowest,
            gap: amount - lowest,
            firstDate: firstBelowDate
        )
    }
}
