---
description: Universal pre-commit quality checks (typecheck, lint, test, coverage, dead code) with auto-detection and --fix support
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
argument-hint: [--fix] [--coverage-min=80] [--deadcode]
visibility: public
pack: dev
---

# /quality-gate - Pre-Commit Quality Checks

Run universal quality checks (typecheck, lint, test, coverage) before committing. Auto-detects project type and available tools.

**Arguments:** Optional flags: `--fix` (auto-fix lint issues), `--coverage-min=80` (coverage threshold percentage), `--deadcode` (run dead code detection)

## Quality Gate Process

```
DETECT → CHECK → REPORT → BLOCK or APPROVE
```

1. **DETECT**: Auto-identify project type and available tools
2. **CHECK**: Run applicable typecheck, lint, test, and coverage checks
3. **REPORT**: Display pass/fail per check with summary
4. **BLOCK/APPROVE**: Block commit if any check fails; suggest fixes

---

## Process

### Step 1: Project Type Detection

Auto-detect the project type by checking for manifest files in priority order:

**Detection Priority (check in this order):**
1. `package.json` → Node.js project (npm, bun, yarn, pnpm)
2. `pyproject.toml` or `requirements.txt` → Python project
3. `go.mod` → Go project
4. `Cargo.toml` → Rust project

**If multiple detected:** Run checks for ALL project types (e.g., monorepo with Node + Python)

**If none detected:** Stop and ask the user which project type to use.

**Report detected project type(s) before proceeding.**

### Step 2: Determine Available Tools

For each detected project type, identify which tools are available:

#### Node.js Project

| Check | Tools to Try (in priority order) | Fallback |
|-------|----------------------------------|----------|
| **Typecheck** | `bun check`, `tsc` (if tsconfig.json exists) | Skip if no tools available |
| **Lint** | `bun lint` (if oxlint available), `eslint`, `oxlint`, `biome lint` | Skip if no tools available |
| **Test** | `bun test`, `npm test`, `pnpm test`, `yarn test` | Skip if no test script |
| **Coverage** | `bun test --coverage`, `npm test -- --coverage`, Vitest coverage | Skip if no coverage tool |

**Custom scripts in package.json:** Prefer these over direct tool invocations:
- If `package.json` has `"typecheck"` script → use `npm run typecheck` (or bun/pnpm/yarn equivalent)
- If `package.json` has `"check"` script → use `npm run check`
- If `package.json` has `"lint"` script → use `npm run lint`
- If `package.json` has `"test"` script → use `npm test`

#### Python Project

| Check | Tools to Try (in priority order) | Fallback |
|-------|----------------------------------|----------|
| **Typecheck** | `mypy`, `pyright` | Skip if not installed |
| **Lint** | `ruff check`, `flake8` | Skip if not installed |
| **Test** | `pytest` | Skip if not installed |
| **Coverage** | `pytest --cov` | Skip if pytest-cov not installed |

**Directory to scan:** `src/` if exists, else `./`

#### Go Project

| Check | Tools to Try (in priority order) | Fallback |
|-------|----------------------------------|----------|
| **Typecheck** | `go vet ./...` | Built-in, always available |
| **Lint** | `golangci-lint run`, `go fmt -l` | Skip if golangci-lint not installed |
| **Test** | `go test ./...` | Built-in, always available |
| **Coverage** | `go test -cover ./...` | Built-in, always available |

#### Rust Project

| Check | Tools to Try (in priority order) | Fallback |
|-------|----------------------------------|----------|
| **Typecheck** | `cargo check` | Built-in, always available |
| **Lint** | `cargo clippy -- -D warnings` | Built-in, always available |
| **Test** | `cargo test` | Built-in, always available |
| **Coverage** | `cargo tarpaulin --out Html` | Skip if tarpaulin not installed |

### Step 3: Run Quality Checks

For each detected project type, run all available checks in this order:

1. **Typecheck first** — catches type errors early
2. **Lint second** — style and code quality
3. **Test third** — functional correctness
4. **Coverage fourth** — test comprehensiveness

**Key behaviors:**
- Run each check independently (don't skip subsequent checks if one fails)
- Capture exit codes and output for reporting
- If `--fix` flag provided, run lint with auto-fix flags:
  - Node: `eslint --fix`, `oxlint --fix`, `biome lint --write`
  - Python: `ruff check --fix`, `ruff format`
  - Go: `gofmt -w`, `golangci-lint run --fix`
  - Rust: `cargo clippy --fix` (requires nightly)
- For coverage checks, compare against threshold (default 80%, configurable with `--coverage-min=NN`)

### Step 4: Report Results

Display results in a clear table format:

```
QUALITY GATE REPORT
═══════════════════════════════════════════════════════════

Project Type: Node.js
Package Manager: bun

Check         Status    Details
─────────────────────────────────────────────────────────
Typecheck     ✓ PASS    (0 errors, 0 warnings)
Lint          ✓ PASS    (0 issues)
Test          ✓ PASS    (42 passed, 2 skipped)
Coverage      ✓ PASS    (92% statements, 88% branches)
─────────────────────────────────────────────────────────

OVERALL: ✓ ALL CHECKS PASSED
═══════════════════════════════════════════════════════════

Safe to commit. Run: git commit -m "your message"
```

**If any check fails:**

```
QUALITY GATE REPORT
═══════════════════════════════════════════════════════════

Project Type: Node.js
Package Manager: bun

Check         Status    Details
─────────────────────────────────────────────────────────
Typecheck     ✗ FAIL    (3 errors)
Lint          ✓ PASS    (0 issues)
Test          ✗ FAIL    (1 failed, 41 passed)
Coverage      ⊘ SKIP    (Test failures prevent coverage)
─────────────────────────────────────────────────────────

OVERALL: ✗ QUALITY GATE BLOCKED
═══════════════════════════════════════════════════════════

Blockers:
  • Fix 3 TypeScript errors
    → Error at src/utils.ts:15: Type 'string' is not assignable to type 'number'
    → Error at src/api.ts:8: Property 'id' does not exist on type 'User'
    → Error at src/api.ts:20: Missing return type annotation

  • Fix 1 test failure
    → Test: parseDate should parse ISO dates
      Expected: '2025-01-01', Got: '2025-01-01T00:00:00Z'

To auto-fix linting issues, run: /quality-gate --fix
```

### Step 5: Block or Approve

**If all checks pass:** Recommend running `git commit`

**If any check fails:**
1. List blocking issues clearly
2. Suggest fixes (e.g., "run: eslint --fix", "fix TypeScript errors before committing")
3. Do NOT allow commit to proceed
4. If `--fix` flag was provided, re-run after auto-fixes to validate

---

## Worked Example: Node.js Project (Complete Walkthrough)

### Detection Phase

```
$ /quality-gate

🔍 Detecting project type...
  ✓ Found package.json
  ✓ Found bun.lockb (using Bun package manager)
  ✓ Found tsconfig.json (TypeScript project)
  ✓ Found .eslintrc.json (ESLint configured)
  ✓ Found jest.config.js (Jest test runner)

Detected: Node.js (Bun) with TypeScript
Available checks: typecheck, lint, test, coverage
```

### Check Phase (All Pass)

```
Running checks...

✓ Typecheck (bun check)
  0 errors, 0 warnings
  Completed in 2.3s

✓ Lint (eslint)
  0 issues
  Completed in 1.8s

✓ Test (bun test)
  42 passed, 0 failed, 2 skipped
  Completed in 8.5s

✓ Coverage (bun test --coverage)
  Statements: 92%
  Branches: 88%
  Functions: 94%
  Lines: 92%
  Completed in 9.1s
```

### Report Phase (Success)

```
QUALITY GATE REPORT
═══════════════════════════════════════════════════════════

Project Type: Node.js (Bun)
TypeScript: enabled
Test Framework: Jest

Check         Status    Details
─────────────────────────────────────────────────────────
Typecheck     ✓ PASS    (0 errors, 0 warnings)
Lint          ✓ PASS    (0 issues)
Test          ✓ PASS    (42 passed, 0 failed)
Coverage      ✓ PASS    (92% statements, meets 80% threshold)
─────────────────────────────────────────────────────────

OVERALL: ✓ ALL CHECKS PASSED
═══════════════════════════════════════════════════════════

✅ Safe to commit. Run: git commit -m "your message"
```

### Check Phase (With Failures)

```
Running checks...

✗ Typecheck (bun check)
  3 errors
    src/api.ts:8 - Property 'id' does not exist on type 'User'
    src/api.ts:15 - Type 'string' is not assignable to type 'number'
    src/utils.ts:22 - Missing return type annotation
  Completed in 2.3s

✓ Lint (eslint)
  0 issues
  Completed in 1.8s

✗ Test (bun test)
  39 passed, 2 failed, 1 skipped
  FAIL src/email.test.ts
    ✕ validateEmail should reject empty string
      Expected: false
      Received: true
  FAIL src/math.test.ts
    ✕ add should sum two numbers
      Expected: 3
      Received: 4
  Completed in 8.5s

⊘ Coverage (skipped due to test failures)
```

### Report Phase (With Failures)

```
QUALITY GATE REPORT
═══════════════════════════════════════════════════════════

Project Type: Node.js (Bun)
TypeScript: enabled
Test Framework: Jest

Check         Status    Details
─────────────────────────────────────────────────────────
Typecheck     ✗ FAIL    (3 errors)
Lint          ✓ PASS    (0 issues)
Test          ✗ FAIL    (2 failed, 39 passed)
Coverage      ⊘ SKIP    (Test failures prevent coverage check)
─────────────────────────────────────────────────────────

OVERALL: ✗ QUALITY GATE BLOCKED
═══════════════════════════════════════════════════════════

Fix the following blockers before committing:

1. TypeScript Errors (3 total):
   src/api.ts:8 - Property 'id' does not exist on type 'User'
   src/api.ts:15 - Type 'string' is not assignable to type 'number'
   src/utils.ts:22 - Missing return type annotation

2. Test Failures (2 total):
   src/email.test.ts - validateEmail should reject empty string
   src/math.test.ts - add should sum two numbers

Next steps:
  1. Fix TypeScript errors in src/api.ts and src/utils.ts
  2. Update tests in src/email.test.ts and src/math.test.ts
  3. Run: /quality-gate (to re-check)
  4. Commit: git commit -m "your message"
```

---

## Python Project Example

### Detection & Checks

```
$ /quality-gate

🔍 Detecting project type...
  ✓ Found pyproject.toml
  ✓ Found pytest.ini
  ✓ Found ruff.toml

Detected: Python project
Available checks: typecheck (mypy), lint (ruff), test (pytest), coverage

Running checks...

✓ Typecheck (mypy)
  No errors
  Completed in 3.2s

✓ Lint (ruff check)
  0 issues
  Completed in 1.1s

✓ Test (pytest)
  24 passed, 0 failed
  Completed in 5.8s

✓ Coverage (pytest --cov)
  Statements: 85%
  Branches: 79%
  Completed in 6.2s
```

---

## --fix Flag Example

```
$ /quality-gate --fix

🔍 Detecting project type...
  ✓ Found package.json (Node.js)
  ✓ Found tsconfig.json (TypeScript)

Running checks...

✓ Typecheck (bun check)
  0 errors, 0 warnings

🔧 Lint (eslint --fix)
  Found 5 issues, fixed 5 issues
  Completed in 1.8s

✓ Test (bun test)
  42 passed, 0 failed

✓ Coverage (bun test --coverage)
  92% statements

QUALITY GATE REPORT
═══════════════════════════════════════════════════════════

Check         Status    Details
─────────────────────────────────────────────────────────
Typecheck     ✓ PASS    (no errors)
Lint          ✓ PASS    (5 issues auto-fixed)
Test          ✓ PASS    (42 passed)
Coverage      ✓ PASS    (92% statements, meets 80%)
─────────────────────────────────────────────────────────

OVERALL: ✓ ALL CHECKS PASSED
═══════════════════════════════════════════════════════════

✅ Safe to commit. Run: git commit -m "your message"
```

---

## Framework-Specific Commands

### Node.js / Bun

```bash
# Detect and run all checks
/quality-gate

# Auto-fix linting issues
/quality-gate --fix

# Custom coverage threshold
/quality-gate --coverage-min=90

# Combine flags
/quality-gate --fix --coverage-min=85
```

### Python

```bash
# Detect and run all checks
/quality-gate

# Auto-fix with ruff
/quality-gate --fix

# Set custom threshold
/quality-gate --coverage-min=75
```

### Go

```bash
# Run all checks
/quality-gate

# Auto-format code
/quality-gate --fix
```

### Rust

```bash
# Run all checks
/quality-gate

# Auto-fix with clippy
/quality-gate --fix
```

---

## Dead Code Detection (--deadcode flag)

When the `--deadcode` flag is provided, run dead code detection **after** lint passes:

### Node.js Projects

| Tool | Detection | Install Check |
|------|-----------|---------------|
| **ts-unused-exports** | Unused exports | `package.json` has `ts-unused-exports` in devDependencies |
| **knip** | Unused exports, files, deps, types | `package.json` has `knip` in devDependencies |
| **ts-prune** | Unused exports only | `package.json` has `ts-prune` in devDependencies |

**Preferred tool:** ts-unused-exports (lightweight, no dependency conflicts in monorepos). Use knip for comprehensive scans if zod version is compatible.

**If project has a `deadcode` script in package.json:** Use that (`bun run deadcode`, `npm run deadcode`, etc.)

**If no dead code tool is installed:** Report: "No dead code tool configured. Consider adding ts-unused-exports: `bun add -d ts-unused-exports`"

### Report Format

```
Dead Code Analysis
─────────────────────────────────────────────────
Unused exports:     12 found
Unused files:        3 found
Unused dependencies: 2 found
Unused types:        5 found
─────────────────────────────────────────────────

Top unused exports:
  src/utils/legacy.ts: formatOldDate, parseOldFormat
  src/api/deprecated.ts: oldEndpoint
  libs/core/auth/src/index.ts: AuthV1Client

⚠️  Dead code scan is INFORMATIONAL — does not block commit.
    Review findings and clean up in a separate commit.
```

**Key behaviors:**
- Dead code results do NOT block commit (informational only)
- Always recommend cleaning dead code in a separate commit
- If knip returns errors (config issues), report the error and suggest checking `knip.config.ts`

---

## Success Checklist

After running /quality-gate, verify:

- [ ] Project type detected correctly
- [ ] All available checks identified
- [ ] Typecheck passes (or skipped if not applicable)
- [ ] Lint passes (or auto-fixed with --fix flag)
- [ ] Tests pass (or blockers clearly listed)
- [ ] Coverage meets threshold (80% by default, or custom value)
- [ ] Dead code report shown (if --deadcode flag provided)
- [ ] Report clearly shows pass/fail per check
- [ ] If any check fails, blockers are clearly documented
- [ ] Ready to commit (if all checks pass)
