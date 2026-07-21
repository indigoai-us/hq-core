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
BASH_BIN="$(command -v bash)"

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

run_gen() { # <root> [PATH] -> echoes exit code; stderr captured to <root>/.err on disk
  local root="$1" path="${2:-$PATH}" rc
  PATH="$path" HQ_ROOT="$root" "$BASH_BIN" "$root/core/scripts/generate-workers-registry.sh" >/dev/null 2>"$root/.err" && rc=0 || rc=$?
  echo "$rc"
}

path_without_yq() { # <root> -> minimal generator PATH with no yq executable
  local root="$1" bin="$1/.no-yq-bin" cmd
  mkdir -p "$bin"
  for cmd in awk cp cut date diff dirname find grep mkdir mktemp mv rm sed sort uniq; do
    ln -s "$(command -v "$cmd")" "$bin/$cmd"
  done
  echo "$bin"
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

# --- Test 1b: no-yq fallback -> exit 0, company worker registered ---
# The fallback must terminate its delimiter-separated record with a newline.
# Otherwise `read` assigns every field but returns 1 at EOF, and `set -e` exits
# the generator before it writes registry.yaml.
r1b="$(new_root)"
mkdir -p "$r1b/companies/acme/workers/company-ops"
cat > "$r1b/companies/acme/workers/company-ops/worker.yaml" <<'YAML'
worker:
  id: company-ops
  name: "company-ops"
  description: "Company operations worker."
  type: OpsWorker
  company: acme
  version: "1.0"
YAML
code="$(run_gen "$r1b" "$(path_without_yq "$r1b")")"; GEN_ERR="$(cat "$r1b/.err" 2>/dev/null || true)"
reg1b="$r1b/core/workers/registry.yaml"
if [ "$code" != "0" ]; then
  echo "FAIL[no-yq]: expected exit 0, got $code; stderr: $GEN_ERR" >&2; fails=$((fails+1))
elif [ ! -f "$reg1b" ]; then
  echo "FAIL[no-yq]: registry.yaml not written" >&2; fails=$((fails+1))
elif ! grep -q 'id: "company-ops"' "$reg1b"; then
  echo "FAIL[no-yq]: company worker 'company-ops' missing from registry" >&2; fails=$((fails+1))
else
  echo "ok: no-yq fallback registers a company worker (exit 0)"
fi
rm -rf "$r1b"

# --- Test 2: duplicate id -> graceful last-wins, registry still generates, EXIT 0 ---
# DEV-1845 (supersedes the DEV-1718 exclude-all + non-zero policy): a duplicate id
# must NOT hard-fail the generator or drop the id entirely — that permanently
# staled registry.yaml (id vanished AND non-zero exit read as "generation
# failed", so new workers stopped appearing). The generator now KEEPS one copy
# deterministically (lexicographically-first path), SKIPS the rest with a loud
# warning, and exits NON-FATAL so the registry keeps regenerating.
r2="$(new_root)"
worker "$r2" "gemini-coder-a" "gemini-coder" "OpsWorker" "Gemini coder (dir A)."
worker "$r2" "gemini-coder-b" "gemini-coder" "OpsWorker" "Gemini coder (dir B)."
worker "$r2" "keep"           "keep"         "OpsWorker" "A valid unique worker."
code="$(run_gen "$r2")"; GEN_ERR="$(cat "$r2/.err" 2>/dev/null || true)"
reg2="$r2/core/workers/registry.yaml"
dup_count="$(grep -c 'id: "gemini-coder"' "$reg2" 2>/dev/null || true)"
if [ "$code" != "0" ]; then
  echo "FAIL[dup]: expected NON-FATAL exit 0 (graceful degradation), got $code; stderr: $GEN_ERR" >&2; fails=$((fails+1))
elif ! grep -qi 'duplicate worker id' <<<"$GEN_ERR"; then
  echo "FAIL[dup]: warning did not mention duplicate id; stderr: $GEN_ERR" >&2; fails=$((fails+1))
elif ! grep -qi 'SKIPPING' <<<"$GEN_ERR"; then
  echo "FAIL[dup]: warning did not name the skipped copy; stderr: $GEN_ERR" >&2; fails=$((fails+1))
elif [ ! -f "$reg2" ]; then
  echo "FAIL[dup]: registry.yaml not written" >&2; fails=$((fails+1))
elif [ "$dup_count" != "1" ]; then
  echo "FAIL[dup]: expected exactly ONE 'gemini-coder' row (last-wins), got '$dup_count'" >&2; fails=$((fails+1))
elif ! grep -q 'Gemini coder (dir A)' "$reg2"; then
  echo "FAIL[dup]: expected the lexicographically-first path (dir A) to win" >&2; fails=$((fails+1))
elif ! grep -q 'id: "keep"' "$reg2"; then
  echo "FAIL[dup]: valid worker 'keep' missing from registry" >&2; fails=$((fails+1))
else
  echo "ok: duplicate id degrades gracefully (last-wins, warned, exit 0, valid worker registered)"
fi
rm -rf "$r2"

# --- Test 2b: a duplicate id does NOT block a NEW (company) worker from appearing ---
# The core contract behind DEV-1845: an operator adding a brand-new worker must
# see it register even while an unrelated duplicate-id clash exists elsewhere.
r2b="$(new_root)"
worker "$r2b" "dupe-a" "dupe" "OpsWorker" "Dupe A."
worker "$r2b" "dupe-b" "dupe" "OpsWorker" "Dupe B."
mkdir -p "$r2b/companies/acme/workers/newbie"
cat > "$r2b/companies/acme/workers/newbie/worker.yaml" <<'YAML'
worker:
  id: newbie
  name: "newbie"
  description: "A brand-new company worker."
  type: OpsWorker
  version: "1.0"
YAML
code="$(run_gen "$r2b")"; GEN_ERR="$(cat "$r2b/.err" 2>/dev/null || true)"
reg2b="$r2b/core/workers/registry.yaml"
if [ "$code" != "0" ]; then
  echo "FAIL[dup-newworker]: expected exit 0, got $code; stderr: $GEN_ERR" >&2; fails=$((fails+1))
elif ! grep -q 'id: "newbie"' "$reg2b"; then
  echo "FAIL[dup-newworker]: new company worker 'newbie' did not appear despite unrelated duplicate" >&2; fails=$((fails+1))
else
  echo "ok: new company worker still registers alongside an unrelated duplicate-id clash"
fi
rm -rf "$r2b"

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

# --- Test 7: personal/workers is walked DIRECTLY (no reindex symlink mirror) ---
# personal is now the sole read source for the personal overlay: a worker.yaml
# under personal/workers/<name>/ must register on its own, without any
# core/workers/<name> -> ../../personal/workers/<name> symlink present. Guards
# the retirement of the mirror (the generator's find must include personal/workers).
r7="$(new_root)"
worker "$r7" "shipped" "shipped" "OpsWorker" "A shipped core worker."
mkdir -p "$r7/personal/workers/my-helper"
cat > "$r7/personal/workers/my-helper/worker.yaml" <<'YAML'
worker:
  id: my-helper
  name: "my-helper"
  description: "A personal-overlay worker."
  type: OpsWorker
  version: "1.0"
YAML
code="$(run_gen "$r7")"; GEN_ERR="$(cat "$r7/.err" 2>/dev/null || true)"
reg7="$r7/core/workers/registry.yaml"
if [ "$code" != "0" ]; then
  echo "FAIL[personal]: expected exit 0, got $code; stderr: $GEN_ERR" >&2; fails=$((fails+1))
elif ! grep -q 'id: "my-helper"' "$reg7"; then
  echo "FAIL[personal]: personal/workers worker 'my-helper' missing from registry" >&2; fails=$((fails+1))
elif ! grep -q 'id: "shipped"' "$reg7"; then
  echo "FAIL[personal]: shipped core worker missing — both core and personal must surface" >&2; fails=$((fails+1))
elif ! grep -q 'personal/workers/my-helper/' "$reg7"; then
  echo "FAIL[personal]: personal worker registered under an unexpected path" >&2; fails=$((fails+1))
else
  echo "ok: personal/workers registers directly (no mirror), alongside core workers"
fi
rm -rf "$r7"

if [ "$fails" -ne 0 ]; then
  echo "generate-workers-registry tests: $fails failure(s)" >&2
  exit 1
fi
echo "generate-workers-registry tests: ok"
