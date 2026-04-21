---
name: run-project
description: "Default: inline execution of PRD stories in-session (per-story Task sub-agents). Use --ralph-mode for the background orchestrator (nohup scripts/run-project.sh + state-file polling). Use --session-mode for plan-file-anchored inline execution."
allowed-tools: Read, Bash(bash:*), Bash(jq:*), Bash(cat:*), Bash(tail:*), Bash(kill:*), Bash(ls:*), Bash(mkdir:*), Bash(nohup:*), Bash(echo:*), Bash(sleep:*), Bash(qmd:*)
argument-hint: "{project} [--status] [--resume] [--dry-run] [--inline] [--ralph-mode] [--session-mode]"
---

# Run Project — Dispatch Shim

**Default is inline.** A bare `/run-project {project}` invocation executes stories in-session via per-story Task sub-agents — it does NOT launch `scripts/run-project.sh`. Pass `--ralph-mode` to opt into the background orchestrator.

Policy: `.claude/policies/run-project-default-is-inline.md` (hard). For full execution details, flags, swarm mode, and worked examples: `.claude/commands/run-project.md`.

**User's input:** $ARGUMENTS

---

## Step 1 — Parse Arguments & Route

Extract from `$ARGUMENTS`:

- `{project}` — project name (required unless `--status`)
- `--status` → run `bash scripts/run-project.sh --status` synchronously, display output, stop
- `--dry-run` → run `bash scripts/run-project.sh --dry-run {project}` synchronously, display output, stop
- `--help` → display flags from `.claude/commands/run-project.md`, stop
- `--session-mode` → **route to session-mode execution** per `.claude/commands/run-project.md` "Session-Mode Execution" section. Load that section and follow it. Error immediately if combined with `--inline`, `--ralph-mode`, `--tmux`, `--swarm`, `--codex-autofix`, `--dry-run`, or `--status`. Governed by `.claude/policies/run-project-session-mode.md` (hard).
- `--ralph-mode` → **route to background orchestrator** (Steps R1–R5 below). Error immediately if combined with `--inline` or `--session-mode`.
- `--inline` → **silent alias for default** — route to Inline Execution (see below). No warning, no error.
- Default (no execution-mode flag) → **route to Inline Execution** per `.claude/commands/run-project.md` "Inline Execution" section. Load that section and follow it.

If no arguments: error — project name required.

## Step 2 — Inline Execution (Default)

Hand off to `.claude/commands/run-project.md` "Inline Execution" section. Steps:

1. Preflight delegation (single Plan sub-agent) — produces markdown plan + JSON state.
2. `ExitPlanMode` approval.
3. Warm-start (`/checkpoint` + `/compact`).
4. Per-story loop: each story runs inside ONE fresh `general-purpose` Task sub-agent that invokes `/execute-task` internally.
5. Regression gates every 3 stories.
6. Completion flow.

Plan-mode preflight MUST obey `.claude/policies/plan-mode-preflight-delegation.md` — parent reads nothing heavy before `ExitPlanMode`.

---

## Ralph Mode (--ralph-mode) — Background Orchestrator

Legacy shape: `nohup bash scripts/run-project.sh ...` runs each story as an isolated `claude -p` subprocess; parent session polls state files.

### Step R1 — Validate PRD

1. Resolve PRD: `companies/{co}/projects/{project}/prd.json` (use `qmd search` if needed)
2. Read prd.json → display: project name, company, total stories, completed, remaining
3. `mkdir -p workspace/orchestrator/{project}`

Under Claude Code plan mode, delegate the read to a Plan sub-agent per `.claude/policies/plan-mode-preflight-delegation.md` — do NOT read prd.json directly in the parent.

### Step R2 — Launch Background

```bash
cd /Users/{your-name}/Documents/HQ && \
  nohup bash scripts/run-project.sh {project} {passthrough_flags} --no-permissions \
  > workspace/orchestrator/{project}/run.log 2>&1 &
echo "PID:$!"
```

Capture PID. Announce: `Launched run-project.sh for {project} (PID {pid}, --ralph-mode). Monitoring progress...`

### Step R3 — Poll Loop

Every ~30 seconds:

1. Read state: `jq -r '.status' workspace/orchestrator/{project}/state.json`
2. Read new progress: `tail -n +{last_line} workspace/orchestrator/{project}/progress.txt`
3. Check PID: `kill -0 {pid} 2>/dev/null && echo "ALIVE" || echo "DEAD"`
4. Print new progress lines
5. Branch:
   - `in_progress` + alive → continue polling
   - `paused` → surface pause reason from `run.log`, prompt user: resume / abort
   - `completed` → exit loop → Step R4
   - PID dead + not completed → tail `run.log`, report error

Poll ceiling: 4 hours. After that, offer to detach.

### Step R4 — Completion Summary

1. Read final `state.json` + `progress.txt`
2. Read `workspace/reports/{project}-summary.md` if exists
3. Display formatted summary

### Step R5 — Reindex

Run `qmd update 2>/dev/null || true` after completion.
