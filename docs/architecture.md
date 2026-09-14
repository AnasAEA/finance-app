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
Bank evidence import remains evidence-only; the first slice does not call the
automatic application operation against the live store.

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

`BudgetLine.tracksSpending` is `false` throughout Phase 1.8: nothing attributes
activity to a budget yet. The screens read the flag and show the limit instead
of a remaining figure and a 0% bar. Wiring attribution is a Phase 2 task; when
it lands, the flag becomes `true` and the existing copy paths turn back on.

## Financial truth boundaries

Account truth and personal economic truth are independent. The September 16
chain may show custody of 1,000.00 through physical and bank rail events, while
ownership and the dependent disposal make its personal net resource exactly
400.00. The other 600.00 is never personal income, spending, safe capacity, or
budget headroom.

Safe-to-spend exposes two values: a non-negative headline and signed raw
headroom. Likewise, settlement failure describes only an actually unsettled
amount; a global pool deficit is reported separately through first risk and
runway balances.

Certainty controls scenarios. A guaranteed dated inflow participates in
guaranteed/base/upside projections but is not current cash before its receipt
day. Debts exist independently of schedules: the acknowledged 960.00 EUR arrears has no forecast payments until an explicit agreement is recorded.

## Persistence lifecycle

The Phase-1 schema was disposable pre-alpha data, so Phase 1.7 uses a new
`FinanceCore-1.1` SwiftData store rather than an elaborate compatibility
migration. This exception ends as soon as genuine user-entered data exists;
future incompatible schemas must use versioned migrations with preservation and
round-trip tests.

The 1.5 trusted-rule change is additive: three normalized entities are added and
1.1–1.4 documents decode with empty rule, audit, and suppression arrays. A disk
migration test opens a pre-1.5 SwiftData store with the current model and proves
its financial rows survive while the new tables begin empty.
