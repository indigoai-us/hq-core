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

# No hq on PATH → nothing to enforce here; allow.
command -v hq >/dev/null 2>&1 || exit 0

# Forward the payload; block ONLY on an explicit guard block (exit 2). Any other
# status (0 allow, or a non-2 error from an older CLI without the subcommand)
# fails open.
hq core timeout-guard
rc=$?
[ "$rc" -eq 2 ] && exit 2
exit 0
