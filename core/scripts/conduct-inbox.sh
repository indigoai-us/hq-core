#!/usr/bin/env bash
# hq-core: public
# conduct-inbox.sh — the drop box a /conduct lane reads while it is still running.
#
# A lane is a headless CLI process with its stdin wired to /dev/null, so there is
# no way to speak to it directly once it starts. This is the way in: the
# conductor writes a message here, and a hook inside the lane drains the box on
# the lane's own tool events and hands the text to the model mid-turn. Delivery
# is mechanical, not cooperative — the lane does not have to choose to look.
#
# Usage:
#   conduct-inbox.sh send  --run-dir <dir> (--text <msg> | --text-file <path>)
#   conduct-inbox.sh drain --run-dir <dir>     # consumer side; used by the hook
#   conduct-inbox.sh list  --run-dir <dir>
#   conduct-inbox.sh clear --run-dir <dir>
#
# `send` is what a human or the conductor calls. `drain` is what the lane's hook
# calls: it prints every pending message, oldest first, and consumes them.
# Draining an empty box prints nothing and exits 0, which is what lets the hook
# run on every tool call for free.
#
# LAYOUT under <run-dir>/inbox/
#   pending/               one file per undelivered message, named for its order
#   claimed/<claim-id>/    a consumer's immutable snapshot, kept as an audit and
#                          crash-recovery record
#
# `drain` claims by RENAMING pending/ aside and immediately recreating it, rather
# than reading the directory and deleting what it read. A message that lands
# between those two steps would be silently dropped, and a dropped instruction to
# a running lane is invisible: the lane simply carries on doing the wrong thing.
# See core/policies (hq-checkpoint-claim-pending-queues-atomically).
#
# Message text is passed through verbatim apart from having its control
# characters stripped; it is delivered as prose to a model, not parsed.

set -euo pipefail

die() { echo "conduct-inbox: $*" >&2; exit 1; }

usage() { sed -n '3,35p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//'; }

RUN_DIR=""
TEXT=""
TEXT_FILE=""
SUBCOMMAND="${1:-}"
[ -n "$SUBCOMMAND" ] || { usage >&2; exit 1; }
shift || true

while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir)   RUN_DIR="${2:-}"; shift 2 ;;
    --text)      TEXT="${2:-}"; shift 2 ;;
    --text-file) TEXT_FILE="${2:-}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$RUN_DIR" ] || die "--run-dir is required"
INBOX="$RUN_DIR/inbox"
PENDING="$INBOX/pending"
CLAIMED="$INBOX/claimed"

cmd_send() {
  local body tmp seq target
  if [ -n "$TEXT_FILE" ]; then
    [ -f "$TEXT_FILE" ] || die "send: no such file: $TEXT_FILE"
    body="$(cat "$TEXT_FILE")"
  else
    body="$TEXT"
  fi
  body="$(printf '%s' "$body" | tr -d '\000\013\014\015')"
  [ -n "$body" ] || die "send: refusing to queue an empty message"
  [ -d "$RUN_DIR" ] || die "send: no such run dir: $RUN_DIR (is the lane running?)"

  mkdir -p "$PENDING"
  # Ordering is by name, so the sequence must be zero-padded and must not reuse
  # a number a concurrent sender already took. The pid suffix makes the name
  # unique without a lock; the second resolution only has to order, not identify.
  seq="$(date -u +%Y%m%d%H%M%S)"
  target="$PENDING/$seq-$$.msg"
  tmp="$(mktemp "$INBOX/.send.XXXXXX")"
  printf '%s\n' "$body" > "$tmp"
  # Rename into place so a reader never sees a half-written message.
  mv "$tmp" "$target"
  echo "conduct-inbox: queued for $(basename "$RUN_DIR") ($(basename "$target"))"
}

cmd_drain() {
  [ -d "$PENDING" ] || exit 0
  # Nothing to do is the overwhelmingly common case — this runs on every tool
  # call of every lane — so get out before paying for a rename.
  if [ -z "$(ls -A "$PENDING" 2>/dev/null)" ]; then exit 0; fi

  local claim snapshot f
  claim="$(date -u +%Y%m%d%H%M%S)-$$"
  snapshot="$CLAIMED/$claim"
  mkdir -p "$CLAIMED"
  # Claim by rename, then immediately restore the queue a sender expects to
  # exist. A message written between these two lines lands in the fresh queue
  # and is delivered on the next drain rather than being lost.
  if ! mv "$PENDING" "$snapshot" 2>/dev/null; then
    # Another drain claimed it first; that consumer will deliver.
    mkdir -p "$PENDING"
    exit 0
  fi
  mkdir -p "$PENDING"

  for f in "$snapshot"/*.msg; do
    [ -f "$f" ] || continue
    cat "$f"
    echo
  done
}

cmd_list() {
  local p=0 d=0
  [ -d "$PENDING" ] && p="$(find "$PENDING" -mindepth 1 -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')"
  [ -d "$CLAIMED" ] && d="$(find "$CLAIMED" -mindepth 2 -maxdepth 2 -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')"
  printf '{"run_dir":"%s","pending":%s,"delivered":%s}\n' "$RUN_DIR" "$p" "$d"
}

cmd_clear() {
  rm -rf "$PENDING"
  mkdir -p "$PENDING"
}

case "$SUBCOMMAND" in
  send)  cmd_send ;;
  drain) cmd_drain ;;
  list)  cmd_list ;;
  clear) cmd_clear ;;
  *) usage >&2; exit 1 ;;
esac
