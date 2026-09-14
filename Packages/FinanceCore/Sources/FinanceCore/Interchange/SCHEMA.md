# FinanceCore Interchange Schema

Versions **1.6.0** (the default wire) and **2.0.0** (explicit monetary
representation) · status: development foundation (a realistic development
fixture exists; the canonical five-year forensic export is NOT attempted).

The interchange format is the contract between three worlds:

1. the forensic reconstruction (audit layer),
2. the planning workbook,
3. the native iOS app.

## Encoding rules

- JSON, UTF-8.
- **Deterministic**: encode with sorted keys (`Interchange.encoder()`); every
  set-typed field serializes as a sorted array. Identical document values →
  identical bytes, on any machine, in any hash-seeded run.
- Days are `"YYYY-MM-DD"`; months are `"YYYY-MM"`.
- **Money and currency depend on the document's major version.**
  - **1.x** — money is an exact decimal string with currency: `"480.00 EUR"`
    (string form chosen over `{minorUnits: …}` objects for readability;
    parsing is exact, strict, and never rounds). Currencies are ISO-4217 alpha
    codes; minor-unit digits come from the small built-in table, defaulting
    to 2.
  - **2.0.0** — money and currency are objects carrying the exponent
    explicitly. See *Schema 2.0.0* below.

  A 1.x document keeps 1.x meaning forever. The built-in table as it stood when
  2.0.0 was introduced is frozen as `Currency.legacyDefaultDigits` and is what
  every 1.x document is read through; it must never gain, lose or change a
  currency, because doing so would retroactively change what documents already
  written say.
- Payment rails are snake_case ids; unknown ids decode with their id as
  summary (extensibility by design).

## Versioning

`schemaVersion` uses semver:

- **major**: removed/renamed field, changed meaning of an existing value;
- **minor**: newly added optional field;
- **patch**: documentation/fixture corrections.

`Interchange.currentSchemaVersion` is `"1.6.0"` — the version an ordinary
write still emits. `Interchange.latestSchemaVersion` is `"2.0.0"`, the newest
version this build can write.

### Changelog

- **2.0.0** — **major**: the representation of an existing value changes.
  Money and currency become explicit objects that carry the minor-unit
  exponent, so a currency whose exponent differs from the legacy table — EUR/0,
  EUR/3, an unknown code with a stated exponent — survives a round trip
  instead of being silently rescaled or refused. No field is added, removed or
  renamed. See *Schema 2.0.0*.

- **1.6.0** — additive planned purchases and sinking funds on `Planning`.
  Arrays default empty. A document that actually carries those rows must
  advertise at least `1.6.0`; an older document with empty arrays stays on
  its original version through ordinary writes.
- **1.5.0** — additive trusted rules and append-only rule audit events.
  Rule, audit, and suppression arrays default empty.
- **1.3.0** — additive external account evidence and review layer:
  - provider-neutral account bindings with a strict sync-start boundary;
  - observations with status, direction, distinct provider/derived dates,
    merchant evidence and durable-vs-provisional identity;
  - typed provider balances kept apart from ledger balances;
  - explicit observation resolutions and many-evidence → one-transaction links;
  - conservative cross-provider candidate state, always suggestion-only.
  - All arrays default empty. 1.1.0 and 1.2.0 documents retain their existing
    economics unchanged.
- **1.2.0** — additive `Planning.settlements`, resolving one dated occurrence
  without stopping its recurring rule. Omitted means no reconciliations.
- **1.1.0** — additive, fully backward-compatible (1.0.0 documents decode
  unchanged):
  - `Transaction.incomeSourceID` (links an expected pass-through arrival to
    the income source stating the owned share — the composer suppresses that
    source and represents the whole chain instead);
  - `Transaction.lifecycle` (`pending | cleared | reconciled | reversed`;
    `reversed` voids the economics — a reversed debit needs no fake income
    entry), `Transaction.bookedDate` (value date ≠ economic date),
    `Transaction.datePrecision` (`exact | estimated`);
  - `IncomeSource.dependsOn` (certainty propagation: a source is only as
    certain as the weakest thing it transitively depends on);
  - `CommitmentStatus` (`committed | hypothetical`) on `RecurringObligation`,
    `InstallmentPlan` and `Debt` — hypothetical items never enter committed
    forecasts; omitted means `committed`.
  - Ownership splits are now **validated** (1.0.0 documents that already
    satisfied the rule decode fine; malformed ones are rejected at decode —
    see `OwnershipSplit` below).
- **1.0.0** — initial contract.

## Schema 2.0.0 — explicit monetary representation

### Why

In 1.x a currency travels as its code alone and the reader rebuilds the
exponent from a built-in table. That is lossless only while every currency
agrees with the table. It does not:

    Currency EUR/0  → "EUR"       → EUR/2      (silently rescaled)
    Money 1 minor EUR/0 → "1 EUR" → 100 minor EUR/2
    Money 1 minor EUR/3 → "0.001 EUR" → decode fails

`Currency` identity has always included the exponent, and SwiftData has always
stored code and exponent separately. 2.0.0 stops the *wire* from being the one
place that throws the exponent away.

### `Currency`

```json
{ "code": "EUR", "exponent": 2 }
```

Both required. `code` is exactly three uppercase ASCII letters; `exponent` is
an integer in `0...6`. No table is consulted: an unknown but syntactically
valid code carries whatever exponent it states. Anything else is a decoding
error — never a default, never a coerced value.

### `Money`

```json
{ "minorUnits": 39600, "currency": { "code": "EUR", "exponent": 2 } }
```

Both required. `minorUnits` is a signed 64-bit integer, and it is the **only**
amount authority: there is no decimal field to disagree with it. The whole
`Int64` range round-trips exactly, `Int64.min` and `Int64.max` included.

Unrecognised sibling keys are ignored, deliberately — the format's additive
minors depend on older readers tolerating fields they have not been taught.

### Version selection

`Interchange.encode(_:as:)` takes an `InterchangeTarget`:

| target | result |
|---|---|
| `.minimumRequired` *(default)* | V2 at `2.0.0` when the source is already V2 **or** any value needs it; otherwise V1, preserving the document's own 1.x version (floored to 1.6.0 by durable planning state) |
| `.format(.v1)` | V1, or `InterchangeError.notRepresentableInV1` naming the field. Never rescales, never normalizes, never upgrades silently |
| `.format(.v2)` | always V2 at `2.0.0`, even when every value would fit V1 |

Selection is **sticky**: a document that arrived as 2.0.0 stays 2.0.0 on an
ordinary re-encode, because demoting it would quietly re-introduce the loss it
was written to avoid. Only an explicit `.format(.v1)` downgrades, and only when
every value is representable.

Format and version are resolved together, once, before any byte is written.
A V1 body never carries a 2.0.0 version and a V2 body never carries a 1.x one.

### Representability

A currency is V1-representable exactly when
`minorUnitDigits == legacyDefaultDigits(code)`; money is V1-representable when
its currency is. **Magnitude never matters** — `Int64.min` in EUR/2 is ordinary
V1 data and does not trigger an upgrade.

### Reading

The reader decodes the version envelope, validates it, and only then interprets
the body, so an unsupported future document reports an unsupported *version*
rather than a confusing money-shape error.

### Compatibility

A build that predates 2.0.0 refuses a 2.0.0 document by version, cleanly, and
writes nothing. Because selection is minimum-required, an ordinary document —
every currency agreeing with the legacy table — stays 1.x and stays readable by
those builds. Nothing recovers the exponent a 1.x document never recorded:
re-exporting a loaded 1.x document as 2.0.0 preserves the value *after* honest
1.x interpretation, and claims nothing more.

### Known JSON limitations (both versions)

Foundation's parser keeps the **first** of two duplicate keys, silently, and
accepts any JSON number that denotes an exact `Int64` (so `1.0` and `1e2` read
as 1 and 100). Neither is introduced by 2.0.0 and neither loses precision; the
writer only ever emits bare integer tokens.

## Root object: `FinanceDocument`

| field                  | type                        | notes                                        |
|------------------------|-----------------------------|----------------------------------------------|
| `schemaVersion`        | string                      | required, semver                             |
| `documentKind`         | string                      | `"DEV-FIXTURE — NOT FINANCIAL EVIDENCE"` for fixtures; an export batch id for canonical data |
| `note`                 | string?                     | provenance note (which export, as-of date)   |
| `accounts`             | `[Account]`                 |                                              |
| `balances`             | `[AccountBalance]`          | carried-forward/manual anchor per account; inclusive through `asOf`. Current holdings are derived and are not this field. |
| `transactions`         | `[Transaction]`             | observed facts                                |
| `expectedTransactions` | `[Transaction]`             | planned/expected events, not yet facts        |
| `incomeSources`        | `[IncomeSource]`            | prospective resources with certainty          |
| `installments`         | `[InstallmentPlan]`         | finite financing plans                        |
| `debts`                | `[Debt]`                    | arrears and other repayment schedules         |
| `planning`             | `Planning`                  | scenario default, floor, budgets, recurring   |
| `externalAccountBindings` | `[ExternalAccountBinding]` | opaque backend account → local account |
| `externalObservations` | `[ExternalObservation]` | account evidence, never economics |
| `providerBalanceSnapshots` | `[ProviderBalanceSnapshot]` | provider balance evidence |
| `externalEvidenceLinks` | `[ExternalEvidenceLink]` | explicit evidence → transaction links |
| `observationResolutions` | `[ExternalObservationResolution]` | explicit review state |
| `crossProviderCandidates` | `[CrossProviderCandidate]` | suggestions only |
| `trustedRules` | `[TrustedRule]` | explicit, narrowly scoped interpretation rules |
| `trustedRuleAuditEvents` | `[TrustedRuleAuditEvent]` | append-only rule lifecycle/application history |
| `trustedRuleObservationSuppressions` | `[TrustedRuleObservationSuppression]` | durable per-observation vetoes created by user reversal |

## Trusted rules (1.5.0)

All three arrays default empty when reading 1.1.0–1.4.0. A rule begins as an
unapproved, suggestion-only draft supported by explicit prior confirmations.
Activation and automatic trust are distinct user approvals recorded in the
audit array. Disabling prevents future matching and leaves reviewed history
unchanged.

Predicates keep provider, binding, merchant evidence field, direction,
currency, amount, and provider code separate. Interpretations independently
carry economic kind, category, user label, recurring obligation, and economic
source. Ownership is not rule-derived. A canonical length-prefixed semantic
fingerprint covers predicate plus interpretation; display and lifecycle fields
do not participate. Audit events snapshot that fingerprint, so approved
semantics cannot be changed in place without invalidating the document.

The first Phase 2.6 automatic boundary is only booked, durable, economically
eligible expense debits matched by structured merchant name, explicit provider
purchase semantics, and at least two prior user-confirmed supports. Credits/income, recurring settlement, ATM/cash,
transfers/top-ups, financing, FX, refunds/reversals, pass-through ownership,
raw/remittance/email-only identities, cross-provider pairing, and unresolved
economics remain suggestion-only. Every successful application passes the same
evidence-assignment eligibility function as manual review.

Application identity is deterministic per rule/observation/attempt. Repeating
evaluation, import, sync, or store reload converges on the existing transaction,
evidence link, and application audit event. Reversal keeps the transaction as a
reversed historical record and creates an explicit suppression; only a later
audited user action can clear it. Preview evaluates matches and reasons without
mutating any document array.

## External account evidence (1.3.0)

`ExternalAccountBinding` contains `id`, `provider`, an opaque backend account
id, `localAccountID`, `syncStartBoundary`, `isActive`, and `createdAt`. Raw
IBANs, Enable Banking account/session ids, identification hashes and entry
references are forbidden.

The boundary is strict: a row enters review only when its booking date (then
transaction, value, or derived date) is later than the boundary. A row
on/before the boundary, or one with no usable date, is retained as
`outsideSyncBoundary` and creates no app activity.

`ExternalObservation` preserves `bookingDate`, `transactionDate`, `valueDate`
and `derivedTransactionDate` separately. A derived date carries provenance and
never fills `transactionDate`. Only a durable, backend-eligible booked row is
reviewable. Pending and rejected rows remain evidence and cannot create an
actual.

Every observation has one explicit state: `unreviewed`,
`linkedToTransaction`, `noEconomicEffect`, `outsideSyncBoundary`,
`provisional`, or `economicallyIneligible`. Absence never means reviewed.

Evidence roles are `accountMovement`, `merchantEnrichment`, and
`supportingEvidence`. Many observations may support one transaction. In 1.3,
one observation may support only one economic transaction across all roles,
with at most one account-movement link. That link must exactly match the
binding's local account leg and signed amount.

Provider balance rows retain their balance type (including CLBD, XPCD, and
ITAV), currency, optional reference date, and observed timestamp. They never
replace the stored `AccountBalance` **anchor**. Current holdings may *display*
the canonical provider current figure (BNP `CLBD`, PayPal `XPCD`, Revolut
`ITAV`) when one is usable.

### `Account`

| field            | type              | notes                                               |
|------------------|-------------------|-----------------------------------------------------|
| `id`             | string            | stable, e.g. `"bank-main"`                           |
| `name`           | string            | display name                                        |
| `currency`       | string            | ISO code                                            |
| `kind`           | `"bank" \| "wallet" \| "cash"` |                                             |
| `supportedRails` | `[string]` (sorted) | rails this account can settle on                  |
| `isActive`       | bool              |                                                     |
| `drawOrder`      | int               | order funds are drawn for eligible payments (lower first) |

### `AccountBalance`

| field       | type     | notes                                    |
|-------------|----------|------------------------------------------|
| `accountID` | string   |                                          |
| `balance`   | money    | signed; positive = funds held            |
| `asOf`      | day      | inclusive through this day; legs on or before it are already in `balance` |
| `status`    | `"observed" \| "carried_forward" \| "assumed"` |              |

### `Transaction`

| field                  | type     | notes                                              |
|------------------------|----------|----------------------------------------------------|
| `id`                   | string   | stable                                             |
| `date`                 | day      | economic date                                      |
| `kind`                 | enum     | `expense, income, transfer, refund, financingRepayment, passThrough, cashWithdrawal, currencyConversion` |
| `legs`                 | `[AccountLeg]` | signed account movements; ≥1                       |
| `ownership`            | `[OwnershipSplit]?` | required to claim a pass-through share         |
| `linkedTransactionID`  | string?  | refund→expense, repayment→purchase, disposal→arrival |
| `incomeSourceID`       | string?  | *(1.1.0)* expected pass-through arrival → the source stating the owned share; the composer suppresses that source (the chain is its statement) |
| `installmentPlanID`    | string?  | for financing repayments                           |
| `factivity`            | `"observed" \| "expected"` | history vs planning                    |
| `lifecycle`            | `"pending" \| "cleared" \| "reconciled" \| "reversed"` | *(1.1.0)* settlement state; omitted → `cleared` (observed) / `pending` (expected). `reversed` contributes zero economics |
| `bookedDate`           | day?     | *(1.1.0)* value date when it differs from `date`   |
| `datePrecision`        | `"exact" \| "estimated"` | *(1.1.0)* how well `date` is known; omitted → `exact` |
| `certainty`            | string?  | for expected inflows (`possible…received`); observed facts always decode as `received` |
| `note`                 | string?  |                                                    |
| `provenance`           | `Provenance` | `{source, evidenceGrade, reference?}`           |

`evidenceGrade`: `primary_source > user_confirmed > derived > inferred > unresolved`.

### `AccountLeg`
`{accountID: string, amount: money}` — amount signed per account (+in/−out).

### `OwnershipSplit`
`{ownerID: string, isSelf: bool, amount: money}` — positive magnitudes.

**Validation (since 1.1.0):** when an explicit split list is present on a
pass-through, the shares must satisfy `sum(shares) == total inflow` **exactly**,
in the arrival currency. Under-allocation, over-allocation and wrong-currency
splits are malformed financial data: construction traps, decoding throws.
Negative/zero shares are structurally impossible. No split list at all remains
valid — it means the conservative default, 0% mine.

### `IncomeSource`

| field              | type      | notes                                   |
|--------------------|-----------|-----------------------------------------|
| `id`               | string    |                                         |
| `name`             | string    |                                         |
| `amount`           | money     | per occurrence; **0.00 = tracked but silent** (a real stream with no known amount — never included, never excluded, no events) |
| `certainty`        | string    | `possible, target, expected, guaranteed, received` |
| `schedule`         | `RecurrenceSpec` |                                    |
| `dependsOn`        | `[string]` | *(1.1.0)* source ids this resource cannot exist without; effective certainty = min of the whole transitive chain (cycle-safe) |
| `arrivesOnAccount` | string?   | nil → composer picks primary euro account |
| `note`             | string?   |                                         |

### `RecurrenceSpec` (tagged object)

- `{"kind": "one_shot", "day": "2026-09-16"}`
- `{"kind": "monthly", "day": 11, "from": "2026-09", "through": null}`
- `{"kind": "monthly_window", "earliestDay": 5, "latestDay": 8, "from": "2026-09", "through": null}`
  (forecast uses `earliestDay` — conservative)

`day` clamps to month length (31 → 30 in April).

### `InstallmentPlan`

| field                   | type     | notes                                    |
|-------------------------|----------|------------------------------------------|
| `id`                    | string   |                                          |
| `provider`              | string   | e.g. `"PayPal Pay-in-4"`                 |
| `purchaseDescription`   | string   |                                          |
| `note`                  | string?  |                                          |
| `purchaseDate`          | day?     |                                          |
| `originalPurchaseAmount`| money    | full economic cost booked at purchase    |
| `installments`          | `[Installment]` | sequence, dueDate, amount, status, paidOn |
| `paymentRequirement`    | `PaymentRequirement` |                             |
| `commitmentStatus`      | `"committed" \| "hypothetical"` | *(1.1.0)* omitted → `committed`; hypothetical plans never enter committed forecasts |
| `status`                | `"active" \| "completed" \| "cancelled"` |                  |

`Installment.status`/`PaymentStatus`: `scheduled, paid, cancelled, reversed`.
`remainingAmount` (computed) = sum of scheduled installments.

### `Debt`

| field                | type     | notes                                       |
|----------------------|----------|---------------------------------------------|
| `id`                 | string   |                                             |
| `name`               | string   | e.g. `"Rent arrears"`                       |
| `note`               | string?  |                                             |
| `originalAmount`     | money    | total owed before payments                  |
| `paymentSchedule`    | `[ScheduledPayment]` | day, amount, status, paidOn. **May be empty**: an acknowledged debt with no agreed schedule (e.g. rent arrears pending a repayment agreement) commits nothing and is never auto-scheduled |
| `paymentRequirement` | `PaymentRequirement` |                                  |
| `commitmentStatus`   | `"committed" \| "hypothetical"` | *(1.1.0)* omitted → `committed`; a *proposed* repayment schedule is hypothetical until agreed |
| `status`             | `"active" \| "repaid" \| "disputed"` |                        |

Paying an arrear **is** economic spending (settles real unpaid consumption) —
unlike installment repayments, which settle a purchase already booked in full.

Computed: `remainingAmount` = sum of scheduled payments;
`unscheduledBalance` = `originalAmount − remainingAmount` — the owed-but-not-
committed part, invisible to cash-flow forecasts until an agreement promotes
it onto the schedule.

### `Planning`

| field                 | type     | notes                                    |
|-----------------------|----------|------------------------------------------|
| `defaultScenario`     | string?  | `guaranteed, base, upside`               |
| `safetyFloor`         | money?   | euro spendable-pool operating floor      |
| `budgets`             | `[BudgetAllocation]` |                                     |
| `recurringObligations`| `[RecurringObligation]` |                                |
| `carriedEURValues`    | `[{accountID, value}]` (sorted) | carried value of foreign holdings at observed conversion cost |
| `plannedPurchases`    | `[PlannedPurchase]` | *(1.6.0)* durable goals; omitted → `[]`; not transactions |
| `sinkingFunds`        | `[SinkingFund]` | *(1.6.0)* durable reservations; omitted → `[]`; not spending |

### `BudgetAllocation`

| field              | type     | notes                                        |
|--------------------|----------|----------------------------------------------|
| `id`               | string   |                                              |
| `name`             | string   |                                              |
| `spendingClass`    | `"essential" \| "flexible" \| "optional"` |                             |
| `monthlyAmount`    | money    | base monthly envelope                        |
| `effectiveFrom`    | month    |                                              |
| `effectiveThrough` | month?   | nil = open-ended                             |
| `monthlyOverrides` | `[{month, amount}]` (sorted) | per-month exceptions              |

### `RecurringObligation`

| field           | type                  | notes                                 |
|-----------------|-----------------------|---------------------------------------|
| `id`            | string                |                                       |
| `name`          | string                |                                       |
| `amount`        | money                 | per occurrence                        |
| `spec`          | `RecurrenceSpec`      |                                       |
| `requirement`   | `PaymentRequirement`  |                                       |
| `spendingClass` | `"essential" \| "flexible" \| "optional"` |                          |
| `commitmentStatus` | `"committed" \| "hypothetical"` | *(1.1.0)* omitted → `committed`; a hypothetical obligation is a what-if, never a committed outflow |
| `note`          | string?               |                                       |

### `PaymentRequirement`

| field    | type     | notes                                             |
|----------|----------|---------------------------------------------------|
| `currency` | string |                                                   |
| `rails`  | `[string]` (sorted) | payment may settle via ANY one of these rails |

## Fixture

`Tests/FinanceCoreTests/Fixtures/sample-scenario.fixture.json` — the sample
scenario used by previews and tests (`documentKind` begins `DEV-FIXTURE`).
Everything in it is invented: no person, account, merchant, amount or date
refers to anything real. Its numbers (396.00 EUR electronic liquidity, a
150.00 CHF cash pocket carried at 30.00 EUR, a 480.00 EUR housing direct
debit, the Mar 16 1,000.00 EUR arrival split 400 owned / 600 not-mine with a
relocation and a handover, two financing legs of 40.00 and 60.00, arrears of
960.00 EUR with an **empty** schedule, and a reversed February housing debit)
exist to prove engine mechanics; they are **not** business rules and appear
in production code nowhere.

The fixture encodes two standing policies:

- **The Mar 16 owned share is `guaranteed`** (a committed future resource:
  not received, not current liquidity). Personal income from the chain is
  exactly 400.00 — never 1,000.00 — and it enters GUARANTEED, BASE and
  UPSIDE forecasts alike.
- **The arrears (960.00 EUR) carry NO committed repayment.** The schedule is
  empty until a real agreement exists; a proposed schedule would be
  `hypothetical`.
