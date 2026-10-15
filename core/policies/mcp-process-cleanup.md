---
id: mcp-process-cleanup
title: MCP Server Process Cleanup
when: mcp || .mcp.json
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
created: 2026-04-06
public: true
---

## Rule

MCP servers spawned via stdio (npx/tsx) leak as orphaned processes when Claude sessions end. The `cleanup-mcp-processes` hook stops these at session exit. It is registered for **SessionEnd**, never Stop: Stop fires at the end of every assistant turn, and the Stop registration reaped the live session's own helpers (feedback_1f67ad54). It acts only for the exit reasons `logout`, `prompt_input_exit` and `other`; `/clear` and a missing reason signal nothing. This hook MUST remain in all profiles (minimal, standard, strict).

Known leakers:
- `slack-mcp/src/server.ts` — 2 node processes per session (~200MB each)
- `advanced-gmail-mcp/src/server.ts` — disabled 2026-04-06, was leaking same pattern
- `agent-browser` — Chromium engine, 2-4 GB per leaked instance
- `detached-flush.js` — Next.js telemetry orphans (~100MB each)

**The cleanup is session-scoped, and must stay that way.** HQ runs a shared multi-agent fleet, so a Stop hook that sweeps by command-line pattern reaps other owners' live work. The hook therefore:

1. Kills **only descendants of the exiting session's own host process**: the nearest ancestor whose executable is `claude` or `codex`. An ancestor shared by several sessions (the desktop app, a terminal) never counts. It signals nothing when no owner is found, when the owner is a server-mode host (`app-server`, `exec-server`, `mcp-server`), or when another session host sits below the owner. A match outside the owner's tree is left alone no matter how orphaned it looks.
2. Matches patterns **anchored to the executable or script path**, so a worker whose prompt merely names a server is not mistaken for one.
3. **Never kills agent workloads** (`codex exec`, the workflow runners `workflow-runner.mjs` / `ultracode-workflow.mjs` / legacy `codex-workflow.mjs`, `agency-worker`, `claude`, `codex`, `grok`), even in-tree — a session that spawned workers must not reap them on its way out.
4. **Re-checks identity** (start time and full command line from the snapshot row that selected the process) before TERM and again before KILL, so a recycled or re-exec'd PID is not signalled.
5. **Reports what it signalled and skipped** on every run. The temp sweep removes only `hq-checkpoint-last-*` and `hq-screenshot-count-*` files older than 60 minutes whose PID is gone.

Never reintroduce a bare `pgrep -f` / `pkill -f` sweep here; see hard policy `no-machine-wide-process-pattern-kills`. Regression coverage: `core/scripts/tests/cleanup-mcp-session-scope.test.sh`.

Because scoping is strict, servers that leak *and* get reparented away from the session survive this hook by design. That is the accepted trade: memory is recoverable, another operator's killed work is not. Escalate genuine accumulation to the operator rather than widening the sweep.

## Rationale

Diagnosed 2026-04-06: 250+ GB RAM usage crashed machine (96 GB physical). Root cause was 12+ orphaned Slack MCP server instances accumulated across sessions. Node.js/tsx processes ignore SIGHUP, so they survive parent Claude process termination.

Scoping added 2026-07-30: the hook had been running `pgrep -f <pattern>` machine-wide and SIGTERM/SIGKILLing every match, on every session stop, in Claude, Codex, and Grok alike — while its own header claimed it scoped by PPID. It never did; there was no ownership check in the implementation at all. Any process on the box whose command line contained one of the four patterns was killed regardless of owner, which is the same failure mode as the 2026-07-28 incident that destroyed a 63-minute build and every live Agency worker.
