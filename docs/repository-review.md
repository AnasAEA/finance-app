# Repository presentation review

Reviewed September 26, 2026. Scope: the iOS repository's presentation,
documentation, contributor experience, and existing GitHub controls.

## Findings and completed improvements

| Finding | Impact | Improvement |
| --- | --- | --- |
| The README was about 23 KB and led with internals. | Readers had to interpret architecture before understanding the app. | A short product introduction, capabilities table, quick start, and engineering map. |
| No app previews or consistent repository artwork. | The interface and visual identity were invisible on GitHub. | A forest/paper SVG header and three actual synthetic simulator previews. |
| Sync, budget, and schema-reset descriptions were stale. | Documentation understated implemented features and described a dangerous obsolete reset policy. | Current automation and budget descriptions; pre-alpha migration clearly labeled historical. |
| Setup and financial behavior were mixed into the landing page. | Everyday setup and deeper contracts were difficult to find. | Separate development and data/sync guides, plus a design-document index. |
| Reports had no structured reproduction prompts. | Missing environment details and private-data attachments could slow investigation. | Lightweight bug and feature issue forms, with contribution guidance. |
| GitHub About emphasized implementation terminology. | Repository summaries gave a weaker product introduction. | A concise description that names cash flow, activity review, and planning. |

## Existing strengths to retain

- Protected main with required Core, app/integration, repository safety, and
  Release-bundle checks, including administrator enforcement.
- Read-only Actions permissions, pinned official actions, timeouts, and
  cancellation of superseded work.
- Monthly grouped dependency updates and automatic merged-branch deletion.
- Independent financial-domain package and documented facade boundaries.
- Explicit privacy exclusions for financial fixtures, local configuration, and
  device artifacts.

These controls already serve the project well. Repository artwork belongs in
documentation rather than the app bundle, and new documentation should not
introduce another hosted test job. Required checks remain in place.

## Next priorities

| Priority | Work | Completion criterion |
| --- | --- | --- |
| 1 | Keep docs aligned with behavior changes. | Feature PRs update the relevant guide and replace obsolete claims. |
| 2 | Refresh previews after material interface changes. | Same demo scenarios, visually checked full-screen captures, no real data. |
| 3 | Make release history readable when releases begin. | Tagged, verified builds with concise user-facing changes and migration notes. |
| 4 | Finish app identity before distribution. | A real application icon and intentional release naming, reviewed independently of repository artwork. |
| 5 | Revisit CI spending after representative runs. | Measured runner duration and cost guide changes while preserving financial and privacy gates. |

Do not invent release badges, coverage percentages, benchmark claims, an open
source license, or an App Store link before there is evidence and a decision to
support them. The repository remains private; a polished landing page does not
change distribution or access.
