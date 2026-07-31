---
id: hq-project-work-mesh-reporting
title: Report Active Project Work To The HQ Work Mesh
when: project || prd || run-project || execute-task || startwork
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: hard
public: true
version: 1
created: 2026-07-05
source: user-request
tags: [projects, collaboration, work-mesh, mqtt, hq-pro]
---

## Rule

For company-scoped project work on a cloud-connected HQ install, agents MUST
attempt to use the HQ work mesh before and during the work:

1. Before creating or starting a project, check for active mesh threads for the
   same company/project with `bash core/scripts/work-mesh.sh check --company
   {co} --project {project}` and surface active owners or blockers before
   duplicating effort.
2. When a project or PRD is created, report it with `start` or `progress`.
3. During execution, report meaningful progress, blocked states, and completion
   with `progress`, `blocked`, and `done`.

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
thread traffic; writes still go through `start`, `progress`, `blocked`, `done`,
and `note`.

## Rationale

The work mesh is the real-time coordination surface for active HQ work. Agents
that skip it make project ownership invisible, increase duplicate effort, and
hide blockers from teammates. Keeping the contract fail-soft preserves local
and offline workflows while ensuring cloud-connected agents leave a live trail.
