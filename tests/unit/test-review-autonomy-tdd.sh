#!/usr/bin/env bash
# Test review workflow guidance for autonomous codegen and TDD verification

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW_COMMAND="$PROJECT_ROOT/.claude/commands/review.md"
REVIEW_SKILL="$PROJECT_ROOT/.claude/skills/skill-code-review.md"

TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

pass() {
    TEST_COUNT=$((TEST_COUNT + 1))
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "PASS: $1"
}

fail() {
    TEST_COUNT=$((TEST_COUNT + 1))
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "FAIL: $1"
    echo "  $2"
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    local label="$3"

    if grep -qiE "$pattern" "$file"; then
        pass "$label"
    else
        fail "$label" "Missing pattern '$pattern' in $file"
    fi
}

assert_contains "$REVIEW_COMMAND" 'header:\s*"Provenance"|Autonomous / Dark Factory|AI-assisted' \
    "review command asks for implementation mode"
assert_contains "$REVIEW_COMMAND" 'Autonomous / Dark Factory' \
    "review command offers autonomous review mode"
assert_contains "$REVIEW_COMMAND" 'TDD discipline|TDD compliance|test-first' \
    "review command surfaces TDD-focused review concerns"

assert_contains "$REVIEW_SKILL" '^## Autonomous Implementation Review' \
    "review skill has autonomous implementation review section"
assert_contains "$REVIEW_SKILL" 'TDD Evidence|failing test|test-first' \
    "review skill checks for TDD evidence"
assert_contains "$REVIEW_SKILL" 'unknown.*not assumed|do not assume TDD' \
    "review skill treats missing TDD evidence as unknown"

echo ""
echo "Total: $TEST_COUNT"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
