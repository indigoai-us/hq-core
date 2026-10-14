# run-project progress band

A Claude Code mod (function-hooks plugin) inside the `run-project` skill. While
`/run-project` runs, it shows how many PRD stories are done and how many remain.

```
run-project  my-project  ████████░░░░░░░░  6/14 done  1 failed  7 left
▶ US-007 Exposure event logging (3m 10s)  ETA ~41m  gate ✓ US-006   [Details] [Hide]
```

## How it loads

`.claude/skills/run-project/` is both the skill (`SKILL.md`) and a plugin
(`.claude-plugin/plugin.json`). Claude Code loads it as `run-project@skills-dir`
in trusted sessions started at the HQ root; `/run-project` is still the same
skill. There is nothing to install.

The mod does nothing until a `run-project` skill expands with a project to
run. Only then does it register `/story-progress` and start reading state. A
session that never runs `/run-project` gets no command, no band and no status
line from it.

`run-project` is not bundled into HQ Anywhere or the Codex pack (its SKILL.md
uses HQ checkout paths), and `build-claude-plugin.test.sh` fails if a bundled
skill ever carries its own plugin manifest.

To turn the band off on one machine, set it to `false` in `.claude/settings.local.json`:

```json
{ "enabledPlugins": { "run-project@skills-dir": false } }
```

## What it does

- When any `run-project` skill expands (`run-project`, `hq-run-project`,
  `hq-pack-engineering:run-project`, ...), it reads the project from the
  skill's `**User's input:**` line. `--status`, `--dry-run` and `--help` are
  ignored because they do not run stories.
- Every 5 seconds it reads `workspace/orchestrator/{project}/state.json` and,
  once the company check below passes, the PRD that `prd_path` names, until the run's `status` is `completed`. A
  `completed` state.json already there when `/run-project` starts is an
  earlier run's, so it keeps reading until the new run rewrites it.
- With `--pipeline` it also reads the conductor's story files,
  `workspace/orchestrator/{project}/pipeline/state/stories/*.json`, which own
  story state in that mode.
- It shows a run only when the run belongs to this session's company
  (`workspace/sessions/{session}/scope-capability.json`): state.json's
  `company`, and the company its `prd_path` is under, must both be locked
  when set, and at least one must be. Otherwise the band shows no counts, no
  status line and no toasts, only why. Only the lock's primary company counts
  (the shell resolver's multi-company kill switch is not readable from a mod),
  and a company folder that is a symbolic link grants nothing.
- The band above the prompt shows done / total, failed and blocked counts,
  stories left, the running story and how long it has run, an ETA (mean time
  per finished story × stories left), and the last regression gate.
- The status line shows `stories 6/14 · 1 ✗`. Toasts announce each story that
  finishes, fails or is blocked, a failed regression gate, and the end of the run.
- **Details** opens a pane listing every story with its status and duration.

Story durations are approximate: `state.json` records when a story finished,
not when it started, so finished stories (failed ones included) are timed back
to back from the run's `started_at`.

A story counts as blocked when state.json lists it in `blocked_tasks` or a
`failed_tasks` entry's `error` starts with `blocked` (`blocked: TIMEOUT`). The
board status `hq lanes story block` sets is not read here.

## Commands

Available once `/run-project` has run in the session:

| Command | Effect |
| --- | --- |
| `/story-progress show` / `hide` | Show or hide the band |
| `/story-progress pane` | Open the details pane |
| `/story-progress watch <project> [--pipeline]` | Attach to a run started elsewhere |
| `/story-progress stop` | Clear the band and stop reading state |

## Developing

```bash
claude plugin validate .claude/skills/run-project
claude plugin test .claude/skills/run-project
```

The engine writes this build's API types to `.claude-plugin/types/` (in
`.gitignore`) when it loads the mod; `tsc -p .claude/skills/run-project` then
type-checks it.
