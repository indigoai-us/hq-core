#!/usr/bin/env bash
# hq-core: public
# Regression: a box upgraded from pre-v15.0.121 can preserve an older
# core/scripts/work-mesh-lib.sh on disk that lacks wm_terminal_marker (and
# friends). The release-shipped work-mesh-close.sh calls those helpers
# unconditionally, so every SessionEnd printed "wm_terminal_marker: command
# not found" to stderr on 15.0.183 (customer-reported, Spice / hq-cli 5.332).
#
# The hook must stay silent and exit 0 when any required lib helper is
# missing. This test runs the hook against a deliberately-stale stub lib
# and asserts clean exit + empty stderr.
#
# bash-3.2 compatible; hermetic (temp HQ_ROOT; no network, no jq calls).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC_HOOK="$REPO_ROOT/core/hooks/work-mesh-close.sh"
[ -f "$SRC_HOOK" ] || { echo "FATAL: missing $SRC_HOOK" >&2; exit 1; }

bash -n "$SRC_HOOK"
echo "  ok:   bash -n work-mesh-close.sh"

SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "$SANDBOX/core/hooks" "$SANDBOX/core/scripts" \
         "$SANDBOX/workspace/sessions" "$SANDBOX/workspace/metrics" \
         "$SANDBOX/workspace/logs" "$SANDBOX/workspace/work-mesh"
cp "$SRC_HOOK" "$SANDBOX/core/hooks/work-mesh-close.sh"
chmod +x "$SANDBOX/core/hooks/work-mesh-close.sh"

# Stale lib: has the pre-v15.0.121 helpers but is missing wm_terminal_marker.
cat > "$SANDBOX/core/scripts/work-mesh-lib.sh" <<'LIB'
wm_hq_root()            { printf '%s' "${HQ_ROOT}"; }
wm_log_file()           { printf '%s/workspace/logs/work-mesh-hook.log' "$(wm_hq_root)"; }
wm_log()                { :; }
wm_safe_path_component(){ LC_ALL=C printf '%s\n' "${1:-}" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; }
wm_reconciled_marker()  { printf '%s/workspace/sessions/%s/work-mesh-reconciled-%s' "$(wm_hq_root)" "$1" "$2"; }
wm_copied_marker()      { printf '%s/workspace/sessions/%s/work-mesh-copied-%s' "$(wm_hq_root)" "$1" "$2"; }
# NOTE: wm_terminal_marker intentionally omitted — the drifted-release case.
LIB

run_one() {
  local mode="$1" tmperr out rc
  tmperr="$(mktemp)"
  set +e
  HQ_ROOT="$SANDBOX" HOME="$SANDBOX" \
    bash "$SANDBOX/core/hooks/work-mesh-close.sh" "$mode" test-session \
      >/dev/null 2>"$tmperr"
  rc=$?
  set -e
  out="$(cat "$tmperr")"
  rm -f "$tmperr"
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $mode returned rc=$rc (expected 0)" >&2
    exit 1
  fi
  if [ -n "$out" ]; then
    echo "FAIL: $mode printed to stderr with a drifted lib:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  echo "  ok:   $mode exits 0 silently when wm_terminal_marker is undefined"
}

run_one close
run_one sweep
run_one __close_bg__
run_one __sweep_bg__

echo "PASS: work-mesh-close.sh fails soft when the installed lib lacks required helpers"
