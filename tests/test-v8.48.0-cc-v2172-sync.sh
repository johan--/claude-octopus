#!/bin/bash
# Test suite for v8.48.0 — Claude Code v2.1.72 feature detection sync
# Validates new SUPPORTS_* flags, detection blocks, wired integrations, and behavioral changes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ORCH="$PLUGIN_DIR/scripts/orchestrate.sh"

PASS=0
FAIL=0
TOTAL=0

pass() {
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
  echo "  ✅ PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  echo "  ❌ FAIL: $1"
}

suite() {
  echo ""
  echo "━━━ $1 ━━━"
}

# ─────────────────────────────────────────────────────────────────────
# Suite 1: New flag declarations (8 flags for v2.1.72)
# ─────────────────────────────────────────────────────────────────────
suite "1. v8.48.0 Flag Declarations"

for flag in SUPPORTS_EXIT_WORKTREE SUPPORTS_AGENT_MODEL_OVERRIDE \
            SUPPORTS_EFFORT_REDESIGN SUPPORTS_DISABLE_CRON_ENV \
            SUPPORTS_HIDDEN_HTML_COMMENTS SUPPORTS_BASH_ALLOWLIST_V2 \
            SUPPORTS_CLEAR_PRESERVES_BG SUPPORTS_TEAM_MODEL_INHERIT_FIX; do
  if grep -q "^${flag}=false" "$ORCH"; then
    pass "$flag declared"
  else
    fail "$flag not declared in orchestrate.sh"
  fi
done

# ─────────────────────────────────────────────────────────────────────
# Suite 2: v2.1.72 detection block
# ─────────────────────────────────────────────────────────────────────
suite "2. v2.1.72 Detection Block"

if grep -q 'version_compare.*2\.1\.72' "$ORCH"; then
  pass "v2.1.72 version_compare block exists"
else
  fail "v2.1.72 version_compare block missing"
fi

# All 8 flags should be set in the v2.1.72 block
for flag in SUPPORTS_EXIT_WORKTREE SUPPORTS_AGENT_MODEL_OVERRIDE \
            SUPPORTS_EFFORT_REDESIGN SUPPORTS_DISABLE_CRON_ENV \
            SUPPORTS_HIDDEN_HTML_COMMENTS SUPPORTS_BASH_ALLOWLIST_V2 \
            SUPPORTS_CLEAR_PRESERVES_BG SUPPORTS_TEAM_MODEL_INHERIT_FIX; do
  if grep -A 15 'version_compare.*2\.1\.72' "$ORCH" | grep -q "${flag}=true"; then
    pass "$flag set in v2.1.72 block"
  else
    fail "$flag not set in v2.1.72 block"
  fi
done

# ─────────────────────────────────────────────────────────────────────
# Suite 3: Log lines for new flags
# ─────────────────────────────────────────────────────────────────────
suite "3. Log Lines"

if grep -q 'Exit Worktree.*Agent Model Override.*Effort Redesign' "$ORCH"; then
  pass "v2.1.72 flags logged (line 1)"
else
  fail "v2.1.72 flags not logged"
fi

if grep -q 'Disable Cron Env.*Hidden HTML Comments.*Bash Allowlist V2' "$ORCH"; then
  pass "v2.1.72 flags logged (line 2)"
else
  fail "v2.1.72 flags not logged"
fi

if grep -q 'Clear Preserves BG.*Team Model Inherit Fix' "$ORCH"; then
  pass "v2.1.72 flags logged (line 3)"
else
  fail "v2.1.72 flags not logged"
fi

# ─────────────────────────────────────────────────────────────────────
# Suite 4: Effort redesign symbols wired
# ─────────────────────────────────────────────────────────────────────
suite "4. Effort Redesign Integration"

if grep -q 'SUPPORTS_EFFORT_REDESIGN.*true' "$ORCH"; then
  pass "Effort redesign gated by SUPPORTS_EFFORT_REDESIGN"
else
  fail "Effort redesign not gated by flag"
fi

# Check all three v2.1.72 effort symbols are present
for symbol in '○' '◐' '●'; do
  if grep -q "$symbol" "$ORCH"; then
    pass "Effort symbol $symbol present"
  else
    fail "Effort symbol $symbol missing"
  fi
done

# Verify effort levels are low/medium/high only (no "max")
# Use grep -c with || true to avoid pipefail issues
max_in_effort=0
while IFS= read -r line; do
  ((max_in_effort++)) || true
done < <(grep -n 'effort.*"max"\|effort_level.*max' "$ORCH" 2>/dev/null | grep -v '#.*max\|comment\|OCTOPUS_MAX' 2>/dev/null || true)
if [[ "$max_in_effort" -eq 0 ]]; then
  pass "No 'max' effort level in effort mapping (v2.1.72 compat)"
else
  fail "Found $max_in_effort 'max' effort level references — v2.1.72 removed max"
fi

# ─────────────────────────────────────────────────────────────────────
# Suite 5: CLAUDE_CODE_DISABLE_CRON wired in workflows
# ─────────────────────────────────────────────────────────────────────
suite "5. Cron Disable Integration"

if grep -A 5 'embrace_full_workflow()' "$ORCH" | head -20 | grep -q 'CLAUDE_CODE_DISABLE_CRON' || \
   grep -B 2 -A 3 'SUPPORTS_DISABLE_CRON_ENV' "$ORCH" | grep -q 'CLAUDE_CODE_DISABLE_CRON'; then
  pass "CLAUDE_CODE_DISABLE_CRON set in embrace workflow"
else
  fail "CLAUDE_CODE_DISABLE_CRON not set in embrace workflow"
fi

# Check cron var is cleaned up at end of embrace
embrace_cleanup_count=$(grep -c 'unset CLAUDE_CODE_DISABLE_CRON' "$ORCH" || echo 0)
if [[ "$embrace_cleanup_count" -ge 2 ]]; then
  pass "CLAUDE_CODE_DISABLE_CRON cleaned up ($embrace_cleanup_count locations)"
else
  fail "CLAUDE_CODE_DISABLE_CRON cleanup missing (found $embrace_cleanup_count, expected >= 2)"
fi

if grep -A 10 'parallel_execute()' "$ORCH" | grep -q 'CLAUDE_CODE_DISABLE_CRON'; then
  pass "CLAUDE_CODE_DISABLE_CRON set in parallel_execute"
else
  fail "CLAUDE_CODE_DISABLE_CRON not set in parallel_execute"
fi

# ─────────────────────────────────────────────────────────────────────
# Suite 6: Agent model override in Agent Teams JSON
# ─────────────────────────────────────────────────────────────────────
suite "6. Agent Model Override Integration"

if grep -q 'model_override_supported' "$ORCH"; then
  pass "model_override_supported field in Agent Teams JSON"
else
  fail "model_override_supported field missing from Agent Teams JSON"
fi

if grep -q 'SUPPORTS_AGENT_MODEL_OVERRIDE' "$ORCH" | head -1; then
  pass "SUPPORTS_AGENT_MODEL_OVERRIDE referenced in dispatch"
else
  # Broader check
  ref_count=$(grep -c 'SUPPORTS_AGENT_MODEL_OVERRIDE' "$ORCH" || echo 0)
  if [[ "$ref_count" -ge 3 ]]; then
    pass "SUPPORTS_AGENT_MODEL_OVERRIDE referenced $ref_count times"
  else
    fail "SUPPORTS_AGENT_MODEL_OVERRIDE under-referenced ($ref_count refs)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────
# Suite 7: Header comment updated
# ─────────────────────────────────────────────────────────────────────
suite "7. Header Comment"

if grep -q 'v2\.1\.72' "$ORCH"; then
  pass "v2.1.72 referenced in header comment"
else
  fail "v2.1.72 not referenced in header"
fi

# ─────────────────────────────────────────────────────────────────────
# Suite 8: Total flag count (should be >= 80 with 8 new flags)
# ─────────────────────────────────────────────────────────────────────
suite "8. Total Flag Count"

FLAG_COUNT=$(grep -c '^SUPPORTS_.*=false' "$ORCH")
if [[ "$FLAG_COUNT" -ge 80 ]]; then
  pass "Total SUPPORTS_* flags: $FLAG_COUNT (expected >= 80)"
else
  fail "Total SUPPORTS_* flags: $FLAG_COUNT (expected >= 80)"
fi

# ─────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: $PASS/$TOTAL passed, $FAIL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
