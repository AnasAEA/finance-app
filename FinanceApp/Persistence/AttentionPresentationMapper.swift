import Foundation

/// The sole display-facing reader of Phase 2.9A attention semantics.
///
/// It translates eligibility, dependency failures, candidate kinds and source
/// diagnostics into stable product language. SwiftUI receives only the values
/// in `Surface/Attention.swift` and performs no financial arithmetic.
enum AttentionPresentationMapper {
    static func present(
        _ state: AttentionState,
        snapshot: FinanceAppSnapshot,
        heroIsAvailable: Bool
    ) -> AttentionPresentation {
        let activity = activity(state, snapshot: snapshot)
        let reviewCount = activity.decisions.count + activity.paymentsToConfirm.count
        let primary = state.primary
        let funding = primary.flatMap { fundingNeeded($0, snapshot: snapshot) }

        let home: HomeAttentionPresentation
        switch state.outcome {
        case let .noActionNeeded(quiet):
            home = .quiet(detail: quiet.horizonEnd.map {
                "No cash shortfall is projected through \(dayText($0))."
            })
        case let .indeterminate(failedKeys):
            home = .indeterminate(uncertainty(for: failedKeys))
        case .actionsAvailable:
            if let primary, isActBand(primary.kind),
               let card = actionCard(primary, snapshot: snapshot) {
                home = .act(card, reviewCount: reviewCount)
            } else if let month = state.actionableCandidates.first(where: {
                $0.kind == .monthReadyToClose
            }), let card = actionCard(month, snapshot: snapshot) {
                // Funding, bank connection and drift stay more urgent. When
                // none of those is the Home card, an ended month that needs
                // verification is the one meaningful next action.
                home = .act(card, reviewCount: reviewCount)
            } else {
                home = .reviewOnly(reviewCount: reviewCount)
            }
        }

        let summarizedEventID: String?
        if case .act = home,
           primary?.kind == .requiredFundingGap,
           case let .fundingGap(fact)? = primary?.detail {
            summarizedEventID = fact.triggerEventID
        } else {
            summarizedEventID = nil
        }

        return AttentionPresentation(
            heroIsAvailable: heroIsAvailable,
            home: home,
            actionableReviewCount: reviewCount,
            activity: activity,
            fundingNeeded: funding,
            summarizedUpcomingEventID: summarizedEventID
        )
    }

    private static func isActBand(_ kind: AttentionCandidateKind) -> Bool {
        switch kind {
        case .requiredFundingGap, .authorityNeedsAttention, .currentAccountDrift:
            true
        case .unresolvedBookedEvidence, .overdueExpectedOccurrence, .monthReadyToClose:
            false
        }
    }

    private static func actionCard(
        _ candidate: AttentionCandidate,
        snapshot: FinanceAppSnapshot
    ) -> HomeAttentionCard? {
        switch candidate.detail {
        case let .fundingGap(fact):
            // The engine's two risks are two different problems, and the card
            // has to say which one this is. A deficit means money has to be
            // found; a reserve breach means the plan stays funded and eats
            // into the margin the person set. `fact.shortfall` means something
            // different in each — the gap itself, or how far under the reserve
            // the pool goes — so the sentence around it changes with the kind
            // rather than the amount being relabelled.
            let title: String
            switch fact.riskKind {
            case .poolDeficit:
                switch fact.subject {
                case let .account(_, name):
                    title = "\(name) needs \(fact.shortfall.formatted()) by \(dayText(fact.day))"
                case .paymentPool:
                    title = "\(fact.shortfall.formatted()) funding gap by \(dayText(fact.day))"
                default:
                    title = "\(fact.shortfall.formatted()) needed by \(dayText(fact.day))"
                }
            case .belowSafetyFloor:
                // Naming an account would imply that account is short. It is
                // not: the pool is funded and the reserve is what is being
                // crossed, so the subject adds nothing here. The configured
                // floor is named when it is the same currency as the gap,
                // because "below your safety reserve" without the amount
                // leaves the person to guess which floor they set.
                if let reserve = snapshot.safetyReserve,
                   reserve.currencyCode == fact.shortfall.currencyCode {
                    title = "\(fact.shortfall.formatted()) below your \(reserve.formatted()) safety reserve by \(dayText(fact.day))"
                } else {
                    title = "\(fact.shortfall.formatted()) below your safety reserve by \(dayText(fact.day))"
                }
            }
            // Funding Needed explains one payment that could not be settled.
            // Without such a payment it has nothing to show and said so, so
            // the card offers what is coming instead of a dead end. This is
            // decided by the evidence the destination needs, not by the kind:
            // a run that opens short has no settlement failure either.
            let explainable = fact.settlementFailure != nil
            return HomeAttentionCard(
                title: title,
                detail: fact.triggerLabel.map { "For \($0)" },
                actionTitle: explainable ? "See what's needed" : "See what's coming",
                destination: explainable ? .planFundingNeeded : .planUpcoming,
                isTinted: true
            )

        case .authority:
            return HomeAttentionCard(
                title: "Your bank connection needs attention",
                detail: "Open Banks & Sync to check it.",
                actionTitle: "Check bank connection",
                destination: .banksAndSync,
                isTinted: true
            )

        case let .drift(fact):
            return HomeAttentionCard(
                title: "\(fact.accountName)'s current balance needs checking",
                detail: "The bank and ledger don't currently agree.",
                actionTitle: "View account",
                destination: .account(fact.accountID),
                isTinted: true
            )

        case let .periodClose(changed, monthOffset):
            let label: String
            if case let .period(periodLabel) = candidate.subject {
                label = periodLabel
            } else {
                label = "This month"
            }
            return HomeAttentionCard(
                title: changed
                    ? "\(label) changed since verification."
                    : "\(label) isn't verified yet.",
                detail: nil,
                actionTitle: changed ? "Review changes" : "Review month",
                destination: .insightsMonthVerification(
                    ReviewPeriodSelection(scope: .month, offset: monthOffset)
                ),
                isTinted: false
            )

        case .bookedEvidence, .overdueOccurrence:
            return nil
        }
    }

    private static func uncertainty(
        for failedKeys: [AttentionDependencyKey]
    ) -> AttentionUncertainty {
        guard let key = failedKeys.first else {
            return AttentionUncertainty(
                message: "Today's financial checks couldn't all be completed.",
                destination: nil
            )
        }
        switch key {
        case .forecastProjection:
            return AttentionUncertainty(
                message: "The projection didn't finish, so today's safe-to-use figure isn't available.",
                destination: nil
            )
        case .currentAccountTruth:
            return AttentionUncertainty(
                message: "One of your current balances can't be established.",
                destination: nil
            )
        case .evidenceReviewQueue:
            return AttentionUncertainty(
                message: "Your bank records couldn't all be checked.",
                destination: .activityToReview
            )
        case .expectedOccurrenceLedger:
            return AttentionUncertainty(
                message: "Scheduled-payment review couldn't be completed.",
                destination: nil
            )
        case .providerAuthority:
            return AttentionUncertainty(
                message: "Your bank connection couldn't be checked.",
                destination: .banksAndSync
            )
        case .periodReview, .periodCheckpointBaseline:
            return AttentionUncertainty(
                message: "Today's financial checks couldn't all be completed.",
                destination: nil
            )
        }
    }

    // MARK: - Activity

    private static func activity(
        _ state: AttentionState,
        snapshot: FinanceAppSnapshot
    ) -> ActivityAttentionPresentation {
        let observations = Dictionary(
            uniqueKeysWithValues: snapshot.syncedObservations.map { ($0.id, $0) }
        )
        let expected = Dictionary(
            uniqueKeysWithValues: snapshot.expectedPayments.map { ($0.id, $0) }
        )

        var decisions: [ActivityAttentionRow] = []
        var payments: [ActivityAttentionRow] = []
        for candidate in state.actionableCandidates {
            switch (candidate.kind, candidate.subject, candidate.detail) {
            case let (.unresolvedBookedEvidence, .observation(id), .bookedEvidence(amount, day)):
                guard let observation = observations[id] else { continue }
                decisions.append(
                    ActivityAttentionRow(
                        id: id,
                        title: observation.displayMerchant,
                        subtitle: "\(observation.providerAccountName) · \(day.map(dayText) ?? "Date unavailable")",
                        amount: amount,
                        destination: .observationReview(id)
                    )
                )

            case let (.overdueExpectedOccurrence, _, .overdueOccurrence(amount, day)):
                guard let payment = expected[candidate.proposal.identity] else { continue }
                payments.append(
                    ActivityAttentionRow(
                        id: payment.id,
                        title: payment.ruleName,
                        subtitle: "Was due \(dayText(day)) · nothing matched",
                        amount: amount.negated,
                        destination: .expectedPayment(payment)
                    )
                )

            default:
                continue
            }
        }

        let pending = snapshot.currentPendingSyncedObservations.map { item in
            ActivityPendingRow(
                id: item.id,
                title: item.displayMerchant,
                subtitle: "\(item.providerName) · \(item.providerAccountName) · No action needed",
                amount: item.amount,
                day: item.dates.booking
                    ?? item.dates.transaction
                    ?? item.dates.value
                    ?? item.dates.derivedTransaction
            )
        }

        let limitations = state.suppressed.compactMap { candidate -> ActivityLimitationRow? in
            guard candidate.kind == .unresolvedBookedEvidence,
                  case .suppressedBecauseNotActionable = candidate.eligibility,
                  case let .observation(id) = candidate.subject,
                  let observation = observations[id],
                  observation.duplicateConflict?.kind == .aggregateExisting
            else { return nil }
            return ActivityLimitationRow(
                id: id,
                title: "Amounts that add up",
                detail: "One bank movement exists and two recorded items add to the same amount. "
                    + "That arithmetic is not proof they are the same money, and the current evidence model "
                    + "can't link one movement to two records. Don't create another expense merely to make it match.",
                amount: observation.amount
            )
        }

        return ActivityAttentionPresentation(
            decisions: decisions,
            paymentsToConfirm: payments,
            pending: pending,
            limitations: limitations
        )
    }

    // MARK: - Funding needed

    private static func fundingNeeded(
        _ candidate: AttentionCandidate,
        snapshot: FinanceAppSnapshot
    ) -> FundingNeededPresentation? {
        guard case let .fundingGap(fact) = candidate.detail,
              let settlement = fact.settlementFailure
        else { return nil }

        let subject: FundingSubjectPresentation
        switch fact.subject {
        case let .account(id, name):
            let kind = snapshot.accounts.first { $0.id == id }?.kind.displayName ?? "Account"
            subject = .account(name: name, kind: kind)
        case let .paymentPool(ids, _):
            let names = ids.compactMap { id in snapshot.accounts.first { $0.id == id }?.name }
            subject = .paymentAccounts(names: names)
        default:
            subject = .paymentAccounts(names: [])
        }

        let riskDay = fact.day
        let before = snapshot.upcomingEvents.filter {
            $0.date <= riskDay && $0.id != fact.triggerEventID
        }
        return FundingNeededPresentation(
            title: "Funding needed",
            trigger: fact.triggerLabel,
            day: riskDay,
            requested: settlement.requested,
            settled: settlement.settled,
            unsettled: settlement.unsettled,
            subject: subject,
            beforeThen: before,
            footer: "This is what the projection expects. It doesn't decide where the money should come from."
        )
    }

    private static func dayText(_ day: CalendarDay) -> String {
        day.formatted(.dateTime.day().month(.abbreviated))
    }
}
