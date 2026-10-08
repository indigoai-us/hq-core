#!/usr/bin/env bash
# hq-core: public
# conduct-link.sh — a two-way mailbox between one /conduct session and the live
# sessions it has adopted as children.
#
# A /conduct lane is a process the conductor launched, and its drop box
# (conduct-inbox.sh) only runs one way. A LINK is for the other case: a session
# that is already open — Claude, Codex or Grok, in any host — joins a conductor,
# and from then on the conductor can instruct it and the child can answer. The
# conductor session becomes the single place the operator talks to.
#
# Usage:
#   conduct-link.sh open   [--engine <e>] [--host-session <id>]     # conductor
#   conduct-link.sh join   --link <id> [--name <n>] [--engine <e>]
#                          [--title <t>] [--host-session <id>]      # child
#   conduct-link.sh send   [--link <id>] --child <name|all>
#                          (--text <msg> | --text-file <path>)      # conductor
#   conduct-link.sh report (--text <msg> | --text-file <path>)
#                          [--state <s>]                            # child
#   conduct-link.sh status --state <working|blocked|idle|done> [--note <n>]
#   conduct-link.sh inbox                       # child: drain own box by hand
#   conduct-link.sh read   [--link <id>]        # conductor: drain child reports
#   conduct-link.sh wait   [--link <id>] [--timeout <secs>]
#   conduct-link.sh list   [--link <id>]
#   conduct-link.sh leave                       # child
#   conduct-link.sh close  [--link <id>]        # conductor
#
# Every command takes --session-id <id> to act as a session other than the
# resolved one (tests, and hosts that do not export a session id).
#
# LAYOUT under workspace/conduct-links/
#   <link>/meta.json                   the conductor's record
#   <link>/up/inbox/                   child -> conductor queue
#   <link>/children/<name>/meta.json   one record per adopted session
#   <link>/children/<name>/inbox/      conductor -> child queue
#   by-session/<session-id>            "<role> <link> [<name>]" — how a hook,
#                                      which only knows its session id, finds
#                                      the queue it should deliver from
#
# Both queues are conduct-inbox.sh queues, so the claim-by-rename delivery and
# its audit trail under claimed/ apply unchanged. Delivery into a running
# session is done by .claude/hooks/conduct-lane-inbox.sh. `inbox` and `read`
# exist for a host that dispatches no hooks: they are the same drain by hand.
#
# `wait` exits 0 when a child report is pending, 3 on timeout. Run it in the
# background so an idle conductor is woken by a report instead of polling.

set -euo pipefail

die() { echo "conduct-link: $*" >&2; exit 1; }
usage() { sed -n '3,45p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//'; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
LINKS="${HQ_CONDUCT_LINKS_DIR:-$HQ/workspace/conduct-links}"
BY_SESSION="$LINKS/by-session"
INBOX_SH="$SCRIPT_DIR/conduct-inbox.sh"

command -v jq >/dev/null 2>&1 || die "jq is required"

SUBCOMMAND="${1:-}"
[ -n "$SUBCOMMAND" ] || { usage >&2; exit 1; }
shift || true

LINK="" CHILD="" NAME="" ENGINE="" TITLE="" HOST_SESSION="" TEXT="" TEXT_FILE=""
STATE="" NOTE="" SESSION="" TIMEOUT="1800"
while [ $# -gt 0 ]; do
  case "$1" in
    --link)         LINK="${2:-}"; shift 2 ;;
    --child)        CHILD="${2:-}"; shift 2 ;;
    --name)         NAME="${2:-}"; shift 2 ;;
    --engine)       ENGINE="${2:-}"; shift 2 ;;
    --title)        TITLE="${2:-}"; shift 2 ;;
    --host-session) HOST_SESSION="${2:-}"; shift 2 ;;
    --text)         TEXT="${2:-}"; shift 2 ;;
    --text-file)    TEXT_FILE="${2:-}"; shift 2 ;;
    --state)        STATE="${2:-}"; shift 2 ;;
    --note)         NOTE="${2:-}"; shift 2 ;;
    --session-id)   SESSION="${2:-}"; shift 2 ;;
    --timeout)      TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# Ids become path segments, so hold them to a conservative charset.
valid_id() {
  case "${1:-}" in
    ""|.|..) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

session_id() {
  if [ -z "$SESSION" ]; then
    SESSION="$(bash "$SCRIPT_DIR/hq-session.sh" current 2>/dev/null || true)"
  fi
  valid_id "$SESSION" || die "cannot resolve this session's id; pass --session-id"
  printf '%s' "$SESSION"
}

# pointer <session-id> — prints "<role> <link> [<name>]" or nothing.
pointer() { [ -f "$BY_SESSION/$1" ] && cat "$BY_SESSION/$1" || true; }

# Resolve LINK (and CHILD for a child) from this session's pointer when the
# caller did not name them.
resolve_from_pointer() {
  local want="$1" p role plink pname
  p="$(pointer "$(session_id)")"
  [ -n "$p" ] || die "this session is not part of a conduct link"
  read -r role plink pname <<EOF2
$p
EOF2
  [ "$role" = "$want" ] || die "this session is a $role on $plink, not a $want"
  [ -n "$LINK" ] || LINK="$plink"
  [ -n "$CHILD" ] || CHILD="${pname:-}"
}

link_dir() {
  valid_id "$LINK" || die "invalid or missing --link"
  [ -d "$LINKS/$LINK" ] || die "no such link: $LINK"
  printf '%s' "$LINKS/$LINK"
}

message_body() {
  if [ -n "$TEXT_FILE" ]; then
    [ -f "$TEXT_FILE" ] || die "no such file: $TEXT_FILE"
    cat "$TEXT_FILE"
  else
    printf '%s' "$TEXT"
  fi
}

write_json() { # write_json <path> <json>
  local tmp
  tmp="$(mktemp "$(dirname "$1")/.meta.XXXXXX")"
  printf '%s\n' "$2" > "$tmp"
  mv "$tmp" "$1"
}

cmd_open() {
  local sid p role plink _rest dir
  sid="$(session_id)"
  p="$(pointer "$sid")"
  if [ -n "$p" ]; then
    read -r role plink _rest <<EOF2
$p
EOF2
    [ "$role" = "conductor" ] || die "this session is already a child of $plink; leave first"
    LINK="$plink"
  else
    LINK="cl-$(date -u +%Y%m%d)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
    dir="$LINKS/$LINK"
    mkdir -p "$dir/children" "$dir/up/inbox/pending" "$BY_SESSION"
    write_json "$dir/meta.json" "$(jq -n --arg link "$LINK" --arg sid "$sid" \
      --arg host "$HOST_SESSION" --arg engine "${ENGINE:-claude}" --arg at "$(now)" \
      '{link:$link, conductor_session:$sid, conductor_host_session:$host, engine:$engine, created:$at}')"
    printf 'conductor %s\n' "$LINK" > "$BY_SESSION/$sid"
  fi
  jq -n --arg link "$LINK" '{link:$link, join:("/conduct-join " + $link)}'
}

cmd_join() {
  local sid dir p cdir company
  sid="$(session_id)"
  dir="$(link_dir)"
  p="$(pointer "$sid")"
  [ -z "$p" ] || die "this session is already linked ($p); leave first"
  [ -n "$NAME" ] || NAME="s-$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9' | cut -c1-8)"
  valid_id "$NAME" || die "invalid --name: $NAME"
  [ "$NAME" != "all" ] || die "'all' is reserved for broadcast"
  cdir="$dir/children/$NAME"
  [ ! -d "$cdir" ] || die "a child named $NAME is already on $LINK; pick another --name"
  company="$(bash "$SCRIPT_DIR/hq-session.sh" --session-id "$sid" get company_slug 2>/dev/null || true)"
  mkdir -p "$cdir/inbox/pending" "$BY_SESSION"
  write_json "$cdir/meta.json" "$(jq -n --arg name "$NAME" --arg sid "$sid" \
    --arg host "$HOST_SESSION" --arg engine "${ENGINE:-claude}" --arg title "$TITLE" \
    --arg company "$company" --arg at "$(now)" \
    '{name:$name, session_id:$sid, host_session:$host, engine:$engine, title:$title,
      company:$company, state:"idle", note:"", joined:$at, updated:$at}')"
  printf 'child %s %s\n' "$LINK" "$NAME" > "$BY_SESSION/$sid"
  bash "$INBOX_SH" send --run-dir "$dir/up" \
    --text "[$NAME joined] ${TITLE:-untitled session} (engine ${ENGINE:-claude}${company:+, company $company})" >/dev/null
  jq -n --arg link "$LINK" --arg name "$NAME" \
    --arg host "$(jq -r '.conductor_host_session // ""' "$dir/meta.json")" \
    '{link:$link, name:$name, conductor_host_session:$host}'
}

cmd_send() {
  local dir body targets t sent=0
  [ -n "$LINK" ] || resolve_from_pointer conductor
  dir="$(link_dir)"
  [ -n "$CHILD" ] || die "--child <name|all> is required"
  body="$(message_body)"
  [ -n "$body" ] || die "refusing to send an empty message"
  if [ "$CHILD" = "all" ]; then
    targets="$(find "$dir/children" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null)"
  else
    valid_id "$CHILD" || die "invalid --child: $CHILD"
    [ -d "$dir/children/$CHILD" ] || die "no child named $CHILD on $LINK"
    targets="$CHILD"
  fi
  for t in $targets; do
    printf '%s' "$body" > "$dir/children/$t/.outgoing.$$"
    bash "$INBOX_SH" send --run-dir "$dir/children/$t" --text-file "$dir/children/$t/.outgoing.$$" >/dev/null
    rm -f "$dir/children/$t/.outgoing.$$"
    sent=$((sent + 1))
  done
  [ "$sent" -gt 0 ] || die "no children on $LINK"
  echo "conduct-link: queued for $sent child session(s) on $LINK"
}

set_state() { # set_state <child-dir> <state> <note>
  local meta="$1/meta.json"
  write_json "$meta" "$(jq --arg s "$2" --arg n "$3" --arg at "$(now)" \
    '.state=$s | .note=$n | .updated=$at' "$meta")"
}

check_state() {
  case "$1" in working|blocked|idle|done) : ;; *) die "--state must be working, blocked, idle or done" ;; esac
}

cmd_report() {
  local dir body cdir tmp
  resolve_from_pointer child
  dir="$(link_dir)"
  cdir="$dir/children/$CHILD"
  body="$(message_body)"
  [ -n "$body" ] || die "refusing to report an empty message"
  if [ -n "$STATE" ]; then check_state "$STATE"; set_state "$cdir" "$STATE" "$NOTE"; fi
  tmp="$cdir/.report.$$"
  printf '[from %s%s]\n%s' "$CHILD" "${STATE:+ · $STATE}" "$body" > "$tmp"
  bash "$INBOX_SH" send --run-dir "$dir/up" --text-file "$tmp" >/dev/null
  rm -f "$tmp"
  jq -n --arg host "$(jq -r '.conductor_host_session // ""' "$dir/meta.json")" \
    '{queued:true, conductor_host_session:$host}'
}

cmd_status() {
  [ -n "$STATE" ] || die "--state is required"
  check_state "$STATE"
  resolve_from_pointer child
  set_state "$(link_dir)/children/$CHILD" "$STATE" "$NOTE"
  echo "conduct-link: $CHILD is $STATE"
}

cmd_inbox() {
  resolve_from_pointer child
  bash "$INBOX_SH" drain --run-dir "$(link_dir)/children/$CHILD"
}

cmd_read() {
  [ -n "$LINK" ] || resolve_from_pointer conductor
  bash "$INBOX_SH" drain --run-dir "$(link_dir)/up"
}

cmd_wait() {
  local dir deadline
  [ -n "$LINK" ] || resolve_from_pointer conductor
  dir="$(link_dir)"
  case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be whole seconds" ;; esac
  deadline=$(( $(date +%s) + TIMEOUT ))
  while :; do
    [ -d "$dir" ] || die "link $LINK was closed"
    if [ -n "$(ls -A "$dir/up/inbox/pending" 2>/dev/null)" ]; then
      echo "conduct-link: report pending on $LINK"
      exit 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || exit 3
    sleep 3
  done
}

cmd_list() {
  local dir c pending rows="[]"
  if [ -z "$LINK" ]; then
    local p role
    p="$(pointer "$(session_id)")"
    [ -n "$p" ] || { echo '{"link":null,"children":[]}'; exit 0; }
    read -r role LINK CHILD <<EOF2
$p
EOF2
  fi
  dir="$(link_dir)"
  for c in "$dir"/children/*/; do
    [ -f "${c}meta.json" ] || continue
    pending="$(find "${c}inbox/pending" -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')"
    rows="$(jq --argjson row "$(jq --argjson p "$pending" '. + {undelivered:$p}' "${c}meta.json")" \
      '. + [$row]' <<EOF2
$rows
EOF2
)"
  done
  jq -n --slurpfile meta "$dir/meta.json" --argjson children "$rows" \
    --argjson up "$(find "$dir/up/inbox/pending" -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')" \
    '$meta[0] + {unread_reports:$up, children:$children}'
}

cmd_leave() {
  local dir sid
  sid="$(session_id)"
  resolve_from_pointer child
  dir="$(link_dir)"
  bash "$INBOX_SH" send --run-dir "$dir/up" --text "[$CHILD left the link]" >/dev/null
  # Keep the directory: its claimed/ snapshots are the record of what this
  # child was told. Only the pointer goes, which is what stops delivery.
  set_state "$dir/children/$CHILD" "done" "left"
  rm -f "$BY_SESSION/$sid"
  rmdir "$BY_SESSION" 2>/dev/null || true
  echo "conduct-link: $CHILD left $LINK"
}

cmd_close() {
  local dir f
  [ -n "$LINK" ] || resolve_from_pointer conductor
  dir="$(link_dir)"
  for f in "$BY_SESSION"/*; do
    [ -f "$f" ] || continue
    case "$(cat "$f")" in *" $LINK"|*" $LINK "*) rm -f "$f" ;; esac
  done
  # An empty registry is removed so the hook's dispatcher prefilter goes back to
  # skipping it outright on a machine with no open link.
  rmdir "$BY_SESSION" 2>/dev/null || true
  write_json "$dir/meta.json" "$(jq --arg at "$(now)" '.closed=$at' "$dir/meta.json")"
  echo "conduct-link: closed $LINK (records kept at $dir)"
}

case "$SUBCOMMAND" in
  open)   cmd_open ;;
  join)   cmd_join ;;
  send)   cmd_send ;;
  report) cmd_report ;;
  status) cmd_status ;;
  inbox)  cmd_inbox ;;
  read)   cmd_read ;;
  wait)   cmd_wait ;;
  list)   cmd_list ;;
  leave)  cmd_leave ;;
  close)  cmd_close ;;
  *) usage >&2; exit 1 ;;
esac
