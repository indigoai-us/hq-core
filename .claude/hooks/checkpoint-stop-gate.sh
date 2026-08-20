#!/usr/bin/env bash
# Stop hook: delegate to the CLI-hosted checkpoint gate.
#
# The gate itself — the checkpoint requirement, the reply demand, the
# consecutive-block loop guard and the opt-in company-scope gate — lives in the
# CLI as `hq core checkpoint-stop-gate` (asset
# assets/scaffold/core/scripts/checkpoint-stop-gate.sh in indigoai-us/hq-cli).
# This file only finds it and hands over stdin.
#
# There is deliberately NO in-tree copy of that logic. One shipped here until
# 2026-08-20 as a transitional fallback for CLIs predating the command, and the
# duplication cost exactly what duplication costs: the two copies drifted (the
# CLI ran three fixes behind at one point), every change needed a matched pair
# of PRs, and each repo grew a suite whose real job was detecting the drift.
# The scaffold and the CLI also ship on different cadences — the scaffold only
# refreshes on `/update-hq`, the CLI updates itself — so the CLI copy is the one
# that actually runs on an operator box. Keeping the second copy meant
# maintaining a version almost nobody executed.
#
# When the CLI cannot provide the gate, this hook does nothing and the turn ends
# normally. That is the same never-strand-a-session doctrine every error path in
# the gate follows: no gate is a missing convenience, a broken gate is a wedged
# operator. `hq core checkpoint-stop-gate` has shipped since hq-cli 5.99.0
# (2026-08-11) and the CLI self-updates, so this path means a CLI that is both
# very stale and not updating — a state `hq doctor` reports and `hq self-update`
# fixes.
#
# HQ_CHECKPOINT_GATE_NO_CLI=1 skips delegation, which now means the gate does
# not run at all. HQ_CHECKPOINT_GATE=0 (read by the CLI) is the supported
# operator kill switch.

set -uo pipefail

[ "${HQ_CHECKPOINT_GATE_NO_CLI:-}" = "1" ] && exit 0

__cp_hq="$(command -v hq 2>/dev/null || true)"
[ -n "$__cp_hq" ] || exit 0

# `hq core --help` costs seconds of node startup, so probe it at most once per
# CLI build and cache the answer. Key by resolved path + mtime + size so a PATH
# switch or same-second rebuild cannot reuse a stale result; keep the cache in a
# private 0700 dir and trust it only when we own it, so another user cannot
# plant a positive result on a shared host; never persist a failed probe. The
# probe reads `hq core --help`, never our stdin, so the delegated command still
# receives the full hook payload. HQ_CLI_CAPS_CACHE overrides the path (tests
# isolate it).
__cp_mt="$(stat -c %Y "$__cp_hq" 2>/dev/null || stat -f %m "$__cp_hq" 2>/dev/null || echo 0)"
__cp_sz="$(stat -c %s "$__cp_hq" 2>/dev/null || stat -f %z "$__cp_hq" 2>/dev/null || echo 0)"
__cp_key="$(printf '%s' "$__cp_hq:$__cp_mt:$__cp_sz" | cksum 2>/dev/null | cut -d' ' -f1)"
if [ -n "${HQ_CLI_CAPS_CACHE:-}" ]; then
  __cp_cache="$HQ_CLI_CAPS_CACHE"
else
  __cp_dir="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/hq-cli"
  mkdir -p "$__cp_dir" 2>/dev/null && chmod 700 "$__cp_dir" 2>/dev/null || true
  __cp_cache="$__cp_dir/core-caps.${__cp_key:-0}"
fi

__cp_caps=""
if [ -r "$__cp_cache" ] && [ -O "$__cp_cache" ]; then
  __cp_caps="$(cat "$__cp_cache" 2>/dev/null || true)"
elif __cp_caps="$(hq core --help 2>/dev/null)"; then
  [ -n "$__cp_caps" ] && (umask 077; printf '%s' "$__cp_caps" >"$__cp_cache" 2>/dev/null) || true
else
  __cp_caps=""
fi

case "$__cp_caps" in
  *checkpoint-stop-gate*) exec hq core checkpoint-stop-gate ;;
esac

# No gate available: emit no decision and let the turn end.
exit 0
