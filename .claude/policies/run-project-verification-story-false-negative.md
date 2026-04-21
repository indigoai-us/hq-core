---
id: run-project-verification-story-false-negative
title: /run-project flags pure-verification stories as FAIL
scope: command
trigger: run-project, execute-task, pure-verification-story
enforcement: soft
version: 1
created: 2026-04-10
source: session-observation
---

## Rule

When a PRD story's only deliverable is a verification report (no code commits, no new tests) — e.g. "E2E verification on dev store", "QA smoke test", "code review pass" — the Ralph orchestrator's passes-detection layers **cannot detect success** and will mark the story as FAIL even if the worker did its job correctly.

**Symptoms:**
- `state.json` shows `failed: ["US-0NN"]`
- `run.log` contains `FAIL US-0NN: passes still false after invocation (exit=0, <N>s)`
- Story produces no commit on the feature branch
- A report file exists at `workspace/reports/{project}-{story}*.md` (or similar) but the orchestrator never checks for it

**Workaround (current sessions):**
1. Treat the FAIL as a false negative — read the report file directly and verify the worker did the expected work
2. Manually mark the story complete: `jq '.completed += ["US-00N"] | .failed -= ["US-00N"] | .progress.completed += 1 | .progress.failed -= 1' state.json`
3. Do NOT auto-retry — retries will re-run the verification without changing anything

**Fix (when addressing at source):**
Add a 4th detection layer to `scripts/run-project.sh` passes-check:
- Layer 1: new commit on branch
- Layer 2: `passes: true` in story output
- Layer 3: explicit completion marker file
- **Layer 4 (new):** configurable `completionArtifact: "workspace/reports/{project}-{story}-*.md"` in prd.json story metadata. If the artifact exists and was modified during the story window, count as passed.

## Related

- `.claude/policies/run-project-progress-txt-no-commit-misleading.md` — sibling observation: `[no-commit]` tags in `progress.txt` are hints, not ground truth
- `workspace/reports/{product}-free-gift-e2e.md` — example of a legitimate report that the orchestrator couldn't see
