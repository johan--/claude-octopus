#!/bin/bash
# Test suite for v8.40.0 — Claude Code v2.1.70-71 feature detection sync
# Validates new SUPPORTS_* flags, detection blocks, and wired integrations

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ORCH="$PLUGIN_DIR/scripts/orchestrate.sh"
HOOK="$PLUGIN_DIR/hooks/subagent-result-capture.sh"

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
# Suite 1: New flag declarations (6 flags)
# ─────────────────────────────────────────────────────────────────────
suite "1. v8.40.0 Flag Declarations"

for flag in SUPPORTS_VSCODE_PLAN_VIEW SUPPORTS_IMAGE_CACHE_COMPACTION \
            SUPPORTS_RENAME_WHILE_PROCESSING SUPPORTS_NATIVE_LOOP \
            SUPPORTS_RUNTIME_DEBUG SUPPORTS_FAST_BRIDGE_RECONNECT; do
  if grep -q "^${flag}=false" "$ORCH"; then
    pass "$flag declared"
  else
    fail "$flag not declared"
  fi
done

# ─────────────────────────────────────────────────────────────────────
# Suite 2: Detection blocks for v2.1.70 and v2.1.71
# ─────────────────────────────────────────────────────────────────────
suite "2. Version Detection Blocks"

if grep -q 'version_compare.*2\.1\.70' "$ORCH"; then
  pass "v2.1.70 detection block exists"
else
  fail "v2.1.70 detection block missing"
fi

if grep -q 'version_compare.*2\.1\.71' "$ORCH"; then
  pass "v2.1.71 detection block exists"
else
  fail "v2.1.71 detection block missing"
fi

# Verify flags are set in the right version blocks
if grep -A5 '2\.1\.70' "$ORCH" | grep -q 'SUPPORTS_VSCODE_PLAN_VIEW=true'; then
  pass "SUPPORTS_VSCODE_PLAN_VIEW set in v2.1.70 block"
else
  fail "SUPPORTS_VSCODE_PLAN_VIEW not in v2.1.70 block"
fi

if grep -A5 '2\.1\.71' "$ORCH" | grep -q 'SUPPORTS_NATIVE_LOOP=true'; then
  pass "SUPPORTS_NATIVE_LOOP set in v2.1.71 block"
else
  fail "SUPPORTS_NATIVE_LOOP not in v2.1.71 block"
fi

if grep -A5 '2\.1\.71' "$ORCH" | grep -q 'SUPPORTS_RUNTIME_DEBUG=true'; then
  pass "SUPPORTS_RUNTIME_DEBUG set in v2.1.71 block"
else
  fail "SUPPORTS_RUNTIME_DEBUG not in v2.1.71 block"
fi

if grep -A5 '2\.1\.71' "$ORCH" | grep -q 'SUPPORTS_FAST_BRIDGE_RECONNECT=true'; then
  pass "SUPPORTS_FAST_BRIDGE_RECONNECT set in v2.1.71 block"
else
  fail "SUPPORTS_FAST_BRIDGE_RECONNECT not in v2.1.71 block"
fi

# ─────────────────────────────────────────────────────────────────────
# Suite 3: Logging for new flags
# ─────────────────────────────────────────────────────────────────────
suite "3. Flag Logging"

if grep -q 'VSCode Plan:.*SUPPORTS_VSCODE_PLAN_VIEW' "$ORCH"; then
  pass "New flags logged in detection output"
else
  fail "New flags not logged"
fi

if grep -q 'Native Loop:.*SUPPORTS_NATIVE_LOOP' "$ORCH"; then
  pass "Native Loop flag logged"
else
  fail "Native Loop flag not logged"
fi

# ─────────────────────────────────────────────────────────────────────
# Suite 4: Wired flag — SUPPORTS_EFFORT_CALLOUT
# ─────────────────────────────────────────────────────────────────────
suite "4. Effort Callout Wiring"

if grep -q 'SUPPORTS_EFFORT_CALLOUT.*true' "$ORCH" | head -1 && \
   grep -q 'log "USER".*Effort' "$ORCH"; then
  pass "SUPPORTS_EFFORT_CALLOUT wired to user-visible effort display"
else
  fail "SUPPORTS_EFFORT_CALLOUT not wired"
fi

# ─────────────────────────────────────────────────────────────────────
# Suite 5: Wired flag — SUPPORTS_HOOK_AGENT_FIELDS
# ─────────────────────────────────────────────────────────────────────
suite "5. Hook Agent Fields Wiring"

if grep -q 'agent_type' "$HOOK"; then
  pass "subagent-result-capture.sh captures agent_type"
else
  fail "subagent-result-capture.sh missing agent_type capture"
fi

if grep -q 'Agent-Type' "$HOOK"; then
  pass "agent_type written to result file"
else
  fail "agent_type not written to result file"
fi

# ─────────────────────────────────────────────────────────────────────
# Suite 6: Wired flag — SUPPORTS_MEMORY_LEAK_FIXES
# ─────────────────────────────────────────────────────────────────────
suite "6. Memory Leak Fixes Wiring"

if grep -q 'leak_safe_boost' "$ORCH" && \
   grep -q 'SUPPORTS_MEMORY_LEAK_FIXES.*true' "$ORCH"; then
  pass "SUPPORTS_MEMORY_LEAK_FIXES wired to timeout boost"
else
  fail "SUPPORTS_MEMORY_LEAK_FIXES not wired to timeout boost"
fi

# ─────────────────────────────────────────────────────────────────────
# Suite 7: Total flag count validation
# ─────────────────────────────────────────────────────────────────────
suite "7. Flag Count"

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
