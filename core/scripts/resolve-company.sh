#!/usr/bin/env bash
# hq-core: public
# resolve-company.sh — resolve the active company for the current session.
#
# Resolution order (first hit wins) — US-011:
#   1. session — workspace/sessions/<id>/meta.yaml `company_slug`, bound by
#      /startwork or trusted spawn. Authoritative.
#   2. none    — nothing resolved. Callers decide whether to ask or default.
#
# Prompt-text / manifest-slug matching was removed (US-011). Never infer a
# company from free text.
#
# Usage:
#   core/scripts/resolve-company.sh
#   core/scripts/resolve-company.sh --root /path/to/HQ
#   core/scripts/resolve-company.sh --prompt "..."   # prompt ignored (compat)
#
# Output: single-line JSON, e.g. {"company":"acme","source":"session"}
#
# ALWAYS exits 0. Callers are UserPromptSubmit hooks running under `set -e`.
# Pure-read: never writes session metadata, project files, or state.

set -uo pipefail

ROOT=""
PROMPT=""
HAVE_PROMPT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root)   ROOT="${2:-}"; shift 2 || shift ;;
    --prompt) PROMPT="${2:-}"; HAVE_PROMPT=1; shift 2 || shift ;;
    --help|-h)
      sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) shift ;;
  esac
done

# Compat: drain stdin when hooks still pipe a prompt (ignored).
if [ "$HAVE_PROMPT" -eq 0 ] && [ ! -t 0 ]; then
  PROMPT="$(cat 2>/dev/null || true)"
fi
# Silence unused-prompt warning for shellcheck / set -u callers.
: "${PROMPT:=}"

emit() {
  printf '{"company":"%s","source":"%s"}\n' "$1" "$2"
  exit 0
}

if [ -z "$ROOT" ]; then
  ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)}}"
fi

MANIFEST="$ROOT/companies/manifest.yaml"
[ -f "$MANIFEST" ] || emit "" "none"

SLUGS="$(
  awk '
    function keep(slug) {
      return slug != "" &&
        slug != "_template" &&
        slug != "companies" &&
        slug != "unaffiliated_repos"
    }

    /^companies:[[:space:]]*$/ { wrapped = 1; next }

    wrapped && /^[^[:space:]][^:]*:[[:space:]]*$/ { wrapped = 0 }

    wrapped && /^  [a-z][a-z0-9_-]*:/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/:.*/, "", line)
      if (keep(line)) print line
      next
    }

    !wrapped && /^[a-z][a-z0-9_-]*:/ {
      line = $0
      sub(/:.*/, "", line)
      if (keep(line)) print line
    }
  ' "$MANIFEST" | sort -u
)"

[ -n "$SLUGS" ] || emit "" "none"

is_known_slug() {
  printf '%s\n' "$SLUGS" | grep -Fxq "$1"
}

SESSION_CO=""
if [ -x "$ROOT/core/scripts/hq-session.sh" ]; then
  SESSION_CO="$(bash "$ROOT/core/scripts/hq-session.sh" get company_slug 2>/dev/null || true)"
  SESSION_CO="$(printf '%s' "$SESSION_CO" | tr -d '[:space:]"')"
fi

if [ -n "$SESSION_CO" ] && is_known_slug "$SESSION_CO"; then
  emit "$SESSION_CO" "session"
fi

emit "" "none"
