---
name: skill-code-review
version: 1.0.0
description: Expert multi-AI code review with quality and security analysis
---

# Code Review Skill

Invokes the code-reviewer persona for thorough code analysis during the `ink` (deliver) phase.

## Usage

```bash
# Via orchestrate.sh
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh spawn code-reviewer "Review this pull request for security issues"

# Via auto-routing (detects review intent)
${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh auto "review the authentication implementation"
```

## Capabilities

- AI-powered code quality analysis
- Security vulnerability detection
- Performance optimization suggestions
- Architecture and design pattern review
- TDD compliance and test-first evidence review
- Autonomous code generation risk detection
- Best practices enforcement

## Persona Reference

This skill wraps the `code-reviewer` persona defined in:
- `agents/personas/code-reviewer.md`
- CLI: `codex-review`
- Model: `gpt-5.2-codex`
- Phases: `ink`

## Example Prompts

```
"Review this PR for OWASP Top 10 vulnerabilities"
"Analyze the error handling in src/api/"
"Check for memory leaks in the connection pool"
"Review the test coverage for the auth module"
```

---

## Autonomous Implementation Review

When the review context indicates `AI-assisted`, `Autonomous / Dark Factory`, or unclear provenance, raise the rigor bar. Do not treat generated code as trustworthy just because it is polished.

### TDD Evidence

Check for concrete signs that the change followed red-green-refactor rather than test-after implementation:

- Compare the diff and recent history when available to see whether tests were added before or alongside production changes.
- Prefer behavior-defining tests over snapshot-only or mock-heavy tests that merely restate the implementation.
- Verify the production code looks like the minimum needed to satisfy the tests, rather than a speculative abstraction with unused options.
- If evidence is missing, mark TDD compliance as unknown and do not assume TDD happened.

### Autonomous Codegen Risk Patterns

Elevate or add findings when you see patterns common in high-autonomy output:

- Option-heavy APIs or abstractions not justified by tests or current requirements
- Placeholder logic, TODO/FIXME-driven control flow, or dead branches that appear "future ready"
- Mock, fake, or dummy behavior leaking into production paths
- Unwired components, unused helpers, or code that exists without an execution path
- Silent failure handling, broad catch blocks, missing logs, or weak operational visibility
- Missing rollback notes, migration guards, or release-safety checks for risky changes

## Edge Case Deep Dive

When `Security & Edge Cases` is a priority (or in `autonomous` mode), explicitly audit for:

### 1. Concurrency & Race Conditions
- **Async/Await without Sequencing**: Multiple async calls where order matters but isn't enforced.
- **Shared State**: Unprotected access to global variables or shared caches in concurrent paths.
- **Double Writes**: Potential for duplicate records if a request is retried (lack of idempotency).

### 2. Partial Failure States
- **Distributed Transactions**: An API call succeeds but the subsequent database write or message queue publish fails.
- **Missing Rollbacks**: Lack of `try/catch/finally` or transactional cleanup when mid-process errors occur.
- **Inconsistent Cache**: Updates to DB succeed but cache invalidation fails (or vice versa).

### 3. Resource & Boundary Limits
- **Large Input Attacks**: Missing length/size validation on inputs that could cause OOM or DoS.
- **Timeout Handling**: Missing or overly generous timeouts on external service calls.
- **Connection Leaks**: Database connections or file handles not closed in error paths.

### 4. Logic Boundaries
- **Empty/Null Handling**: "Polished" code that crashes on empty arrays or null properties.
- **Integer Overflows**: Unchecked math on user-provided values.
- **Timezone/DST Issues**: Naive date math in scheduling logic.

## Review Output Addendum

Add a short section to the review synthesis when autonomy or TDD is in scope:

```markdown
## TDD / Autonomy Assessment

- Provenance: Human-authored | AI-assisted | Autonomous / Dark Factory | Unknown
- TDD evidence: Confirmed | Partial | Unknown
- Autonomous risk signals: None | Minor | Significant
- Recommendation: Ship | Fix before merge | Re-run with /octo:tdd or tighter supervision
```

---

## Implementation Completeness Verification

After the code-reviewer persona completes, run stub detection to verify implementation completeness.

### Stub Detection Process

**Step 1: Get changed files**

```bash
# Get files changed in the commit/PR
if [ -n "$COMMIT_RANGE" ]; then
    changed_files=$(git diff --name-only "$COMMIT_RANGE")
else
    changed_files=$(git diff --name-only HEAD~1..HEAD)
fi

# Filter for source code files
source_files=$(echo "$changed_files" | grep -E "\.(ts|tsx|js|jsx|py|go)$")
```

**Step 2: Check for stub patterns**

For each changed file, check for common stub indicators:

```bash
for file in $source_files; do
    echo "Checking $file for stubs..."

    # Check 1: Comment-based stubs
    stub_count=$(grep -E "(TODO|FIXME|PLACEHOLDER|XXX)" "$file" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$stub_count" -gt 0 ]; then
        echo "⚠️  WARNING: Found $stub_count stub indicators in $file"
        grep -n -E "(TODO|FIXME|PLACEHOLDER)" "$file" | head -3
    fi

    # Check 2: Empty function bodies
    empty_functions=$(grep -E "function.*\{\s*\}|const.*=>.*\{\s*\}" "$file" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$empty_functions" -gt 0 ]; then
        echo "❌ ERROR: Found $empty_functions empty functions in $file"
        echo "   Empty functions must be implemented before merge"
    fi

    # Check 3: Return null/undefined
    null_returns=$(grep -E "return (null|undefined);" "$file" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$null_returns" -gt 0 ]; then
        echo "⚠️  WARNING: Found $null_returns null/undefined returns in $file"
        echo "   Verify these are intentional, not stubs"
    fi

    # Check 4: Substantive content check
    substantive_lines=$(grep -vE "^\s*(//|/\*|\*|import|export|$)" "$file" 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$file" == *.tsx ]] && [ "$substantive_lines" -lt 10 ]; then
        echo "⚠️  WARNING: Component $file only has $substantive_lines substantive lines"
        echo "   Components should typically be >10 lines"
    fi

    # Check 5: Mock/test data in production
    mock_data=$(grep -E "const.*(mock|test|dummy|fake).*=" "$file" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$mock_data" -gt 0 ]; then
        echo "⚠️  WARNING: Found $mock_data references to mock/test data in $file"
        echo "   Ensure these are not placeholders for production code"
    fi
done
```

**Step 3: Add findings to review synthesis**

Include stub detection results in the review output:

```markdown
## Implementation Completeness

**Stub Detection Results:**

✅ **Fully Implemented Files:**
- src/components/UserProfile.tsx (42 substantive lines)
- src/api/users.ts (67 substantive lines)

⚠️  **Files with Warnings:**
- src/components/Dashboard.tsx
  - 3 TODO comments (non-blocking)
  - Consider addressing before release

❌ **Files Requiring Implementation:**
- src/utils/analytics.ts
  - 2 empty functions detected (BLOCKING)
  - Must implement before merge

**Verification Levels:**
- Level 1 (Exists): 5/5 files ✅
- Level 2 (Substantive): 3/5 files ⚠️
- Level 3 (Wired): 4/5 files ✅
- Level 4 (Functional): Tests pending

**Recommendation:**
- Fix empty functions in analytics.ts before merge
- Address TODO comments in Dashboard.tsx in follow-up PR
- All other files meet implementation standards
```

### Stub Detection Reference

See `.claude/references/stub-detection.md` for comprehensive patterns and detection strategies.

### When to Block Merge

**BLOCKING Issues (must fix):**
- ❌ Empty function bodies
- ❌ Mock data in production code paths
- ❌ Components not imported/wired anywhere
- ❌ API endpoints returning empty objects

**NON-BLOCKING Issues (note in review):**
- ⚠️ TODO/FIXME comments (create follow-up tickets)
- ⚠️ Null returns (if intentional)
- ⚠️ Low line count (if appropriate for the component)
