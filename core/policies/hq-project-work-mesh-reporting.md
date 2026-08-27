---
id: hq-project-work-mesh-reporting
title: Report Active Project Work To The HQ Work Mesh
when: project || prd || run-project || execute-task || startwork
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: hard
public: true
version: 2
created: 2026-07-05
source: user-request
tags: [projects, collaboration, work-mesh, mqtt, hq-pro]
---

## Rule

For company-scoped project work on a cloud-connected HQ install, agents MUST
attempt to use the HQ work mesh before and during the work:

0. **Task / Board status comes from the work mesh, not local `prd.json`.**
   Read `stories[]` (`id`, `title`, `status`) from
   `bash core/scripts/work-mesh.sh ground --company {co} --project {project} --json`
   (or `check --json`). Fallback file:
   `~/.hq/work-mesh/cache/projects/{companyUid}/{projectId}.json`.
   Local `prd.json` is spec (description, acceptance, files). Use it for Board
   columns **only when** the helper skipped/failed **and** that cache file is
   missing. Never treat `prd.passes` as remaining work.

1. Before creating or starting a project, check for active mesh threads for the
   same company/project with `bash core/scripts/work-mesh.sh check --company
   {co} --project {project}` and surface active owners or blockers before
   duplicating effort.
2. When a project is created, and whenever a **task** starts, waits, or
   finishes, make **one** call:

   `bash core/scripts/work-mesh.sh report --company {co} --project {project}
   [--task {id} --status doing|waiting|done] [--summary "…"]`

   That single invocation seeds the Board from local `prd.json` if missing,
   moves the task when `--task` is set, and records the update. Do not issue
   a separate `start` plus `story` pair. Board columns are To do / Doing /
   Waiting / Done (`queued` / `in_progress` / `review` / `done` on the wire).
   `--story` is a hidden alias of `--task`.
3. Use `blocked` or `done` only when you are not already passing that state
   through `report --status` / `--summary`. `start`, `progress`, and `story`
   remain aliases of the same helper.

The attempt is mandatory; success is not. The helper is best-effort and exits
zero when the install is local-only, logged out, not a company member, or the
work-mesh API is unavailable. Do not block project work solely because mesh
reporting failed.

Use the helper rather than direct MQTT publishing. Thread events are written
through the hq-pro work-mesh API; MQTT/IoT is the server-side fanout mechanism.
For live awareness, local agents and HQ instances MAY run
`bash core/scripts/work-mesh.sh watch` to subscribe to the authorized MQTT
topics (`topics.work` and company `thread/#`) and maintain
`workspace/work-mesh/live-cache.json`. The watcher is read/listen only for
thread traffic; writes still go through `report` (or the `start` / `progress` /
`blocked` / `done` / `note` aliases).

## Rationale

The work mesh is the real-time coordination surface for active HQ work. Agents
that skip it make project ownership invisible, increase duplicate effort, and
hide blockers from teammates. Keeping the contract fail-soft preserves local
and offline workflows while ensuring cloud-connected agents leave a live trail.
