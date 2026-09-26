# GitHub workflow

The iOS source lives in the private `AnasAEA/finance-app` repository.

## Publishing a verified change

Use a short-lived feature branch, commit product and tooling changes separately,
and open a pull request against `main`. Run the local acceptance relevant to
the change before publishing. GitHub checks the PR merge result; merge only
after all required checks pass. Verify the subsequent `main` run, then update
the local branch with a fast-forward pull. Report the committed SHA and CI
result at closeout. This workflow never installs or deploys a build by itself.

## Required checks

- Repository safety: tracked private-file and credential-material checks.
- FinanceCore: the complete pure Swift package suite.
- App and integration: the complete app, persistence and integration suite.
- Release bundle check: private fixture, evidence and credential exclusion.

The workflow runs on pushes to main and pull requests. It has read-only token
permissions, immutable checkout action references, no persisted checkout
credentials, job timeouts and cancellation of superseded runs. Simulator
selection uses an available device UUID rather than an ambiguous model name.
Xcode's verbose simulator diagnostic collection is disabled to avoid the
observed post-test stalls. Full simulator UI acceptance is available through
Actions → CI → Run workflow → Run the full simulator UI suite. Local targeted
UI and physical checks still accompany interface changes.

Dependencies are local Swift packages. Actions dependency updates arrive as a
grouped monthly Dependabot PR and must pass the same checks.

## Repository controls

Main requires up-to-date status checks and resolved conversations. Administrators
are included in enforcement; force pushes and main deletion are blocked. No
second reviewer is required for this single-maintainer repository. Merged
feature branches are deleted automatically. Automatic merge is available for
PRs whose required checks have passed.

Private bank evidence, imported databases, local agent state, device captures,
development financial fixtures and local endpoint overrides stay outside Git.
The safety check supplements the Release bundle gate; it is not proof that
arbitrary financial narratives or every possible secret format were detected.
Never place real customer or device data in workflow logs or artifacts.
