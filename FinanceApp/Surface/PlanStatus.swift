import Foundation

/// Whether the plan holds, and what to do about it when it does not.
///
/// The Plan tab used to open on a menu: Budget, Safety reserve, Upcoming,
/// Goals, affordability. Five mature tools and no answer to the question the
/// tab exists for. A person who arrived because Home said money was missing
/// read "Budget — 198,00 € left of 750,00 € this month" at the top of a plan
/// that could not fund itself, and had to guess which row led to the problem.
///
/// ## This states no new fact
///
/// Every case here is a restatement of one `RequiredFundingGapFact` the
/// attention engine already produced from one forecast run, or of that
/// engine's own verdict that there is nothing to report. There is no second
/// funding formula, no threshold, and no rule that could disagree with the
/// destination the status leads to. The engine's two risks stay two risks:
/// `.fundingGap` is money that is genuinely missing, `.reserveWarning` is a
/// funded plan crossing a floor the person chose, and neither is ever written
/// in the other's words.
///
/// ## What it may not say
///
/// `.funded` is a claim, so it is made only when every source a funding
/// statement rests on — `AttentionFactAdapters.fundingGapDependencies` — was
/// recorded available. Two absences would otherwise read as safety: a forecast
/// that ran but whose first risk was rejected as incoherent, and a real gap
/// suppressed because a balance could not be established. Neither is a funded
/// plan; both are unknown ones, and unknown is a case here rather than a
/// silence. Nothing is zero-filled and no horizon is quoted that a run did not
/// establish.
struct PlanStatusPresentation: Hashable, Sendable {

    let kind: PlanStatusKind

    /// The one sentence that answers "does my plan hold?".
    let headline: String

    /// The fact behind the headline, when there is one worth stating. Never a
    /// second figure competing with the first.
    let detail: String?

    /// What to do, and the canonical screen that does it. Absent when there is
    /// genuinely nothing to do and when nothing can be established.
    let action: PlanStatusAction?

    /// The forecast event that triggered the risk, so the screen listing what
    /// is coming can mark the payment the status is about instead of showing
    /// it as one row among many. Carried verbatim from the fact; nil whenever
    /// there is no risk to attribute.
    let triggerEventID: String?
}

/// Which of the four things is true. A closed vocabulary: the presentation
/// layer picks copy from it and never infers a fifth state from an amount.
enum PlanStatusKind: String, Hashable, Sendable {
    /// The projection ran, held together, and found no cash risk in its horizon.
    case funded
    /// Money is missing on a day. Somebody has to find it.
    case fundingGap
    /// Still funded. The margin the person set is what is being spent into.
    case reserveWarning
    /// The plan cannot be judged right now, and says so.
    case unavailable
}

struct PlanStatusAction: Hashable, Sendable {
    let title: String
    /// One of the destinations the app already owns. Plan never duplicates a
    /// screen it can route to.
    let destination: AttentionDestination
}

extension PlanStatusPresentation {

    /// The eyebrow above the headline. Plan states a condition rather than
    /// shouting a task: Home owns "NEEDS ACTION", and the same alarm raised in
    /// the same words on two tabs is one alarm too many.
    static let eyebrow = "YOUR PLAN"

    /// Whether this state warrants the one tint the hub is allowed to use.
    var isTinted: Bool { kind == .fundingGap || kind == .reserveWarning }

    /// Nothing to establish and nothing to do: the status still renders, but
    /// as a statement of ignorance rather than of safety.
    static let projectionUnavailable = PlanStatusPresentation(
        kind: .unavailable,
        headline: "Your plan can't be checked right now.",
        detail: "Today's projection isn't available, so this can't say whether the plan is funded.",
        action: nil,
        triggerEventID: nil
    )
}
