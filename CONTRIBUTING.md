# Contributing

FinanceApp is a private development project. Work in a short-lived feature
branch and open a pull request against `main`. Keep product changes and tooling
changes in separate commits. Main requires green checks and resolved review
conversations; do not bypass protection.

## Before changing code

Read the [architecture](docs/architecture.md) and the instructions applicable to
your checkout. FinanceCore is authoritative for financial semantics. SwiftUI
views consume facade types and do not import FinanceCore or SwiftData.

A change must preserve exact money, ownership, civil dates, evidence identity,
and explicit confirmations. Do not infer an exchange rate, equate transfers
with spending, or treat absent provider evidence as zero.

## Verify the change

Use the [development commands](docs/development.md) relevant to the change.
Include meaningful regression coverage for behavior fixes. Interface work needs
synthetic simulator acceptance; changes to bundled resources or build settings
need the Release privacy gate. Documentation work needs correct links, accurate
examples, and visual inspection of any images.

In the PR, explain the user-visible change, its cause, verification performed,
and remaining limitations. Required CI checks are listed in the
[GitHub workflow](docs/github-workflow.md). Verify the merge's own main run too.

## Reports and screenshots

Use the issue forms with synthetic reproduction steps. Include device family,
iOS version, app revision, and expected versus actual behavior where relevant.
Do not attach bank exports, databases, credentials, pairing codes, private
endpoints, account identifiers, or real financial screenshots. Describe
security-sensitive findings privately to the repository owner before putting
technical details into an issue.

The README previews use Debug in-memory demo scenarios. Follow the
[screenshot instructions](docs/development.md#repository-images) when refreshing
repository artwork.
