---
type: reference
domain: [engineering]
status: canonical
tags: [ralph, back-pressure, validation, testing, code-quality]
relates_to: []
---

# Back Pressure Engineering

## What is Back Pressure?

Back pressure is the automated feedback mechanism that validates AI-generated code before it's allowed to proceed. It's the critical component that makes autonomous coding reliable.

> "The back pressure if it generates something wrong, the test pushes back on the generative function to try again before the wheel is allowed to turn around."
> — Geoffrey Huntley

> "Our job is now engineering back pressure to the generative function to keep the generative function on the rails, the locomotive."
> — Geoffrey Huntley

## Why Back Pressure Matters

Without back pressure:
- AI will hallucinate solutions
- Bugs accumulate silently
- Context rot compounds errors
- Human review becomes overwhelming

With proper back pressure:
- Errors are caught immediately
- Each commit is verified working
- The loop is truly autonomous
- Code quality remains high

## Types of Back Pressure

### 1. Type Systems

**TypeScript (Recommended)**
```bash
tsc --noEmit
```

Benefits:
- Fast compilation
- Comprehensive type checking
- Excellent IDE integration
- Good error messages for AI

**Rust** (Trade-offs)
> "The compilation speed on Rust is very, very, very slow. What happens if it does an invalid generation or hallucination and the compilation takes 30 minutes? Compare that against TypeScript - in that time how many generations has it done?"
> — Geoffrey Huntley

### 2. Linting

```bash
eslint . --max-warnings 0
```

Catches:
- Code style violations
- Potential bugs
- Best practice violations
- Security issues

### 3. Unit Tests

```bash
npm test
# or
pytest
# or
cargo test
```

The most important form of back pressure:
- Verifies functionality
- Catches regressions
- Documents behavior
- Enables refactoring

### 4. Integration Tests

```bash
npm run test:integration
```

Verifies:
- Component interactions
- API contracts
- Database operations
- External service integration

### 5. Build Verification

```bash
npm run build
```

Ensures:
- Code compiles
- Dependencies resolve
- Assets bundle correctly
- No dead code

### 6. Pre-commit Hooks

```yaml
# .pre-commit-config.yaml
repos:
  - repo: local
    hooks:
      - id: typecheck
        name: Type Check
        entry: npm run typecheck
        language: system
      - id: lint
        name: Lint
        entry: npm run lint
        language: system
      - id: test
        name: Test
        entry: npm test
        language: system
```

### 7. Visual Verification (Frontend)

For frontend applications, text-based back pressure isn't enough:

> "The difficulty comes when you start adding visual elements... A feedback loop in a frontend: write some code, then look at the UI to see what changed, go back, write a bit more code, look at the UI again."
> — Matt Pocock

Solution: Browser automation via MCP:
- Screenshot comparison
- DOM inspection
- User interaction simulation
- Responsive design testing

## Engineering Effective Back Pressure

### Make It Fast

Speed is critical for rapid iteration:

```
Fast back pressure:
  TypeScript + ESLint + Jest = ~10 seconds

Slow back pressure:
  Rust compilation = ~5-30 minutes
```

> "If the compilation takes forever, what happens if it does an invalid generation? You got to be an engineer and make that back pressure fast."
> — Geoffrey Huntley

### Make It Comprehensive

Cover all failure modes:
- Syntax errors (compiler)
- Logic errors (tests)
- Style issues (linter)
- Type errors (type checker)
- Visual issues (browser automation)

### Make It Deterministic

Tests must be:
- Reproducible
- Not flaky
- Independent
- Fast

### Make It Informative

Error messages should help the AI fix issues:
- Clear descriptions
- Line numbers
- Suggested fixes
- Context

## The Feedback Loop Cycle

```
┌──────────────────────────────────────────┐
│                                          │
│  Generate Code                           │
│       │                                  │
│       ▼                                  │
│  ┌─────────┐                            │
│  │Type     │──fail──► Fix & Retry       │
│  │Check    │                     │      │
│  └────┬────┘                     │      │
│       │pass                      │      │
│       ▼                          │      │
│  ┌─────────┐                     │      │
│  │Lint     │──fail──► Fix & Retry│      │
│  └────┬────┘                     │      │
│       │pass                      │      │
│       ▼                          │      │
│  ┌─────────┐                     │      │
│  │Test     │──fail──► Fix & Retry│      │
│  └────┬────┘                     │      │
│       │pass                      │      │
│       ▼                          │      │
│  ┌─────────┐                     │      │
│  │Build    │──fail──► Fix & Retry│      │
│  └────┬────┘                     │      │
│       │pass                      │      │
│       ▼                          │      │
│  Commit & Proceed                       │
│                                          │
└──────────────────────────────────────────┘
```

## Language Recommendations

Based on back pressure speed and reliability:

| Language | Back Pressure Speed | Recommendation |
|----------|-------------------|----------------|
| TypeScript | Very Fast | Highly Recommended |
| Python | Fast | Recommended |
| Go | Fast | Recommended |
| Java | Medium | Acceptable |
| Rust | Slow | Trade-offs |
| C++ | Slow | Trade-offs |

> "Any discipline where you can mechanically verify it is going to be automated. That's absolutely certain - when you can mechanically verify it, it's going to be automated."
> — Geoffrey Huntley

## Story-Level Acceptance Tests (Cumulative Regression Guard)

### The Problem

Project-global back-pressure (typecheck, lint, test suite) catches structural errors but misses **semantic regressions** — when sub-agent B undoes sub-agent A's work in a way that no existing test covers. Each sub-agent gets fresh context and has zero awareness of prior stories' changes.

The `passes: true` flag is never re-verified. Once a story is marked complete, the loop skips it forever. If a later story regresses its behavior, nothing catches it — unless a test specifically covers that behavior.

### The Solution

Each story's `e2eTests` field in prd.json drives the creation of **executable acceptance tests** that persist across stories.

### Convention

```
{repo}/__tests__/stories/{story-id}.test.ts
```

- One `describe("{story-id}: {title}")` block per story
- One `it()` / `test()` per `e2eTests` entry from prd.json
- Import from real modules — no mocks for behavior under test
- Tests must be deterministic and fast

### How It Works

1. `/prd` generates `e2eTests` entries in Given/When/Then format for each story
2. `/execute-task` includes an `acceptance-test-writer` phase (after dev, before code-reviewer) that writes test files from these descriptions
3. The test-writer runs ALL existing story tests as back-pressure — catching regressions immediately
4. `run-project.sh` runs `run_story_tests()` after EVERY completed story (not every 3 like the regression gate)
5. If a prior story's test fails, the orchestrator logs the failure and can pause/retry

### Flow

```
Story US-001 completes:
  → acceptance-test-writer creates __tests__/stories/US-001.test.ts
  → 3 tests pass ✅
  → committed with story

Story US-002 completes:
  → acceptance-test-writer creates __tests__/stories/US-002.test.ts
  → runs US-002 tests: 2 tests pass ✅
  → runs US-001 tests: 3 tests still pass ✅  ← regression guard
  → committed with story

Story US-003 completes:
  → acceptance-test-writer creates __tests__/stories/US-003.test.ts
  → runs US-003 tests: 4 tests pass ✅
  → runs US-001 tests: 2 pass, 1 FAILS ❌  ← regression detected!
  → orchestrator pauses — US-003 broke US-001's behavior
```

### Backwards Compatibility

- Empty `e2eTests` (`[]`) = no test-writer phase, no story tests written
- If `__tests__/stories/` directory doesn't exist, `run_story_tests()` returns 0 silently
- Existing projects without `e2eTests` are completely unaffected

### Key Principle

The test suite IS the regression check — but only if it covers each story's acceptance criteria. Story-level acceptance tests close the gap between "all tests pass" and "all stories still work."
