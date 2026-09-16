import Foundation

/// Display-safe output of the financial-attention presentation boundary.
/// Views never receive engine vocabulary, eligibility/suppression diagnostics,
/// or checkpoint enums.
struct AttentionPresentation: Hashable, Sendable {
    let heroIsAvailable: Bool
    let home: HomeAttentionPresentation
    let actionableReviewCount: Int
    let activity: ActivityAttentionPresentation
    let fundingNeeded: FundingNeededPresentation?
    /// The exact canonical forecast event already summarized by the primary
    /// funding card. Home excludes only this event from its seven-day list.
    let summarizedUpcomingEventID: String?
    /// Whether the plan holds, for the tab that exists to answer that.
    ///
    /// Composed from the same `AttentionState` as `home` and never from a
    /// second evaluation, so the two surfaces cannot contradict each other
    /// about one forecast. They are allowed to *say different things*: Home
    /// asks what needs doing now, Plan asks whether the plan works and what to
    /// change, and a reserve breach is a different destination in each.
    let plan: PlanStatusPresentation
}

extension AttentionPresentation {
    static func initial(heroIsAvailable: Bool = false) -> AttentionPresentation {
        AttentionPresentation(
            heroIsAvailable: heroIsAvailable,
            home: .indeterminate(
                AttentionUncertainty(
                    message: "Today's financial checks haven't completed yet.",
                    destination: nil
                )
            ),
            actionableReviewCount: 0,
            activity: ActivityAttentionPresentation(
                decisions: [], paymentsToConfirm: [], pending: [], limitations: []
            ),
            fundingNeeded: nil,
            summarizedUpcomingEventID: nil,
            plan: .projectionUnavailable
        )
    }
}

enum HomeAttentionPresentation: Hashable, Sendable {
    case act(HomeAttentionCard, reviewCount: Int)
    case reviewOnly(reviewCount: Int)
    case quiet(detail: String?)
    case indeterminate(AttentionUncertainty)
}

struct HomeAttentionCard: Hashable, Sendable {
    let title: String
    let detail: String?
    let actionTitle: String
    let destination: AttentionDestination
    /// Home may tint this one block. No other attention element is tinted.
    let isTinted: Bool
}

struct AttentionUncertainty: Hashable, Sendable {
    let message: String
    let destination: AttentionDestination?
}

enum AttentionDestination: Hashable, Sendable {
    case planFundingNeeded
    /// The Plan destination that already lists what is coming.
    ///
    /// Used for a projected risk the Funding Needed screen cannot explain,
    /// because that screen exists to describe one payment that could not be
    /// settled and this risk has no such payment: the reserve is simply being
    /// spent into, or the run opened short. Offering it anyway reached a
    /// "Funding detail unavailable" dead end.
    case planUpcoming
    /// The Plan destination that owns the safety reserve: what the floor is,
    /// how the projection sits against it, and the field that changes it.
    ///
    /// Reached from the Plan status when the plan stays funded and crosses
    /// that floor, because the reserve is the thing the person can actually
    /// act on there. Home deliberately does not send anyone here — it asks
    /// what needs doing, and adjusting a planning policy is not that.
    case planSafetyReserve
    case banksAndSync
    case account(String)
    case observationReview(String)
    case expectedPayment(ExpectedPayment)
    case activityToReview
    /// The canonical Insights ended-month verification detail for this period.
    case insightsMonthVerification(ReviewPeriodSelection)
}

struct ActivityAttentionPresentation: Hashable, Sendable {
    let decisions: [ActivityAttentionRow]
    let paymentsToConfirm: [ActivityAttentionRow]
    let pending: [ActivityPendingRow]
    let limitations: [ActivityLimitationRow]

    var isEmpty: Bool {
        decisions.isEmpty && paymentsToConfirm.isEmpty
            && pending.isEmpty && limitations.isEmpty
    }
}

struct ActivityAttentionRow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let amount: Amount
    let destination: AttentionDestination
}

struct ActivityPendingRow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let amount: Amount
    let day: CalendarDay?
}

struct ActivityLimitationRow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let amount: Amount?
}

struct FundingNeededPresentation: Hashable, Sendable {
    let title: String
    let trigger: String?
    let day: CalendarDay
    let requested: Amount
    let settled: Amount
    let unsettled: Amount
    let subject: FundingSubjectPresentation
    let beforeThen: [PlannedEvent]
    let footer: String
}

enum FundingSubjectPresentation: Hashable, Sendable {
    case account(name: String, kind: String)
    case paymentAccounts(names: [String])
}
