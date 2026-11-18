# Conductor core (runners)

The small always-on part of `/conduct-runners`. hq-cli's
`hq runners session-start` emits the block between the inject markers at
SessionStart when `conduct.runner` resolves to `runner`; in the default
`subagent` mode it emits the block in `.claude/skills/conduct/conductor-core.md`
instead. Keep the block under 750 bytes. The rest of this file is for the
skill and for people.

<!-- inject:start -->
<auto-conduct>
Conduct mode is on with runners (conduct.runner: runner). The conductor coordinates and never does project work.
- Inline only: answer from loaded context, or one status read.
- Lane on a runner: a worker's area, kept open with keep-alive.
- Subagent: a small task, no matching worker; registered so hq runners list shows it.
- Child session: work that needs its own session.
Run `/conduct-runners` with the task; the engine is chosen at first dispatch.
Route by core/settings/intent-index.yaml before reading any skill body. Charter non-negotiables stay in force.
Leave with `/conduct-runners off`; disable the default with HQ_AUTO_CONDUCT=0 or conduct.default_enabled: false in personal/settings/orchestrator.yaml.
</auto-conduct>
<!-- inject:end -->

## Routing rule

The conductor coordinates and never does project work itself. Route each
task to the first row that fits.

| Where | What |
|---|---|
| Inline | An answer from context already loaded in this session, or one status read (`/conduct-runners status`, one board or lane read) |
| Lane on a runner (standing) | A task or an ongoing area of work that matches an HQ worker or a `--workers` role; a detached `hq runners` process kept open with `hq runners keep-alive <lane> --on --standing` takes the follow-up tasks for that worker and company |
| One-shot lane on a runner | Work with no matching worker that must outlive this session or runs on a non-Claude engine |
| Background subagent | A small, bounded task with no matching worker; registered with `hq runners create --runner subagent` so `hq runners list` is the one view |
| Conduct child session | An area that needs its own session; it joins over the conduct link and reports in the same shape as in default mode |

`bash core/scripts/conduct-standing.sh route --kind <answer|status|lookup|small|ongoing>`
applies the table for the `runner` setting, including reuse of a standing
lane already open for the same worker and company. When unsure between
inline and a subagent, use a subagent.

## What stays in SKILL.md

Runner choice, standing lanes, subagent registration, admission fallback,
watchers, and the per-turn rows. Runner mechanics live in `dispatch.md`.
