#!/usr/bin/env bash
# hq-core: public
# session-scope-capability.sh — mint/read workspace/sessions/<id>/scope-capability.json
#
# Sourced by core/scripts/hq-session.sh and .claude/hooks/mandatory-scope-authorizer.sh.
# Never execute directly.

# session_scope_identity_is_valid <identity>
#   Identities become path segments; accept only a conservative portable set.
session_scope_identity_is_valid() {
  local identity="${1:-}"
  [ -n "$identity" ] || return 1
  case "$identity" in
    .|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# session_scope_capability_path <root> <session_id> [agent_id]
#   Main thread retains the legacy path. A Task subagent gets a distinct path.
session_scope_capability_path() {
  local root="${1:-}" sid="${2:-}" aid="${3:-}"
  [ -n "$root" ] && session_scope_identity_is_valid "$sid" || return 1
  if [ -n "$aid" ]; then
    session_scope_identity_is_valid "$aid" || return 1
    printf '%s/workspace/sessions/%s/agents/%s/scope-capability.json' "$root" "$sid" "$aid"
  else
    printf '%s/workspace/sessions/%s/scope-capability.json' "$root" "$sid"
  fi
}

# session_scope_read <root> <session_id> [agent_id]
#   Print company_slug from the exact caller's capability, or empty if invalid.
session_scope_read() {
  local root="${1:-}" sid="${2:-}" aid="${3:-}" cap
  cap="$(session_scope_capability_path "$root" "$sid" "$aid")" || return 0
  [ -f "$cap" ] || return 0
  jq -r --arg sid "$sid" --arg aid "$aid" \
    'select(.session_id == $sid and (.agent_id // "") == $aid) | .company_slug // empty' \
    "$cap" 2>/dev/null || true
}

# session_scope_resolve_agent_company <root> <session_id> <agent_id> <session_company> <event>
#   Existing tuple bindings always win. Session metadata may bind a caller only
#   on SessionStart, when that agent has not been bound before.
session_scope_resolve_agent_company() {
  local root="${1:-}" sid="${2:-}" aid="${3:-}" session_company="${4:-}" event="${5:-}" bound_company=""
  bound_company="$(session_scope_read "$root" "$sid" "$aid")"
  if [ -n "$bound_company" ]; then
    printf '%s' "$bound_company"
  elif [ "$event" = "SessionStart" ]; then
    printf '%s' "$session_company"
  fi
}

# session_scope_mint <root> <session_id> <company_slug> [agent_id]
#   Write scope-capability.json for the exact caller. Main-thread writes retain
#   the legacy shape/path for one-restart compatibility.
session_scope_mint() {
  local root="${1:-}" sid="${2:-}" slug="${3:-}" aid="${4:-}"
  [ -n "$root" ] && session_scope_identity_is_valid "$sid" && [ -n "$slug" ] || return 1
  if [ -n "$aid" ]; then
    session_scope_identity_is_valid "$aid" || {
      echo "session-scope-capability: invalid agent_id" >&2
      return 1
    }
  fi

  case "$slug" in
    ''|*[!a-zA-Z0-9_-]*)
      echo "session-scope-capability: invalid company_slug: $slug" >&2
      return 1
      ;;
  esac

  local cap dir tmp minted_at
  cap="$(session_scope_capability_path "$root" "$sid" "$aid")" || return 1
  dir="$(dirname "$cap")"
  mkdir -p "$dir" || return 1

  minted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S'Z')"
  tmp="$(mktemp)"
  jq -n \
    --arg sid "$sid" \
    --arg aid "$aid" \
    --arg slug "$slug" \
    --arg minted_at "$minted_at" \
    '{session_id: $sid, company_slug: $slug, minted_at: $minted_at} + (if $aid == "" then {} else {agent_id: $aid} end)' >"$tmp" \
    || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$cap"
}
