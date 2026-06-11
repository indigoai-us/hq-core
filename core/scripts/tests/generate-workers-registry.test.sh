#!/usr/bin/env bash
# hq-core: public
# Regression tests for core/scripts/generate-workers-registry.sh.
#
# DEV-1735: a v15.0.9 release shipped worker content with duplicate worker ids
# (gemini-coder / gemini-reviewer each in two dirs) plus workers missing
# required fields.
#
# DEV-1718: the original fail-closed behavior was TOTAL — one pack's bad or
# duplicate metadata refused to write the WHOLE registry, silently blocking ALL
# new worker registration. The generator now QUARANTINES the offending entries
# (fail-closed on them) while still writing the registry for every VALID worker,
# and reports loudly which entry is at fault (non-zero exit signals the problem,
# but the partial registry is written). These tests lock the quarantine semantics
# AND the happy path so a regression in either direction is caught.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$ROOT/core/scripts/generate-workers-registry.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found" >&2; exit 1; }

new_root() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/core/scripts" "$d/core/workers/public"
  cp "$SCRIPT" "$d/core/scripts/generate-workers-registry.sh"
  chmod +x "$d/core/scripts/generate-workers-registry.sh"
  echo "$d"
}

worker() { # <root> <dir> <id> <type> <desc>
  local root="$1" dir="$2" id="$3" type="$4" desc="$5"
  mkdir -p "$root/core/workers/public/$dir"
  cat > "$root/core/workers/public/$dir/worker.yaml" <<YAML
worker:
  id: $id
  name: "$id"
  description: "$desc"
  type: $type
  version: "1.0"
YAML
}

run_gen() { # <root> -> echoes exit code; stderr captured to <root>/.err on disk
  local root="$1" rc
  HQ_ROOT="$root" bash "$root/core/scripts/generate-workers-registry.sh" >/dev/null 2>"$root/.err" && rc=0 || rc=$?
  echo "$rc"
}

fails=0

# --- Test 1: clean unique worker set -> exit 0, registry written with both ---
r1="$(new_root)"
worker "$r1" "alpha" "alpha" "OpsWorker" "Alpha worker."
worker "$r1" "beta"  "beta"  "OpsWorker" "Beta worker."
code="$(run_gen "$r1")"; GEN_ERR="$(cat "$r1/.err" 2>/dev/null || true)"
if [ "$code" != "0" ]; then
  echo "FAIL[clean]: expected exit 0, got $code; stderr: $GEN_ERR" >&2; fails=$((fails+1))
elif [ ! -f "$r1/core/workers/registry.yaml" ]; then
  echo "FAIL[clean]: registry.yaml not written" >&2; fails=$((fails+1))
elif ! grep -q 'id: alpha' "$r1/core/workers/registry.yaml" || ! grep -q 'id: beta' "$r1/core/workers/registry.yaml"; then
  echo "FAIL[clean]: registry missing expected worker ids" >&2; fails=$((fails+1))
else
  echo "ok: clean worker set generates registry (exit 0)"
fi
rm -rf "$r1"

# --- Test 2: duplicate id -> quarantine BOTH copies, still write valid workers ---
# DEV-1718: a duplicate id must NOT block the whole registry. Both copies of the
# clashing id are excluded (never pick a winner -> no silent shadowing), but the
# unique 'keep' worker still registers. Exit is non-zero to flag the problem.
r2="$(new_root)"
worker "$r2" "gemini-coder-a" "gemini-coder" "OpsWorker" "Gemini coder (dir A)."
worker "$r2" "gemini-coder-b" "gemini-coder" "OpsWorker" "Gemini coder (dir B)."
worker "$r2" "keep"           "keep"         "OpsWorker" "A valid unique worker."
code="$(run_gen "$r2")"; GEN_ERR="$(cat "$r2/.err" 2>/dev/null || true)"
reg2="$r2/core/workers/registry.yaml"
if [ "$code" = "0" ]; then
  echo "FAIL[dup]: expected non-zero exit flagging the duplicate, got 0" >&2; fails=$((fails+1))
elif ! printf '%s' "$GEN_ERR" | grep -qi 'duplicate worker id'; then
  echo "FAIL[dup]: error did not mention duplicate id; stderr: $GEN_ERR" >&2; fails=$((fails+1))
elif [ ! -f "$reg2" ]; then
  echo "FAIL[dup]: registry.yaml not written (must quarantine, not total-block)" >&2; fails=$((fails+1))
elif grep -q 'id: gemini-coder' "$reg2"; then
  echo "FAIL[dup]: duplicated id 'gemini-coder' was registered (must be excluded)" >&2; fails=$((fails+1))
elif ! grep -q 'id: keep' "$reg2"; then
  echo "FAIL[dup]: valid worker 'keep' missing from registry (one bad id blocked all)" >&2; fails=$((fails+1))
else
  echo "ok: duplicate id quarantined, valid worker still registered (non-zero exit)"
fi
rm -rf "$r2"

# --- Test 3: worker missing a required field -> quarantine it, register the rest ---
r3="$(new_root)"
worker "$r3" "good" "good" "OpsWorker" "Good worker."
mkdir -p "$r3/core/workers/public/bad"
cat > "$r3/core/workers/public/bad/worker.yaml" <<'YAML'
worker:
  id: bad
  name: "bad"
  type: OpsWorker
  version: "1.0"
YAML
code="$(run_gen "$r3")"; GEN_ERR="$(cat "$r3/.err" 2>/dev/null || true)"
reg3="$r3/core/workers/registry.yaml"
if [ "$code" = "0" ]; then
  echo "FAIL[missing]: expected non-zero exit flagging the missing field, got 0" >&2; fails=$((fails+1))
elif ! printf '%s' "$GEN_ERR" | grep -qi 'missing required field'; then
  echo "FAIL[missing]: error did not mention missing required field; stderr: $GEN_ERR" >&2; fails=$((fails+1))
elif [ ! -f "$reg3" ]; then
  echo "FAIL[missing]: registry.yaml not written (must quarantine, not total-block)" >&2; fails=$((fails+1))
elif grep -q 'id: bad' "$reg3"; then
  echo "FAIL[missing]: invalid worker 'bad' was registered (must be excluded)" >&2; fails=$((fails+1))
elif ! grep -q 'id: good' "$reg3"; then
  echo "FAIL[missing]: valid worker 'good' missing from registry (one bad worker blocked all)" >&2; fails=$((fails+1))
else
  echo "ok: missing-field worker quarantined, valid worker still registered (non-zero exit)"
fi
rm -rf "$r3"

if [ "$fails" -ne 0 ]; then
  echo "generate-workers-registry tests: $fails failure(s)" >&2
  exit 1
fi
echo "generate-workers-registry tests: ok"
