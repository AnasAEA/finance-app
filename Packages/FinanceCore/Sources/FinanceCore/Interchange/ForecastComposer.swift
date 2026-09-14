/// Builds a `ForecastRequest` from an interchange `FinanceDocument`.
///
/// This is the path the UI is expected to use: document + horizon + scenario
/// in, `ForecastResult` out. The UI never touches forensic provenance.
///
/// Composition rules:
///
/// - Starting balances are effective current holdings: canonical provider
///   current cash when usable, otherwise the stored anchor plus post-anchor
///   economic legs. Stored `document.balances` stay the inclusive-through-day
///   anchor and are never mutated here.
/// - Recurring obligations expand to `scheduledDebit` events — only when
///   `commitmentStatus == .committed` (a hypothetical obligation never
///   becomes a committed outflow).
/// - Installment plans contribute their **scheduled, unpaid** installments as
///   `financingCommitment` debits (liquidity events, never new spending) —
///   again, committed plans only.
/// - Debts contribute their committed, scheduled payments. An acknowledged
///   but **unscheduled** debt (the rent arrears with no agreed repayment
///   schedule) contributes **nothing**: no repayment event is ever invented
///   (policy C2). A `hypothetical` recovery schedule is skipped the same way.
/// - Expected transactions:
///   - `.passThrough` **chains are simulated directly** (defect D3): the
///     gross arrival is a credit on the account it lands on, the non-owned
///     share is a `dependentDisposal`, and both the account truth and the
///     economic truth survive — see below.
///   - `.transfer` / `.cashWithdrawal` between owned accounts become
///     `relocation` movements (out of the source, into the destination) —
///     rail-specific liquidity changes, never consumption (defect D1).
///   - `.expense` expected purchases become EUR bank debits.
/// - Income sources are expanded by the engine under the scenario policy,
///   **except** a source whose id is claimed by a pass-through arrival's
///   `incomeSourceID` — the chain already carries the owned share, so the
///     source is suppressed and the share can never be counted twice.
///
/// ## Pass-through chain representation (defect D3)
///
/// The September chain is represented *in the document* and composed *here* —
/// the caller never hand-writes forecast events:
///
///     physical €1,000 arrival (cash pocket, ownership 800 self / 800 co-resident)
///     → deposit transfer (cash pocket → bank)
///     → co-resident's €600 remitted onward (dependent disposal)
///
/// The composer emits, in same-day order (credits → relocation → disposal):
///
/// 1. `credit +1000` to the pocket (phase `.credit`);
/// 2. `directedDebit −1000` pocket + `credit +1000` bank (phase `.relocation`);
/// 3. `directedDebit −800` bank (phase `.dependentDisposal`,
///    semantics `.disposal`).
///
/// Account truth: the bank really holds +1000 then −800; the pocket nets
/// zero. Economic truth: only the owned €400 is personal income (the linked
/// income source is suppressed — its statement *is* the chain), the disposal
/// is never a commitment, and the €1,000 gross is never personal income.
/// Scenario gating: the chain enters a run iff the policy admits the
/// arrival's `certainty` (the guaranteed parental share passes every
/// scenario — policy C1); excluded chains contribute no events at all.
public enum ForecastComposer {

    public static func makeRequest(
        from document: FinanceDocument,
        startDate: Day,
        endDate: Day,
        scenario: Scenario? = nil,
        policy: ScenarioPolicy? = nil
    ) -> ForecastRequest {
        let chosenScenario = scenario ?? document.planning.defaultScenario ?? .base
        let chosenPolicy = policy ?? chosenScenario.defaultPolicy

        var events: [ForecastEvent] = []
        var suppressedIncomeSourceIDs = Set<String>()

        // Reconciliation is read here and nowhere else in the composer: a
        // resolved occurrence is one the forecast must stop asking for.
        let ledger = ReconciliationLedger(document.planning.settlements)

        // Fixed recurring obligations — committed only.
        for obligation in document.planning.recurringObligations
        where obligation.commitmentStatus == .committed {
            for day in obligation.spec.occurrences(from: startDate, to: endDate) {
                // An occurrence that has been paid, skipped or written off is
                // no longer a future outflow. Paid is the load-bearing case:
                // the actual transaction has already moved the balance this
                // forecast starts from, so re-adding the expectation would
                // charge one real payment twice. The rule itself is untouched
                // — next month's occurrence is generated exactly as before.
                guard !ledger.isResolved(obligationID: obligation.id, day: day) else { continue }
                events.append(
                    ForecastEvent(
                        id: "\(obligation.id)-\(day.isoString)",
                        day: day,
                        phase: .scheduledDebit,
                        effect: .debit(obligation.amount, requirement: obligation.requirement),
                        outflowSemantics: .economicCommitment,
                        sourceRef: obligation.id
                    )
                )
            }
        }

        // Installment plans: scheduled, unpaid legs of committed plans only.
        for plan in document.installments
        where plan.status == .active && plan.commitmentStatus == .committed {
            for installment in plan.installments where installment.status == .scheduled {
                guard installment.dueDate >= startDate, installment.dueDate <= endDate else { continue }
                events.append(
                    ForecastEvent(
                        id: "\(plan.id)-seq\(installment.sequence)",
                        day: installment.dueDate,
                        phase: .scheduledDebit,
                        effect: .debit(installment.amount, requirement: plan.paymentRequirement),
                        outflowSemantics: .financingCommitment,
                        sourceRef: plan.id
                    )
                )
            }
        }

        // Debts: committed, scheduled payments only. An acknowledged but
        // unscheduled debt emits nothing — no repayment is ever invented.
        for debt in document.debts
        where debt.status == .active && debt.commitmentStatus == .committed {
            for payment in debt.paymentSchedule where payment.status == .scheduled {
                guard payment.day >= startDate, payment.day <= endDate else { continue }
                events.append(
                    ForecastEvent(
                        id: "\(debt.id)-\(payment.day.isoString)",
                        day: payment.day,
                        phase: .scheduledDebit,
                        effect: .debit(payment.amount, requirement: debt.paymentRequirement),
                        outflowSemantics: .economicCommitment,
                        sourceRef: debt.id
                    )
                )
            }
        }

        // Expected transactions — two passes, because a disposal transaction
        // is only composed when the arrival it is linked to was itself
        // included by the scenario (a disposal without its arrival would
        // spend money that never came).
        var includedArrivals = Set<String>()
        for transaction in document.expectedTransactions {
            guard transaction.date >= startDate, transaction.date <= endDate else { continue }
            guard transaction.lifecycle != .reversed else { continue }

            switch transaction.kind {
            case .passThrough where transaction.legs.contains(where: \.isInflow):
                composePassThroughArrival(transaction, policy: chosenPolicy, into: &events,
                                          includedArrivals: &includedArrivals,
                                          suppressedIncomeSourceIDs: &suppressedIncomeSourceIDs)

            case .expense:
                for leg in transaction.legs where leg.isOutflow {
                    events.append(
                        ForecastEvent(
                            id: "etx-\(transaction.id)",
                            day: transaction.date,
                            phase: .scheduledDebit,
                            effect: .debit(leg.amount.magnitude, requirement: PaymentRequirement.euroBankPayment()),
                            outflowSemantics: .economicCommitment,
                            sourceRef: transaction.id
                        )
                    )
                }

            case .transfer, .cashWithdrawal, .currencyConversion:
                composeRelocation(transaction, into: &events)

            default:
                continue
            }
        }

        for transaction in document.expectedTransactions {
            guard transaction.kind == .passThrough,
                  transaction.date >= startDate, transaction.date <= endDate,
                  transaction.lifecycle != .reversed,
                  !transaction.legs.contains(where: \.isInflow),
                  let linked = transaction.linkedTransactionID,
                  includedArrivals.contains(linked)
            else { continue }
            for leg in transaction.legs where leg.isOutflow {
                events.append(
                    ForecastEvent(
                        id: "etx-\(transaction.id)",
                        day: transaction.date,
                        phase: .dependentDisposal,
                        effect: .directedDebit(leg.amount.magnitude, fromAccount: leg.accountID),
                        outflowSemantics: .disposal,
                        sourceRef: transaction.id
                    )
                )
            }
        }

        return ForecastRequest(
            startDate: startDate,
            endDate: endDate,
            accounts: document.accounts,
            startingBalances: Dictionary(
                CurrentHoldings.overlayBalances(in: document, asOf: startDate).map {
                    ($0.accountID, $0.balance)
                },
                uniquingKeysWith: { a, _ in a }
            ),
            events: events,
            incomeSources: document.incomeSources.filter { !suppressedIncomeSourceIDs.contains($0.id) },
            budgets: document.planning.budgets,
            // A budget line is a gross envelope: what it has already promised to
            // the scheduled debits above must not be spread a second time. Built
            // over this request's own window and the same ledger, so the map nets
            // exactly the charges this request carries — no more, no less.
            committedByBudgetMonth: BudgetCommitmentAttribution.committedByBudgetMonth(
                in: document, from: startDate, to: endDate, asOf: startDate, ledger: ledger
            ),
            scenario: chosenScenario,
            policy: policy,
            safetyFloor: document.planning.safetyFloor,
            carriedEURValues: document.planning.carriedEURValues
        )
    }

    // MARK: - Chain composition

    /// Composes a pass-through **arrival** (inflow legs). See the type doc
    /// comment for the full story.
    ///
    /// The arrival contributes its **gross** amount as a credit; the linked
    /// disposal transaction (composed in the second pass, from the account
    /// the document says it leaves) remits the non-owned share; the owned
    /// share simply stays — which is exactly what the suppressed linked
    /// income source states, so the economics cannot double-count.
    private static func composePassThroughArrival(
        _ transaction: Transaction,
        policy: ScenarioPolicy,
        into events: inout [ForecastEvent],
        includedArrivals: inout Set<String>,
        suppressedIncomeSourceIDs: inout Set<String>
    ) {
        // Scenario gate on the arrival's certainty (default: expected).
        let certainty = transaction.certainty ?? .expected
        guard policy.includes(certainty) else { return }

        includedArrivals.insert(transaction.id)
        // The linked income source (if any) is represented by this chain.
        if let sourceID = transaction.incomeSourceID {
            suppressedIncomeSourceIDs.insert(sourceID)
        }

        for leg in transaction.legs where leg.isInflow {
            events.append(
                ForecastEvent(
                    id: "etx-\(transaction.id)",
                    day: transaction.date,
                    phase: .credit,
                    effect: .credit(leg.amount, toAccount: leg.accountID),
                    sourceRef: transaction.id,
                    certainty: certainty
                )
            )
        }
    }

    /// Composes an internal movement (transfer / withdrawal / conversion)
    /// between owned positions as `relocation` events: value leaves the
    /// source account and arrives at the destination. Never consumption,
    /// never income — but the per-account (rail) balances move, which is the
    /// honest liquidity picture (defect D1).
    ///
    /// Within the phase the out-leg applies before the in-leg (conservative:
    /// the source dips before the destination is credited), fixed by priority.
    private static func composeRelocation(_ transaction: Transaction, into events: inout [ForecastEvent]) {
        for leg in transaction.legs where leg.isOutflow {
            events.append(
                ForecastEvent(
                    id: "etx-\(transaction.id)-out",
                    day: transaction.date,
                    phase: .relocation,
                    priority: 0,
                    effect: .directedDebit(leg.amount.magnitude, fromAccount: leg.accountID),
                    outflowSemantics: .relocation,
                    sourceRef: transaction.id
                )
            )
        }
        for leg in transaction.legs where leg.isInflow {
            events.append(
                ForecastEvent(
                    id: "etx-\(transaction.id)-in",
                    day: transaction.date,
                    phase: .relocation,
                    priority: 1,
                    effect: .credit(leg.amount, toAccount: leg.accountID),
                    sourceRef: transaction.id
                )
            )
        }
    }
}
