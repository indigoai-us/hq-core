#!/usr/bin/env bash
# Regression: block-core-writes.sh must keep blocking a write that travels
# through a package contribution link (core/knowledge/* → core/packages/*/
# knowledge/*) — installed pack content is immutable — while still allowing
# writes through symlinks that resolve OUT of the protected tree (a leftover
# personal→core mirror link, or an invalid legacy knowledge symlink whose
# repos/ target is the repos-guard's problem, not this hook's).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/block-core-writes.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$HOOK" ] || fail "hook not found: $HOOK"

PROJ="$(mktemp -d)"; trap 'rm -rf "$PROJ"' EXIT
mkdir -p "$PROJ/.claude" \
         "$PROJ/core/knowledge/public" \
         "$PROJ/core/packages/hq-pack-design-styles/knowledge/design-styles" \
         "$PROJ/personal/policies" \
         "$PROJ/repos/private/knowledge-acme"
# The hook resolves its hook-lib relative to its own location, so give the fake
# root a real copy at the expected path.
mkdir -p "$PROJ/core/scripts" "$PROJ/.claude/hooks"
cp "$ROOT/core/scripts/hook-lib.sh" "$PROJ/core/scripts/hook-lib.sh"
cp "$HOOK" "$PROJ/.claude/hooks/block-core-writes.sh"
HOOK="$PROJ/.claude/hooks/block-core-writes.sh"

printf 'packs: []\n' > "$PROJ/core/packages/hq-pack-design-styles/knowledge/design-styles/registry.yaml"

# Package contribution link: core/knowledge/public/design-styles → packages.
ln -s ../../packages/hq-pack-design-styles/knowledge/design-styles \
  "$PROJ/core/knowledge/public/design-styles"
# Leftover personal→core mirror link (resolves OUT of core/ — allowed).
mkdir -p "$PROJ/core/policies"
ln -s ../../personal/policies/my-rule.md "$PROJ/core/policies/my-rule.md"
# Legacy knowledge symlink into repos/ (resolves OUT of core/ — allowed here;
# the repos/ write guard owns that block).
ln -s ../../../repos/private/knowledge-acme "$PROJ/core/knowledge/public/acme"

export CLAUDE_PROJECT_DIR="$PROJ"

gate() {
  printf '%s' "$1" | jq -Rs '{tool_input:{file_path:.}}' | bash "$HOOK" >/dev/null 2>&1
  echo $?
}
expect() { local want="$1" got; got="$(gate "$2")"; [ "$got" = "$want" ] || fail "want exit $want got $got for: $2"; pass "exit $want :: $3"; }

expect 2 "$PROJ/core/knowledge/public/design-styles/registry.yaml" \
  "write through a package contribution link stays BLOCKED (immutable pack content)"
expect 0 "$PROJ/core/policies/my-rule.md" \
  "write through a retired personal→core mirror link is allowed (lands in personal/)"
expect 0 "$PROJ/core/knowledge/public/acme/notes.md" \
  "write through a legacy knowledge symlink is allowed here (repos-guard territory)"
expect 2 "$PROJ/core/scripts/anything.sh" \
  "plain core/ write stays BLOCKED"

echo "ALL PASS: block-core-writes-package-mount"
