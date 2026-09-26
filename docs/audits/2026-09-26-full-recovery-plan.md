# Full encrypted recovery

This milestone extends the verified operational backup to recover the separate
historical archive and accepted checkpoint lineage. It changes no financial
interpretation and introduces no new SwiftData entities or schema migration.

## Recovery contract

- Keep portable FinanceDocument at the root. Add app metadata version 2 carrying
  full-recovery version 1, while continuing to read document-only and version 1
  app backups with their original scope.
- Snapshot explicit stored archive fields, source gaps, checkpoint dataset identity,
  canonical projection bytes, revision predecessors, and ordered acknowledgments.
  Restore these existing records; do not recreate verified periods or turn history
  into current ledger transactions.
- Preserve saved provider coverage and pending membership, classifications,
  source activation and last-used account choices. Exclude device keys, pairing,
  transport cursors and retry queues. Trusted Automation restarts off.
- Check a domain-separated SHA-256 digest over the full recovery section, then
  validate archive semantics and references, derived search/index values, money
  identity, checkpoint chain/digests/acknowledgments, and coverage bindings before
  staging. Validate checkpoint rows in an isolated in-memory container using the
  existing repository. Unknown future checkpoint formats remain opaque unsupported
  history; they do not acquire current-format interpretation.
- Restore into an empty destination only. Recheck at confirmation, then insert the
  ledger, archive and checkpoints before a single save. A failure rolls back all
  subgraphs, including rows inserted immediately before the failing save.
- Refuse unreadable source history. Read the produced package back and require a
  deterministic encoding fixed point. Refuse plaintext output above 32 MiB so
  base64 encryption fits the existing 64 MiB input limit.

## User experience

Export and restore show historical-transaction and verified-month-revision counts.
Exclusions describe the selected format: old backups stay operational-only; new
backups exclude pairing and restart automation off. Password protection remains
on by default. The displayed plaintext size is labeled before encryption. Failed
new restore attempts clear older staged data so it cannot be confirmed accidentally.

## Verification and delivery

1. Synthetic encrypted source-to-fresh-container round trip, including archive,
   source gaps, two checkpoint revisions and their acknowledgments.
2. Close and reopen a temporary SQLite container and reproduce the backup exactly.
3. Malformed archive, orphan rows, bad monetary identity, invalid dates, broken
   checkpoint lineage, modified projections/acknowledgments and unknown package
   versions refuse without destination writes.
4. Inject failure after inserting every subgraph and prove rollback; preserve an
   existing archive if it appears after staging. Test saved coverage, pending
   membership, expected labels, legacy imports, credential exclusion and failed
   password staging.
5. Run Core, all app/integration tests, focused recovery UI, repository safety and
   the Release bundle gate. Review and publish a feature PR; merge only after all
   required checks pass. Use a WAL-aware read-only iPhone export-preview canary;
   do not save private backups or run phone Sync Now.

The original archive source file remains useful for independent provenance: the
backup restores the stored query projection and its original source hash, not a
claim that it recreates the original import-file bytes. A backup still needs an
operational account; archive-only export is not part of this milestone. Performance
at 1k/10k/50k rows and physical file-protection attributes remain follow-up work.

## Local validation results

- All 1,142 app and integration tests passed, including encrypted recovery,
  SQLite reopen, malformed-data refusal and complete rollback rehearsals.
- All nine first-run recovery UI tests passed.
- FinanceCore: 816 tests executed, two existing skips, zero failures.
- Repository safety passed for 351 tracked paths. Simulator Release and signed
  iPhone Release bundle gates passed with no private fixtures or credentials.

Post-merge automated review identified two compatibility cases. Pending-provider
keys now must be canonical before they can reach a keyed dictionary; case aliases
are refused before staging. Future checkpoint formats retain opaque payloads and
digests, with supported-format checks owned by the existing repository. Recovery
screens explicitly exclude endpoint settings, transport cursors and retry queues.
Regression coverage exercises both the provider-alias refusal and an exact
future-format export/restore/re-export. All 1,144 app/integration tests and
the 816-test Core gate passed after these corrections (two existing Core skips).
