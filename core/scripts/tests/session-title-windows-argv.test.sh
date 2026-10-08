#!/usr/bin/env bash
# Exercise slash-prefixed mode argv through the real Git Bash -> Node boundary.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TITLE="$ROOT/core/scripts/session-title.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/companies" "$TMP/repos/public/probe-console/src"
cat > "$TMP/companies/manifest.yaml" <<'YAML'
companies:
  probe:
    name: Probe
YAML

windows_root="$(cygpath -w "$TMP")"
unset CLAUDE_PROJECT_DIR || true
title="$(HQ_ROOT="$windows_root" bash "$TITLE" \
  --session-id "session-title-windows-argv-$$" \
  --command /handoff \
  --cwd "$windows_root/repos/public/probe-console/src" 2>&1)"

if [[ "$title" != *"📝"* ]]; then
  printf 'FAIL: Git Bash session-title lost /handoff mode; got %q\n' "$title" >&2
  exit 1
fi
if [[ "$title" == *"Program Files/Git/handoff"* ]]; then
  printf 'FAIL: Git Bash converted /handoff into a filesystem path: %q\n' "$title" >&2
  exit 1
fi

printf 'PASS: Git Bash preserved /handoff and rendered the handoff glyph: %s\n' "$title"
