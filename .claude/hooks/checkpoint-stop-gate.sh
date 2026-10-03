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

# Each bail-out below happens before anything reads the payload, and the
# dispatcher is still writing it into our stdin. Exiting with the pipe unread
# kills that writer with SIGPIPE, and a dispatcher under `pipefail` reports the
# resulting 141 as this hook's own status. Drain on every early exit; the
# delegated CLI path inherits and reads stdin itself.
__cp_bail() { cat >/dev/null 2>&1 || true; exit 0; }

[ "${HQ_CHECKPOINT_GATE_NO_CLI:-}" = "1" ] && __cp_bail

command -v hq >/dev/null 2>&1 || __cp_bail

# Dispatch directly instead of starting Node once for `hq core --help` and
# again for the gate. A CLI too old to register this subcommand returns its
# normal unknown-command diagnostic; discard only that known missing-command
# case so the historical silent-allow behavior remains intact. Preserve all
# output and status for an installed gate. This hook is deadline-bound, so keep
# CLI self-update outside its budget.
__cp_err="$(mktemp "${TMPDIR:-/tmp}/hq-checkpoint-stop-gate.XXXXXX")" || __cp_bail
HQ_NO_UPDATE_CHECK=1 hq core checkpoint-stop-gate 2>"$__cp_err"
__cp_rc=$?
if [ "$__cp_rc" -ne 0 ]; then
  __cp_missing=0
  while IFS= read -r __cp_line || [ -n "$__cp_line" ]; do
    case "$__cp_line" in
      *"unknown command 'checkpoint-stop-gate'"*|*"unknown command: checkpoint-stop-gate"*)
        __cp_missing=1
        ;;
    esac
  done <"$__cp_err"
  if [ "$__cp_missing" -eq 1 ]; then
    rm -f "$__cp_err"
    __cp_bail
  fi
fi
[ ! -s "$__cp_err" ] || cat "$__cp_err" >&2
rm -f "$__cp_err"
exit "$__cp_rc"
