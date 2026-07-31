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

MCP servers spawned via stdio (npx/tsx) leak as orphaned processes when Claude sessions end. The `cleanup-mcp-processes` Stop hook kills these on session exit. This hook MUST remain in all profiles (minimal, standard, strict).

Known leakers:
- `slack-mcp/src/server.ts` — 2 node processes per session (~200MB each)
- `advanced-gmail-mcp/src/server.ts` — disabled 2026-04-06, was leaking same pattern
- `agent-browser` — Chromium engine, 2-4 GB per leaked instance
- `detached-flush.js` — Next.js telemetry orphans (~100MB each)

**The cleanup is session-scoped, and must stay that way.** HQ runs a shared multi-agent fleet, so a Stop hook that sweeps by command-line pattern reaps other owners' live work. The hook therefore:

1. Kills **only descendants of the stopping session's own process tree**. A match outside that tree is left alone no matter how orphaned it looks — reclaiming a stranger's memory is never worth killing a stranger's job.
2. Matches patterns **anchored to the executable or script path**, so a worker whose prompt merely names a server is not mistaken for one.
3. **Never kills agent workloads** (`codex exec`, `codex-workflow.mjs`, `agency-worker`, `claude`, `codex`, `grok`), even in-tree — a session that spawned workers must not reap them on its way out.
4. **Reports what it skipped** instead of sweeping silently.

Never reintroduce a bare `pgrep -f` / `pkill -f` sweep here; see hard policy `no-machine-wide-process-pattern-kills`. Regression coverage: `core/scripts/tests/cleanup-mcp-session-scope.test.sh`.

Because scoping is strict, servers that leak *and* get reparented away from the session survive this hook by design. That is the accepted trade: memory is recoverable, another operator's killed work is not. Escalate genuine accumulation to the operator rather than widening the sweep.

## Rationale

Diagnosed 2026-04-06: 250+ GB RAM usage crashed machine (96 GB physical). Root cause was 12+ orphaned Slack MCP server instances accumulated across sessions. Node.js/tsx processes ignore SIGHUP, so they survive parent Claude process termination.

Scoping added 2026-07-30: the hook had been running `pgrep -f <pattern>` machine-wide and SIGTERM/SIGKILLing every match, on every session stop, in Claude, Codex, and Grok alike — while its own header claimed it scoped by PPID. It never did; there was no ownership check in the implementation at all. Any process on the box whose command line contained one of the four patterns was killed regardless of owner, which is the same failure mode as the 2026-07-28 incident that destroyed a 63-minute build and every live Agency worker.
