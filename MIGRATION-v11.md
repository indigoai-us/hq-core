# Migration Guide — v10.10.0 → v11.0.0

**Release date:** 2026-04-15
**Type:** MAJOR (breaking change)
**Headline:** Orchestrator externalization — `/run-project` is now a thin router around `scripts/run-project.sh`.

---

## What changed and why

Before v11, `/run-project` carried the full Ralph-loop orchestrator inline in the command markdown. That coupled orchestration to a command invocation, made cross-session repo coordination impossible (sibling Claude sessions couldn't see each other's active runs), and made the loop unrunnable outside Claude Code.

In v11 the loop lives in `scripts/run-project.sh` as a real shell program. The `/run-project` command is now a thin router that validates arguments and execs the script. The same script powers the repo-level active-run registry, worktree auto-creation, per-story heartbeats, cmux monitor, and stale-PID detection.

**Impact:** Kits that pulled v10.10.0 and rely on `/run-project` will break at the next invocation until they pull `scripts/run-project.sh` and make it executable. That is the reason this is a major bump.

---

## Pre-flight check

Before pulling v11.0.0, confirm your template is on v10.10.0:

```bash
grep -A1 '^## \[' CHANGELOG.md | head -4
```

Expected: `## [10.10.0]` as the top entry. If you're on an older release, walk through the intermediate migration guides first.

---

## Step 1 — Pull the new scripts

Three scripts are required for the new orchestrator. Pull them from the release:

```bash
# Required — orchestrator entrypoint and its dependencies
scripts/run-project.sh          # NEW — externalized Ralph loop
scripts/repo-run-registry.sh    # cross-session repo lock registry
scripts/run-pipeline.sh         # updated (product-specific blocks removed)

# Required — monitor helper relocated under .claude/scripts/
.claude/scripts/monitor-project.sh   # moved from workspace/orchestrator/
```

If you sync via git pull, these land automatically. If you sync file-by-file, copy all four.

---

## Step 2 — Make everything executable

Fresh `.sh` files from a tarball or partial sync will not carry the execute bit:

```bash
chmod +x scripts/run-project.sh
chmod +x scripts/repo-run-registry.sh
chmod +x scripts/run-pipeline.sh
chmod +x .claude/scripts/monitor-project.sh
```

---

## Step 3 — Install the required hooks

Three hooks are **required** for v11 to function safely. Two enforce repo-level run coordination (without them, concurrent sessions can clobber each other's commits). The other two add session-start health checks and resume-sentinel rewriting.

**New required hooks (install and wire into settings.json):**

| Hook | Event | Purpose |
|------|-------|---------|
| `block-on-active-run.sh` | PreToolUse (Edit/Write/Bash) | Hard-block writes into a repo owned by another session |
| `check-repo-active-runs.sh` | SessionStart | Banner listing active runs visible to this session |
| `check-claude-desktop-bridge-health.sh` | SessionStart | Verify Claude Desktop bridge state before it's needed |
| `rewrite-resume-sentinel.sh` | UserPromptSubmit | Rewrite `<<autonomous-loop-dynamic>>` on resume |

**Settings.json wiring — three edits:**

1. **Add a new `UserPromptSubmit` event block** (did not exist in v10.10.0):

```json
"UserPromptSubmit": [
  {
    "matcher": "",
    "hooks": [
      {
        "type": "command",
        "command": ".claude/hooks/hook-gate.sh rewrite-resume-sentinel .claude/hooks/rewrite-resume-sentinel.sh",
        "timeout": 5
      }
    ]
  }
]
```

2. **Move `context-warning-60` from SessionStart → Stop.** The 60% advisory fires after an assistant turn, not on session start. In v10.10.0 it was incorrectly wired under SessionStart; move that hook entry into the existing `Stop` hooks array.

3. **Add `check-claude-desktop-bridge-health` under SessionStart** in the slot previously held by `context-warning-60`.

After these three edits, your settings.json should declare hooks for six event types: `PreToolUse`, `PostToolUse`, `PreCompact`, `Stop`, `SessionStart`, `UserPromptSubmit`.

---

## Step 4 — Verify the orchestrator script runs

Before your next real orchestrator run, smoke-test the new entrypoint:

```bash
bash scripts/run-project.sh --help
```

Expected: usage banner listing `--company`, `--project`, `--worker`, and the standard Ralph-loop flags. If you see `command not found` the chmod from Step 2 was skipped. If you see a Python/Node stack trace, you're still on the old inline orchestrator — confirm `/run-project` now routes to the script (read `.claude/commands/run-project.md` and verify it execs `scripts/run-project.sh`).

---

## Step 5 — Repo coordination sanity check

Open two Claude sessions in the same repo. In the first, run `/run-project` against any project. In the second, try to edit a file in that same repo. The Edit should be hard-blocked with exit code 2 and a message pointing at `block-on-active-run.sh`. Read/Grep/Glob/`git status` must still work in the second session.

If writes are NOT blocked, `block-on-active-run.sh` is missing from your PreToolUse wiring. Re-check Step 3.

Emergency bypass (audited): `HQ_IGNORE_ACTIVE_RUNS=1 <command>`. Logs to `workspace/learnings/active-run-bypasses.jsonl`.

---

## Step 6 — Update command references

Fifteen core commands were refreshed alongside the orchestrator work. None of them are breaking on their own, but if you've forked any of these locally, reconcile your fork against the v11 versions:

`brainstorm`, `document-release`, `execute-task`, `harness-audit`, `land` (new), `learn`, `personal-interview`, `prd`, `quality-gate`, `retro`, `review`, `setup`, `strategize`, `tdd`, `update-hq`.

`land.md` is new — it's a post-merge gate that watches CI + prod metrics after you ship. Read the command file for the full flow.

---

## Rollback

If v11 breaks your workflow, roll back by pulling the v10.10.0 tag. Revert your settings.json edits by removing the `UserPromptSubmit` block and the two SessionStart/Stop moves. The new scripts can stay on disk — they're inert until `/run-project` invokes them.

Your v10.10.0 `/run-project` command will resume carrying the inline orchestrator, and concurrent sessions lose repo coordination (which you did not have before v11 anyway).

---

## Getting help

- Breakage in the orchestrator loop itself → read `scripts/run-project.sh` header comments
- Hook misconfiguration → `bash .claude/hooks/hook-gate.sh --help`
- Policy questions → `.claude/policies/repo-run-coordination.md`
- Changelog detail → `CHANGELOG.md` → `[11.0.0]` entry
