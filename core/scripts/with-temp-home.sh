#!/bin/bash
# with-temp-home.sh — run a command with a throwaway $HOME, then delete it.
#
# Usage:
#   bash core/scripts/with-temp-home.sh [--keep] -- <command> [args...]
#
# Why: sessions ran tests as `HOME=$(mktemp -d) <cmd>`. Every run then
# downloaded its own Rust toolchain (~1.8 GB) and pnpm store (~1.4 GB) into
# the fresh home, and nothing deleted it. That refilled tens of GB
# of disk within hours of a cleanup.
#
# This wrapper:
#   1. Creates the temp home under $TMPDIR (or /tmp).
#   2. Keeps the real toolchain and package caches by exporting RUSTUP_HOME,
#      CARGO_HOME, PNPM_HOME, npm_config_store_dir, npm_config_cache, and
#      COREPACK_HOME at the real home's locations (only when not already set).
#   3. Deletes the temp home on exit, success or failure, after checking the
#      path is still the directory it created under the temp root.
#
# The command's exit code is passed through. --keep leaves the directory
# and prints its path on stderr (for debugging a failed run). A kept folder
# is not permanent: once its lock pid is dead and nothing in it has changed
# for 90 minutes, `hq doctor --sweep-temp-homes` removes it.
# The temp home path is also exported as HQ_TEMP_HOME.
#
# Signals: INT, TERM and HUP sent to the wrapper are forwarded to the
# command at once, then TERM, then KILL if it is still running after
# HQ_TEMP_HOME_GRACE seconds (default 5). The temp home is then removed and
# the wrapper exits 128+signal. A supervisor that sends TERM and then KILL
# after a grace period therefore does not leave the folder behind.
#
# Process group: when stdin is not a terminal, the command runs in its own
# process group (job control, set -m) and signals go to the whole group, so
# a grandchild (a cargo or pnpm worker, a backgrounded subshell) cannot
# outlive the cleanup and recreate the folder. When the command exits on its
# own and left background jobs running in that group, the wrapper sends them
# TERM, then KILL after the grace, before it removes the folder. When stdin
# is a terminal the command stays in the terminal's group so it can still
# read the terminal. It then starts as a background job without job control,
# so bash makes it ignore SIGINT and Ctrl-C does not stop it directly. The
# wrapper still catches the INT and sends TERM, then KILL, to the command pid
# only. Grandchildren that ignore SIGINT may survive that and recreate the
# folder; `hq doctor --sweep-temp-homes` removes it later. Agent Bash calls
# have no terminal and take the process-group path above.
#
# Lock file: the wrapper writes its pid to <temp home>/.hq-temp-home.lock.
# `hq doctor --sweep-temp-homes` skips a temp home whose lock names a live
# process, and sweeps hq-temp-home.* folders left by a wrapper that was
# killed with SIGKILL.
#
# Enforced by .claude/hooks/block-raw-temp-home.sh (policy
# hq-temp-home-use-wrapper).

set -uo pipefail

keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) keep=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [ $# -eq 0 ]; then
  echo "usage: with-temp-home.sh [--keep] -- <command> [args...]" >&2
  exit 64
fi

real_home="${HOME:?HOME must be set}"
tmp_root="${TMPDIR:-/tmp}"
tmp_root="${tmp_root%/}"
tmp_root_real=$(cd "$tmp_root" && pwd -P) || { echo "with-temp-home: no temp root $tmp_root" >&2; exit 70; }

temp_home=$(mktemp -d "$tmp_root_real/hq-temp-home.XXXXXXXX") || { echo "with-temp-home: mktemp failed" >&2; exit 70; }

cleanup() {
  if [ "$keep" = 1 ]; then
    echo "with-temp-home: kept $temp_home" >&2
    return
  fi
  # Refuse anything that is not exactly the directory we created.
  case "$temp_home" in
    "$tmp_root_real"/hq-temp-home.*) ;;
    *) echo "with-temp-home: refusing to remove $temp_home" >&2; return ;;
  esac
  [ "$temp_home" = "$real_home" ] && return
  [ -d "$temp_home" ] && rm -rf -- "$temp_home"
}
trap cleanup EXIT

printf '%s\n' "$$" >"$temp_home/.hq-temp-home.lock" 2>/dev/null || true

case "$(uname -s 2>/dev/null)" in
  Darwin) pnpm_default="$real_home/Library/pnpm" ;;
  *) pnpm_default="${XDG_DATA_HOME:-$real_home/.local/share}/pnpm" ;;
esac

export RUSTUP_HOME="${RUSTUP_HOME:-$real_home/.rustup}"
export CARGO_HOME="${CARGO_HOME:-$real_home/.cargo}"
export PNPM_HOME="${PNPM_HOME:-$pnpm_default}"
export npm_config_store_dir="${npm_config_store_dir:-$pnpm_default/store}"
export npm_config_cache="${npm_config_cache:-$real_home/.npm}"
export COREPACK_HOME="${COREPACK_HOME:-$real_home/.cache/node/corepack}"
export HQ_TEMP_HOME="$temp_home"

grace="${HQ_TEMP_HOME_GRACE:-5}"
case "$grace" in ''|*[!0-9]*) grace=5 ;; esac
child=""
group=0

# send <signal|0>: signal the command's process group, or the command alone
# when it shares the terminal's group. Exit 0 when something received it.
send() {
  if [ "$group" = 1 ]; then
    kill -s "$1" -- "-$child" 2>/dev/null && return 0
  fi
  kill -s "$1" "$child" 2>/dev/null
}

# Forward a signal to the command, escalate to TERM and then KILL, and exit
# so the EXIT trap removes the temp home.
on_signal() {
  local sig="$1" code="$2" ticks=0
  trap '' INT TERM HUP
  if [ -n "$child" ] && send 0; then
    send "$sig"
    [ "$sig" = TERM ] || send TERM
    while send 0 && [ "$ticks" -lt $((grace * 10)) ]; do
      sleep 0.1
      ticks=$((ticks + 1))
    done
    send 0 && send KILL
    wait "$child" 2>/dev/null
  fi
  exit "$code"
}
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
trap 'on_signal HUP 129' HUP

# Run in the background so a signal reaches the trap at once instead of
# after the command exits. <&0 keeps stdin; a background job would
# otherwise read from /dev/null.
if [ ! -t 0 ]; then
  set -m
  group=1
fi
HOME="$temp_home" "$@" <&0 &
child=$!
[ "$group" = 1 ] && set +m
wait "$child"
rc=$?
# The command exited on its own, but a background job it started may still
# be running in its group and could write into the temp home after the EXIT
# trap removes it. Stop the rest of the group the same way: TERM, then KILL
# after the grace. Only the group is signalled here, never the bare pid,
# which is already reaped and may belong to another process.
if [ "$group" = 1 ] && kill -0 -- "-$child" 2>/dev/null; then
  trap '' INT TERM HUP
  kill -s TERM -- "-$child" 2>/dev/null
  ticks=0
  while kill -0 -- "-$child" 2>/dev/null && [ "$ticks" -lt $((grace * 10)) ]; do
    sleep 0.1
    ticks=$((ticks + 1))
  done
  kill -s KILL -- "-$child" 2>/dev/null
fi
exit "$rc"
