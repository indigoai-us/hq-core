#!/usr/bin/env bash
# A trusted bind writes the live-binding marker before mesh state catches up.
# The next hook must keep that marker only when it carries trusted authority
# and is still fresh. Any newer timestamp is not enough, and an old trusted
# marker must not hold a session whose reconcile never runs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$ROOT/core/scripts/lib/work-mesh-live-rebind.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -f "$LIB" ] || fail "missing rebind lib"
command -v jq >/dev/null 2>&1 || fail "jq is required"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/work-mesh-trusted-hold.XXXXXX")"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# shellcheck disable=SC1090
. "$LIB"

# Defined before any rebind. On the old lib, case 1 reaches work_mesh_live_rebind
# and this stub lets it finish, so the assertion below prints FAIL instead of
# set -e exiting with no output.
work_mesh_enqueue() { return 0; }

SID="sid-trusted-hold"
export HOME="$SANDBOX/home"
export WORK_MESH_HOME="$SANDBOX/home"
mkdir -p "$WORK_MESH_HOME/.hq/work-context/sessions"
STATE="$WORK_MESH_HOME/.hq/work-context/sessions/$SID.json"
MARKER="$WORK_MESH_HOME/.hq/work-context/sessions/$SID.live-binding"

marker_project() {
  awk -F= '/^project=/{print $2; exit}' "$MARKER"
}
marker_task() {
  awk -F= '/^task=/{print $2; exit}' "$MARKER"
}
marker_authority() {
  awk -F= '/^authority=/{print $2; exit}' "$MARKER"
}

# State is old. The trusted marker is newer and not expired, so the hook holds.
printf '%s\n' '{"companySlug":"indigo","projectId":"harness2-vs-hq","taskId":"US-001"}' >"$STATE"
touch -t 202001010000 "$STATE"
printf 'companySlug=indigo\nproject=install-flow-rethink\ntask=US-002\nauthority=trusted\n' >"$MARKER"
touch "$MARKER"

work_mesh_live_maybe_rebind_from_state "$SID"
[ "$(marker_project)" = "install-flow-rethink" ] \
  || fail "newer trusted marker was overwritten with harness2-vs-hq"
[ "$(marker_task)" = "US-002" ] || fail "trusted marker task changed"
pass "fresh trusted marker survives a hook while state still names the old project"

# A newer marker without trusted authority must not hold.
printf '%s\n' '{"companySlug":"indigo","projectId":"harness2-vs-hq","taskId":"US-001"}' >"$STATE"
touch -t 202001010000 "$STATE"
printf 'companySlug=indigo\nproject=install-flow-rethink\ntask=US-002\n' >"$MARKER"
touch "$MARKER"
work_mesh_live_maybe_rebind_from_state "$SID"
[ "$(marker_project)" = "harness2-vs-hq" ] \
  || fail "newer marker without trusted authority was held"
[ "$(marker_task)" = "US-001" ] || fail "untrusted marker kept its task"
pass "a newer marker without trusted authority follows mesh state"

# Trusted authority that is older than the hold window must not hold,
# even when the marker is still newer than state.
printf '%s\n' '{"companySlug":"indigo","projectId":"harness2-vs-hq","taskId":"US-001"}' >"$STATE"
touch -t 202001010000 "$STATE"
printf 'companySlug=indigo\nproject=install-flow-rethink\ntask=US-002\nauthority=trusted\n' >"$MARKER"
touch -t 202001020000 "$MARKER"
work_mesh_live_maybe_rebind_from_state "$SID"
[ "$(marker_project)" = "harness2-vs-hq" ] \
  || fail "expired trusted marker was held"
[ "$(marker_task)" = "US-001" ] || fail "expired trusted marker kept its task"
pass "an expired trusted marker follows mesh state"

printf '%s\n' '{"companySlug":"indigo","projectId":"install-flow-rethink","taskId":"US-009","projectBindAuthority":"trusted"}' >"$STATE"
touch -t 202001030000 "$STATE"
printf 'companySlug=indigo\nproject=install-flow-rethink\ntask=US-002\nauthority=trusted\n' >"$MARKER"
touch -t 202001020000 "$MARKER"
work_mesh_live_maybe_rebind_from_state "$SID"
[ "$(marker_project)" = "install-flow-rethink" ] || fail "marker left the trusted project"
[ "$(marker_task)" = "US-009" ] || fail "marker did not follow the newer trusted state"
pass "marker follows state once the trusted project is stored and newer"

printf 'companySlug=indigo\nproject=harness2-vs-hq\ntask=US-001\n' >"$MARKER"
touch -t 202001010000 "$MARKER"
touch -t 202001030000 "$STATE"
work_mesh_live_maybe_rebind_from_state "$SID"
[ "$(marker_project)" = "install-flow-rethink" ] \
  || fail "older marker was not updated from the newer trusted state"
[ "$(marker_task)" = "US-009" ] || fail "older marker kept the foreign task"
pass "an older marker follows the newer trusted state"

# A trusted marker with a future mtime must not hold. A skewed or touched
# file would otherwise hold until state becomes newer than it.
printf '%s\n' '{"companySlug":"indigo","projectId":"harness2-vs-hq","taskId":"US-001"}' >"$STATE"
touch -t 202001010000 "$STATE"
printf 'companySlug=indigo\nproject=install-flow-rethink\ntask=US-002\nauthority=trusted\n' >"$MARKER"
touch -t 209901010000 "$MARKER"
work_mesh_live_maybe_rebind_from_state "$SID"
[ "$(marker_project)" = "harness2-vs-hq" ] \
  || fail "trusted marker with a future mtime was held"
pass "a trusted marker with a future mtime follows mesh state"

work_mesh_live_write_binding_marker "$SID" indigo harness2-vs-hq US-001
[ -z "$(marker_authority)" ] || fail "marker without authority recorded authority=$(marker_authority)"
work_mesh_live_write_binding_marker "$SID" indigo install-flow-rethink US-002 trusted
[ "$(marker_authority)" = "trusted" ] \
  || fail "write_binding_marker did not record authority=trusted"
[ "$(marker_project)" = "install-flow-rethink" ] \
  || fail "write_binding_marker dropped the project"
[ "$(marker_task)" = "US-002" ] || fail "write_binding_marker dropped the task"
pass "write_binding_marker records authority=trusted only when asked"

# The marker is written through a temp file and renamed into place.
leftover="$(find "$WORK_MESH_HOME/.hq/work-context/sessions" -name "$SID.live-binding.tmp.*" | head -1)"
[ -z "$leftover" ] || fail "marker write left a temp file: $leftover"
grep -c '^project=' "$MARKER" | grep -qx 1 || fail "marker has more than one project line"
pass "marker write leaves no temp file behind"

echo "ALL PASS: work-mesh-trusted-bind-holds"
