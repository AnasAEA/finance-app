# Sustainable CI on the development Mac

CI defaults to the repository-scoped Apple Silicon Mac runner labelled
`finance-private`. All four required checks run through GitHub Actions on that
Mac: Repository safety, FinanceCore, App and integration, and Release bundle
check. Branch protection stays strict and keeps those exact required names.
An offline Mac leaves work queued; it never silently allocates a paid runner.

GitHub currently charges no Actions usage fee for self-hosted runners. This is
not a guarantee of future pricing, and the Mac still supplies power, storage and
availability. See [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).

## Run policy

- Build and test locally before publishing. Batch product and tooling commits in
  one push rather than pushing each small fix separately.
- Use draft PRs during active iteration. Safety runs, but the other required
  checks explicitly fail with a deferred message. They do not claim a pass or
  run builds. Mark ready after local validation; `ready_for_review` triggers the
  full required checks. A ready PR's later pushes still receive fresh checks.
- PR checks run against GitHub's merge candidate. The classifier uses the trusted
  accepted base SHA and the candidate SHA; missing history and unknown paths
  select all gates. Unchanged inputs produce explicit reports, not test claims.
- No automatic main-push build repeats the PR work. Main remains protected with
  strict up-to-date required checks. Direct/admin bypasses remain prohibited;
  validate releases with an explicit dispatch when needed.
- Full UI acceptance stays local or manually dispatched. It is not automatic.
- Cancelled and superseded runs still consume any hosted time already executed.

| Change | FinanceCore | App/integration and Release |
| --- | --- | --- |
| Only repository documentation | Explicit unchanged report | Explicit unchanged reports |
| App source, app tests, UI tests or Xcode project | Core unchanged report | Full checks |
| Core, scripts, workflows or unfamiliar input | Full suite | Full checks |
| Manual dispatch, malformed/missing history, empty diff | Full suite | Full checks |

## Mac runner

The registered runner is `finance-anasait-mac`. It belongs only to the private
`AnasAEA/finance-app` repository, uses a user LaunchAgent, and executes one job at
a time. No root service or global Xcode selection change is needed. The workflow
sets `DEVELOPER_DIR` for its processes. Keep Xcode and a simulator installed.
The Mac must be awake and logged in for the user service to execute jobs.

```sh
Scripts/local-ci status
Scripts/local-ci stop
Scripts/local-ci start
```

`Scripts/local-ci install` is for a new installation, not a routine restart. It
verifies the pinned official runner archive's SHA-256, requires the private repo
and owner/admin login, and registers with a short-lived token without printing
it. Registration files are private and live outside the repository under
`~/.local/share/finance-app-ci/runner`. No credentials belong in git.
The official runner handles its own updates; inspect its service diagnostics if
GitHub reports it offline.

This is a trusted-code runner on a personal machine, not a sandbox. Only the
owner currently has repository access. Private-fork workflows are disabled in
repository settings, and the workflow refuses non-owner or foreign-repository
PRs before checkout. Preserve those restrictions. Reassess isolation before
adding collaborators, enabling fork workflows or making the repository public.
Never use `pull_request_target` to run a PR checkout on this machine.

## Explicit paid fallback

A manual CI dispatch has `use_hosted=false` and `run_ui=false` by default. Set
`use_hosted=true` only for an intentional paid run when the Mac cannot provide
verification. This selects hosted Linux for safety/unchanged reports and hosted
macOS for full gates. No offline timeout or failed local check activates it.
Do not rerun an old hosted workflow expecting its runner choice to change;
runner migration must first be present in the branch's workflow.

Keep the account's user-set $10 hard stop. It is a monthly ceiling, not new
credit each time it is edited. Resolve actual account billing failures separately;
self-hosting does not repair failed payments or guarantee GitHub will schedule
jobs while an account-wide restriction is in effect.

## Cost visibility

```sh
python3 Scripts/ci-cost.py
python3 Scripts/ci-cost.py --since 2026-09-27 --max-estimate 5
```

The local report reads CI jobs through authenticated `gh`, includes every attempt
and cancelled run, rounds executed hosted jobs to whole minutes, and separates
self-hosted execution. Unknown hosted rates and unfinished jobs refuse a false
zero. `--max-estimate` exits nonzero at the supplied gross repository threshold.
It does not change billing or block git pushes; use it before any paid dispatch.

These are gross runner estimates, not invoices or account allowance. Included
usage, other repositories, storage and Copilot charges need the account Billing
page. Current standard rates are $0.062/macOS minute and $0.006/Linux minute;
recheck [GitHub runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing)
when images or pricing change. Self-hosted jobs currently have no Actions usage
fee. No scheduled reporting workflow is needed: reporting should not add spend.

## Verification

Run `python3 Scripts/test-ci-scope.py`, `python3 Scripts/test-ci-cost.py`,
`python3 Scripts/repository-safety.py`, and actionlint. Then verify a real PR's
required jobs show runner `finance-anasait-mac` and all succeed on the exact head
before merging. Source tests and Release privacy inspection still run normally.
There is intentionally no post-merge duplicate CI to wait for.
