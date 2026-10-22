#!/usr/bin/env bash
# Every global npm install in the GitHub workflows names an exact version, and
# the two workflows that install codex agree on it. A global install ignores
# lockfiles, so an unpinned one resolves whatever was published last.
# Security audit 2026-10-21, item M4.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
WORKFLOWS="$ROOT/.github/workflows"

checks=0
failures=0
check() {
  label="$1"
  shift
  checks=$((checks + 1))
  if "$@"; then
    printf 'ok %s\n' "$label"
  else
    failures=$((failures + 1))
    printf 'not ok %s\n' "$label" >&2
  fi
}

# Global installs in run steps (comment lines excluded).
installs="$(grep -rnE '^[^#]*npm (i|install) (-g|--global) ' "$WORKFLOWS" || true)"
check "workflows contain global installs to check" test -n "$installs"

while IFS= read -r line; do
  [ -n "$line" ] || continue
  # Each package argument must end in @<x.y.z> or @<$VAR>.
  spec="${line#*npm }"
  pinned=1
  for word in $spec; do
    word="${word//\"/}"
    case "$word" in
      i|install|-g|--global|--ignore-scripts|'||'|true) ;;
      *@[0-9]*.[0-9]*.[0-9]*|*@\$*) ;;
      *) pinned=0 ;;
    esac
  done
  check "exact version: ${line%%:*}: ${spec}" test "$pinned" -eq 1
done <<< "$installs"

codex_versions="$(grep -rhE '^[[:space:]]*CODEX_VERSION:' "$WORKFLOWS" | awk '{print $2}' | sort -u)"
check "codex workflows pin one codex version" test "$(printf '%s\n' "$codex_versions" | grep -c .)" -eq 1
check "codex version is exact" grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' <<< "$codex_versions"
check "doctor-advisory pins hq-cli exactly" \
  grep -Eq '^[[:space:]]*HQ_DOCTOR_CLI_VERSION: [0-9]+\.[0-9]+\.[0-9]+$' "$WORKFLOWS/doctor-advisory.yml"
check "doctor-advisory installs through the pinned installer" \
  grep -Fq 'install-pinned-hq-cli.sh --version "$HQ_DOCTOR_CLI_VERSION"' "$WORKFLOWS/doctor-advisory.yml"

if [ "$failures" -eq 0 ]; then
  printf 'PASS workflow global install pins (%s/%s assertions)\n' "$checks" "$checks"
  exit 0
fi
printf 'FAIL workflow global install pins (%s/%s assertions failed)\n' "$failures" "$checks" >&2
exit 1
