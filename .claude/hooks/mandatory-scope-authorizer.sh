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

scope_mask_literal_expansions() {
  local raw="${1:-}" out="" ch backtick
  local in_single=0 escaped=0 i
  backtick=$'\140'

  for ((i = 0; i < ${#raw}; i++)); do
    ch="${raw:i:1}"
    if [ "$escaped" -eq 1 ]; then
      case "$ch" in
        '$'|"$backtick") out+="__HQ_LITERAL_EXPANSION__" ;;
        *) out+="$ch" ;;
      esac
      escaped=0
      continue
    fi

    if [ "$in_single" -eq 1 ]; then
      if [ "$ch" = "'" ]; then
        in_single=0
        out+="$ch"
      else
        case "$ch" in
          '$'|"$backtick") out+="__HQ_LITERAL_EXPANSION__" ;;
          *) out+="$ch" ;;
        esac
      fi
      continue
    fi

    case "$ch" in
      \\) out+="$ch"; escaped=1 ;;
      \') out+="$ch"; in_single=1 ;;
      *) out+="$ch" ;;
    esac
  done

  printf '%s' "$out"
}

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
# shellcheck source=../../core/scripts/lib/session-id.sh
. "$LIB_DIR/session-id.sh"

# The hook payload is the ONLY identity this guard accepts. It names the session
# that fired this event; nothing else here describes the caller reliably.
#
# Not workspace/sessions/.current: that pointer is global and last-writer-wins
# (see core/scripts/lib/session-id.sh, whose own header states the invariant this
# restores: "the enforcement side does not use .current"). It names whichever
# session fired a hook most recently, so an unrelated agent inherits a stranger's
# company binding — an UNBOUND agent was observed reading another tenant's files
# because .current happened to name a session bound to that tenant (2026-08-19,
# HQ 15.0.98).
#
# And NOT the session environment either, however tempting: a session id in the
# environment describes whoever EXPORTED it, which for a spawned agent is its
# PARENT. core/scripts/tests/hq-agent-session-hooks.test.sh case 7 documents and
# tests exactly that inheritance ("An agent session spawned from inside another
# session inherits that parent's session id"). Resolving identity from the
# environment would therefore authorize a payload-less child against its parent's
# tenant — the same cross-session failure by a different route.
#
# A payload with no session id is produced by `claude -p --session-id <uuid>`.
# Such a call cannot be attributed to any session and is denied below.
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty')"

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
  local rel="${1:-}" co
  [ -n "$rel" ] || return 0
  case "$rel" in
    companies)
      printf '%s' "__companies_root__"
      ;;
    companies/*)
      co="${rel#companies/}"
      co="${co%%/*}"
      # The first segment is a company only when it resolves to an actual
      # tenant directory. Top-level files (notably manifest.yaml), shell
      # expansions, and placeholder prose are not tenant targets.
      case "$co" in
        *'$'*|*'`'*|*'('*|*')'*|*'{'*|*'}'*|*'<'*|*'>'*) return 0 ;;
      esac
      [ -d "$HQ_ROOT/companies/$co" ] || return 0
      printf '%s' "$co"
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

  # Fail CLOSED. An unidentifiable session (no id in the payload, none in the
  # environment) gets no company access, and neither does an identified session
  # with no binding. Permitting either would make the guard depend on being able
  # to name the caller, which is precisely what it cannot assume.
  if [ -z "$SESSION_ID" ] || [ -z "$BOUND_CO" ]; then
    return 1
  fi

  [ "$co" = "$BOUND_CO" ]
}

scope_block_rel() {
  local rel="${1:-}"
  local co bound_msg
  co="$(scope_company_slug_for_rel "$rel")"
  if [ -z "$SESSION_ID" ]; then
    bound_msg="This call carries NO session id in its hook payload, so there is no
session whose company scope could authorize it, and company paths are denied
rather than guessed. Only the payload identity counts here: an id in the
environment names whoever exported it — for a spawned agent, its parent — and a
child must not inherit its parent's tenant. If this is an agent you spawned, run
it so the host reports a session of its own (a \`claude -p --session-id <uuid>\`
child does not)."
  elif [ -z "$BOUND_CO" ]; then
    bound_msg="Session has no company_slug bound."
  else
    bound_msg="Session company_slug is '$BOUND_CO'."
  fi

  cat >&2 <<EOF
BLOCKED: Cross-company scope violation
Tool: $TOOL
Path: $rel
Target company: ${co:-unknown}
Session: ${SESSION_ID:-unknown}
$bound_msg

Bind the correct company with: core/scripts/hq-session.sh set company_slug <slug>
If that reports success but this keeps blocking, the bind landed on another
session — retry it as: core/scripts/hq-session.sh --session-id ${SESSION_ID:-<id>} set company_slug <slug>
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
    # Bash removes an unquoted backslash-newline before tokenizing, so scan the
    # same normalized form when extracting possible path tokens.
    scope_cmd="${cmd//$'\\\n'/}"
    scope_detection_cmd="$(scope_mask_literal_expansions "$scope_cmd")"
    # A literal tenant followed by an unexpanded remainder can traverse out of
    # that tenant at execution time (companies/indigo/$p). This is distinct
    # from an unresolved first segment, which has no tenant to authorize.
    if printf '%s' "$scope_detection_cmd" | grep -qE 'companies/[a-z0-9_-]+/[^[:space:];|&()<>]*[$`]'; then
      scope_block_rel "companies/(shell-expanded)"
    fi
    while IFS= read -r fragment; do
      [ -n "$fragment" ] || continue
      scope_check_raw "$fragment"
    done < <(printf '%s' "$scope_cmd" | grep -oE 'companies/[^[:space:];|&()<>]*' 2>/dev/null || true)
    ;;
esac

exit 0
