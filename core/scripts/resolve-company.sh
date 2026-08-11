#!/usr/bin/env bash
# hq-core: public
# resolve-company.sh — resolve the active company for the current session.
#
# Resolution order (first hit wins):
#   1. session — workspace/sessions/<id>/meta.yaml `company_slug`, bound by
#      /startwork. This is authoritative: the user already told HQ where they
#      are, so no prompt heuristic may override it.
#   2. prompt  — a companies/manifest.yaml slug appearing as a whole token
#      anywhere in the prompt (not just the first word). Longest slug wins;
#      an exact length tie is broken by earliest occurrence.
#   3. none    — nothing resolved. Callers decide whether to ask or default.
#
# Usage:
#   core/scripts/resolve-company.sh --prompt "fix the unicom morning flash bug"
#   core/scripts/resolve-company.sh --root /path/to/HQ --prompt "..."
#   printf '%s' "$PROMPT" | core/scripts/resolve-company.sh
#
# Output: single-line JSON, e.g. {"company":"unicom","source":"prompt"}
#
# ALWAYS exits 0. Callers are UserPromptSubmit hooks running under `set -e`;
# a non-zero exit here would abort the hook and drop the user's prompt.
#
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
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) shift ;;
  esac
done

emit() {
  printf '{"company":"%s","source":"%s"}\n' "$1" "$2"
  exit 0
}

if [ -z "$ROOT" ]; then
  ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)}}"
fi

MANIFEST="$ROOT/companies/manifest.yaml"
[ -f "$MANIFEST" ] || emit "" "none"

# Read the prompt from stdin only when it was not passed explicitly and stdin
# is not a terminal. Hooks always pass --prompt; this is for interactive use.
if [ "$HAVE_PROMPT" -eq 0 ] && [ ! -t 0 ]; then
  PROMPT="$(cat 2>/dev/null || true)"
fi

# --- 1. Known slugs from the manifest -------------------------------------
# Handles both the wrapped `companies:` form and a flat top-level mapping.
# Reserved keys are never valid tenants.
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

# --- 2. Session bind wins -------------------------------------------------
SESSION_CO=""
if [ -x "$ROOT/core/scripts/hq-session.sh" ]; then
  SESSION_CO="$(bash "$ROOT/core/scripts/hq-session.sh" get company_slug 2>/dev/null || true)"
  SESSION_CO="$(printf '%s' "$SESSION_CO" | tr -d '[:space:]"')"
fi

if [ -n "$SESSION_CO" ] && is_known_slug "$SESSION_CO"; then
  emit "$SESSION_CO" "session"
fi

# --- 3. Whole-token scan of the prompt ------------------------------------
# Normalize: lowercase, then collapse every character that cannot appear in a
# slug into a space. Tokens are therefore hyphen- and underscore-preserving
# whole words (the manifest parser accepts `[a-z0-9_-]`, e.g. an `acme_labs`
# slug), so `temple` cannot match inside `templates` and `alive` cannot match
# inside `aliveness`. Matching is deliberately conservative: a miss falls
# through to "none", which callers surface as a question rather than a silent
# misfile.
[ -n "$PROMPT" ] || emit "" "none"

NORMALIZED="$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' ' ')"

MATCH="$(
  printf '%s\n' "$SLUGS" | awk -v line="$NORMALIZED" '
    BEGIN {
      n = split(line, tok, /[ \t]+/)
      for (i = 1; i <= n; i++) if (tok[i] != "") {
        # Record the earliest position at which each token appears.
        if (!(tok[i] in pos)) pos[tok[i]] = i
      }
      bestSlug = ""; bestLen = 0; bestPos = 0
    }
    {
      slug = $0
      if (slug in pos) {
        len = length(slug)
        p = pos[slug]
        if (len > bestLen || (len == bestLen && p < bestPos)) {
          bestSlug = slug; bestLen = len; bestPos = p
        }
      }
    }
    END { if (bestSlug != "") print bestSlug }
  '
)"

[ -n "$MATCH" ] && emit "$MATCH" "prompt"

emit "" "none"
