# Pre-Landing Review Checklist

## Instructions

Review the `git diff origin/main` output for the issues listed below. Be specific — cite `file:line` and suggest fixes. Skip anything that's fine. Only flag real problems.

**Two-pass review:**
- **Pass 1 (CRITICAL):** Run these first. These block PR creation.
- **Pass 2 (INFORMATIONAL):** Run all remaining categories. Included in PR body but do not block.

**Output format:**

```
Pre-Landing Review: N issues (X critical, Y informational)

CRITICAL (blocking):
- [file:line] Problem description
  Fix: suggested fix

INFORMATIONAL (non-blocking):
- [file:line] Problem description
  Fix: suggested fix
```

If no issues found: `Pre-Landing Review: No issues found.`

Be terse. For each issue: one line describing the problem, one line with the fix. No preamble, no summaries, no "looks good overall."

---

## Review Categories

### Pass 1 — CRITICAL

#### SQL & Data Safety
- String interpolation or template literals in SQL queries — use parameterized queries (`$1` placeholders, Prisma parameters, Supabase `.eq()`)
- TOCTOU races: check-then-set patterns that should be atomic (e.g., `SELECT` then `UPDATE` instead of `UPDATE ... WHERE`)
- Raw `.execute()` or `.raw()` calls with user-controlled input without parameterization
- Missing transactions around multi-step mutations that must be atomic
- `DELETE` or `UPDATE` without `WHERE` clause (or with overly broad conditions)
- N+1 queries: associations accessed in loops without eager loading (`.include()`, `.select()`, `JOIN`)

#### Race Conditions & Concurrency
- Read-check-write without uniqueness constraint or conflict handling (e.g., `findFirst` then `create` without `upsert` or `ON CONFLICT`)
- `findOrCreate` / `upsert` on columns without unique DB index — concurrent calls create duplicates
- Status transitions that don't use atomic `WHERE old_status = ? SET new_status` — concurrent updates can skip or double-apply
- Shared mutable state in serverless functions (module-level variables that persist across invocations)
- Missing idempotency keys on retry-able operations (webhooks, payment processing, queue consumers)

#### Injection & Trust Boundaries
- XSS: `dangerouslySetInnerHTML` on user-controlled or LLM-generated data without sanitization
- Command injection: user input passed to `exec()`, `spawn()`, or template strings in shell commands
- LLM output written to DB or used in API calls without format validation (email regex, URL parse, type checks)
- Structured LLM output (JSON, arrays) accepted without schema validation before persistence
- `eval()`, `new Function()`, or dynamic `import()` with user-controlled strings
- Path traversal: user input used in `fs.readFile()`, `path.join()` without sanitization
- SSRF: user-controlled URLs passed to `fetch()` / HTTP clients without allowlist

### Pass 2 — INFORMATIONAL

#### Conditional Side Effects
- Code paths that branch on a condition but forget to apply a side effect on one branch (e.g., status updated but notification only sent in one branch)
- Log messages that claim an action happened but the action was conditionally skipped
- Error handlers that catch but don't propagate context (swallowing errors silently)

#### Magic Numbers & String Coupling
- Bare numeric literals used in multiple files — should be named constants
- Error message strings used as query filters or conditional checks elsewhere
- Hardcoded URLs, ports, or API paths that should be config/env values

#### Dead Code & Consistency
- Variables assigned but never read
- Imports that are unused (if not caught by linter)
- Comments/docstrings describing old behavior after code changed
- Version or changelog entries that don't match actual changes

#### Type Safety Gaps
- `any` type assertions that hide real type errors
- `as` casts bypassing TypeScript's type narrowing (especially `as unknown as X`)
- Missing null/undefined checks on values from external sources (API responses, DB queries, user input)
- Unvalidated `.json()` responses — parsed but not checked against expected shape
- Optional chaining (`?.`) used where the value should never be null (hiding bugs instead of catching them)

#### LLM Prompt Issues
- 0-indexed lists in prompts (LLMs reliably return 1-indexed)
- Prompt text listing tools/capabilities that don't match what's wired up in code
- Token/word limits stated in multiple places that could drift out of sync
- System prompts with contradictory instructions

#### Test Gaps
- Negative-path tests that check type/status but not side effects (was the webhook fired? was the record cleaned up?)
- Missing integration tests for security enforcement (auth, rate limiting, role checks)
- Tests asserting string presence without checking format or structure
- Flaky test signals: tests depending on time, randomness, network, or ordering

#### Crypto & Entropy
- `Math.random()` for security-sensitive values (tokens, codes, session IDs) — use `crypto.randomUUID()` or `crypto.getRandomValues()`
- Non-constant-time comparisons (`===`) on secrets or tokens — use `crypto.timingSafeEqual()`
- Truncation of data for uniqueness instead of hashing (less entropy, easier collisions)
- Hardcoded secrets, API keys, or credentials (even in test files)

#### Time & Timezone Safety
- Date-key lookups that assume "today" covers 24h — report generated at 8am only sees midnight→8am
- `new Date()` without timezone context — server UTC vs user's local timezone
- Mismatched time windows between related features (one uses hourly, another daily)
- `toISOString()` used for display (always UTC) when local time was intended
- Cache keys or DB columns typed as `date` but storing values with suffixes or time components

#### Import & Bundle
- Circular imports between modules (A imports B imports A)
- Barrel file (`index.ts`) re-exports that prevent tree-shaking and bloat bundles
- Heavy dependencies imported for minor utility (`lodash` for `_.get`, `moment` for formatting)
- Dynamic `import()` in hot paths that could be statically imported
- Missing `type` keyword on type-only imports (`import type { X }`) — imports value where only type is needed

---

## Gate Classification

```
CRITICAL (blocks PR):               INFORMATIONAL (in PR body):
├─ SQL & Data Safety                 ├─ Conditional Side Effects
├─ Race Conditions & Concurrency     ├─ Magic Numbers & String Coupling
└─ Injection & Trust Boundaries      ├─ Dead Code & Consistency
                                     ├─ Type Safety Gaps
                                     ├─ LLM Prompt Issues
                                     ├─ Test Gaps
                                     ├─ Crypto & Entropy
                                     ├─ Time & Timezone Safety
                                     └─ Import & Bundle
```

---

## Suppressions — DO NOT flag these

- "X is redundant with Y" when the redundancy is harmless and aids readability
- "Add a comment explaining why this threshold/constant was chosen" — thresholds change during tuning, comments rot
- "This assertion could be tighter" when the assertion already covers the behavior
- Consistency-only changes (reformatting a value to match how another is written) with no behavioral impact
- "Regex doesn't handle edge case X" when the input is constrained and X never occurs in practice
- "Test exercises multiple guards simultaneously" — that's fine, tests don't need to isolate every guard
- Threshold/config value changes that are tuned empirically
- Harmless no-ops (e.g., `.filter()` on an array that never contains the filtered value)
- ANYTHING already addressed in the diff you're reviewing — read the FULL diff before commenting
- Style preferences (single vs double quotes, trailing commas, brace style) — that's the linter's job
- Missing JSDoc/TSDoc on internal functions — only flag on public API boundaries
