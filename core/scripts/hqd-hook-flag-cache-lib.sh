#!/bin/sh
# Sourced by hqd-hook-shim.sh; cache refresh stays outside the fresh event path.
TTL_SECONDS=60
company_cache_scope=${HQ_COMPANY_UID:-unscoped}
case "$company_cache_scope" in
  ''|*[!A-Za-z0-9_-]*) company_cache_scope=$(printf '%s' "$company_cache_scope" | cksum | awk '{print $1}') ;;
esac
CACHE_FILE=${HOME:-}/.hq/hq-anywhere-runtime.flag.$company_cache_scope

now_seconds() {
  if [ -r /proc/uptime ]; then
    IFS='. ' read -r uptime_seconds _ < /proc/uptime || uptime_seconds=''
    case "$uptime_seconds" in ''|*[!0-9]*) ;; *) printf '%s\n' "$uptime_seconds"; return 0 ;; esac
  fi
  date +%s 2>/dev/null || printf '0\n'
}

store_flag_cache_value() {
  value="$1"
  case "$value" in true|false) ;; *) return 1 ;; esac
  [ -n "${HOME:-}" ] || return 1
  cache_dir=${CACHE_FILE%/*}
  [ "$cache_dir" != "$CACHE_FILE" ] || cache_dir=.
  (umask 077; mkdir -p "$cache_dir") 2>/dev/null || return 1
  chmod 700 "$cache_dir" 2>/dev/null || return 1
  temporary=$(umask 077; mktemp "$CACHE_FILE.tmp.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s %s\n' "$value" "$(now_seconds)" >"$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  chmod 600 "$temporary" 2>/dev/null || { rm -f "$temporary"; return 1; }
  mv -f "$temporary" "$CACHE_FILE" 2>/dev/null || { rm -f "$temporary"; return 1; }
  return 0
}

hqd_hook_flag_cache_store_enabled() {
  store_flag_cache_value true
}

refresh_cache() {
  [ -n "${HOME:-}" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  local flag_script=${HQD_FLAG_SCRIPT:-${FLAG_DIR:-}/hq-anywhere-runtime-flag.cjs}
  [ -f "$flag_script" ] || return 1
  value=$(HQ_ROOT="${HQD_FLAG_ROOT:-${HQ_ROOT:-}}" \
    HQ_FLAG_KEY="${HQD_FLAG_KEY:-${HQ_FLAG_KEY:-}}" \
    HQ_COMPANY_SLUG="${HQ_COMPANY_SLUG:-}" \
    node "$flag_script" 2>/dev/null) || return 1
  store_flag_cache_value "$value"
}



hqd_hook_flag_enabled() {
cached_value=''
cached_at=''
extra=''
cache_line=''
if [ -r "$CACHE_FILE" ] && [ -f "$CACHE_FILE" ]; then
  if exec 3<"$CACHE_FILE"; then
    IFS= read -r cache_line <&3 || cache_line=''
    IFS=' ' read -r cached_value cached_at extra <<EOF
$cache_line
EOF
    if IFS= read -r _ <&3; then cached_value=''; fi
    exec 3<&-
  fi
fi
case "$cached_value" in true|false) ;; *) cached_value='' ;; esac
case "$cached_at" in ''|*[!0-9]*) cached_value='' ;; esac
[ "$cache_line" = "$cached_value $cached_at" ] || cached_value=''
[ -z "$extra" ] || cached_value=''

now=$(now_seconds)
case "$now" in ''|*[!0-9]*) cached_value='' ;; esac
if [ -n "$cached_value" ] && [ "$now" -ge "$cached_at" ] \
  && [ $((now - cached_at)) -lt "$TTL_SECONDS" ]; then
  # shellcheck disable=SC2034 # The sourcing hqd shim consumes this result.
  HQD_FLAG_ENABLED=$cached_value
  return 0
  fi

# Cache misses and stale snapshots refresh synchronously. Use that successful
# result for this event; otherwise an enabled gate would skip enforcement.
if refresh_cache >/dev/null 2>&1; then
  # shellcheck disable=SC2034 # The sourcing hqd shim consumes this result.
  HQD_FLAG_ENABLED=$value
else
  # An unavailable flag reader follows the HQ Anywhere fail-safe default.
  # shellcheck disable=SC2034 # The sourcing hqd shim consumes this result.
  HQD_FLAG_ENABLED=true
fi
}

# hqd_hook_flag_enabled_for <cache-key> <flag-key> <script> <root> <company-scope>
# Use a dedicated, company-scoped snapshot for additional hook flags.
# A missing, malformed, or expired value refreshes synchronously; failed reads
# return false for this event. The cache file is private like the legacy cache.
hqd_hook_flag_enabled_for() {
  local cache_key="${1:-}" flag_key="${2:-}" flag_script="${3:-}" root="${4:-}" scope="${5:-}"
  local old_cache_file=${CACHE_FILE:-} old_script=${HQD_FLAG_SCRIPT:-} old_key=${HQD_FLAG_KEY:-}
  local old_root=${HQD_FLAG_ROOT:-} scope_key
  case "$cache_key" in ''|*[!A-Za-z0-9_.-]*) HQD_FLAG_ENABLED=false; return 0 ;; esac
  case "$flag_key" in ''|*[!A-Za-z0-9_.-]*) HQD_FLAG_ENABLED=false; return 0 ;; esac
  [ -n "${HOME:-}" ] && [ -n "$root" ] && [ -n "$scope" ] && [ -f "$flag_script" ] \
    || { # shellcheck disable=SC2034 # The caller consumes this fail-closed result.
      HQD_FLAG_ENABLED=false
      return 0
    }
  case "$scope" in ''|*[!A-Za-z0-9_-]*) scope_key=$(printf '%s' "$scope" | cksum | awk '{print $1}') ;; *) scope_key=$scope ;; esac
  CACHE_FILE="${HOME:-}/.hq/hook-flag.${cache_key}.${scope_key}"
  HQD_FLAG_SCRIPT=$flag_script
  HQD_FLAG_KEY=$flag_key
  HQD_FLAG_ROOT=$root
  hqd_hook_flag_enabled
  HQD_FLAG_SCRIPT=$old_script
  HQD_FLAG_KEY=$old_key
  HQD_FLAG_ROOT=$old_root
  if [ -n "$old_cache_file" ]; then CACHE_FILE=$old_cache_file; else unset CACHE_FILE; fi
  return 0
}

# hqd_hook_flag_state_for <cache-key> <flag-key> <script> <root> <company-scope> [company-slug]
# Return true, false, or unknown in HQD_FLAG_STATE. The tri-state form lets
# one kill switch default on without changing the legacy helper's other callers.
hqd_hook_flag_state_for() {
  local cache_key="${1:-}" flag_key="${2:-}" flag_script="${3:-}" root="${4:-}" scope="${5:-}" company_slug="${6:-}"
  local old_cache_file=${CACHE_FILE:-} old_script=${HQD_FLAG_SCRIPT:-} old_key=${HQD_FLAG_KEY:-}
  local old_root=${HQD_FLAG_ROOT:-} old_company_slug=${HQ_COMPANY_SLUG:-} scope_key
  local cached_value='' cached_at='' extra='' cache_line='' now='' value=''
  HQD_FLAG_STATE=unknown
  case "$cache_key" in ''|*[!A-Za-z0-9_.-]*) return 0 ;; esac
  case "$flag_key" in ''|*[!A-Za-z0-9_.-]*) return 0 ;; esac
  [ -n "${HOME:-}" ] && [ -n "$root" ] && [ -n "$scope" ] && [ -f "$flag_script" ] || return 0
  case "$scope" in ''|*[!A-Za-z0-9_-]*) scope_key=$(printf '%s' "$scope" | cksum | awk '{print $1}') ;; *) scope_key=$scope ;; esac
  CACHE_FILE="${HOME}/.hq/hook-flag.${cache_key}.${scope_key}"
  HQD_FLAG_SCRIPT=$flag_script
  HQD_FLAG_KEY=$flag_key
  HQD_FLAG_ROOT=$root
  [ -z "$company_slug" ] || HQ_COMPANY_SLUG=$company_slug

  if [ -r "$CACHE_FILE" ] && [ -f "$CACHE_FILE" ] && exec 3<"$CACHE_FILE"; then
    IFS= read -r cache_line <&3 || cache_line=''
    IFS=' ' read -r cached_value cached_at extra <<EOF
$cache_line
EOF
    if IFS= read -r _ <&3; then cached_value=''; fi
    exec 3<&-
  fi
  case "$cached_value" in true|false) ;; *) cached_value='' ;; esac
  case "$cached_at" in ''|*[!0-9]*) cached_value='' ;; esac
  [ "$cache_line" = "$cached_value $cached_at" ] || cached_value=''
  [ -z "$extra" ] || cached_value=''
  now=$(now_seconds)
  case "$now" in ''|*[!0-9]*) cached_value='' ;; esac
  if [ -n "$cached_value" ] && [ "$now" -ge "$cached_at" ] \
    && [ $((now - cached_at)) -lt "$TTL_SECONDS" ]; then
    HQD_FLAG_STATE=$cached_value
  elif refresh_cache >/dev/null 2>&1; then
    HQD_FLAG_STATE=$value
  fi

  HQD_FLAG_SCRIPT=$old_script
  HQD_FLAG_KEY=$old_key
  HQD_FLAG_ROOT=$old_root
  if [ -n "$old_company_slug" ]; then HQ_COMPANY_SLUG=$old_company_slug; else unset HQ_COMPANY_SLUG; fi
  if [ -n "$old_cache_file" ]; then CACHE_FILE=$old_cache_file; else unset CACHE_FILE; fi
  return 0
}
