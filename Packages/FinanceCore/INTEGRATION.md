# FinanceCore — Integration Notes for the SwiftUI App

This package is the financial domain + forecast core. It has **no UI
dependency** (pure Swift, tested from the command line). Add it to the app
target and `import FinanceCore`.

```swift
.package(path: "../FinanceCore")   // or a remote/zip reference
.product(name: "FinanceCore", package: "FinanceCore")
```

Platforms: iOS 16+, macOS 13+. **Swift 6 language mode** (the package builds
and tests clean under Swift 6 strict concurrency; all domain types are
`Sendable` by construction). Build/test from the CLI with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`.

## The one flow you need

Everything the Home / Activity / Plan screens need starts from a
`FinanceDocument` (decoded JSON — see `Interchange.decode`) plus a horizon:

```swift
import FinanceCore

let document = try Interchange.decode(jsonData)

let request = ForecastComposer.makeRequest(
    from: document,
    startDate: Day(isoString: "2026-09-01")!,   // or today
    endDate: Day(isoString: "2026-09-30")!,
    scenario: .base                              // nil → planning.defaultScenario
)
let result = try ForecastEngine.run(request)

let snapshot = FinanceOverview.snapshot(
    document: document,
    result: result,
    today: Day(isoString: "2026-09-01")!,
    horizonDays: 30
)
```

`ForecastEngine.run` is pure and synchronous: same request → same result.
Typical horizons (30–90 days) run in microseconds; call it from any queue,
including `Task.detached`, and cache freely.

## The facade — what to render, from where

The UI should never need forensic internals (legs, provenance, rail
mechanics). Everything screen-shaped is already computed:

| Screen concept | Source |
|---|---|
| "Money I can spend" (bank/wallet euro cash) | `snapshot.financialAccountLiquidity` |
| Physical cash, **per currency** ("Dirhams: 200 MAD") | `snapshot.physicalCashByCurrency.amount(in: .mad)` / `.currencies` |
| Physical holdings display list (name, amount, carried EUR) | `snapshot.physicalHoldings` |
| Total tracked holdings, per currency, never collapsed | `snapshot.totalTrackedHoldings` (`MoneyBag`) |
| EUR-comparable liquidity (incl. carried foreign cost) | `snapshot.trackedEURLiquidity` |
| **Safe to spend** — honest, deficit never hidden | `snapshot.safeToSpend` (below) |
| Committed outflows, next N days | `snapshot.committedOutflowsNext` (excludes transfers/disposals) |
| Rail movements (transfers, deposits, disposals) | `snapshot.railRelocations` |
| Upcoming payments feed | `snapshot.upcoming` (`[ForecastEvent]`, deterministic order) |
| First red day + how bad | `snapshot.firstRiskDate`, `snapshot.minimumBridge` |
| What triggered it | `result.firstRisk` (`.poolDeficit` / `.belowSafetyFloor`, trigger event id + label) |
| Safety-floor breach | `snapshot.firstBelowFloorDate` |
| Cash runway in days | `result.cashRunwayDays` |
| Day-by-day chart line | `result.dailyBalances.map { ($0.day, $0.spendablePool) }` |
| End-of-month projection / month cards | `result.projectedMonthEnd[month]` or `FinanceOverview.monthEndPool(month, in: result)` |
| Unfunded (unsettled) volume per month, **per currency** | `result.unfundedByMonth[month]` (a `MoneyBag`) |
| Unfunded in one currency (e.g. the EUR headline) | `result.unfunded(in: .eur, month: month)` / `result.unfundedEURByMonth` — excludes, never converts, foreign shortfalls |
| Scenario switcher (Guaranteed/Base/Upside) | re-run `makeRequest(..., scenario:)` — never edit history |
| Weekly / monthly review (structured, no copy) | `ReviewEngine.review(ReviewRequest)` — ephemeral; not stored |

### `SafeToSpendResult` — never hide a deficit

```swift
snapshot.safeToSpend.amount        // display-safe: max(rawHeadroom, 0)
snapshot.safeToSpend.rawHeadroom   // signed truth (negative = deficit)
snapshot.safeToSpend.dailyAmount   // headroom ÷ horizon, or nil when in deficit
snapshot.safeToSpend.isDeficit     // render this prominently, don't clamp it away
snapshot.safeToSpend.basis         // what the number is
snapshot.safeToSpend.firstConstraint // the first day a commitment bites
```

The fixture snapshot demonstrates the contract: rawHeadroom **−114.76**,
amount 0.00, `dailyAmount` nil, `isDeficit` true. A UI that renders only
`amount` would show a serene zero on the eve of a missed rent; render
`rawHeadroom`/`isDeficit` too.

Formatting money for display: `money.decimalString` → `"396.00"`,
`money.currency.code` → `"EUR"`, or `money.description` → `"396.00 EUR"`.

## Semantics the UI must not silently break

These are enforced by the core, but presentation should not fight them:

1. **Movement ≠ spending.** A transfer, an ATM withdrawal, a bank deposit or
   a financing repayment is not consumption — they surface in
   `railRelocations`, never in `committedOutflowsNext`. Use
   `Economics.totals(...)` for headline numbers; never sum raw legs.
2. **Pass-through money is not the user's.** The sample fixture's Mar 16
   chain puts +1000 in the pocket and moves +400 to the bank — income is
   exactly the owned 400. The temporary 1000 balance is real but is not
   capacity, and the −600
   handover is a *disposal*, not spending.
3. **A deficit is never clamped away** (see `SafeToSpendResult` above).
4. **Refunds are not income** — they offset spending.
5. **Scenario ≠ history.** Switching to Upside adds prospective income
   events; it never rewrites observed facts. `reversed` transactions (the
   pulled-back August rent) contribute zero economics directly — there is no
   fake income entry to find and mis-render.
6. **TARGET/POSSIBLE money must be visually distinct.**
   `result.includedIncomeEventIDs` / `excludedIncomeEventIDs` tell you which
   prospective sources entered the projection; label upside-only sources as
   such in the UI. A zero-amount stream (the royalties line)
   appears in neither list — by design.
7. **Physical cash ≠ bank liquidity, and currencies never collapse.** The
   dirham pocket lives in `physicalCashByCurrency` / `totalTrackedHoldings`,
   never in `financialAccountLiquidity` or `spendablePool`. If a payment
   needs a rail the pocket cannot ride, it cannot be paid from it — show the
   settlement failure (`result.settlementFailures`: requested / settled /
   unsettled / eligible accounts) instead of implying coverage.
8. **Settlement failure ≠ pool deficit.** A €6.13 card payment that settled
   in full is not "bounced" just because the pool was negative that day; and
   a SEPA debit can fail while the pool reads positive. Render
   `settlementFailures` and `firstRisk` as the two different facts they are.
9. **Intraday dips are real.** `lowestBalance` is measured after every event
   application (debits before credits), not at day close. Sep 16 closes at
   +132.50 after dipping to −267.50 (`lowestBalanceDate`).

## Money hygiene rules for app code

- Never `Double` a `Money`. Parse user input with
  `Money(exactDecimal: text, currency: .eur)` (failable) and show the error
  when it returns nil.
- Never convert currencies without an explicit `ExchangeRate`; never sum a
  `MoneyBag` across currencies — read `amount(in:)` per currency. This
  includes `unfundedByMonth`: the UI chooses its presentation currency
  explicitly (`unfunded(in:month:)`) and renders foreign-currency deficits
  separately; they are never auto-converted into the EUR headline and never
  dropped just because Home is EUR-led.
- `Day(isoString:)` for date entry/parsing; `day.isoString` for storage.
  Days have no timezone — no `Date`/`Calendar` anywhere in app finance code.
  The package deliberately carries **no Foundation date types**; the app owns
  the single `Day ↔ Date` bridge (create `Date` from `day.isoString` at the
  app boundary, never inside finance logic).
- No SwiftData/persistence inside the package — persistence is an app-layer
  concern; the interchange JSON is the storage contract.

## Where things live

- `Sources/FinanceCore/Interchange/SCHEMA.md` — the JSON contract field by
  field (version 1.1.0, with the changelog).
- `DOMAIN.md` — full semantics, worked examples, intentional simplifications.
- `Tests/FinanceCoreTests/Fixtures/sample-scenario.fixture.json` — a
  realistic **dev fixture** (marked `DEV-FIXTURE — NOT FINANCIAL EVIDENCE`)
  you can load for previews/tests. Expected September BASE vector for it:
  end-of-month pool **54.00**, first negative **2027-03-10** (housing day),
  true intraday minimum **−267.50** on 2027-03-16 (the day's everyday
  spending lands before the 1,000.00 arrival, which then deposits the owned
  400.00 and hands on the remaining 600.00), minimum bridge 267.50 / floor
  bridge 347.50 (floor = 80.00), and GUARANTEED == BASE for the month (the
  400.00 owned share is guaranteed).
- The fixture loader pattern:
  `Bundle.module.url(forResource: "sample-scenario", withExtension: "fixture.json", subdirectory: "Fixtures")`.

## Known limitations (v1)

- Variable budgets forecast as even daily spending.
- Window ("between the 5th and 8th") obligations forecast on the earliest day.
- Same-day ordering is conservative by default (debits first); a known-first
  credit is representable but must be stated explicitly.
- No historical import: the observed layer is populated by interchange
  documents, not by bank-statement parsing (out of scope by design).
- `FinanceDocument.transactions` is currently summarized, not a full
  five-year export.
