# Finance app: deep engineering and product audit

Date: 2026-09-26. App baseline: `02bb7d8`. Companion bank service baseline: `6df04b0`.

The app has a substantial, carefully separated accounting domain, conservative bank-evidence handling, and unusually extensive regression coverage. Its most consequential weaknesses are at boundaries: recovery omits user classifications, some valid foreign-currency planning data can crash the Plan screen, malformed money can terminate the app before validation, and sync does not consistently retire derived suggestions. Fix those before expanding automatic interpretation.

## Scope and evidence

Reviewed the app's entry, persistence, import/export, planning summaries, money types, forecast composition, bank transport, signing identity, synchronization lifecycle, and relevant UI consumers and tests. Reviewed the companion service's mobile authentication, pairing, authorization callback, normalization/redaction, snapshot publication, queue jobs, and CI. This was a source audit with synthetic local verification, not a production penetration test or physical-device UX acceptance.

No real fixture, account data, bank payload, or credential was read or used for reproductions. No deployment, migration, financial action, commit, or push was performed. The service's pre-existing modified local state file was preserved.

Validation:

- Core: 812 tests executed, two existing skips, zero failures.
- App/integration: all 1,116 existing tests plus three initial synthetic probes passed: 1,119 tests in 88 suites. Swift Testing executed the tests; the XCTest wrapper's zero-test line is not the actual suite count.
- Follow-up audit probes: seven passed. These deliberately assert the observed defects, not desired behavior.
- Service: zero TypeScript errors, 199 Worker tests and seven Python tests passed.
- App repository safety: 335 tracked paths passed. Backend secret scan passed.
- Release fixture/bundle gate: passed; no private history, sample fixture, repository documentation, bank preview, provider identity, bank secret, or admin credential found in the Release bundle.
- Full UI suite, spoken VoiceOver, device file-protection attributes, live TLS redirect behavior, deployed edge controls, provider outage behavior, and database restore were not exercised.

Synthetic probe source and raw audit logs remain locally under `/tmp/finance-audit-*`; the temporary test source was removed from the app test target after verification. Passing suites do not invalidate the findings below: existing tests largely check domain/interchange fidelity rather than fidelity of the complete user experience.

## Findings, ordered by impact

### F01 — High: backups silently lose categories and merchant labels

**Confirmed by export → restore probe.** `StoredTransaction.appCategoryKey` and `appMerchant` live outside `FinanceDocument`. `loadForExport` reconstructs the domain document without those fields, and `confirmImport` installs an empty presentation dictionary. The byte-identical export test therefore proves fidelity only after this information has already been dropped.

Reproduction: add a synthetic expense categorized `food` with a merchant label; export; restore into an empty container. The transaction survives, but both stored classification fields are nil. Budget attribution and merchant matching depend on this metadata, so this is more than cosmetic loss. Income-source activation and other app preferences also sit outside the exported document; the importer initializes all restored income sources as active.

Sources: [stored transaction metadata](../../FinanceApp/Persistence/PersistedModels.swift#L373), [domain export](../../FinanceApp/Persistence/PersistedModels.swift#L2218), [restore metadata](../../FinanceApp/Persistence/FinanceStore.swift#L1205), [budget categories](../../FinanceApp/Persistence/DomainMapper.swift#L1676), [backup exclusions](../../FinanceApp/Surface/BackupExport.swift).

**Fix:** introduce a versioned app backup envelope containing the domain document plus durable app metadata. Keep the portable FinanceDocument export as a separate operation. Add a restoration test comparing budget attribution, merchant labels, inactive sources, and review behavior before and after recovery. Preserve the safe default that automation does not unexpectedly resume on a restored device. Explicitly account for archive/checkpoint exclusions; pairing keys should continue to be excluded.

### F02 — High: a valid foreign-currency reservation can crash Plan

**Accepted data path verified; crash follows directly from the arithmetic precondition.** The probe imported a valid USD sinking fund, and the resulting EUR snapshot retained the USD reservation. `PlanHubView` calls `PlanningTotals.setAside`, which starts with EUR zero and adds every fund and direct goal reservation. `Amount.+` traps when the codes differ, including when the foreign reservation is zero.

Sources: [Plan tile](../../FinanceApp/Features/Plan/PlanHubView.swift#L98), [unfiltered aggregation](../../FinanceApp/Surface/PlanningTotals.swift#L17), [foreign fund mapping](../../FinanceApp/Persistence/DomainMapper.swift#L1135), [Amount arithmetic](../../FinanceApp/Surface/Amount.swift#L79).

**Fix:** provide per-currency set-aside totals, or a clearly labeled EUR subtotal plus separate foreign totals. Add a UI acceptance case that actually opens Plan after importing foreign goals/funds; current multi-currency tests concentrate on obligations and forecasts.

### F03 — High: malformed bank money can terminate the app before refusal

**Confirmed source path; process-crashing payloads were not injected into the real app.** `MobileSnapshotMapper` uses the trapping `Currency(code:)` initializer on network strings in observation, balance, and candidate mapping. A lowercase, empty, or malformed code invokes `preconditionFailure`, which the surrounding `throws`/`catch` cannot catch. `signedMoney` can also negate a decoded `Int64.min` credit before the operational boundary rejects that value.

Sources: [network money mapping](../../FinanceApp/Persistence/BankSync/LiveBankSyncProvider.swift#L395), [balance mapping](../../FinanceApp/Persistence/BankSync/LiveBankSyncProvider.swift#L301), [Currency preconditions](../../Packages/FinanceCore/Sources/FinanceCore/Money/Currency.swift#L21), [Money negation](../../Packages/FinanceCore/Sources/FinanceCore/Money/Money.swift#L80).

**Fix:** use throwing currency validation on all external strings, reject unrepresentable operational magnitudes before applying direction, and test malformed codes/exponents and signed extrema in isolated crash-detection tests. A trusted HTTPS service can still emit malformed data after a regression; this is not proof that an arbitrary remote attacker can control responses.

### F04 — High: import integrity checks accept inconsistent account legs

**Confirmed by probe.** Both `DocumentImporter.semanticValidate` and `StoredDocumentGraph.validate` accepted a USD expense leg attached to the EUR bank account. `CurrentHoldings.derivedLedgerBalance` silently skips that leg's currency, leaving the anchor unchanged. The document is accepted but its movement does not appear in the account holdings calculation.

The import validator checks whether the account exists, but not whether every leg's complete currency identity matches the account. It also does not comprehensively establish the foreign-key integrity of transaction `linkedTransactionID`, income-source references, and installment references. Those need individual regression cases rather than an assumption that decoding provides relational validation.

Sources: [import leg checks](../../FinanceApp/Persistence/DocumentImporter.swift#L164), [write validation](../../FinanceApp/Persistence/PersistedModels.swift#L2517), [skipped foreign leg](../../Packages/FinanceCore/Sources/FinanceCore/Accounts/CurrentHoldings.swift#L64).

**Fix:** centralize a document-level integrity validator shared by preview, write, load, and export. Validate leg currency and exponent, relationship existence, identifier uniqueness, schedule currency, and lifecycle/factivity placement. Refuse inconsistent input before presenting a successful restore preview.

### F05 — High for hostile/extreme input: aggregate overflow remains reachable

**Source-confirmed risk; aggregate crash was not deliberately executed.** The operational guard rejects `Int64.min`, but accepts other Int64 values without establishing that subsequent totals are representable. `Money.+`, `Money.sum`, `MoneyBag.add`, current-balance overlays, and debt/instalment preview reductions use ordinary checked Swift addition. Two individually accepted values can overflow and trap; a throwing import method cannot catch an arithmetic trap.

Sources: [Money arithmetic](../../Packages/FinanceCore/Sources/FinanceCore/Money/Money.swift#L85), [MoneyBag aggregation](../../Packages/FinanceCore/Sources/FinanceCore/Money/MoneyBag.swift#L71), [import totals](../../FinanceApp/Persistence/DocumentImporter.swift#L264), [single-value guard](../../FinanceApp/Persistence/PersistedModels.swift#L2559).

**Fix:** define explicit operational amount/aggregate limits or introduce checked, throwing aggregation at external boundaries. Cover maximum positive values, minimum negative values, repeated large legs, and overflowing debt schedules. This is primarily availability hardening for malformed files, not an assertion that ordinary personal amounts are near the limit.

### F06 — High privacy impact: IBAN redaction misses common representations

**Confirmed with the repository's synthetic IBAN fixture.** The redactor removes a compact uppercase IBAN, but leaves the lowercase and space-separated representations intact. `isIban` uppercases input, yet the candidate regex is uppercase-only and allows no separators. Consequently, valid account numbers can survive normalization and reach stored text/mobile responses.

Redaction is also applied to joined remittance text, while counterparty names are stored via `emptyToNull` without the same redactor. That is a coverage gap, not evidence that current provider names contain account numbers.

Sources: [candidate regex](../../../finance-bank-sync-poc/service/src/normalize/redact.ts#L16), [normalization paths](../../../finance-bank-sync-poc/service/src/normalize/observation.ts#L87).

**Fix:** identify bounded case-insensitive candidates with common separators, normalize for checksum validation, and replace the entire original span. Apply the policy to every persisted narrative field. Add lowercase, grouped, multiple, punctuation-adjacent, and Unicode-separator tests while preserving non-IBAN references.

### F07 — Medium: withdrawn cross-provider suggestions remain on the device

**Retention confirmed by probe; production retirement path confirmed in source.** The service can delete candidate rows when refreshing provider evidence. Its mobile snapshot sends the current candidate collection, but the app imports it as upserts only. An empty collection does not remove previous candidates. The probe verified that a previously imported candidate survives a subsequent empty feed.

This can preserve obsolete duplicate warnings, matching suggestions, and automation blockers. No automatic financial mutation from this gap was demonstrated; human confirmation and duplicate safeguards still apply.

Sources: [server retirement](../../../finance-bank-sync-poc/service/src/sync/publication.ts#L242), [candidate upserts](../../Packages/FinanceCore/Sources/FinanceCore/ExternalEvidence/ExternalEvidenceReview.swift#L213), [suggestion consumers](../../FinanceApp/Persistence/DomainMapper.swift#L564).

**Fix:** distinguish authoritative current candidate membership from delta evidence. Reconcile candidates only after a complete, timestamped page walk and within the mapped scope, or transmit explicit retirement markers. Test disappearance, refresh failure, unmapped references, pagination, and out-of-order responses.

### F08 — Medium: restore preview relabels foreign debt as EUR

**Confirmed by probe.** A USD 100 unscheduled debt passed semantic validation and appeared as EUR 100 in the preview. Debt originals and remaining instalments are summed as bare minor units and wrapped in an EUR `Amount`. Different exponents make this even less meaningful. The stored currency is not changed; the review/confirmation screen is wrong.

The preview also calls the original debt principal “outstanding,” whereas the regular debt mapper subtracts paid schedule items. A partially repaid active debt can therefore disagree between restore preview and the subsequent debt screen.

Sources: [preview reductions and labels](../../FinanceApp/Persistence/DocumentImporter.swift#L264), [normal outstanding mapper](../../FinanceApp/Persistence/DomainMapper.swift#L1967).

**Fix:** derive remaining debt from one shared authority and retain per-currency totals throughout preview and confirmation. Test paid schedules and EUR/USD/JPY/KWD together.

### F09 — Medium: display arithmetic ignores currency exponent identity

**Confirmed by probe.** `Amount.requireSameCurrency` compares codes only. EUR/2 with 100 minor units plus EUR/4 with 100 minor units becomes EUR/2 with 200 minor units: 2.00 instead of the mathematically correct 1.01. Comparisons similarly compare raw units without matching precision. FinanceCore correctly treats code and exponent as distinct identities; the facade weakens that invariant.

Source: [Amount arithmetic/comparison](../../FinanceApp/Surface/Amount.swift#L79).

**Fix:** require code and exponent equality in arithmetic and comparisons. At product aggregation points, use a full currency-identity key. No implicit rescaling should occur merely because the code matches.

### F10 — Medium availability: public pairing attempts can block legitimate pairing

**Confirmed source behavior; no live attempts performed.** Pairing uses a single global budget of ten attempts per ten-minute window. Anyone who can reach the public pairing endpoint can spend that budget using invalid attempts, denying the owner a pairing opportunity for the remainder of each window. Strong code entropy prevents a practical guessing attack but does not prevent this availability attack.

Source: [global counter](../../../finance-bank-sync-poc/service/src/api/device.ts#L210).

**Fix:** retain a global emergency ceiling and add edge/per-source abuse controls with a suitable operator recovery path. Do not replace high-entropy, single-use codes with guessable codes. Deployed Cloudflare controls were not inspected, so existing edge mitigation may reduce exposure.

### F11 — Medium privacy/consistency: error sanitization is uneven

**Confirmed source paths; no sensitive error was triggered.** Import/export carefully sanitize errors, but many ordinary mutation handlers return `String(describing: error)` in user-visible persistence failures. Load failures do the same. SwiftData/runtime descriptions can expose paths, stored values, or internal details. Even `safeReason` treats mapping descriptions as safe, although their enum payloads include raw stored tokens and encoded values.

The backend logger caps strings but does not redact content. Authorization-start failures pass arbitrary exception messages as `errorDetail`, and route logging uses the supplied path rather than a fixed route template.

Sources: [entry error construction](../../FinanceApp/Persistence/FinanceStore.swift#L1499), [mapping descriptions](../../FinanceApp/Persistence/PersistedModels.swift#L40), [logger](../../../finance-bank-sync-poc/service/src/log.ts#L44), [callback exception detail](../../../finance-bank-sync-poc/service/src/callback.ts#L150).

**Fix:** use stable product error codes/messages and sanitized structural diagnostics everywhere. Logging fields need runtime allowlisting and content policy; truncation alone is not sanitization. Test deliberately private-shaped synthetic error messages across entry, management, reconciliation, callback, and recovery.

### F12 — Medium recovery/security: exported backups are readable plaintext

**Confirmed intentional behavior.** The export writes JSON, and the UI correctly discloses that it is readable text. This is a security tradeoff rather than a hidden implementation defect: anyone with access to the exported file can read the financial document. Archive and verified-month history are explicitly excluded, and there is no complete app-state recovery package.

Sources: [backup encoding](../../FinanceApp/Persistence/DocumentExporter.swift#L38), [export disclosure](../../FinanceApp/Features/DataExport/ExportBackupView.swift), [exclusions](../../FinanceApp/Surface/BackupExport.swift).

**Improvement:** add an encrypted complete-backup option with a versioned authenticated envelope, a deliberate recovery-key/password design, and an actual restore rehearsal. Keep readable interchange export available when the user explicitly needs it. Sensitive exported files deserve separate protection from sandboxed local storage; see [OWASP MASVS-STORAGE-1](https://mas.owasp.org/MASVS/controls/MASVS-STORAGE-1/).

### F13 — Medium hardening gap: visible financial data has no app lock or inactive cover

**Confirmed source absence in app lifecycle/UI.** `RootView` reacts to foregrounding by refreshing evidence, but there is no cover on inactive/background transitions, optional biometric access gate, or balance-hiding mode. Anyone using the unlocked phone can open the app, and the app does not actively obscure its financial view before system snapshots.

The local store also does not explicitly configure or verify file protection. This does **not** establish that it is unencrypted: iOS provides platform protection. The actual SQLite/WAL/SHM protection attributes need a read-only device inspection before selecting a stronger policy.

Sources: [lifecycle](../../FinanceApp/App/RootView.swift#L302), [store configuration](../../FinanceApp/App/FinanceApp.swift), [storage directory](../../FinanceApp/Persistence/PersistenceLocation.swift).

**Improvement:** an inactive cover, optional Face ID with a grace period, and tap-to-hide amounts. Verify effective protection of all store sidecars and exported temporary files. Apple recommends biometric technologies where appropriate and the strongest file protection compatible with app behavior: [privacy design guidance](https://developer.apple.com/design/human-interface-guidelines/privacy), [protecting user privacy](https://developer.apple.com/documentation/uikit/protecting-the-user-s-privacy).

### F14 — Medium conditional transport risk: redirects are not bound to the service origin

**Policy gap confirmed; redirect exploit not tested.** HTTPS is checked for the initial request, but the client uses `URLSession.shared` and no redirect delegate. It does not enforce that redirected requests stay on the configured HTTPS origin. Pairing carries a short-lived bearer code in its body; signed headers also deserve an explicit redirect policy. Signature replay protection limits their reuse, and ATS may prevent some downgrade scenarios.

Source: [transport](../../FinanceApp/Persistence/BankSync/BankSyncClient.swift#L132).

**Fix:** use a dedicated session, reject cross-origin redirects, decide whether to allow same-origin redirects at all, and test 301/302/307/308 behavior. Prefer ephemeral/no-cache behavior for financial responses. Apple exposes this policy through the [URLSession redirect delegate](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession%28_%3Atask%3Awillperformhttpredirection%3Anewrequest%3Acompletionhandler%3A%29). Certificate pinning is not automatically necessary.

### F15 — Medium reliability: async job and identity lifecycle has edge cases

**Source-confirmed risks, not reproduced races.** `resumeSyncIfNeeded` captures `bankIdentityGeneration` only after awaiting `currentSync`. An unpair/re-pair during that suspension can attach an old job to the new generation. `finishAsyncSync` allows another caller for the same active job, has no local polling deadline, and checks generation after sleep but not immediately after every awaited status response before publishing its runs.

The backend times jobs out after twenty minutes, which bounds normal polling against the current service. A worker terminated after claiming a provider leaves it `running`; a redelivered queue message cannot reclaim it because only `queued` rows are claimable, so recovery can devolve to timeout.

Sources: [foreground resume/polling](../../FinanceApp/Persistence/FinanceStore.swift#L3594), [queue claim](../../../finance-bank-sync-poc/service/src/sync/mobileJob.ts#L138).

**Fix:** capture identity before the first suspension, recheck after every awaited result, own one polling task per job, cancel on unpair/inactivity as intended, add a bounded local deadline, and use a recoverable provider-job lease. Test unpair during `currentSync`, duplicate resume, cancellation, terminated delivery, and a provider that never completes.

### F16 — Medium recovery reliability: Keychain writes delete before replacement

**Confirmed source behavior; failure injection not performed.** `DeviceIdentityStore.write` deletes the existing item before `SecItemAdd`. If the add fails, the original value is gone. The signing blob, hardware marker, and device id are separate writes, so a partial failure can leave an inconsistent identity. The random nonce generator also ignores `SecRandomCopyBytes` status; failure would yield a repeated zero nonce and authentication failures rather than a clean local refusal.

Sources: [Keychain replacement](../../FinanceApp/Persistence/BankSync/DeviceIdentity.swift#L175), [nonce creation](../../FinanceApp/Persistence/BankSync/BankSyncClient.swift#L108).

**Fix:** update existing items with `SecItemUpdate`, use a versioned single identity record where appropriate, and explicitly handle partial creation/clear failures. Check random-generation status. Preserve Secure Enclave and `ThisDeviceOnly` protection.

### F17 — Medium long-term reliability: retention and withdrawal policies are incomplete

**Confirmed source/model gap.** Unchanged balance writes and pending pruning are implemented, but historical balances, runs, completed jobs, pairing attempt windows, and consumed pairing codes do not have a comprehensive bounded retention policy. Booked observations have no general disappearance/tombstone protocol for rows a provider no longer returns. Missing evidence must not delete a user's economic transaction, but withdrawal still needs to be conveyed as evidence.

Sources: [publication](../../../finance-bank-sync-poc/service/src/sync/publication.ts), [limited pruning](../../../finance-bank-sync-poc/service/src/api/device.ts#L391), [job lifecycle](../../../finance-bank-sync-poc/service/src/sync/mobileJob.ts).

**Fix:** define retention by data class, keep required provenance, expire purely operational records, index cleanup queries, and test database backup/restore. Add explicit provider withdrawal markers with conservative review presentation. Measure table growth and snapshot sizes before choosing numeric limits.

### F18 — Low current product exposure: allocation is not largest-remainder allocation

**Confirmed by probe.** `Money(minorUnits: 1).allocated(ratios: [1, 2])` returns `[1, 0]`. Under largest remainder it should return `[0, 1]`: the second share has the larger fractional remainder. The implementation distributes leftover units by index rather than ranking remainders. Existing tests exercise equal ratios. No app production caller of this helper was established during the audit, so this is a latent domain bug rather than a demonstrated current screen error.

Source: [allocation](../../Packages/FinanceCore/Sources/FinanceCore/Money/Money.swift#L118).

**Fix:** sort exact remainders with stable original-index tie breaking, then assign residual minor units. Test unequal ratios, negative totals, conservation, and large products with checked arithmetic.

## Engineering and product inconsistencies

- **Backup tests cover the wrong completeness boundary.** Domain JSON equality does not prove restoration of classifications, verification history, imported archives, activation state, or user preferences. Add user-outcome recovery tests.
- **Persistence is much broader than its three-file description.** The project documentation describes three files as the whole boundary, while checkpoint, archive, transport, and multiple mapper/repository files now participate. Update the map and ownership rules. FinanceStore has 4,430 lines, DomainMapper 2,346, and PersistedModels 2,652; split focused services while preserving the existing facade and transaction boundaries.
- **Financial work is largely synchronous on the main actor.** Import decoding/preview, complete graph replacement, backup verification, and recalculation can block rendering as history grows. This was not benchmarked. Measure 1k/10k/50k synthetic observations and slow-save scenarios, then move pure decoding/computation off the UI actor with immutable snapshots and generation checks.
- **Migration discipline should become explicit before distribution.** A historical pre-alpha reset remains documented as historical; do not repeat it for real data. The current app does not establish an explicit `VersionedSchema`/`SchemaMigrationPlan` release lineage. Add old-store fixtures and preservation checks for SQLite plus WAL, recovery after failed migration, and app backup upgrade paths.
- **Swift 5 mode hides future concurrency errors.** The fresh app build reports actor-isolated default-argument warnings in import/planning tests that become errors under Swift 6. Resolve warnings and make strict-concurrency adoption deliberate.
- **Some SwiftUI-adjacent helpers still reach into DomainMapper.** For example, `PlanningTotals` uses the persistence mapper for civil-day conversion. Move product-safe civil date operations into the Surface layer to make the architectural direction enforceable without importing the domain into views.
- **Release identity is incomplete.** The AppIcon asset declares an image slot but no filename/image. Add the icon, release naming, migration notes, and privacy declarations based on actual data practices. Absence of a privacy manifest was not treated as proof of an App Store rejection; required-reason API use needs its own distribution review.
- **UI acceptance is not a required CI gate.** This is a defensible cost choice, but maintain a small reliable critical-flow smoke suite covering restore, foreign Plan, error recovery, matching, and categorization. Full simulator UI and read-only physical acceptance remain complementary.

## Features most likely to add value

| Priority | Feature | User value | Guardrails / acceptance |
| --- | --- | --- | --- |
| 1 | Complete encrypted backups, recovery rehearsal, backup reminders | Protects years of categorization and planning work; recovery becomes trustworthy | Restore an actual synthetic full app state into a fresh install and compare user-visible outcomes. Never export pairing secrets. |
| 2 | Correct a recorded transaction without deleting it | Fix merchant/category/date/account mistakes despite durable evidence links | Preserve identity and provenance, append correction audit, recompute budgets/checkpoints, and require explicit decisions for economic changes. |
| 3 | Guided balance reconciliation | Explains why the bank and local ledger disagree and helps find missed/duplicate entries | Show observation dates, pending/available/booked differences, and candidate causes; never turn unexplained drift into fabricated income or spending. |
| 4 | Foreign-payment settlement and explicit FX entry | Supports travel, USD subscriptions, and foreign cash without manual workarounds | Capture original amount, actual charged amount, fee, date and evidence; never invent an FX rate. Maintain per-currency totals. |
| 5 | Subscription and recurring-payment review | Helps stop unwanted charges and makes upcoming obligations easier to maintain | Suggest recurring patterns for approval, show price changes, support end/pause dates and reminders; evidence remains a proposal. |
| 6 | Actionable forecast scenarios | Answers “What if this income is late?” or “What if I buy this next month?” | Explain the triggering payment, lowest cash day, required bridge, and what changed; simulations must not modify the ledger. |
| 7 | A faster, inspectable review queue | Reduces the daily review burden while preserving user control | Searchable categories, visible supporting evidence, explicit batch preview, undo/correction, and per-rule explanations. Fix stale candidate retirement first. |
| 8 | Optional Face ID, hidden balances, app-switcher cover | Improves confidence when using the app in public or sharing an unlocked phone | Provide a deliberate grace period and accessible fallback; verification remains possible without weakening key storage. |
| 9 | Local cash-flow reminders and small widgets | Makes funding gaps and coming bills useful before opening the app | Opt-in local scheduling, stale-data indicators, redacted lock-screen defaults, no promises based on missing coverage. |
| 10 | Debt and instalment management | Turns imported liabilities into something the owner can maintain | Separate principal, paid items, remaining scheduled payments and unscheduled debt; do not invent repayment schedules. |

The next major product increment should combine recovery, correction, and reconciliation. Those make the existing financial model more useful and trustworthy. Broader automation, investment valuation, or multi-device synchronization should come after these boundaries are reliable; each would introduce substantially more interpretation, conflict, or market-data policy.

## Suggested execution order

1. Repair F01–F06: backup metadata, foreign Plan totals, safe external-money parsing, shared document validation, overflow handling, redaction.
2. Repair F07–F11 and add adversarial regression cases for stale membership, currency precision, pairing availability, and sanitized failures.
3. Harden recovery/privacy and job lifecycle: encrypted complete backup, inactive cover, effective file-protection verification, dedicated transport, Keychain failure handling, queue recovery and retention.
4. Add correction and guided reconciliation, then improve recurring payments and scenarios. Include a small critical-flow UI gate and meaningful performance baselines.

Keep the existing strengths: integer money, explicit currency identity in Core, civil dates, evidence separated from economics, no silent ownership inference, signature-before-nonce verification, per-device revocation, atomic writes, closed-vocabulary refusals, private-fixture Release exclusion, and protected delivery checks.
