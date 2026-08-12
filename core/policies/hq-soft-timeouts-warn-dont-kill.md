---
id: hq-soft-timeouts-warn-dont-kill
title: A timeout on work still making progress should WARN repeatedly, not kill — kill only as a bounded safety cap
scope: global
trigger: adding or reviewing a fixed deadline around a long-running command (monitor, poller, deploy watch, CI wait, builder, batch job)
when: timeout || SIGTERM || SIGKILL || kill-after || deadline || monitor || poller || watchdog || soft-timeout
on: [PreToolUse, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-08-11
source: session-learning
related: hq-foreground-timeout-killed-by-harness-deadline, hq-bash-discipline
---

## Rule

When a command HQ launches and supervises is still making expected progress, a
timeout must **NOTIFY, not terminate**. On each interval the command keeps
running and a `SOFT-TIMEOUT` / `TIMEOUT WARNING` line is emitted so whoever is
watching — an agent, an orchestrator, a human tailing the log — DECIDES what to
do (keep waiting, background it, or kill it). The runner does not decide *for*
them by killing progressing work at a fixed deadline.

A hard kill at a deadline is permitted only as a **bounded safety cap for
unattended callers** (an autonomous loop that could otherwise run forever), and
even then it should be a high multiple of the warn interval, opt-in, and logged
— never the default response to "this is taking a while."

Concretely:

- **Work HQ supervises itself** (its own child processes): use a warn-and-continue
  loop. Two shipped implementations of one contract —
  - `core/scripts/workflow-runner.mjs`: emits `TIMEOUT WARNING: … still running
    after Ns … not killed` every interval and never kills on the soft timeout.
  - `hq core soft-timeout <interval> [--hard-cap <spec>] [--label <name>] -- <cmd…>`:
    the CLI-hosted primitive (hq-cli) — warns every interval to stderr, preserves
    the command's exit status verbatim, and terminates only if an explicit
    `--hard-cap` is reached (SIGTERM to the whole process group, then SIGKILL,
    exit 124). Scripts call this directly rather than a bundled shell helper.
- **Work under a deadline HQ does NOT own** (the outer Bash-tool ceiling on
  Claude, Codex, and Grok): the harness kills at the ceiling and cannot be made
  to warn instead, so prevent the kill by moving the work to
  `run_in_background: true` (no outer deadline, auto-notifies). The guard fires
  across all three backends because their shell tool calls are normalized to
  the same `tool_input.command` shape. See
  `hq-foreground-timeout-killed-by-harness-deadline`.

## Rationale

Team harness analysis 2026-08-10, **finding 2.1 (1,393 events across seven
members)**: fixed 30s/2m/10m ceilings killed operations that were still making
expected progress — deploys, CI/sync monitors, searches, worktree ops — with
exit 143 and loss of in-flight work. The classification was "harness friction"
precisely because some of those commands *would have completed* given more time;
a blind kill cannot tell the difference, but a warned human/agent can.

Do NOT convert a bounded network/IO timeout (a fetch abort, a connection-open
deadline, a subscription window) into a soft warn loop — those bound an
operation that is *not* making progress and are correct as hard bounds. The
warn-don't-kill rule targets deadlines on work that is or may be progressing.

## Enforcement

Principle-level (soft). Mechanically supported by the PreToolUse shim
`.claude/hooks/block-foreground-timeout-over-harness-ceiling.sh` → `hq core
timeout-guard` for the harness-ceiling seam (gated to a designated internal HQ
email domain during rollout, configured in the CLI), and by the `hq core
soft-timeout` primitive for HQ-supervised work.
Both are unit-tested in hq-cli; `core/scripts/tests/run-project-soft-timeout.test.sh`
locks the runner wiring.
