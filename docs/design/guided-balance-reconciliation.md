# Guided balance reconciliation

## Problem and delivery order

Balance evidence previously compared a dated provider amount with today's ledger,
and disappeared entirely when there was no opening anchor. A difference could
therefore reflect activity after the reference date, and missing data could look
like no evidence. The first release fixes those diagnostics and gives the person
a guided review. It does not introduce a balance adjustment or acceptance stamp.

1. Retain mapped provider evidence even when comparison is unavailable. Show its
   original type, amount, explicit reference date and separate observation time.
   Distinguish closing booked (`CLBD`), expected (`XPCD`) and interim available
   (`ITAV`) balances. Unknown types remain evidence without inferred meaning.
2. Reconstruct the recorded ledger at the explicit bank reference date: inclusive
   opening anchor plus non-reversed account legs strictly after that anchor and
   through the reference date. Preserve the existing ledger inclusion rules;
   explain that recorded pending entries may differ from booked bank cash. Use
   checked minor-unit arithmetic for both replay and bank-minus-ledger difference.
3. State why comparison is unavailable for absent dates/anchors, dates before the
   anchor or after today, inactive mappings, inconsistent provider identity,
   currency/precision mismatch, unknown balance type, unavailable current civil day
   or arithmetic range failure.
   Never use observation time as a financial date, infer FX, clip overflow, or
   fabricate a zero balance.
4. Explain the opening balance, net account movement and included record count.
   Offer routes to those recorded transactions, relevant unreviewed booked bank
   evidence, current pending evidence, all evidence and account details. Pending
   evidence is separate and is not added to the ledger. Activity records retain native currency and exponent; daily
   home-currency totals do not convert foreign amounts. Lists show up to ten
   relevant rows; the complete evidence/account destinations remain available.
5. Verify that reading and rendering cannot mutate anchors, provider evidence,
   audit history, checkpoint revisions or backup bytes. Test date boundaries,
   missing information, transfers, pending membership, range failures and live
   navigation. Run Core/app/UI/Release gates and publish through required CI.

## Claims and invariants

The result is a diagnostic, not proof of completeness or missing spending.
Equal numbers do not verify an account. Booked, expected and available balances
are different bank statements of cash; provider holds and booking dates can
legitimately differ from recorded economic dates. Review current pending evidence
without treating it as an explanation of an older reference balance.

The guide adds no persistence model, recovery version or interchange field.
Source evidence and ledger facts remain separate. Account movement never becomes
spending automatically, and no delta becomes synthetic income or an expense.
Existing explicit evidence review, payment matching and supported financial
corrections remain the write paths. Imported, linked, matched and shared records
keep their financial correction blockers.

## Subsequent relationship-review release

Before allowing financial edits on a bank-linked or payment-matched record:

- Capture the ledger revision, complete original transaction, supporting bank
  evidence and settlement/goal dependencies in an editor draft.
- Preview each relationship that would become incompatible. Require an explicit
  retain/review decision; do not silently unlink, retarget or reinterpret it.
- Rebuild and compare the preview at confirmation, including civil day, bank
  evidence changes and newly introduced dependencies. Refuse stale/dirty stores.
- Commit the narrow financial change, explicit relationship decisions and full
  before/after history together. Inject failures to prove complete rollback.
- Carry relationship history in full encrypted recovery with strict integrity,
  migration and endpoint validation; prevent ordinary writes from erasing it.

A later reconciliation acceptance needs authoritative dated coverage and
compatible bank balance semantics. It must not be inferred from a zero delta.
