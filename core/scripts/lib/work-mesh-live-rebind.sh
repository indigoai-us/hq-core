#!/usr/bin/env bash
# hq-core: public
# US-011 — mid-session rebind: session_end (old) + session_start (new) in spool.
# Sourced by hooks/scripts. Never execute directly.

# work_mesh_live_binding_marker_path <sid>
work_mesh_live_binding_marker_path() {
  printf '%s/.hq/work-context/sessions/%s.live-binding' "${WORK_MESH_HOME:-$HOME}" "$1"
}

# work_mesh_live_read_binding_marker <sid>
#   Sets REPLY to "company|project|task" (may be empty fields).
work_mesh_live_read_binding_marker() {
  local sid="$1" path body
  path="$(work_mesh_live_binding_marker_path "$sid")"
  REPLY="||"
  [ -f "$path" ] || return 0
  body="$(tr -d '\r' <"$path" 2>/dev/null || true)"
  # companySlug=.. project=.. task=..
  local co="" pr="" tk=""
  co="$(printf '%s\n' "$body" | awk -F= '/^companySlug=/{print $2; exit}')"
  pr="$(printf '%s\n' "$body" | awk -F= '/^project=/{print $2; exit}')"
  tk="$(printf '%s\n' "$body" | awk -F= '/^task=/{print $2; exit}')"
  REPLY="${co}|${pr}|${tk}"
}

# work_mesh_live_write_binding_marker <sid> <company> <project> <task>
work_mesh_live_write_binding_marker() {
  local sid="$1" co="${2:-}" pr="${3:-}" tk="${4:-}" path dir
  path="$(work_mesh_live_binding_marker_path "$sid")"
  dir="${path%/*}"
  mkdir -p -- "$dir" 2>/dev/null || true
  chmod 700 -- "$dir" 2>/dev/null || true
  printf 'companySlug=%s\nproject=%s\ntask=%s\n' "$co" "$pr" "$tk" >"$path"
  chmod 600 -- "$path" 2>/dev/null || true
}

# work_mesh_live_enqueue_lifecycle <kind> <sid> <harness> <adapter> <company> <project> <task>
work_mesh_live_enqueue_lifecycle() {
  local kind="$1" sid="$2" harness="$3" adapter="$4"
  local company="${5:-}" project="${6:-}" task="${7:-}"
  local seq
  if ! command -v work_mesh_enqueue >/dev/null 2>&1; then
    return 1
  fi
  if command -v work_mesh_live_next_seq >/dev/null 2>&1; then
    seq="$(work_mesh_live_next_seq "$sid")" || return 1
  else
    seq=1
  fi
  local args=(
    --kind "$kind"
    --session-id "$sid"
    --harness "$harness"
    --adapter-version "$adapter"
    --seq "$seq"
    --cwd "${PWD:-}"
    --hq-root "${HQ_ROOT:-}"
  )
  [ -n "$company" ] && args+=(--company-slug "$company")
  [ -n "$project" ] && args+=(--project "$project")
  [ -n "$task" ] && args+=(--task "$task")
  work_mesh_enqueue "${args[@]}" || true
}

# work_mesh_live_rebind <sid> <old_co> <old_pr> <old_tk> <new_co> <new_pr> <new_tk>
#   Always appends session_end then session_start when old project differs from new
#   and new project is non-empty. Updates the live-binding marker to the new binding.
work_mesh_live_rebind() {
  local sid="$1"
  local old_co="${2:-}" old_pr="${3:-}" old_tk="${4:-}"
  local new_co="${5:-}" new_pr="${6:-}" new_tk="${7:-}"
  local harness adapter
  [ -n "$sid" ] || return 1
  [ -n "$new_pr" ] || return 1
  [ "$old_pr" != "$new_pr" ] || {
    work_mesh_live_write_binding_marker "$sid" "$new_co" "$new_pr" "$new_tk"
    return 0
  }

  harness="${HQ_HARNESS:-${HQ_WORK_MESH_HARNESS:-${HQ_CHECKPOINT_RUNTIME:-claude-code}}}"
  case "$harness" in
    claude|Claude|ClaudeCode) harness=claude-code ;;
    Codex) harness=codex ;;
    Grok) harness=grok ;;
  esac
  adapter="${HQ_ADAPTER_CONTRACT_VERSION:-1.0.0}"

  # Event order: session_end then session_start. Each call takes the next seq from
  # the same per-session counter, so session_start always has a strictly higher
  # seq than session_end. The server REOPENs a session when a session_start with
  # a higher seq and a new binding follows the session_end.
  if [ -n "$old_pr" ]; then
    work_mesh_live_enqueue_lifecycle session_end "$sid" "$harness" "$adapter" \
      "$old_co" "$old_pr" "$old_tk"
  fi
  work_mesh_live_enqueue_lifecycle session_start "$sid" "$harness" "$adapter" \
    "$new_co" "$new_pr" "$new_tk"
  work_mesh_live_write_binding_marker "$sid" "$new_co" "$new_pr" "$new_tk"
  return 0
}

# work_mesh_live_maybe_rebind_from_state <sid>
#   Compare state file projectId to live-binding marker; rebind if changed.
work_mesh_live_maybe_rebind_from_state() {
  local sid="$1" state co pr tk old old_co old_pr old_tk
  local wc="${WORK_MESH_HOME:-$HOME}"
  state="$wc/.hq/work-context/sessions/$sid.json"
  [ -f "$state" ] || return 0

  if command -v jq >/dev/null 2>&1; then
    co="$(jq -r '.companySlug // empty' "$state" 2>/dev/null || true)"
    pr="$(jq -r '.projectId // empty' "$state" 2>/dev/null || true)"
    tk="$(jq -r '.taskId // empty' "$state" 2>/dev/null || true)"
  else
    return 0
  fi
  [ -n "$pr" ] || return 0

  work_mesh_live_read_binding_marker "$sid"
  old=$REPLY
  old_co="${old%%|*}"
  rest="${old#*|}"
  old_pr="${rest%%|*}"
  old_tk="${rest#*|}"

  if [ -z "$old_pr" ]; then
    # First bind observed — record marker without closing a card (session_start
    # already fired at SessionStart). Still emit session_start when marker empty
    # but only if organize rebound after an unbound start: treat empty old as
    # "no prior card" and only update marker unless caller forces rebind.
    work_mesh_live_write_binding_marker "$sid" "$co" "$pr" "$tk"
    return 0
  fi
  if [ "$old_pr" = "$pr" ]; then
    # Same project — refresh task/company on marker.
    work_mesh_live_write_binding_marker "$sid" "$co" "$pr" "$tk"
    return 0
  fi
  work_mesh_live_rebind "$sid" "$old_co" "$old_pr" "$old_tk" "$co" "$pr" "$tk"
}
