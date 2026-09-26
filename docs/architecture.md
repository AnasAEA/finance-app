# FinanceApp architecture

## Dependency boundary

```text
SwiftUI views
    │ read FinanceAppSnapshot / write TransactionDraft
    ▼
FinanceProviding
    ▼
FinanceStore
    │ owns FinanceDocument and invokes one ForecastEngine
    ▼
DomainMapper
    ├── hardened FinanceOverview → FinanceAppSnapshot
    └── TransactionDraft → FinanceCore.Transaction
    ▼
normalized SwiftData rows ⇄ FinanceDocument ⇄ FinanceCore
```

Views never import FinanceCore or SwiftData and cannot construct domain
transactions. The surface types intentionally contain only product-shaped
Foundation values. The persistence boundary is limited to
`DomainMapper.swift`, `PersistedModels.swift`, and `FinanceStore.swift`.

## Source and package isolation

`Packages/FinanceCore` is a local Swift package and the authoritative copy of
the accounting semantics: it is edited here, and the Xcode project references
it by relative path only. The package has no dependency on the application,
no networking, and no UI framework, so it can be built and tested on its own
with `Scripts/test-core`.

The package owns all accounting semantics: Money/MoneyBag, Day/MonthKey,
accounts and payment requirements, rails, transactions and legs, ownership,
economic effects, lifecycle, certainty/scenario policy, commitments, debts and
installments, forecast composition/settlement, FinanceOverview, and
FinanceDocument interchange. The app does not fork any of those concepts.

## Store and forecast flow

On load, the normalized SwiftData graph is rebuilt as a FinanceDocument.
`ForecastComposer` turns that document into the sole engine request;
`ForecastEngine` performs rail-aware day/intraday settlement; `FinanceOverview`
produces product-oriented liquidity values. DomainMapper fills every facade
section used by the UI: balances/holdings, safe-to-spend and raw shortfall,
risk/bridge/runway, upcoming/month projections, budgets, account-aware
activity, account and income-source management, commitments, installments,
income, debts, and entry options.

Phase 2.6 trusted rules live beside external observations in FinanceDocument,
never inside them. A predicate reads exact provider evidence; its interpretation
keeps economic kind, category, user label, recurring obligation, and economic
source as separate fields, and has no ownership field. FinanceCore owns trust
gating, canonical semantic identity, append-only lifecycle/application audit,
and explicit per-observation reversal suppression. The automatic operation
reuses the manual evidence-assignment preflight and is idempotent across repeated
evaluation and reload. DomainMapper exposes inspectable supporting confirmations,
pure current-Inbox preview counts, safety reasons, and Smart Inbox priority.
Bank import persists provider evidence independently of economic interpretation.
After a successful import, eligible evidence can be handled by explicitly approved
rules only when the persisted automation master switch is enabled. The mutation
boundary rechecks that switch and duplicate blockers. Turning the switch on alone
does not evaluate historical Inbox work.

Import follows `FinanceDocument → domain validation → normalized persistence`.
Export follows `normalized persistence → FinanceDocument`. Production first
launch creates an empty local document; only previews and tests load the app-
owned authoritative development fixture.

## The civil-date boundary

`FinanceCore.Day` is a zone-free civil date and stays that way. `Date` is an
instant. The app converts between them in exactly one place, in the device's
time zone:

```text
DatePicker → Date → CalendarDay(_:in: .current) → TransactionDraft.day
                                                       ↓
                                        DomainMapper.day(_: CalendarDay) → Day
```

`TransactionDraft` carries a `CalendarDay`, not a `Date`, so the day a person
selected cannot be reinterpreted downstream. `DomainMapper.date(_:in:)` and
`day(_:in:)` use a Gregorian, `en_US_POSIX` calendar whose only variable is the
time zone; both directions use the same one. `CalendarDay.date(in:)` anchors at
midday, because a spring-forward transition can delete local midnight.

Reading a locally picked date in UTC — what the mapper used to do — shifts the
day by one in every zone with a non-zero offset, and at a month end shifts the
month.

## The entry error contract

`add(_:)` throws. A return means persisted; every other outcome is a typed
`AppEntryError`. `DomainMapper.transaction(from:accounts:)` produces those
errors for anything it cannot map, and `FinanceStore.add` adds the store-level
ones (read-only store, failed write) and rolls the in-memory document back if
the write fails. The sheet renders `error.message`, stays open, and keeps its
fields.

The app layer never approximates an unsupported entry into a supported one. A
shared expense is refused rather than stored at full price, because
`FinanceCore` has no partial-consumption model and inventing one above the
facade would put a number in the ledger that the engine does not mean.

## The removal contract

A transaction is removed only when nothing durable still refers to it.
`FinanceStore.removalBlocker(forTransaction:)` is the single authority, read
twice: once by the screen, to decide whether to offer the action, and again
inside `deleteActivityRow` before anything is written, so an answer that went
stale while the screen was open cannot authorise the removal.

Four durable records name a transaction by identifier, and each is a decision
or an observation rather than bookkeeping to tidy away:

| Record | Refused because |
|---|---|
| `ObligationSettlement.actualTransactionID` | this payment is recorded as settling an expected occurrence |
| `ExternalEvidenceLink.transactionID` | bank evidence was decided to mean this transaction |
| another `Transaction.linkedTransactionID` | a refund, repayment or disposal is recorded against it |
| `PlannedPurchase.purchasedTransactionID` | a goal records it as the purchase |

**Nothing cascades.** Removing a row never deletes a settlement, an evidence
link or a decision recorded elsewhere; the removal is refused instead and the
screen says which relationship stands in the way.

The first two would also fail on the way to disk — `ReconciliationLedger` and
`ExternalEvidenceReview` both refuse a document naming a transaction it does
not contain — so checking them up front turns an opaque write failure into a
sentence a person can act on. The last two have no such backstop: a refund
whose linked expense disappears silently starts offsetting spending the
reversal had already cancelled, because `refundOffsetsAnything` reads a missing
link as "not reversed". That asymmetry is what the check exists for.

Provenance decides the rest. Only `evidenceGrade == .userConfirmed` is
removable — the grade the domain already requires of the confirmations behind a
trusted rule, and the grade both of this app's entry paths produce. Imported
and reconstructed records are evidence the app cannot recreate, so it does not
offer to erase them.

There is no correction primitive. Nothing updates a stored transaction in
place, and removal is deliberately not paired with re-entry: delete-then-add
would mint a new identifier and drop every relationship the old one carried.

## Currency at the entry boundary

`EntryOptions` carries each account's currency exponent, and entry parses at
that scale. Excess precision is a refusal, not a rounding. The persistence
layer already stored exponents per money value; entry now matches it.

## Account and income-source identity

Accounts answer where money moved. Income sources answer why or from which
economic stream income arrived. The facade therefore uses **Paid from**,
**Received in**, **From / To**, and **Income source** as distinct fields and
carries stable IDs for each relationship. Activity resolves current names from
those IDs, so a rename updates history without rewriting transactions.

Only active accounts and income sources are offered for new entries. Historical
filters are the union of active and referenced entities, so deactivation never
hides old activity. Remembered expense/income accounts are app preferences. An
income source's preferred receiving account uses FinanceCore's planning hint
and is a suggestion only; the saved transaction leg always reflects the user's
actual selection.

## Multi-currency policy

The euro headline figures — month projections, the everyday budget total, and
monthly unfunded volume — are euro-only. A planned event, budget, or settlement
shortfall in another currency is preserved and shown in its own currency,
never converted and never summed in. `ForecastResult.unfundedByMonth` carries a
`MoneyBag`; `DomainMapper` reads EUR explicitly and maps every other currency
into ISO-sorted facade amounts. Converting remains a separate, explicitly rated
domain event; a projection that invents a rate is a projection about a number
nobody committed to.

## Persistence integrity

Closed vocabularies fail loudly. An unrecognised stored token throws
`PersistenceMappingError.unknownEnumValue` rather than decoding to a plausible
default, because a default turns unreadable data into valid-looking accounting
that is simply wrong. Payment rails are the deliberate exception: they are an
open vocabulary and an unknown token becomes a named rail.

`PersistedSchema.supported` gates both load and import. A store that fails to
load leaves `FinanceStore.loadFailure` set: the app opens empty and refuses to
write, so the next entry cannot purge rows that are still the only copy of
themselves. Import validates before it replaces — one account per identifier,
one current balance per account.

## Budget progress

`MonthlyBudgetEngine.report` computes targets, spent amounts, commitments,
remaining capacity, and pace for the selected month. DomainMapper maps that
report into BudgetLine values; transaction presentation supplies category keys.
Budget progress follows recorded economic activity, not unreviewed bank evidence.
The euro budget headline does not convert or sum other currencies.

## Financial truth boundaries

Account truth and personal economic truth are independent. Custody of money
through bank and cash movements does not establish personal ownership. Only
the user's owned share contributes to personal resources and economic effects;
other people's money does not become personal income or budget headroom.

Safe-to-spend exposes two values: a non-negative headline and signed raw
headroom. Likewise, settlement failure describes only an actually unsettled
amount; a global pool deficit is reported separately through first risk and
runway balances.

Certainty controls scenarios. A guaranteed dated inflow participates in
guaranteed/base/upside projections but is not current cash before its receipt
day. Debts exist independently of schedules: an acknowledged debt has no
forecast payments until an explicit payment agreement is recorded.

## Persistence lifecycle

Manual transaction entry uses a narrow append to the normalized SwiftData
graph. It validates the resulting document, then saves the new transaction,
its legs, entry preferences, and document revision together. A failed save
rolls the context back. Import, bank evidence, and other structural edits use
the full validate-then-replace writer; checkpoint and archive rows remain
outside its purge. The operational store refuses an `Int64.min` money value
before preview, write, or load because its signed magnitude cannot be
calculated. The interchange format can still round-trip that wire value.

Bank snapshot reads retain the binding set with which their page walk began.
An older completed read cannot replace a newer completed read. Pending and
live-coverage authority also advance by provider timestamp, and balance
snapshots advance by observation timestamp. A complete empty remote directory
clears read-through remote rows; an incomplete or failed walk changes none.

History amount ranges and amount sorting require one selected currency and
its recorded exponent. The editor refuses malformed, over-precise, or
out-of-range bounds before applying a query. Archive rows with an ambiguous
exponent for the same currency code cannot offer amount comparison.

Historically, Phase 1.7 replaced disposable pre-alpha sample data with a new
`FinanceCore-1.1` SwiftData store. That exception is closed: genuine user data
now exists. Incompatible schemas require versioned migrations with preservation
and round-trip tests; resetting or deleting the store is not a migration.

The 1.5 trusted-rule change is additive: three normalized entities are added and
1.1–1.4 documents decode with empty rule, audit, and suppression arrays. A disk
migration test opens a pre-1.5 SwiftData store with the current model and proves
its financial rows survive while the new tables begin empty.

## Activity history and synced bank movements

Activity combines three read-only projections: the reconstructed archive up to
its explicit cutoff, recorded ledger transactions after that cutoff, and synced
bank movements after the cutoff. Durable bank observations remain browseable
even when outside the review boundary or on an inactive binding. Provisional
rows appear only when present in current authoritative pending membership.
Missing bank dates are shown as unknown and are never replaced by receipt time.

A bank row is suppressed only when its persisted evidence link points to a
ledger transaction that this view already displays. Amount, merchant, date and
cross-provider candidate resemblance do not establish identity. Showing bank
history creates no economic transaction, category, spending or income. The bank
detail states its status and dates and offers the existing review flow where
available. Filter catalogs combine archive, ledger and bank options; a bank
import refreshes the history presentation without requiring a relaunch.
