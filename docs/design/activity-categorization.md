# Activity categorization and filters — 2026-09-26

## Findings

Bank history was made visible before it acquired recorded meaning. The ledger
still contains only explicitly recorded transactions, so a clear merchant name
does not itself resolve a bank row. The interface nevertheless sent ordinary
purchases through the same long evidence page as transfers, refunds and
possible duplicates. Its expense action saved no category at all. This also
weakened the category information available to future merchant-rule proposals.

The filter sheet exposed ten dimensions in a generic Form. Account and category
were mixed with provenance, economic source and evidence status; amount fields
appeared before their required currency selection. This made a common browsing
task feel like editing a technical record.

## Changes

- Straightforward active, booked debits have a direct Categorize route and a
  Quick categorization section. Existing matches, cross-provider uncertainty,
  transfers, cash, refunds, recurring settlements, provider warnings and
  conflicting automatic rules retain full review. This is a navigation
  shortcut; it never creates financial facts by itself.
- A compact category chooser shows the merchant/account/amount, an editable
  merchant label, category search and a persistent Record expense action.
  A category is required by this UI. The store validates the selected spending
  category and saves it in the same persistence unit as the transaction,
  evidence links, settlement and merchant-rule proposals. No second save or
  later cleanup step is needed.
- Exact prior merchant labels in the same currency can propose their previously
  used category. Conflicting prior categories produce no proposal. The person
  sees and can change the selection before explicitly recording the expense.
  No merchant keyword table or fuzzy match automatically classifies money.
- Full review puts decisions before expandable bank details. Duplicate
  confirmation and the store's authoritative eligibility checks remain in place.
- Rules for repeat merchants are reachable from To Review. Trusted Rules also
  links to the existing master automation setting and states that both the
  setting and a separately approved rule are required. Neither is enabled by
  this change; approval affects future arrivals, not the existing queue.
- Filters use the app's paper/forest theme, four period choices, account/category
  selection summaries and searchable selection pages. Less-used dimensions
  remain under More filters. Currency precedes amount; exact amount validation,
  Reset, Cancel and explicit Show transactions semantics remain intact.
- Selection rows have a full-width, 44-point tap target. A focused UI test
  caught taps landing in unclickable whitespace; the hit region was corrected.

## Limits

Unconfirmed payments remain visible and counted. This change reduces the work
needed to confirm clear purchases rather than suppressing evidence. It does
not bulk-approve transactions, enable automatic rules or change real
classifications during installation. Category suggestions use operational
records, not the static historical archive. Advanced filters retain their
existing archive/live applicability; bank evidence has no guessed category.

## Validation

- Final run: 1,112 app/integration tests in 87 suites and six focused Activity UI
  tests passed with `TEST SUCCEEDED`. New tests cover selected-category save and
  reopen, exact-label proposals, conflicting categories, wrong-currency and
  similar-label refusal, invalid-category atomicity, and shortcut exclusions.
  UI checks cover choosing a category before save, applying an everyday filter,
  Accessibility XL filters, duplicate caution, bank detail and Activity routes.
- `Scripts/check` passed 806 Core tests (two existing skips) and Debug. The final
  signed device Release build and its private-resource exclusion gate passed.
- Synthetic category and filter screenshots were inspected. Local captures are
  under `/tmp/finance-category-final-renders`; no private capture is committed.
- Signed Release over-installed on the iPhone 13 Pro. Quick categorization opened
  directly with `ACTION_CONFIRMED`; the save button was disabled before choosing
  a category. Everyday period choices, account/category controls, More filters
  and the new apply action were verified in the physical tree. Returning from
  the chooser, switching to Transactions, opening filters and cancelling all
  had confirmed postconditions. Phone left on Transactions.
- WAL-aware pre-install versus post-navigation comparison yielded
  `NO_BUSINESS_MUTATION`, with zero business and zero operational tables changed.
  No expense was recorded, rule approved, setting enabled or Sync Now performed
  during physical acceptance. Task-private artifacts were removed.
- The full UI suite and spoken VoiceOver were not rerun for this slice.
