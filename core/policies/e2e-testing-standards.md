---
id: e2e-testing-standards
enforcement: hard
scope: global
tags: [testing, e2e, prd, ralph, run-project, execute-task]
public: true
created: 2026-05-11
provenance: claude-md-extracted
---

## Rule

For deployable projects (web, API, CLI), E2E coverage is the truth signal — not unit tests, not type checks, not lint. The orchestrator (Ralph loop) treats E2E failure as back-pressure: the story is not done while the E2E fails, regardless of unit-test pass count.

**Mechanics:**

- **E2E vs unit:** Unit tests check that the code is internally consistent. E2E tests check that the product works. A green unit suite with a failing E2E means the product is broken; ship-state is FAIL.
- **PRDs (`prd.json` per project):** Stories may declare an optional `e2eTests` array. Each entry names a test or test pattern that must pass before the story is counted as complete. Stories without `e2eTests` rely on the project-level smoke (declared at the PRD root).
- **Workers:** Use the `e2e-testing` skill for writing and running these tests. Don't reinvent harnesses inline.
- **Knowledge base path:** Templates, infra guides, and the `agent-browser` recipe live alongside this policy under `core/knowledge/` — search via `qmd vsearch -c hq-knowledge "e2e <topic>"` rather than hard-coding a path.

## Rationale

The Ralph orchestrator's passes-detection (`core/scripts/run-project.sh`) needs an observable, automated signal for "done." E2E provides it. Unit-only PRDs lead to the "all green but doesn't work" failure mode that pure-verification stories already suffer.

## Related

- Core Principles #4–8 in `.claude/CLAUDE.md` (Test before ship, E2E proves it, Never skip failing tests, Bugfixes require tests)
