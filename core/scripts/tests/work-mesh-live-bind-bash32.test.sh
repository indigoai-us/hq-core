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

MARKER="$SANDBOX/home/.hq/work-context/sessions/$SID.live-binding"
if [ -f "$MARKER" ] && grep -qx 'authority=trusted' "$MARKER"; then
  fail "company-only bind recorded trusted authority"
fi
pass "company-only bind does not record trusted authority"

if ! env \
  HOME="$SANDBOX/home" \
  HQ_ROOT="$HQ" \
  CLAUDE_PROJECT_DIR="$HQ" \
  HQ_SESSION_ID="$SID" \
  HQ_HQ_SESSION_NO_CLI=1 \
  HQ_WORK_MESH_RECONCILE_STUB=1 \
  /bin/bash "$HQ/core/scripts/work-mesh-live-bind-trusted.sh" \
    --company acme --project install-flow-rethink --task US-002 \
    --session "$SID" --root "$HQ" --no-reconcile; then
  fail "/bin/bash trusted project bind failed"
fi
grep -qx 'project=install-flow-rethink' "$MARKER" \
  || fail "project bind did not write the live-binding marker"
grep -qx 'authority=trusted' "$MARKER" \
  || fail "project bind did not record trusted authority"
grep -qx 'task=US-002' "$MARKER" \
  || fail "project bind did not keep the task on the marker"
pass "project bind records trusted authority on the live-binding marker"

# Trusted authority needs a session id the caller owns: --session or the
# process env. workspace/sessions/.current is last-writer-wins and can name
# another session, so a bind resolved only from it gets no authority.
OBS_TMP="$SANDBOX/obs-tmp"
run_bind() {
  local bash_bin="$1"; shift
  rm -rf "$OBS_TMP"; mkdir -p "$OBS_TMP"
  env \
    HOME="$SANDBOX/home" \
    TMPDIR="$OBS_TMP" \
    HQ_ROOT="$HQ" \
    CLAUDE_PROJECT_DIR="$HQ" \
    HQ_SESSION_ID= \
    CLAUDE_CODE_SESSION_ID= \
    CLAUDE_SESSION_ID= \
    CODEX_SESSION_ID= \
    CODEX_THREAD_ID= \
    GROK_SESSION_ID= \
    HQ_HQ_SESSION_NO_CLI=1 \
    HQ_WORK_MESH_RECONCILE_STUB=1 \
    "$@" \
    "$bash_bin" "$HQ/core/scripts/work-mesh-live-bind-trusted.sh" \
      --company acme --project install-flow-rethink --task US-002 \
      ${BIND_SESSION_ARGS:+$BIND_SESSION_ARGS} --root "$HQ"
}
obs_file() { find "$OBS_TMP/hq-work-mesh-obs" -name "$SID.bind.*.json" 2>/dev/null | head -1; }

for BASH_BIN in /bin/bash bash; do
  rm -f "$MARKER"
  BIND_SESSION_ARGS="" run_bind "$BASH_BIN" \
    || fail "$BASH_BIN .current-only project bind failed"
  grep -qx 'project: install-flow-rethink' "$META" \
    || fail "$BASH_BIN .current-only bind did not store the project"
  if [ -f "$MARKER" ] && grep -qx 'authority=trusted' "$MARKER"; then
    fail "$BASH_BIN .current-only bind recorded trusted authority on the marker"
  fi
  OBS="$(obs_file)"
  [ -n "$OBS" ] || fail "$BASH_BIN .current-only bind wrote no observation"
  if grep -q '"authority"' "$OBS"; then
    fail "$BASH_BIN .current-only bind sent trusted authority"
  fi
  pass "$BASH_BIN: a session id read only from .current gets no trusted authority"

  rm -f "$MARKER"
  BIND_SESSION_ARGS="" run_bind "$BASH_BIN" GROK_SESSION_ID="$SID" \
    || fail "$BASH_BIN GROK_SESSION_ID project bind failed"
  grep -qx 'authority=trusted' "$MARKER" \
    || fail "$BASH_BIN GROK_SESSION_ID bind did not record trusted authority"
  OBS="$(obs_file)"
  [ -n "$OBS" ] && grep -q '"authority":"trusted"' "$OBS" \
    || fail "$BASH_BIN GROK_SESSION_ID bind did not send trusted authority"
  pass "$BASH_BIN: GROK_SESSION_ID is a caller-owned session id"

  rm -f "$MARKER" "$META"
  if BIND_SESSION_ARGS="--session bad/../id" run_bind "$BASH_BIN" 2>/dev/null; then
    fail "$BASH_BIN bind with an invalid --session succeeded"
  fi
  [ ! -e "$SANDBOX/home/.hq/work-context/sessions/bad" ] \
    || fail "$BASH_BIN invalid --session reached the marker path"
  [ ! -e "$SANDBOX/home/.hq/work-context/id.live-binding" ] \
    || fail "$BASH_BIN invalid --session escaped the sessions directory"
  [ ! -e "$MARKER" ] \
    || fail "$BASH_BIN invalid --session fell back to the .current session marker"
  [ ! -e "$META" ] \
    || fail "$BASH_BIN invalid --session wrote meta for the .current session"
  [ -z "$(obs_file)" ] \
    || fail "$BASH_BIN invalid --session wrote an observation"
  pass "$BASH_BIN: an invalid --session stops the bind"

  # A trusted bind back to a project the marker no longer names rebinds the
  # marker and stamps it trusted.
  mkdir -p "$(dirname "$MARKER")"
  printf 'companySlug=acme\nproject=other-project\ntask=US-009\nauthority=trusted\n' >"$MARKER"
  BIND_SESSION_ARGS="--session $SID" run_bind "$BASH_BIN" \
    || fail "$BASH_BIN revert bind failed"
  grep -qx 'project=install-flow-rethink' "$MARKER" \
    || fail "$BASH_BIN revert bind left the marker on the other project"
  grep -qx 'task=US-002' "$MARKER" \
    || fail "$BASH_BIN revert bind did not move the task"
  grep -qx 'authority=trusted' "$MARKER" \
    || fail "$BASH_BIN revert bind did not stamp trusted authority"
  pass "$BASH_BIN: a trusted bind back to another project rebinds and stamps the marker"
done

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
