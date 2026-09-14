#!/bin/bash
# Shared helpers for the Scripts/ test and build wrappers.
#
# The wrappers keep full validation output on disk rather than on the terminal
# while running the real command unchanged. They filter output. They never
# skip a test, hide a failure, silence a warning, or alter an exit code.

set -uo pipefail

REPO_NAME="${REPO_NAME:?lib.sh needs REPO_NAME}"
LOG_ROOT="${FINANCE_LOG_DIR:-${TMPDIR:-/tmp}/finance-logs}/$REPO_NAME"
mkdir -p "$LOG_ROOT"
RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

log_path() { echo "$LOG_ROOT/${RUN_STAMP}-$1.log"; }

# rule <char> — a separator narrow enough for a terminal.
rule() { printf '%s\n' "------------------------------------------------------------"; }

# tail_failures <log> <n> — the last n lines, for a failed run only.
tail_failures() {
    echo "--- last $2 log lines ---"
    tail -n "$2" "$1"
}

# prune old logs so the directory does not grow without bound.
prune_logs() {
    find "$LOG_ROOT" -name '*.log' -type f -mtime +7 -delete 2>/dev/null || true
}

# swift_test_counts <log>
#
# Sets XCTEST_N, XCTEST_LINE, SWIFTTESTING_N, SWIFTTESTING_LINE, TESTS_TOTAL.
#
# A Swift target can carry XCTest cases, swift-testing cases, or both, and each
# framework prints its own final tally. Reading only one of them reports 0 tests
# for a suite that ran hundreds — which is how a green run hides a scheme that
# tests nothing.
swift_test_counts() {
    local log="$1"
    XCTEST_LINE=$(grep -A1 -E "Test Suite 'All tests' (passed|failed)" "$log" 2>/dev/null \
        | tail -1 | sed 's/^[[:space:]]*//')
    XCTEST_N=$(printf '%s' "$XCTEST_LINE" | grep -oE 'Executed [0-9]+' | grep -oE '[0-9]+')
    XCTEST_N=${XCTEST_N:-0}

    SWIFTTESTING_LINE=$(grep -oE "Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed)" "$log" 2>/dev/null | tail -1)
    SWIFTTESTING_N=$(printf '%s' "$SWIFTTESTING_LINE" | grep -oE 'with [0-9]+' | grep -oE '[0-9]+')
    SWIFTTESTING_N=${SWIFTTESTING_N:-0}

    TESTS_TOTAL=$((XCTEST_N + SWIFTTESTING_N))
}

# report_test_counts — prints the tallies that are non-zero, and shouts when a
# run that "succeeded" executed nothing at all.
report_test_counts() {
    if [ "$TESTS_TOTAL" -eq 0 ]; then
        echo "TESTS     0 executed"
        echo "WARNING   the command reported success but ran no tests — check the"
        echo "          scheme's test action and the destination before believing it"
        return
    fi
    echo "TESTS     $TESTS_TOTAL executed"
    [ "$XCTEST_N" -gt 0 ] && echo "          XCTest         $XCTEST_LINE"
    [ "$SWIFTTESTING_N" -gt 0 ] && echo "          swift-testing  $SWIFTTESTING_LINE"
}
