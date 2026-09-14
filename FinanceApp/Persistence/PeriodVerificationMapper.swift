import FinanceCore
import Foundation

/// An ended month's verification as the product holds it: what the screen
/// renders, and the evaluated readiness it was rendered from.
///
/// The readiness travels *beside* the presentation rather than inside it for
/// two reasons. `Insights.swift` is deliberately free of `FinanceCore` types,
/// and — the load-bearing one — an acknowledgment decision has to be stated as
/// the exact current `PeriodCheckpointException` value. A title, a detail
/// sentence or a row identifier cannot reconstruct one: an identifier that
/// survives while its subject changes underneath is precisely the substitution
/// the confirmation boundary refuses.
///
/// Nothing here is stored. It is the answer to one question asked once.
struct EndedMonthVerification {

    /// The evaluator's answer, including the exact exceptions this period
    /// carries and how the confirmed decisions partitioned them.
    let readiness: PeriodCheckpointReadiness

    /// Display only.
    let presentation: PeriodVerificationPresentation
}

/// Read-only verification presentation for an ended period.
///
/// Reads safe claims, blockers and exceptions, and — since the checkpoint
/// writer landed — `PeriodCheckpointReadiness.baselineComparison`, so the
/// screens can state what the stored checkpoint history says. That is the one
/// claim this widening admits, and it is read-only: the mapper still never
/// consults `projection` or `disposition`, never stores anything, never
/// constructs a `PeriodCheckpointRevision`, never classifies close policy and
/// never reaches the acknowledgment matcher.
enum PeriodVerificationMapper {

    /// The product's reading of one baseline comparison.
    ///
    /// `verified` requires proof that current state equals what was accepted,
    /// so only `.unchangedSinceClose` earns it. `.indeterminate` and
    /// `.requiresReverification` are established facts about the baseline but
    /// settle neither changed nor unchanged, and an `.unavailable` baseline
    /// establishes nothing at all; all three fail closed to `.unavailable`
    /// rather than borrowing the nearest confident answer.
    static func verificationState(
        for comparison: PeriodCheckpointBaselineComparison
    ) -> CheckpointVerificationState {
        switch comparison {
        case .notPreviouslyClosed: .notVerified
        case .unchangedSinceClose: .verified
        case .changedSinceClose: .changedSinceVerification
        case .unavailable, .indeterminate, .requiresReverification: .unavailable
        }
    }

    static func present(
        _ readiness: PeriodCheckpointReadiness,
        periodLabel: String,
        observations: [SyncedObservationItem],
        expectedPayments: [ExpectedPayment]
    ) -> PeriodVerificationPresentation {
        let observationsByID = Dictionary(
            uniqueKeysWithValues: observations.map { ($0.id, $0) }
        )
        let paymentsByID = Dictionary(
            uniqueKeysWithValues: expectedPayments.map { ($0.id, $0) }
        )

        var decisions: [PeriodVerificationIssue] = []
        var limitations: [PeriodVerificationIssue] = []
        for exception in readiness.exceptions {
            switch exception.kind {
            case .unknownBookedEconomics:
                guard let item = observationsByID[exception.id] else {
                    limitations.append(unrouted(exception, title: "Bank movement needs context"))
                    continue
                }
                let amount = exception.amount.map(DomainMapper.amount)
                let day = exception.day.map { DomainMapper.civilDay($0) }
                let detail: String
                if let amount, let day {
                    detail = "\(amount.magnitude.formatted()) left \(item.providerAccountName) on "
                        + "\(dayText(day)), but its meaning hasn't been decided. Until it is reviewed, "
                        + "the month's total may be incomplete."
                } else {
                    detail = "A bank movement's meaning hasn't been decided. Until it is reviewed, "
                        + "the month's total may be incomplete."
                }
                decisions.append(
                    PeriodVerificationIssue(
                        id: "decision:\(exception.id)",
                        title: item.displayMerchant,
                        detail: detail,
                        amount: amount,
                        destination: .observationReview(item.id)
                    )
                )

            case .overdueExpectedOccurrence:
                guard let payment = paymentsByID[exception.id] else {
                    limitations.append(unrouted(exception, title: "Scheduled payment is unresolved"))
                    continue
                }
                decisions.append(
                    PeriodVerificationIssue(
                        id: "decision:\(exception.id)",
                        title: payment.ruleName,
                        detail: "Was due \(dayText(payment.expectedDate)) · nothing matched.",
                        amount: exception.amount.map { DomainMapper.amount($0).negated },
                        destination: .expectedPayment(payment)
                    )
                )

            case .uncategorizedEconomicSpending:
                let amount = exception.amount.map(DomainMapper.amount)
                limitations.append(
                    PeriodVerificationIssue(
                        id: "limitation:\(exception.id)",
                        title: "Some spending isn't assigned",
                        detail: amount.map {
                            "\($0.magnitude.formatted()) of spending is counted in the total, but isn't assigned to a budget line."
                        } ?? "Some spending is counted in the total, but isn't assigned to a budget line.",
                        amount: amount,
                        destination: nil
                    )
                )

            case .aggregateEvidenceModelLimitation:
                limitations.append(
                    PeriodVerificationIssue(
                        id: "limitation:\(exception.id)",
                        title: "One movement, two existing records",
                        detail: "One bank movement exists and two existing economic records add to the same amount. "
                            + "Arithmetic is not proof that they are the same money. The current evidence model "
                            + "can't link one bank movement to two economic records, so no new expense should be "
                            + "created merely to make it match.",
                        amount: exception.amount.map(DomainMapper.amount),
                        destination: nil
                    )
                )

            case .providerStatusConflict:
                limitations.append(
                    unrouted(
                        exception,
                        title: "The bank's current status conflicts with an earlier decision"
                    )
                )

            case .unresolvedEvidenceLinkage, .unresolvedEconomicClassification,
                 .unresolvedIncomeClassificationOrOwnership,
                 .acceptedReconciliationAmountDifference:
                limitations.append(unrouted(exception, title: "A recorded limitation remains"))
            }
        }

        limitations += readiness.blockers.enumerated().map { index, _ in
            PeriodVerificationIssue(
                id: "coverage:\(index)",
                title: "Records are incomplete",
                detail: "Not every day needed for this period can be confirmed, so totals aren't shown as complete.",
                amount: nil,
                destination: nil
            )
        }

        let claims = readiness.safeClaims
        let totals: String
        if !claims.mayShowCalculatedTotals {
            totals = "Totals aren't available because the period's records aren't complete."
        } else if !claims.unquestionablyCompleteTotals {
            totals = "Totals are calculated from what's recorded — they may not be the whole picture."
        } else {
            totals = "Totals reflect the recorded economics for this period."
        }
        return PeriodVerificationPresentation(
            periodLabel: periodLabel,
            verificationState: verificationState(for: readiness.baselineComparison),
            decisionCount: decisions.count,
            limitationCount: limitations.count,
            totalsStatement: totals,
            categoryStatement: claims.completeCategoryAttribution
                ? nil
                : "Some spending is counted but isn't assigned to a budget line.",
            auditStatement: claims.completeEvidenceAudit
                ? nil
                : "Not every relevant bank record has a confirmed relationship.",
            decisions: decisions,
            limitations: limitations
        )
    }

    private static func unrouted(
        _ exception: PeriodCheckpointException,
        title: String
    ) -> PeriodVerificationIssue {
        PeriodVerificationIssue(
            id: "limitation:\(exception.id)",
            title: title,
            detail: "There is no proven action in this version that can clear this limitation.",
            amount: exception.amount.map(DomainMapper.amount),
            destination: nil
        )
    }

    private static func dayText(_ day: CalendarDay) -> String {
        day.formatted(.dateTime.day().month(.abbreviated))
    }
}
