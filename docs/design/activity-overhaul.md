# Activity redesign — 2026-09-26

## Findings

The recently repaired feed contains archive records, recorded transactions and
bank movements. Its previous visual treatment made those sources difficult to
read together: all-caps statement titles fought large amounts, account/status/
review text wrapped as one gray sentence, and several zero-amount pending rows
could occupy the entire first screen. Search, sort, filter and Add controls also
competed in native navigation chrome. The review queue stacked several long
sentences without a consistent merchant/amount/action hierarchy.

| Problem | Change | Reason |
| --- | --- | --- |
| Crowded controls | Open text tabs; Add stays in navigation; sort and Filters share one timeline control row | Separate navigation from browsing controls |
| Status buried in metadata | Amount and status align at the trailing edge; account/category stay beneath the title | Scan identity, money and state independently |
| Loud statement descriptors | Readable list casing; original detail text retained | Improve reading without changing evidence |
| Pending dominates the newest day | Default newest timeline has an expandable Pending at bank summary with an exact count | Keep waiting visible while bringing completed movements into the first screen |
| Pending hidden during search | Search, active filters and alternate sorts display matching rows directly | Preserve search completeness and sort meaning |
| Repetitive dates | Clear date headings; omit the year only in the current year | Group the timeline with less metadata |
| Review feels like prose | Merchant and amount first, context second, decision instruction in forest below; cautions retain explicit wording | Make the item and its action legible before opening |
| Too many repeated calculations | Parent captures one presentation; child filters/sorts once and groups once | Reduce evaluation and array work per render |

## Visual language

Use the app's warm paper, forest ink, ruled content and restrained status
palette. Rows use small bank initials or existing semantic symbols on a muted
inset, aligned monospaced amounts and readable metadata. There is no new image
asset, decorative chart, gradient or card around every transaction. Pending is
blue, review is amber, and both have explicit text. Amount signs do not decide
whether a movement is spending. Accessibility sizes stack the monetary column
and let text grow vertically.

Transactions and To Review remain the two destinations. The review tab count
includes decisions and payments to confirm, excludes pending and limitations,
and is spoken by VoiceOver. The history summary is a disclosure; the separate
pending review section remains informational and supplies no economic action.

## Efficiency and correctness

- Keep the native virtualized List, 80-row archive pages, bounded archive
  queries and the existing debounced search.
- Reuse one presentation in Activity, including its attention sections. The
  timeline no longer rereads the store or sorts the same rows for emptiness,
  grouping and rendering.
- Group only adjacent equal dates so amount sorting retains its selected
  order. An undated first row now creates a group safely; the prior comparison
  could match two nil dates before a group existed and index an empty array.
- Preserve original financial values, identities, archive cutoff, persisted
  evidence-link deduplication and review/creation guards.
- Retain opaque accessibility row identifiers and existing navigation routes.

## Acceptance

Check default and dark appearance, a small phone and Accessibility XL. Verify
search, filters, pending disclosure, bank detail, both tabs, queue empty states,
decision wording and caution visibility. Use synthetic screenshots only. A
physical candidate must be over-installed, never reset, and compared with
WAL-aware store copies before and after read-only navigation.

## Validation results

- 1,108 app/integration tests in 86 suites passed, including three new timeline
  presentation tests. Eight distinct focused Activity UI cases passed across
  the final runs: navigation, decision language, duplicate caution, empty
  states, bank detail, pending disclosure/search, pending Accessibility XL and
  timeline filters at Accessibility XL. The full UI suite was not rerun.
- `Scripts/check` passed: 806 Core tests (two existing skips) and Debug build.
  The final signed device Release build and its bundle privacy gate passed.
- Reviewed synthetic normal light, dark review, iPhone 13 mini and dark
  Accessibility XL renders. Merchant/amount/status hierarchy is readable on
  the small phone. Accessibility tabs, rows and browsing controls stack; a
  render caught squeezed Sort/Filters labels and prompted that control fix.
- The pending disclosure initially masked expanded rows' automation identities;
  its identifier now belongs to the summary label. The final disclosure/search
  test passed. An undated-first-row grouping regression is independently tested.
- Efficiency is established by reduced repeated work in the rendering path;
  no elapsed-time benchmark or spoken VoiceOver acceptance is claimed.

Physical acceptance completed after the cable was reconnected. The signed
Release candidate was over-installed on the iPhone 13 Pro. Transactions and
To Review, pending disclosure and Transaction filters were reached with
`ACTION_CONFIRMED` postconditions. The app was left on Transactions. Its first
launch refreshed existing service evidence (including provider snapshots and
an additional pending archive batch); a field-level comparison found all 14
transactions, five account balances, five accounts and 16 transaction legs
identical. A settled-launch versus post-navigation WAL-aware comparison yielded
`NO_BUSINESS_MUTATION`: zero business and zero operational tables changed.
No Sync Now or financial review action was performed. Private artifacts were
removed after recording the proof.
