# /octo:review Multi-LLM Redesign — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild `/octo:review` as a multi-LLM competitor to Claude Code's managed Code Review service, with a 3-round parallel fleet (Codex + Gemini + Claude + Perplexity), inline PR comments, `REVIEW.md` support, and a canonical `review_run()` backend.

**Architecture:** A new `review_run()` function in `orchestrate.sh` serves as the single backend for all entrypoints (command, MCP, OpenClaw). It runs three sequential rounds: parallel specialist agents (Round 1), a Codex verifier that filters false positives (Round 2), and Claude synthesis that formats findings for inline PR comments or terminal output (Round 3).

**Tech Stack:** Bash (orchestrate.sh), TypeScript (MCP + OpenClaw), Markdown (command/skill files), `gh` CLI for PR comments, `jq` for JSON findings.

**Spec:** `docs/superpowers/specs/2026-03-11-octo-review-multi-llm-design.md`

---

## Chunk 1: orchestrate.sh — Core Backend

**Files:**
- Modify: `scripts/orchestrate.sh` (insert new functions in the Code Review section near line 7930, update dispatch near line 21200)

---

### Task 1: Write failing tests for `parse_review_md()`

**Files:**
- Create: `tests/unit/test-review-run.sh`

- [ ] **Step 1: Create test file with boilerplate**

```bash
#!/usr/bin/env bash
# Tests for review_run() pipeline, REVIEW.md parsing, fleet fallback, severity output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORCHESTRATE="$PROJECT_ROOT/scripts/orchestrate.sh"

TEST_COUNT=0; PASS_COUNT=0; FAIL_COUNT=0

pass() { TEST_COUNT=$((TEST_COUNT+1)); PASS_COUNT=$((PASS_COUNT+1)); echo "PASS: $1"; }
fail() { TEST_COUNT=$((TEST_COUNT+1)); FAIL_COUNT=$((FAIL_COUNT+1)); echo "FAIL: $1 — $2"; }

assert_contains() {
  local output="$1" pattern="$2" label="$3"
  echo "$output" | grep -qE "$pattern" && pass "$label" || fail "$label" "missing: $pattern"
}

assert_not_contains() {
  local output="$1" pattern="$2" label="$3"
  echo "$output" | grep -qE "$pattern" && fail "$label" "should not contain: $pattern" || pass "$label"
}

# ── parse_review_md ──────────────────────────────────────────────────────────

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
```

- [ ] **Step 2: Add parse_review_md tests**

Append to `tests/unit/test-review-run.sh`:

```bash
TEST_REVIEW_MD="$TMPDIR_TEST/REVIEW.md"
cat > "$TEST_REVIEW_MD" <<'EOF'
# Code Review Guidelines

## Always check
- New API endpoints have corresponding integration tests
- Database migrations are backward-compatible

## Style
- Prefer early returns over nested conditionals

## Skip
- Generated files under src/gen/
- Formatting-only changes in *.lock files
EOF

# Source only the parse_review_md function
# (static grep — orchestrate.sh cannot be sourced safely)

assert_contains "$(grep -A1 'Always check' "$TEST_REVIEW_MD")" \
  "integration tests" "parse_review_md: always_check section readable"

assert_contains "$(grep -A1 'Style' "$TEST_REVIEW_MD")" \
  "early returns" "parse_review_md: style section readable"

assert_contains "$(grep -A1 'Skip' "$TEST_REVIEW_MD")" \
  "src/gen" "parse_review_md: skip section readable"
```

- [ ] **Step 3: Add build_review_fleet and review profile tests**

Append to `tests/unit/test-review-run.sh`:

```bash
# ── build_review_fleet ───────────────────────────────────────────────────────

assert_contains "$(grep -c 'build_review_fleet' "$ORCHESTRATE" 2>/dev/null || echo 0)" \
  "[1-9]" "build_review_fleet: function exists in orchestrate.sh"

assert_contains "$(grep -c 'review_run' "$ORCHESTRATE" 2>/dev/null || echo 0)" \
  "[1-9]" "review_run: function exists in orchestrate.sh"

# ── severity model ───────────────────────────────────────────────────────────

assert_contains "$(grep 'normal\|nit\|pre.existing' "$ORCHESTRATE" 2>/dev/null | head -5)" \
  "normal|nit|pre.existing" "severity model: all three levels referenced in orchestrate.sh"

# ── code-review command dispatch ─────────────────────────────────────────────

assert_contains "$(grep 'code-review)' "$ORCHESTRATE" 2>/dev/null | head -3)" \
  "code-review" "dispatch: code-review command exists in main case"

# ── post_inline_comments ─────────────────────────────────────────────────────

assert_contains "$(grep -c 'post_inline_comments' "$ORCHESTRATE" 2>/dev/null || echo 0)" \
  "[1-9]" "post_inline_comments: function exists in orchestrate.sh"

# ── REVIEW.md command file references ────────────────────────────────────────

REVIEW_CMD="$PROJECT_ROOT/.claude/commands/review.md"
assert_contains "$(cat "$REVIEW_CMD" 2>/dev/null)" \
  "REVIEW\.md" "review command: references REVIEW.md"
assert_contains "$(cat "$REVIEW_CMD" 2>/dev/null)" \
  "code-review|review_run" "review command: calls code-review or review_run backend"

# ── MCP schema ───────────────────────────────────────────────────────────────

MCP_INDEX="$PROJECT_ROOT/mcp-server/src/index.ts"
assert_contains "$(cat "$MCP_INDEX" 2>/dev/null)" \
  "focus|provenance|autonomy|publish|debate" "mcp: review tool has typed profile fields"

# ── OpenClaw schema ──────────────────────────────────────────────────────────

OPENCLAW_INDEX="$PROJECT_ROOT/openclaw/src/index.ts"
assert_contains "$(cat "$OPENCLAW_INDEX" 2>/dev/null)" \
  "focus|provenance|autonomy|publish|debate" "openclaw: review tool has typed profile fields"

# ── summary ──────────────────────────────────────────────────────────────────

echo ""
echo "Total: $TEST_COUNT | Passed: $PASS_COUNT | Failed: $FAIL_COUNT"
[[ $FAIL_COUNT -gt 0 ]] && exit 1 || exit 0
```

- [ ] **Step 4: Run tests — verify they all fail**

```bash
bash tests/unit/test-review-run.sh
```

Expected: multiple FAIL lines (functions don't exist yet). The `parse_review_md` REVIEW.md content tests may pass — that's fine.

---

### Task 2: Implement `parse_review_md()`

**Files:**
- Modify: `scripts/orchestrate.sh` — insert after the `# REVIEW & AUDIT COMMANDS` section header (~line 7930)

- [ ] **Step 1: Find insertion point**

```bash
grep -n "REVIEW & AUDIT COMMANDS\|approve_review\|reject_review" \
  scripts/orchestrate.sh | head -5
```

Note the line number of the first `approve_review()` function definition. Insert **before** it.

- [ ] **Step 2: Add `parse_review_md()` to orchestrate.sh**

Insert at the insertion point found above:

```bash
# ═══════════════════════════════════════════════════════════════════════════
# CODE REVIEW PIPELINE (v8.50.0)
# review_run() — multi-LLM competitor to CC Code Review managed service
# ═══════════════════════════════════════════════════════════════════════════

# parse_review_md: reads REVIEW.md from repo root, outputs directive vars
# WHY: CC Code Review supports REVIEW.md for customization; we match that
# convention so repos already configured for CC work with /octo:review too.
parse_review_md() {
    local repo_root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local review_md="$repo_root/REVIEW.md"

    REVIEW_ALWAYS_CHECK=""
    REVIEW_STYLE_RULES=""
    REVIEW_SKIP_PATTERNS=""

    [[ ! -f "$review_md" ]] && return 0

    local section=""
    while IFS= read -r line; do
        case "$line" in
            "## Always check"|"## Always Check") section="always" ;;
            "## Style")                          section="style" ;;
            "## Skip")                           section="skip" ;;
            "## "*)                              section="" ;;
            "- "*)
                local item="${line#- }"
                case "$section" in
                    always) REVIEW_ALWAYS_CHECK+="${item}"$'\n' ;;
                    style)  REVIEW_STYLE_RULES+="${item}"$'\n' ;;
                    skip)   REVIEW_SKIP_PATTERNS+="${item}"$'\n' ;;
                esac
                ;;
        esac
    done < "$review_md"

    log DEBUG "parse_review_md: always=$(echo "$REVIEW_ALWAYS_CHECK" | wc -l) style=$(echo "$REVIEW_STYLE_RULES" | wc -l) skip=$(echo "$REVIEW_SKIP_PATTERNS" | wc -l)"
}
```

- [ ] **Step 3: Run tests — parse_review_md tests should still pass**

```bash
bash tests/unit/test-review-run.sh 2>/dev/null | grep -E "PASS|FAIL"
```

---

### Task 3: Implement `build_review_fleet()`

- [ ] **Step 1: Add `build_review_fleet()` immediately after `parse_review_md()`**

```bash
# build_review_fleet: builds active agent list based on available providers
# WHY: fleet is dynamic — if Perplexity is not configured, fall back to
# Gemini search; if Codex is unavailable, fall back to claude-sonnet.
# Returns a newline-separated list of "agent_type:role:specialty" triples.
# NOTE: Uses command -v for provider detection — safe with set -euo pipefail.
# AVAILABLE_PROVIDERS is not exported by preflight; detect inline instead.
build_review_fleet() {
    local fleet=""

    # logic-reviewer: Codex (correctness/logic) → claude-sonnet fallback
    if command -v codex >/dev/null 2>&1; then
        fleet+="codex:logic-reviewer:correctness and logic bugs, edge cases, regressions"$'\n'
    else
        fleet+="claude-sonnet:logic-reviewer:correctness and logic bugs, edge cases, regressions"$'\n'
    fi

    # security-reviewer: Gemini (security/OWASP) → claude-sonnet fallback
    if command -v gemini >/dev/null 2>&1; then
        fleet+="gemini:security-reviewer:OWASP vulnerabilities, injection, auth flaws, data exposure"$'\n'
    else
        fleet+="claude-sonnet:security-reviewer:OWASP vulnerabilities, injection, auth flaws, data exposure"$'\n'
    fi

    # arch-reviewer: claude-sonnet (always available)
    fleet+="claude-sonnet:arch-reviewer:architecture, integration, API contracts, breaking changes"$'\n'

    # cve-reviewer: Perplexity → Gemini search → claude WebSearch → skip
    if command -v perplexity >/dev/null 2>&1 || [[ -n "${PERPLEXITY_API_KEY:-}" ]]; then
        fleet+="perplexity:cve-reviewer:known CVEs, library advisories, live web search"$'\n'
    elif command -v gemini >/dev/null 2>&1; then
        fleet+="gemini:cve-reviewer:known CVEs via web search, library advisories"$'\n'
        log INFO "CVE lookup: Perplexity unavailable, using Gemini search"
    else
        fleet+="claude-sonnet:cve-reviewer:known CVEs via WebSearch tool, library advisories"$'\n'
        log WARN "CVE lookup: no dedicated web-search provider, using Claude WebSearch (degraded)"
    fi

    echo "$fleet"
}
```

- [ ] **Step 2: Run tests**

```bash
bash tests/unit/test-review-run.sh 2>/dev/null | grep -E "PASS|FAIL"
```

`build_review_fleet` test should now pass.

---

### Task 4: Implement `review_run()` — the canonical backend

- [ ] **Step 1: Add `review_run()` after `build_review_fleet()`**

```bash
# review_run: canonical 3-round multi-LLM code review pipeline
# WHY: replaces the single-model "codex exec review" dispatch with a
# parallel fleet (Round 1) + verification (Round 2) + synthesis (Round 3)
# that competes with CC Code Review's managed service.
#
# Args: JSON profile string with fields:
#   target, focus, provenance, autonomy, publish, debate
review_run() {
    local profile_json="${1:-{}}"

    # Parse profile fields (with defaults)
    local target focus provenance autonomy publish debate
    target=$(echo "$profile_json"     | jq -r '.target     // "staged"')
    focus=$(echo "$profile_json"      | jq -r '.focus      // ["correctness"]  | join(",")')
    provenance=$(echo "$profile_json" | jq -r '.provenance // "unknown"')
    autonomy=$(echo "$profile_json"   | jq -r '.autonomy   // "supervised"')
    publish=$(echo "$profile_json"    | jq -r '.publish    // "ask"')
    debate=$(echo "$profile_json"     | jq -r '.debate     // "auto"')

    local timestamp
    timestamp=$(date +%s)
    local results_dir="${RESULTS_DIR:-$HOME/.claude-octopus/results}"
    local findings_file="$results_dir/review-findings-${timestamp}.json"
    mkdir -p "$results_dir"

    log INFO "review_run: target=$target focus=$focus provenance=$provenance autonomy=$autonomy"

    # ── REVIEW.md ────────────────────────────────────────────────────────────
    parse_review_md
    local review_context=""
    if [[ -n "$REVIEW_ALWAYS_CHECK" || -n "$REVIEW_STYLE_RULES" ]]; then
        review_context="Repository review rules (from REVIEW.md):\nAlways check:\n${REVIEW_ALWAYS_CHECK}\nStyle:\n${REVIEW_STYLE_RULES}"
    fi

    # ── Collect diff ─────────────────────────────────────────────────────────
    local diff_content
    case "$target" in
        staged)       diff_content=$(git diff --cached 2>/dev/null || echo "") ;;
        working-tree) diff_content=$(git diff 2>/dev/null || echo "") ;;
        [0-9]*)       diff_content=$(gh pr diff "$target" 2>/dev/null || echo "") ;;
        *)            diff_content=$(git diff HEAD -- "$target" 2>/dev/null || echo "") ;;
    esac

    if [[ -z "$diff_content" ]]; then
        log WARN "review_run: no diff found for target=$target"
        echo '{"findings":[],"message":"No changes found to review"}' > "$findings_file"
        render_terminal_report "$findings_file"
        return 0
    fi

    # Apply skip patterns from REVIEW.md (pre-filter before spending tokens)
    if [[ -n "$REVIEW_SKIP_PATTERNS" ]]; then
        while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue
            diff_content=$(echo "$diff_content" | grep -v "$pattern" || echo "$diff_content")
        done <<< "$REVIEW_SKIP_PATTERNS"
    fi

    # ── ROUND 1: Parallel agent fleet ────────────────────────────────────────
    log INFO "review_run: Round 1 — parallel specialist fleet"
    local fleet
    fleet=$(build_review_fleet)

    local agent_prompt_base
    agent_prompt_base="You are a code reviewer. Review the following diff and return ONLY a JSON object with a 'findings' array.

Each finding must have: file (string), line (integer), severity (normal|nit|pre-existing), category (string), title (string), detail (string), confidence (0.0-1.0).

Severity guide:
- normal: bug that should be fixed before merging (🔴)
- nit: minor issue, not blocking (🟡)
- pre-existing: bug not introduced by this PR (🟣)

${review_context}

Provenance: ${provenance}
$([ "$provenance" = "autonomous" ] || [ "$provenance" = "ai-assisted" ] && echo "ELEVATED RIGOR: Check for TDD evidence, placeholder logic, unwired components, speculative abstractions." || echo "")

Diff to review:
\`\`\`
${diff_content}
\`\`\`

Return ONLY valid JSON. No prose, no markdown fences."

    local round1_files=()
    while IFS=: read -r agent_type role specialty; do
        [[ -z "$agent_type" ]] && continue
        local task_id="review-r1-${role}-${timestamp}"
        local result_file="$results_dir/${task_id}.json"
        round1_files+=("$result_file")

        local agent_prompt="You are the ${role} specialist. Focus on: ${specialty}.

${agent_prompt_base}"

        spawn_agent "$agent_type" "$agent_prompt" "$task_id" "$role" "review" &
    done <<< "$fleet"

    # Wait for all Round 1 agents
    wait
    log INFO "review_run: Round 1 complete"

    # Collect Round 1 findings
    local all_findings="[]"
    for f in "${round1_files[@]}"; do
        [[ ! -f "$f" ]] && continue
        local agent_findings
        agent_findings=$(jq -r '.findings // []' "$f" 2>/dev/null || echo "[]")
        all_findings=$(echo "$all_findings $agent_findings" | jq -s 'add' 2>/dev/null || echo "$all_findings")
    done

    # ── ROUND 2: Verification ─────────────────────────────────────────────────
    log INFO "review_run: Round 2 — verification"
    local verifier_prompt
    verifier_prompt="You are a code review verifier. For each finding below, check whether it is a real bug (confirmed), a false positive, or needs debate (uncertain/conflicting).

Return ONLY JSON: same findings array with an added 'verdict' field: confirmed|false-positive|needs-debate.
Also add 'pre_existing_newly_reachable': true if a pre-existing finding becomes reachable via this PR's changes.

Diff:
\`\`\`
${diff_content}
\`\`\`

Findings to verify:
$(echo "$all_findings" | jq -c '.')

Return ONLY valid JSON with 'findings' array including verdict field."

    local verified_findings
    verified_findings=$(run_agent_sync "codex" "$verifier_prompt" 180 "code-reviewer" "review")

    # Filter false positives
    local confirmed_findings
    confirmed_findings=$(echo "$verified_findings" | \
        jq '.findings | map(select(.verdict != "false-positive"))' 2>/dev/null || \
        echo "$all_findings")

    # ── Debate gate (if enabled) ──────────────────────────────────────────────
    if [[ "$debate" != "off" ]]; then
        local debate_candidates
        debate_candidates=$(echo "$confirmed_findings" | \
            jq '[.[] | select(.verdict == "needs-debate")]' 2>/dev/null || echo "[]")
        local debate_count
        debate_count=$(echo "$debate_candidates" | jq 'length' 2>/dev/null || echo "0")
        if [[ "$debate_count" -gt 0 ]]; then
            log INFO "review_run: debating $debate_count contested findings"
            # Run 1-round adversarial debate on contested findings
            local debate_prompt="Challenge these $debate_count contested code review findings. For each, state whether it is a real bug (include) or false positive (exclude). Be adversarial.
Findings: $(echo "$debate_candidates" | jq -c '.')
Return JSON: {\"include\": [...finding titles...], \"exclude\": [...finding titles...]}"
            local debate_result
            debate_result=$(run_agent_sync "codex" "$debate_prompt" 120 "code-reviewer" "review")
            local exclude_titles
            exclude_titles=$(echo "$debate_result" | jq -r '.exclude // [] | .[]' 2>/dev/null || echo "")
            if [[ -n "$exclude_titles" ]]; then
                while IFS= read -r title; do
                    confirmed_findings=$(echo "$confirmed_findings" | \
                        jq --arg t "$title" '[.[] | select(.title != $t)]' 2>/dev/null || \
                        echo "$confirmed_findings")
                done <<< "$exclude_titles"
            fi
        fi
    fi

    # ── ROUND 3: Synthesis ────────────────────────────────────────────────────
    log INFO "review_run: Round 3 — synthesis"
    local synthesis_prompt
    synthesis_prompt="Deduplicate and rank these code review findings by severity (normal first, then nit, then pre-existing). Merge duplicate findings (same bug from multiple agents) into one entry, preserving all agent perspectives in the detail field.

Findings: $(echo "$confirmed_findings" | jq -c '.')

Return ONLY JSON: {\"findings\": [...ranked, deduplicated findings...]}"

    local final_json
    final_json=$(run_agent_sync "claude-sonnet" "$synthesis_prompt" 120 "code-reviewer" "review")

    # Write findings file
    echo "$final_json" > "$findings_file"
    log INFO "review_run: findings saved to $findings_file"

    # ── Output ────────────────────────────────────────────────────────────────
    local pr_number
    pr_number=$(gh pr view --json number -q .number 2>/dev/null || echo "")

    if [[ -n "$pr_number" && "$publish" != "never" ]]; then
        local avg_confidence
        avg_confidence=$(jq '[.findings[].confidence] | if length > 0 then add/length else 0 end' \
            "$findings_file" 2>/dev/null || echo "0")
        if [[ "$publish" == "auto" ]] && awk "BEGIN{exit !($avg_confidence >= 0.85)}"; then
            log INFO "review_run: auto-publishing to PR #$pr_number (confidence=$avg_confidence)"
            post_inline_comments "$pr_number" "$findings_file"
        elif [[ "$publish" == "ask" ]]; then
            render_terminal_report "$findings_file"
            echo ""
            echo "PR #$pr_number is open. Post findings as inline comments? (y/N)"
            read -r response
            [[ "$response" =~ ^[Yy] ]] && post_inline_comments "$pr_number" "$findings_file"
        fi
    else
        render_terminal_report "$findings_file"
    fi
}
```

- [ ] **Step 2: Run tests — review_run test should pass**

```bash
bash tests/unit/test-review-run.sh 2>/dev/null | grep -E "PASS|FAIL"
```

---

### Task 5: Implement output functions + command dispatch

- [ ] **Step 1: Add `post_inline_comments()` after `review_run()`**

```bash
# post_inline_comments: posts findings as inline PR comments via gh API
# WHY: inline line-level comments match CC Code Review's UX exactly.
# Uses gh api pull_request_review_comments for true per-line comments.
post_inline_comments() {
    local pr_number="$1"
    local findings_file="$2"

    local repo
    repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
    if [[ -z "$repo" ]]; then
        log ERROR "post_inline_comments: could not determine repo (is gh auth configured?)"
        render_terminal_report "$findings_file"
        return 1
    fi

    local commit_id
    commit_id=$(gh pr view "$pr_number" --json headRefOid -q .headRefOid 2>/dev/null || echo "")

    # Post a summary comment on the PR
    local summary
    summary=$(render_review_summary "$findings_file")
    gh pr review "$pr_number" --comment --body "$summary" 2>/dev/null || true

    # Post per-finding inline comments
    local finding_count
    finding_count=$(jq '.findings | length' "$findings_file" 2>/dev/null || echo "0")
    log INFO "post_inline_comments: posting $finding_count inline comments to PR #$pr_number"

    jq -c '.findings[]' "$findings_file" 2>/dev/null | while IFS= read -r finding; do
        local file line severity title detail
        file=$(echo "$finding"     | jq -r '.file')
        line=$(echo "$finding"     | jq -r '.line')
        severity=$(echo "$finding" | jq -r '.severity')
        title=$(echo "$finding"    | jq -r '.title')
        detail=$(echo "$finding"   | jq -r '.detail')

        local icon
        case "$severity" in
            normal)      icon="🔴" ;;
            nit)         icon="🟡" ;;
            pre-existing) icon="🟣" ;;
            *)           icon="⚪" ;;
        esac

        local body="${icon} **${title}**

${detail}

_Reviewed by /octo:review (multi-LLM fleet)_"

        gh api "repos/${repo}/pulls/${pr_number}/comments" \
            --method POST \
            -f body="$body" \
            -f commit_id="$commit_id" \
            -f path="$file" \
            -F line="$line" \
            -f side="RIGHT" 2>/dev/null || \
        log WARN "post_inline_comments: failed to post comment on $file:$line"
    done
}

# render_terminal_report: formats findings for terminal display
render_terminal_report() {
    local findings_file="$1"

    local finding_count
    finding_count=$(jq '.findings | length' "$findings_file" 2>/dev/null || echo "0")

    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│  🐙 /octo:review — Multi-LLM Code Review Results               │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""

    if [[ "$finding_count" -eq 0 ]]; then
        echo "✅ No issues found."
        return 0
    fi

    echo "Found $finding_count issue(s):"
    echo ""

    jq -c '.findings[]' "$findings_file" 2>/dev/null | while IFS= read -r finding; do
        local severity title file line detail
        severity=$(echo "$finding" | jq -r '.severity')
        title=$(echo "$finding"    | jq -r '.title')
        file=$(echo "$finding"     | jq -r '.file')
        line=$(echo "$finding"     | jq -r '.line')
        detail=$(echo "$finding"   | jq -r '.detail')

        local icon
        case "$severity" in
            normal)       icon="🔴" ;;
            nit)          icon="🟡" ;;
            pre-existing) icon="🟣" ;;
            *)            icon="⚪" ;;
        esac

        echo "${icon} ${title}"
        echo "   ${file}:${line}"
        echo "   ${detail}"
        echo ""
    done
}

# render_review_summary: short markdown summary for PR-level comment
render_review_summary() {
    local findings_file="$1"
    local normal_count nit_count preexisting_count
    normal_count=$(jq '[.findings[] | select(.severity=="normal")] | length' "$findings_file" 2>/dev/null || echo "0")
    nit_count=$(jq '[.findings[] | select(.severity=="nit")] | length' "$findings_file" 2>/dev/null || echo "0")
    preexisting_count=$(jq '[.findings[] | select(.severity=="pre-existing")] | length' "$findings_file" 2>/dev/null || echo "0")

    echo "## 🐙 /octo:review — Multi-LLM Code Review"
    echo ""
    echo "| Severity | Count |"
    echo "|----------|-------|"
    echo "| 🔴 Normal | $normal_count |"
    echo "| 🟡 Nit | $nit_count |"
    echo "| 🟣 Pre-existing | $preexisting_count |"
    echo ""
    echo "_Reviewed by Codex + Gemini + Claude + Perplexity fleet_"
    echo "_See inline comments for details_"
}
```

- [ ] **Step 2: Add `code-review` to main command dispatch**

Find the `embrace)` case in the main dispatch (~line 20672). Add `code-review)` immediately before it:

```bash
    code-review)
        # Multi-LLM code review pipeline — competitor to CC Code Review
        if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
            echo "Usage: $(basename "$0") code-review '<json-profile>'"
            echo "Profile fields: target, focus, provenance, autonomy, publish, debate"
            echo "Example: $(basename "$0") code-review '{\"target\":\"staged\",\"publish\":\"ask\"}'"
            exit 0
        fi
        review_run "${1:-{}}"
        ;;
```

- [ ] **Step 3: Run full test suite**

```bash
bash tests/unit/test-review-run.sh
```

Expected: all tests pass.

- [ ] **Step 4: Run existing tests to confirm no regressions**

```bash
bash tests/test-intent-questions.sh 2>/dev/null | tail -5
bash tests/unit/test-review-autonomy-tdd.sh 2>/dev/null | tail -5
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/orchestrate.sh tests/unit/test-review-run.sh
git commit -m "feat: add review_run() multi-LLM pipeline to orchestrate.sh

3-round architecture: parallel specialist fleet (Round 1),
Codex verifier filtering false positives (Round 2),
Claude synthesis + inline PR comment publishing (Round 3).
Includes parse_review_md(), build_review_fleet(),
post_inline_comments(), render_terminal_report().
Provider cascade: Perplexity→Gemini→Claude WebSearch for CVE lookup.
REVIEW.md drop-in compatible with CC Code Review."
```

---

## Chunk 2: Command Files

**Files:**
- Modify: `.claude/commands/review.md`
- Modify: `commands/octo-review.md`

---

### Task 6: Redesign `.claude/commands/review.md`

- [ ] **Step 1: Read current file**

```bash
cat .claude/commands/review.md
```

Note the current line count and structure.

- [ ] **Step 2: Replace with clean redesign**

The new command is thin — it collects the typed profile and delegates to `orchestrate.sh code-review`. Replace the entire file content with:

```markdown
---
name: review
description: Expert multi-LLM code review with inline PR comments — competes with CC Code Review
---

# /octo:review

🐙 **CLAUDE OCTOPUS ACTIVATED** — Multi-LLM Code Review

Providers:
🔴 Codex CLI — logic and correctness
🟡 Gemini CLI — security and edge cases
🔵 Claude — architecture and synthesis
🟣 Perplexity — CVE lookup (if available)

---

When the user invokes this command (e.g., `/octo:review <arguments>`):

## Step 1: Context Acquisition

**Determine mode based on session autonomy:**

If `AUTONOMY_MODE` env var is `autonomous` or session is running headlessly, skip Q&A and auto-infer:
1. Run `git diff --cached` — if non-empty, `target=staged`
2. Run `gh pr view --json number` — if open PR exists, set `target=<pr_number>`
3. Otherwise `target=working-tree`
4. Set `provenance=unknown`, `autonomy=autonomous`, `publish=ask`, `debate=auto`

**Otherwise (supervised mode), use AskUserQuestion:**

```javascript
AskUserQuestion({
  questions: [
    {
      question: "What should be reviewed?",
      header: "Target",
      multiSelect: false,
      options: [
        {label: "Staged changes", description: "git diff --cached — what you're about to commit"},
        {label: "Open PR", description: "Review the current branch's open pull request"},
        {label: "Working tree", description: "All uncommitted changes"},
        {label: "Specific path", description: "A file or directory"}
      ]
    },
    {
      question: "What should the fleet focus on?",
      header: "Focus",
      multiSelect: true,
      options: [
        {label: "Correctness", description: "Logic bugs, edge cases, regressions"},
        {label: "Security & Edge Cases", description: "OWASP, race conditions, partial failures"},
        {label: "Architecture", description: "API contracts, integration, breaking changes"},
        {label: "TDD discipline", description: "Verify failing-test-first evidence and minimal implementation"}
      ]
    },
    {
      question: "How was this code produced?",
      header: "Provenance",
      multiSelect: false,
      options: [
        {label: "Human-authored", description: "Standard review"},
        {label: "AI-assisted", description: "Review for over-abstraction and weak tests"},
        {label: "Autonomous / Dark Factory", description: "Elevated rigor: verify tests, wiring, operational safety"},
        {label: "Unknown", description: "Assume less context, verify from code and tests"}
      ]
    },
    {
      question: "Should findings be posted to the open PR?",
      header: "Publish",
      multiSelect: false,
      options: [
        {label: "Ask me after review", description: "Show findings first, then decide"},
        {label: "Auto-post if confident", description: "Post inline comments when confidence ≥ 85%"},
        {label: "Never — terminal only", description: "Always show in terminal, never post to PR"}
      ]
    }
  ]
})
```

## Step 2: Build Review Profile

Map answers to JSON profile:

```javascript
const profile = {
  target: <from answer or inference>,  // "staged" | "working-tree" | PR# | path
  focus: <multi-select answers as array>,
  provenance: <answer>,                // "human" | "ai-assisted" | "autonomous" | "unknown"
  autonomy: <detected mode>,           // "supervised" | "autonomous"
  publish: <answer>,                   // "ask" | "auto" | "never"
  debate: "auto"                       // always default to auto debate
}
```

## Step 3: Execute Review Pipeline

Run via Bash tool:

```bash
/path/to/orchestrate.sh code-review '<profile-json>'
```

Where `<profile-json>` is the JSON profile built in Step 2.

The pipeline runs 3 rounds (parallel fleet → verification → synthesis) and outputs findings. If a PR is open and publish is not "never", it offers to post inline comments.

## What `/octo:review` checks

- Correctness: logic bugs, edge cases, regressions, unreachable code
- Security: OWASP Top 10, injection, auth flaws, data exposure (Gemini specialist)
- Architecture: API contracts, integration issues, breaking changes (Claude specialist)
- CVE lookup: known vulnerabilities in dependencies (Perplexity → Gemini → Claude WebSearch)
- TDD compliance and test-first evidence (when provenance is AI-assisted/autonomous)
- Autonomous codegen risk: placeholder logic, unwired code, speculative abstractions

## REVIEW.md support

Add a `REVIEW.md` file to your repository root to guide what `/octo:review` flags.
Drop-in compatible with Claude Code's managed Code Review service.

```markdown
# Code Review Guidelines

## Always check
- New API endpoints have corresponding integration tests

## Style
- Prefer early returns over nested conditionals

## Skip
- Generated files under src/gen/
```
```

- [ ] **Step 3: Verify the file was written correctly**

```bash
grep -c "code-review\|REVIEW.md\|review_run\|AskUserQuestion" .claude/commands/review.md
```

Expected: ≥ 4 matches.

---

### Task 7: Mirror to `commands/octo-review.md`

- [ ] **Step 1: Replace `commands/octo-review.md` with the same content**

```bash
cp .claude/commands/review.md commands/octo-review.md
```

- [ ] **Step 2: Run test to confirm command file references are correct**

```bash
bash tests/unit/test-review-run.sh 2>/dev/null | grep "review command"
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add .claude/commands/review.md commands/octo-review.md
git commit -m "feat: redesign /octo:review command for multi-LLM pipeline

Thin command collects typed profile (target, focus, provenance,
publish) then delegates to orchestrate.sh code-review backend.
Autonomous mode skips Q&A and auto-infers target from git state.
REVIEW.md documentation included in command help text."
```

---

## Chunk 3: TypeScript Entrypoints

**Files:**
- Modify: `mcp-server/src/index.ts` (~line 260)
- Modify: `openclaw/src/index.ts` (~line 234)

---

### Task 8: Expand MCP `octopus_review` schema

- [ ] **Step 1: Read current MCP review tool definition**

```bash
sed -n '258,275p' mcp-server/src/index.ts
```

- [ ] **Step 2: Replace single-string schema with typed profile**

Find and replace the `octopus_review` tool definition in `mcp-server/src/index.ts`:

**Old:**
```typescript
server.tool(
  "octopus_review",
  "Run expert code review with multi-provider analysis (security, performance, architecture).",
  {
    target: z
      .string()
      .describe("File path, directory, or description of what to review"),
  },
  async ({ target }) => {
    // orchestrate.sh uses "codex-review" for code review
    const { text, isError } = await runOrchestrate("codex-review", target);
    return { content: [{ type: "text" as const, text }], isError };
  }
);
```

**New:**
```typescript
server.tool(
  "octopus_review",
  "Multi-LLM code review (Codex + Gemini + Claude + Perplexity) with inline PR comments. Competes with CC Code Review.",
  {
    target: z
      .string()
      .default("staged")
      .describe("What to review: 'staged', 'working-tree', PR number, or file/dir path"),
    focus: z
      .array(z.enum(["correctness", "security", "performance", "architecture", "tdd"]))
      .optional()
      .describe("Review focus areas (default: correctness)"),
    provenance: z
      .enum(["human", "ai-assisted", "autonomous", "unknown"])
      .default("unknown")
      .describe("How the code was produced — affects review rigor"),
    autonomy: z
      .enum(["supervised", "autonomous"])
      .default("autonomous")
      .describe("supervised: Q&A before review; autonomous: infer everything"),
    publish: z
      .enum(["never", "ask", "auto"])
      .default("ask")
      .describe("Whether to post findings as inline PR comments"),
    debate: z
      .enum(["off", "auto", "high-severity", "architecture"])
      .default("auto")
      .describe("When to run adversarial debate on contested findings"),
  },
  async ({ target, focus, provenance, autonomy, publish, debate }) => {
    const profile = JSON.stringify({ target, focus, provenance, autonomy, publish, debate });
    const { text, isError } = await runOrchestrate("code-review", profile);
    return { content: [{ type: "text" as const, text }], isError };
  }
);
```

- [ ] **Step 3: Build to verify TypeScript compiles**

```bash
cd mcp-server && npm run build 2>&1 | tail -10
```

Expected: no errors.

- [ ] **Step 4: Run review-run tests for MCP schema check**

```bash
bash tests/unit/test-review-run.sh 2>/dev/null | grep "mcp"
```

Expected: PASS.

---

### Task 9: Expand OpenClaw `octopus_review` schema

- [ ] **Step 1: Read current OpenClaw review tool definition**

```bash
sed -n '232,255p' openclaw/src/index.ts
```

- [ ] **Step 2: Replace single-string schema with typed profile**

Find and replace the `octopus_review` entry in the tools array in `openclaw/src/index.ts`:

**Old:**
```typescript
  {
    name: "octopus_review",
    label: "Octopus Review",
    description:
      "Expert code review with multi-provider security and architecture analysis.",
    parameters: Type.Object({
      target: Type.String({ description: "File or directory to review" }),
    }),
    run: async (params) =>
      executeOrchestrate("codex-review", params.target as string),
  },
```

**New:**
```typescript
  {
    name: "octopus_review",
    label: "Octopus Review",
    description:
      "Multi-LLM code review (Codex + Gemini + Claude + Perplexity) with inline PR comments.",
    parameters: Type.Object({
      target: Type.String({
        description: "What to review: 'staged', 'working-tree', PR number, or file/dir path",
        default: "staged",
      }),
      focus: Type.Optional(Type.Array(
        Type.Union([
          Type.Literal("correctness"), Type.Literal("security"),
          Type.Literal("performance"), Type.Literal("architecture"), Type.Literal("tdd"),
        ]),
        { description: "Review focus areas" }
      )),
      provenance: Type.Optional(Type.Union([
        Type.Literal("human"), Type.Literal("ai-assisted"),
        Type.Literal("autonomous"), Type.Literal("unknown"),
      ], { description: "How code was produced — affects review rigor", default: "unknown" })),
      autonomy: Type.Optional(Type.Union([
        Type.Literal("supervised"), Type.Literal("autonomous"),
      ], { description: "supervised: Q&A before review; autonomous: infer everything", default: "autonomous" })),
      publish: Type.Optional(Type.Union([
        Type.Literal("never"), Type.Literal("ask"), Type.Literal("auto"),
      ], { description: "Post findings as inline PR comments", default: "ask" })),
      debate: Type.Optional(Type.Union([
        Type.Literal("off"), Type.Literal("auto"),
        Type.Literal("high-severity"), Type.Literal("architecture"),
      ], { description: "Adversarial debate on contested findings", default: "auto" })),
    }),
    run: async (params) => {
      const profile = JSON.stringify(params);
      return executeOrchestrate("code-review", profile);
    },
  },
```

- [ ] **Step 3: Build OpenClaw to verify TypeScript compiles**

```bash
cd openclaw && npm run build 2>&1 | tail -10
```

Expected: no errors.

- [ ] **Step 4: Run OpenClaw schema test**

```bash
bash tests/unit/test-review-run.sh 2>/dev/null | grep "openclaw"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mcp-server/src/index.ts openclaw/src/index.ts
git add mcp-server/dist/ openclaw/dist/ 2>/dev/null || true
git commit -m "feat: expand MCP and OpenClaw review tool to typed profile schema

Replace single target string with typed review profile: target,
focus[], provenance, autonomy, publish, debate. Both tools now
call orchestrate.sh code-review with JSON profile instead of
codex-review with raw string."
```

---

## Chunk 4: Skill Updates + Final Tests

**Files:**
- Modify: `.claude/skills/skill-code-review.md`
- Modify: `skills/skill-code-review/SKILL.md`

---

### Task 10: Update skill files to reference new pipeline

- [ ] **Step 1: Read current skill description section**

```bash
head -20 .claude/skills/skill-code-review.md
```

- [ ] **Step 2: Update pipeline reference in `.claude/skills/skill-code-review.md`**

Find and replace the orchestrate.sh example in the skill to use `code-review` instead of `auto "review ..."`:

```bash
# Old pattern (single-model):
# ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh auto "review the authentication implementation"

# New pattern (multi-LLM pipeline):
# ${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh code-review '{"target":"staged","focus":["correctness","security"]}'
```

Also update the skill description line to mention the multi-LLM fleet:

Find the line:
```
- Security vulnerability detection
```

And prepend:
```
- Multi-LLM fleet (Codex + Gemini + Claude + Perplexity) for maximum coverage
- REVIEW.md support — drop-in compatible with CC Code Review
```

- [ ] **Step 3: Mirror changes to `skills/skill-code-review/SKILL.md`**

Read the current file first:
```bash
head -30 skills/skill-code-review/SKILL.md
```

Then apply the same two edits as Task 10 Steps 1-2:

**Edit 1** — update the orchestrate.sh call example. Find the line:
```
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh auto "review the authentication implementation"
```
Replace with:
```
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh code-review '{"target":"staged","focus":["correctness","security"]}'
```

**Edit 2** — add multi-LLM capabilities. Find the line:
```
- Security vulnerability detection
```
Replace with:
```
- Multi-LLM fleet (Codex + Gemini + Claude + Perplexity) for maximum coverage
- REVIEW.md support — drop-in compatible with CC Code Review
- Security vulnerability detection
```

- [ ] **Step 4: Run full test suite**

```bash
bash tests/unit/test-review-run.sh
bash tests/unit/test-review-autonomy-tdd.sh
bash tests/test-command-registration.sh 2>/dev/null | tail -5
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add .claude/skills/skill-code-review.md skills/skill-code-review/SKILL.md
git commit -m "feat: update skill-code-review to reference multi-LLM pipeline

Update orchestrate.sh call pattern from 'auto review...' to
'code-review <json-profile>'. Add multi-LLM fleet and REVIEW.md
support to capability list. Retain Autonomous Implementation
Review section from v8.49.1."
```

---

### Task 11: Final integration verification

- [ ] **Step 1: Run all review-related tests**

```bash
bash tests/unit/test-review-run.sh
bash tests/unit/test-review-autonomy-tdd.sh
```

Expected: all pass.

- [ ] **Step 2: Run existing test suite for regressions**

```bash
bash tests/run-all-tests.sh 2>/dev/null | tail -20
```

Or if no run-all-tests.sh:
```bash
for f in tests/unit/test-*.sh tests/test-*.sh; do
  [[ -f "$f" ]] && echo "--- $f ---" && bash "$f" 2>/dev/null | tail -3
done
```

Expected: no new failures vs baseline.

- [ ] **Step 3: Smoke test the code-review command dispatch**

```bash
# Verify the code-review dispatch branch exists in orchestrate.sh (static check)
grep -c "code-review)" scripts/orchestrate.sh
```

Expected: output is `1` or higher (dispatch case exists).

```bash
# Verify code-review help path works
bash scripts/orchestrate.sh code-review --help 2>&1 | head -5
```

Expected: usage/help text printed (not "Unknown command").

- [ ] **Step 4: Final commit of any remaining changes**

```bash
git status
# Stage any remaining changes explicitly (no interactive flags)
git add scripts/orchestrate.sh \
        .claude/commands/review.md commands/octo-review.md \
        .claude/skills/skill-code-review.md skills/skill-code-review/SKILL.md \
        mcp-server/src/index.ts openclaw/src/index.ts \
        tests/unit/test-review-run.sh 2>/dev/null || true
git diff --cached --stat
git commit -m "chore: finalize /octo:review multi-LLM redesign" 2>/dev/null || echo "Nothing left to commit"
```

---

## Summary of Changes

| File | Change |
|------|--------|
| `scripts/orchestrate.sh` | +`parse_review_md()`, +`build_review_fleet()`, +`review_run()`, +`post_inline_comments()`, +`render_terminal_report()`, +`render_review_summary()`, +`code-review` dispatch |
| `.claude/commands/review.md` | Full redesign — typed profile, autonomous mode, REVIEW.md docs |
| `commands/octo-review.md` | Mirror of above |
| `.claude/skills/skill-code-review.md` | Updated pipeline reference + multi-LLM capability list |
| `skills/skill-code-review/SKILL.md` | Mirror |
| `mcp-server/src/index.ts` | Typed profile schema (6 fields), calls `code-review` backend |
| `openclaw/src/index.ts` | Typed profile schema (6 fields), calls `code-review` backend |
| `tests/unit/test-review-run.sh` | New: 10 tests covering all new functions and schema |
