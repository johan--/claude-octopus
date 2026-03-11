# /octo:review — Multi-LLM Code Review Design

**Date:** 2026-03-11
**Status:** Approved
**Scope:** Medium feature — clean redesign of `/octo:review` as a multi-LLM competitor to Claude Code's managed Code Review service

---

## Problem

Claude Code is rolling out a managed **Code Review** service that runs a fleet of specialized agents on GitHub PRs, posts inline comments with severity levels (🔴/🟡/🟣), and reads `REVIEW.md` for customization. Currently `/octo:review` cannot compete:

- Single-model (Codex CLI only) despite claiming multi-provider
- Three disconnected code paths (command → skill, MCP → codex-review, OpenClaw → codex-review)
- No canonical backend — `review` maps to `codex exec review` in orchestrate.sh
- Mandatory Q&A blocks autonomous/background use
- No inline PR comment posting
- No `REVIEW.md` support
- No structured output (findings.json)
- No verification step to filter false positives

---

## Goal

Rebuild `/octo:review` as a direct multi-LLM alternative to CC Code Review that matches its UX conventions and beats it where possible: live CVE lookup, pre-PR support, any git host, autonomy-aware rigor, adversarial debate for contested findings.

---

## Architecture

### Canonical Backend: `review_run()`

All entrypoints call a single `review_run()` function in `orchestrate.sh`. This replaces the current `codex exec review` dispatch.

```
/octo:review  ──┐
MCP tool      ──┼──► review_run() ──► Round 1 (parallel agents)
OpenClaw tool ──┘                          │
                                      Round 2 (verification)
                                           │
                                      Round 3 (synthesis)
                                           │
                               ┌───────────┴───────────┐
                          PR exists?               No PR
                       inline gh comments      terminal report
```

### Typed Review Profile

All entrypoints pass a structured profile to `review_run()`:

```bash
target      # file/dir/PR#/"staged"/"working-tree"
focus[]     # correctness | security | performance | architecture | tdd
provenance  # human | ai-assisted | autonomous | unknown
autonomy    # supervised | semi-autonomous | autonomous
publish     # never | ask | auto
debate      # off | auto | high-severity | architecture
```

In **supervised** mode, the command collects this via `AskUserQuestion`. In **autonomous** mode, `review_run()` infers all values from `git diff --cached`, open PR state, and session context — no Q&A.

---

## The Three Rounds

### Round 1: Parallel Agent Fleet

Four agents run simultaneously via `spawn_agent()`, each reading the same diff + surrounding context through a different lens:

| Agent | Primary Provider | Fallback | Specialty |
|-------|-----------------|----------|-----------|
| `logic-reviewer` | Codex (gpt-5.1-codex-max) | Claude-sonnet | Correctness, logic bugs, edge cases, regressions |
| `security-reviewer` | Gemini (gemini-3-pro-preview) | Claude-sonnet | OWASP, injection, auth flaws, data exposure |
| `arch-reviewer` | Claude-sonnet | — (always available) | Architecture, integration, API contracts, breaking changes |
| `cve-reviewer` | Perplexity | Gemini search → Claude WebSearch → skip | Known CVEs, library advisories (live web search) |

The active fleet is built dynamically from `AVAILABLE_PROVIDERS` detected at preflight. Missing providers use their fallback. CVE lookup degrades gracefully with a noted warning in output.

Each agent receives:
1. The diff (scoped to `target`)
2. Surrounding context (configurable lines around changed code)
3. Contents of `REVIEW.md` if present at repo root
4. The review profile (focus, provenance, autonomy)

Each agent outputs structured JSON findings:

```json
{
  "findings": [
    {
      "file": "src/auth.ts",
      "line": 42,
      "severity": "normal",
      "category": "security",
      "title": "JWT secret falls back to hardcoded value",
      "detail": "The fallback `process.env.JWT_SECRET || 'dev-secret'` will silently use the hardcoded value in production if the env var is unset.",
      "confidence": 0.92
    }
  ]
}
```

Severity matches CC Code Review exactly:
- 🔴 `normal` — bug that should be fixed before merging
- 🟡 `nit` — minor issue, worth fixing but not blocking
- 🟣 `pre-existing` — bug that exists but was not introduced by this PR

### Round 2: Verification (Codex-review)

A dedicated verifier reads all candidate findings and checks each against actual code behavior — not just the diff.

The verifier:
- Reads the actual file content at each flagged line
- Checks whether the triggering condition is reachable
- Marks each finding: `confirmed | false-positive | needs-debate`
- Elevates `pre-existing` findings that were dormant but are newly reachable via this PR

`false-positive` findings are dropped. `needs-debate` findings (verifier uncertain, or Round 1 agents disagreed) trigger a 1-round adversarial debate between Codex + Gemini + Claude before inclusion. This is controlled by the `debate` profile field:
- `off` — skip debate, include borderline findings with lower confidence
- `auto` — debate only `needs-debate` findings (default)
- `high-severity` — debate all `normal`-severity findings
- `architecture` — debate all `arch-reviewer` findings

### Round 3: Synthesis (Claude)

Takes verified findings, deduplicates (same bug from multiple agents → merged, all perspectives preserved), severity-ranks, formats output.

**Outputs:**
- `~/.claude-octopus/results/review-findings-<timestamp>.json` — structured, full detail
- Rendered markdown report — terminal display
- Per-line inline comments — for PR posting

**PR detection and publishing:**

```bash
pr_number=$(gh pr view --json number -q .number 2>/dev/null)

if [[ -n "$pr_number" && "$publish" != "never" ]]; then
  gh pr review "$pr_number" --comment --body "$(render_review_summary)"
  post_inline_comments "$pr_number" findings.json
elif [[ "$publish" == "auto" && avg_confidence >= 0.85 ]]; then
  # Auto-post only when confidence threshold met
  post_inline_comments "$pr_number" findings.json
else
  render_terminal_report findings.json
fi
```

---

## REVIEW.md Support

`review_run()` auto-discovers `REVIEW.md` at the repo root (same location as CC Code Review). Parsed into three directive lists:

```bash
always_check=()    # Injected into all Round 1 agent prompts
style_rules=()     # Injected into all Round 1 agent prompts
skip_patterns=()   # Pre-filter: excluded files/paths skip Round 1 entirely
```

This is a **drop-in**: repos already configured for CC Code Review work with `/octo:review` without any changes.

---

## Where `/octo:review` Beats CC Code Review

| Capability | CC Code Review | `/octo:review` |
|-----------|---------------|----------------|
| Provider fleet | Claude only | Codex + Gemini + Claude + Perplexity |
| CVE / advisory lookup | Codebase-only | Live web search (Perplexity → Gemini → Claude WebSearch) |
| Works pre-PR | No | Yes — staged changes, working tree, any path |
| Git host | GitHub only | Any (GitLab, Bitbucket, local) |
| TDD / autonomy mode | No | Auto-elevates rigor for AI-generated code |
| Contested findings | Included or dropped | Adversarial debate gate |
| Cost model | $15-25/run (managed) | Pay-per-provider, skip providers you don't need |
| `REVIEW.md` | Yes | Yes — same format, drop-in compatible |
| Inline PR comments | Yes | Yes — via `gh pr review` |
| Structured output | No | `findings.json` for downstream automation |

---

## Files Changed

| File | Change |
|------|--------|
| `scripts/orchestrate.sh` | Add `review_run()`, `post_inline_comments()`, `parse_review_md()`, `build_review_fleet()`. Map `review` command dispatch to `review_run()` instead of `codex exec review`. |
| `.claude/commands/review.md` | Clean redesign — thin command collecting typed profile, delegates to `review_run()` |
| `commands/octo-review.md` | Mirror of above |
| `.claude/skills/skill-code-review.md` | Update description and pipeline reference; keep Autonomous Implementation Review section from v8.49.1 |
| `skills/skill-code-review/SKILL.md` | Mirror |
| `mcp-server/src/index.ts` | Expand `octopus_review` schema: add `focus`, `provenance`, `autonomy`, `publish`, `debate` fields |
| `openclaw/src/index.ts` | Same schema expansion |
| `tests/unit/test-review-run.sh` | Tests for `review_run()` pipeline, `REVIEW.md` parsing, fleet fallback logic, severity output format, PR detection |

Existing `tests/unit/test-review-autonomy-tdd.sh` (added in v8.49.1 Develop phase) is retained and extended.

---

## Implementation Notes

- `build_review_fleet()` reads `AVAILABLE_PROVIDERS` from preflight state and returns the active agent list with fallbacks resolved. Called once at start of `review_run()`.
- All Round 1 agents use `spawn_agent()` for true parallelism. Results collected via the existing result-file pattern.
- Verification (Round 2) is synchronous — must complete before synthesis.
- `post_inline_comments()` uses `gh api` with `pull_request_review_comments` endpoint for true inline (line-level) comments, not just PR-level comments.
- Confidence threshold for auto-publish defaults to `0.85`. Configurable via `OCTOPUS_REVIEW_CONFIDENCE` env var.
- New tests must pass existing `test-command-registration.sh` and `test-version-consistency.sh` — hardcoded counts may need updating.

---

## Out of Scope

- GitHub App installation / managed service hosting (that's CC Code Review's territory)
- Auto-resolve threads on subsequent pushes (future: detect previously-posted findings and close them)
- Per-subdirectory `REVIEW.md` hierarchy (CC Code Review supports this; defer to v2)
