---
id: hq-destructive-scripts-default-dry-run
title: Destructive-write scripts default to dry-run; require explicit --live flag
when: .sh
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
---

## Rule

ALWAYS design destructive-write scripts (CRM mutations, DB upserts/deletes, KV overwrites, Vercel env changes, bulk API PATCH/POST) to default to **dry-run mode** and require an explicit `--live` (or `--apply`, `--commit`) flag to perform writes. Never ship the opposite pattern (`--dry-run` opt-in) for scripts that touch shared runtime state.

Required shape:

```bash
node sync-reps.ts              # dry-run by default — logs what WOULD change, no writes
node sync-reps.ts --live       # explicit opt-in for writes
```

Script behavior in dry-run mode:

- Log every intended write with full payload diff
- Print a summary count (e.g. "Would write: 47 records, skip: 12")
- Exit 0 cleanly so the caller can review output without a failure signal
- NEVER partially execute — dry-run is all-or-nothing

Script behavior in `--live` mode:

- Echo `MODE: LIVE (will write)` to stderr at startup so it's visible in any captured logs
- Perform writes; log the same diff summary with actual counts

Exceptions (default-live allowed):

- Read-only scripts (analytics, export, audit) — no writes at all
- Scripts that only touch ephemeral/local state (temp files, local cache) — no shared blast radius
- Orchestrator-internal scripts that receive explicit confirmation from the user before dispatch

## Rationale

Default-safe inversion. When the destructive behavior is the default, a forgotten flag produces real writes against shared state — often silently, often irreversible. When dry-run is the default, a forgotten flag produces a harmless log dump that reveals the intended blast radius before any damage.

This matters most for CRM and DB scripts where "forgot the flag" means "overwrote 47 contact records" or "dropped a column." The cost asymmetry is extreme: the worst-case outcome of `--live` being accidentally added is catching it in review; the worst-case outcome of `--dry-run` being accidentally forgotten is data loss.

The pattern also composes with code review — a reviewer can see `--live` in the invocation and pause on it, whereas `--dry-run` absence is easy to miss. CI/automation callers are forced to declare intent explicitly.

Related: `hq-announce-before-irreversible.md` (state the action + account before executing) and `hq-no-production-testing.md` (never test against production endpoints).
