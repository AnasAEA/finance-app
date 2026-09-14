# FinanceCore — Domain Reference

This document is the semantic contract of the `FinanceCore` package: what each
concept *means*, not merely what the types are named. It distills the
forensic-audit layer of this repository into reusable rules, without porting
every workbook formula and without mutating any historical artifact.

Two layers run through everything:

1. **The observed layer** — facts: bank movements that already happened.
2. **The planning layer** — prospective: what may happen, graded by certainty.

The cardinal rule: **an account movement is not an economic event.** Money
moving between positions you control is not spending; money arriving that
belongs to somebody else is not income; repaying financing is not a new
purchase. Only the economic interpretation feeds headline numbers, and it is
always derived, never assumed.

## External evidence is not economics

`ExternalObservation` records what a provider reported about one bound
account. A debit is not inherently an expense and a credit is not inherently
income. Booked observations enter an explicit review queue only after their
binding's opening-balance boundary; pending, rejected, pre-boundary, and
undated rows remain evidence without becoming actuals.

The only bridge to `Transaction` is an `ExternalEvidenceLink` created by an
explicit resolution. Many provider observations may support one transaction
(for example a bank account movement plus PayPal merchant enrichment), while
one observation cannot support two transactions. Typed provider balances are
reconciliation evidence and never rewrite ledger balances.

A provider may withdraw a row it once reported as booked, and the two cases are
not symmetrical. An observation nobody has acted on leaves the review queue by
itself: keeping it in New would offer actions guaranteed to fail. An observation
someone already resolved keeps its resolution — they saw real money move and
recorded what it meant, and a later status change is new evidence about the
bank's bookkeeping, not grounds to retract their decision or delete their
transaction. That divergence surfaces as a warning
(`ExternalEvidenceReview.providerStatusWarnings`) for a human to judge.

---

## 1. Money

- `Money` is an `Int64` of minor units plus a `Currency`. **No `Double` ever
  decides an authoritative value** — parsing is exact-string
  (`Money(exactDecimal: "480.00", currency: .eur)`), printing is
  `"480.00 EUR"`, and division always carries an explicit `RoundingRule`
  (`down` = toward zero, `up` = away from zero, `halfUp`, `halfEven`).
- Splitting an amount (`allocated(ratios:)`) uses largest-remainder so the
  parts sum back to the original exactly, deterministically (earliest index
  takes any leftover cent).
- `Currency` identity includes `minorUnitDigits` (JPY ≠ a 2-digit "JPY").
- `MoneyBag` holds several `Money` amounts, each in its own currency, with
  **no implicit conversion anywhere**: there is no `total`, no `sum`, no way
  to ask "what is this worth" without an explicit conversion policy.
  `amount(in:)` returns zero for unheld currencies; `currencies` iterates
  sorted (deterministic); merging is per-currency and exact. This is the
  honest representation of tracked holdings: 54.00 EUR *and* 150.00 CHF coexist
  and neither can pay the other's obligations.
- **No implicit FX anywhere.** Conversion requires an explicit
  `ExchangeRate`, and rates are *observed* (built from two observed amounts)
  or hand-supplied exact rationals — never fetched, never estimated.

## 2. Time

`Day` is a pure Gregorian date (Howard Hinnant's civil-days algorithms), with
zero Foundation `Date`/`Calendar`/timezone involvement. Days are totally
ordered by an integer index; months are `MonthKey`. Recurrences:

- `oneShot(on:)` — a single dated event;
- `monthly(onDay:)` — day-of-month, **clamped** into shorter months
  (day 31 → April 30, day 29 → Feb 28/29);
- `monthlyWindow(earliestDay:latestDay:)` — a "somewhere between the 5th and
  the 8th" obligation forecasts on the **earliest** day: conservative.

## 3. Accounts, capabilities and payment rails

An `Account` is a *position*: bank account, wallet, or physical cash pocket.

- `kind` (bank / wallet / cash) is descriptive. **Capability is
  `supportedRails`**, and the two are independent.
- A `PaymentRequirement` is a currency plus a set of acceptable rails
  (any one suffices). An account **satisfies** a requirement iff it is
  active, its currency matches, AND it supports at least one acceptable rail:

  | situation                        | currency | rail     | satisfies |
  |----------------------------------|----------|----------|-----------|
  | BNP paying a SEPA rent debit     | ✓ EUR    | ✓ sepa   | yes       |
  | 200 MAD cash, EUR SEPA debit     | ✗ MAD    | ✗ cash   | **no**    |
  | €500 pocket cash, card debit     | ✓ EUR    | ✗ cash   | **no**    |
  | bank account, in-person cash-only| ✓ EUR    | ✗ no cash rail | **no** |

  The failure axes are independent and both are tested. Rails are an open
  id-value type — unknown rails decode fine; the model is extensible.
- `drawOrder` fixes the deterministic funding order when several accounts can
  pay (lowest first, ties by id).

## 4. Transactions — economic semantics

A `Transaction` is one economic event with one or more `AccountLeg`
movements. `TransactionKind` drives all interpretation:

| kind                 | spending? | income? | notes                                                  |
|---------------------|-----------|---------|--------------------------------------------------------|
| `expense`           | yes       | —       | booked once, at purchase                               |
| `income`            | —         | yes     |                                                        |
| `transfer`          | no        | no      | form/place change between owned accounts               |
| `refund`            | no        | **no**  | offsets the original expense (`netEconomicSpending`)  |
| `financingRepayment`| **no**    | no      | liquidity event; the purchase was already booked       |
| `passThrough`       | no        | share   | see ownership below                                    |
| `cashWithdrawal`    | no        | no      | ATM: form (and possibly currency) change; **no fee is ever invented** |
| `currencyConversion`| no        | no      | exchange at an observed rate                           |

`Economics.effect(of:currency:)` produces the **per-transaction** read-out
(`EconomicEffect`: `spending`, `income`, `refund`, `financingRepayment`,
`passThroughNotMine`, the raw `accountMovementIn/Out` facts, a display
`role`, `netPersonalFlow`, `isRelocation`, `isConsumption`) — one semantic
source of truth per row, so the UI never reproduces the kind switch.
`Economics.totals(for:currency:)` folds those same effects into the headline
fields (`economicSpending`, `personalIncome`, `netEconomicSpending`,
`refunds`, `financingRepayments`, `internalTransfers`, `passThroughNotMine`,
`personalNetFlow`, gross movements) — the per-row and aggregate views can
never disagree.

### Lifecycle

Every transaction carries a `TransactionLifecycle` — `pending` (a card hold),
`cleared` (settled; the default for observed facts), `reconciled`
(statement-confirmed), `reversed` (pulled back or voided). Orthogonal to
`Factivity`: an observed rent debit can be `reversed` (a landlord pulling back a monthly direct debit). **`reversed` voids the economics** — the reversal is
modelled directly on the transaction, never via a synthetic income entry; the
still-owed obligation, if any, belongs to the planning layer (`Debt`).
`bookedDate` carries a differing value date, `datePrecision` carries how well
`date` is known (exact vs estimated — carried, never flattened).

### Worked examples (all are tests)

- **Cash withdrawal abroad**: −30.00 EUR account, +150.00 CHF in hand.
  Spending **0**, income **0**, gross outflow 30.00 (movement ≠ spending),
  two legs exactly, and no
  invented fee.
- **Shared-pot pass-through**: a +1000 arrival documented as 400 owned + 600
  someone else's. Personal income **400**, not 1000; forwarding the 600 is
  not spending; the account still physically held 1000 for a while.
- **Phone on Pay-in-4**: 324.89 expense booked at purchase; the four × 81.22
  repayments are `financingRepayments` — total economic spending is 324.89,
  never 649.77.
- **Refund**: 21.99 back for a 21.99 purchase → income 0, net spending 0.

### Ownership

`passThrough` carries an optional `OwnershipSplit` list. Without documented
splits the conservative default is **0% mine** — a split is never invented.
When splits **are** documented they must satisfy `sum(shares) == total
inflow` **exactly** (exact integer arithmetic, in the arrival currency):
under-allocation (money with no owner), over-allocation (ownership invented
out of thin air) and wrong-currency splits are malformed financial data —
construction traps, decoding throws. Observed layer entries carry
`Provenance` with a graded `EvidenceGrade` (primary source > user confirmed
> derived > inferred > unresolved).

## 5. Planning — the certainty ladder

Prospective income is graded `IncomeCertainty`:

`possible < target < expected < guaranteed < received`

- `possible` — contingent, not even applied for;
- `target` — intended, not obtained (an unsigned contract);
- `expected` — realistically planned and dated, not contractually secured;
- `guaranteed` — contractually or structurally secured;
- `received` — an observed fact.

A `Scenario` (`guaranteed` / `base` / `upside`) maps to a `ScenarioPolicy`
(minimum certainty + an explicit `includesPossible` flag). The rules that can
never be violated (all tested):

- `received` enters **every** scenario — history is not scenario-dependent;
- `target` enters only `upside` — an intended job is not plan income;
- `possible` enters **no** scenario by default, only an explicit opt-in
  policy — a possible hardship grant is not cash;
- scenarios filter **prospective resources only**; historical facts are never
  rewritten by a scenario.

Two refinements on the ladder:

- **`dependsOn` propagation** — a source may declare the sources it cannot
  exist without (a top-up depends on the contract). Its *effective* certainty
  is the minimum of the whole transitive chain (cycle-safe, unknown ids
  ignored). An "expected" grant resting on a "target" job is effectively
  `target` — and `base` excludes it accordingly. The stored certainty is
  never rewritten.
- **Zero-amount streams** — a source with amount 0.00 is *tracked but
  silent*: a real stream with no known amount yet (the royalties
  reimbursement, a chèque énergie). It never appears as included *or*
  excluded income and emits no events.

Every planning item also carries a `CommitmentStatus` — `committed` (default)
or `hypothetical`. Hypothetical obligations, installment plans and debt
schedules are what-if reconstructions: they **never** enter a committed
forecast. This is also how an *acknowledged but unscheduled* debt differs
from a *proposed* repayment schedule (below).

`RecurringObligation`s and `BudgetAllocation`s (classes: `essential`,
`flexible`, `optional`, with per-month overrides) describe outflows.

## 6. Debts and installments — two different animals

- `InstallmentPlan` (Pay-in-4, 4X CB): the **purchase was already spending**
  when it happened. Remaining `scheduled` installments are future liquidity
  events, nothing more.
- `Debt` / arrears (e.g. unpaid rent): the consumption happened and was
  **never paid for** — repaying an arrear **is** economic spending, unlike a
  financing repayment. The scheduled payment stream drives liquidity either
  way; the economic classification is a property of the debt, carried in the
  event's `sourceRef` for callers that care.

**An acknowledged debt is not a repayment schedule.** A `Debt` may exist
with an **empty** `paymentSchedule` — the arrears are real, documented
(`unscheduledBalance` = the full amount), and commit *nothing*: no repayment
event is ever invented (no "2×€436.43" from thin air). A *proposed* schedule
— the scenario the creditor might accept — is encoded as
`commitmentStatus: .hypothetical` and stays out of committed forecasts until
a real agreement promotes it. When the schedule exists and is committed,
`remainingAmount` is the sum of scheduled payments and `unscheduledBalance`
is the remainder.

## 7. The forecast engine

`ForecastEngine.run(ForecastRequest) -> ForecastResult` is a **pure,
day-level** simulation. Determinism rules:

- Every event is totally ordered by `(day, phase, priority, id)`.
- Same-day phase order: **scheduled debits → variable spending → credits →
  relocations → dependent disposals** — debits before credits, so a same-day
  arrival never cosmetically rescues a same-day debit; a relocation (deposit
  the cash that arrived) happens only after the arrival; a dependent
  disposal (remitting someone's pass-through share) only after that. This is
  the conservative **default**, not a secret: the phase is a caller-set
  field, and a *known-first* credit (a morning deposit, an agreed same-day
  sequence) is representable by placing it in an earlier phase with an
  explicit priority. There is deliberately **no timestamp simulation** —
  day + phase + priority is the whole clock.
- Collection order never leaks into results: shuffles of the same inputs
  produce identical results (tested).
- Balances are integers; the engine records per-account end-of-day balances,
  the **spendable euro pool** (accounts satisfying the pool requirement —
  euro bank/wallet rails), `otherTrackedEUR` (euro money outside those rails
  + foreign holdings at **carried observed cost**, never a market rate), and
  their sum, tracked liquidity.

Every outflow event carries `OutflowSemantics` — `economicCommitment`,
`financingCommitment`, `relocation` or `disposal` — and only the first two
are `isCommittedOutflow`. An OWNED→OWNED movement (transfer, cash withdrawal,
deposit) never reduces economic spend or safe-to-spend, while rail-specific
liquidity still moves honestly (bank → pocket lowers bank-rail spendability;
the pool is untouched). A disposal moves somebody *else's* money out — never
a commitment of the user's.

Debits draw only from accounts satisfying their requirement, in
`(drawOrder, id)` order. A debit that cannot settle in full is still applied
(the first eligible account goes negative — overdraft/bounce modelling) and
recorded as a `SettlementFailure` — **never** funded by cross-currency or
wrong-rail money: 200 MAD cannot stop a euro SEPA balance going negative
(tested at the engine level).

### Settlement failure ≠ pool deficit

These are two different facts and both are first-class:

- **`SettlementFailure`** — *this payment* could not settle from eligible
  accounts (right currency + rail + active) when it came due:
  `requested`, `settled` (what eligible *positive* balances covered),
  `unsettled`, `eligibleAccountIDs`, `requirement`. A €6.13 card debit paid
  in full from Revolut while the aggregate pool was negative is **settled**
  — never labelled bounced. The mirror holds: a SEPA debit can fail while
  the pool stays positive, because the covering money rides the wrong rail.
- **Pool-deficit facts** — `firstNegativeDate`, `lowestBalance` /
  `lowestBalanceDate` (true **intraday** minimum — measured after every
  event application), `minimumBridgeRequired`, and their safety-floor twins
  (`firstBelowSafetyFloorDate`, `minimumBridgeForSafetyFloor`). The starting
  pool itself counts: a negative or floor-breaching opening balance is
  already a risk on day one.

### Product-shaped outputs

`ForecastResult` also carries the read-outs a UI needs without forensic
knowledge: `cashRunwayDays` (days the pool stays non-negative),
`projectedMonthEnd` (pool at each month close), `firstRisk` (earliest
pool-deficit or floor breach, with the triggering event's id and label) and
`unfundedByMonth` (unsettled volume per month, **per currency**: a
`[MonthKey: MoneyBag]` — a month with an EUR *and* an MAD failure holds both
deficits separately, never summed, never converted; read one currency with
`unfunded(in:month:)`, or `unfundedEURByMonth` for the EUR-led view, which
excludes — never converts — foreign shortfalls).

`VariableSpendingPlanner` spreads a month's budget envelope evenly across
the month with exact largest-remainder cents (v1 simplification, documented;
the workbook's resource smoothing is deliberately not ported).

### Chains in the composer

`ForecastComposer` simulates a pass-through **chain directly** from the
document's expected transactions. The sample fixture's Mar 16 shape — a
1,000.00 physical arrival split 400 owned / 600 not-mine, the owned share
deposited to the bank and the rest handed on — becomes, in one day: credit
+1000 to the pocket; relocation −400 pocket / +400 bank; dependent disposal
−600 pocket. Account truth (the pocket really saw +1000 then −1000) and
economic truth (income exactly 400; the
linked income source is suppressed so nothing double-counts; the disposal is
never a commitment) both survive. The arrival enters a run iff the scenario
policy admits its certainty — a **guaranteed** share passes every scenario.

## 8. Intended simplifications (not bugs)

- Budgets forecast as even daily spending, not the workbook's smoothing.
- Window recurrences forecast on the earliest plausible day.
- Same-day credits land after same-day debits *by default* (conservative);
  a known-first credit is representable with an explicit phase + priority.
- No fee is ever invented; if a statement shows none, none exists.
- Carried value of foreign cash is its observed conversion cost, never a
  market estimate; foreign cash never counts as spendable euros.
- A pass-through arrival whose scenario-excluded chain is dropped contributes
  no events at all (a disposal without its arrival would spend money that
  never came).
- Sources with no occurrence inside the horizon are neither included nor
  excluded; they simply do not occur.

## 9. The interchange document

`FinanceDocument` (JSON, schema-versioned semver, currently `1.1.0`) is the
single artifact exchanged with the app: accounts, balances, observed
transactions, expected transactions, income sources, installment plans,
debts, and planning (scenario, floor, budgets, obligations, carried values).
Encoding is byte-deterministic (sorted keys; sets as sorted arrays).
`Tests/FinanceCoreTests/Fixtures/sample-scenario.fixture.json` is
**development fixture data** — marked as such in `documentKind` — built from
an invented scenario (396.00 EUR electronic liquidity, a 150.00 CHF cash
pocket, a 480.00 EUR housing direct debit, the Mar 16 guaranteed 400/600
shared-pot chain with relocation and handover, small obligations and
financing legs, a reversed February housing debit, 960.00 EUR arrears with an
empty schedule). It proves mechanics; it is not financial evidence, and no
value in it refers to anything real.

Full field-by-field contract: `Sources/FinanceCore/Interchange/SCHEMA.md`.

## 10. Affordability and goals (Phase 2.7)

`AffordabilityEngine.evaluate` is a **pure** what-if. Same request → same
verdict. It never mutates balances, transactions, planned purchases, sinking
funds, or budgets. It does not change Home `safeToSpend`, and it does not
call reservation-adjusted cash by that name.

A `PlannedPurchase` is planning state, not a `Transaction`. A status label
never creates an obligation and never enters `ForecastComposer`. Wishlist
rows have no cash, budget, or forecast effect. Earmarked rows affect
available cash only through an explicit reservation. A purchased goal still
invents no economics — the actual transaction is authoritative.

A `SinkingFund` is reservation state, not spending. Virtual custody overlays
the general spendable pool. Dedicated custody overlays only that account;
dedicated reserved money is not generally spendable just because the account
sits inside pooled liquidity. Applying a reservation never also subtracts the
same euros from the rest of the pool.

A sinking-funded **purchase** consumes/releases `min(purchase, reserved)` on
the purchase day *before* the cash debit, so reserved cash plus the purchase
are not both withheld. The actual fund object is not mutated. The purchase
still counts once against the monthly economic-spending ceiling.

The verdict is multi-axis, not a Boolean: cash (ledger / reserved /
unreserved), budget (strict ceiling), timing (hard deficit vs floor),
funding (operating scenario vs more-inclusive certainty), settlement
(rail/account vs pooled cash). Uncertain income uses the existing
`IncomeCertainty` ladder and `ScenarioPolicy`. A possible grant never silently
makes a purchase `affordable`; if only a more-inclusive policy would succeed,
the overall is `affordableConditionally` and names the certainty class.

No silent FX. A candidate that cannot settle on its currency and rail is
ineligible. Pooled cash does not invent a transfer to rescue an unfunded
account.

Durable planned purchases and sinking funds live on `FinanceDocument.Planning`
from schema **1.6.0**. Affordability candidates, overlays and verdicts remain
ephemeral request/result types and are not stored. An older document with
empty arrays stays on its original schema version; the first persisted
non-empty planning row requires at least 1.6.0.

## 11. Period review (Phase 2.8)

`ReviewEngine.review(ReviewRequest) -> ReviewResult` is a **pure** period
close. Same document + interval + as-of day → same result. It never reads
`Date()`, never writes `FinanceDocument`, and never calls an external model.
`ReviewRequest` / `ReviewResult` are ephemeral; they are not schema fields
and generated reviews are not stored.

The engine answers “how did this week/month go, what changed, why, and what
to look at next” as structured facts and findings. A later presentation
layer may turn those findings into copy. The engine itself does not coach.

### Periods

Callers pass an explicit inclusive `ReviewInterval`. Helpers:

- `ReviewInterval.weekStarting(_:)` — seven days; the caller chooses the
  week origin.
- `ReviewInterval.month(_:)` — first through last civil day of the month.

Previous-period comparison uses the prior calendar month for a full-month
monthly review, otherwise the immediately preceding interval of the same
length.

### Spending

Inclusion is `Economics` plus the monthly budget engine’s refund-of-reversed
correction. Transfers, cash withdrawals, top-ups, currency conversions,
financing repayments, pass-through disposals, reversed rows, and
rejected/provisional provider observations (which never became transactions)
are not spending. A sinking-fund reservation or contribution is not spending.
A goal purchase counts only when an observed economic `Transaction` exists.

Ordinary vs exceptional is not inferred from amount:

- a settlement against a recurring obligation → ordinary recurring
- attribution to a budget line → ordinary variable
- exceptional only from an explicit `spendingNatures` map
- otherwise unresolved

### Budget contexts

`ReviewBudget.periodEconomicSpending` is the interval total. Monthly ceiling
math is never applied to a week as if the week were a month.

Each calendar month the interval touches gets a `ReviewMonthlyBudgetContext`:

- a full-month review → one context
- a week inside one month → one context
- a week 2026-08-29…2026-09-04 → two contexts; 29–31 Aug against August,
  1–4 Sep against September

`periodSpendingInMonth` is only the review days in that month.
`monthSpending` / `remaining` / `overage` are the **month** against that
month’s ceiling and in-effect budget lines. There is no prorated weekly
ceiling.

### Income

Classification is evidence-driven. Personal income is still
`Economics.personalIncome`. Pass-through volume that is not owned is never
the user’s income and never `earnedOrOther`.

Precedence:

1. `Transaction.kind` of transfer / cash withdrawal / conversion → internal
2. `ReviewRequest.incomeClasses[transaction.id]`
3. `incomeClasses[incomeSourceID]`
4. `economicSources[incomeSourceID]` or `[transaction.id]`, mapped through
   `ReviewEconomicSourceClass` from the canonical history tokens
   (`PARENTAL_SUPPORT_SELF`, `EARNED_EMPLOYMENT`,
   `SHARED_EXPENSE_REIMBURSEMENT`, …)
5. history `economicSource` on archive rows, same table
6. `kind == passThrough` → `passThrough`, with gross vs owned from
   `OwnershipSplit`
7. `kind == income` with no source evidence → `unresolved`

A live `income` row is never earned merely because it is personal income.
Reimbursement requires an explicit class or a canonical reimbursement token.

### Coverage

`ReviewCoverageInput` is the completeness contract. Completeness is
fail-closed: omitting history, cutoff, gaps, or live coverage is **not**
`complete`. Status is `complete` / `partial` / `insufficient`.

- Archive-era days (on or before `archiveCutoff`) require a history document
  whose `dateRange` covers them and that has no intersecting `sourceGaps`.
- Live-era days require `liveCoveredIntervals` that actually cover them.
- No metadata at all → `insufficient` (`coverageMetadataAbsent`).
- Missing source periods are never zero activity.
- Dates on or before cutoff are owned by history; later dates by the live
  ledger. The same economic event is never counted on both sides.

### Comparison

Previous-period deltas exist only when **both** intervals are `complete`.
A percentage is not invented when the prior value is zero (`basisPoints`
is nil). Raw deltas are always available on a successful comparison;
named “material” findings are gated separately.

### Risk

Outlook is generated from `request.asOf` via `ForecastComposer` +
`ForecastEngine`. `asOfLedgerLiquidity` is spendable-pool liquidity at
`asOf`. It is not a reconstructed period-end balance: a June review read
in August reports June as `interval` and August as the outlook. Hard cash
risk (`firstNegativeDate`) and floor warning (`firstBelowSafetyFloorDate`)
stay separate. Home `safeToSpend` is not this overlay.

### Findings

Findings are a closed vocabulary with severity, amounts, dates and ids,
ordered by severity then kind then id. No prose is generated.

`ReviewFindingPolicy.standard` (euro cents) gates significance:

| finding | rule |
|---|---|
| material spending Δ | \|Δ\| ≥ €25 **and** (prior = 0 **or** \|Δ\| ≥ 20% of prior) |
| unusually high category | prior ≥ €20, current ≥ 2× prior, \|Δ\| ≥ €25 |
| major exceptional purchase | exceptional **and** amount ≥ €100 |

€400 → €401 is not material. €1 → €2 is not an unusually high category.
Not every exceptional purchase is major. Thresholds live on the request
and can be replaced; they are not buried in conditionals.
