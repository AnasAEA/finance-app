# CI cost controls

The four required check names remain unchanged. Repository safety runs for every
pull request and main push, tests the scope classifier, and determines the work
from the complete changed-file list. The other jobs wait for this inexpensive
Linux check before allocating a runner.

| Change | FinanceCore | App/integration and Release |
| --- | --- | --- |
| Only `docs/`, root README, AGENTS or license text | Linux report: inputs unchanged | Linux report: inputs unchanged |
| App source, app tests, UI tests or Xcode project | Linux report: Core unchanged | Full macOS checks |
| Core, scripts, workflows or any unrecognized path | Full macOS suite | Full macOS checks |
| Manual dispatch, invalid event/history, empty diff | Full macOS suite | Full macOS checks |

An unchanged report is not a claim that tests ran. Each job summary records the
decision explicitly. A safety failure makes the dependent required jobs fail
explicitly on Linux, without starting macOS builds. No workflow-level
path filter leaves a required check pending. No permissions or branch protections
are relaxed, and manual UI acceptance retains its full suite.

The classifier uses the PR base and checked-out merge SHA, or the before/after
SHAs for a push. Renames are expanded into old/new paths, so moving a source file
into documentation still requires product checks. Missing history, malformed
events and unfamiliar paths choose the complete gates.

The routing code is read from the accepted base commit, not the PR checkout.
A candidate cannot change its own classifier to suppress tests. If the base has
no classifier yet, all gates run; manual dispatch always runs all gates as well.

## Cost expectations

GitHub's September 2026 standard-runner rates are $0.062 per macOS minute and
$0.006 per Linux minute. Each job is rounded up to a whole minute. Before included
usage discounts, a run with one Linux minute and eight macOS minutes is about
$0.502. A documentation run with four one-minute Linux jobs is about $0.024.
An app-only run replacing one Core macOS minute with Linux is about $0.446.
These are estimates from representative durations, not billing guarantees.

See [GitHub runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing).

Concurrency already cancels superseded runs. Automatic UI tests remain disabled;
they are available by manual dispatch. Build caches are not added speculatively:
measure cold/warm timings and cache size first, then retain an invalidation key
that includes the toolchain and build inputs. A cache must never replace a test.

## Verification

Run `python3 Scripts/test-ci-scope.py` for documentation, product changes,
unknown inputs, rename/delete safety and manual/error fallback coverage. Lint the
workflow with actionlint. Changes to the classifier or workflow themselves take
the full macOS route, so the optimization must pass the original product gates
before merging.

## Monitor the savings

For a documentation-only PR, confirm that all four required jobs use
`ubuntu-24.04`. The three product jobs should report unchanged inputs and omit
their build steps. For app-only changes, Core should use Linux while app and
Release checks use macOS. Check the main push too, since it uses a separate diff.

Use each job's start/end time, round its duration up to a whole minute, and
multiply by the current rate for that runner. Include every attempt and cancelled
run when reviewing actual consumption. This measures gross CI usage; the Billing
Usage page shows the included discounts and final billed amount. Optional Copilot
reviews and manual UI runs are separate from the four-job estimates above.

Keep required checks enabled when tuning costs. If product inputs are unchanged,
look for an explicit eligibility report rather than treating a missing or skipped
test log as evidence that tests passed. Recheck the scope rules whenever a new
package, resource or build tool is added.
