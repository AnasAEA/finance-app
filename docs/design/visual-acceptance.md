# Visual acceptance and second pass — September 21, 2026

## Verdict on 705b75f

**VISUAL_OVERHAUL_NEEDS_SECOND_PASS.** The previous overhaul made the product clearer, but did not fully answer the complaint that it felt bland and static. This judgment comes from rendered screens, not its tokens or tests. The initial checkout was clean main, aligned with origin/main; its CI was successful.

Reviewed the original before/after gallery at `/private/tmp/finance-redesign/review.html`, the experience-overhaul report, individual PNGs, fresh simulator captures, and UI-driven interaction recordings. The original pre-overhaul baseline is 336b59e; the acceptance baseline is 705b75f. They are not interchangeable.

## What improved, and what remained bland

The first overhaul strengthened Safe to Use, separated planning purposes, promoted review decisions over metadata, and brought verification into view. It also escaped default Forms on important reading surfaces. Yet Home remained a bold number above a generic status panel. Plan still read as grouped destinations. Verification looked like another notice. Warm paper, forest links, and rounded panels were insufficient identity.

## Surface critique and second-pass response

| Surface | Acceptance baseline | Second pass | Remaining weakness |
| --- | --- | --- | --- |
| Home | Stronger hierarchy, anonymous composition; attention panel competed with the financial headline | Continuous ink header joins navigation, serif Safe to Use, explanation, and quieter cash; attention becomes an open status row; weekly low gains a medium numeric tier | Explanations remain long. A healthy financial fixture still has a real month-review task, so it is not a completely quiet day. |
| Plan | Purpose grouping helped, but four independent panels still made a menu | Plain verdict; budget and reserve share a ruled spread; commitments and protected money sit alongside one another; affordability remains visible below | It remains a workspace for opening tools, not inline editing. Narrow phones wrap Goals & Set Aside. |
| Transactions | Sensible alignment, but oversized date separation and repeated bold rows slowed scanning | Quieter date headings, tighter row insets, medium merchant weight; amounts keep a stable right edge | Native search and toolbar consume significant room, especially at large type. |
| To Review | Decision-first ordering was useful; forest-colored headlines competed with warnings | Neutral decision titles leave caution amber and metadata subordinate; resolved decisions have a brief removal transition | Long authoritative decision wording still dominates. This is the most text-heavy screen. |
| Transaction detail | Already a readable story, but bold headline and repeated date were mechanical | Serif title, lighter financial value, one date, a clearer Details section | Long provenance remains necessarily documentary. Safe removal stays separate. |
| Insights | Verification was visible but visually resembled a warning/checklist | Open verification composition; dotted unverified mark, changed-state arrows, solid completed check; plain counts instead of nested pills; verified action says View verification | Repeated period language and totals prose remain. A real checkpoint fixture can show Verified above a general Items still to review finding; both authoritative outputs remain visible. |
| Onboarding | More welcoming copy, but nested icon tiles and option cards resembled Settings | Ink opening with serif title, standalone wallet mark, plain restore/manual choices with rules | Home chrome/tabs remain during first run; the experience is still restrained rather than expressive illustration-led onboarding. |
| Settings | Appropriate native groups and useful hierarchy | Retained | No novelty needed here. |

## Identity, cards, color, typography

The recognizable motif is now an ink financial opening with a lighter serif value, editorial verdicts, and ruled content below. Operational rows retain sans-serif clarity. This is a stronger signature than a tint applied to controls. It does not require extra charts or decorative illustrations.

Card counts below refer to visible independent body groupings, excluding native tab/search/segmented controls. Counts vary with state and scrolling.

| Surface | 705b75f | Second pass |
| --- | --- | --- |
| Home with attention | 1 rounded status panel | 0 rounded body panels; 1 rectangular financial header |
| Plan | 4: status, 2 policy tiles, affordability | 0; rules and columns replace containers |
| Transactions / To Review | 0 body cards | 0; retained plain rows |
| Transaction detail | 0 principal story cards | 0; retained separated sections |
| Insights verification | 1 panel plus 2 count pills | 0 panels/pills; 1 state medallion |
| Onboarding | 2 choice cards plus wallet/icon wells | 0 choice cards/icon wells; 1 rectangular header |
| Settings | 3 native grouped surfaces plus icon wells | Unchanged, appropriate grouping |

Forest now anchors Home and onboarding instead of coloring every review decision. Deficit remains red with a distinct symbol and wording; reserve caution remains amber; informational bank/month states remain blue. Healthy figures are not automatically green. Dark Mode has a clear ink header over a darker page, though the green-gray palette can still feel subdued. No gradients or nested glass were added.

The new serif hero is memorable, but its purpose is hierarchy, not decoration on every amount. Supporting monetary values use the shared MoneyText renderer with monospaced digits and Dynamic Type. Medium-size weekly and policy numbers bridge the previous giant-number/small-caption gap. Metadata remains the least expressive layer and is still abundant on evidence screens.

## Motion, density, accessibility

The baseline had native push/sheet/disclosure continuity and press opacity; it did not have a distinctive completion language. The second pass adds a brief Reduce Motion-aware value crossfade, review-row removal animation, state-mark transitions, and visible Saved confirmation after a successful reserve write. Reserve and verification success request native haptics only after success; simulator review cannot establish physical haptic quality. No rolling numbers or invented intermediate balances.

Interaction review uses XCUITest-driven taps, typing, disclosure, navigation and evidence resolution, plus simulator video. The desktop computer-use connection was unavailable. Verification verified/changed images come from the existing real checkpoint test writer; a full physical-device verification-completion experience was not assessed.

Reviewed iPhone 13 mini, iPhone 17, and iPhone 17 Pro Max, plus AccessibilityXL and dark Increase Contrast captures. Plan stacks at accessibility sizes; financial amounts scale; status includes text/symbols. Large type requires substantially more scrolling in Insights and onboarding. Native tab overlays are retained with existing bottom clearance. This is not a claim of a complete VoiceOver audit or localization certification.

## Boundaries

Only presentation components, feature views, and one existing visual UI test changed. No financial formulas, persistence/schema, evidence authority, bank execution, checkpoint writer, restore guards, or authoritative actions changed. The shared financial renderer and mapped-state source assertions remain intact. The verification/general-review wording tension needs a separately scoped explanation review; it was not hidden to manufacture a clean screenshot.

## Evidence and validation

Local visual evidence is intentionally not committed. `/private/tmp/finance-acceptance/review.html` collects baseline and second-pass captures. Additional dark AccessibilityXL specimens are under `/private/tmp/finance-redesign/acceptance-shipped-dark-ax`; focused test attachments and recordings are under `/private/tmp/finance-acceptance`.

Validation results and final remote commit are recorded in the delivery report. Passing tests establish retained workflows, not visual quality.

## Final visual judgment

**VISUAL_OVERHAUL_ACCEPTED after the second pass.** Home now has a memorable financial headline, Plan feels less like a menu, and onboarding shares the same visual identity. The result is calmer and more deliberate without adding decoration or changing money meaning. This is acceptance of the rendered presentation, not a claim that every operational screen is equally expressive. Long evidence wording, repeated month-review prose, and first-run tab chrome remain the clearest opportunities.

Local validation: 1,082 app tests and 54 UI tests passed; FinanceCore 804 executed with two existing skips and no failures. Focused mini interactions (4), final first-run/recovery suite (7), and Activity interaction (1) passed. Scripts/check, Debug builds, Release fixture-absence gate, and git diff --check passed. The final onboarding alignment and date-contrast adjustments were checked with focused UI reruns and fresh renders after the full suite build. Two existing compiler warnings remain. Earlier source-guard failures were fixed without relaxing assertions.
