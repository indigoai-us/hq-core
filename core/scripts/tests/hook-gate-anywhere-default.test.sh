#!/usr/bin/env bash
# Run the real gate in a disposable layout, without host services or config.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/layout/.claude/hooks" "$TMP/layout/core/scripts" "$TMP/bin" "$TMP/resolved"
cp "${HQ_TEST_HOOK_GATE:-$ROOT/.claude/hooks/hook-gate.sh}" "$TMP/layout/.claude/hooks/hook-gate.sh"
# Omit hook-lib beside the gate to exercise Anywhere root resolution.
# An unregistered hook exits after resolution, before PATH augmentation.
cat > "$TMP/layout/core/scripts/resolve-hq-root.sh" <<'SH'
hq_resolve_root() {
  printf 'resolved\n' > "$PROBE_OUT"
  HQ_ROOT_RESULT="$PROBE_ROOT"
}
SH
for util in dirname cat; do
  real="$(command -v "$util")"
  printf '#!/bin/bash\nexec "%s" "$@"\n' "$real" > "$TMP/bin/$util"
  chmod +x "$TMP/bin/$util"
done
run_case() {
  local label="$1" expected="$2" output="$3" status="$4" override="$5" node_present="$6" script_present="$7"
  rm -f "$TMP/probe" "$TMP/bin/node" "$TMP/layout/core/scripts/hq-anywhere-runtime-flag.cjs"
  if [ "$node_present" = yes ]; then
    # shellcheck disable=SC2016 # Expanded by the fixture process.
    printf '#!/bin/bash\nprintf "%%s" "$FLAG_OUTPUT"\nexit "$FLAG_STATUS"\n' > "$TMP/bin/node"
    chmod +x "$TMP/bin/node"
  fi
  if [ "$script_present" = yes ]; then
    : > "$TMP/layout/core/scripts/hq-anywhere-runtime-flag.cjs"
  fi
  env -i HOME="$TMP/home" PATH="$TMP/bin" BASH_ENV=/dev/null \
    HQ_HOOK_PROFILE=minimal HQ_FLAG_HQ_ANYWHERE_RUNTIME="$override" \
    FLAG_OUTPUT="$output" FLAG_STATUS="$status" PROBE_OUT="$TMP/probe" PROBE_ROOT="$TMP/resolved" \
    /bin/bash "$TMP/layout/.claude/hooks/hook-gate.sh" fixture-unused "$TMP/unused" <<<'{}'
  local actual=off
  [ ! -f "$TMP/probe" ] || actual=on
  [ "$actual" = "$expected" ] || { echo "FAIL: $label expected $expected got $actual"; exit 1; }
  echo "PASS: $label"
}
run_case 'node missing' on '' 0 '' no yes
run_case 'flag script missing' on '' 0 '' yes no
run_case 'reader fails' on '' 1 '' yes yes
run_case 'reader prints false then fails' on false 1 '' yes yes
run_case 'explicit false' off false 0 '' yes yes
run_case 'explicit true' on true 0 '' yes yes
run_case 'empty response' on '' 0 '' yes yes
run_case 'unexpected response' on unknown 0 '' yes yes
run_case 'env false' off true 0 false yes yes
run_case 'env zero' off true 0 0 yes yes
run_case 'env false without node' off '' 0 false no yes
run_case 'env zero without reader' off '' 0 0 yes no
