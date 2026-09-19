#!/usr/bin/env bash
# hq-dm-bind.sh — bind the current session to one HQ DM channel, post
# structured updates to it, and listen for replies (feedback / requests).
#
# Usage:
#   core/scripts/hq-dm-bind.sh bind <channel>                 # bind + set the read cursor to "now"
#   core/scripts/hq-dm-bind.sh status                         # show the binding and cursor
#   core/scripts/hq-dm-bind.sh post --title <t> [--state <s>] [--line <l>]... [--next <l>]... [--ask <l>]... [--to <name>]... [--topic <t>] [--under <id>] [--new-thread]
#   core/scripts/hq-dm-bind.sh post --title <t> - < body.md    # body from stdin (already structured)
#   core/scripts/hq-dm-bind.sh threads                        # list the channel's recent top-level threads (id, replies, author, text)
#   core/scripts/hq-dm-bind.sh roster                         # print the channel members a post will @-mention
#   core/scripts/hq-dm-bind.sh poll                           # print new messages since the cursor, advance it
#   core/scripts/hq-dm-bind.sh listen [--interval 60] [--timeout 1800]
#                                                             # block until a new message arrives (or timeout)
#   core/scripts/hq-dm-bind.sh unbind
#
# The binding lives in the session's meta.yaml (`dm_channel`) via hq-session.sh;
# the cursor is `workspace/sessions/<sid>/dm-bind.cursor` (the last seen sort
# key from `hq dm channel --json`). `listen` is meant to run detached
# (Bash run_in_background): it exits 0 and prints the new messages the moment
# one lands, exits 3 on timeout with nothing new.
#
# Every post opens with an @-mention of every other member of the channel, so
# the update reaches people (HQ mentions are structured: the `hq` CLI resolves
# the `@"Display Name"` tokens against the roster and sends the real mention
# list; an unresolvable name fails the post rather than posting text that looks
# addressed but is not). The CLI rewrites a resolved `@"Display Name"` token to
# `@Display Name`, so the room never shows the quotes.
#
# Posts thread by topic. The first post on a topic (`--topic`, else the title)
# is a top-level root; every later post on the same topic in this session goes
# out as a reply under it. `--under <id>` replies under an existing thread that
# someone else (or an earlier session) started — a top-level post is only for a
# subject the channel has no thread for yet. `--new-thread` starts a fresh root. The topic → root
# map is `workspace/sessions/<sid>/dm-bind.threads`.
#
# A post ALWAYS mentions someone. `--to <name>` (repeatable) narrows the line to
# the named members, for a reply to one person; without it the line names every
# other human member (bots are left out unless named with --to, because a tagged
# bot wakes and replies). There is no way to post unmentioned: an update nobody is
# notified about does not get read. `post` refuses when the roster cannot be
# read rather than sending a silent update.
#
# Post format (kept deliberately plain — see .claude/skills/dm-bind/SKILL.md):
#   @"Ada Lovelace" @"Grace Hopper"
#
#   <title> — <state>
#
#   • line
#   • line
#
#   Next: line
#   Need from you: line
set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SESSION_SH="$HQ_ROOT/core/scripts/hq-session.sh"

die() { echo "hq-dm-bind: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need hq; need jq

session_id() { bash "$SESSION_SH" current 2>/dev/null || true; }
session_dir() {
  local sid; sid="$(session_id)"
  [ -n "$sid" ] || die "no current session (hq-session.sh current is empty)"
  local d="$HQ_ROOT/workspace/sessions/$sid"; mkdir -p "$d"; echo "$d"
}
cursor_file() { echo "$(session_dir)/dm-bind.cursor"; }
channel() { bash "$SESSION_SH" get dm_channel 2>/dev/null | tr -d '"' || true; }
require_channel() {
  local ch; ch="$(channel)"
  [ -n "$ch" ] && [ "$ch" != "null" ] || die "session is not bound — run: core/scripts/hq-dm-bind.sh bind <channel>"
  echo "$ch"
}

# Own address, used to skip our own posts when polling. Best effort.
self_email() {
  hq whoami 2>/dev/null | grep -oE '[[:alnum:]._+-]+@[[:alnum:].-]+\.[[:alpha:]]+' | head -1 || true
}

# Normalise `hq dm channel --json` to a JSON array of messages.
fetch_items() {
  local ch="$1" limit="${2:-30}"
  hq dm channel "$ch" --limit "$limit" --json 2>/dev/null \
    | jq -c 'if type=="array" then . else (.messages // .items // []) end' 2>/dev/null \
    || echo '[]'
}

latest_sk() { fetch_items "$1" 5 | jq -r 'last // empty | .sk // empty'; }
roster_file() { echo "$(session_dir)/dm-bind.roster"; }

# The channel's members other than us, one display name per line. Reads the
# same local session files the `hq` CLI uses (the token is sent only as an
# Authorization header, never printed). Resolves the bound channel token to a
# channel id by slug, the way `hq dm <name>` does. Fails soft: prints nothing.
fetch_roster() {
  local ch="$1" me; me="$(self_email)"
  command -v node >/dev/null 2>&1 || return 0
  node - roster "$ch" "$me" <<'NODE' 2>/dev/null || true
const fs = require("fs"), os = require("os"), path = require("path");
const [, ch, me] = process.argv.slice(2);
const home = os.homedir();
const slug = (n) => String(n).trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
(async () => {
  const cfg = JSON.parse(fs.readFileSync(path.join(home, ".hq", "config.json"), "utf8"));
  const tok = JSON.parse(fs.readFileSync(path.join(home, ".hq", "cognito-tokens.json"), "utf8")).idToken;
  const base = cfg.vaultApiUrl; const h = { Authorization: "Bearer " + tok };
  const chans = await (await fetch(base + "/v1/notify/channels", { headers: h })).json();
  const rows = Array.isArray(chans) ? chans : (chans.channels || []);
  const hit = rows.find((c) => c.channelId === ch || slug(c.name || "") === slug(ch) || c.slug === slug(ch));
  if (!hit) return;
  const mem = await (await fetch(base + "/v1/notify/channels/" + encodeURIComponent(hit.channelId) + "/members", { headers: h })).json();
  const list = Array.isArray(mem) ? mem : (mem.members || []);
  for (const m of list) {
    const email = String(m.email || "").toLowerCase();
    if (me && email === me.toLowerCase()) continue;
    const name = String(m.displayName || "").trim();
    const uid = String(m.personUid || m.participantUid || m.uid || "").trim();
    if (name) process.stdout.write(name + "\t" + uid + "\n");
  }
})().catch(() => {});
NODE
}

# Refresh the cached roster; fall back to the cache when the fetch fails.
roster() {
  local ch="$1" rf; rf="$(roster_file)"
  local fresh; fresh="$(fetch_roster "$ch")"
  if [ -n "$fresh" ]; then printf '%s\n' "$fresh" > "$rf"; fi
  cut -f1 "$rf" 2>/dev/null || true
}

# The structured `mentions` array for a newline list of display names, built
# from the cached roster rows (name<TAB>uid). `agt_*` uids are agents, every
# other uid is a human — the server 400s when the type and the prefix disagree.
mentions_json() {
  local rf; rf="$(roster_file)"
  jq -Rn --rawfile rows "$rf" '
    ($rows | split("\n") | map(select(length>0) | split("\t")) | map({key:.[0], value:(.[1] // "")}) | from_entries) as $uid
    | [inputs | select(length>0) | select(($uid[.] // "") != "")
       | {participantUid:$uid[.], participantType:(if ($uid[.]|startswith("agt_")) then "agent" else "human" end), displayName:.}]'
}

threads_file() { echo "$(session_dir)/dm-bind.threads"; }
topic_slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'; }
thread_root() { awk -F'\t' -v k="$1" '$1==k{v=$2} END{if(v!="")print v}' "$(threads_file)" 2>/dev/null || true; }

# POST one message to the channel through the notify API (the `hq` CLI has no
# thread flag, and a threaded reply needs `rootEventId`). Reads the JSON payload
# from $1, prints the new message's eventId. Same local session files and the
# same slug resolution as fetch_roster; the token is only ever a header.
send_channel() {
  local ch="$1" payload="$2"
  node - send "$ch" "$payload" <<'NODE'
const fs = require("fs"), os = require("os"), path = require("path");
const [, ch, payload] = process.argv.slice(2);
const home = os.homedir();
const slug = (n) => String(n).trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
(async () => {
  const cfg = JSON.parse(fs.readFileSync(path.join(home, ".hq", "config.json"), "utf8"));
  const tok = JSON.parse(fs.readFileSync(path.join(home, ".hq", "cognito-tokens.json"), "utf8")).idToken;
  const base = cfg.vaultApiUrl; const h = { Authorization: "Bearer " + tok, "Content-Type": "application/json" };
  const chans = await (await fetch(base + "/v1/notify/channels", { headers: h })).json();
  const rows = Array.isArray(chans) ? chans : (chans.channels || []);
  const hit = rows.find((c) => c.channelId === ch || slug(c.name || "") === slug(ch) || c.slug === slug(ch));
  if (!hit) throw new Error("channel not found: " + ch);
  const res = await fetch(base + "/v1/notify/channels/" + encodeURIComponent(hit.channelId) + "/messages", { method: "POST", headers: h, body: payload });
  const text = await res.text();
  if (!res.ok) throw new Error("post failed: HTTP " + res.status + " " + text.slice(0, 300));
  let j = {}; try { j = JSON.parse(text); } catch {}
  const m = j.message || j.event || j;
  const id = m.eventId || (typeof m.sk === "string" && m.sk.includes("#") ? m.sk.split("#").pop() : "");
  process.stdout.write(String(id || ""));
})().catch((e) => { process.stderr.write("hq-dm-bind: " + e.message + "\n"); process.exit(1); });
NODE
}

# The @-mention line: one quoted token per member so multi-word names resolve.
# The quotes are input syntax only — the `hq` CLI strips them once the name
# resolves, so the room reads `@Ada Lovelace`. With no extra args it names every
# other member; extra args narrow it to those members, matched case-insensitively
# against the roster (exact display name first, then a unique partial match).
# Exit 4: roster unreadable. Exit 5: a --to name matched nobody or several.
mention_line() {
  local ch="$1"; shift
  local names line="" n
  names="$(roster "$ch")"
  [ -n "$names" ] || return 4
  if [ $# -eq 0 ]; then
    # Default: the people, not the bots. A tagged bot wakes and answers, and a
    # round of "no response needed" replies under every update is the clutter
    # threads exist to prevent. Name a bot with --to when the post is for it.
    local humans; humans="$(awk -F'\t' '$2 !~ /^agt_/ {print $1}' "$(roster_file)" 2>/dev/null || true)"
    [ -n "$humans" ] || humans="$names"
    while IFS= read -r n; do [ -n "$n" ] && line="$line @\"$n\""; done <<< "$humans"
  else
    local want hit count
    for want in "$@"; do
      want="${want#@}"
      hit="$(printf '%s\n' "$names" | grep -ixF -- "$want" | head -1 || true)"
      if [ -z "$hit" ]; then
        count="$(printf '%s\n' "$names" | grep -icF -- "$want" || true)"
        if [ "$count" = 1 ]; then hit="$(printf '%s\n' "$names" | grep -iF -- "$want")"; fi
      fi
      if [ -z "$hit" ]; then
        echo "hq-dm-bind: --to '$want' does not match exactly one channel member. Members:" >&2
        printf '%s\n' "$names" | sed 's/^/  /' >&2
        return 5
      fi
      case "$line" in *"@\"$hit\""*) ;; *) line="$line @\"$hit\"" ;; esac
    done
  fi
  printf '%s' "${line# }"
}

cmd_bind() {
  local ch="${1:-}"; [ -n "$ch" ] || die "bind needs a channel name (see: hq channels)"
  ch="${ch#\#}"
  hq channels 2>/dev/null | grep -q -- "hq dm $ch " || die "no channel named '$ch' (see: hq channels)"
  bash "$SESSION_SH" set dm_channel "$ch" >/dev/null
  local sk; sk="$(latest_sk "$ch")"
  printf '%s\n' "$sk" > "$(cursor_file)"
  local names; names="$(roster "$ch")"
  local n; n="$(printf '%s' "$names" | grep -c . || true)"
  echo "bound session $(session_id) to #$ch (cursor: ${sk:-<empty>}; will @-mention $n member(s))"
  [ "$n" -gt 0 ] || echo "hq-dm-bind: could not read the channel roster — posts will not @-mention anyone until it is readable" >&2
}

cmd_roster() {
  local ch; ch="$(require_channel)"
  roster "$ch"
}

# Recent top-level messages (thread roots) in the bound channel, newest last:
# "<id8>  <replies>  <author>: <first 90 chars>". Read this BEFORE starting a
# new topic — if a thread for the subject already exists, reply under it.
recent_roots() { fetch_items "$1" 100 | jq -c 'map(select((.rootEventId // "") == ""))'; }
cmd_threads() {
  local ch; ch="$(require_channel)"
  recent_roots "$ch" | jq -r '.[-25:] | .[] | [(.eventId[0:8]), ((.replyCount // 0)|tostring), ((.fromDisplayName // "?") + ": " + ((.body // "") | gsub("\\s+";" ") | .[0:90]))] | @tsv'
}
# Resolve --under: a full event id, or a unique id prefix of a recent root.
resolve_root() {
  local ch="$1" want="$2" hits
  hits="$(recent_roots "$ch" | jq -r --arg w "$want" '.[] | select(.eventId | startswith($w)) | .eventId')"
  [ -n "$hits" ] || { echo "hq-dm-bind: --under '$want' matches no recent top-level message (see: hq-dm-bind.sh threads)" >&2; return 1; }
  [ "$(printf '%s\n' "$hits" | wc -l | tr -d ' ')" = 1 ] || { echo "hq-dm-bind: --under '$want' matches several messages — use more of the id" >&2; return 1; }
  printf '%s' "$hits"
}

cmd_unbind() {
  bash "$SESSION_SH" set dm_channel "" >/dev/null
  rm -f "$(cursor_file)" "$(roster_file)" "$(threads_file)"
  echo "unbound"
}

cmd_status() {
  local ch; ch="$(channel)"
  echo "session:  $(session_id)"
  echo "channel:  ${ch:-<none>}"
  echo "cursor:   $(cat "$(cursor_file)" 2>/dev/null || echo '<none>')"
}

cmd_post() {
  local ch; ch="$(require_channel)"
  local title="" state="" body_from_stdin=0 topic="" new_thread=0 under=""
  local -a lines=() nexts=() asks=() tos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --topic) topic="$2"; shift 2 ;;
      --new-thread) new_thread=1; shift ;;
      --under) [ -n "${2:-}" ] || die "post: --under needs a message id (see: threads)"; under="$2"; shift 2 ;;
      --to) [ -n "${2:-}" ] || die "post: --to needs a member name"; tos+=("$2"); shift 2 ;;
      --no-mention) die "post: --no-mention was removed — every post @-mentions someone. Use --to <name> to address specific members." ;;
      --title) title="$2"; shift 2 ;;
      --state) state="$2"; shift 2 ;;
      --line)  lines+=("$2"); shift 2 ;;
      --next)  nexts+=("$2"); shift 2 ;;
      --ask)   asks+=("$2"); shift 2 ;;
      -)       body_from_stdin=1; shift ;;
      *) die "post: unknown arg $1" ;;
    esac
  done
  [ -n "$title" ] || die "post needs --title"
  local msg="$title"; [ -n "$state" ] && msg="$title — $state"
  if [ "$body_from_stdin" = 1 ]; then
    msg="$msg"$'\n\n'"$(cat)"
  else
    if [ ${#lines[@]} -gt 0 ]; then
      msg="$msg"$'\n'
      for l in "${lines[@]}"; do msg="$msg"$'\n'"• $l"; done
    fi
    if [ ${#nexts[@]} -gt 0 ]; then
      msg="$msg"$'\n'
      for l in "${nexts[@]}"; do msg="$msg"$'\n'"Next: $l"; done
    fi
    if [ ${#asks[@]} -gt 0 ]; then
      msg="$msg"$'\n'
      for l in "${asks[@]}"; do msg="$msg"$'\n'"Need from you: $l"; done
    fi
  fi
  local ml rc=0
  if [ ${#tos[@]} -gt 0 ]; then ml="$(mention_line "$ch" "${tos[@]}")" || rc=$?
  else ml="$(mention_line "$ch")" || rc=$?; fi
  [ "$rc" != 5 ] || exit 2
  [ "$rc" = 0 ] && [ -n "$ml" ] || die "could not read the channel roster — not posting an update that notifies nobody (check \`hq whoami\` and that node is on PATH, then retry)"
  # The room shows `@Ada Lovelace`; the quotes only ever existed as CLI syntax.
  local shown names_nl
  shown="$(printf '%s' "$ml" | sed -E 's/@"([^"]+)"/@\1/g')"
  names_nl="$(printf '%s' "$ml" | grep -oE '@"[^"]+"' | sed -E 's/^@"//; s/"$//')"
  msg="$shown"$'\n\n'"$msg"

  # One thread per topic: the first post on a topic is the root, every later
  # post on it is a reply under that root, so the room stays scannable.
  local key root=""
  key="$(topic_slug "${topic:-$title}")"
  if [ -n "$under" ]; then
    # Reply under someone else's (or an earlier) thread, and keep this topic there.
    root="$(resolve_root "$ch" "$under")" || exit 2
    [ "$(thread_root "$key")" = "$root" ] || printf '%s\t%s\n' "$key" "$root" >> "$(threads_file)"
  elif [ "$new_thread" != 1 ]; then
    root="$(thread_root "$key")"
  fi
  local payload
  payload="$(printf '%s\n' "$names_nl" | mentions_json | jq -c --arg body "$msg" --arg root "$root" \
    '{body:$body, mentions:.} + (if $root != "" then {rootEventId:$root} else {} end)')"
  [ "$(printf '%s' "$payload" | jq '.mentions | length')" -gt 0 ] || die "no mention resolved to a channel member id — not posting an update that notifies nobody"
  local eid
  eid="$(send_channel "$ch" "$payload")" || die "post failed — nothing was sent"
  if [ -z "$root" ]; then
    [ -n "$eid" ] && printf '%s\t%s\n' "$key" "$eid" >> "$(threads_file)"
    echo "thread: new topic '$key'${eid:+ (root $eid)}"
  else
    echo "thread: reply under topic '$key'"
  fi
  # Our own post must not come back as "new" on the next poll.
  latest_sk "$ch" > "$(cursor_file)"
  echo "posted to #$ch ($(printf '%s' "$msg" | wc -c | tr -d ' ') chars)"
}

# Prints new messages (not ours) since the cursor as "<time> <name>: <body>",
# advances the cursor. Exit 0 if any printed, 3 if none.
cmd_poll() {
  local ch; ch="$(require_channel)"
  local cf; cf="$(cursor_file)"
  local cursor; cursor="$(cat "$cf" 2>/dev/null || true)"
  local me; me="$(self_email)"
  local items; items="$(fetch_items "$ch" 50)"
  local last; last="$(printf '%s' "$items" | jq -r 'last // empty | .sk // empty')"
  local msgs
  msgs="$(printf '%s' "$items" | jq -r --arg cur "$cursor" --arg me "$me" '
    map(select((.sk // "") > $cur and ($me == "" or .fromEmail != $me)))
    | .[]
    | ((.sk // "")[0:16] | sub("T"; " ")) + "Z " + (.fromDisplayName // .fromEmail // "?") + ": " + ((.body // "") | gsub("^\\s+|\\s+$"; ""))')"
  [ -n "$last" ] && printf '%s\n' "$last" > "$cf"
  if [ -n "$(printf '%s' "$msgs" | tr -d '[:space:]')" ]; then printf '%s\n' "$msgs"; return 0; fi
  return 3
}

cmd_listen() {
  local interval=60 timeout=1800
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval) interval="$2"; shift 2 ;;
      --timeout)  timeout="$2"; shift 2 ;;
      *) die "listen: unknown arg $1" ;;
    esac
  done
  local ch; ch="$(require_channel)"
  local deadline=$(( $(date +%s) + timeout ))
  echo "listening on #$ch every ${interval}s (timeout ${timeout}s)"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if cmd_poll; then echo "--- new message(s) on #$ch; handle them, then re-run listen"; return 0; fi
    sleep "$interval"
  done
  echo "no new messages on #$ch within ${timeout}s"; return 3
}

case "${1:-}" in
  bind)   shift; cmd_bind "$@" ;;
  unbind) cmd_unbind ;;
  status) cmd_status ;;
  post)   shift; cmd_post "$@" ;;
  roster) cmd_roster ;;
  threads) cmd_threads ;;
  poll)   cmd_poll ;;
  listen) shift; cmd_listen "$@" ;;
  *) sed -n '2,25p' "$0"; exit 2 ;;
esac
