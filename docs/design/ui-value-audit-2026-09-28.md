# UI value audit and redesign plan — 28 September 2026

## Decision

The app is functionally much stronger than its daily experience. Keep the four financial questions (Home, Activity, Plan, Insights), but redesign **Activity as the place to find and resolve a record** and **Insights as the place to understand a period and act on the explanation**. Do not solve this by adding more cards, charts, or color. The current presentation spends too much space repeating caveats and too little connecting an answer to its evidence.

This began as an audit and implementation plan; the status section below records what has since shipped and what was deliberately left. Evidence is current `main` at `881b0a1`, source review, existing tests, and fresh Debug-preview iPhone simulator captures of Activity (light/dark) and Insights (`full` and `positive`). The Debug preview is seeded from the local development fixture; screenshots remained local and were not committed. No live phone data was used. Prior [visual acceptance](visual-acceptance.md) acknowledged repeated Insights prose and crowded Activity chrome; the fresh review finds those issues material to product value.

## Implementation status — 29 September 2026

The plan below has been carried out in reviewable slices. Each merged only after
the local gate (`Scripts/check`, `Scripts/test-app`, Release privacy gate,
repository safety), a synthetic simulator review in light and dark, and the four
required checks on the exact PR head.

| Finding | Status | Where |
| --- | --- | --- |
| P0 Act on an Insight | Shipped. Unresolved bank items open exactly their decisions. Recorded spent, each category, each budget month and any finding that quotes one of those figures open the review's own record list for it. Those lists come from the engine's contributions and are withheld unless their rows add up to the figure. A list is read again from the current review each time it is shown, and a whole-month list appears only when the reviewed days cover that month. Large one-offs and settled expected payments open their transaction. Goal, cash-risk and floor findings open the Plan screen that owns them. A coverage gap that syncing can close offers Banks & Sync. | #22, #27 |
| P0 Repeated coverage copy | Shipped. One conclusion leads, coverage is stated once, and unknown totals are hidden rather than shown as zero. | #23 |
| P0 Row collision on narrow screens | Shipped. Rows reflow on actual width, and a Debug `longRow` variant stresses it. | #22 |
| P1 Activity chrome | Shipped. Search opens from the toolbar. Sort and filters share one row, and rare filters sit behind More filters. Each applied filter is a removable chip, and filters survive a switch to To Review and back. | #22, #28 |
| P1 One timeline, clearer semantics | Shipped. Rows state their record kind and state visually. VoiceOver hears one sentence (name, amount, kind and state, account) plus a hint naming the screen the row opens. | #22, #28 |
| P1 Muted hierarchy | Shipped. `Theme.Role.supporting` (at least 6.2:1 on every app surface in light and dark, darker under Increase Contrast) replaces system secondary and tertiary text across the app. The To Review rules explanation moved into its row. | #24, #26 |
| P1 Tests for comprehension | Shipped. UI journeys: Insight → review items → back; Insight category → records → transaction → back; finding → records → Budget; filter chip survives a section switch and removes only itself; the row speaks its kind. Engine tests prove the contributions add up. | #22, #27, #28 |
| P2 Details that change no decision | Shipped. Where it went is on the page whenever figures are known. Goals are no longer repeated (Plan owns them). Looking ahead states the first risk once and links to Funding Needed and Upcoming instead of copying current cash and the upcoming list. | #27 |
| P2 Date language | Shipped. Insights and the few raw `YYYY-MM-DD` dates now use the same locale-aware formatting as the rest of the app, including localized spans and the locale's own calendar. | #25 |

Touch targets raised to 44 points: Insights period arrows, Activity section tabs, filter chips, Clear all.

Deliberately not done, and why:

- **Support below expected** stays informational: the engine names no income
  records for that comparison, so no exact list exists.
- **Archive-era periods** are not reviewed, because the store does not yet feed
  archive history to the engine. That is a separate engine phase, not a
  presentation change.
- **Evidence status** remains under More filters. Ledger rows carry no provider
  status, so promoting it would silently hide every recorded transaction.
- **Manual VoiceOver listening pass** has not been run. Row and control labels were
  checked through the accessibility tree on the simulator and on the phone; the
  tooling cannot capture VoiceOver audio.

Physical check, 29 September: the signed Release build of `ab97299` was
over-installed on the owner's iPhone and browsed read-only (Insights this month
and last week, a category's record list, a transaction and back, Activity rows).
A WAL-aware store copy before installation and after navigation compared as
`NO_BUSINESS_MUTATION`. It found one real-data problem the synthetic fixtures
could not: ledger rows created from card evidence were titled with the bank's
full statement line. List rows now show the merchant (#29); detail keeps the
statement verbatim.

## What a person should be able to do

| Job | Expected answer and path | Current friction |
| --- | --- | --- |
| See what needs attention | See the type and count of decisions, open the right review, and return to the same place | Activity has a useful To Review count, but it competes with search, sort, filters, pending status, and a dense timeline. Insights can report unreviewed items without linking to that queue. |
| Understand a period | See the main change, the confidence of the figures, and why it happened | Insights often restates the same coverage issue in the headline, Records, finding, and comparison note. Findings are prose with no drill-down. |
| Find and trust a transaction | Identify merchant, amount, account, date, state, and source; correct or review it | A single timeline mixes archive, operational entries, bank evidence, pending, and rejected items. Their states are accurate but the hierarchy is weak. Long names crowd the amount/status column. |
| Resolve a discrepancy | Move from an insight or budget variance to the contributing records, then back | The existing navigation can open verification details and Home/Plan destinations, but there is no general route from an Insight to Activity with period/category/evidence context. |

## Findings, ranked

**P0 — Act on an Insight.** `InsightsView` renders findings as title/detail text (`findingRow`), and its budget, category, income, expectation, and outlook figures have no drill-down. The only top-level destinations are verification detail and a historical Home pointer. A period review that cannot show its contributing records is hard to trust and cannot complete the user's task. Add explicit destinations only where the underlying evidence can be represented honestly; keep purely interpretive findings visibly informational.

**P0 — Eliminate contradictory-looking and repeated coverage copy.** In the synthetic `positive` state, the first screen says records are missing, both totals are “Unavailable,” Records says coverage is unconfirmed, What changed says records are incomplete, and the comparison note repeats that it is unavailable. In the `full` state, “0,00 €” spent/income appears above a finding that five bank items remain unreviewed. These may be technically correct, but the presentation invites the wrong inference. Lead with a single confidence/action statement; label confirmed figures as such when unresolved bank evidence exists; reserve the explanation and date ranges for a disclosure. Preserve the core distinction **unknown ≠ zero**.

**P0 — Transaction row collision on narrow screens.** In the fresh small-phone Activity capture, “Streaming Membership” wraps beside the amount while “Needs review” occupies the same horizontal band as the second title line. `UnifiedHistoryRowView` switches to a vertical layout only at accessibility text sizes; ordinary narrow widths and long names retain two columns. Reflow according to *available width and actual content*, then test long names, large values, multi-currency values, and status text at standard as well as accessibility sizes. No amount, sign, currency, or state may truncate or overlap.

**P1 — Activity has too much persistent chrome before the first record.** Native search, the two-section switcher, sort, filters, and the pending disclosure occupy much of the initial viewport. Keep search discoverable, but make the default browse view prioritize records and the actionable review count. Consolidate sort/filter affordances and put rare filter types behind an Advanced disclosure. The existing filter sheet includes account, category, currency, amount, type, income source, provider, evidence status, and provenance; these remain available for expert/reconciliation use. The app should remember query context while a detail is opened and closed.

**P1 — One timeline needs clearer semantics.** Archive records, live ledger transactions, reviewed/unreviewed bank movements, pending and rejected bank items are deliberately combined in `HistoryBrowserView`. That is useful for search, but a row should communicate *what kind of record it is* and *what action is possible* without making the person infer it from provider initials or a secondary caption. Pending remains informational; a bank observation is not yet a ledger expense. Use explicit, accessible state and source labels and a stable route to the canonical detail/review screen. Do not split the ledger or copy archived rows into it.

**P1 — Muted information lacks hierarchy.** The custom semantic role colors are not the obvious contrast failure: calculated against the declared light background they range about **5.76–7.09:1**, and against the dark background about **9.48–10.42:1**. The harder areas in captures are repeated gray captions, inactive segment text, faint chevrons and controls, and a floating bar over scrolling rows. `Theme` uses `.secondary` extensively, so token arithmetic alone cannot certify the rendered UI. Inventory *actual text and controls on actual surfaces* in light, dark, and Increase Contrast; raise the emphasis of decision, state, date, and account where necessary. Use color as reinforcement, with text/symbols retaining meaning.

**P1 — Tests protect routes and financial logic better than comprehension.** `InsightsAdapterTests` thoroughly covers coverage, totals, income distinctions, risks, and findings. `ProductionHCIUITests` checks access to Insights, Activity search/filter/review, pending behavior, and some large-text layouts; `DeviceAccessibilityUITests` checks identifiers. There is no test of Insight → filtered contributing records → canonical detail → back, no assertion against repeated/conflicting top-level explanations, and no layout assertion for long names at ordinary narrow widths. Visual acceptance explicitly did not claim full VoiceOver or localization coverage. This is a test-scope gap, not evidence that the underlying calculations are wrong.

**P2 — Some details add length without changing a decision.** Insights' hidden detail block includes budget months, top categories, one-off purchases, income/support, expectations, goals, and today's outlook. Some duplicate Home/Plan; most cannot be acted on here. Keep only a concise period explanation and the most important difference on the main screen. Move the remaining useful breakdowns to focused drill-downs, link to the canonical Plan or Home destination when the person needs to change a plan, and remove sections that cannot answer a specific user question. Retain source/evidence nuance in detail screens, where it matters.

**P2 — Date language is inconsistent.** Insights' `dayText` builds English abbreviated month names by hand, while the Activity timeline formats dates through the system date formatter. A locale change can make related screens disagree. Use one locale-aware date presentation policy and check period labels, date groups, and VoiceOver output together; do not alter the underlying civil-day or statement-date semantics.

## Target experience

### Activity

1. **Top:** Activity title, add action, a compact Transactions / To Review switch with a clear count. Search remains one tap away and can expand while active; sort/filter combine into one compact control row or menu. Do not hide the review queue behind a generic filter.
2. **Transactions default:** Chronological groups, with each row showing a readable name, signed amount/currency, date group, and one meaningful state. Show account/source context on a second line only when it helps distinguish records. Use a width-aware arrangement where status moves below the title/amount when space is tight. The amount remains visually anchored and complete.
3. **To Review:** Group by the *decision the user can make* (quick category, other evidence decisions, expected-payment confirmation). Each row answers “what is this?” and “what happens if I open it?” Pending and known limitations should be a separate, low-priority informational area, not mixed into the action count.
4. **Find:** Default filters are date, account, category, and state. Advanced exposes currency/amount, type/source/provider, evidence status/provenance. Applied filters are visible, removable, and restore after returning from a detail. Search must cover the same unified timeline without pretending archive or bank evidence is a recorded ledger transaction.
5. **Details:** Clear title and source/state first; actions next; raw bank evidence, correction/audit history, and exceptional explanations in disclosures. Destructive and financially authoritative actions keep their existing explicit confirmations.

### Insights

1. **Top:** Period control and one plain-language conclusion. The first viewport should answer “What changed?”, “Can I trust the numbers?”, and “What can I do?” A coverage limitation appears once, with a direct route to its cause or a clear statement that it cannot be resolved here.
2. **Figures:** Show a small number of decisive figures (for example confirmed spending, confirmed inflow, and meaningful variance) only when supported. Label scope and status; unavailable must never look like zero. Avoid visual emphasis on zero totals when many bank items are waiting for review.
3. **Explanations:** A finding has a cause and, where supported, a “See transactions” or “Review items” route with period/category/state encoded in the route. The destination shows the same set used to explain the finding, with a visible filter context and a way back. No fabricated one-tap action for a finding with no traceable records.
4. **Depth:** Verification remains the canonical month-checkpoint workflow. Budget setup stays in Plan; current cash risk stays in Home/Plan. Insights may link to them with context, but must not show an apparently independent second source of truth. Keep detailed support/pass-through and coverage caveats in the relevant explanation screen.

The exact copy, grouping, and visual composition should be prototyped on synthetic states **before** any engine or persistence change. A new chart is justified only if it answers a comparison faster than a number and remains understandable without color. No chart is a prerequisite.

## Implementation sequence

| Slice | Work | Acceptance / evidence |
| --- | --- | --- |
| 0. Baseline and design contract | Record the four user jobs above; create synthetic fixtures for complete/nonzero, missing coverage, five unreviewed items, quiet period, changed verification, archive gap, long merchant, large multi-currency amount. Capture light/dark/Increase Contrast at small, standard, and accessibility sizes. Annotate which information is action, evidence, or explanation. | Before images and task walkthroughs are reviewable. Each proposed main-screen element has a user question it answers. No private screenshot enters Git. |
| 1. Navigation and data contracts | Add a typed Activity destination/query context for period, account, category, and evidence state; define stable IDs/return behavior. Expose contributing-record IDs from the existing authoritative review adapter where possible. A finding without traceable IDs stays informational. | Unit tests prove date boundaries, archive cutoff, pending/evidence distinctions, multi-currency handling, and no invented matches. UI test opens an Insight, reaches the expected filtered records, opens a detail, and returns with context intact. |
| 2. Activity overhaul | Rebuild transaction rows and top controls first, then To Review hierarchy and progressive filter UI. Keep current reconciliation actions and read-only archive boundary. | No collision/truncation at narrow standard width or AX sizes; pending never joins actionable count; search/filter/sort are accessible and restore state. Screenshot review across required fixtures. |
| 3. Insights overhaul | Replace repeated warnings with one coverage presentation; redesign summary, findings, and focused details; connect supported findings to Activity and canonical Plan/Home routes. | Each finding either has a correct destination or is explicitly informational. The first viewport has one confidence statement, meaningful figures, and a relevant next step. Unknown/partial periods cannot display definitive totals. |
| 4. Color, copy, and accessibility pass | Audit rendered foreground/background pairs, interactive boundaries, tab overlay, text wrapping, touch targets, VoiceOver order/labels, Reduce Motion, Increase Contrast, and locale-aware dates. Shorten repeated copy without deleting financially necessary distinctions. | Aim for WCAG 2.2 AA reference values: **4.5:1** normal text, **3:1** large text and meaningful UI indicators; target **7:1** for important small captions where feasible. No status relies on hue alone. Manual VoiceOver walkthrough of both complete user journeys. |
| 5. Regression and release | Run relevant core/app tests, focused UI tests, `Scripts/check`, Release fixture gate, and final synthetic visual matrix. Test read-only phone presentation only after simulator acceptance, under device policy. | Product and financial invariants remain green; no private fixture in Release; fresh renders and interaction recordings match the accepted design. CI uses the self-hosted runner and stays within the Actions budget. |

Each slice should be a reviewable feature-branch PR. Prefer presentation and navigation changes before touching the review engine. If a finding cannot identify records from existing authoritative data, either extend the adapter with tested provenance or keep that finding informational; never reconstruct a financial answer in SwiftUI.

## Explicit acceptance scenarios

- **Unreviewed bank movement:** Insight says what is confirmed versus awaiting a decision, routes to the exact queue, and changes only after the existing review action succeeds.
- **Incomplete coverage:** One prominent limitation; no invented zero, comparison, category total, or trend. The details explain missing dates and the next useful action.
- **Complete quiet period:** Plain “nothing material changed” state, without filler cards or a forced call to action.
- **Actual spending change:** Amount, comparison period, cause, and filtered contributing records agree; account movement and pass-through are not counted as spending/income.
- **Mixed history:** Archive, ledger, and bank evidence remain distinguishable in search, filters, rows, and detail routes; rejected/pending states cannot masquerade as recorded expenses.
- **Accessibility:** Narrow/AX layouts do not overlap, hide an amount, or strand a control behind the tab bar; VoiceOver describes row type, amount, state, and action; high contrast remains meaningful in both appearances.

## Reference standards

- [Apple Human Interface Guidelines: Designing for iOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ios/) recommends prioritizing primary tasks and content while keeping secondary actions discoverable, and adapting to Dynamic Type and appearance changes.
- [Apple Human Interface Guidelines: Color](https://developer.apple.com/design/human-interface-guidelines/color) recommends checking light, dark, and increased contrast and using color consistently for interaction and status.
- [W3C WCAG 2.2](https://www.w3.org/TR/WCAG22/) supplies the contrast targets used as the audit's measurable reference. iOS visual acceptance still requires inspecting the rendered native controls and materials, not only calculating constants.
