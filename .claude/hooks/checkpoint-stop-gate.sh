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

# A desktop-app or launchd PATH can miss the HQ toolchain and ~/.local/bin,
# where hq, claude and grok live. Append (never prepend) the install dirs.
__cp_add_path() {
  [ -n "$1" ] && [ -d "$1" ] || return 0
  case ":$PATH:" in *":$1:"*) return 0 ;; esac
  PATH="$PATH:$1"
}
__cp_h="${HOME:-/nonexistent}"
__cp_tc="${HQ_TOOLCHAIN_DIR:-$__cp_h/Library/Application Support/Indigo HQ/toolchain}"
for __cp_d in "$__cp_tc/node/bin" "$__cp_tc/npm-global/bin" "$__cp_h/.npm-global/bin" \
  "$__cp_h/.local/bin" "$__cp_h/.claude/local"; do __cp_add_path "$__cp_d"; done
if [ -n "${APPDATA:-}" ] && command -v cygpath >/dev/null 2>&1; then
  __cp_add_path "$(cygpath -u "$APPDATA" 2>/dev/null)/npm"
fi
export PATH

command -v hq >/dev/null 2>&1 || __cp_bail

# The gate always runs: its checkpoint and reply block decisions do not
# depend on a sibling backend. Only the maintenance sibling does. When nothing
# chose a backend and neither claude nor grok resolves, tell the CLI
# HQ_CHECKPOINT_BACKEND=none so the gate's background checkpoint records
# without probing or spawning a backend (each probe is a process, and on
# Windows each one could open a console). An operator or settings value is
# left to the CLI.
__cp_set=""
for __cp_f in "${CLAUDE_PROJECT_DIR:-.}/.claude/settings.local.json" "${CLAUDE_PROJECT_DIR:-.}/.claude/settings.json"; do
  [ -f "$__cp_f" ] && __cp_set="$__cp_set$(<"$__cp_f")"
done
if [ -z "${HQ_CHECKPOINT_BACKEND:-}" ] && [[ "$__cp_set" != *HQ_CHECKPOINT_BACKEND* ]] \
  && ! command -v claude >/dev/null 2>&1 \
  && ! command -v grok >/dev/null 2>&1; then
  export HQ_CHECKPOINT_BACKEND=none
fi

# Dispatch directly (no `hq core --help` probe). A CLI too old to register
# this subcommand returns its normal unknown-command diagnostic; discard only
# that known missing-command case so the historical silent-allow behavior remains intact. Preserve all
# output and status for an installed gate. This hook is deadline-bound, so keep
# CLI self-update outside its budget: HQ_NO_UPDATE_CHECK is exported so it
# reaches hq through the hidden launcher too.
export HQ_NO_UPDATE_CHECK=1
__cp_err="$(mktemp "${TMPDIR:-/tmp}/hq-checkpoint-stop-gate.XXXXXX")" || __cp_bail
__cp_hook_dir="${BASH_SOURCE[0]%/*}"
[ "$__cp_hook_dir" != "${BASH_SOURCE[0]}" ] || __cp_hook_dir=.
__cp_hidden="$__cp_hook_dir/../../core/scripts/hq-hidden-run.sh"
# On Windows the launcher starts hq with no console; elsewhere it execs hq.
if [ -f "$__cp_hidden" ]; then
  bash "$__cp_hidden" --wait --direct-on-error -- hq core checkpoint-stop-gate 2>"$__cp_err"
else
  HQ_NO_UPDATE_CHECK=1 hq core checkpoint-stop-gate 2>"$__cp_err"
fi
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
