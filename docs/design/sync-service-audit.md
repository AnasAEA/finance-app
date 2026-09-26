# Bank sync audit and improvement plan

Audit date: 2026-09-25.

Baselines read for this audit:

- App: `finance-app` `main` at `a3d46db`.
- Service: `finance-bank-sync-poc` `main` at `cf6d8d7` (one local tooling commit ahead of `origin/main`; the sync behavior below is the code in `service/`).

This document records the audit and the staged repair plan. The user authorized
implementation on 2026-09-25; deployment and remote migration remain separate
steps.

## Implementation in the current working trees

The first repair slice is implemented locally in both repositories. The app
requests 500 booked rows per page, uses terminal-page pending, balances and
candidates, refuses malformed mapped money, reports provider failures after a
successful evidence pull, invalidates pulls after unpairing, and refreshes from
the Worker when it becomes active. An identical pull skips the SwiftData graph
write and forecast recalculation. The Worker leaves unchanged booked rows,
balances and candidates untouched; booked change timestamps now describe content
changes. Candidate amount comparison is exact decimal text with an amount index.

This is a partial implementation of Phases 1, 2, 4 and 5. The Worker now returns
a terminal high-water key, and the phone persists it with the local store after
a complete import. Subsequent pulls re-read one day around that key to catch
in-progress provider writes. First pull and binding changes still replay all
history. A new provider success clock now updates only bank metadata rows when
the financial document is unchanged and reuses the published forecast. Worker
account and run writes still happen
on a quiet cycle; superseded pending snapshots are pruned, while old balance
and run rows remain. Withdrawal markers,
an asynchronous Sync Now status flow, and in-app reauthorization
remain to implement and validate. No live service or physical device was changed
by this slice.

The next local slice adds one active lease per provider and stages the complete
fetch before a single D1 publication transaction. Failed later accounts and
failed database statements leave the prior evidence intact. A stale lease
holder cannot publish after takeover. Grouped JSON statements published a
synthetic 1,600-row archive in the Worker tests. Candidate suggestions for the
affected window are cleared with publication and rebuilt afterward, so a failed
refresh cannot leave a stale unique suggestion. Sync Now names an overlapping
run explicitly. The Worker gate passes 186 service tests; the app Debug build
and 43 bank-sync tests on the iPhone 17 simulator pass. The simulator tests use
synthetic service responses. Migration 0004 and the Worker remain undeployed.

The following local Worker slice shortens routine AIS transaction queries to a
14-day overlap from each account's committed horizon. New accounts, accounts
with current pending rows, and the 02:00 UTC repair cycle still use the full
configured 90-day window. Missed days widen the overlap; a failed fetch does
not move the horizon. Synthetic tests cover these boundaries. The Worker gate
passes 194 service tests and 7 Python tests. The running Worker is unchanged.

Local validation: 59 focused bank app tests passed. All 1,097 non-UI app tests
passed, although Xcode's later simulator diagnostic collection was stopped
after the assertions finished (command exit 75). The ordinary gate passed 806
Core tests and a Debug build, and the Release bundle gate passed. The Worker
gate passed typecheck, 180 service tests and 7 Python tests; its secret scan
passed. UI automation was not rerun after this slice.

## Verdict

The private Worker and the iOS client already do the hard part correctly: bank rows stay provider evidence, the phone authenticates with a device key, and a failed pull leaves the ledger alone. The cost sits around that boundary.

A routine open of Banks & Sync re-downloads the full observation history, imports it on the main actor, and replaces the entire SwiftData document, which forces a full forecast rebuild. Home cash, Safe to Use, review coverage, and attention all wait on that same write. Meanwhile the Worker refetches 90 days from each bank four times a day and restamps every row it sees, so the history never becomes a small delta.

The highest-leverage work is to make "the banks are current" a small read, and to make a real bank round-trip write only the rows that changed. Ledger replication between devices is out of scope. Sync keeps adding evidence. It does not become a second ledger.

## How a sync actually reaches the app

```text
cron (one provider per invocation, 4×/day)
        or
phone  POST /v1/mobile/sync   (user present, PSU taken from the connection)
        │
        ▼
Enable Banking AIS  →  D1 observations, balances, pending, candidates
        │
        ▼
phone  GET /v1/mobile/snapshot?since=   (signed, paged)
        │
        ▼
FinanceStore.readAllEvidence
        │  one import after the last page
        ▼
ExternalEvidenceReview.importBatch
        │
        ▼
StoredDocumentGraph.replace + ForecastEngine recalculate
        │
        ├─ CurrentHoldings overlay  → Home cash, Safe to Use, forecast start
        ├─ authoritative live coverage → Review / Insights (intersection)
        ├─ authoritative pending    → attention, freshness clock
        └─ new unreviewed rows      → To Review, then Trusted Automation
```

Two different operations share one button today.

| Operation | What it does | Who starts it |
| --- | --- | --- |
| Bank round-trip | Worker calls Enable Banking for one provider | Cron, or `POST /v1/mobile/sync` |
| Evidence pull | Phone reads D1 and imports | `refreshFromService`, and the second half of Sync Now |

Cron already keeps D1 warm. The phone does not subscribe to that. `BankSyncView` calls `refreshFromService` only when the in-memory remote directory is empty. That directory is not stored, so every cold launch that opens Banks & Sync pulls the whole history. Opening Home, Activity, Plan, or Review pulls nothing. Sync Now always does both operations, then discards the per-provider outcomes (`LiveBankSyncProvider.runRemoteSync` ignores the `runs` array).

`FinanceStore` is `@MainActor`. The network await yields. The import, the graph replace, and `recalculate()` do not.

## What is already right

Keep these. Several of them are repairs of production defects, and an optimization that undoes one of them is a regression.

- The Worker stops at normalized observations. No category, no spending flag, no FinanceCore transaction. A regression test locks the absence.
- Account identity is the singular `identification_hash`, HMAC'd with a length-prefixed domain string. Shared Revolut hashes are indexed and excluded. Accounts with no singular hash are skipped and counted.
- Booked identity is provider + account + `entry_reference`. Revolut exchange legs that share a reference stay distinct. Pending rows have no durable id and are never fingerprinted onto a later booked row.
- `syncedFrom` / `syncedThrough` record the window the Worker requested after a successful fetch, including quiet days. Review coverage reads that window. It does not infer coverage from transaction dates.
- Pending membership is the latest **successful** run per provider, including a run that captured zero pending rows.
- Device auth verifies the signature before claiming the nonce. Pairing codes are single-use. The signing key stays on device. Secure Enclave keys are created with `.privateKeyUsage` only, so a later background pull does not demand Face ID.
- PSU IP and user agent are taken from the connection Cloudflare saw. The phone cannot assert them. Cron passes `null`.
- One provider per Worker invocation. A combined three-provider request exceeded the invocation budget in production (about 38 seconds). Crons are staggered by 10 minutes.
- Snapshot paging is a keyset on `(last_observed_at, id)`. A timestamp-only cursor skips the rest of a same-timestamp bucket; that bug is fixed.
- The phone imports once, after the last page. A failed later page leaves the document unchanged.
- Re-import upserts an observation and does not undo a human resolution. A provider status change on an already resolved row becomes a warning, not a silent unlink.
- Amounts stay decimal strings until `Money`. Direction follows `creditDebitIndicator`.
- Unmapped accounts produce no Inbox work. Export stays a financial document: remote directory and pairing stay outside it.
- Preferred holdings types are pinned from measured provider behavior: BNP `CLBD`, PayPal `XPCD`, Revolut `ITAV`. Unlike balance types are not collapsed.

## Findings

Ordered by how much they cost the whole app, not by which repository they live in.

### 1. The phone replays all history on every pull

`readAllEvidence` starts `since` at nil and walks `nextSince` until the end, capped at 20 pages. The client never sends `limit`, so the server default of 200 applies. The hard ceiling is 4,000 booked observations. Past that, the walk throws `malformedResponse` and imports nothing: no new rows, no new balances, no freshness update.

The service was tuned against an archive of 1,599 booked rows, which is about 8 pages today. The ceiling is a few years of personal card spend away, and the failure mode looks like a broken service.

Every page repeats the full connection list, account directory, latest balances, current pending set, and up to 500 candidates. The client concatenates balances and candidates from every page. Import is idempotent on those ids, so the result is correct and the work is multiplied by the page count. Observations for unmapped accounts are downloaded and then dropped.

There is no stored high-water mark. `nextSince` exists only inside one walk, and the last page returns `nextSince: null`, so the client is not even given a cursor it could save.

### 2. Every successful import rewrites the whole app

`importBankEvidence` calls `persistCurrentDocument`, which is `StoredDocumentGraph.replace` of the full document plus app metadata. Then `recalculate()` rebuilds the forecast and the published snapshot.

That one write is what moves:

- Home cash and Safe to Use, because `CurrentHoldings` overlays the provider's canonical balance on the stored anchor. The anchor is not advanced. A stale pull means a stale cash figure. A bad balance-type collapse would move cash without a transaction.
- Review and Insights. Live coverage is the **intersection** of every relevant same-currency account. One account with no authoritative window makes the global live claim unknown.
- Attention and the Home freshness caption. The clock is provider `lastSuccessfulSyncAt` stored on the authoritative pending snapshot, not the time the HTTP call finished.
- To Review, for rows that are new or newly eligible.

`importBatch` finds each existing observation with `firstIndex`. A full replay is quadratic in the size of the evidence already stored, on the main actor, before the graph replace starts.

Trusted Automation then applies each newly eligible observation as its own economic unit: one more full replace and one more recalculate per applied row. That isolation is worth keeping for failures. The happy path does not need N replaces.

A pull that confirms "nothing new" still pays this cost, because the import path has no equality short-circuit. And because app metadata lives inside the same graph replace, there is no small write that means "the bank time moved, the ledger did not."

### 3. The Worker makes deltas impossible by restamping unchanged rows

`upsertBookedObservation` always sets `last_observed_at` and `last_sync_run_id` on conflict. Every cron refetches `today - SYNC_LOOKBACK_DAYS` (90) for every account and upserts every returned row. After each successful bank sync, the entire 90-day window shares one new timestamp.

Consequences:

- A stored cursor, added alone, would still re-download the whole lookback after every cron. It would at least stop re-downloading history older than 90 days. That is worth doing, and it is not sufficient.
- `bookedUpdated` counts restamps, not content changes. The log line cannot tell a quiet day from a busy one.
- D1 write amplification is two statements per row in the window (existence probe, then insert/update), issued one at a time. `env.DB.batch` is already used for pairing and not used here.

`insertBalanceSnapshot` inserts a new row on every run for every balance type. Nothing prunes `balance_snapshots`, `pending_snapshots`, or `sync_runs`. The snapshot's "latest balance" query is a full `GROUP BY` over that growing table. Pending reads stay correct because they join the latest successful run; the table still grows without bound. Four cycles a day across seven accounts and two balance types is on the order of 150 balance rows a day.

### 4. Sync Now is the slow path, and it reports success too early

`POST /v1/mobile/sync` dispatches each provider into its own invocation, which fixes the CPU-budget failure, then **awaits them one after another**. The phone's wall clock is still the sum. The client timeout is 180 seconds. The button copy is "Asking your banks for new activity…" for the whole of that, plus the history replay.

The HTTP response is 200 when the Worker itself answered, including when a provider outcome is `error`, `skipped_rate_limited`, or `skipped_reauth_required`. The app throws that array away and, if the following snapshot read succeeds, sets `bankSyncActivity` to `succeeded`. Home can still show `needsAttention` later, from `lastErrorCode` on the snapshot. The button the person just tapped has already said the sync worked.

User-present sync is still necessary. Cron must not invent PSU headers. Some fetches will only succeed while the phone is on the connection. The plan keeps Sync Now. It stops using it as the way to refresh a database the cron already filled.

### 5. Absence is not communicated

Booked rows are insert-or-update only. When a bank stops returning a row inside the window it was asked for, D1 and the phone keep the old observation. `reclassifyIfUnresolved` runs only for a row that arrives again. An unreviewed row the bank withdrew stays in To Review. A resolved row the bank withdrew never becomes the provider-status warning, because that warning requires the row to come back with `eligibleForEconomicActual == false`.

Cross-provider candidates have the same shape. `refreshCandidatesFor` upserts the current 120-day BNP/PayPal recompute and never retires a candidate that the rule no longer emits. The phone upserts by `candidate-<bank observation id>` and also never deletes. A link that was unique and is now ambiguous can remain unique on the device until that bank id is upserted again; a link that should disappear remains.

A tombstone protocol has a trap. The fetch window is 90 days. Treating "not in this response" as "gone" would withdraw every older booked row. Tombstones are valid only for rows whose booking date sat inside the window just fetched.

### 6. The 90-day refetch is a fixed cost, and it still misses late history

Every account, every cycle: session, account details, balances, then `fetchAllTransactions` with `strategy=default` from `today-90` through today, following continuation keys up to 200 pages. BNP is known to return empty pages that still carry a continuation key; the paginator handles that and must keep handling it.

Card presentment is why the window cannot shrink to "since yesterday." BNP remittance dates are parsed in a `-60..+5` day band around booking. A weekly full 90-day repair plus a shorter overlap on the other cycles is the shape that stays honest. A one-day delta is not.

Anything booked, corrected, or removed outside the 90-day request is invisible until a deeper repair (`strategy=longest` exists in the POC harness and is not what the Worker runs). Reauthorization identity is explicitly unproven: no real reauthorization has been observed. Consents created 2026-08-28 remain valid until 2027-02-24. The app can display "Reconnect required." It cannot start the bank's authorization. That flow is an operator call to `POST /v1/authorize`.

### 7. Candidate matching is correct and expensive, and one comparison breaks the amount rule

`buildCandidates` walks every PayPal-rail BNP debit against every wallet row in a widened window. Matching is conservative: one match is `unique`, two or more stay `ambiguous`, zero stays `unresolved`. The archive measurement under the shipped rule is about 77% unique, 16 ambiguous, 16 unresolved of 139 wallet-rail bank rows. Ambiguous rows are the review burden. Guessing the nearest date would manufacture a merchant.

`sameAmount` uses `Number.parseFloat`. The rest of the system refuses binary floats for money. Equal canonical strings survive. Distinct amounts that collapse in binary floating point would link. The comparison should be exact decimal minor units.

The snapshot returns at most 500 candidates, newest `computed_at` first. Restamping `computed_at` on every recompute means "newest" is "just recomputed," not "most recently matched." Under 500 this is invisible. Past 500, older links silently drop out of the pull while remaining on the phone.

### 8. Freshness, holdings, and review are coupled to the fat pull

`BankFreshness` is right about its inputs. It uses the stalest relevant provider's `lastSuccessfulSyncAt`, ignores the local HTTP completion time, and treats 48 hours as stale. Those inputs are only as new as the last **imported** snapshot. Cron can be healthy all day while Home still says the banks are stale, because nobody opened Banks & Sync.

The same import is what installs the balance overlay. A lightweight balance read would move Home cash without replaying observations. That read does not exist. `GET /v1/mobile/snapshot` is the only mobile read, and observations dominate it.

### 9. Smaller contract and safety nicks

- `SELECT *` on `booked_observations` is then mapped field-by-field, so extra columns are not sent to the phone. A later sensitive column would still be loaded into the Worker. The explicit column list is the same discipline the response mapping already uses.
- Contract version is 1, and the phone refuses any other version. New fields and new routes are safe. Changing the meaning of `since`, `pending`, or `syncedFrom` is not.
- The Python package at the root of `finance-bank-sync-poc` is the original provider harness. The running service is `service/`. Optimizations belong in the Worker and the app, not in a second client.
- `PROJECT_STATE.md` still describes an older `main` baseline. It is not a sync defect. It will mislead the next phase if left beside this plan.

## Invariants the plan is not allowed to weaken

- Evidence is not an economic transaction. Import creates no spending and no income.
- A human resolution survives a later sync. Withdrawing a booked row may remove it from the unreviewed queue or raise the existing provider-status warning. It does not delete a transaction.
- Pending rows gain no durable identity.
- Coverage is the requested window of a successful fetch. Quiet days stay covered. A missing window stays unknown. Global review coverage stays the intersection.
- Holdings keep the pinned balance type per provider. No FX. The stored anchor is not overwritten by a provider figure.
- Unmapped and inactive bindings receive no new work.
- Signature verification stays ahead of nonce claim. Cron stays PSU-free. The AIS allowlist stays payment-free. Opaque ids stay opaque. Redaction stays on provider free text.
- A pull is atomic. Page by page import is not an acceptable way to make the UI feel faster.
- An unknown closed-vocabulary value still fails loudly.
- Backup and export still omit pairing, the remote directory, and sync cursors.

## Plan

Six phases. Each one is independently shippable and leaves the phone able to sync if the other side has not shipped yet. Contract changes are additive on version 1.

### Phase 1 — Make a quiet pull cheap on the phone

Goal: opening the app, or returning to it, refreshes cash, freshness, pending, and coverage without a bank round-trip and without a full-history replay when D1 has not changed.

App, compatible with today's Worker:

1. Split the two operations in the UI and in `FinanceStore`. Foreground and the Banks screen call `refreshFromService`. Sync Now stays the user-present bank round-trip, used when a connection needs attention, when the pull says the Worker is stale, or when the person asks.
2. Send `limit=500` (the server maximum). The 20-page cap then means 10,000 rows, and a current archive fits in a handful of signed requests.
3. Keep observations from every page. Take connections, accounts, balances, pending authority, and candidates from the terminal page only.
4. Replace `firstIndex` walks in `importBatch` with dictionaries keyed by id.
5. Add an opaque `highWater` on every snapshot page, including the last and including an empty page. Empty pages echo the caller's cursor. The phone stores that cursor in app-local metadata, outside `FinanceDocument`, and sends it as `since` on the next pull. Advance it only after the single import commits.
6. Until Phase 2 lands, accept that a post-cron pull still re-reads the restamped 90-day window. History older than the last restamp stays put. That removes the all-time replay and the 4,000-row cliff for normal use.

Still in this phase, because of finding 2: a cursor-only pull that updates `lastSuccessfulSyncAt` must not require `StoredDocumentGraph.replace` when observations, balances, pending membership, candidates, and coverage windows are unchanged. Persist the provider clock in a sidecar the freshness evaluator already knows how to read (`providerSuccessfulSyncAt` / authoritative pending `authoritativeAt`). Home can say "Last sync 10 min ago" after a quiet pull. The ledger graph stays on disk untouched.

Exit:

- A second pull with no intervening bank sync transfers one small snapshot and writes no document rows.
- A pull that stops at page 20 is still a hard failure with no partial import.
- Existing snapshot tests, `BankSyncTests`, holdings tests, and coverage tests pass. The service snapshot-paging tests pass with the new field ignored by old clients.

### Phase 2 — Stop writing rows that did not change

Goal: a quiet cron is a few reads and a success stamp. `last_observed_at` moves when the normalized observation changes.

Worker:

1. Compare the normalized booked payload to the stored row. On a match, leave `last_observed_at` and the content columns alone. Bump a run counter for "unchanged" instead of `bookedUpdated`.
2. Insert a balance snapshot only when type, amount, currency, or reference date changed for that account. Keep the latest-balance query correct for unchanged rows.
3. Batch the D1 writes for the full provider run in one transaction. Keep the
   existence decision correct under the batch.
4. Prune pending rows that are not the latest successful run per provider, and prune balance rows that are not the latest per `(account, type)` once a successor exists. Keep `sync_runs` long enough for the pending query and for diagnosis (a bounded tail, not an unbounded log). Do this after the reads that depend on the old rows, in the same success path.
5. Select an explicit observation column list in the mobile snapshot.

The phone's Phase 1 cursor then re-downloads a quiet cycle as an empty observation page plus the directory. That is the steady state this audit is aiming at.

Exit:

- A fixture sync run twice reports `bookedNew` on the first run and `unchanged` on the second, with identical `last_observed_at`.
- Pending authority tests, including the empty-successful-run case, still pass.
- A content change (status, amount, dates, merchant text, eligibility) still advances `last_observed_at` and reaches a phone whose cursor was caught up.

### Phase 3 — Shrink the bank round-trip

Goal: cut ASPSP traffic and Worker time without missing late presentment.

Worker:

1. Record per account the booking horizon last fetched successfully.
2. On three of the four daily cycles, request `date_from = min(horizon, today) - overlap`. Start the overlap at 14 days, which covers the `+5` derived-date band with margin and is still far smaller than 90. Keep one cycle on the full 90-day window as the repair.
3. Leave pagination termination as "no continuation key," including empty BNP pages.
4. Do not run `strategy=longest` on a cron tick. Run it as an explicit operator repair after connect and after reauthorization, in its own invocation, with the same identity rules.
5. Add `POST /v1/mobile/sync/jobs` so the phone is not held for the sum of three providers, while the existing signed route keeps serving older app builds. Return a durable device-owned job immediately, process one provider per Queue invocation, and poll a small status read before the Phase 1 pull. Queue consumer concurrency starts at one until measured bank latency and rate limits justify a change. Cloudflare's HTTP `waitUntil` window is too short for a bank fetch.
6. Surface each provider outcome on that status read. Sync Now shows success only when every mapped provider succeeded or was skipped because nothing was due. `skipped_rate_limited` and `error` stay visible and do not advance that provider's freshness.

Exit:

- A quiet overlapped cycle fetches a short window and writes nothing in D1 beyond the run row.
- The daily 02:00 UTC repair still widens `synced_through`; the existing
  `MIN`/`MAX` coverage update does not shrink the recorded window.
- Rate-limit handling stays "record backoff and stop." No retry loop.

### Phase 4 — Tell the truth about withdrawals, and make the import proportional

Goal: the Inbox and the candidate list match the latest fetch window, and a real change does not replace the whole document on the main actor.

1. During a fetch, collect booked ids the provider returned whose booking date lies inside `[date_from, date_to]`. Ids stored for that account in that date range and absent from the response become withdrawal markers on the snapshot. Additive field, version 1. Rows outside the window are not markers.
2. On the phone: an unreviewed withdrawn observation leaves the queue (resolution moves to economically ineligible, or the existing equivalent that `reclassifyIfUnresolved` already uses when a row comes back ineligible). A resolved withdrawn observation stays linked and appears in `providerStatusWarnings`. No transaction is deleted.
3. Candidates that the recompute no longer emits are marked withdrawn the same way, scoped to the recompute window. The phone drops or demotes them. A unique candidate whose wallet id disappeared is `unresolved`, which the mapper already does when the wallet row is absent.
4. `sameAmount` compares exact decimal strings at the currency scale. Add an index by amount and currency so the matcher is not a full cross product. Keep the unique / ambiguous / unresolved rule. Do not chase a higher unique rate by tightening dates.
5. Apply Trusted Automation in memory across the newly eligible set, then one `replace` and one `recalculate` for the successes. A failure still isolates that observation: drop it from the success set, record it on the retry list, and persist the successes. The current per-row rollback semantics stay; the N intermediate disk replaces go.
6. Only after the delta path is proven: teach `StoredDocumentGraph` to upsert evidence rows and app metadata without deleting and recreating the rest of the graph. This is the persistence change with the most blast radius. It waits until Phases 1–3 have removed the need to touch unchanged rows at all.

Exit:

- A fixture that omits one previously booked in-window row withdraws it once, and a second pull is a no-op.
- A row older than the fetch window is still present.
- A linked transaction whose evidence was withdrawn still exists, and the warning list names the observation.
- One automatic rule application writes the document once.

### Phase 5 — Let the rest of the app stay current without Banks & Sync

Goal: Home, Review, and attention follow the Worker on a normal day.

1. On foreground, when the device is paired, run the Phase 1 pull. Do not call `POST /v1/mobile/sync` from foreground or from a background task.
2. The key policy already allows a background refresh without Face ID. Add a background pull that only reads snapshot/status. If the system will not wake the app, a push that carries no financial payload and means "pull" is the alternative. The push body is a generation counter. Pairing and revocation still own whether the device may pull.
3. Reauthorization, before the 2027-02-24 consent deadline and ideally while the current sessions still work: perform one real reauthorization per provider, record whether `identification_hash` survived, and write the result into `service/docs/data-model.md`. If it did not, the fallback path is what the synthetic tests describe, and it needs a production observation before it is trusted.
4. Give "Reconnect required" an in-app continuation that opens the bank's existing authorization URL from a device-signed request. The admin token stays off the phone. The operator-only curl can remain as the recovery tool.
5. Map provider outcome codes to the sentences the app already owns. A rate limit says when to retry. An expired consent says reconnect. A malformed snapshot says the service was unreadable and that nothing local changed.

Exit:

- A day when cron finds nothing new: Home freshness moves, holdings stay put, review coverage stays put, and no document replace runs.
- A day when one provider needs reauthorization: Home shows attention, the other providers still refresh, and the reconnect path can be completed on the phone.
- The reauthorization note in the data-model doc is either "hash survived" or a specific fallback, based on a real session change.

### Phase 6 — Measure, then stop

Add counters the logs can already carry without payloads: provider, trigger, pages, booked new, unchanged, withdrawn, balances written, duration, rate-limit skips. No amounts, no merchant text, no ids that are not already opaque.

Watch for a month of normal use:

- Quiet pull payload under one snapshot page.
- Quiet cron duration dominated by the short overlap, not by the 90-day repair.
- D1 row counts for balances and pending flat across a week with no content changes.
- To Review growth equal to genuinely new eligible observations.
- Home freshness inside the cron period without opening Banks & Sync.

Then leave the 90-day weekly repair, the pending snapshot rule, and the candidate ambiguity rule alone. Further shrinking the overlap or auto-resolving ambiguous PayPal links is how this system would start inventing certainty.

## Suggested order of work

| Order | Phase | Mostly | Why this slot |
| --- | --- | --- | --- |
| 1 | Phase 1 | App, plus one additive snapshot field | Removes the stall and the 4,000-row cliff with today's banks |
| 2 | Phase 2 | Worker | Makes the Phase 1 cursor a true delta |
| 3 | Phase 3 | Worker | Cuts bank load once deltas are trustworthy |
| 4 | Phase 4 | Both | Withdrawals and one-write automation, after deltas exist to scope them |
| 5 | Phase 5 | App, then one supervised reauthorization | Makes Home and Review follow the service; clears the consent deadline |
| 6 | Phase 6 | Observation only | Decides whether anything further is earned |

Phases 1 and 2 are the ones that make the whole app feel better. Phases 3 and 4 make that improvement honest as history grows. Phase 5 is the product gap: the service can be healthy while every screen the person actually uses is looking at yesterday's import.

## What this plan deliberately does not do

- Sync the ledger, the budget, or checkpoints between devices.
- Turn cron into a user-present call by fabricating PSU headers.
- Import a page before the walk finishes.
- Infer coverage from the dates of imported rows.
- Auto-apply Trusted Automation to the existing queue, or auto-link ambiguous PayPal candidates.
- Replace the pinned balance types with a single "current balance."
- Fold the Python POC harness and the Worker into one process.

## Provisional pending evidence archive (2026-09-25)

The app now keeps superseded, unreferenced provisional pending observations in
compressed SwiftData archive batches. Current authoritative pending rows remain
in the live document. Full interchange and backup exports reassemble both parts
and validate the result, so an authoritative empty snapshot still preserves its
older evidence. A document replacement clears the old archive in the same save.

The live document and its startup/refresh cost no longer grow with each stale
pending snapshot. Total stored history still grows because every observation is
preserved; that is the chosen retention policy. A later storage policy can
export and prune old batches only with a separate product decision.

## Validation when a phase is implemented

App phases use `Scripts/test-core` and `Scripts/test-app`. Anything that changes the document graph or holdings also owes the budget repository's `Scripts/agent-validate-export` when FinanceCore behavior changes. Phase 1–4 as written should not need a FinanceCore semantic change until the `importBatch` index and the withdrawal resolution live in FinanceCore; those two edits are app-owned only if the withdrawal state can be represented with the existing resolution enum. If it cannot, that part is a FinanceCore change and gets the export validation.

Service phases use the Worker vitest suite, especially snapshot paging, pending snapshot selection, sync, candidates, and the schedule test that every provider has exactly one cron. Deploy, remote migration, and `wrangler tail` stay operator steps, not phase validation.
