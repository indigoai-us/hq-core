#!/usr/bin/env bash
# hq-core-source.sh — resolve the address HQ downloads hq-core releases from.
#
# One config value, HQ_CORE_SOURCE, holds a JSON object. Every key is optional;
# a missing key takes the GitHub default:
#
#   repo          indigoai-us/hq-core          release channel owner/name
#   stagingRepo   indigoai-us/hq-core-staging  staging channel owner/name
#   apiBase       https://api.github.com       ${apiBase}/repos/${repo}/...
#   codeloadBase  https://codeload.github.com  ${codeloadBase}/${repo}/tar.gz/${ref}
#   webBase       https://github.com           ${webBase}/${repo}.git
#
# Lookup order: the HQ_CORE_SOURCE env var, then ~/.hq/core-source.json (same
# JSON shape; HQ_CORE_SOURCE_FILE overrides the path), then the defaults.
# Invalid JSON or an invalid field prints one warning to stderr and uses the
# default for each bad field. Parsing uses jq, then node; with neither, an
# override is ignored with a warning. HQ_CORE_SOURCE_ENGINE=jq|node|none forces
# one engine (used by tests).
#
# GitHub credentials (gh, GH_TOKEN, GITHUB_TOKEN) are used only when the target
# host is api.github.com. Requests to any other host go out without
# credentials.
#
# Source it and call hq_core_source_load, or run it:
#   bash core/scripts/lib/hq-core-source.sh print
#   bash core/scripts/lib/hq-core-source.sh get <repo|stagingRepo|apiBase|codeloadBase|webBase>
#   bash core/scripts/lib/hq-core-source.sh core-yaml --ref <ref> [--staging | --source <owner/name>]
#
# Compatible with bash 3.2.

HQ_CORE_SOURCE_DEFAULT_REPO="indigoai-us/hq-core"
HQ_CORE_SOURCE_DEFAULT_STAGING_REPO="indigoai-us/hq-core-staging"
HQ_CORE_SOURCE_DEFAULT_API_BASE="https://api.github.com"
HQ_CORE_SOURCE_DEFAULT_CODELOAD_BASE="https://codeload.github.com"
HQ_CORE_SOURCE_DEFAULT_WEB_BASE="https://github.com"

hq_core_source__warn() {
  printf 'warning: %s\n' "$*" >&2
}

hq_core_source_valid_repo() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  case "$1" in .*|*/.*|*..*) return 1 ;; esac
  return 0
}

# Strip trailing slashes; prints the result.
hq_core_source__strip_slashes() {
  local v="$1"
  while [ "${v%/}" != "$v" ]; do v="${v%/}"; done
  printf '%s' "$v"
}

# https:// with a host, or http:// only for localhost / 127.0.0.1.
hq_core_source_valid_base() {
  local v="$1"
  [[ "$v" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/+-]*)?$ ]] && return 0
  [[ "$v" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]+)?(/[A-Za-z0-9._~%/+-]*)?$ ]] && return 0
  return 1
}

# Prints the host of a URL (no port). Callers compare it case-insensitively.
hq_core_source_host() {
  local rest="${1#*://}"
  rest="${rest%%/*}"
  rest="${rest%%:*}"
  printf '%s' "$rest"
}

# hq_core_source__host_in <url> <host>... : case-insensitive host match with
# no subprocess (the update check runs on SessionStart).
hq_core_source__host_in() {
  local host="${1#*://}" want rc=1 was_set=0
  host="${host%%/*}"
  host="${host%%:*}"
  shift
  if shopt -q nocasematch; then was_set=1; fi
  shopt -s nocasematch
  for want in "$@"; do
    if [[ "$host" == "$want" ]]; then rc=0; break; fi
  done
  [ "$was_set" -eq 1 ] || shopt -u nocasematch
  return "$rc"
}

hq_core_source_is_github_host() {
  hq_core_source__host_in "$1" github.com api.github.com codeload.github.com
}

# Parse JSON on stdin into five lines: repo, stagingRepo, apiBase,
# codeloadBase, webBase. A missing or null key prints an empty line; a value
# that is not a usable string prints "!invalid". Exit 2 means the input is not
# a JSON object; exit 3 means no parser is available.
hq_core_source__parse() {
  local engine="${HQ_CORE_SOURCE_ENGINE:-}" json
  json="$(cat)"
  if [ -z "$engine" ]; then
    if command -v jq >/dev/null 2>&1; then engine=jq
    elif command -v node >/dev/null 2>&1; then engine=node
    else engine=none
    fi
  fi
  case "$engine" in
    jq)
      # --slurp so trailing documents or empty input are rejected, as node does.
      printf '%s' "$json" | jq -rs '
        if length != 1 or (.[0] | type) != "object" then error("not one object") else .[0] end
        | [.repo, .stagingRepo, .apiBase, .codeloadBase, .webBase][]
        | if . == null then ""
          elif type == "string" and . != "" and (test("[[:cntrl:]]") | not) then .
          else "!invalid" end' 2>/dev/null || return 2
      ;;
    node)
      printf '%s' "$json" | node -e '
let s = "";
process.stdin.on("data", (c) => { s += c; });
process.stdin.on("end", () => {
  let d;
  try { d = JSON.parse(s); } catch (e) { process.exit(2); }
  if (d === null || typeof d !== "object" || Array.isArray(d)) process.exit(2);
  for (const k of ["repo", "stagingRepo", "apiBase", "codeloadBase", "webBase"]) {
    const v = d[k];
    if (v === undefined || v === null) console.log("");
    else if (typeof v === "string" && v !== "" && !/[\u0000-\u001f]/.test(v)) console.log(v);
    else console.log("!invalid");
  }
});
' 2>/dev/null || return 2
      ;;
    *) return 3 ;;
  esac
  return 0
}

# Sets HQ_CORE_SOURCE_REPO, HQ_CORE_SOURCE_STAGING_REPO, HQ_CORE_SOURCE_API_BASE,
# HQ_CORE_SOURCE_CODELOAD_BASE and HQ_CORE_SOURCE_WEB_BASE. Always returns 0.
hq_core_source_load() {
  HQ_CORE_SOURCE_REPO="$HQ_CORE_SOURCE_DEFAULT_REPO"
  HQ_CORE_SOURCE_STAGING_REPO="$HQ_CORE_SOURCE_DEFAULT_STAGING_REPO"
  HQ_CORE_SOURCE_API_BASE="$HQ_CORE_SOURCE_DEFAULT_API_BASE"
  HQ_CORE_SOURCE_CODELOAD_BASE="$HQ_CORE_SOURCE_DEFAULT_CODELOAD_BASE"
  HQ_CORE_SOURCE_WEB_BASE="$HQ_CORE_SOURCE_DEFAULT_WEB_BASE"

  local raw="" label="HQ_CORE_SOURCE" file=""
  if [ -n "${HQ_CORE_SOURCE:-}" ]; then
    raw="$HQ_CORE_SOURCE"
  else
    if [ -n "${HQ_CORE_SOURCE_FILE:-}" ]; then
      file="$HQ_CORE_SOURCE_FILE"
    elif [ -n "${HOME:-}" ]; then
      file="$HOME/.hq/core-source.json"
    fi
    if [ -n "$file" ] && [ -f "$file" ]; then
      raw="$(cat "$file" 2>/dev/null)" || raw=""
      label="HQ_CORE_SOURCE (from ~/.hq/core-source.json)"
      [ -z "${HQ_CORE_SOURCE_FILE:-}" ] || label="HQ_CORE_SOURCE (from $file)"
      # An empty file means no override.
      [[ "$raw" =~ [^[:space:]] ]] || return 0
    fi
  fi
  [ -n "$raw" ] || return 0

  local parsed rc=0
  parsed="$(printf '%s' "$raw" | hq_core_source__parse)" || rc=$?
  if [ "$rc" -eq 3 ]; then
    hq_core_source__warn "$label is set but no JSON parser (jq or node) is available; using the GitHub defaults"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    hq_core_source__warn "$label is not a valid JSON object; using the GitHub defaults"
    return 0
  fi

  local repo="" staging="" api="" codeload="" web="" bad=""
  # Command substitution drops trailing empty lines, so a read can hit EOF on
  # a partial override; || true keeps set -e callers alive.
  { IFS= read -r repo || true; IFS= read -r staging || true; IFS= read -r api || true
    IFS= read -r codeload || true; IFS= read -r web || true; } <<EOF
$parsed
EOF

  if [ -n "$repo" ]; then
    if hq_core_source_valid_repo "$repo"; then HQ_CORE_SOURCE_REPO="$repo"; else bad="$bad repo"; fi
  fi
  if [ -n "$staging" ]; then
    if hq_core_source_valid_repo "$staging"; then HQ_CORE_SOURCE_STAGING_REPO="$staging"; else bad="$bad stagingRepo"; fi
  fi
  if [ -n "$api" ]; then
    api="$(hq_core_source__strip_slashes "$api")"
    if hq_core_source_valid_base "$api"; then HQ_CORE_SOURCE_API_BASE="$api"; else bad="$bad apiBase"; fi
  fi
  if [ -n "$codeload" ]; then
    codeload="$(hq_core_source__strip_slashes "$codeload")"
    if hq_core_source_valid_base "$codeload"; then HQ_CORE_SOURCE_CODELOAD_BASE="$codeload"; else bad="$bad codeloadBase"; fi
  fi
  if [ -n "$web" ]; then
    web="$(hq_core_source__strip_slashes "$web")"
    if hq_core_source_valid_base "$web"; then HQ_CORE_SOURCE_WEB_BASE="$web"; else bad="$bad webBase"; fi
  fi
  if [ -n "$bad" ]; then
    hq_core_source__warn "$label has invalid field(s):$bad; using the GitHub default for each"
  fi
  return 0
}

# True when API calls go to api.github.com, so gh and its login may be used.
hq_core_source_api_is_github() {
  hq_core_source__host_in "${HQ_CORE_SOURCE_API_BASE:-$HQ_CORE_SOURCE_DEFAULT_API_BASE}" api.github.com
}

# GET ${apiBase}/<path>. On api.github.com this uses `gh api` (with the user's
# gh login); on any other host it uses curl with no credentials and with the
# GitHub token variables removed from its environment. Optional second
# argument: an Accept header value.
hq_core_source_api_get() {
  local path="${1#/}" accept="${2:-}"
  if hq_core_source_api_is_github; then
    if [ -n "$accept" ]; then
      gh api -H "Accept: $accept" "$path"
    else
      gh api "$path"
    fi
    return $?
  fi
  command -v curl >/dev/null 2>&1 || { hq_core_source__warn "curl is required to reach ${HQ_CORE_SOURCE_API_BASE}"; return 1; }
  # -q first: ignore ~/.curlrc so no user default headers reach this host.
  local -a args=(-q -fsSL --max-time "${HQ_CORE_SOURCE_CURL_TIMEOUT:-20}")
  [ -z "$accept" ] || args+=(-H "Accept: $accept")
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
    curl "${args[@]}" "${HQ_CORE_SOURCE_API_BASE}/${path}"
}

hq_core_source__cli() {
  local cmd="${1:-print}"
  [ $# -eq 0 ] || shift
  hq_core_source_load
  case "$cmd" in
    print)
      printf 'repo=%s\nstagingRepo=%s\napiBase=%s\ncodeloadBase=%s\nwebBase=%s\n' \
        "$HQ_CORE_SOURCE_REPO" "$HQ_CORE_SOURCE_STAGING_REPO" "$HQ_CORE_SOURCE_API_BASE" \
        "$HQ_CORE_SOURCE_CODELOAD_BASE" "$HQ_CORE_SOURCE_WEB_BASE"
      ;;
    get)
      case "${1:-}" in
        repo) printf '%s\n' "$HQ_CORE_SOURCE_REPO" ;;
        stagingRepo) printf '%s\n' "$HQ_CORE_SOURCE_STAGING_REPO" ;;
        apiBase) printf '%s\n' "$HQ_CORE_SOURCE_API_BASE" ;;
        codeloadBase) printf '%s\n' "$HQ_CORE_SOURCE_CODELOAD_BASE" ;;
        webBase) printf '%s\n' "$HQ_CORE_SOURCE_WEB_BASE" ;;
        *) printf 'usage: hq-core-source.sh get <repo|stagingRepo|apiBase|codeloadBase|webBase>\n' >&2; return 2 ;;
      esac
      ;;
    core-yaml)
      # Print core/core.yaml from the release source at a ref.
      local ref="" repo="$HQ_CORE_SOURCE_REPO"
      while [ $# -gt 0 ]; do
        case "$1" in
          --ref) ref="${2:-}"; shift; [ $# -eq 0 ] || shift ;;
          --staging) repo="$HQ_CORE_SOURCE_STAGING_REPO"; shift ;;
          --source) repo="${2:-}"; shift; [ $# -eq 0 ] || shift ;;
          *) printf 'hq-core-source.sh core-yaml: unknown argument: %s\n' "$1" >&2; return 2 ;;
        esac
      done
      hq_core_source_valid_repo "$repo" || { printf 'hq-core-source.sh core-yaml: invalid repo: %s\n' "$repo" >&2; return 2; }
      [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] || { printf 'hq-core-source.sh core-yaml: --ref <tag|branch|sha> is required\n' >&2; return 2; }
      hq_core_source_api_get "repos/${repo}/contents/core/core.yaml?ref=${ref}" "application/vnd.github.raw+json"
      ;;
    *)
      printf 'usage: hq-core-source.sh <print|get <key>|core-yaml --ref <ref> [--staging|--source <owner/name>]>\n' >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  hq_core_source__cli "$@"
  exit $?
fi
