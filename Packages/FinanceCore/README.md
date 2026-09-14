# FinanceCore

Pure-Swift financial domain and day-level forecast engine for the personal
budget iOS app. No SwiftUI, no UIKit, no SwiftData, no networking, no
persistence — just the semantics and the simulation, fully deterministic and
fully tested (103 tests, including a complete hand-derived acceptance
vector). **Swift 6 language mode**, strict concurrency, `Sendable` domain
types by construction.

## Modules

```
Sources/FinanceCore/
├── Money/         Money, Currency, Rounding, ExchangeRate, MoneyBag (Int64 minor units, no Double; no implicit FX)
├── Time/          Day, MonthKey                              (Gregorian, Foundation-free)
├── Accounts/      Account, PaymentRail, capabilities         (currency AND rail satisfaction)
├── Transactions/  Transaction kinds, lifecycle, ownership (exactly validated), provenance, Economics per-row + totals
├── Planning/      IncomeCertainty ladder + dependsOn, scenarios, commitment status, recurrences, budgets, debts, installments
├── Forecast/      ForecastEngine, event phases & outflow semantics, planner, LiquiditySnapshot facade
└── Interchange/   FinanceDocument (versioned deterministic JSON), SCHEMA.md, ForecastComposer
```

## Quick start

```swift
let document = try Interchange.decode(json)
let request = ForecastComposer.makeRequest(from: document,
                                           startDate: start, endDate: end,
                                           scenario: .base)
let result = try ForecastEngine.run(request)
result.projectedEndBalance    // Money
result.firstRisk              // FirstRisk? (day, kind, trigger event)
result.settlementFailures     // per-payment requested/settled/unsettled
let snapshot = FinanceOverview.snapshot(document: document, result: result,
                                        today: start, horizonDays: 30)
snapshot.safeToSpend          // amount + rawHeadroom (deficits never clamped away)
```

## Reading order

1. `README.md` (this file)
2. `INTEGRATION.md` — how the SwiftUI app consumes the package (the facade)
3. `DOMAIN.md` — the full semantic contract with worked examples
4. `Sources/FinanceCore/Interchange/SCHEMA.md` — the JSON interchange contract

## Testing

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test   # 103 tests
```

(Requires a toolchain with XCTest — full Xcode, or the `DEVELOPER_DIR` prefix
when only CommandLineTools is selected.)

The fixture `Tests/FinanceCoreTests/Fixtures/sample-scenario.fixture.json`
is development data, clearly marked as such — not canonical financial
evidence. It encodes the two standing policies: the Sep 16 parental share is
**guaranteed** income of exactly 400.00 (never 1,000.00), and the 960.00 EUR rent
arrears carry **no committed repayment** (empty schedule until a real
agreement exists).
