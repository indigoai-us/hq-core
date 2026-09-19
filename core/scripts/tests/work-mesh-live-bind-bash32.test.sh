#!/usr/bin/env bash
# Regression: macOS /bin/bash 3.2 aborts on an empty assigned array under
# `set -u`. The trusted bind must set company context before an explicit session
# id is available, while still pinning the .current session when present.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BIND="$ROOT/core/scripts/work-mesh-live-bind-trusted.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -x /bin/bash ] || fail "/bin/bash is required for the macOS regression"
[ -f "$BIND" ] || fail "missing trusted bind script"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/work-mesh-bind-bash32.XXXXXX")"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

HQ="$SANDBOX/hq"
SID="sid-bash32-current"
mkdir -p "$HQ/core/scripts" "$HQ/workspace/sessions/$SID" "$SANDBOX/home"
cp -R "$ROOT/core/scripts/lib" "$HQ/core/scripts/lib"
cp "$ROOT/core/scripts/hq-session.sh" "$HQ/core/scripts/"
cp "$BIND" "$HQ/core/scripts/"
chmod +x "$HQ/core/scripts/hq-session.sh" "$HQ/core/scripts/work-mesh-live-bind-trusted.sh"
printf '%s\n' "$SID" >"$HQ/workspace/sessions/.current"

if ! env \
  HOME="$SANDBOX/home" \
  HQ_ROOT="$HQ" \
  CLAUDE_PROJECT_DIR="$HQ" \
  HQ_SESSION_ID= \
  CLAUDE_CODE_SESSION_ID= \
  CLAUDE_SESSION_ID= \
  CODEX_SESSION_ID= \
  CODEX_THREAD_ID= \
  HQ_HQ_SESSION_NO_CLI=1 \
  HQ_WORK_MESH_RECONCILE_STUB=1 \
  /bin/bash "$HQ/core/scripts/work-mesh-live-bind-trusted.sh" \
    --company acme --root "$HQ"; then
  fail "/bin/bash trusted bind failed without --session-id"
fi

META="$HQ/workspace/sessions/$SID/meta.yaml"
grep -qx 'company_slug: acme' "$META" \
  && pass "company bind succeeds under /bin/bash without --session-id" \
  || fail "company context was not stored on the .current session"

# The enqueue fallback can receive no bytes when its entropy pipeline is
# unavailable. Its empty copy must also stay portable under macOS Bash 3.2.
mkdir -p "$SANDBOX/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SANDBOX/bin/dd"
chmod +x "$SANDBOX/bin/dd"
if ! env PATH="$SANDBOX/bin:$PATH" /bin/bash -c '
  set -u
  . "$1"
  work_mesh_ulid >/dev/null
' bash "$ROOT/core/scripts/lib/work-mesh-enqueue.sh"; then
  fail "/bin/bash enqueue fallback failed with an empty entropy array"
fi
pass "enqueue fallback handles an empty array under /bin/bash"

echo "ALL PASS: work-mesh-live-bind-bash32"
