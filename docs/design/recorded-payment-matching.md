# Recorded-payment matching — 2026-09-26

## System defect

The old matcher proposed every non-reversed ledger record with the same bound
account and signed amount within five days. If the incoming bank row had no
date, it skipped the time limit entirely. It never checked merchant identity.
The app then promoted these suggestions into duplicate warnings and creation
guards, labelled them as matches, and hid the suggested records in a menu.
This made coincidental similarities look like decisions the user owed us.

## Policy

Account and exact signed amount/currency remain necessary, but cannot establish
identity. A prompt now requires one of these supporting paths:

1. The recorded transaction explicitly names the incoming bank observation's
   exact evidence reference. This remains usable when the provider omitted dates.
2. Merchant identity agrees with the saved merchant label or attached bank
   evidence, and both records have dates within the existing five-day window.
   If the provider supplied a payment date, it must equal the recorded day.
   Normalization changes case, diacritics and whitespace only; it does not strip
   numbers, dates or provider prefixes to manufacture an identity. Generic
   payment/provider descriptions are excluded.
3. The existing unique cross-provider path points to a transaction already
   linked to its related provider's account movement. This remains a proposal
   until explicitly linked and retains its own explanation.

A target already owned by a different durable payment on the same provider
binding is excluded from direct matching. Two same-price purchases at the same
merchant, even on the same day, do not reuse each other's recorded transaction.
Multiple corroborated candidates remain visible and medium confidence; the
system never chooses one automatically. Unknown dates without an exact evidence
reference produce no automatic duplicate prompt.

The UI and expense write guard use the same policy and saved labels. The
projection reuses its direct suggestions when composing conflict context rather
than evaluating them twice. Confirmed links and stored financial records are
not rewritten by this change.

## Interaction

- Replace the Match Existing menu with an inline possible-record comparison:
  merchant, recorded date, amount, account and the matching reason.
- Say Possibly already recorded and Link to [record]. Similarity is not presented
  as a proven duplicate. Retain explicit duplicate override for supported cases.
- Keep Find a recorded payment as an optional manual lookup. It shows matching
  account legs and exact amounts, supports merchant search and asks for an
  explicit link confirmation. Opening or browsing it resolves nothing. The
  list is capped at 100 matches per search; searching examines the operational
  ledger and can find older matches beyond that first result set.
- Approved automation rechecks supported duplicate/conflict evidence before
  creating a transaction and again at the serialized application boundary.
  Ambiguous evidence stays for review rather than producing another expense.

Aggregate arithmetic and already-settled recurring conflicts retain their
separate existing guards. This slice does not silently resolve them, enable
automation, approve rules or record user payments.

## Regression evidence

Core regressions cover amount/date-only collisions, different merchants,
payment-date disagreement, undated and generic descriptors, distinct durable
same-price payments, multiple merchant candidates and exact evidence references.
Store tests prove a weak collision no longer requires an override, remains
manually findable, and approved automation cannot duplicate a record naming the
incoming evidence. Supported-duplicate fixtures now carry an actual evidence
reference instead of relying on the bug's amount-only relationship.

Validation on the final source:

- `Scripts/check`: 812 Core tests executed, two existing skips, zero failures;
  Debug build passed.
- 1,114 app/integration tests in 87 suites and five focused simulator UI tests
  passed. The focused cases cover supported candidates, explicit duplicate
  override, category confirmation, optional lookup without resolution and the
  complete evidence-to-record explanation flow. Two initial invocations
  stalled in Xcode simulator diagnostic collection after their suites passed;
  the final serial invocation disabled that collection and exited successfully
  with TEST SUCCEEDED. No product test was skipped or weakened for this recovery.
- Signed Release build and the bundle privacy/security gate passed.
- Budget export consumer: DOCUMENT PASS; its harness reports 12 passing and two
  existing schema-version rejection failures. These were previously documented
  and are not changed by this matching slice.
- Signed Release over-installed on the paired iPhone. Quick categorization,
  full review and optional lookup reached their expected navigation titles;
  the manual lookup has a visible native search field. Pre-install versus
  settled launch: NO_BUSINESS_MUTATION, zero business or operational tables
  changed. After a cable disconnection, the phone was reconnected and the final
  post-navigation comparison also returned NO_BUSINESS_MUTATION, with zero
  business or operational tables changed. No save, evidence link,
  rule approval, automation toggle or Sync Now was performed. The phone was left
  on Transactions and private store copies and inspect artifacts were removed.

No speed benchmark, complete UI-suite run or spoken VoiceOver acceptance is
claimed. Core is edited in this repository under its authoritative nested
instructions; the budget consumer harness above checks the downstream export.
