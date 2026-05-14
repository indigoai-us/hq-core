#!/bin/bash
# auto-startwork.sh — SessionStart hook for single-company HQ installs.
#
# When companies/manifest.yaml contains exactly one company, emit a compact
# startup instruction telling the assistant to run /startwork <company>. This
# keeps multi-company HQs explicit while making single-company installs feel
# ready-to-work by default.
#
# Disable with:
#   HQ_AUTO_STARTWORK=0
#   HQ_DISABLED_HOOKS=auto-startwork

set -euo pipefail

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"
SOURCE="$(printf '%s' "$STDIN_JSON" | sed -nE 's/.*"source"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
[ -z "$SOURCE" ] && SOURCE="startup"

# Only fresh sessions should auto-bootstrap. Resume/compact events already have
# accumulated context and should not re-run startwork.
case "$SOURCE" in
  startup|"") ;;
  *) exit 0 ;;
esac

case "${HQ_AUTO_STARTWORK:-1}" in
  0|false|FALSE|off|OFF|no|NO) exit 0 ;;
esac

disabled_hooks=",${HQ_DISABLED_HOOKS:-},"
disabled_hooks="$(printf '%s' "$disabled_hooks" | tr -d '[:space:]')"
case "$disabled_hooks" in
  *,auto-startwork,*) exit 0 ;;
esac

HQ_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MANIFEST="$HQ_ROOT/companies/manifest.yaml"
[ -f "$MANIFEST" ] || exit 0

company_slug="$(
  awk '
    function keep(slug) {
      return slug != "" &&
        slug != "_template" &&
        slug != "companies" &&
        slug != "unaffiliated_repos"
    }

    /^companies:[[:space:]]*$/ { wrapped = 1; next }

    wrapped && /^[^[:space:]][^:]*:[[:space:]]*$/ {
      wrapped = 0
    }

    wrapped && /^  [a-z][a-z0-9_-]*:/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/:.*/, "", line)
      if (keep(line)) slugs[++count] = line
      next
    }

    !wrapped && /^[a-z][a-z0-9_-]*:/ {
      line = $0
      sub(/:.*/, "", line)
      if (keep(line)) slugs[++count] = line
    }

    END {
      if (count == 1) print slugs[1]
    }
  ' "$MANIFEST"
)"

[ -n "$company_slug" ] || exit 0

cat <<EOF
<auto-startwork>
Single-company HQ detected: $company_slug
Run \`/startwork $company_slug\` now as the first session action. If slash commands are unavailable in this runtime, execute the startwork skill with argument "$company_slug" instead.
Disable with \`HQ_AUTO_STARTWORK=0\` or \`HQ_DISABLED_HOOKS=auto-startwork\`.
</auto-startwork>
EOF
