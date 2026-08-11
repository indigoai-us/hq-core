---
id: hq-foreground-timeout-killed-by-harness-deadline
title: Don't wrap long work in a foreground `timeout Ns` Bash call — the harness outer deadline wins and SIGTERMs it
scope: global
trigger: launching a long-running command (build, full test suite, Codex runner, batch job) from a foreground Bash tool call
when: timeout || codex-workflow || workflow-runner || e2e || build || long-running || 2400 || background
on: [PreToolUse, AssistantIntent]
enforcement: soft
public: true
version: 3
created: 2026-08-10
updated: 2026-08-11
source: session-learning
related: hq-bash-discipline, hq-soft-timeouts-warn-dont-kill
---

## Rule

NEVER rely on a foreground Bash tool call's own timeout — whether the `timeout <N>s` coreutils prefix or the tool's `timeout` parameter — to keep a long-running command alive past the harness ceiling. The Claude Code Bash tool observed in this incident enforces its own **2-minute default / 10-minute maximum** outer deadline and SIGTERMs the process at that ceiling **regardless of any longer timeout you declared**. The command dies with **exit 143** ("Command timed out after 10m 0s") and any work in flight is lost.

Treat those exact limits as evidence from that harness, not as a portable promise for every agent runtime. Before choosing a foreground execution path, verify the active runtime's outer deadline; if the work could exceed it, use that runtime's supported background or supervised execution mechanism.

```bash
# WRONG — declares 2400s but the harness kills it at 600s (exit 143):
timeout --foreground 2400s node core/scripts/workflow-runner.mjs <script> 2>&1 | tail -80
#   → Exit code 143 — Command timed out after 10m 0s

# RIGHT — launch as a harness-tracked background task (Bash run_in_background: true).
# It survives turn boundaries and auto-notifies on completion; no outer deadline applies.
#   (The workflow runner is already launched this way.)
```

For anything that can plausibly exceed ~2 minutes — a full test/e2e suite, a real build, a Codex runner invocation, a batch extraction over large data — launch it with `run_in_background: true` and wait for the completion notification (or poll its log), rather than blocking a foreground call and hoping the declared timeout is honored. It will not be.

## Rationale

Discovered 2026-08-10 by the harness-error analysis and confirmed team-wide as **finding 2.1 — "Fixed deadlines and forced kills," 1,393 events across seven members** (Hassaan 916, Stefan 215, Shawon 96, Jacob 91, Geoff 38, Shahzaib 34, Jonathan 3), on Claude Opus/Fable/Sonnet and Codex. A representative case launched the workflow runner under `timeout --foreground 2400s …` with the tool `timeout` set to 2,460,000 ms, and the harness still killed it at exactly 10m 0s with exit 143 — the runner never finished and produced nothing.

The declared timeout gives false confidence: the coreutils `timeout` prefix and the tool's `timeout` field bound the command from *inside*, but the harness bounds it from *outside* at a lower ceiling, and the outer bound always wins. The only reliable way to run past the ceiling is to move the work off the foreground call entirely (harness-tracked background task, or a supervised out-of-session unit for durable monitors).

We cannot change the harness ceiling, and we cannot make it warn-and-continue instead of kill. So the mechanical guard prevents the *kill* by redirecting long foreground declarations to background before they are launched — background is the warn-and-continue equivalent for the one deadline seam HQ does not own. Where HQ *does* own the supervision (its own child processes), warn-and-continue is implemented directly; see `hq-soft-timeouts-warn-dont-kill`.

## Enforcement

Backed by the release-shipped PreToolUse hook
`.claude/hooks/block-foreground-timeout-over-harness-ceiling.sh` — a thin SHIM
that forwards the payload to `hq core timeout-guard` and blocks iff the guard
exits 2 (shim test: `core/scripts/tests/block-foreground-timeout.test.sh`;
registered in `.claude/settings.json` and all three `hook-gate.sh` profile
lists). The decision logic and the rollout gate live in the CLI:

- **Rollout gate:** the guard only acts for a designated internal HQ email
  domain during rollout (the domain is configured in the CLI, not hard-coded in
  hq-core); every other identity, machine identity, or logged-out session is
  allowed through. The shim fails OPEN when `hq` is absent or too old.
- **Effective-deadline comparison:** an inner `timeout`/`gtimeout` (matched by
  executable basename, so `/usr/bin/timeout` counts) or `perl -e 'alarm(N)…'`
  deadline is compared against the *effective* ceiling — the declared tool
  `timeout` (capped at the 600000ms max) or the ~120000ms default when none is
  declared — not always against the 10-minute max. A tool `timeout` > 600000ms
  is blocked outright.
- Never fires on `run_in_background: true` or within-ceiling timeouts. Escape
  hatch: `HQ_ALLOW_LONG_FOREGROUND=1` in the env or inline on the command.
- Unit-tested in hq-cli (`timeout-guard`).

Coverage is cross-backend: the Codex and Grok hook adapters normalize their
shell tool calls (`exec`, `run_terminal_command`) to the same
`tool_name=Bash`/`tool_input.command` shape Claude uses, so this one guard fires
for all three. Routing is verified through the real Grok adapter
(`core/scripts/tests/hq-grok-hook-adapter.test.sh`, end-to-end when a gated
guard is active) and the Codex adapter dispatch
(`core/scripts/test-codex-hook-adapter.sh`).

## Related

- `hq-soft-timeouts-warn-dont-kill` — the warn-don't-kill principle and the `soft-timeout.sh` primitive for work HQ supervises itself.
- `hq-bash-discipline` — BSD/GNU `timeout` portability trap (`timeout` is not on macOS by default).
