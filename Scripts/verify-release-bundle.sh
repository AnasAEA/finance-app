#!/bin/bash
#
# Proves sample fixtures and provider-only identifiers are not in a shipped app.
#
# The sample fixture cannot *execute* in Release — its only caller sits behind
# `#if DEBUG` — but that was never the point: sample data has no business being
# copied into a bundle anyone with the .app can read. Runtime unreachability is
# not the same as absence.
#
# Usage: Scripts/verify-release-bundle.sh [derived-data-path]
#        Scripts/verify-release-bundle.sh --app <path/to/FinanceApp.app>
#
# The second form inspects a bundle that has already been built — the signed
# device build above all, which is the one that actually reaches a phone. The
# simulator build the first form produces is a stand-in for it, and a stand-in
# is not the artefact.

set -euo pipefail

cd "$(dirname "$0")/.."

if [ "${1:-}" = "--app" ]; then
    APP="${2:?--app needs a path to a built FinanceApp.app}"
    if [ ! -d "$APP" ]; then
        echo "FAIL: $APP is not a bundle"
        exit 1
    fi
else
    DERIVED="${1:-$(mktemp -d)/DerivedData}"

    echo "Building Release into $DERIVED"
    xcodebuild build \
        -project FinanceApp.xcodeproj \
        -scheme FinanceApp \
        -configuration Release \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$DERIVED" \
        CODE_SIGNING_ALLOWED=NO \
        > /dev/null

    APP=$(find "$DERIVED/Build/Products" -name "FinanceApp.app" -maxdepth 3 | head -1)
    if [ -z "$APP" ]; then
        echo "FAIL: no Release FinanceApp.app was produced"
        exit 1
    fi
fi

echo "Inspecting $APP"
FOUND=$(find "$APP" -name "*fixture*" -o -name "*.fixture.json" | head -20)

if [ -n "$FOUND" ]; then
    echo "FAIL: development fixture present in the Release bundle:"
    echo "$FOUND"
    exit 1
fi

# Historical archive data is private import material, never an application
# resource. The schema and importer ship, but no generated archive, canonical
# ledger export, statement, or forensic table may ride along with them.
PRIVATE_HISTORY_FILES=$(find "$APP" \( \
    -iname "*finance-history-archive*" -o \
    -iname "*canonical*transactions*" -o \
    -iname "*.tsv" -o \
    -iname "*.csv" -o \
    -iname "*.pdf" \
\) -print | head -20)

if [ -n "$PRIVATE_HISTORY_FILES" ]; then
    echo "FAIL: private history or forensic source present in the Release bundle:"
    echo "$PRIVATE_HISTORY_FILES"
    exit 1
fi

# Repository documentation and local tool configuration are repository
# furniture, not application resources. The synchronized file-system group adds
# every file it finds under FinanceApp/ to the target, so a Markdown note
# dropped beside a feature ships without anyone choosing to ship it — which is
# how the first one got in. This refuses the whole shape, so a filename nobody
# thought of here fails the gate instead of riding along quietly.
DOC_FILES=$(find "$APP" \( \
    -iname "*.md" -o \
    -iname "*.mdc" -o \
    -iname ".*rc" -o \
    -name ".*" -type d \
\) -print | head -20)

if [ -n "$DOC_FILES" ]; then
    echo "FAIL: repository documentation or local configuration is in the Release bundle:"
    echo "$DOC_FILES"
    echo "Exclude it with EXCLUDED_SOURCE_FILE_NAMES; do not delete it from the repository."
    exit 1
fi

# The name would survive inside the binary if a resource were compiled in.
if grep -rqs "sample-scenario.fixture.json" "$APP"/*.car 2>/dev/null; then
    echo "FAIL: fixture found inside a compiled asset catalog"
    exit 1
fi

# Phase 2.4C's synthetic Bank Inbox state is source-only and guarded by
# `#if DEBUG`. These exact sentinels prove neither it nor a copied backend
# payload survived Release compilation/resource processing.
#
# The sync service URL is deliberately NOT on this list any more. From Phase
# 2.4D the app really does talk to that host, and the address is not a secret:
# the service authenticates callers by device signature, so knowing where it
# lives grants nothing. What must stay out is anything that would let a reader
# of the binary *act*: an admin credential, a bank secret, provider-internal
# identifiers, or the synthetic fixture's personal-shaped figures.
#
# A sentinel standing in for a *Swift literal* must be at least 16 UTF-8
# bytes. Swift stores a shorter literal inline in the code that builds it
# rather than as a string in the binary, so grep cannot find it even when it
# is compiled in — a check that can never fail. `obs-streaming` (13 bytes)
# was exactly that, and it hid the fact that the longer ids beside it in the
# visual-validation switch really were shipping in Release. The short entries
# below stay useful because they would arrive as payload or resource text
# (a copied backend response, a plist key), which is stored verbatim.
FORBIDDEN_RELEASE_STRINGS=(
    "Synthetic Neobank"
    "acct_neobank_eur"
    "obs-paypal-unresolved"
    "obs-bank-merchant"
    "balance-bank-clbd"
    "synthetic_same_amount_window"
    "identification_hash"
    "identification_hashes"
    "entry_reference"
    "ADMIN_API_TOKEN"
    "ENABLE_BANKING_APP_ID"
    "ENABLE_BANKING_PRIVATE_KEY"
    "INTERNAL_IDENTITY_KEY"
    "BEGIN RSA PRIVATE KEY"
    "BEGIN PRIVATE KEY"
    "session_account_uid"
    "Psu-Ip-Address"
    "CT-BNP-"
    "CT-PPL-"
    "CT-RVL-"
    "HCIPrototypeNeedsReviewQueue"
    "HCI-Insights-Week-Fixture"
    "HCI-PROTOTYPE-FIXTURE"
)

for value in "${FORBIDDEN_RELEASE_STRINGS[@]}"; do
    if grep -aRqs -- "$value" "$APP"; then
        echo "FAIL: forbidden Release sentinel found: $value"
        exit 1
    fi
done

# The endpoint is expected in Release from 2.4D on. Its absence would mean a
# build that silently cannot sync, which is worth failing over just as loudly.
if ! grep -aRqs -- "finance-bank-sync" "$APP"; then
    echo "FAIL: the Release bundle carries no sync endpoint; BANK_SYNC_BASE_URL did not substitute"
    exit 1
fi

# The service must be reached over TLS. A cleartext URL compiled into the app
# would send a signed request, and the signature with it, over a readable link.
if grep -aRqs -- "http://finance-bank-sync" "$APP"; then
    echo "FAIL: cleartext sync endpoint in the Release bundle"
    exit 1
fi

echo "PASS: no private history, sample fixture, repository documentation, bank preview, provider identity, bank secret or admin credential in Release"
find "$APP" -maxdepth 1 -type f -o -maxdepth 1 -type d | sed "s|$APP|  FinanceApp.app|"
