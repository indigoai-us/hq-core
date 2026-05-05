---
id: hq-bash-pgrep-no-hardcode-pids
title: Never hardcode pgrep PIDs across cron firings or orchestrator relaunches
scope: global
trigger: A scheduled task, cron handler, or repeat-firing script needs to operate on a long-running process (orchestrator parent, swarm workers, monitor loop)
enforcement: hard
tier: 1
public: true
version: 1
created: 2026-04-26
updated: 2026-04-26
source: session-learning
---

## Rule

NEVER hardcode a PID discovered by `pgrep` (or `ps`) into a follow-up cron/scheduled-task body, state file, or shell variable that survives across orchestrator relaunches.

- The `/run-project --ralph-mode` orchestrator parent PID changes on every relaunch (each `nohup` start is a fresh process).
- Per-story swarm-worker shell PIDs change every batch — there is no PID stability across stories.
- The cron monitor itself can re-exec on schedule changes.

Always rediscover the target PID on each cron firing via `pgrep -f <pattern>`, then validate with `ps -p <pid> -o command=` (see `hq-bash-pgrep-self-match-validate-with-ps`). Persist only the SEARCH PATTERN, never the resolved PID.

### Wrong

```bash
# Cron body
ORCHESTRATOR_PID=12345  # captured 2 hours ago
kill -USR1 "$ORCHESTRATOR_PID"  # kills whatever process now owns 12345
```

### Right

```bash
# Cron body
PID=$(pgrep -f 'run-project.sh.*<project>' | while read p; do
  ps -p "$p" -o command= | grep -q 'run-project.sh' && echo "$p" && break
done)
[ -n "$PID" ] && kill -USR1 "$PID"
```

## Rationale

PIDs are reused aggressively by the kernel — on macOS the PID space is 99999 and rolls over within hours on a busy system. A cron firing that signals a hardcoded PID may hit the orchestrator on the first tick, an unrelated user shell on the second tick, and `launchd` itself on the third. The blast radius is unbounded.

The orchestrator's own design assumes PID instability: state.json carries `last_orchestrator_pid` only as a debugging breadcrumb, never as a control-plane handle. Cron handlers must follow the same discipline.

## Related

- `.claude/policies/hq-bash-pgrep-self-match-validate-with-ps.md` — companion rule on harness self-matching
- `.claude/policies/hq-cmd-run-project-ralph-hard-pause-procedure.md` — pause flow that depends on fresh discovery
