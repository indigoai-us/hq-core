---
id: claude-desktop-bridge-state-zombie
title: Claude desktop bridge-state.json zombie session leak
scope: global
trigger: Claude desktop memory leak, high RSS, sparse main.log, OOM dialog, slow UI
enforcement: hard
version: 2
created: 2026-04-10
updated: 2026-04-15
public: true
---

## Rule

If Claude desktop shows signs of a memory leak — macOS "out of application memory" dialog, Activity Monitor reporting tens of GB+ for the Claude process, sparse logging in `~/Library/Logs/Claude/main.log`, or slow/unresponsive UI after long uptime — check **`~/Library/Application Support/Claude/bridge-state.json`** first. It is the most likely culprit.

**Zombie signature:**

1. `bridge-state.json` entry has `enabled: true` + `userConsented: true` for a Cowork Ditto sync session (`remoteSessionId: cse_...`, `localSessionId: local_ditto_...`).
2. `processedMessageUuids: []` is empty (bridge never successfully processed any messages despite being "enabled").
3. `~/Library/Logs/Claude/main*.log` contains repeated patterns:
   - `[sessions-bridge] Transport permanently closed for session cse_... code=4090`
   - `[sessions-bridge] Reconnecting transport ... attempt N/6, delay=...ms`
   - `[sessions-bridge] Cap-redispatch budget exhausted for cse_... (N); transport stays dead until app restart or system resume`
4. Secondary amplifier often present: `[Preview] capturePreviewScreenshot failed: Preview not found for server <uuid>` — Claude Preview MCP orphan.
5. **Sparse logging is a leading indicator.** If `main.log` is growing much slower than it should (e.g. 1 MB in 24h when it previously rotated 10 MB in hours), the Node event loop is starved by GC pressure — the leak is already active, mitigate immediately.

**Mitigation (highest-impact first):**

1. Quit Claude desktop (force-quit via macOS "out of memory" dialog if unresponsive).
2. Back up the state file: `cp ~/Library/Application\ Support/Claude/bridge-state.json{,.bak}`
3. Delete the file: `rm ~/Library/Application\ Support/Claude/bridge-state.json` — it will regenerate clean on next Cowork consent.
   - Alternative (more surgical): flip `"enabled": false` for the broken entry only, preserving other entries.
4. Restart Claude desktop. Verify via `tail -f ~/Library/Application\ Support/Claude/main.log` that no `Transport permanently closed` loop appears.
5. If the leak persists after a clean `bridge-state.json`, investigate the Claude Preview MCP orphan as a secondary cause.

## Automated detection

Hook: `.claude/hooks/check-claude-desktop-bridge-health.sh` (SessionStart, advisory).

**Correlated-signal rule (v2, 2026-04-15):** warn only when BOTH fire:

1. **File signature** — `bridge-state.json` has ≥1 entry with `enabled=true` + `processedMessageUuids=[]`.
2. **Log evidence** — `~/Library/Logs/Claude/main.log` and/or `main1.log` contain ≥1 hit for `Transport permanently closed ... code=4090` OR `Cap-redispatch budget exhausted` in the last 5,000 lines.

**Staleness escape valve:** if the file signature matches but logs are clean AND `bridge-state.json` mtime is ≥7 days old, skip the warning — it's a leftover consent from an idle bridge, not an active leak.

**Why the rule tightened (v1 → v2):** v1 checked only signal 1, which is *also* the normal resting state of a healthy bridge (empty processed-uuid queue ≠ zombie). That produced a false positive on every SessionStart and risked numbing users to a real alert. v2 gates on the log discriminators from the rationale below, preserving the 260 GB canary while eliminating the noise.

**Testing the detector:**

```bash
# Healthy state — should be silent
bash .claude/hooks/check-claude-desktop-bridge-health.sh

# Simulate zombie — should emit warning with log-match count ≥ 1
cp "$HOME/Library/Logs/Claude/main.log" /tmp/fake-main.log
printf '[sessions-bridge] Transport permanently closed for session cse_test code=4090\n' >> /tmp/fake-main.log
LOG_FILE=/tmp/fake-main.log bash .claude/hooks/check-claude-desktop-bridge-health.sh
```

## Rationale

**Observed 2026-04-10:** Claude desktop consumed **260.06 GB** of memory (compressed + swap), triggering macOS's "out of application memory" dialog.

**Root cause:** `bridge-state.json` persisted a dead Cowork Ditto sync session (`remoteSessionId: cse_019AMhd3pNAVxdSMPgWWJ4ip` in environment `env_01DsNufyZQqzWCBe79S6AfJe`). Because the file had `enabled: true` + `userConsented: true`, Claude desktop auto-reconnected the zombie on every startup. Each reconnect cycle:

1. `Connecting transport for session cse_...`
2. `attaching SDK bridge`
3. `Scheduled session_ingress_token refresh`
4. `Transport permanently closed ... code=4090` (terminal WebSocket close in app-specific range 4000-4999)
5. Exponential backoff retry (2s → 4s → 8s → 16s), then cap-redispatch.

Each cycle allocated a new SDK adapter, new EventEmitter listeners, and new timers. Over **at least 7 days** (Apr 3 → Apr 10, 2026), the rotated log `main1.log` accumulated **1,722** leak-pattern matches with per-day counts ranging 118–480 (peak Apr 5). The live `main.log` added **970 more** over ~24h post-rotation (~40 cycles/hour sustained rate) — total observed ~**2,700 cycles in 8 days**. The slow-but-compounding allocation leak starved the Electron renderer's heap until macOS OOM'd. **Version context:** Claude desktop app version `1.1617.0` (from `sentry/scope_v3.json`); CCD subcomponent version `2.1.92` (from `main.log` startup banner).

**Secondary amplifier:** Claude Preview MCP held an orphaned preview-server reference (`3ad313fb-9b18-4e0e-8342-90911ef7e14b`) and tight-looped on `capturePreviewScreenshot failed: Preview not found` errors — each error path retained response buffers.

**Leading indicator of active leak:** sparse logging. After log rotation at Apr 9 14:17, `main.log` grew only 1.1 MB in the following 24 hours, vs. `main1.log` accumulating 10 MB in 6 days pre-rotation. When Node's event loop is pegged by GC mark-sweep cycles, log flushes get blocked. **If Claude desktop's logs go quiet while the app stays responsive-ish, you are already in the leak.**

**Design flaw in Claude desktop:** the bridge trusts `enabled: true` + `userConsented: true` more than runtime failure signals. Its own log message says "permanently closed", yet the reconnect logic retries anyway. WebSocket close code 4090 (application-specific range 4000–4999) should be treated as terminal by the bridge, not as transient. This is an upstream bug in the Claude desktop Electron app (version 1.1617.0 observed, confirmed via `~/Library/Application Support/Claude/sentry/scope_v3.json`).

## Related leak vectors

These are independent of the bridge-state zombie but frequently co-occur. Document here for faster triage on future OOMs.

**`createWorktree` git-128 subprocess leak** (main.log lines 790–796):

```
[info] [createWorktree] FETCH_HEAD is 3684s old — fetching origin before worktree add
[error] Git command failed: git fetch --prune origin
[info] [createWorktree] pre-worktree fetch failed (continuing with on-disk refs):
  fatal: 'origin' does not appear to be a git repository
fatal: Could not read from remote repository.
```

Claude desktop's `createWorktree` code path repeatedly spawns `git fetch --prune origin` inside `.claude/worktrees/*` subtrees. Those worktrees are *detached* (no `origin` remote configured), so `git fetch` exits 128 every time. Each failed subprocess leaves a buffered error object. Volume observed 2026-04-10: ~30 git-128 breadcrumbs in sentry vs. ~970 bridge cycles in main.log — much lower, but still a contributor. **Not fixable from HQ** — upstream bug that calls `git fetch` without first validating remote existence. If you see `git exit 128` + `createWorktree` in sentry or main.log, classify as this vector, not the bridge-state zombie.

**Claude Preview MCP orphan** (covered in Rationale "Secondary amplifier"):

The `PreviewError: Preview not found for server <uuid>` pattern is a separate retain-loop, distinct from the bridge. It can exist with or without a zombie bridge entry.

## Related

- Spec: `knowledge/public/hq-core/policies-spec.md`
- Diagnosis plan: `/Users/{your-name}/.claude/plans/recursive-cooking-mitten.md`
- Log locations: `~/Library/Logs/Claude/main*.log`, `~/Library/Logs/Claude/unknown-window*.log`
- State file: `~/Library/Application Support/Claude/bridge-state.json`
- Sentry breadcrumbs (forensic evidence after crash): `~/Library/Application Support/Claude/sentry/scope_v3.json` — contains recent HTTP calls, app memory, version, and error breadcrumbs. Useful for confirming a zombie env is still being polled post-restart.
