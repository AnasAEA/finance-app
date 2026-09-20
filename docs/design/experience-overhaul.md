# Financial workspace experience

## Baseline audit

Baseline product: 336b59e, with local tooling commit bebaea8 preserved. Visual
specimens use only existing synthetic Debug previews. Screenshots and result
bundles live outside the repository under /private/tmp/finance-redesign.

- Home gives its title more weight than Safe to Use. Separate white rectangles
  fragment cash, attention, and the weekly forecast. Bank trouble and a cash
  shortage share amber treatment. Routine outflows look like errors.
- Plan answers funding status, then gives five tools identical menu-row weight.
  Budget policy, future commitments and protected money need different groups.
- Activity repeats dates on every transaction. Review suggestions are tiny,
  subordinate to merchant/account metadata. Long names compete with amounts.
- Transaction detail separates the transaction into generic settings sections.
  Evidence and destructive actions need a clear place in the story.
- Insights repeats white panels around period controls, a summary, records,
  findings and verification. Ended-month status appears too far down the page.
- Settings conventions work, but the account count adds a destination-less row.
  Onboarding is a small wallet icon and two cards with disproportionate copy.
- Secondary planning, source evidence, bank connection, restore and manual
  setup screens retain useful native controls; reading surfaces need the same
  typography and spacing language as the main tabs.

## Direction

A quiet financial workspace: warm paper in light appearance, deep ink in dark
appearance, forest accent, strong aligned numerals. Financial headlines live
on the page. Panels group controls or a single decision; ordinary facts do not
all need cards. Red means a funding problem, amber means a reserve/caution,
blue means a connection or information issue. Every status has words or a
symbol as well as color.

Keep the four tabs and their stable identifiers. Keep existing owners and
navigation paths for all actions. Custom compositions for Home and Plan,
date-grouped native transaction lists, document-like reading surfaces for
transaction detail and Insights, conventional Settings and editing forms.

## Boundaries

All financial calculations, authority, persistence, eligibility, checkpoint
writes and evidence resolution remain in their existing implementations.
Presentation may restyle a mapped state; it cannot infer a new financial state
from a number or invent a relationship between forecast events.

## Design system specification

- Type: financial hero (52pt, scaled), screen title (title2), section title
  (headline), card title (headline), body, supporting (subheadline), metadata
  (caption), numeric emphasis (monospaced digits), action (semibold subheadline).
- Space: 4, 8, 12, 16, 24, 32. Screen gutter 24; compact controls 12–16.
- Shape: 12pt controls, 20pt panels; capsules only for compact status.
- Surfaces: page, elevated control panel, inset, and a leading status rule.
  Narrative sections use headings and whitespace rather than nested cards.
- Color: adaptive paper/ink; forest accent; readable positive, warning,
  deficit and information roles, with explicit high-contrast variants.
- Motion: brief opacity feedback for pressed controls and disclosure changes;
  never interpolate or count through fabricated financial amounts. Reduce
  Motion disables added transitions.
- Accessibility: stack labels and values at accessibility sizes; preserve
  reading order and currency units; allow long text to wrap; minimum 44pt
  actions; retain native navigation, controls and VoiceOver semantics.

## Shipped composition

Home starts with Safe to Use and its explanation affordance, followed by cash,
the mapped attention priority, and a single Next 7 days story. A connection
problem uses information blue; a funding deficit uses red; a reserve warning
uses amber. The selected primary issue and event attribution have not changed.
A quiet state has a small positive mark and deliberate breathing room.

Plan starts with the existing funding verdict. Budget and Safety reserve form
Spending policy, Upcoming sits under Commitments, Goals & Set Aside states the
protected amount, and affordability has its own action panel. Every former
management destination remains reachable.

Activity groups adjacent transaction dates while preserving the selected sort
order. Routine amounts are neutral and signed. Review rows lead with the
suggested decision, then the event, caution and metadata. Transaction detail
reads from amount/date through economic meaning and accounts to source
evidence; removal is separated at the end. Evidence detail puts interpretation
and duplicate caution before raw provider fields, with distinct decision
buttons below. No eligibility rule has moved into the views.

Insights puts ended-month verification before the period summary. Verified is
calm green; changed and unverified are informational. Decision/limitation
counts are compact at standard sizes and become readable lines at accessibility
sizes. Existing acknowledgment and checkpoint actions retain their conditions.

Settings keeps native conventions, grouped under Connections and Your app.
Accounts now opens the existing account destination. Onboarding uses a serif
welcome, a restrained wallet mark and clearer restore/manual choices. Editors,
bank pairing and data import/export retain native forms with the shared palette.

## Navigation and interaction

- Four existing tabs and their order remain unchanged: Home, Activity, Plan,
  Insights. No router framework or extra navigation layer was added.
- Primary tab titles use compact navigation bars so content leads the screen.
- Existing push/sheet ownership remains intact; Settings adds a direct Accounts
  link using the existing route.
- Press opacity, Activity section transitions and Insights disclosure provide
  brief native feedback. Budget month transitions use the same restraint.
  Added motion respects Reduce Motion; money never counts through invented values.
- Saving a safety reserve dismisses its numeric keyboard after the existing
  successful write, keeping navigation available.

## Accessibility decisions

Accessibility sizes stack policy tiles, ledger labels/values, activity amounts,
status symbols and source evidence. Upcoming switches from a compact day/month
column to a full date line. Long text wraps; monetary values retain currency,
signs, monospaced digits and their whole-value accessibility labels. Status
uses words and symbols as well as color. Adaptive colors include light-mode
Increase Contrast variants and a separate dark palette. New action surfaces
use a minimum 44pt height; destructive actions use large native controls.

## Deliberate limits

The runway chart and financial explanation language retain their existing
meaning. Editing forms use native controls; not every utility screen needs a
custom composition. Bank service availability, pairing, Trusted Automation,
restore guards, provenance, safe removal, E1/E2 and checkpoint authority are
unchanged. This phase adds no financial or bank capability.

Validation uses synthetic stores on simulators. It does not establish physical
iPhone ergonomics, a spoken VoiceOver walkthrough, or exhaustive localization
coverage. Very large amounts use the existing single-line scaling strategy;
additional currency/localization stress specimens remain a useful follow-up.

## Validation record — 20 September 2026

- Initial main was clean at bebaea8 (the existing Scripts task commit), one
  commit ahead of origin/main at 336b59e. Remote CI was green at that baseline.
- FinanceCore: 804 tests, two existing skips, zero failures.
- Full app gate: 1,082 app/integration tests across 84 suites and all 54
  XCUITests passed. Existing workflow/semantic assertions were retained.
- Small iPhone: four additional UI checks passed, covering AccessibilityXL
  Plan navigation, dark AccessibilityXL pending rows, evidence resolution and
  provenance, transaction detail, and reserve-warning navigation.
- The final copy/background adjustments were rebuilt and the complete 1,082
  app/integration tests passed again on the small iPhone, together with the
  setup/recovery and Home navigation follow-up checks.
- Scripts/check, the Release fixture/secret-absence gate, and git diff --check
  passed. Existing actor-isolation warnings remain outside this presentation
  change. The import tests explicitly select FinanceApp.DocumentWriter to
  avoid the new SwiftUI type-name collision in Xcode 27.
- Source inspection confirms no changes to FinanceCore, Surface, persistence,
  forecast, evidence authority, or checkpoint implementation.

Visual inspection covered iPhone 13 mini, iPhone 17 and iPhone 17 Pro Max;
light, dark and AccessibilityXL with Increase Contrast; Home positive,
funding deficit, reserve warning and unavailable states; Plan funded/deficit/
reserve warning; transactions, To Review, transaction detail and removal
explanation; provider evidence; Insights unverified, verified and changed;
Settings, banks/failed sync, Automation, Data & Privacy, onboarding, restore,
manual setup and planning destinations.

Verified and changed Insights specimens were rendered from the real checkpoint
writer and repository using synthetic test documents. No fabricated financial
state was added to production. Screenshots, test bundles and the local comparison
page remain outside version control in /private/tmp/finance-redesign.
