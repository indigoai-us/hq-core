---
type: reference
domain: [engineering, operations]
status: canonical
tags: [work-mesh, presence, hq-cli, daemon, sessions]
relates_to: [policies/hq-project-work-mesh-reporting.md]
---

# Work Mesh Live (hq-core)

Every interactive and agent session is captured through three hq-cli families.
The pack-owned `listen` / `watch` daemon is retired (hq-pack-work-mesh 0.2.0).

## The daemon's `mesh` service

`hq daemon` runs the resident Work Mesh process as its `mesh` service: install
once per machine.

| Command | Purpose |
|---|---|
| `hq daemon install` | Install the daemon; takes over an older standalone LaunchAgent `ai.getindigo.hq-mesh-daemon` or systemd `hq-mesh-daemon.service` |
| `hq daemon status` | Each service's state, `mesh` included |
| `hq mesh daemon doctor` | MQTT, spool depth, held/dead-letter, outbox and flush health |
| `hq daemon disable mesh` | Stop running Work Mesh on this machine |
| `hq daemon restart mesh` | Restart the Work Mesh service |

The `hq mesh daemon` verbs (`install`, `status`, `doctor`, `uninstall`, `run`)
are retiring and still run for one release.

Legacy LaunchAgent `ai.getindigo.hq-work-mesh-listen` is unloaded by pack
`apply.sh` on upgrade and must not be reinstalled.

## `hq mesh context`

Local session binding under `~/.hq/work-context/sessions/<sessionId>.json`
(written only by hq-cli):

- `reconcile --observation-file <path>|--observation-json '<json>'` — resolve company/project (SessionStart spawns once, detached; no `--session`)
- `default get|set|clear` — device default company (dark until migration)
- `untracked <sessionId>` — explicit no-server-record choice
- `organize --session <sid>` — apply a clarification decision
- `correct --session <sid> --to-company <slug>` — explicit cross-company correction

## `hq mesh session`

Hooks enqueue lifecycle kinds. Agents use only (`--session-id`, not `--session`):

- `task-status` — Board/task move
- `blocked` — blocked reason
- `note` — short summary (≤280 chars)
- `flush` — push the local spool now

Reporting is otherwise automatic. See
`core/policies/hq-project-work-mesh-reporting.md` and the skill
`core/skills/work-mesh/SKILL.md`.
