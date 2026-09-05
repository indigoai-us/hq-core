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

## `hq mesh daemon`

Resident process: install once per machine.

| Verb | Purpose |
|---|---|
| `install` | LaunchAgent `ai.getindigo.hq-mesh-daemon` or systemd `hq-mesh-daemon.service` |
| `status` / `doctor` | Installed/loaded, MQTT, spool depth, held/dead-letter |
| `uninstall` | Remove the user service |
| `run` | Foreground single-instance process |

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
