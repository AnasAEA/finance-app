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
            summarizedUpcomingEventID: nil
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
    case banksAndSync
    case account(String)
    case observationReview(String)
    case expectedPayment(ExpectedPayment)
    case activityToReview
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
