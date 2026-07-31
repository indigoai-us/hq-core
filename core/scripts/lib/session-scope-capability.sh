#!/usr/bin/env bash
# hq-core: public
# session-scope-capability.sh — mint/read workspace/sessions/<id>/scope-capability.json
#
# Sourced by core/scripts/hq-session.sh and .claude/hooks/mandatory-scope-authorizer.sh.
# Never execute directly.

# session_scope_capability_path <root> <session_id>
#   Print the absolute path to scope-capability.json for a session.
session_scope_capability_path() {
  local root="${1:-}" sid="${2:-}"
  [ -n "$root" ] && [ -n "$sid" ] || return 1
  printf '%s/workspace/sessions/%s/scope-capability.json' "$root" "$sid"
}

# session_scope_read <root> <session_id>
#   Print company_slug from scope-capability.json, or empty when absent/invalid.
session_scope_read() {
  local root="${1:-}" sid="${2:-}" cap
  cap="$(session_scope_capability_path "$root" "$sid")" || return 0
  [ -f "$cap" ] || return 0
  jq -r '.company_slug // empty' "$cap" 2>/dev/null || true
}

# session_scope_mint <root> <session_id> <company_slug>
#   Write scope-capability.json for the session. Returns 0 on success.
session_scope_mint() {
  local root="${1:-}" sid="${2:-}" slug="${3:-}"
  [ -n "$root" ] && [ -n "$sid" ] && [ -n "$slug" ] || return 1

  case "$slug" in
    ''|*[!a-z0-9_-]*)
      echo "session-scope-capability: invalid company_slug: $slug" >&2
      return 1
      ;;
  esac

  local cap dir tmp minted_at
  cap="$(session_scope_capability_path "$root" "$sid")" || return 1
  dir="$(dirname "$cap")"
  mkdir -p "$dir" || return 1

  minted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S'Z')"
  tmp="$(mktemp)"
  jq -n \
    --arg sid "$sid" \
    --arg slug "$slug" \
    --arg minted_at "$minted_at" \
    '{session_id: $sid, company_slug: $slug, minted_at: $minted_at}' >"$tmp" \
    || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$cap"
}
