#!/usr/bin/env bash
# hq-core: public
# usable-integrations.sh - which HQ Integrations (connected apps) this caller
# can use in the active company, cached so session start stays fast.
#
# Usage:
#   core/scripts/usable-integrations.sh context            # SessionStart hook (reads hook JSON on stdin)
#   core/scripts/usable-integrations.sh show --company <slug> [--json] [--refresh]
#   core/scripts/usable-integrations.sh refresh --company <slug>
#
# context: never touches the network. It resolves the active company from the
#   session's bound company, else the cwd (companies/<slug>/...), else, only
#   when the session starts at the HQ root itself, this device's default
#   company. A binding or companies/ folder that does not validate resolves to
#   nothing. With a fresh cache for that company it prints a SessionStart
#   additionalContext note that leads with the HQ-first rule and names the
#   usable apps. A missing or stale cache starts a background refresh and
#   prints the rule with how to check the list. Always exits 0.
# show: prints the cached list when fresh, else refreshes live first.
# refresh: runs `hq integrations list --usable --json --no-login --company
#   <slug>` and writes the cache. Signed out deletes every company's cache; a
#   denied company deletes its own. Offline or an older CLI leaves the cache
#   alone (it stops being shown after the TTL).
#
# Scope: one company per cache file, keyed and re-checked by slug. Output never
# includes endpoint URLs, tokens, scopes, or other companies' apps.
#
# Env: HQ_NO_USABLE_INTEGRATIONS=1 disables `context`.
#   HQ_USABLE_INTEGRATIONS_TTL     seconds a cache may be shown (default 3600)
#   HQ_USABLE_INTEGRATIONS_REFRESH seconds before a background refresh (default 600)
#   HQ_USABLE_INTEGRATIONS_MAX     app names listed at session start (default 30)
#   HQ_CLI_BIN                     hq binary (default: hq on PATH)
#   HQ_USABLE_INTEGRATIONS_TIMEOUT refresh deadline in seconds (default 20)

set -uo pipefail

is_hq_root() { [ -n "${1:-}" ] && [ -d "${1%/}/core" ] && [ -d "${1%/}/companies" ]; }

resolve_root() {
  local dir
  for dir in "${HQ_ROOT:-}" "${CLAUDE_PROJECT_DIR:-}"; do
    if is_hq_root "$dir"; then printf '%s' "${dir%/}"; return 0; fi
  done
  dir="$PWD"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if is_hq_root "$dir"; then printf '%s' "$dir"; return 0; fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# A company slug is usable only when it names a real, non-symlinked
# companies/<slug> directory (same rule as resolve-company.sh).
valid_slug() {
  case "${1:-}" in
    ''|_template|companies|*[!A-Za-z0-9_-]*) return 1 ;;
  esac
  [ -d "$ROOT/companies/$1" ] && [ ! -L "$ROOT/companies/$1" ]
}

now_epoch() { date +%s 2>/dev/null; }

file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true
}

# Seconds since a file changed, or empty when it is missing or unreadable.
file_age() {
  local mtime now
  [ -e "$1" ] || return 0
  mtime="$(file_mtime "$1")"
  now="$(now_epoch)"
  case "$now:$mtime" in
    *[!0-9:]*|:*|*:) return 0 ;;
  esac
  printf '%s' "$((now - mtime))"
}

int_env() { # <value> <default>
  case "${1:-}" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$((10#$1))" ;;
  esac
}

ROOT="$(resolve_root)" || exit 0
CACHE_DIR="$ROOT/.hq/usable-integrations"
DEFAULT_FILE="$CACHE_DIR/device-default"
TTL="$(int_env "${HQ_USABLE_INTEGRATIONS_TTL:-}" 3600)"
REFRESH_AFTER="$(int_env "${HQ_USABLE_INTEGRATIONS_REFRESH:-}" 600)"
MAX_NAMES="$(int_env "${HQ_USABLE_INTEGRATIONS_MAX:-}" 30)"
TIMEOUT_SECS="$(int_env "${HQ_USABLE_INTEGRATIONS_TIMEOUT:-}" 20)"
HQ_BIN="${HQ_CLI_BIN:-hq}"
# A cache too old to show is always due a refresh.
[ "$REFRESH_AFTER" -gt "$TTL" ] && REFRESH_AFTER="$TTL"
[ "$MAX_NAMES" -lt 1 ] && MAX_NAMES=1
[ "$TIMEOUT_SECS" -lt 1 ] && TIMEOUT_SECS=1

cache_file() { printf '%s/%s.json' "$CACHE_DIR" "$1"; }

# A cache is trusted only when it names the company it is filed under.
cache_valid_for() {
  local file
  file="$(cache_file "$1")"
  [ -f "$file" ] || return 1
  jq -e --arg slug "$1" '.schema == 1 and .company == $slug and (.apps | type == "array")' \
    "$file" >/dev/null 2>&1
}

run_with_deadline() { # <seconds> <cmd...>
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
  else
    "$@"
  fi
}

ensure_cache_dir() {
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 1
  chmod 700 "$CACHE_DIR" 2>/dev/null || true
}

# jq filter: one line of printable text, at most $n characters. Replaces
# control, bidi, and zero-width characters. Works without jq's regex support.
# shellcheck disable=SC2016 # jq program, not shell expansion
JQ_CLEAN='def clean($n): tostring | explode | map(if . < 32 or (. >= 127 and . < 160) or . == 8232 or . == 8233 or (. >= 8203 and . <= 8207) or (. >= 8234 and . <= 8238) or (. >= 8294 and . <= 8297) or . == 65279 then 32 else . end) | implode | split(" ") | map(select(length > 0)) | join(" ") | .[0:$n];'

do_refresh() {
  local slug="$1" out err rc=0 tmp
  valid_slug "$slug" || { echo "usable-integrations: unknown company '$slug'" >&2; return 2; }
  command -v jq >/dev/null 2>&1 || { echo "usable-integrations: jq is required" >&2; return 2; }
  ensure_cache_dir || return 1
  err="$(mktemp "$CACHE_DIR/.err.XXXXXX" 2>/dev/null)" || return 1
  out="$(run_with_deadline "$TIMEOUT_SECS" "$HQ_BIN" integrations list --usable --json --no-login \
    --company "$slug" 2>"$err" </dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if grep -Eqi 'no valid hq session|interactive login is disabled|not signed in|session has expired|run `?hq login' "$err"; then
      # Signed out: no list from the previous identity may keep showing.
      rm -f "$CACHE_DIR"/*.json "$DEFAULT_FILE"
    elif grep -Eqi 'not a member|forbidden|(^|[^0-9])403([^0-9]|$)|no active membership|unknown company' "$err"; then
      rm -f "$(cache_file "$slug")"
    fi
    # Anything else (offline, timeout, older CLI) keeps the cache until the TTL.
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  tmp="$(mktemp "$CACHE_DIR/.$slug.XXXXXX" 2>/dev/null)" || return 1
  if printf '%s' "$out" | jq -e --arg slug "$slug" --argjson now "$(now_epoch)" "$JQ_CLEAN"'
      def flag: if (type == "string") and test("^--(provider|connection) [A-Za-z0-9._:-]{1,120}$")
                then . else null end;
      select(.viewerAccessKnown == true and (.apps | type == "array"))
      | {schema: 1, company: $slug, fetchedAt: $now,
         apps: [.apps[]
                | ((.providerArg // "") | clean(80)) as $p
                | select($p != "")
                | {name: ((.name // $p) | clean(60)),
                   domain: (if (.domain | type) == "string" and (.domain | test("^[A-Za-z0-9.-]{1,80}$"))
                           then .domain else null end),
                   provider: $p,
                   status: ((.status // "connected") | clean(30)),
                   selector: ((.selector | flag) // ("--provider " + $p))}]}
    ' >"$tmp" 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$(cache_file "$slug")"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Record this device's default company for HQ-root sessions. Reads the local
# default without a membership reconcile and accepts it only when it is
# enabled, needs no choice, is one of the caller's memberships, and is a real
# companies/<slug>. A failed read leaves the file alone.
refresh_device_default() {
  local json slug
  json="$(run_with_deadline "$TIMEOUT_SECS" "$HQ_BIN" mesh context default get --json 2>/dev/null </dev/null)" || return 0
  printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1 || return 0
  slug="$(printf '%s' "$json" | jq -r '
      (.defaultCompany // .) as $d
      | if $d.enabled == true and ($d.source // "") != "disabled" and ($d.needsChoice // false) == false
           and ($d.slug | type == "string")
           and ([(.memberships // $d.memberships // [])[]? | .slug] | index($d.slug)) != null
        then $d.slug else "" end' 2>/dev/null)"
  ensure_cache_dir || return 0
  if valid_slug "$slug"; then
    printf '%s\n' "$slug" >"$DEFAULT_FILE"
  else
    rm -f "$DEFAULT_FILE"
  fi
}

# Run refreshes in the background unless one is already running for this key.
# <slug or empty> <want-default 0|1>
spawn_refresh() {
  local slug="$1" want_default="$2" key lock age
  key="${slug:-device-default}"
  ensure_cache_dir || return 0
  lock="$CACHE_DIR/.$key.lock"
  if [ -d "$lock" ]; then
    age="$(file_age "$lock")"
    [ -n "$age" ] && [ "$age" -lt 120 ] && return 0
    rmdir "$lock" 2>/dev/null || return 0
  fi
  mkdir "$lock" 2>/dev/null || return 0
  (
    trap 'rmdir "$lock" 2>/dev/null' EXIT
    if [ "$want_default" = 1 ]; then
      refresh_device_default
      [ -n "$slug" ] || slug="$(head -n 1 "$DEFAULT_FILE" 2>/dev/null | tr -d '[:space:]')"
    fi
    if valid_slug "$slug"; then do_refresh "$slug"; fi
  ) </dev/null >/dev/null 2>&1 &
  return 0
}

session_company() { # <session_id>
  local sid="$1" meta
  case "$sid" in ''|*[!A-Za-z0-9_.-]*) return 0 ;; esac
  meta="$ROOT/workspace/sessions/$sid/meta.yaml"
  [ -f "$meta" ] || return 0
  sed -n 's/^company_slug:[[:space:]]*//p' "$meta" 2>/dev/null | head -n 1 \
    | sed 's/[[:space:]]#.*$//' | tr -d "\"' \r"
}

# Prints "<slug> <source>" for the active company, or nothing. A leading
# "DEFAULT " marks a session started at the HQ root (device default allowed).
#   session         the session's bound company
#   cwd             the working folder is companies/<slug>/...
#   device_default  the session started at the HQ root itself
# A binding or companies/ folder that does not validate, and a session bound to
# personal work, resolve to nothing; they never fall through to the default.
active_company() {
  local input="$1" sid cwd slug rest
  sid="$(printf '%s' "$input" | jq -r '.session_id // .sessionId // empty' 2>/dev/null)"
  [ -n "$sid" ] || sid="${CLAUDE_SESSION_ID:-${HQ_SESSION_ID:-}}"
  slug="$(session_company "$sid")"
  if [ -n "$slug" ]; then
    if [ "$slug" != "personal" ] && valid_slug "$slug"; then printf '%s session' "$slug"; fi
    return 0
  fi
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
  [ -n "$cwd" ] || cwd="$PWD"
  cwd="${cwd%/}"
  case "$cwd/" in
    "$ROOT/companies/"*)
      rest="${cwd#"$ROOT/companies/"}"
      slug="${rest%%/*}"
      if valid_slug "$slug"; then printf '%s cwd' "$slug"; fi
      return 0
      ;;
  esac
  # Only a session started at the HQ root itself may fall back to the device
  # default. repos/, workspace/, and anything outside the root could belong to
  # any company.
  [ "$cwd" = "$ROOT" ] || return 0
  printf 'DEFAULT '
  slug="$(head -n 1 "$DEFAULT_FILE" 2>/dev/null | tr -d '[:space:]')"
  if valid_slug "$slug"; then printf '%s device_default' "$slug"; fi
  return 0
}

age_phrase() {
  local secs="$1"
  if [ "$secs" -lt 120 ]; then printf 'just now'
  elif [ "$secs" -lt 7200 ]; then printf '%s min ago' "$((secs / 60))"
  else printf '%s h ago' "$((secs / 3600))"
  fi
}

# The rule every note leads with: HQ first, everything else only after.
priority_rule() { # <slug>
  # shellcheck disable=SC2016 # backticks are literal command text
  printf 'HQ Integrations come first. Before you use any other MCP server, connector, web search, browser session, or ask the user for data from an external app, check whether company %s has that app in HQ and use it through HQ if so.' "$1"
}

scope_line() { # <slug> <source>
  if [ "$2" = "device_default" ]; then
    # shellcheck disable=SC2016 # backticks are literal command text
    printf 'This is for %s, this device'"'"'s default company. If this session is for another company, ignore it and run `bash core/scripts/usable-integrations.sh show --company <that company>` instead.' "$1"
  else
    printf 'Scoped to %s; never use these for another company'"'"'s work.' "$1"
  fi
}

# Note for a known company whose list is not cached yet (or has expired).
cold_text() { # <slug> <source>
  # shellcheck disable=SC2016 # backticks are literal command text
  printf '%s Run `bash core/scripts/usable-integrations.sh show --company %s` to see the apps you can use and the exact flag for each. %s' \
    "$(priority_rule "$1")" "$1" "$(scope_line "$1" "$2")"
}

context_text() { # <slug> <age> <source>
  local slug="$1" age="$2" source="$3" file count names more
  file="$(cache_file "$slug")"
  count="$(jq -r '.apps | length' "$file" 2>/dev/null)"
  case "$count" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$count" -eq 0 ]; then
    # shellcheck disable=SC2016 # backticks are literal command text
    printf 'HQ Integrations for company %s (checked %s): none of its connected apps are shared with you, so other routes are fine. Run `hq integrations list --company %s` to see what is connected; an admin can share an app with you. %s' \
      "$slug" "$(age_phrase "$age")" "$slug" "$(scope_line "$slug" "$source")"
    return 0
  fi
  names="$(jq -r --argjson max "$MAX_NAMES" '
      [.apps[:$max][] | .name + (if .domain then " (" + .domain + ")" else "" end)
                      + (if .status == "needs-attention" then " [needs attention]" else "" end)]
      | join(", ")' "$file" 2>/dev/null)" || return 1
  more=""
  [ "$count" -gt "$MAX_NAMES" ] && more=", and $((count - MAX_NAMES)) more"
  # shellcheck disable=SC2016 # backticks are literal command text
  printf '%s You can use %s apps through HQ in company %s (checked %s): %s%s. If the app you need is not named here, check the full list before using anything else: `bash core/scripts/usable-integrations.sh show --company %s`, which also prints the exact flag for each app. Then run `hq integrations tools --company %s <flag>` and `hq integrations call <tool> --company %s <flag> --args '"'"'<json>'"'"'`. Fall back to other routes only when the app is not in the list or HQ refuses the call. %s' \
    "$(priority_rule "$slug")" "$count" "$slug" "$(age_phrase "$age")" "$names" "$more" "$slug" "$slug" "$slug" "$(scope_line "$slug" "$source")"
}

cmd_context() {
  local input resolved slug source age text want_default=0
  input="$(cat 2>/dev/null || true)"
  [ "${HQ_NO_USABLE_INTEGRATIONS:-}" = "1" ] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  resolved="$(active_company "$input")"
  case "$resolved" in
    "DEFAULT "*|DEFAULT)
      resolved="${resolved#DEFAULT}"
      resolved="${resolved# }"
      # Keep the device default current; re-read it at most hourly.
      age="$(file_age "$DEFAULT_FILE")"
      if [ -z "$age" ] || [ "$age" -ge 3600 ] || [ "$age" -lt 0 ]; then want_default=1; fi
      ;;
  esac
  slug="${resolved%% *}"
  source="${resolved#* }"
  if [ -z "$slug" ]; then
    [ "$want_default" = 1 ] && spawn_refresh "" 1
    return 0
  fi
  age="$(file_age "$(cache_file "$slug")")"
  if [ -z "$age" ] || [ "$age" -ge "$REFRESH_AFTER" ] || [ "$age" -lt 0 ] || [ "$want_default" = 1 ]; then
    spawn_refresh "$slug" "$want_default"
  fi
  if [ -n "$age" ] && [ "$age" -ge 0 ] && [ "$age" -lt "$TTL" ] && cache_valid_for "$slug"; then
    text="$(context_text "$slug" "$age" "$source")" || text=""
  else
    text=""
  fi
  # No usable list yet: still say HQ comes first and how to check.
  [ -n "$text" ] || text="$(cold_text "$slug" "$source")"
  [ -n "$text" ] || return 0
  jq -nc --arg ctx "$text" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
}

cmd_show() {
  local slug="" json=0 force=0 age
  while [ $# -gt 0 ]; do
    case "$1" in
      --company) slug="${2:-}"; shift 2 || shift ;;
      --json) json=1; shift ;;
      --refresh) force=1; shift ;;
      *) shift ;;
    esac
  done
  if ! valid_slug "$slug"; then
    echo "usable-integrations: pass --company <slug> for a company in companies/" >&2
    return 2
  fi
  age="$(file_age "$(cache_file "$slug")")"
  if [ "$force" -eq 1 ] || [ -z "$age" ] || [ "$age" -ge "$TTL" ] || [ "$age" -lt 0 ] \
    || ! cache_valid_for "$slug"; then
    if ! do_refresh "$slug"; then
      echo "usable-integrations: could not reach HQ (signed out or offline). Try \`hq integrations list --usable --company $slug\`." >&2
      return 1
    fi
  fi
  cache_valid_for "$slug" || return 1
  if [ "$json" -eq 1 ]; then
    cat "$(cache_file "$slug")"
    return 0
  fi
  jq -r '
    if (.apps | length) == 0 then "No connected apps are shared with you in \(.company)."
    else .apps[] | "\(.name)\(if .domain then " (" + .domain + ")" else "" end)  \(.selector)\(if .status == "needs-attention" then "  [needs attention]" else "" end)"
    end' "$(cache_file "$slug")"
}

cmd_refresh() {
  local slug=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --company) slug="${2:-}"; shift 2 || shift ;;
      *) shift ;;
    esac
  done
  do_refresh "$slug"
}

case "${1:-}" in
  context) shift; cmd_context "$@"; exit 0 ;;
  show) shift; cmd_show "$@"; exit $? ;;
  refresh) shift; cmd_refresh "$@"; exit $? ;;
  -h|--help|help|'') sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usable-integrations: unknown command '$1'" >&2; exit 2 ;;
esac
