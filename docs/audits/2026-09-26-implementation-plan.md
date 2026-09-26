# Audit remediation and product plan

This plan implements the September 26 audit against app `02bb7d8` and service `6df04b0`. Work happens in isolated `fix/audit-hardening` worktrees; the original checkout and private device store are preserved. Each phase earns behavior-level regression tests. Publishing uses separate app/service PRs with required green checks. Backend deployment and production migrations are separate from implementation and testing.

## Design decisions

- Preserve ledger/evidence separation, existing identities, civil dates, exact minor units, and explicit human financial decisions.
- Keep portable FinanceDocument interoperability. Introduce an app backup envelope alongside it to preserve application metadata; continue reading legacy backups. Restore remains empty-store-only and atomic.
- Never invent currency conversions. Product totals either retain complete currency identity or explicitly state that they are EUR subtotals.
- Fail safely on malformed external input. Validate before calculations, writes, or interpretation; preserve existing on-disk data if it is unreadable.
- Treat candidate membership as an authoritative scoped snapshot only after a complete read. Preserve observations and user economic conclusions independently.
- Make privacy controls transparent and optional where appropriate. Do not make device pairing credentials portable.

## Phase 1 — Financial correctness and recovery

1. **F09/F18:** enforce exponent identity in Amount arithmetic/comparison; correct proportional allocation using largest exact remainder and stable index tie breaks. Test unequal/negative ratios and conservation.
2. **F02/F08:** derive set-aside, debt and instalment totals per currency identity. Keep existing EUR summary properties for compatibility, show foreign totals explicitly, and derive debt outstanding consistently with paid schedule items. Test imported USD and KWD reservations and partially repaid debts.
3. **F01:** versioned app backup envelope with encoded FinanceDocument, transaction classifications/labels and income-source activation. Legacy document imports stay supported. Automation restarts disabled, device transport cursors/keys are excluded, and archive/checkpoint exclusions remain explicit until a separately versioned full-store recovery format is implemented. Validate references/duplicates before staging and persist metadata with the same domain write. Test source → export → fresh restore → budget/label/activation outcomes, not just byte equality.
4. **F04/F05:** shared operational checks for account-leg currency identity, representable aggregates and schedule consistency. Bound file sizes before decoding. Use regression fixtures to distinguish incompatible documents from missing data. Run the downstream budget export gate for changed Core accounting.

Acceptance: old readable backups still restore; new backups preserve classifications; foreign planning opens without traps; hostile amounts and inconsistent legs refuse before persistence; failures leave the existing graph intact.

## Phase 2 — External input and service privacy

1. **F03:** throwing/failable currency validation at every network money conversion, including direction normalization before Int64-min negation. Reject malformed mapped evidence atomically.
2. **F06:** case-insensitive IBAN candidate detection with bounded grouping separators, checksum validation of normalized spans, and redaction on every stored narrative path. Test punctuation, lowercase, grouping, multiple candidates and false positives.
3. **F10/F11:** add source-scoped pairing throttling before the global ceiling, retain single-use high-entropy codes, bound request bodies, sanitize runtime log fields and all product persistence errors. No raw exceptions or supplied route content in logs.

Acceptance: malformed provider input becomes a sanitized refusal; common IBAN forms do not reach normalized output; one abusive source cannot consume the owner's ordinary pairing budget; error tests cannot echo synthetic private markers.

## Phase 3 — Sync and identity reliability

1. **F07:** reconcile complete mapped candidate snapshots at the serialized import boundary, with identity/binding/read-generation protection; retain delta-feed semantics for test/offline providers.
2. **F14:** dedicated ephemeral URLSession and explicit redirect refusal; test secure initial URLs and redirected requests.
3. **F15:** capture identity before suspension, check it after every await, own one polling task, impose a local deadline, cancel safely, and recover queue provider claims with leases.
4. **F16:** update Keychain values without delete-before-add; recover partial identity creation and fail explicitly if secure random generation fails.
5. **F17:** bounded operational retention with explicit separation from financial evidence. Queue retry/timeout cleanup must not erase observations or ledger decisions. Withdrawal markers require a provider-authoritative withdrawal statement; absence alone must never become deletion.

Acceptance: old reads/jobs cannot publish into a changed pairing; duplicate resumes do not duplicate polling; terminated queue deliveries can recover; candidate deletion reaches the app; credentials remain hardware/device bound.

## Phase 4 — Privacy and maintainability

1. **F12/F13:** inactive/background privacy cover; an encrypted-backup and optional biometric-lock design must include recovery and accessibility behavior before release. Verify effective SQLite/WAL/SHM protection on a read-only device canary rather than assuming the store is unprotected.
2. Resolve actionable concurrency warnings; update the actual persistence ownership map. Avoid a large simultaneous FinanceStore rewrite while financial fixes are landing.
3. Measure decoding, graph saves and recalculation on synthetic 1k/10k/50k observations. Move measured pure bottlenecks off the main actor with immutable snapshots, bounded input and generation checks.
4. Establish old-store migration fixtures and explicit release schema lineage before adding/removing persisted entities. Add a small stable UI smoke gate for recovery, foreign Plan, categorization, and error states. Preserve the existing full optional UI gate.

Acceptance: inactive views hide amounts, release resources remain private, baseline stores preserve economic records, warnings and architectural documentation agree with the code. Runtime/device-dependent claims need actual verification.

## Product roadmap after the remediation gate

1. **Correction:** identity-preserving metadata correction first; economic/account/date correction requires an append-only audit and revalidation of evidence, settlements and checkpoint projections. No delete-and-recreate shortcut.
2. **Guided reconciliation:** compare dated bank and ledger values, show pending/booked/available distinctions and candidate explanations, require explicit confirmation for each actual correction.
3. **Full encrypted recovery:** include historical archive and checkpoint lineage in a versioned app-state package, validate all subgraphs before any write, use one atomic restore context, exclude device secrets, and test a real fresh-container rehearsal. This extends Phase 1's portable metadata backup.
4. **Explicit FX settlement**, then recurring-payment management and forecast what-if tools. Each introduces its own financial model contract and focused UX acceptance.

These product extensions are design/release milestones rather than permission to invent new ledger semantics during defect repair. Prioritize correction and reconciliation over broader automation until recovery and sync boundaries pass.

## Delivery verification

- Core, app/integration, focused synthetic UI, Release privacy gate, repository safety, service typecheck/tests, Python tests, backend secret scan, downstream budget export validation for Core changes.
- Review the entire diff, record phase results and unresolved risks here and in PROJECT_STATE, and publish app/service feature PRs. Merge only on green required checks; no administrative bypass.
- No bank service deploy, remote database migration, phone reset/uninstall, financial mutation or Sync Now is part of this implementation run.

## Implementation status

The implemented slice covers F01–F11, F14–F16 and F18, plus password-protected
operational backups and optional device authentication/background privacy cover
for F12/F13. F04 checks include leg currency/exponent, linked/source/instalment
references, purchase references, duplicate operational identities and schedule
currency. F05 uses a conservative aggregate acceptance bound rather than
changing every pure Core arithmetic operator. Invalid old stores remain intact
and read-only. These changes do not redesign existing persisted entities.

F17 is partially addressed: scheduled nonce/pairing-attempt/code cleanup and
90-day retention of completed sync jobs, with interrupted claim recovery and
four queue retries. Balance snapshots and sync-run evidence still have no
bounded retention policy; booked-withdrawal statements need a provider protocol
and must not be inferred from absent activity. Full archive/checkpoint recovery,
physical SQLite/WAL protection verification, schema lineage fixtures, and measured
1k/10k/50k performance work remain follow-up milestones. They are not completed
by an encrypted operational backup or synthetic integration tests.

The foreground task now belongs to SwiftUI's scene lifecycle, cancels on phase
changes, and cannot publish a cancelled evidence walk. Polling keeps one active
job, captures identity before suspension, checks identity after status responses,
and has a local deadline. Keychain updates retain the existing record on failure.

The full UI gate also identified duplicate inherited Activity section identifiers;
children now have explicit identities inside a containing accessibility group.
The recovery smoke fixture is synthetic and memory-only, guarded out of Release.

### Validation record

- Core: 816 executed, two existing skips, no failures.
- App integration: 1,126 tests passed before the final lifecycle/UI adjustments.
- Service: 207 tests, zero TypeScript errors; Python POC: seven tests passed.
- Budget: original repository gate has two stale rejection assertions for schema
  2.0.0/1.0.0 and an obsolete wrapper-error expectation. Its actual private export
  validates. A temporary harness copy using this worktree's Core, unsupported
  99.0.0/0.9.0 and the current Interchange error contract passes 14/14 tests;
  the private export also validates against the updated Core. No budget source
  or financial output was modified.
- Final app integration: 1,126 tests passed with the final currency validation
  and scene lifecycle code. The new encrypted-backup controls UI passes after
  making the tap address the switch itself; Activity identifier and foreign Plan
  UI cases pass. The full initial UI sweep ran 62 cases: 59 passed and three failed. Two
  were the corrected recovery/Activity cases. The third selected the first bank
  movement but expected a ledger detail; it now targets a specific synthetic
  ledger identity. Xcode's diagnostic collection stalled after the results, so
  that collector was interrupted after test execution had finished. The focused
  final recovery, foreign Plan, Activity and visual cases are recorded below. Final compile has no warnings.
- Release bundle gate: passed. App repository safety and service secret scans:
  passed, including newly added files. No production service deployment or
  physical-device install. Device doctor/inspection were read-only; this does
  not establish effective file-protection attributes.

Final focused simulator UI: 11 tests passed, including all recovery cases,
foreign Plan, Activity identifier uniqueness and the full transaction/reserve
visual flow. No compiler warnings in the final app compile.

The final identity regression passes: revocation releases the old polling slot,
without allowing its completion to clear a newer job. Pairing resets the prior
job markers. Final app integration count is **1,127 passed**. App PR:
https://github.com/AnasAEA/finance-app/pull/3. The service changes remain staged
in the separate service worktree under its commit-on-request rule; no deploy.

## Follow-up: full encrypted recovery

The next milestone is specified in [the full recovery plan](2026-09-26-full-recovery-plan.md).
It extends the operational backup with archive projections, checkpoint lineage,
and saved coverage in one validated, atomic restore, while retaining legacy scope
and excluding device credentials. Its validation and release results are recorded
with that milestone rather than changing the historical implementation counts above.
