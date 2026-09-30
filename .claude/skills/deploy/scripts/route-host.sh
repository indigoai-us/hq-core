#!/usr/bin/env bash
# route-host.sh — reuse an existing static deploy by adding the new artifact as
# a route (sub-path) on it instead of creating a new app.
#
# hq-deploy static completion replaces every live file of an app, so adding a
# route means re-uploading the host's current site with the new artifact placed
# under /<route>/. hq-deploy has no API to download a live site, so this script
# keeps a local snapshot of every static site /deploy publishes and merges
# against that snapshot.
#
# Subcommands (each prints exactly one JSON line on stdout):
#   hosts [--org <slug>|-]
#       List recorded hosts, optionally for one org ("-" = personal scope).
#       -> {"hosts":[{key,org,subdomain,appId,accessMode,deployId,site,siteExists,routes,updatedAt}]}
#   merge <host_site_dir> <artifact_dir> <route> <out_dir> [--replace]
#       Copy the host site into <out_dir> and place the artifact at <out_dir>/<route>/.
#       -> {"ok":true,"out_dir":...,"route":"/r/","replaced":bool,"file_count":N,"routes":[...]}
#       -> {"ok":false,"reason":"invalid_route|route_exists|route_blocked|no_index|
#            root_absolute_paths|host_missing|artifact_missing|out_not_empty|copy_failed",...}
#   record --org <slug|-> --subdomain <s> --app-id <id> --access-mode <m> --deploy-id <id>
#          (--tarball <path.tar.gz> | --site <dir>)
#       Snapshot the site that just went live and update the registry. Prefer
#       --tarball: it is byte-for-byte what was uploaded.
#       -> {"ok":true,"key":...,"site":...,"routes":[...]}
#
# Storage (overridable for tests):
#   HQ_DEPLOY_ROUTES_FILE  registry JSON   (default ~/.hq/deploy-routes.json, mode 0600)
#   HQ_DEPLOY_HOSTS_DIR    site snapshots  (default ~/.hq/deploy-hosts, mode 0700)
#
# `record` (snapshot + registry) and `merge` (snapshot read) run under one
# exclusive lock, a directory next to the registry, so concurrent deploys can
# neither drop each other's registry entries nor pair one deploy's files with
# another deploy's deployId. mkdir is atomic on every platform, including
# macOS, which has no Linux file-lock command.
#
# Never prints JWTs or artifact contents.

set -euo pipefail

ROUTES_FILE="${HQ_DEPLOY_ROUTES_FILE:-$HOME/.hq/deploy-routes.json}"
HOSTS_DIR="${HQ_DEPLOY_HOSTS_DIR:-$HOME/.hq/deploy-hosts}"
LOCK_DIR="${ROUTES_FILE}.lock"
LOCK_WAIT_TENTHS="${HQ_DEPLOY_ROUTES_LOCK_WAIT_TENTHS:-300}"
LOCK_HELD=false

if ! command -v jq >/dev/null 2>&1; then
  printf '{"ok":false,"reason":"missing_dependency","dep":"jq"}\n'
  exit 0
fi

fail_json() {
  local reason="$1"
  shift
  jq -cn --arg reason "$reason" --arg detail "${1:-}" \
    '{ok:false,reason:$reason} + (if $detail != "" then {detail:$detail} else {} end)'
  exit 0
}

release_lock() {
  if [ "$LOCK_HELD" = "true" ]; then
    rm -rf "$LOCK_DIR"
    LOCK_HELD=false
  fi
}

# Take the exclusive lock, waiting up to LOCK_WAIT_TENTHS tenths of a second.
# A lock whose owner pid is gone is stale and is broken.
acquire_lock() {
  local tries=0 owner
  mkdir -p "$(dirname "$LOCK_DIR")"
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    owner="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$LOCK_DIR"
      continue
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge "$LOCK_WAIT_TENTHS" ]; then
      fail_json lock_timeout "$LOCK_DIR"
    fi
    sleep 0.1
  done
  LOCK_HELD=true
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  trap release_lock EXIT
}

# Emit the URL paths ("/", "/a/", "/a/b/") of every directory in $1 that has an
# index.html, sorted, as a JSON array.
list_routes() {
  local dir="$1"
  (cd "$dir" && find . -type f -name index.html) \
    | sed -e 's#^\.##' -e 's#index\.html$##' \
    | LC_ALL=C sort \
    | jq -Rsc 'split("\n") | map(select(. != "")) | unique'
}

count_files() {
  (cd "$1" && find . -type f | wc -l | tr -d ' ')
}

normalize_route() {
  local r="$1"
  while [ "${r#/}" != "$r" ]; do r="${r#/}"; done
  while [ "${r%/}" != "$r" ]; do r="${r%/}"; done
  printf '%s' "$r"
}

valid_route() {
  local r="$1" seg first
  [ -n "$r" ] || return 1
  printf '%s' "$r" | grep -Eq '^[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)*$' || return 1
  first="${r%%/*}"
  # api/ is the app backend mount; everything else reserved starts with "_".
  [ "$first" != "api" ] || return 1
  local IFS='/'
  for seg in $r; do
    case "$seg" in
      ..|.) return 1 ;;
    esac
  done
  return 0
}

cmd_merge() {
  local host="${1:-}" art="${2:-}" raw_route="${3:-}" out="${4:-}" replace=false
  [ "${5:-}" = "--replace" ] && replace=true
  [ -n "$host" ] && [ -d "$host" ] || fail_json host_missing "$host"
  [ -n "$art" ] && [ -d "$art" ] || fail_json artifact_missing "$art"
  [ -n "$out" ] || fail_json out_not_empty "no out_dir given"

  local route
  route="$(normalize_route "$raw_route")"
  valid_route "$route" || fail_json invalid_route "$raw_route"

  [ -f "$art/index.html" ] || fail_json no_index "artifact has no index.html"

  # A page served under /<route>/ cannot use root-absolute asset or link paths
  # ("/app.js", "/style.css"): they resolve against the host root, not the route.
  local abs_hits
  # Case-insensitive; tolerates whitespace around "=" and inside url( ).
  local abs_re
  abs_re="(src|href|action|poster)[[:space:]]*=[[:space:]]*[\"']?[[:space:]]*/[^/\"'[:space:]>]"
  abs_re="$abs_re|url\\([[:space:]]*[\"']?[[:space:]]*/[^/\"')[:space:]]"
  abs_hits="$({ grep -rEil --include='*.html' --include='*.htm' --include='*.css' \
    "$abs_re" "$art" 2>/dev/null || true; } | wc -l | tr -d ' ')"
  if [ "${abs_hits:-0}" != "0" ]; then
    fail_json root_absolute_paths "$abs_hits file(s) use root-absolute paths"
  fi

  # Walk the route's parent segments: a file where a directory must go blocks it.
  local prefix="" seg
  local IFS='/'
  for seg in $route; do
    prefix="${prefix:+$prefix/}$seg"
    if [ -e "$host/$prefix" ] && [ ! -d "$host/$prefix" ]; then
      unset IFS
      fail_json route_blocked "/$prefix is a file on the host"
    fi
  done
  unset IFS

  local replaced=false
  if [ -d "$host/$route" ]; then
    [ "$replace" = "true" ] || fail_json route_exists "/$route/"
    replaced=true
  fi

  if [ -e "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
    fail_json out_not_empty "$out"
  fi
  mkdir -p "$out"

  acquire_lock
  if ! cp -R "$host/." "$out/" 2>/dev/null; then
    fail_json copy_failed "host copy"
  fi
  release_lock
  rm -rf "${out:?}/$route"
  mkdir -p "$out/$route"
  if ! cp -R "$art/." "$out/$route/" 2>/dev/null; then
    fail_json copy_failed "artifact copy"
  fi

  local routes files
  routes="$(list_routes "$out")"
  files="$(count_files "$out")"
  jq -cn --arg out "$out" --arg route "/$route/" --argjson replaced "$replaced" \
    --argjson files "$files" --argjson routes "$routes" \
    '{ok:true,out_dir:$out,route:$route,replaced:$replaced,file_count:$files,routes:$routes}'
}

host_key() {
  local org="$1" sub="$2"
  if [ "$org" = "-" ] || [ -z "$org" ]; then org="_personal"; fi
  printf '%s/%s' "$org" "$sub"
}

safe_segment() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9._-]*$'
}

cmd_record() {
  local org="" sub="" app_id="" mode="" deploy_id="" site="" tarball=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --org) org="${2:-}"; shift 2 ;;
      --subdomain) sub="${2:-}"; shift 2 ;;
      --app-id) app_id="${2:-}"; shift 2 ;;
      --access-mode) mode="${2:-}"; shift 2 ;;
      --deploy-id) deploy_id="${2:-}"; shift 2 ;;
      --site) site="${2:-}"; shift 2 ;;
      --tarball) tarball="${2:-}"; shift 2 ;;
      *) fail_json bad_argument "$1" ;;
    esac
  done
  if [ -z "$sub" ] || [ -z "$app_id" ] || { [ -z "$site" ] && [ -z "$tarball" ]; }; then
    fail_json bad_argument "subdomain, app-id and one of site or tarball are required"
  fi
  if [ -n "$tarball" ]; then
    [ -f "$tarball" ] || fail_json host_missing "$tarball"
  else
    [ -d "$site" ] || fail_json host_missing "$site"
  fi
  if [ "$org" != "-" ] && [ -n "$org" ] && ! safe_segment "$org"; then
    fail_json bad_argument "unsafe org"
  fi
  safe_segment "$sub" || fail_json bad_argument "unsafe subdomain"
  local key org_dir
  key="$(host_key "$org" "$sub")"
  org_dir="${key%%/*}"

  acquire_lock
  mkdir -p "$HOSTS_DIR/$org_dir"
  chmod 0700 "$HOSTS_DIR" 2>/dev/null || true
  local dest="$HOSTS_DIR/$org_dir/$sub"
  local tmp="$HOSTS_DIR/$org_dir/.$sub.tmp.$$"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  if [ -n "$tarball" ]; then
    if ! tar -xzf "$tarball" -C "$tmp" 2>/dev/null; then
      rm -rf "$tmp"
      fail_json copy_failed "snapshot extract"
    fi
  elif ! cp -R "$site/." "$tmp/" 2>/dev/null; then
    rm -rf "$tmp"
    fail_json copy_failed "snapshot"
  fi
  rm -rf "$dest"
  mv "$tmp" "$dest"

  local routes now
  routes="$(list_routes "$dest")"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$ROUTES_FILE")"
  [ -f "$ROUTES_FILE" ] || printf '{"version":1,"hosts":{}}\n' > "$ROUTES_FILE"
  chmod 0600 "$ROUTES_FILE" 2>/dev/null || true
  local reg_tmp="${ROUTES_FILE}.tmp.$$"
  jq --arg key "$key" --arg org "${org_dir}" --arg sub "$sub" --arg app "$app_id" \
     --arg mode "${mode:-public}" --arg dep "$deploy_id" --arg site "$dest" \
     --arg now "$now" --argjson routes "$routes" \
     '.version = 1 | .hosts = (.hosts // {}) | .hosts[$key] = {
        org: $org, subdomain: $sub, appId: $app, accessMode: $mode,
        deployId: $dep, site: $site, routes: $routes, updatedAt: $now }' \
     "$ROUTES_FILE" > "$reg_tmp" && mv "$reg_tmp" "$ROUTES_FILE"
  chmod 0600 "$ROUTES_FILE" 2>/dev/null || true
  release_lock

  jq -cn --arg key "$key" --arg site "$dest" --argjson routes "$routes" \
    '{ok:true,key:$key,site:$site,routes:$routes}'
}

cmd_hosts() {
  local org_filter=""
  if [ "${1:-}" = "--org" ]; then
    org_filter="${2:-}"
    [ "$org_filter" = "-" ] && org_filter="_personal"
  fi
  if [ ! -f "$ROUTES_FILE" ]; then
    printf '{"hosts":[]}\n'
    return 0
  fi
  local out
  out="$(jq -c --arg org "$org_filter" \
    '{hosts: [(.hosts // {}) | to_entries[] | select($org == "" or .value.org == $org)
              | .value + {key: .key}]}' "$ROUTES_FILE" 2>/dev/null)" \
    || { printf '{"hosts":[],"error":"registry_unreadable"}\n'; return 0; }
  # Mark hosts whose snapshot directory disappeared: they cannot take routes.
  local site exists_list=""
  while IFS= read -r site; do
    if [ -n "$site" ] && [ -d "$site" ]; then exists_list="${exists_list}true
"; else exists_list="${exists_list}false
"; fi
  done < <(printf '%s' "$out" | jq -r '.hosts[].site')
  printf '%s' "$exists_list" | jq -Rsc --argjson doc "$out" \
    '(split("\n") | map(select(. != "")) | map(. == "true")) as $e
     | $doc | .hosts |= [ to_entries[] | .value + {siteExists: ($e[.key] // false)} ]'
}

case "${1:-}" in
  hosts) shift; cmd_hosts "$@" ;;
  merge) shift; cmd_merge "$@" ;;
  record) shift; cmd_record "$@" ;;
  *)
    printf 'usage: route-host.sh hosts|merge|record ...\n' >&2
    exit 2
    ;;
esac
