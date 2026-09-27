# Transaction correction

The first release corrects app-owned merchant labels and spending categories on
operational transactions. It preserves the complete FinanceCore transaction,
including its identity, provenance, legs, date, lifecycle and relationships.
Imported bank text remains evidence, alongside the user's corrected label.

## Delivery sequence

1. Add a facade draft carrying the metadata and revision the editor actually saw.
   Refuse stale forms, unreadable/read-only stores, unsupported categories,
   overlong labels and edits that change nothing.
2. Append a dated before/after correction and update just the transaction's app
   metadata in one context save. Retain stored row identities. Correction rows
   are independent of ordinary graph replacement; corrected transactions cannot
   be deleted and leave their history orphaned.
3. Recompute the existing projections after success. Category changes feed the
   same budget/review/checkpoint categorization source. Accepted checkpoint
   revisions are never rewritten; comparison exposes changed financial meaning.
4. Offer correction from transaction details, show the current saved values,
   explain the unchanged bank evidence, and show the correction history. Keep
   fields and the sheet open on refusal.
5. Include correction history in full encrypted recovery. Backups containing it
   require app envelope version 3 so older app readers refuse rather than lose
   history. Legacy v1/v2 backups remain readable. Validate chain continuity and
   its final metadata before staging. Restore everything in the existing single
   save, with shared rollback.
6. Verify additive on-disk schema migration from the immediately preceding model
   set, disk reopen, backup round trips, failed saves, stale edits, linked records,
   budget/checkpoint recomputation and UI acceptance with synthetic data. Run
   Core, app and Release gates, then publish through green-check PRs.

## Follow-up scope

The financial release below adds previewed amount/date/account corrections for
plain user-confirmed expenses and income. Transfers, ownership, economic-kind,
source-evidence and relationship-bearing corrections need a further explicit
review flow. Guided reconciliation follows that work; it must distinguish dated
booked, available and pending bank balances and must never manufacture income or
spending from unexplained drift. Historical archive rows remain read-only.

## Financial correction release

A financial correction supersedes the earlier assertion about the same event,
not the event itself. FinanceCore's `reversed` lifecycle means an event never
happened; it must not be used for correction history. Keep the transaction and
leg IDs, record complete before/after FinanceCore snapshots with a reason, and
atomically update only the date, single account leg and document revision.

This release supports observed, pending or cleared, user-confirmed expenses and ordinary
income with one leg, no booking-date distinction, no ownership split and no
outgoing transaction/financing link. Bank-evidence links, payment matches,
incoming actual/expected links and recorded goal purchases block financial
correction. The save repeats those checks from persisted state. Imported facts,
transfers, pass-throughs, reconciled records and other economic kinds require a
later relationship-review flow; none is silently transformed or unlinked.

1. Capture the complete document revision in an editor draft. Offer only active
   accounts in the existing currency and exponent; preserve kind, source,
   lifecycle, precision, note and provenance. Refuse future/invalid dates,
   currency changes, nonpositive/out-of-range amounts (including headroom for
   balance and forecast arithmetic), no-op edits and missing
   correction reasons.
2. Preview before/after fields, affected months and derived ledger balances for
   both affected accounts. Missing balances stay unavailable. Explain that
   inclusive opening anchors and provider balances are not rewritten; accepted
   checkpoints retain their original evidence and comparison may change.
3. Explicit confirmation reconstructs and compares the preview, including its
   civil-day anchor. Refuse stale document revisions and dirty contexts before
   staging anything. A single narrow save retains row/leg IDs and app metadata,
   appends the audit, and advances the revision; failures roll back all of it.
4. Ordinary document writes validate and preserve the audit chain. Deleting a
   corrected transaction is refused. App recovery envelope v4 carries full
   financial snapshots; earlier readers refuse v4, and v1/v2/v3 remain readable.
   Validate sequential revisions, immutable fields, currency, reasons and final
   endpoints and the financial record format version before atomic recovery.
5. Validate cross-month and opening-anchor effects, budgets/checkpoints, stale
   contexts, newly added matches, injected save/recovery failures, additive disk
   migration, reopen and backup integrity. Use synthetic simulator UI tests for
   review/edit/cancel/refused-save/confirmed-save. Run app/Core/Release gates and
   the budget repository's downstream export validation; publish by green PR.
