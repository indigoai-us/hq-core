#!/usr/bin/env bash
# Exercise the generated-wrapper block and verify its stderr message byte-for-byte.
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/route-company-skill-creation.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
mkdir -p "$PROJECT/companies/indigo"

cat > "$TMP/input.json" <<'JSON'
{"tool_input":{"file_path":".claude/skills/indigo:demo/SKILL.md"}}
JSON
cat > "$TMP/expected.stderr" <<'EXPECTED'
BLOCKED: Direct write to .claude/skills/indigo:demo/SKILL.md is not allowed.
This is a generated runtime path for companies/indigo/skills/demo/SKILL.md.

For a new company skill, run:
  hq skill --company indigo create demo --no-sync

Then edit companies/indigo/skills/demo/SKILL.md and run the create command again to surface and sync it.
Generated `.claude/skills/` wrappers are owned by HQ.

Override (rare, audited): set HQ_ALLOW_DIRECT_PREFIX_WRITE=1 to bypass this check.
EXPECTED

status=0
CLAUDE_PROJECT_DIR="$PROJECT" HQ_ALLOW_DIRECT_PREFIX_WRITE= \
  bash "$HOOK" < "$TMP/input.json" > "$TMP/stdout" 2> "$TMP/stderr" || status=$?
if [[ "$status" -ne 2 ]]; then
  printf 'FAIL: expected hook exit 2, got %s\n' "$status" >&2
  cat "$TMP/stdout" "$TMP/stderr" >&2
  exit 1
fi

grep -Fxq 'Generated `.claude/skills/` wrappers are owned by HQ.' "$TMP/stderr" || {
  echo 'FAIL: literal generated-wrapper message was missing' >&2
  cat "$TMP/stderr" >&2
  exit 1
}
if grep -Fq 'Is a directory' "$TMP/stderr"; then
  echo 'FAIL: heredoc treated the backticked path as a command' >&2
  cat "$TMP/stderr" >&2
  exit 1
fi
cmp -s "$TMP/expected.stderr" "$TMP/stderr" || {
  echo 'FAIL: hook stderr differed from the expected message' >&2
  diff -u "$TMP/expected.stderr" "$TMP/stderr" >&2 || true
  exit 1
}
[[ ! -s "$TMP/stdout" ]] || {
  echo 'FAIL: hook unexpectedly wrote to stdout' >&2
  cat "$TMP/stdout" >&2
  exit 1
}

echo 'route-company-skill-creation behavior test passed'
