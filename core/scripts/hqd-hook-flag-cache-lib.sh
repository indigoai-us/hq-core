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
  [ -f "$FLAG_DIR/hq-anywhere-runtime-flag.cjs" ] || return 1
  value=$(node "$FLAG_DIR/hq-anywhere-runtime-flag.cjs" 2>/dev/null) || return 1
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
  # shellcheck disable=SC2034 # The sourcing hqd shim consumes this result.
  HQD_FLAG_ENABLED=false
fi
}
