# Foreign-currency categorization — 2026-09-26

## Cause

The affected PayPal evidence reports a USD purchase while its bound local
account is EUR. It is booked, durable, active and unreviewed; its date is after
the binding boundary. The account-currency invariant rejects recording the USD
amount as a EUR account leg. The category chooser previously offered Save
without surfacing this requirement. This is unrelated to category selection.

The mobile contract carries one provider amount/currency and no separate
account-currency settlement amount. No exact EUR charge can be derived from
that evidence alone. The original provider observation must not be relabelled
as EUR, converted using a guessed rate, or attached as exact EUR account movement.

## Fix

The product projection carries the linked account's currency and precision.
For a currency mismatch, categorization shows the original payment and asks
for the exact positive amount charged in the account currency, from the user's
statement, including conversion fees. Save requires both that amount and an
explicit category. Existing same-currency payments retain their exact original
amount and do not show the additional input.

The serialized store validates currency, precision and positivity, refuses a
missing foreign charge or an override of a same-currency amount, and stores an
explicit user-confirmed account-currency expense. The untouched foreign amount
is attached as supporting evidence, using the existing Core role; it is never
claimed as exact account movement. A transaction note records that distinction.
The resolution, category, merchant and evidence links save atomically. Failure
rolls back. Stored balance snapshots are unchanged. Supporting-only evidence
cannot supply the account-movement confirmations used to propose automated rules.

No FinanceCore invariant or provider normalization is weakened. The additional
field is an explicit financial confirmation, not an automatic conversion. The
app cannot supply the missing charged amount until the provider contract offers
reliable settlement evidence.

## Validation

Synthetic store regressions cover required input, wrong currency, wrong
precision, zero/negative input, same-currency override refusal, successful
USD-to-EUR manual confirmation, unchanged evidence/balances, category persistence,
supporting-only links and repeat-save refusal. A simulator UI case proves that
Save is disabled until category and charge are supplied and that the completed
save returns to Activity without the error.

Final acceptance:

- 1,116 app/integration tests in 87 suites and two focused simulator UI cases
  passed; xcodebuild exited zero with TEST SUCCEEDED.
- Scripts/check: 812 Core tests, two existing skips, zero failures; Debug PASS.
- Signed Release build and its privacy/security bundle gate passed.
- Signed Release over-installed on the paired iPhone. The actual affected row
  opened Categorize payment with a confirmed navigation postcondition; the
  charged-amount field was visible/enabled and Save remained disabled until
  confirmation. No real charge, category, expense, rule or sync action was
  submitted. WAL-aware pre-install/post-navigation comparison returned
  NO_BUSINESS_MUTATION: zero business and zero operational tables changed.
- Left the phone on that categorization screen for the user to complete using
  their statement. Private copies and inspection captures removed. No commit.

No provider or Core source changed. No real financial save or full UI-suite
acceptance is claimed; the save path was exercised with synthetic data.
