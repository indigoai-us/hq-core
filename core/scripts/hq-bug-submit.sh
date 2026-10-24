#!/usr/bin/env bash
# Run an `hq feedback` submit for /hq-bug, then delete the body file.
#
# Usage: hq-bug-submit.sh hq feedback <type> --title <t> --body-file <path> [...]
#
# The body file is removed after success, after failure, and on INT/TERM. Only
# a regular file (not a symlink) whose name starts with hq-feedback-body. is
# removed, so a wrong --body-file value cannot delete anything else. The exit
# status is the `hq feedback` exit status (130/143 after INT/TERM). Works on
# bash 3.2.
set -u

if [ "$#" -lt 2 ] || [ "$1" != "hq" ] || [ "$2" != "feedback" ]; then
  echo "hq-bug-submit: expected 'hq feedback ...' arguments" >&2
  exit 2
fi

body_path=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--body-file" ]; then
    body_path="$arg"
  fi
  case "$arg" in
    --body-file=*) body_path="${arg#--body-file=}" ;;
  esac
  prev="$arg"
done

cleanup() {
  [ -n "$body_path" ] || return 0
  [ "$body_path" != "-" ] || return 0
  base="${body_path##*/}"
  case "$base" in
    hq-feedback-body.*) ;;
    *) return 0 ;;
  esac
  if [ -f "$body_path" ] && [ ! -L "$body_path" ]; then
    rm -f -- "$body_path"
  fi
}
child=""
on_signal() {
  if [ -n "$child" ]; then
    kill -TERM "$child" 2>/dev/null || true
  fi
  exit "$1"
}
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

# Run the submit in the background and wait, so INT/TERM reach the traps
# (and the cleanup) at once instead of after a hung `hq` exits.
"$@" &
child=$!
wait "$child"
rc=$?
child=""
exit "$rc"
