---
id: hq-mcp-trial-integration-pattern
title: MCP server trial integration pattern — launcher, idle pattern, registration, co-location, hot-reload asymmetry
scope: global
trigger: When integrating a new MCP server as a staged trial (kill switch + launcher + trial artifacts) in HQ
enforcement: soft
public: true
version: 1
created: 2026-04-19
updated: 2026-04-19
source: session-learning
---

## Rule

Five structural invariants govern every MCP-server trial in HQ. Apply all five together — they compose into the reusable playbook that mirrors the hook-trial equivalent in `hq-trial-hooks-stage-in-settings-local.md`.

### 1. Kill switch lives in a launcher shell script, not inline in `.mcp.json`

`.mcp.json` only accepts a command path plus args — NOT an inline shell expression. The env-var guard idiom `[ "${HQ_X_DISABLED:-0}" = "1" ] || exec <cmd>` CANNOT live in `.mcp.json` the way it lives in a PreToolUse hook's `command` field in `.claude/settings.local.json`.

Write a launcher script (`workspace/reports/{trial-name}/{trial-name}-launcher.sh`) that performs the env-var guard, then exec the real MCP binary. Point `.mcp.json` at the launcher path. The launcher is the idiomatic bridge between `.mcp.json`'s command-only field and the env-var kill-switch UX.

### 2. Use `exec cat >/dev/null` as the idle pattern, never `sleep infinity`

When the kill switch trips, the launcher must hold stdio open until Claude Code closes the pipe at session end — otherwise Claude Code logs "MCP server crashed" or attempts a crash-loop reconnect.

Portable idle pattern:

```bash
if [ "${HQ_X_DISABLED:-0}" = "1" ]; then
  exec cat >/dev/null
fi
exec /path/to/real-mcp-binary "$@"
```

Why `cat`, not `sleep`:

- `sleep infinity` is invalid on BSD/macOS — `sleep` requires a numeric argument and errors out immediately (which then becomes the crash-loop we're trying to prevent).
- `exit 0` makes Claude Code log "MCP server crashed" on every session start even though the behavior is intentional — noisy false signal.
- `cat >/dev/null` blocks on stdin until Claude Code closes the pipe, then exits 0 cleanly. No orphan processes, no crash logs.

### 3. Register MCP servers in `.mcp.json`, NOT in `.claude/settings.local.json`

`.claude/settings.local.json` rejects a top-level `mcpServers` key with `Unrecognized field: mcpServers`. The settings schema only exposes three MCP controls:

- `enabledMcpjsonServers` — allowlist of servers from `.mcp.json` to auto-attach.
- `disabledMcpjsonServers` — denylist.
- `enableAllProjectMcpServers` — boolean switch.

All three operate on entries already defined in `.mcp.json` (project root, gitignored by default). Adding a new MCP server means editing `.mcp.json` — there is no settings-level alternative.

This is a structural asymmetry from hook trials: a new PreToolUse hook CAN be added to `.claude/settings.local.json`'s `hooks` array directly and composes at runtime with the tracked `.claude/settings.json`. MCP servers have no equivalent local-overlay mechanism in the settings file.

### 4. Co-locate trial artifacts under `workspace/reports/{trial-name}/`

Launcher, README, baseline metrics, and any support scripts all live under `workspace/reports/{trial-name}/` — NOT under `.claude/hooks/` or `scripts/` (both protect-core locked; a trial is not HQ infrastructure).

Benefits:

- **No `HQ_BYPASS_CORE_PROTECT=1` required** — the tracked kernel stays untouched.
- **Revert is trivial**: `rm -rf workspace/reports/{trial-name}/` + remove the `.mcp.json` block. Two atomic operations, no git history to untangle.
- **Trial stays self-contained** — future sessions can find every artifact for the trial (decision log, launcher, baseline) at one path, not scattered across the repo.
- **Mirrors the hook-trial layout** at `workspace/reports/rtk-trial/`, so the pattern is already familiar and has precedent.

### 5. Document the MCP-vs-hook hot-reload asymmetry in the kill-switch policy

Whenever a kill-switch policy references a hook-trial precedent (e.g. "modeled on the RTK trial kill switch"), it MUST call out this runtime difference explicitly:

| Layer | Re-evaluation cadence | Env-var flip takes effect |
|-------|----------------------|---------------------------|
| PreToolUse hook command | Per tool call | Immediately mid-session |
| MCP server | Once at session start | Only after Claude Code restart |

Claude Code attaches MCP servers during the initialize handshake at session start. Flipping `HQ_X_DISABLED=1` mid-session does NOT detach an already-attached server or skip the next-tool-call launcher invocation — it takes effect on the NEXT session start. Hook commands, by contrast, re-read their env at every PreToolUse fire.

A kill-switch policy that silently claims parity with a hook-trial precedent misleads future operators. The policy copy must say: "restart Claude Code for the env-var flip to apply."

## Rationale

Derived from the context-mode MCP trial (staged 2026-04-18, commits around `41f633bf3`). Each of the five facets was an independent correction discovered during the staging session:

1. First attempt put the env-var guard inline in `.mcp.json`; Claude Code's MCP client silently treated the shell expression as an unknown binary. Rewriting the guard into a launcher script was the structural fix.
2. First launcher draft used `sleep infinity` (copied from common Linux idiom). macOS `sleep` exited with `usage: sleep seconds` which triggered the MCP crash-reconnect loop and flooded `~/.context-mode/` logs. `exec cat >/dev/null` replaced it.
3. An earlier draft tried adding the server under `mcpServers:` in `.claude/settings.local.json`. Claude Code's settings schema rejected the whole file with `Unrecognized field: mcpServers` — the file failed to parse at all, which took down every other local override until the bad block was removed.
4. The first "where does the launcher live?" attempt targeted `.claude/hooks/context-mode-launcher.sh`. `protect-core` blocked the write. `workspace/reports/context-mode-trial/` bypassed the lock without needing `HQ_BYPASS_CORE_PROTECT=1`.
5. Post-staging, a test confirmed that flipping `HQ_CONTEXT_MODE_DISABLED=1` mid-session did NOT detach the already-attached MCP tools. The existing `hq-context-mode-kill-switch.md` buried this in rationale; future trials need the asymmetry called out at Rule level.

Companion policies:

- `hq-context-mode-kill-switch.md` — concrete three-layer kill switch for the current trial.
- `hq-context-mode-trial-scope.md` — trial scope invariants (where the binary stays staged).
- `hq-trial-hooks-stage-in-settings-local.md` — hook-trial staging pattern; this policy is the MCP equivalent.
- `hq-rtk-init-preview-hook-command.md` — RTK precedent that inspired the kill-switch idiom.
- `mcp-process-cleanup.md` — orphan MCP cleanup on session exit (composes with rule 2's idle pattern).
- `hq-bash-discipline.md` — broader bash-portability umbrella (rule 4 is a specific instance).
