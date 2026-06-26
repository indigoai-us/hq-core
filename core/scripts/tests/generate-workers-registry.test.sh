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
elif ! grep -q 'id: "alpha"' "$r1/core/workers/registry.yaml" || ! grep -q 'id: "beta"' "$r1/core/workers/registry.yaml"; then
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
elif ! grep -qi 'duplicate worker id' <<<"$GEN_ERR"; then
  echo "FAIL[dup]: error did not mention duplicate id; stderr: $GEN_ERR" >&2; fails=$((fails+1))
elif [ ! -f "$reg2" ]; then
  echo "FAIL[dup]: registry.yaml not written (must quarantine, not total-block)" >&2; fails=$((fails+1))
elif grep -q 'id: "gemini-coder"' "$reg2"; then
  echo "FAIL[dup]: duplicated id 'gemini-coder' was registered (must be excluded)" >&2; fails=$((fails+1))
elif ! grep -q 'id: "keep"' "$reg2"; then
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
elif ! grep -qi 'missing required field' <<<"$GEN_ERR"; then
  echo "FAIL[missing]: error did not mention missing required field; stderr: $GEN_ERR" >&2; fails=$((fails+1))
elif [ ! -f "$reg3" ]; then
  echo "FAIL[missing]: registry.yaml not written (must quarantine, not total-block)" >&2; fails=$((fails+1))
elif grep -q 'id: "bad"' "$reg3"; then
  echo "FAIL[missing]: invalid worker 'bad' was registered (must be excluded)" >&2; fails=$((fails+1))
elif ! grep -q 'id: "good"' "$reg3"; then
  echo "FAIL[missing]: valid worker 'good' missing from registry (one bad worker blocked all)" >&2; fails=$((fails+1))
else
  echo "ok: missing-field worker quarantined, valid worker still registered (non-zero exit)"
fi
rm -rf "$r3"

# --- Test 4: PACK-SOURCED missing-field worker -> remedy points at `hq packs update` ---
# DEV-1796: a worker shipped by an installed pack lives under protected core/ (a
# symlink into core/packages/<pkg>/), so the user cannot edit it locally. The
# quarantine message must attribute the pack AND tell them to refresh the stale
# pack with `hq packs update` — NOT "fix the worker.yaml" (impossible for a
# protected pack copy).
r4="$(new_root)"
worker "$r4" "firstparty" "firstparty" "OpsWorker" "A valid first-party worker."
mkdir -p "$r4/core/packages/hq-pack-demo/workers/demo-team"
cat > "$r4/core/packages/hq-pack-demo/workers/demo-team/worker.yaml" <<'YAML'
worker:
  id: demo-team
  name: "demo-team"
  type: OpsWorker
  version: "1.0"
YAML
# Symlink the pack worker into core/workers/public so the generator's `find -L`
# discovers it and attribute_pack resolves the physical core/packages/ path.
ln -s "$r4/core/packages/hq-pack-demo/workers/demo-team" "$r4/core/workers/public/demo-team"
code="$(run_gen "$r4")"; GEN_ERR="$(cat "$r4/.err" 2>/dev/null || true)"
if [ "$code" = "0" ]; then
  echo "FAIL[pack]: expected non-zero exit flagging the quarantine, got 0" >&2; fails=$((fails+1))
elif ! grep -qi 'source: pack hq-pack-demo' <<<"$GEN_ERR"; then
  echo "FAIL[pack]: quarantine did not attribute the source pack; stderr: $GEN_ERR" >&2; fails=$((fails+1))
elif ! grep -qi 'hq packs update hq-pack-demo' <<<"$GEN_ERR"; then
  echo "FAIL[pack]: pack-sourced quarantine must advise the named 'hq packs update <pack>' form; stderr: $GEN_ERR" >&2; fails=$((fails+1))
elif grep -qi 'fix the worker.yaml and re-run' <<<"$GEN_ERR"; then
  echo "FAIL[pack]: pack-sourced quarantine wrongly told user to fix the protected worker.yaml; stderr: $GEN_ERR" >&2; fails=$((fails+1))
else
  echo "ok: pack-sourced quarantine advises 'hq packs update' (not 'fix the worker.yaml')"
fi
rm -rf "$r4"

# --- Test 5: FIRST-PARTY missing-field worker -> keeps "fix the worker.yaml" ---
# The pack-specific remedy must NOT leak onto first-party workers, which the user
# CAN edit directly.
r5="$(new_root)"
worker "$r5" "okw" "okw" "OpsWorker" "Valid."
mkdir -p "$r5/core/workers/public/local-bad"
cat > "$r5/core/workers/public/local-bad/worker.yaml" <<'YAML'
worker:
  id: local-bad
  name: "local-bad"
  type: OpsWorker
  version: "1.0"
YAML
run_gen "$r5" >/dev/null; GEN_ERR="$(cat "$r5/.err" 2>/dev/null || true)"
if ! grep -qi 'fix the worker.yaml and re-run' <<<"$GEN_ERR"; then
  echo "FAIL[firstparty]: first-party quarantine should keep 'fix the worker.yaml and re-run'; stderr: $GEN_ERR" >&2; fails=$((fails+1))
elif grep -qi 'hq packs update' <<<"$GEN_ERR"; then
  echo "FAIL[firstparty]: first-party quarantine wrongly advised 'hq packs update'; stderr: $GEN_ERR" >&2; fails=$((fails+1))
else
  echo "ok: first-party quarantine keeps 'fix the worker.yaml and re-run'"
fi
rm -rf "$r5"

# --- Test 6: multi-line `description: |` block -> flattened to ONE space-joined
# line with NO trailing space. Locks the batched yq reader's byte-parity with
# the old per-field reader, which relied on command substitution stripping the
# block scalar's trailing newline. Regression guard for the reindex yq-batch
# speedup (6 yq spawns/worker -> 1). Gated on yq: the awk fallback cannot parse
# block scalars (a separate, pre-existing limitation), so this asserts the yq
# path that production reindex always takes.
if command -v yq >/dev/null 2>&1; then
  r6="$(new_root)"
  mkdir -p "$r6/core/workers/public/multi"
  cat > "$r6/core/workers/public/multi/worker.yaml" <<'YAML'
worker:
  id: multi
  name: "multi"
  type: OpsWorker
  version: "1.0"
  description: |
    first line
    second line
    third line
YAML
  run_gen "$r6" >/dev/null
  reg6="$r6/core/workers/registry.yaml"
  if ! grep -q 'description: "first line second line third line"' "$reg6"; then
    echo "FAIL[multiline]: block scalar not flattened to single space-joined line without trailing space; got:" >&2
    grep 'description:' "$reg6" | grep -i line >&2 || true
    fails=$((fails+1))
  else
    echo "ok: multi-line description flattened to single line, no trailing space"
  fi
  rm -rf "$r6"
else
  echo "skip: multi-line description test (yq not on PATH)"
fi

if [ "$fails" -ne 0 ]; then
  echo "generate-workers-registry tests: $fails failure(s)" >&2
  exit 1
fi
echo "generate-workers-registry tests: ok"
