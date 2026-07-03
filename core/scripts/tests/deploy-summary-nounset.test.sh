#!/usr/bin/env bash
# Regression: .claude/skills/project-summary/scripts/deploy-summary.sh runs
# under `set -euo pipefail`, and HQ_DEPLOY_API is an OPTIONAL override. It must
# NOT abort with "HQ_DEPLOY_API: unbound variable" when that var is unset — it
# should fall through to the manifest / public-default resolution and behave
# gracefully (feedback_3cdd3064). Also guards the other set -u hazard found on
# the same audit pass (HOME, read for the cognito-token path).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
SRC="$ROOT/.claude/skills/project-summary/scripts/deploy-summary.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$SRC" ] || fail "deploy-summary.sh not found at $SRC"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Copy the script into a fake HQ root so it resolves HQ_ROOT here (no
# companies/manifest.yaml → the manifest branch is skipped deterministically)
# and aborts at the build-dir guard BEFORE any identity/network call.
mkdir -p "$TMP/.claude/skills/project-summary/scripts"
cp "$SRC" "$TMP/.claude/skills/project-summary/scripts/deploy-summary.sh"
FS="$TMP/.claude/skills/project-summary/scripts/deploy-summary.sh"

echo "[1] HQ_DEPLOY_API unset under set -u: no unbound abort; clean build_dir error"
set +e
out="$(env -u HQ_DEPLOY_API bash "$FS" "$TMP/nope-build" appname 2>&1)"; code=$?
set -e
printf '%s' "$out" | grep -qi 'unbound variable' && fail "still aborts with unbound variable: $out"
printf '%s' "$out" | grep -q 'build_dir_missing' || fail "did not reach the build-dir guard cleanly: $out"
[ "$code" -ne 0 ] || fail "expected non-zero exit for a missing build dir, got 0"
pass "no unbound abort; failed cleanly at build_dir_missing"

echo "[2] no regression when HQ_DEPLOY_API IS set"
set +e
out2="$(HQ_DEPLOY_API='https://example.test' bash "$FS" "$TMP/nope-build" appname 2>&1)"
set -e
printf '%s' "$out2" | grep -q 'build_dir_missing' || fail "set-HQ_DEPLOY_API path regressed: $out2"
pass "set HQ_DEPLOY_API still resolves + fails cleanly at build_dir_missing"

echo "[3] source-contract: optional env vars are guarded for set -u"
# HQ_DEPLOY_API must be read with a ${..:-} default (fixed-string matches to
# avoid brace-as-ERE-interval ambiguity)...
grep -qF 'API="${HQ_DEPLOY_API:-' "$SRC" || fail "HQ_DEPLOY_API is not read with a default"
# ...and no BARE, unguarded HQ_DEPLOY_API reference may remain (comments stripped
# first, since the resolution comment names the var).
if sed 's/#.*//' "$SRC" | grep -F 'HQ_DEPLOY_API' | grep -qvF '${HQ_DEPLOY_API:-'; then
  fail "a bare, unguarded \$HQ_DEPLOY_API reference remains in code"
fi
# HOME (read for the cognito-token path) must also be guarded.
grep -qF '${HOME:-}/.hq/cognito-tokens.json' "$SRC" \
  || fail "HOME is not guarded (\${HOME:-}) for the cognito-token path read"
pass "HQ_DEPLOY_API and HOME are guarded against set -u"

echo "ALL PASS: deploy-summary-nounset"
