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

Amount, date, account, ownership and economic-kind corrections need a separate
supersession design: explicit evidence/settlement revalidation, cross-month
effects and a user-confirmed preview. Guided reconciliation follows that work;
it must distinguish dated booked, available and pending bank balances and must
never manufacture income or spending from unexplained drift. Historical archive
rows remain read-only in this first release.
