#!/usr/bin/env bash
# hq-core: public
# provider-adapter-capabilities-snapshot.test.sh - US-504 snapshot drift guard.
#
# capabilities.generated.json is the ONLY mechanism by which hq-pro
# control-plane TypeScript can read a capability descriptor that otherwise
# exists solely as bash on an agent box. A stale snapshot is therefore not a
# cosmetic problem: the control plane would route work using a descriptor the
# fleet no longer has -- for example dispatching a plan turn to a provider that
# has since declared plan_mode=absent.
#
# This regenerates the snapshot into a temp file and diffs it against the
# checked-in copy. Any difference exits 1 and prints the diff, so the fix is
# always the same and always obvious: re-run the generator and commit.
#
# It also re-proves determinism here rather than trusting the generator's own
# test, because determinism is what makes the diff meaningful at all.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GEN="$ROOT/core/scripts/generate-adapter-capabilities.sh"
SNAPSHOT="$ROOT/core/scripts/lib/provider-adapters/capabilities.generated.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

if [[ ! -f "$SNAPSHOT" ]]; then
  echo "  FAIL: capabilities.generated.json is not checked in" >&2
  echo "        run: bash core/scripts/generate-adapter-capabilities.sh" >&2
  exit 1
fi
pass "snapshot is checked in"

bash "$GEN" --stdout > "$TMP/regenerated.json"

if diff -u "$SNAPSHOT" "$TMP/regenerated.json" > "$TMP/drift.diff" 2>&1; then
  pass "checked-in snapshot matches a fresh generation (no drift)"
else
  fail "capabilities.generated.json is STALE - an adapter descriptor changed"
  echo "--- drift ---" >&2
  cat "$TMP/drift.diff" >&2
  echo "--- fix: bash core/scripts/generate-adapter-capabilities.sh && commit ---" >&2
fi

# Determinism (AC7): two runs on an unchanged tree are byte-identical.
bash "$GEN" --stdout > "$TMP/second.json"
if cmp -s "$TMP/regenerated.json" "$TMP/second.json"; then
  pass "generator is deterministic across runs"
else
  fail "generator is NONDETERMINISTIC - the drift check above is meaningless"
  diff -u "$TMP/regenerated.json" "$TMP/second.json" >&2 || true
fi

# AC7: no environment-derived content. These would each make the snapshot
# machine-specific and turn the drift check into permanent CI noise.
if grep -qE '/(Users|home)/' "$SNAPSHOT"; then
  fail "snapshot contains an absolute user path"
else
  pass "snapshot contains no absolute user paths"
fi
if grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}T|[0-9]{10}' "$SNAPSHOT"; then
  fail "snapshot contains something timestamp-shaped"
else
  pass "snapshot contains no timestamps"
fi
if command -v hostname >/dev/null 2>&1 && grep -qiF "$(hostname)" "$SNAPSHOT" 2>/dev/null; then
  fail "snapshot contains this machine's hostname"
else
  pass "snapshot contains no hostname"
fi

# AC7: contractVersion is present and matches the live contract.
. "$ROOT/core/scripts/lib/provider-adapter-version.sh"
snapshot_version="$(sed -n 's/.*"contractVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SNAPSHOT" | head -1)"
if [[ -z "$snapshot_version" ]]; then
  fail "snapshot has no top-level contractVersion"
elif [[ "$snapshot_version" != "$HQ_ADAPTER_CONTRACT_VERSION" ]]; then
  fail "snapshot contractVersion $snapshot_version != contract $HQ_ADAPTER_CONTRACT_VERSION"
else
  pass "snapshot records contractVersion $snapshot_version"
fi

if [[ "$FAIL" -gt 0 ]]; then
  echo "provider-adapter-capabilities-snapshot: $FAIL failure(s)" >&2
  exit 1
fi
echo "provider-adapter-capabilities-snapshot: all passed"
