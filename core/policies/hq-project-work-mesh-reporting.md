---
id: hq-project-work-mesh-reporting
title: Report Active Project Work To The HQ Work Mesh
when: project || prd || run-project || execute-task || startwork
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: hard
public: true
version: 3
created: 2026-07-05
updated: 2026-09-03
source: work-mesh-live US-010
tags: [projects, collaboration, work-mesh, mqtt, hq-pro]
---

## Rule

Presence and per-turn activity are **automatic** (US-010 enqueue-only hooks +
`hq mesh daemon`). Agents MUST NOT call the deleted `core/scripts/work-mesh.sh`
helper. Do not invent companies or projects from prompt text.

### Automatic (do nothing)

- Session start / turn start / turn end / session end are written by hooks to
  `~/.hq/work-mesh/spool.jsonl`.
- Context binding is resolved by `hq mesh context reconcile` (spawned once at
  SessionStart) and organized via `hq mesh context organize` when clarification
  is required.
- Channel cards and presence are owned by the daemon + server.

### Manual verbs only

When the agent must record a discrete Board/task signal, use the CLI:

```bash
hq mesh session task-status --session-id <sid> --enqueue --seq <n> --task-id <id> --status queued|in_progress|review|done
hq mesh session blocked --session-id <sid> --enqueue --seq <n> --reason "<short reason>"
hq mesh session note --session-id <sid> --enqueue --seq <n> --summary "<<=280 chars>"
```

(`--story` is accepted as an ingress alias of `--task-id` where the CLI allows it.)

### Clarification

If additionalContext instructs a Work Mesh clarification:

- Claude Code: ask once via `AskUserQuestion` with the **exact stable options**,
  then `hq mesh context organize --session <sid> --decision <id> --option <id>`.
- Codex: ask once via `request_user_input` with the same options, then organize.
- Grok: run `hq mesh context organize` (passive hooks cannot ask).

Never create a project from a hook or from a guessed prompt token. Prefer
leaving the session `unresolved` over inventing a tenant or project.

`HQ_WORK_MESH_DISABLED=1` or `HQ_DISABLED_HOOKS` containing `work-mesh` /
`work-mesh-live` disables the live hooks.
