#!/usr/bin/env bash
# Regression coverage for core/scripts/qmd-ready.sh — the gate skills run
# before `qmd vsearch` / `qmd query` so a fresh/constrained machine never
# blocks on qmd's lazy ~1.3GB GGUF model download mid-session (verified
# new-user report). Asserts:
#   (a) not ready when qmd is missing from PATH
#   (b) not ready when qmd is installed but models are absent / partial
#   (c) ready when all model roles (embed, expansion, rerank) are cached,
#       including the union across two cache dirs and both filename shapes
#   (d) the script NEVER invokes qmd itself (an invocation could trigger
#       the very download the gate exists to prevent)
#   (e) usage errors exit 2

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

SCRIPT="${ROOT}/core/scripts/qmd-ready.sh"
[[ -f "$SCRIPT" ]] || fail "qmd-ready.sh not found at $SCRIPT"

# Fake qmd stub: records every invocation. The gate must never call it.
FAKEBIN="${TMP}/bin"
mkdir -p "$FAKEBIN"
cat > "${FAKEBIN}/qmd" <<STUB
#!/bin/sh
echo "invoked \$*" >> "${TMP}/qmd-invocations.log"
exit 0
STUB
chmod +x "${FAKEBIN}/qmd"

DIR_A="${TMP}/models-a"
DIR_B="${TMP}/models-b"
mkdir -p "$DIR_A" "$DIR_B"

# Isolated PATH (system utils, no real qmd) + isolated model dirs for all cases.
BASE_PATH="/usr/bin:/bin"
MODEL_DIRS="${DIR_A}:${DIR_B}"

run_gate() { # run_gate <with_qmd:0|1> [args...] -> echoes exit code
  local with_qmd="$1"; shift
  local path="$BASE_PATH"
  [[ "$with_qmd" == "1" ]] && path="${FAKEBIN}:${BASE_PATH}"
  local rc=0
  PATH="$path" QMD_READY_MODEL_DIRS="$MODEL_DIRS" bash "$SCRIPT" "$@" > "${TMP}/out.log" 2>&1 || rc=$?
  echo "$rc"
}

# --- Case A: qmd not installed -> exit 1, explain says so -------------------
if command -v /usr/bin/qmd >/dev/null 2>&1 || command -v /bin/qmd >/dev/null 2>&1; then
  echo "SKIP-CASE-A: a real qmd exists in /usr/bin or /bin on this machine"
else
  rc="$(run_gate 0 --explain)"
  [[ "$rc" == "1" ]] || fail "Case A: expected exit 1 without qmd, got $rc"
  grep -qi "not installed" "${TMP}/out.log" || fail "Case A: --explain should mention qmd is not installed, got: $(cat "${TMP}/out.log")"
fi

# --- Case B: qmd installed, no models cached -> exit 1 ----------------------
rc="$(run_gate 1 --explain)"
[[ "$rc" == "1" ]] || fail "Case B: expected exit 1 with empty model dirs, got $rc"
grep -qi "query-expansion" "${TMP}/out.log" || fail "Case B: --explain should list the missing query-expansion model, got: $(cat "${TMP}/out.log")"

# --- Case C: partial cache (embedding only) -> still exit 1 -----------------
# hf_-prefixed shape (as in ~/.cache/qmd/models on qmd 2.x)
touch "${DIR_A}/hf_ggml-org_embeddinggemma-300M-Q8_0.gguf"
rc="$(run_gate 1 --explain)"
[[ "$rc" == "1" ]] || fail "Case C: expected exit 1 with only the embedding model cached, got $rc"
grep -qi "query-expansion" "${TMP}/out.log" || fail "Case C: --explain should still list query-expansion as missing"
grep -qi "rerank" "${TMP}/out.log" || fail "Case C: --explain should still list reranker as missing"

# --- Case D: all roles cached across BOTH dirs and BOTH name shapes -> 0 ----
# bare shape (as in ~/Library/Caches/qmd/models) in dir B for the other roles
touch "${DIR_B}/qwen3-reranker-0.6b-q8_0.gguf"
touch "${DIR_B}/hf_tobil_qmd-query-expansion-1.7B-q4_k_m.gguf"
rc="$(run_gate 1)"
[[ "$rc" == "0" ]] || fail "Case D: expected exit 0 with all models cached, got $rc (out: $(cat "${TMP}/out.log"))"
rc="$(run_gate 1 --explain)"
[[ "$rc" == "0" ]] || fail "Case D: expected exit 0 with --explain too, got $rc"
grep -qi "ready" "${TMP}/out.log" || fail "Case D: --explain should say ready"

# --- Case E: the gate never invoked qmd across any case ---------------------
[[ ! -f "${TMP}/qmd-invocations.log" ]] \
  || fail "Case E: qmd-ready.sh invoked qmd ($(cat "${TMP}/qmd-invocations.log")) — the gate must be pure filesystem checks"

# --- Case F: unknown flag -> exit 2 ------------------------------------------
rc="$(run_gate 1 --bogus-flag)"
[[ "$rc" == "2" ]] || fail "Case F: expected exit 2 on unknown flag, got $rc"

echo "PASS: qmd-ready (missing qmd -> partial cache -> full cache union -> no qmd invocation -> usage)"
