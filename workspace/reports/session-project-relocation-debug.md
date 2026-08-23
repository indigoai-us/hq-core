# DEBUG REPORT — stale session project paths recreate moved projects

**Date:** 2026-08-22
**Company:** none (HQ core repository)
**Scope lock:** auto-session-project hook, session-project helper, and their shell tests
**Investigation depth:** 1 hypothesis tested

## Root Cause

**Status:** CONFIRMED

The auto-session hook writes a project path into each session marker, but its existing-marker branch ignores that value and invokes `append-event` without `--project`. The helper therefore resolves the shared active-project pointer instead of the session's marker; when that pointer names a moved project, `readJson(prdPath) || {}` and recursive `writeJson` recreate the missing path, and when another session has changed the pointer, the event is appended to that unrelated project.

## Evidence

| Evidence | Supports | Refutes |
|---|---|---|
| Moving a session project and appending through the current shared pointer recreated the old `prd.json`; the moved PRD received zero events. | Hypothesis 1 | — |
| Creating a second active session project before the first session's follow-up caused the first session's event to appear in the second project. | Hypothesis 1 | — |
| Existing smoke tests pass because they do not assert the destination of a later per-session event. | Hypothesis 1 | — |

## Pattern Classification

**Primary:** STATE CORRUPTION
**Secondary:** COMPANY ISOLATION / HOOK ORDERING

## What Was Ruled Out

- No additional hypotheses were needed after the direct data-flow prediction was reproduced.

## Recommended Fix

Pass the marker's stored project path and session ID to `append-event`. Require an existing valid PRD at that destination; if it is stale, scan the allowed Personal and company project roots for exactly one PRD whose `metadata.nativeSessions` contains that session ID. Append only to that unique project and otherwise fail closed before any write or directory creation.

**Minimal change:** make `append-event` resolve a session-owned destination and make the hook use its marker value.
**Files to touch:** `.claude/hooks/auto-session-project.sh`, `core/scripts/session-project.sh`, and their two existing smoke-test files.
**Risk of fix:** LOW — existing destinations keep the direct path; only stale or ambiguous destinations gain stricter handling.
**Regression test:** cover Personal-to-company relocation, an in-company rename, an unreconcilable stale path, and two session markers while the shared pointer names a different project.
