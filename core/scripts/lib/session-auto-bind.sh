#!/usr/bin/env bash
# hq-core: public
# session-auto-bind.sh — bind company_slug + scope-capability for a session
# when a *safe* source already names the tenant.
#
# Safe sources (first hit wins):
#   1. This session's existing meta.yaml / scope-capability.json
#   2. HQ_SPAWN_COMPANY (explicit spawn / conduct / fleet)
#   3. Parent session id (payload or HQ_PARENT_SESSION_ID) — inherit that slug
#
# Never invent a tenant from cwd path fragments (category-1). If nothing
# resolves, leave the session unbound (authorizer stays fail-closed).
#
# Sourced; never execute directly.

# session_auto_bind_meta_slug <root> <sid>
session_auto_bind_meta_slug() {
  local root="${1:-}" sid="${2:-}" meta
  [ -n "$root" ] && [ -n "$sid" ] || return 0
  meta="$root/workspace/sessions/$sid/meta.yaml"
  [ -f "$meta" ] || return 0
  awk '
    $1 == "company_slug:" {
      sub(/^[^:]+:[[:space:]]*/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$meta" 2>/dev/null || true
}

# session_auto_bind_is_known_slug <root> <slug>
session_auto_bind_is_known_slug() {
  local root="${1:-}" slug="${2:-}"
  [ -n "$root" ] && [ -n "$slug" ] || return 1
  case "$slug" in
    ''|*[!a-z0-9_-]*) return 1 ;;
  esac
  [ "$slug" = "personal" ] && return 0
  [ -d "$root/companies/$slug" ] && return 0
  return 1
}

# session_auto_bind_resolve <root> <sid> [parent_sid]
#   Print the slug to bind, or empty.
session_auto_bind_resolve() {
  local root="${1:-}" sid="${2:-}" parent="${3:-}" slug=""
  [ -n "$root" ] && [ -n "$sid" ] || return 0

  if command -v session_scope_read >/dev/null 2>&1; then
    slug="$(session_scope_read "$root" "$sid" 2>/dev/null || true)"
  fi
  [ -z "$slug" ] && slug="$(session_auto_bind_meta_slug "$root" "$sid")"
  if session_auto_bind_is_known_slug "$root" "$slug"; then
    printf '%s' "$slug"
    return 0
  fi

  slug="${HQ_SPAWN_COMPANY:-}"
  slug="$(printf '%s' "$slug" | tr -d '[:space:]"')"
  if session_auto_bind_is_known_slug "$root" "$slug"; then
    printf '%s' "$slug"
    return 0
  fi

  [ -z "$parent" ] && parent="${HQ_PARENT_SESSION_ID:-}"
  parent="$(printf '%s' "$parent" | tr -d '[:space:]')"
  if [ -n "$parent" ] && [ "$parent" != "$sid" ]; then
    slug=""
    if command -v session_scope_read >/dev/null 2>&1; then
      slug="$(session_scope_read "$root" "$parent" 2>/dev/null || true)"
    fi
    [ -z "$slug" ] && slug="$(session_auto_bind_meta_slug "$root" "$parent")"
    if session_auto_bind_is_known_slug "$root" "$slug"; then
      printf '%s' "$slug"
      return 0
    fi
  fi
  return 0
}

# session_auto_bind_apply <root> <sid> [parent_sid]
#   Bind slug + mint capability when a safe source exists. Exit 0 always.
session_auto_bind_apply() {
  local root="${1:-}" sid="${2:-}" parent="${3:-}" slug=""
  [ -n "$root" ] && [ -n "$sid" ] || return 0
  case "$sid" in
    .|..|*/*|*[!A-Za-z0-9._-]*) return 0 ;;
  esac

  slug="$(session_auto_bind_resolve "$root" "$sid" "$parent")"
  [ -n "$slug" ] || return 0

  local meta_dir meta
  meta_dir="$root/workspace/sessions/$sid"
  meta="$meta_dir/meta.yaml"
  mkdir -p "$meta_dir" 2>/dev/null || return 0

  if [ ! -f "$meta" ]; then
    printf 'session_id: %s\ncompany_slug: %s\nstarted_at: "%s"\n' \
      "$sid" "$slug" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" \
      > "$meta" || return 0
  elif ! grep -q '^company_slug:' "$meta" 2>/dev/null; then
    printf 'company_slug: %s\n' "$slug" >> "$meta" || return 0
  fi

  if command -v session_scope_mint >/dev/null 2>&1; then
    session_scope_mint "$root" "$sid" "$slug" || true
  fi
  return 0
}
