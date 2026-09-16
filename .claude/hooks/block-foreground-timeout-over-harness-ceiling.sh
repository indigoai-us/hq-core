#!/bin/bash
# block-foreground-timeout-over-harness-ceiling.sh — PreToolUse hook (Bash).
#
# THIN SHIM. The decision logic and the identity rollout gate live in the
# hq CLI (`hq core timeout-guard`); this hook just forwards the PreToolUse JSON
# on stdin and blocks iff the guard exits 2. Keeping the logic in the CLI means
# it is versioned, tested, and gated in one place across Claude, Codex, and Grok
# (whose shell tool calls all reach this hook normalized to tool_input.command).
#
# Backs finding 2.1 / policy hq-foreground-timeout-killed-by-harness-deadline: a
# FOREGROUND shell tool call is SIGTERM'd at the harness outer deadline (~2m
# default / 10m max) regardless of any longer declared timeout, losing the work.
# The guard blocks a long foreground declaration and steers it to a background
# run.
#
# FAILS OPEN: if `hq` is unavailable, too old to have `timeout-guard`, or errors,
# the command is allowed — a hook must never break tool calls. Only an explicit
# exit 2 from the guard blocks.
#
# Exit codes: 0 = allow, 2 = block.

set -uo pipefail

# No hq on PATH → nothing to enforce here; allow. Drain the payload first: this
# guard runs before the hook reads stdin, and exiting with the pipe unread kills
# the dispatcher's payload writer with SIGPIPE. A dispatcher under `pipefail`
# that records the pipeline status then reports this hook as failing with 141
# even though it exited 0 (the hq-core 15.0.139 fleet-box symptom).
command -v hq >/dev/null 2>&1 || { cat >/dev/null 2>&1 || true; exit 0; }

# Most Bash calls cannot possibly be blocked by timeout-guard. When jq is
# available, inspect the payload just enough to eliminate those calls before
# starting the CLI (which otherwise loads its full command graph). Keep this
# deliberately broader than the CLI parser: a false positive merely invokes the
# existing guard, while a false negative would let a blockable call through.
# Without jq, preserve the original stdin-forwarding behaviour exactly.
if command -v jq >/dev/null 2>&1; then
  payload="$(cat)"
  if jq -e '
    (.tool_input? // {}) as $input
    | (
        (($input.timeout? | if type == "number" then . > 600000 else false end) | not)
        and
        (($input.command? // "") | if type == "string" then (contains("timeout") or contains("gtimeout") or contains("alarm")) else false end | not)
      )
  ' >/dev/null 2>/dev/null <<<"$payload"; then
    exit 0
  fi
  printf '%s' "$payload" | hq core timeout-guard
else
  hq core timeout-guard
fi

# Forward the payload; block ONLY on an explicit guard block (exit 2). Any other
# status (0 allow, or a non-2 error from an older CLI without the subcommand)
# fails open.
rc=$?
[ "$rc" -eq 2 ] && exit 2
exit 0
