# FinanceApp

A native, local-first iOS personal-finance app. It can pull bank evidence from
a self-hosted sync service, authenticating as a paired device that signs every
request with a key it generates on device and never transmits. No bank
credential, admin token or shared secret is embedded in the app, and there is
no analytics.

Local-first is not a slogan here: the ledger is the local document. Sync only
ever adds *evidence*, and evidence becomes spending or income when a person says
so. With the network gone, entry, Activity, Plan, balances and the existing Bank
Inbox all keep working.

The app answers three questions without collapsing distinct financial truths:

1. What is held in financial accounts, physical cash, and all tracked holdings?
2. What is personally safe to spend, and what raw deficit constrains it?
3. Which dated event first puts the relevant payment pool at risk?

## Architecture

There is one direction of dependency and one accounting implementation:

```text
SwiftUI
  ↓
FinanceProviding / FinanceAppSnapshot
  ↓
FinanceStore
  ↓
DomainMapper
  ↓
SwiftData + FinanceCore
```

No SwiftUI screen imports `FinanceCore`. `FinanceAppSnapshot`, `Amount`,
`TransactionDraft`, and `FinanceProviding` are product-facing types in
`FinanceApp/Surface`. The three persistence-layer importers are the boundary:

| File | Responsibility |
|---|---|
| `DomainMapper.swift` | Maps hardened `FinanceOverview` output to the app facade and expands simple drafts into domain transactions |
| `PersistedModels.swift` | Maps the normalized SwiftData graph to and from `FinanceDocument` |
| `FinanceStore.swift` | Owns the document/context, runs the sole `ForecastEngine`, and publishes snapshots |

The app target remains in Swift 5 language mode. The local package at
`Packages/FinanceCore` is Swift 6, imports Foundation only, and contains the
only `Money`, account, transaction, economic-effect, and forecast semantics in
production. It is the authoritative copy and is edited here.

See [docs/architecture.md](docs/architecture.md) for the full boundary and
[docs/swiftdata-migration.md](docs/swiftdata-migration.md) for the persistence
schema.

## Bank sync

```text
private Worker ── signed HTTPS ── BankSyncClient ── DomainMapper ── FinanceStore ── SwiftUI
```

The app holds a P-256 key pair, generated in the Secure Enclave where the
hardware provides one and never leaving the device. Pairing claims a single-use
code the operator mints; from then on every request carries a signature over its
method, path-and-query, body digest, timestamp and nonce, so a captured request
cannot be replayed or re-pointed. The service can revoke one device without
touching another.

`BANK_SYNC_BASE_URL` is a build setting substituted into the Info.plist, and
only HTTPS is accepted. It ships as `https://finance-bank-sync.example.invalid`
— a placeholder, not a running service. Point it at your own deployment before
using sync; everything else in the app works without it.

Remote accounts must be mapped to local ones explicitly. An unmapped account
creates no work at all: a dormant non-EUR pocket is simply ignored. Each mapping carries a cutover, defaulting to the day that local
account's balance was last stated, because activity already inside an opening
balance would otherwise be counted twice.

## FinanceDocument interchange

`FinanceDocument` schema 1.6.0 is the import/export spine (1.1–1.5 remain readable):

```text
FinanceDocument ⇄ FinanceCore domain ⇄ normalized SwiftData rows
```

The document is never stored as an opaque blob. Import replaces the normalized
graph; export rebuilds the same versioned document. The bundled hardened
September fixture proves exact round-trip fidelity in integration tests. The
1.3 additions preserve provider observations, typed provider balances, review
state, and evidence links without turning them into transactions. The 1.5
additions preserve explicit trusted-rule definitions, append-only rule audit
events, and per-observation reversal suppressions. Older documents decode with
no rules or suppressions, which is deliberately inert.

Trusted rules match exact provider/binding/merchant-identity/direction/currency
predicates and keep their economic kind, category, user label, recurring
obligation, and economic source independent. They begin inactive and
suggestion-only. The automatic boundary is booked, durable,
economically eligible expense debits matched through structured merchant
identity, explicit provider purchase semantics, and at least two confirmations. The app exposes
distinct suggestion and automatic approvals, supporting evidence, current-match
dry-run counts, and disablement; approval itself never applies existing matches.
Real bank import still creates evidence only and does not invoke automatic
resolution.

Production first launch starts with an empty local document. Fictional personal
history is not silently seeded. The development fixture is used only by
previews, development rendering, and tests.

### First-run onboarding and import

An empty store shows onboarding with two ways in — **Import current state** and
**Set up manually** — and no third. There is no fixture behind either.

Import runs in four steps, and writes nothing before the last:

```text
choose a JSON file → decode + schema + semantic validation → preview
    → review balances → confirm
```

Rules the path enforces:

- **Empty store only.** There is no merge or reconciliation yet, so importing
  into an existing history is refused (`AppImportError.storeNotEmpty`) rather
  than risking duplicated money. An *unreadable* store is refused too: it is not
  an empty one, and its rows are the only copy of themselves.
- **Atomic.** `StoredDocumentGraph.replace` and `FinanceStore` both roll the
  context back when a write fails. A refused import leaves the store exactly as
  it was, in memory and on disk.
- **Dated balances.** A balance is shown with the day it was observed
  (`As of 20 Aug`), never as a "current balance", and can be corrected before
  the import is confirmed.
- **Nothing is echoed.** Decoder messages quote the value they choked on, so
  the import path never propagates them: a rejection names the *field*
  (`balances[0].balance`) and the shape of the problem, never the contents. The
  chosen file is read once and not copied into the container; what persists is
  the normalized graph.
- **No restart.** `FinanceStore` recalculates on confirmation, so Home renders
  from the imported data on the next frame.

`Settings → Data & Privacy` offers the same import, and the other direction.

### Export backup

Export writes the stored document out as an interchange file and then proves
it: the bytes are decoded and semantically validated through the *import*
path, and re-encoded, and the file is offered only if that re-encoding is
byte-identical. A document that decodes but is not a fixed point of the
encoder has lost or reinterpreted something, and the loss would otherwise only
surface on the day somebody needed the file.

Every figure on the screen is counted from the document read back out of the
file, not from the live store, so what a person is shown describes the file.

Three refusals, each with its own reason:

- the stored graph could not be read — the store is serving an empty plan, so
  a backup taken now would be a well-formed file holding nothing;
- there is no persistent store behind the facade — a preview has nothing to
  copy;
- there is no account — a restore requires one, so nothing here could produce
  a file that restores.

A backup carries the `FinanceDocument` and only that. The historical archive,
local checkpoint history and the device's bank pairing live outside it by
design, and the screen says so rather than implying a complete device copy.

### Supported schema versions

`PersistedSchema.supported` is the whole list of document versions this build
will read. Writing always produces `PersistedSchema.current` (`1.3.0`); reading
also accepts `1.1.0` and `1.2.0`, whose differences are additive — a 1.1.0
document is a 1.3.0 document with nothing reconciled or externally evidenced,
which this build can represent exactly,
and refusing it would strand every export taken before reconciliation existed.
An import at a readable older version is stored as the current one. Loading a
stored document or importing a `FinanceDocument` at any other version throws
`PersistenceMappingError.unsupportedSchemaVersion` instead of decoding it on
the assumption that the fields still mean what they used to. A version that
should be readable earns explicit migration logic and a place on that list, in
the same change.

### The development fixture does not ship

`FinanceApp/Resources/sample-scenario.fixture.json` is an invented sample
document used by previews and tests — no person, account, merchant, amount or
date in it refers to anything real. Its only caller sits behind `#if DEBUG`, so
it could never execute in Release; even so, sample data has no business being
in a shipped bundle. Unreachable is not the same as absent.

The app target's Release configuration sets
`EXCLUDED_SOURCE_FILE_NAMES = "*.fixture.json"`, so the file is a member of
Debug builds only. Previews and tests still load it; a shipped bundle has no
copy. `Scripts/verify-release-bundle.sh` builds Release and fails if any
fixture file is found inside the produced `.app`.

## Manual entry

### Civil dates

A date someone picks has no instant and no time zone; a `Date` is a point on
the timeline. Converting between them requires saying *whose* calendar day is
meant, and the answer is always the person's own zone.

- `CalendarDay` (year/month/day) is the product-facing civil date, and
  `TransactionDraft` carries one. The sheet converts the `DatePicker`'s value
  once, at the UI boundary, with `Calendar.current`'s zone.
- `DomainMapper.date(_:in:)` / `day(_:in:)` bridge `FinanceCore.Day` and
  `Date` in the device's zone — a Gregorian, POSIX calendar whose *only*
  variable is the time zone. They previously used a UTC-fixed calendar, which
  stored 16 September as the 15th anywhere east of Greenwich and rolled a
  month-end entry into the month before.
- A `CalendarDay` renders as midday, not midnight: a spring-forward transition
  can delete local midnight altogether.
- `FinanceCore` keeps its zone-free `Day` arithmetic. This is the one place a
  zone is applied, and it is applied identically in both directions.

`CivilDateTests` round-trips every day of 2026 through Europe/Paris,
Africa/Casablanca, UTC and America/New_York, and covers both DST transitions in
each and every month end.

### The `add` contract

`FinanceProviding.add(_:)` throws. Returning means the entry is in the document
*and* on disk; anything else throws a typed `AppEntryError` naming the reason —
unknown or stale account, currency mismatch, a transfer with no or an
ineligible destination, an invalid amount or share, a shared expense, a
read-only store, or a failed write. There is no success-shaped no-op.

The sheet stays open on a refusal, keeps every field as it was, and shows the
error's `message`. It dismisses only after a successful save. A write that
fails rolls the in-memory document back, so a transaction never appears saved
while the store does not have it.

Transfer destinations are filtered to the paid-from account's currency
(`EntryOptions.transferDestinations(from:)`), so a plain cross-currency
transfer is not offered in the first place. The mapper rejects one if a stale
or hand-built draft reaches it: the app never pretends one numeric amount is
present on both sides of an FX movement.

Expense, income, and transfer entry keep account movement distinct from
economic origin. Expenses require **Paid from**; income requires both
**Received in** and an **Income source**; transfers require **From** and **To**.
Drafts carry stable account and income-source identifiers, never display
names. The mapper resolves those identifiers and creates the FinanceCore legs
and economic linkage.

Account and income-source editors live under More. Account opening balance is
stored as an observed balance as of the selected date, not as ordinary income.
An income source can suggest a preferred receiving account, but entry remains
overridable and the transaction records the account actually chosen. Inactive
entities are excluded from new entry while their stable identifiers continue
to resolve renamed historical rows and filters.

### Amount precision

Entry reads a typed figure at the scale of the account it is going to.
`AccountOption.fractionDigits` carries the currency exponent through
`EntryOptions`, and `Amount.parse(_:currencyCode:fractionDigits:)` uses it: EUR
`12.34` → 1234, JPY `123` → 123, KWD `12.345` → 12345. Nothing in entry
hard-codes two decimals.

A figure finer than the currency is **refused**, never rounded — turning
`123.5` into ¥124 invents a number nobody typed. The field says so inline and
Save stays disabled. Text that is not a plain number is rejected too, rather
than being read as its numeric prefix.

### Shared expenses are not offered

An owned share is offered for income only. A part-owned inflow becomes a
pass-through whose unowned share is not personal income — that is implemented
and tested. FinanceCore has no partial-consumption model, so an expense share
has nothing behind it: the control is absent for expenses
(`TransactionDraft.Kind.supportsOwnShareEntry`), and a draft that carries one
anyway is refused with `AppEntryError.sharedExpenseNotSupported` rather than
stored at full price.

## Budget progress is not wired yet

Nothing attributes a transaction to a budget yet, so `BudgetLine.spent` is a
placeholder zero and everything derived from it — remaining, fraction,
overspent — says nothing. `BudgetLine.tracksSpending` and
`BudgetSummary.tracksSpending` are `false`, and the screens read them: Home leads with the budget itself rather than "€170.00 left
of €170.00", Plan shows the limit rather than "€0.00 / €170.00", and neither
draws a progress bar. A bar at 0% is a claim, and the claim would be false.

Wiring actual spend attribution is still to do.

## Semantic invariants

- `accountCash`, physical cash, and total tracked holdings are separate. The
  foreign-currency cash pocket cannot settle a EUR electronic payment.
- Money is signed `Int64` minor units plus currency code and exponent. No path
  assumes exponent 2; the integration suite round-trips three-decimal KWD.
- Payment rails are stable semantic tokens such as `sepa_direct_debit`, never
  persisted `OptionSet` bit positions. Rails are an open vocabulary by design,
  so an unrecognised token becomes a named rail rather than an error; the
  closed enumerations below are treated the opposite way.
- Stored values from closed vocabularies — transaction kind, factivity,
  lifecycle, date precision, evidence grade, account kind, balance status,
  certainty, commitment status, spending class, payment status, scenario —
  fail loudly when unrecognised
  (`PersistenceMappingError.unknownEnumValue`). They are never defaulted to a
  plausible neighbour: silently reading an unknown kind as `expense`, an
  unknown factivity as `observed`, or an unknown account as `bank` converts
  unreadable data into confidently wrong accounting that nothing downstream
  can detect.
- A store that cannot be read opens empty **and read-only**. `add` and delete
  refuse while `FinanceStore.loadFailure` is set, so the first new entry
  cannot purge rows that failed to load but are still the only copy of them.
  An explicit `importDocument` is the one path that may replace them.
- Removing a transaction is refused while any durable record still names it —
  a settlement, an evidence link, another transaction's link, or a goal's
  purchase — and nothing cascades. Only what a person entered here is
  removable; imported evidence is not. See
  [docs/architecture.md](docs/architecture.md) for the whole contract.
- Import is validated before anything is written: exactly one account per
  identifier and at most one current balance per account. A duplicate fails the
  import naming the record, rather than silently keeping whichever row the
  store's uniqueness constraint happened to write last.
- The month projection headline is EUR-only. A planned event in another
  currency is listed in `MonthProjection.eventsInOtherCurrencies`, kept in its
  own currency, and left out of the euro totals. Monthly settlement shortfalls
  follow the same rule: `unfundedEUR` is explicit, while
  `unfundedInOtherCurrencies` preserves each foreign deficit separately. No
  rate is invented, and no cross-currency total is formed.
- Transfers, cash withdrawals, currency conversions, financing repayments,
  refunds, and pass-through disposals are not ordinary spending.
- Ownership is explicit. The sample scenario's 1,000.00 custody chain produces
  400.00 of personal income and 600.00 of pass-through-not-mine; only the net
  400.00 affects personal resources.
- `safeToSpend` is clamped to a non-negative display amount while
  `rawShortfall` preserves the signed deficit. A visible 0.00 cannot hide a
  −256.00 constraint.
- Settlement failure means an amount actually failed to settle. A settled
  payment followed by a negative global pool is a separate pool deficit/risk.
- Income certainty is scenario policy, not decoration. The sample scenario's
  guaranteed owned share enters guaranteed, base, and upside forecasts but does
  not enter current account cash before receipt; UI copy says “Not received
  yet.”
- The 960.00 EUR arrears debt is visible with an empty committed payment
  schedule. No recovery instalments are invented.

## Persistence reset

The normalized schema intentionally replaced the earlier disposable pre-alpha
schema instead of migrating sample rows. The normalized store uses the distinct configuration
name `FinanceCore-1.1`, so SwiftData does not attempt an inferred migration from
the temporary schema.

This is safe only because the app has no real user-entered production data.
Once actual user data begins, every incompatible schema change requires a
versioned migration and explicit preservation tests.

## Building and testing

Built and verified with Xcode 26.6 (Swift 6.2). The project format and
Swift 6 language mode need Xcode 16 or newer; the deployment target is iOS 18.

```sh
open FinanceApp.xcodeproj
```

Core tests:

```sh
cd Packages/FinanceCore && swift test
# or, with the output filtered to a verdict:
Scripts/test-core
```

App and integration tests:

```sh
xcodebuild -project FinanceApp.xcodeproj -scheme FinanceApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
# or:
Scripts/test-app
```

The wrappers in `Scripts/` run exactly these commands and keep the full log on
disk; they never skip a test, hide a failure or alter an exit code. `Scripts/check`
is the quick gate (Core tests plus a Debug build) and `Scripts/release-gate`
builds Release and proves no sample fixture reached the produced bundle.

The app suite includes facade-only screen rendering plus FinanceDocument,
SwiftData, transaction-semantics, ownership, arrears, and authoritative
forecast-vector integration coverage, together with the hardening suites:
civil dates across four time zones, entry validation and the `add`
error contract, currency-exponent parsing, persistence corruption and schema
gating, multi-currency projection, and budget-progress copy.

Release bundle check:

```sh
Scripts/verify-release-bundle.sh   # or Scripts/release-gate
```

A `ModelContext` does not keep its `ModelContainer` alive. Test helpers hand
back both together; one that returns only the context leaves the test working
against a deallocated container, which traps.

## Current UI scope

Home, Activity, Add, Plan, and More are built. The UI uses semantic system
colors, Dynamic Type-scaled metrics, and VoiceOver labels. Account-aware entry,
account and income-source editors, separate account/source activity filters,
and transaction detail are available for real local use. SwiftUI produces only
facade drafts; `DomainMapper` decides account legs, economic kind, ownership,
and withdrawal semantics.

Explicit real-data import, a rated FX editor, and expected-to-actual matching
are future product work.
