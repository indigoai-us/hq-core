#!/bin/bash
# welcome-brief-ready.sh — once per person, on a fresh SessionStart, say when
# the welcome brief is ready.
#
# Startup only (source=startup). Never resume or compact. No company is
# required. Only a human session counts: agent and bot sessions, the
# checkpoint sibling (HQ_CHECKPOINT_SIBLING) and lane workers (HQ_LANE_ID)
# exit before any marker is read or written. HQ_WELCOME_BRIEF_HOOK=0 (or
# false, off, no) makes this a no-op. Workflow-runner children and hq-job-run
# jobs disable it.
# Any other case, including errors and a missing jq, exits 0 with no output
# and no stderr.
#
# Index lines do not carry a welcome field. Run ids come from
# workspace/brief/index.jsonl, or from brief-*/ when that file is missing or
# empty. The welcome run is usually the oldest, so candidates are the 20
# oldest runs plus the 20 newest, checked oldest first. One jq reads those
# brief.json and status.json files. A run counts only when brief.json has a
# top-level welcome object with no error key and status.json says ready. jq.exe on Windows
# writes CRLF; a CR left on a run id is stripped before the id check.
# Symlinks are resolved before the read. Git Bash pwd -P keeps the path
# used to enter a directory link, so on Windows each component is readlink'd.
# A physical path outside the HQ root is not read. A Windows C:/ or C:\
# project root, or link target, is turned into /c/ first.
#
# The marker ~/.hq/onboarding/welcome-brief-announced is created exclusively
# before any output. When no candidate qualifies and the newest run is
# finished (status.json ready or failed, and brief.json present), a
# single checked-none file holding that run id is written instead. A later
# startup with that same newest id exits after one builtin read. A newest run
# that is still going, or has no brief.json, does not get the marker, and
# neither does a newest run while an older candidate is still going. One
# unreadable candidate is skipped and the rest are still read. A failed write
# stays silent, and a marker this run created but could not fill is removed.
# Registered in .claude/hooks/hook-registry.json immediately after
# auto-startwork. settings.json only starts master-hook.sh, which dispatches
# that registry; the Codex and Grok adapters read it too.

set -u

# Git Bash pwd -P does not resolve a directory symlink. Walk those with readlink.
hq_windows=0
case "${OSTYPE:-}" in
  msys*|cygwin*|mingw*) hq_windows=1 ;;
esac

silent() { exit 0; }

stdin_json=""
while IFS= read -r line || [ -n "${line:-}" ]; do
  if [ -z "$stdin_json" ]; then
    stdin_json="$line"
  else
    stdin_json="${stdin_json}
${line}"
  fi
done

case "${HQ_WELCOME_BRIEF_HOOK:-}" in
  0|false|FALSE|off|OFF|no|NO) silent ;;
esac

# Only a person's own session may use up the once-only marker. Same order as
# inject-policy-on-trigger.sh: HQ_SESSION_PRINCIPAL, then fleet identity
# (agent), then HQ_BOT_AGENT_UID or HQ_MACHINE_CREDS_FILE (bot), else human.
# Builtins and file tests only.
session_principal=""
case "${HQ_SESSION_PRINCIPAL:-}" in
  human|agent|bot) session_principal="$HQ_SESSION_PRINCIPAL" ;;
esac
if [ -z "$session_principal" ]; then
  principal_agent_root="${HQ_AGENT_ROOT_PREFIX:-}"
  if [ -n "${HQ_AGENT_WORKDIR:-}" ] || [ -n "${HQ_AGENT_COMPANY_DIR:-}" ] \
    || [ -n "${HQ_AGENT_IDENTITY_FILE:-}" ] \
    || [ -f /etc/hq-agent/identity.json ] || [ -f /etc/hq-agent/machine-creds.json ] \
    || [ -f /var/lib/hq-agent/machine-creds.json ] \
    || { [ -n "$principal_agent_root" ] && [ -f "${principal_agent_root%/}/var/lib/hq-agent/identity.json" ]; } \
    || { [ -z "$principal_agent_root" ] && [ -f /var/lib/hq-agent/identity.json ]; }; then
    session_principal="agent"
  elif [ -n "${HQ_BOT_AGENT_UID:-}" ] || [ -n "${HQ_MACHINE_CREDS_FILE:-}" ]; then
    session_principal="bot"
  else
    session_principal="human"
  fi
fi
[ "$session_principal" = "human" ] || silent

# Headless runs that keep the person's env and so resolve as human: the
# detached checkpoint sibling (hq core checkpoint) and hq lanes workers.
[ -z "${HQ_CHECKPOINT_SIBLING:-}" ] || silent
[ -z "${HQ_LANE_ID:-}" ] || silent

home="${HOME:-}"
if [ -n "$home" ] && [ -f "${home}/.hq/onboarding/welcome-brief-announced" ]; then
  silent
fi

# First "key" string value. SessionStart payloads are flat; values have no
# escaped quotes. Builtin only, so the no-op path does not spawn jq.
json_string_field() {
  local json="$1" key="$2" token rest
  json="${json:-}"
  token="\"${key}\""
  case "$json" in
    *"$token"*) ;;
    *) printf '%s' ""; return 0 ;;
  esac
  rest="${json#*"$token"}"
  while :; do
    case "$rest" in
      "") printf '%s' ""; return 0 ;;
      [[:space:]]*) rest="${rest#?}" ;;
      ":"*) rest="${rest#:}"; break ;;
      *) printf '%s' ""; return 0 ;;
    esac
  done
  while :; do
    case "$rest" in
      "") printf '%s' ""; return 0 ;;
      [[:space:]]*) rest="${rest#?}" ;;
      "\""*) rest="${rest#\"}"; break ;;
      *) printf '%s' ""; return 0 ;;
    esac
  done
  printf '%s' "${rest%%\"*}"
}

event_name="$(json_string_field "$stdin_json" hook_event_name)"
case "$event_name" in
  ""|SessionStart) ;;
  *) silent ;;
esac

source_name="$(json_string_field "$stdin_json" source)"
case "$source_name" in
  startup) ;;
  *) silent ;;
esac

command -v jq >/dev/null 2>&1 || silent

hq_root="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$hq_root" ]; then
  hq_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || silent
fi
[ -n "$hq_root" ] || silent

# Git Bash pwd -P prints /c/repo. Claude on Windows often passes C:/repo or
# C:\repo, which resolve_inside would reject and then miss the index.
to_slash_root() {
  local p="$1" drive rest low
  p="${p//\\//}"
  case "$p" in
    [A-Za-z]:/*)
      drive="${p%%:*}"
      rest="${p#*:}"
      low="$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')"
      printf '/%s%s' "$low" "$rest"
      ;;
    *) printf '%s' "$p" ;;
  esac
}
hq_root="$(to_slash_root "$hq_root")"

root_phys="$(cd -P -- "$hq_root" 2>/dev/null && pwd -P)" || silent
[ -n "$root_phys" ] && [ "$root_phys" != "/" ] || silent

# Collapse /./ and /../ without resolving any further symlink.
normalize_path() {
  local path="$1" rest part out
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  rest="$path"
  out=""
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *) rest="" ;;
    esac
    case "$part" in
      ""|.) ;;
      ..) out="${out%/*}" ;;
      *) out="${out}/${part}" ;;
    esac
  done
  printf '%s' "${out:-/}"
}

inside_phys() {
  case "$1" in
    "$root_phys"|"$root_phys"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Physical path after every symlink hop. On macOS, cd -P resolves directory
# links. On Windows, pwd -P keeps the path used to enter the link, so each
# component is readlink'd instead. Prints the path only when it stays inside
# the HQ root.
resolve_inside() {
  local p="$1" i=0 target parent base final cur segment rest followed
  case "$p" in
    /*) ;;
    *) return 1 ;;
  esac
  while [ "$i" -lt 40 ]; do
    i=$((i + 1))
    p="$(normalize_path "$p")" || return 1
    followed=0
    if [ "$hq_windows" -eq 1 ]; then
      rest="${p#/}"
      cur=""
      while [ -n "$rest" ]; do
        segment="${rest%%/*}"
        case "$rest" in
          */*) rest="${rest#*/}" ;;
          *) rest="" ;;
        esac
        [ -n "$segment" ] || continue
        if [ -z "$cur" ]; then
          cur="/${segment}"
        else
          cur="${cur}/${segment}"
        fi
        if [ -L "$cur" ]; then
          target="$(readlink "$cur" 2>/dev/null)" || return 1
          target="${target//$'\r'/}"
          [ -n "$target" ] || return 1
          target="$(to_slash_root "$target")"
          case "$target" in
            /*) p="$target" ;;
            *)
              parent="${cur%/*}"
              [ -n "$parent" ] || parent="/"
              p="${parent}/${target}"
              ;;
          esac
          if [ -n "$rest" ]; then
            p="${p}/${rest}"
          fi
          followed=1
          break
        fi
      done
    elif [ -L "$p" ]; then
      target="$(readlink "$p" 2>/dev/null)" || return 1
      target="${target//$'\r'/}"
      [ -n "$target" ] || return 1
      target="$(to_slash_root "$target")"
      parent="${p%/*}"
      [ -n "$parent" ] || parent="/"
      parent="$(cd -P -- "$parent" 2>/dev/null && pwd -P)" || return 1
      case "$target" in
        /*) p="$target" ;;
        *) p="${parent}/${target}" ;;
      esac
      followed=1
    fi
    [ "$followed" -eq 1 ] && continue
    [ -e "$p" ] || return 1
    parent="${p%/*}"
    base="${p##*/}"
    case "$parent" in
      ""|"/") parent="/" ;;
      *) parent="$(cd -P -- "$parent" 2>/dev/null && pwd -P)" || return 1 ;;
    esac
    if [ "$parent" = "/" ]; then
      final="/${base}"
    else
      final="${parent}/${base}"
    fi
    final="$(normalize_path "$final")" || return 1
    inside_phys "$final" || return 1
    printf '%s\n' "$final"
    return 0
  done
  return 1
}

# Whole-string match for brief-YYYYMMDD-HHMMSS. Rejects ../ and any extra path.
valid_run_id() {
  case "${1:-}" in
    brief-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# 20 oldest plus 20 newest. Welcome is normally the oldest run.
CAP=20
oldest_n=0
ring_n=0
ring_i=0
oldest_ids=()
newest_ids=()
newest=""

consider_id() {
  local id="$1"
  newest="$id"
  if [ "$oldest_n" -lt "$CAP" ]; then
    oldest_ids[$oldest_n]="$id"
    oldest_n=$((oldest_n + 1))
  fi
  newest_ids[$ring_i]="$id"
  ring_i=$(( (ring_i + 1) % CAP ))
  if [ "$ring_n" -lt "$CAP" ]; then
    ring_n=$((ring_n + 1))
  fi
}

# One file holds the newest run id that was checked and had no welcome.
none_marker="${home}/.hq/onboarding/welcome-brief-checked-none"

checked_none_exists() {
  local saved=""
  [ -n "${home:-}" ] || return 1
  valid_run_id "${newest:-}" || return 1
  [ -f "$none_marker" ] || return 1
  IFS= read -r saved <"$none_marker" 2>/dev/null || [ -n "$saved" ] || return 1
  [ "$(json_string_field "$saved" run_id)" = "$newest" ]
}

# Write a temp file, then rename it over the old one.
write_checked_none() {
  local dir tmp
  [ -n "${home:-}" ] || return 0
  valid_run_id "${newest:-}" || return 0
  dir="${home}/.hq/onboarding"
  mkdir -p -- "$dir" 2>/dev/null || return 0
  tmp="${none_marker}.tmp.$$"
  if { printf '{"run_id":"%s"}\n' "$newest" >"$tmp"; } 2>/dev/null; then
    mv -f -- "$tmp" "$none_marker" 2>/dev/null || rm -f -- "$tmp" 2>/dev/null
  else
    rm -f -- "$tmp" 2>/dev/null
  fi
  return 0
}

brief_dir="${hq_root}/workspace/brief"
index_path="${brief_dir}/index.jsonl"
index_phys=""
index_nonempty=0
last_line=""
cand_nl=""
chosen=""
brief_phys_dir=""

if [ -f "$index_path" ]; then
  index_phys="$(resolve_inside "$index_path" 2>/dev/null || true)"
fi
if [ -n "$index_phys" ]; then
  while IFS= read -r line || [ -n "${line:-}" ]; do
    line="${line//$'\r'/}"
    case "${line:-}" in
      *[![:space:]]*) index_nonempty=1; last_line="$line" ;;
    esac
  done <"$index_phys"
fi

if [ "$index_nonempty" -eq 1 ]; then
  # Run dirs sit under the brief dir, wherever an index link points.
  brief_phys_dir="$(resolve_inside "$brief_dir" 2>/dev/null || true)"
  newest="$(json_string_field "$last_line" run_id)"
  valid_run_id "$newest" || newest=""
  checked_none_exists && silent
  # \z, not $, so a trailing newline is not a valid run id.
  # File order is oldest first. Keep the first 20 and the last 20.
  cand_nl="$(jq -nRr '
    [inputs
      | fromjson?
      | select(type == "object")
      | .run_id // empty
      | select(type == "string" and test("^brief-[0-9]{8}-[0-9]{6}\\z"))
    ] as $all
    | if ($all | length) == 0 then empty
      else
        ($all[0:20] + (
          $all[-20:] | map(select(. as $id | ($all[0:20] | index($id) | not)))
        ))
        | .[]
      end
  ' <"$index_phys" 2>/dev/null || true)"
  cand_nl="${cand_nl//$'\r'/}"
elif brief_phys_dir="$(resolve_inside "$brief_dir" 2>/dev/null || true)" \
  && [ -n "$brief_phys_dir" ]; then
  newest=""
  oldest_n=0
  ring_n=0
  ring_i=0
  id=""
  run_dir=""
  for run_dir in "${brief_dir}/"brief-*/; do
    [ -d "$run_dir" ] || continue
    id="${run_dir%/}"
    id="${id##*/}"
    valid_run_id "$id" || continue
    consider_id "$id"
  done
  checked_none_exists && silent
  seen="|"
  i=0
  while [ "$i" -lt "$oldest_n" ]; do
    id="${oldest_ids[$i]}"
    case "$seen" in
      *"|${id}|"*) ;;
      *)
        seen="${seen}${id}|"
        cand_nl="${cand_nl}${id}
"
        ;;
    esac
    i=$((i + 1))
  done
  if [ "$ring_n" -gt 0 ]; then
    if [ "$ring_n" -lt "$CAP" ]; then
      start=0
    else
      start=$ring_i
    fi
    i=0
    while [ "$i" -lt "$ring_n" ]; do
      idx=$(( (start + i) % CAP ))
      id="${newest_ids[$idx]}"
      case "$seen" in
        *"|${id}|"*) ;;
        *)
          seen="${seen}${id}|"
          cand_nl="${cand_nl}${id}
"
          ;;
      esac
      i=$((i + 1))
    done
  fi
else
  silent
fi

file_n=0
pair_files=()
id_text=""
# Split on newlines with parameter expansion. bash 3.2 backs a here-document
# with a temp file, which fails on a full disk.
nl='
'
cand_rest="$cand_nl"
while [ -n "$cand_rest" ]; do
  case "$cand_rest" in
    *"$nl"*) id="${cand_rest%%"$nl"*}"; cand_rest="${cand_rest#*"$nl"}" ;;
    *) id="$cand_rest"; cand_rest="" ;;
  esac
  id="${id//$'\r'/}"
  [ -n "${id:-}" ] || continue
  valid_run_id "$id" || continue
  run_logical="${brief_dir}/${id}"
  brief_logical="${run_logical}/brief.json"
  status_logical="${run_logical}/status.json"
  # A real directory with real files stays at the brief dir's physical path.
  # Symlinks take the full walk, so a later hop cannot leave the HQ root.
  if [ -n "$brief_phys_dir" ] && [ ! -L "$run_logical" ] && [ -d "$run_logical" ] \
    && [ ! -L "$brief_logical" ] && [ ! -L "$status_logical" ] \
    && [ -f "$brief_logical" ] && [ -f "$status_logical" ]; then
    brief_phys="${brief_phys_dir}/${id}/brief.json"
    status_phys="${brief_phys_dir}/${id}/status.json"
  else
    brief_phys="$(resolve_inside "$brief_logical" 2>/dev/null || true)"
    status_phys="$(resolve_inside "$status_logical" 2>/dev/null || true)"
  fi
  [ -n "$brief_phys" ] && [ -n "$status_phys" ] || continue
  pair_files[$file_n]="$brief_phys"
  file_n=$((file_n + 1))
  pair_files[$file_n]="$status_phys"
  file_n=$((file_n + 1))
  id_text="${id_text}${id}
"
done

# First line is the oldest ready welcome id, or empty. Second line is 1 only
# when the newest run's own brief.json and status.json were read and status
# is ready or failed, and no other candidate read here is still going. A
# welcome block with an error key does not count. A parse failure is not a
# finished run.
SCAN_FILTER='
  [ $ids | split("\n")[] | select(length > 0) ] as $want
  | [ range(0; ($want | length)) as $i
      | {id: $want[$i], b: .[$i * 2], s: .[$i * 2 + 1]}
    ] as $rows
  | ([ $rows[]
      | select(
          (.b | type) == "object"
          and ((.b.welcome | type) == "object")
          and ((.b.welcome | has("error")) | not)
          and (.s | type) == "object"
          and ((.s.state | type) == "string")
          and (.s.state == "ready")
        )
      | .id
    ] | .[0] // "") as $chosen
  | ([ $rows[] | select(.id == $newest) ] | .[0] // null) as $new
  | (
      $new != null
      and ($new.b | type) == "object"
      and ($new.s | type) == "object"
      and (($new.s.state | type) == "string")
      and ($new.s.state == "ready" or $new.s.state == "failed")
      and ([ $rows[]
        | select(((.s | type) != "object")
          or ((.s.state != "ready") and (.s.state != "failed")))
      ] | length) == 0
    ) as $done
  | $chosen + "\n" + (if $done then "1" else "0" end)
'

apply_scan_out() {
  local result="$1" flag
  result="${result//$'\r'/}"
  case "$result" in
    *$'\n'*) ;;
    *) return 1 ;;
  esac
  chosen="${result%%$'\n'*}"
  flag="${result#*$'\n'}"
  flag="${flag%%$'\n'*}"
  case "$flag" in
    1) newest_finished=1 ;;
    0) newest_finished=0 ;;
    *) return 1 ;;
  esac
  return 0
}

run_scan() {
  local out
  [ "$file_n" -gt 0 ] || return 1
  out="$(jq -sr --arg ids "$id_text" --arg newest "${newest:-}" \
    "$SCAN_FILTER" "${pair_files[@]}" 2>/dev/null)" || return 1
  apply_scan_out "$out"
}

# The batch read fails closed on one bad file. Drop pairs jq cannot parse
# and read the rest. The happy path does not do this.
drop_bad_pairs() {
  local i=0 n=0 k=0 brief status id good_ids id_rest
  local -a good_files ids_arr
  good_ids=""
  id_rest="$id_text"
  while [ -n "$id_rest" ]; do
    case "$id_rest" in
      *"$nl"*) id="${id_rest%%"$nl"*}"; id_rest="${id_rest#*"$nl"}" ;;
      *) id="$id_rest"; id_rest="" ;;
    esac
    [ -n "${id:-}" ] || continue
    ids_arr[$k]="$id"
    k=$((k + 1))
  done
  i=0
  while [ "$i" -lt "$file_n" ]; do
    brief="${pair_files[$i]}"
    status="${pair_files[$((i + 1))]}"
    id="${ids_arr[$((i / 2))]:-}"
    if [ -n "$id" ] \
      && jq -e . "$brief" >/dev/null 2>&1 \
      && jq -e . "$status" >/dev/null 2>&1; then
      good_files[$n]="$brief"
      n=$((n + 1))
      good_files[$n]="$status"
      n=$((n + 1))
      good_ids="${good_ids}${id}
"
    fi
    i=$((i + 2))
  done
  file_n=0
  id_text=""
  pair_files=()
  if [ "$n" -gt 0 ]; then
    pair_files=("${good_files[@]}")
    file_n=$n
    id_text="$good_ids"
  fi
}

scan_ok=1
newest_finished=0
chosen=""
if [ "$file_n" -gt 0 ]; then
  if ! run_scan; then
    drop_bad_pairs
    if [ "$file_n" -eq 0 ] || ! run_scan; then
      scan_ok=0
      chosen=""
      newest_finished=0
    fi
  fi
fi

if ! valid_run_id "${chosen:-}"; then
  if [ "$scan_ok" -eq 1 ] && [ "$newest_finished" -eq 1 ]; then
    write_checked_none
  fi
  silent
fi
[ -n "$home" ] || silent

marker_dir="${home}/.hq/onboarding"
marker="${marker_dir}/welcome-brief-announced"
mkdir -p -- "$marker_dir" 2>/dev/null || silent
at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
at="${at//$'\r'/}"
case "${at:-}" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
  *)
    # Git Bash can find Windows date.exe first. That date does not take +fmt.
    if [ -x /usr/bin/date ]; then
      at="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
      at="${at//$'\r'/}"
    fi
    ;;
esac
[ -n "${at:-}" ] || silent

# Fixed text with no quotes or backslashes, so the JSON is a literal and
# nothing can fail between the marker write and the output.
sentence='Your welcome brief is ready. [Open your welcome brief](hq://brief). See your files: [Open your files](hq://vault).'
instruction='Show that sentence to the person in your first reply.'
output="{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"${sentence}\\n${instruction}\"}}"

# Exclusive create. The redirection error stays off stderr. Losers of a
# concurrent startup, and an unwritable directory, produce no announcement.
# Run id and time were checked above, so printf writes valid JSON. If the
# write fails after this process created the file, the file is removed so a
# later startup can still announce. printf runs in a subshell: bash 3.2 keeps
# the text of a failed builtin printf buffered and flushes it to stdout later,
# which would put the marker JSON in the hook output.
set -C
wrote=0
if { exec 3>"$marker"; } 2>/dev/null; then
  set +C
  if ( printf '{"run_id":"%s","at":"%s"}\n' "$chosen" "$at" ) >&3 2>/dev/null; then
    wrote=1
  fi
  exec 3>&-
  [ "$wrote" -eq 1 ] || rm -f -- "$marker" 2>/dev/null
fi
set +C
[ "$wrote" -eq 1 ] || silent

printf '%s\n' "$output"
exit 0
