#!/usr/bin/env bash
# Mandatory company-scope authorizer — blocks cross-company filesystem reads.
# PreToolUse for Read, Grep, Glob, Bash.
#
# Resolves the active company from workspace/sessions (scope-capability.json,
# then meta.yaml company_slug). Unbound sessions may not read companies/{co}/
# except companies/manifest.yaml and companies/_template/.

set -euo pipefail

INPUT="$(cat)"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"

case "$TOOL" in
  Read|Grep|Glob|Bash) ;;
  *) exit 0 ;;
esac

self_src="${BASH_SOURCE[0]:-$0}"
self_dir="$(cd "$(dirname "$self_src")" 2>/dev/null && pwd -P || true)"
HQ_ROOT=""
if [ -n "$self_dir" ]; then
  cand="$(cd "$self_dir/../.." 2>/dev/null && pwd -P || true)"
  if [ -n "$cand" ] && [ -f "$cand/core/scripts/lib/session-authz.sh" ]; then
    HQ_ROOT="$cand"
  fi
fi
[ -n "$HQ_ROOT" ] || HQ_ROOT="${CLAUDE_PROJECT_DIR:-${HQ_ROOT:-}}"
[ -n "$HQ_ROOT" ] && [ -d "$HQ_ROOT/companies" ] || exit 0

LIB_DIR="$HQ_ROOT/core/scripts/lib"
# shellcheck source=../../core/scripts/lib/session-authz.sh
. "$LIB_DIR/session-authz.sh"
# shellcheck source=../../core/scripts/lib/session-scope-capability.sh
. "$LIB_DIR/session-scope-capability.sh"

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty')"
if [ -z "$SESSION_ID" ] && [ -f "$HQ_ROOT/workspace/sessions/.current" ]; then
  SESSION_ID="$(tr -d '[:space:]' < "$HQ_ROOT/workspace/sessions/.current" 2>/dev/null || true)"
fi

BOUND_CO=""
if [ -n "$SESSION_ID" ]; then
  BOUND_CO="$(session_scope_read "$HQ_ROOT" "$SESSION_ID")"
  if [ -z "$BOUND_CO" ]; then
    meta="$HQ_ROOT/workspace/sessions/$SESSION_ID/meta.yaml"
    if [ -f "$meta" ]; then
      BOUND_CO="$(awk '
        $1 == "company_slug:" {
          sub(/^[^:]+:[[:space:]]*/, "")
          gsub(/^"|"$/, "")
          print
          exit
        }
      ' "$meta" 2>/dev/null || true)"
    fi
  fi
fi

scope_normalize_hq_relative() {
  local raw="${1:-}"
  [ -n "$raw" ] || { printf '%s' ""; return 0; }
  raw="${raw//\\//}"

  case "$raw" in
    ~/*)
      [ -n "${HOME:-}" ] || { printf '%s' ""; return 0; }
      raw="${HOME}/${raw#~/}"
      ;;
    ~)
      raw="${HOME:-}"
      [ -n "$raw" ] || { printf '%s' ""; return 0; }
      ;;
  esac

  local rel="$raw"
  case "$raw" in
    "$HQ_ROOT"/*) rel="${raw#"$HQ_ROOT"/}" ;;
    "$HQ_ROOT") rel="" ;;
    /*) printf '%s' ""; return 0 ;;
  esac

  local out="" seg
  IFS='/' read -r -a parts <<< "$rel"
  for seg in "${parts[@]}"; do
    [ -n "$seg" ] || continue
    case "$seg" in
      .) ;;
      ..)
        if [ -n "$out" ]; then
          out="${out%/*}"
        fi
        ;;
      *)
        out="${out:+$out/}$seg"
        ;;
    esac
  done
  printf '%s' "$out"
}

scope_resolve_rel_symlinks() {
  local rel="${1:-}"
  [ -n "$rel" ] || { printf '%s' ""; return 0; }
  local abs="$HQ_ROOT/$rel"
  [ -e "$abs" ] || [ -L "$abs" ] || { printf '%s' "$rel"; return 0; }

  local cur="$abs" target base hops=0
  while [ -L "$cur" ] && [ "$hops" -lt 20 ]; do
    target="$(readlink "$cur" 2>/dev/null || true)"
    [ -n "$target" ] || break
    case "$target" in
      /*) cur="$target" ;;
      *)
        base="$(dirname "$cur")"
        cur="$base/$target"
        ;;
    esac
    hops=$((hops + 1))
  done

  case "$cur" in
    "$HQ_ROOT"/*) rel="${cur#"$HQ_ROOT"/}" ;;
    *) rel="" ;;
  esac
  printf '%s' "$rel"
}

scope_company_slug_for_rel() {
  local rel="${1:-}"
  [ -n "$rel" ] || return 0
  case "$rel" in
    companies)
      printf '%s' "__companies_root__"
      ;;
    companies/*)
      printf '%s' "${rel#companies/}" | cut -d/ -f1
      ;;
  esac
}

scope_is_manifest_rel() {
  case "${1:-}" in
    companies/manifest.yaml|companies/manifest.yml|companies/manifest.json) return 0 ;;
    *) return 1 ;;
  esac
}

scope_is_template_rel() {
  case "${1:-}" in
    companies/_template|companies/_template/*) return 0 ;;
    *) return 1 ;;
  esac
}

scope_rel_allowed() {
  local rel="${1:-}"
  [ -n "$rel" ] || return 0

  if scope_is_manifest_rel "$rel" || scope_is_template_rel "$rel"; then
    return 0
  fi

  local co
  co="$(scope_company_slug_for_rel "$rel")"
  [ -n "$co" ] || return 0
  [ "$co" != "__companies_root__" ] || return 0

  case "$co" in
    _template|_*)
      return 0
      ;;
  esac

  if [ -z "$BOUND_CO" ]; then
    return 1
  fi

  [ "$co" = "$BOUND_CO" ]
}

scope_block_rel() {
  local rel="${1:-}"
  local co bound_msg
  co="$(scope_company_slug_for_rel "$rel")"
  if [ -z "$BOUND_CO" ]; then
    bound_msg="Session has no company_slug bound."
  else
    bound_msg="Session company_slug is '$BOUND_CO'."
  fi

  cat >&2 <<EOF
BLOCKED: Cross-company scope violation
Tool: $TOOL
Path: $rel
Target company: ${co:-unknown}
$bound_msg

Bind the correct company with: core/scripts/hq-session.sh set company_slug <slug>
Allowed without binding: core/, personal/, repos/, workspace/, companies/manifest.yaml, companies/_template/
EOF
  exit 2
}

scope_check_rel() {
  local rel="${1:-}"
  [ -n "$rel" ] || return 0
  scope_rel_allowed "$rel" || scope_block_rel "$rel"
}

scope_check_raw() {
  local raw="${1:-}" rel
  [ -n "$raw" ] || return 0
  rel="$(scope_normalize_hq_relative "$raw")"
  rel="$(scope_resolve_rel_symlinks "$rel")"
  scope_check_rel "$rel"
}

case "$TOOL" in
  Read)
    scope_check_raw "$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')"
    ;;
  Grep|Glob)
    scope_check_raw "$(printf '%s' "$INPUT" | jq -r '.tool_input.path // empty')"
    ;;
  Bash)
    cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
    [ -n "$cmd" ] || exit 0
    if printf '%s' "$cmd" | grep -q 'companies/'; then
      if printf '%s' "$cmd" | grep -q '\$'; then
        scope_block_rel "companies/(shell-expanded)"
      fi
    fi
    while IFS= read -r fragment; do
      [ -n "$fragment" ] || continue
      scope_check_rel "$fragment"
    done < <(printf '%s' "$cmd" | grep -oE 'companies/[a-z0-9_-]+(/[a-zA-Z0-9._@+/-]*)?' 2>/dev/null || true)
    ;;
esac

exit 0
