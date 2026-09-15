import Foundation

/// Why Home's headline is the figure it is.
///
/// The engine reaches "safe to use" by subtracting one number from another:
/// the money on accounts that can actually settle a payment, less the
/// obligations already committed inside the window. Both halves were already
/// computed; only the result was ever shown. This type carries that
/// subtraction to the screen.
///
/// It is a **restatement, never a second opinion**. `safeToUse` is copied from
/// the snapshot verbatim and is never recomputed here, the two components are
/// copied from the snapshot as well, and a breakdown is published only when
/// `cash − committed` clamps to the headline **to the cent**. When it does
/// not, this reports `.unavailable` instead: a person is better served by no
/// explanation than by an explanation that argues with the number above it.
enum SafeToUseExplanation: Hashable, Sendable {
    case explained(SafeToUseBreakdown)
    case unavailable(SafeToUseUnavailability)
}

/// The subtraction, plus what surrounds it without being part of it.
struct SafeToUseBreakdown: Hashable, Sendable {
    /// `FinanceAppSnapshot.safeToSpend`, copied. Never derived here.
    let safeToUse: Amount
    /// `FinanceAppSnapshot.accountCash` — balances that can settle a payment
    /// in the home currency today.
    let cash: Amount
    /// `FinanceAppSnapshot.committedOutflows`, positive: what is already
    /// committed inside `windowDays`.
    let committed: Amount
    /// `cash − committed`, signed. Equals `safeToUse` when positive, and goes
    /// below zero when commitments already outrun the money available — which
    /// the clamped headline cannot say for itself.
    let headroom: Amount
    /// The window `committed` was measured over. Carried rather than assumed:
    /// the snapshot holds two horizons and a sentence that borrows the wrong
    /// one is a wrong sentence.
    let windowDays: Int
    let outcome: Outcome
    /// Facts that bear on the figure without being terms of it. Never summed
    /// into anything above.
    let notes: [SafeToUseNote]

    /// What the person is actually looking at.
    enum Outcome: Hashable, Sendable {
        /// Money is free to use.
        case headroom
        /// The commitments exactly consume what is there. Not a shortfall.
        case nothingFree
        /// Commitments already outrun the money available. Carries the one
        /// sentence Home is entitled to say about it, when there is one.
        case short(ShortfallStatement?)
    }
}

/// Something true about the figure that is deliberately **not** one of its
/// terms. Presenting these as components would imply the headline already
/// subtracted them, and it did not.
enum SafeToUseNote: Hashable, Sendable {
    /// Money reserved against goals and sinking funds. It is still sitting in
    /// the accounts, so it is inside `cash` and inside `safeToUse`; planning
    /// reservations do not reduce the headline today.
    case setAside(Amount)
    /// Holdings the figure excludes: notes and coins, and anything held in
    /// another currency. `HoldingLine.isSpendableHere` is the same test the
    /// engine applies when it totals spendable liquidity, so this names
    /// exactly what was left out and nothing else.
    case notCounted([HoldingLine])
}

/// Why there is no breakdown to show.
enum SafeToUseUnavailability: Hashable, Sendable {
    /// Today's projection did not complete, so there is no figure to explain.
    case projectionUnavailable
    /// The snapshot's own components do not reconcile with its headline.
    /// Refusing is the point: nothing here is allowed to print a sum that
    /// disagrees with the authoritative answer.
    case componentsDoNotReconcile
}

// MARK: - What the screen says

/// The sentences are values, so what this screen claims can be tested without
/// rendering it — the same reason `ShortfallStatement` exists.
extension SafeToUseBreakdown {

    var isShort: Bool {
        if case .short = outcome { return true }
        return false
    }

    /// The window, said once, in the person's terms.
    var windowCaption: String {
        "Over the next \(windowDays) day\(windowDays == 1 ? "" : "s")"
    }

    /// The line under the headline.
    ///
    /// A shortfall is named **once**. The projection also knows the day the
    /// balance first falls short and what was missing at that moment, and
    /// those are a different measurement over a different span: printing that
    /// amount here beside the window deficit below would put two shortfall
    /// figures on one screen and leave a person to guess which one they are
    /// in. So the day is borrowed and the amount is not.
    var summary: String {
        let window = "the next \(windowDays) day\(windowDays == 1 ? "" : "s")"
        switch outcome {
        case .headroom:
            return "What is left on your accounts once everything already committed in \(window) is covered."
        case .nothingFree:
            return "Everything on your accounts is already committed in \(window). Nothing is free to use."
        case let .short(statement):
            let opening = "Committed payments come to more than the money on your accounts, so nothing is free to use."
            guard let date = statement?.date else { return opening }
            let day = date.formatted(.dateTime.day().month(.wide))
            return opening + " Your balance is first projected to fall short on \(day)."
        }
    }

    /// The last row of the subtraction.
    var resultLabel: String {
        isShort ? "Short by" : "Safe to use"
    }

    /// What that row prints. A shortfall is written as the amount it is short
    /// by, because "short by −256,00 €" says the same thing twice and reads
    /// as its own opposite. `headroom` keeps the signed truth for anything
    /// that needs to do arithmetic with it.
    var resultValue: Amount {
        isShort ? headroom.magnitude : headroom
    }

    var methodFooter: String {
        let base = "Moving money between your own accounts, cash withdrawals and your everyday spending are not part of this. Only obligations already committed are."
        return isShort
            ? base + " Safe to use is shown as zero rather than as a negative amount."
            : base
    }
}

extension SafeToUseExplanation {

    /// Builds the explanation from the published snapshot.
    ///
    /// - Parameter isAvailable: `FinanceStore.safeToUseIsAvailable` — the same
    ///   gate that decides whether Home shows the headline at all. Passed in
    ///   rather than guessed from the figures, because a snapshot retained
    ///   from an earlier day still carries plausible-looking numbers.
    static func make(
        from snapshot: FinanceAppSnapshot,
        isAvailable: Bool
    ) -> SafeToUseExplanation {
        guard isAvailable else { return .unavailable(.projectionUnavailable) }

        let cash = snapshot.accountCash
        let committed = snapshot.committedOutflows
        let safeToUse = snapshot.safeToSpend

        // Arithmetic is defined within one currency. A mixed subtraction here
        // would trap, and a figure that survived it would be wrong in a way
        // nothing downstream could detect.
        guard cash.currencyCode == committed.currencyCode,
              cash.currencyCode == safeToUse.currencyCode
        else { return .unavailable(.componentsDoNotReconcile) }

        let headroom = cash - committed

        // Integer cents decide it. `safeToSpend` is the clamped headroom, so
        // the components reconcile exactly or they do not reconcile at all.
        guard max(headroom.minorUnits, 0) == safeToUse.minorUnits else {
            return .unavailable(.componentsDoNotReconcile)
        }

        let outcome: SafeToUseBreakdown.Outcome
        if headroom.isNegative {
            outcome = .short(PlanningTotals.shortfall(from: snapshot))
        } else if headroom.isZero {
            outcome = .nothingFree
        } else {
            outcome = .headroom
        }

        return .explained(
            SafeToUseBreakdown(
                safeToUse: safeToUse,
                cash: cash,
                committed: committed,
                headroom: headroom,
                windowDays: snapshot.safeToSpendWindowDays,
                outcome: outcome,
                notes: notes(from: snapshot, homeCurrency: cash.currencyCode)
            )
        )
    }

    private static func notes(
        from snapshot: FinanceAppSnapshot,
        homeCurrency: String
    ) -> [SafeToUseNote] {
        var notes: [SafeToUseNote] = []

        // The same total the Plan hub prints, read from the one place that
        // computes it. Nothing is said when nothing is reserved.
        let setAside = PlanningTotals.setAside(from: snapshot)
        if setAside.isPositive, setAside.currencyCode == homeCurrency {
            notes.append(.setAside(setAside))
        }

        let excluded = snapshot.trackedHoldings.filter {
            !$0.isSpendableHere && !$0.balance.isZero
        }
        if !excluded.isEmpty { notes.append(.notCounted(excluded)) }

        return notes
    }
}
