# Grok adapter — work mesh session loop (live)

Grok-only. Presence is automatic via US-010 enqueue hooks. Do **not** call the
deleted `core/scripts/work-mesh.sh` / `work-mesh-session.sh` helpers.

## Automatic

Hooks append `session_start` / `turn_start` / `turn_end` / `session_end` and
bump `toolWrites`. A detached `hq mesh context reconcile` runs at session start.

## When clarification is pending

Grok hooks are passive (cannot inject AskUserQuestion). If
`~/.hq/work-context/sessions/<sid>.pending-decision` exists (or additionalContext
says a decision is pending):

```bash
hq mesh context organize --session <sid> list
hq mesh context organize --session <sid> --decision <decisionId> --option <optionId>
# or: --untracked   (explicit user choice only)
```

Do not invent a project. Do not mkdir `companies/<slug>`.

## Manual Board signals only

```bash
hq mesh session task-status --session <sid> --enqueue --seq <n> --task-id <id> --status in_progress
hq mesh session blocked --session <sid> --enqueue --seq <n> --reason "<reason>"
hq mesh session note --session <sid> --enqueue --seq <n> --summary "<milestone>"
```

Board snapshot (when present): `~/.hq/work-context/sessions/<sid>/board.md`
(written by the daemon). Local `prd.json` is spec only — never treat `prd.passes`
as Board columns.

`HQ_WORK_MESH_DISABLED=1` no-ops the hooks.
