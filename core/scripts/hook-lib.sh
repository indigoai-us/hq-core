#!/bin/bash
# hook-lib.sh — shared, python-free primitives for HQ hooks and scripts.
#
# SOURCED, never executed:  . "$HELPERS/hook-lib.sh"
# bash 3.2 safe; no heredocs nested inside $( ) (hooks-heredoc-syntax lint).
#
# HQ hooks must run on machines WITHOUT python3 — including Windows, where the
# Store alias stub resolves on PATH but cannot execute anything (so a bare
# `command -v python3` is not a usable capability probe). These primitives
# replace every inline `python3 -c` snippet the hooks used to carry.
#
# Engine order (locked 2026-07-15, Shahzaib):
#   - Hot-path primitives (hq_json_get / hq_json_encode / hq_normpath):
#     jq FIRST — jq ships with the HQ toolchain, is already a hard requirement
#     of the policy-trigger pipeline, and spawns fastest — then node (HQ is
#     npm-installed, so node exists on every HQ machine), else degrade to ""
#     so callers keep their existing fail-open behavior.
#   - Complex analyzers stay in their own hooks but follow node-first with an
#     awk fallback (see validate-policy-frontmatter.sh).
#
# Test override: HQ_HOOK_ENGINE=jq|node forces a single engine so parity
# suites can drive both implementations over the same payloads.

HQ_LIB_JQ="$(command -v jq 2>/dev/null || true)"
HQ_LIB_NODE="$(command -v node 2>/dev/null || true)"
case "${HQ_HOOK_ENGINE:-}" in
  jq)   HQ_LIB_NODE="" ;;
  node) HQ_LIB_JQ="" ;;
esac

# hq_json_get <dotted.key.path>
#   stdin: JSON document. stdout: the addressed value, or "" when the path is
#   missing, null, or resolves to an object/array. Numeric path segments index
#   arrays ("tool_input.edits.0.old_string").
hq_json_get() {
  if [ -n "$HQ_LIB_JQ" ]; then
    "$HQ_LIB_JQ" -r --arg p "$1" '
      try (getpath($p | split(".") | map(if test("^[0-9]+$") then tonumber else . end))
        | if . == null or type == "object" or type == "array" then "" else tostring end)
      catch ""' 2>/dev/null || echo ""
    return 0
  fi
  if [ -n "$HQ_LIB_NODE" ]; then
    "$HQ_LIB_NODE" -e '
      let d = "";
      process.stdin.on("data", c => d += c).on("end", () => {
        let v;
        try { v = JSON.parse(d); } catch (e) { console.log(""); return; }
        for (const k of process.argv[1].split(".")) {
          if (v && typeof v === "object") v = Array.isArray(v) ? v[Number(k)] : v[k];
          else { v = undefined; break; }
        }
        if (v === undefined || v === null || typeof v === "object") console.log("");
        else console.log(String(v));
      });' "$1" 2>/dev/null || echo ""
    return 0
  fi
  cat >/dev/null 2>&1 || true
  echo ""
}

# hq_json_encode
#   stdin: raw string. stdout: the string as a JSON literal (quoted, escaped).
hq_json_encode() {
  if [ -n "$HQ_LIB_JQ" ]; then
    "$HQ_LIB_JQ" -Rs . 2>/dev/null || echo '""'
    return 0
  fi
  if [ -n "$HQ_LIB_NODE" ]; then
    "$HQ_LIB_NODE" -e '
      let d = "";
      process.stdin.on("data", c => d += c).on("end", () => console.log(JSON.stringify(d)));' \
      2>/dev/null || echo '""'
    return 0
  fi
  cat >/dev/null 2>&1 || true
  echo '""'
}

# hq_normpath <path>
#   Lexical normalization (no filesystem access): backslashes -> "/", collapse
#   "//" and "/./", resolve "x/..", trim trailing "/" (keeps root). Both
#   engines produce IDENTICAL output, so equality checks between two
#   hq_normpath results are stable regardless of engine or platform.
hq_normpath() {
  printf '%s' "$1" | awk '
    {
      p = $0
      gsub(/\\/, "/", p)
      isabs = (p ~ /^\//) ? 1 : 0
      drive = ""
      if (p ~ /^[A-Za-z]:/) { drive = substr(p, 1, 2); p = substr(p, 3); isabs = (p ~ /^\//) ? 1 : 0 }
      n = split(p, seg, "/")
      out_n = 0
      for (i = 1; i <= n; i++) {
        s = seg[i]
        if (s == "" || s == ".") continue
        if (s == "..") {
          if (out_n > 0 && out[out_n] != "..") { out_n--; continue }
          if (isabs) continue
          out[++out_n] = ".."
        } else out[++out_n] = s
      }
      r = ""
      for (i = 1; i <= out_n; i++) r = r (i > 1 ? "/" : "") out[i]
      if (isabs) r = "/" r
      if (drive != "") r = drive r
      if (r == "") r = (isabs ? "/" : ".")
      print r
    }'
}

hq_text_compact() {
  local max="${1:-240}"
  local text="$2"
  text="$(printf '%s' "$text" | tr '\r\n' '  ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')"
  if [ "${#text}" -gt "$max" ]; then
    printf '%s...' "${text:0:$((max - 3))}"
  else
    printf '%s' "$text"
  fi
}

hq_hook_safe_session_key() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '_')"
  raw="${raw#_}"
  raw="${raw%_}"
  if [ -z "$raw" ]; then
    raw="session-${PPID:-$$}"
  fi
  if [ "${#raw}" -gt 96 ]; then
    raw="${raw:0:96}"
  fi
  printf '%s' "$raw"
}

hq_hook_session_key_from_payload() {
  local payload="$1"
  local key="${HQ_HOOK_SESSION_ID:-}"
  if [ -z "$key" ]; then
    key="$(printf '%s' "$payload" | hq_json_get 'session_id')"
  fi
  if [ -z "$key" ]; then
    key="$(printf '%s' "$payload" | hq_json_get 'sessionId')"
  fi
  if [ -z "$key" ]; then
    key="$(printf '%s' "$payload" | hq_json_get 'conversation_id')"
  fi
  if [ -z "$key" ]; then
    key="$(printf '%s' "$payload" | hq_json_get 'conversationId')"
  fi
  if [ -z "$key" ]; then
    key="$(printf '%s' "$payload" | hq_json_get 'thread_id')"
  fi
  if [ -z "$key" ]; then
    key="$(printf '%s' "$payload" | hq_json_get 'threadId')"
  fi
  if [ -z "$key" ]; then
    key="$(printf '%s' "$payload" | hq_json_get 'tool_input.session_id')"
  fi
  hq_hook_safe_session_key "$key"
}

hq_path_within_root() {
  local root="$1"
  local path="$2"
  local root_norm path_norm
  [ -n "$root" ] || return 1
  [ -n "$path" ] || return 1
  # Never chmod through a symlink that may resolve outside HQ_ROOT.
  [ -L "$path" ] && return 1
  root_norm="$(hq_normpath "$root")"
  path_norm="$(hq_normpath "$path")"
  case "$path_norm" in
    "$root_norm"|"$root_norm"/*) return 0 ;;
  esac
  return 1
}

hq_path_label() {
  local root="$1"
  local path="$2"
  local root_norm path_norm
  [ -n "$path" ] || return 0
  root_norm="$(hq_normpath "$root")"
  path_norm="$(hq_normpath "$path")"
  case "$path_norm" in
    "$root_norm")
      printf '.'
      return 0
      ;;
    "$root_norm"/*)
      printf '%s' "${path_norm#"$root_norm"/}"
      return 0
      ;;
  esac
  case "$path" in
    */*) printf '%s' "${path##*/}" ;;
    *) printf '%s' "$path" ;;
  esac
}

hq_hook_repair_command() {
  local root="$1"
  local path="$2"
  local rel
  if ! hq_path_within_root "$root" "$path"; then
    return 0
  fi
  rel="$(hq_path_label "$root" "$path")"
  [ -n "$rel" ] || return 0
  printf 'chmod u+x "$HQ_ROOT/%s"' "$rel"
}

hq_hook_warning_cache_path() {
  local root="$1"
  local session_key="$2"
  local cache_dir
  [ -n "$root" ] || return 1
  cache_dir="$root/workspace/.hook-launch-warnings"
  mkdir -p "$cache_dir" 2>/dev/null || return 1
  printf '%s/%s.keys' "$cache_dir" "$session_key"
}

hq_hook_warning_once() {
  local root="$1"
  local session_key="$2"
  local dedupe_key="$3"
  local cache_path
  cache_path="$(hq_hook_warning_cache_path "$root" "$session_key")" || return 0
  if grep -Fqx "$dedupe_key" "$cache_path" 2>/dev/null; then
    return 1
  fi
  printf '%s\n' "$dedupe_key" >>"$cache_path" 2>/dev/null || true
  return 0
}

hq_hook_launch_warning_text() {
  local payload="$1"
  local root="$2"
  local mode="$3"
  local kind="$4"
  local label="$5"
  local path="$6"
  local cause="$7"
  local session_key rel repair dedupe_key msg

  session_key="$(hq_hook_session_key_from_payload "$payload")"
  rel="$(hq_path_label "$root" "$path")"
  repair="$(hq_hook_repair_command "$root" "$path")"
  dedupe_key="$(hq_text_compact 240 "$mode|$kind|$label|$rel|$cause")"
  if ! hq_hook_warning_once "$root" "$session_key" "$dedupe_key"; then
    return 0
  fi

  msg="WARNING: HQ ${mode} ${kind} launch failed for ${label}"
  if [ -n "$rel" ]; then
    msg="${msg} (${rel})"
  fi
  msg="${msg}: ${cause}."
  if [ -n "$repair" ]; then
    msg="${msg} Repair: ${repair}"
  fi
  printf '%s' "$(hq_text_compact 420 "$msg")"
}

HQ_HOOK_LAST_STATUS=0
HQ_HOOK_LAST_CAUSE=""

hq_launch_shell_path() {
  local root="$1"
  local path="$2"
  local payload="$3"
  shift 3

  HQ_HOOK_LAST_STATUS=0
  HQ_HOOK_LAST_CAUSE=""

  if [ ! -f "$path" ]; then
    HQ_HOOK_LAST_STATUS=127
    if hq_path_within_root "$root" "$path"; then
      HQ_HOOK_LAST_CAUSE="file is missing under HQ_ROOT"
    else
      HQ_HOOK_LAST_CAUSE="file is missing"
    fi
    return 127
  fi

  if [ ! -x "$path" ] && hq_path_within_root "$root" "$path"; then
    chmod u+x "$path" 2>/dev/null || true
  fi

  if [ -x "$path" ]; then
    printf '%s' "$payload" | "$path" "$@"
    HQ_HOOK_LAST_STATUS=$?
    return "$HQ_HOOK_LAST_STATUS"
  fi

  local bash_bin="${BASH:-}"
  if [ -z "$bash_bin" ] || [ ! -x "$bash_bin" ]; then
    bash_bin="$(command -v bash 2>/dev/null || true)"
  fi
  if [ -r "$path" ] && [ -n "$bash_bin" ]; then
    printf '%s' "$payload" | "$bash_bin" "$path" "$@"
    HQ_HOOK_LAST_STATUS=$?
    return "$HQ_HOOK_LAST_STATUS"
  fi

  if [ ! -r "$path" ]; then
    if hq_path_within_root "$root" "$path"; then
      HQ_HOOK_LAST_CAUSE="chmod u+x could not repair the file and bash could not read it"
    else
      HQ_HOOK_LAST_CAUSE="file is not executable or readable"
    fi
    HQ_HOOK_LAST_STATUS=126
    return 126
  fi

  HQ_HOOK_LAST_STATUS=127
  # shellcheck disable=SC2034 # Read by adapters after this sourced function returns.
  HQ_HOOK_LAST_CAUSE="bash is unavailable for the readable shell fallback"
  return 127
}
