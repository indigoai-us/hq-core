#!/usr/bin/env bash
# gitignore-secret-paths.test.sh — the shipped .gitignore keeps token caches
# and credential-shaped core/settings files out of git without hiding the
# tracked defaults that core/settings ships (feedback_87abfe55-1983-4f7c-9fbb-2b405187b759).
#
# Ignoring core/settings/ whole would drop every future shipped default there
# (a directory rule cannot be re-included file by file), so the rule is the
# narrower credential-shaped set.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$(cd "$SRC_ROOT/.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

git -C "$TMP_ROOT" init -q
cp "$REPO_ROOT/.gitignore" "$TMP_ROOT/.gitignore"

ignored() { git -C "$TMP_ROOT" check-ignore -q --no-index -- "$1"; }

for p in tokens/cognito.json companies/syntha/tokens/oauth.json core/settings/api.json \
         core/settings/nested/creds.json core/settings/service.env core/settings/service.env.local \
         core/settings/secrets/key.txt; do
  ignored "$p" || fail "$p must be ignored"
done

for p in core/settings/pure-ralph.json core/settings/.gitkeep core/settings/fingerprint.yaml \
         core/settings/new-default.yaml; do
  if ignored "$p"; then fail "$p is a shipped default and must not be ignored"; fi
done

# Every file core/settings ships today stays visible to git.
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  if ignored "$p"; then fail "tracked $p is now ignored"; fi
done < <(git -C "$REPO_ROOT" ls-files -- core/settings)

echo "PASS: .gitignore covers tokens/ and credential-shaped core/settings files"
