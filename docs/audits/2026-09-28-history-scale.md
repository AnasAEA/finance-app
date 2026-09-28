# Synthetic provider-history scale check — 2026-09-28

The app previously opened a 10,000-observation synthetic store in 206 seconds
after the SQLite read itself took about two seconds. Bank presentation asked
FinanceCore to search the full observation array for each row and rebuilt a
full observation dictionary inside each per-row suggestion lookup. The mapper
now passes the observation it already holds and reuses a read-only suggestion
lookup for the whole snapshot. Existing suggestion eligibility, duplicate
checks and financial state remain unchanged.

`FinanceAppTests/HistoryScaleDiagnostics.swift` is an opt-in, disk-backed
SwiftData diagnostic. Each run seeds one EUR account and binding with 1k, 10k
or 50k booked, unreviewed debit observations, encodes and decodes the portable
document, saves a fresh store, closes it,
reopens it with the current schema, opens `FinanceStore`, then requests another
base-scenario snapshot. A second variant includes one same-amount recorded
payment and merchant label, so every observation takes the existing-payment
suggestion path. It checks row counts and a resulting suggestion. All IDs,
amounts and merchant text are synthetic.

Measured once per size on an M1 Pro Mac (16 GB), macOS 27.0, Xcode 27.0,
iPhone 17 simulator (iOS 26.5). Times are wall seconds and include simulator
and SwiftData overhead. `storeOpen` includes a second graph load and initial
presentation; `recalculate` requests an additional complete snapshot.

| Shape | Rows | Save | Reopen/load | FinanceStore open | Recalculate |
| --- | ---: | ---: | ---: | ---: | ---: |
| No recorded payment, before | 1,000 | 0.45 | 0.24 | 2.19 | — |
| No recorded payment, before | 10,000 | 3.75 | 2.21 | 206.09 | — |
| No recorded payment, after | 1,000 | 0.46 | 0.24 | 0.27 | 0.02 |
| No recorded payment, after | 10,000 | 3.86 | 2.25 | 2.70 | 0.23 |
| No recorded payment, after | 50,000 | 20.26 | 12.16 | 14.28 | 1.12 |
| Same-amount recorded payment, after | 1,000 | 0.46 | 0.25 | 0.32 | 0.03 |
| Same-amount recorded payment, after | 10,000 | 4.05 | 2.35 | 3.04 | 0.34 |
| Same-amount recorded payment, after | 50,000 | 20.56 | 12.13 | 15.48 | 1.69 |

Portable encode/decode on the final matched-payment runs took 0.02/0.02s at
1k, 0.12/0.15s at 10k, and 0.57/0.74s at 50k. These are decode costs for a
valid synthetic document; malformed-input refusal and backup encryption have
separate tests.

The pre-change 50k case was deliberately not run after the 10k opening took
over three minutes. These numbers are a regression baseline for this shape,
not a phone latency or frame-rate promise. The 50k store still takes more than
12 seconds to load and roughly 20 seconds to save synchronously. Before using
that scale as a release target, measure history with multiple accounts,
transactions, linked evidence, recurring obligations and trusted rules; then
bound/paginate history presentation and move pure preparation off the main
actor with immutable inputs and generation checks. Disk writes and schema
upgrades need separate preservation checks.

Run one size with `TEST_RUNNER_FINANCE_HISTORY_COUNT=1000` (or `10000`,
`50000`) and `xcodebuild -project FinanceApp.xcodeproj -scheme FinanceApp
-destination 'platform=iOS Simulator,name=iPhone 17'
-only-testing:FinanceAppTests/HistoryScaleDiagnostics test`, after sourcing
`Scripts/xcode-env.sh`. Add
`TEST_RUNNER_FINANCE_HISTORY_MATCHED_TRANSACTION=1` for the payment variant.
The opt-in test is skipped by ordinary CI so the 50k case cannot silently
lengthen every PR check.
