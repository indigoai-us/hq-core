#!/usr/bin/env bash
# Regression: block-qmd-model-download.sh denies cold foreground GGUF pulls.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/block-qmd-model-download.sh"
GATE="$ROOT/.claude/hooks/hook-gate.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/block-qmd-model.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

expect() {
  local want="$1" desc="$2" payload="$3"
  shift 3
  local rc=0
  printf '%s' "$payload" | "$@" bash "$HOOK" >/dev/null 2>"$TMP/err" || rc=$?
  if [ "$rc" -eq "$want" ]; then
    ok "$desc"
  else
    bad "$desc (want $want got $rc; err=$(tr '\n' ' ' < "$TMP/err"))"
  fi
}

vsearch_payload='{"tool_name":"Bash","tool_input":{"command":"qmd vsearch \"auth\" --json -n 5"}}'
search_payload='{"tool_name":"Bash","tool_input":{"command":"qmd search \"how to vsearch\" --json -n 5"}}'
query_payload='{"tool_name":"Bash","tool_input":{"command":"qmd query foo"}}'
embed_payload='{"tool_name":"Bash","tool_input":{"command":"qmd embed"}}'
pull_payload='{"tool_name":"Bash","tool_input":{"command":"qmd pull"}}'
update_payload='{"tool_name":"Bash","tool_input":{"command":"qmd update"}}'
bg_payload='{"tool_name":"Bash","tool_input":{"command":"qmd vsearch foo","run_in_background":true}}'
echo_payload='{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'

expect 2 "cold vsearch blocks" "$vsearch_payload" env QMD_MODELS_DIR="$TMP/empty"
expect 2 "cold query blocks" "$query_payload" env QMD_MODELS_DIR="$TMP/empty"
expect 2 "cold embed blocks" "$embed_payload" env QMD_MODELS_DIR="$TMP/empty"
expect 2 "cold pull blocks" "$pull_payload" env QMD_MODELS_DIR="$TMP/empty"
expect 0 "qmd search with vsearch in query allowed" "$search_payload" env QMD_MODELS_DIR="$TMP/empty"
expect 0 "qmd update allowed" "$update_payload" env QMD_MODELS_DIR="$TMP/empty"
expect 0 "unrelated bash allowed" "$echo_payload" env QMD_MODELS_DIR="$TMP/empty"
expect 0 "background vsearch allowed" "$bg_payload" env QMD_MODELS_DIR="$TMP/empty"
expect 0 "escape hatch allows cold vsearch" "$vsearch_payload" env HQ_ALLOW_QMD_MODEL_DOWNLOAD=1 QMD_MODELS_DIR="$TMP/empty"

mkdir -p "$TMP/ready"
dd if=/dev/zero of="$TMP/ready/embeddinggemma-300M-Q8_0.gguf" bs=1024 count=1025 status=none 2>/dev/null \
  || dd if=/dev/zero of="$TMP/ready/embeddinggemma-300M-Q8_0.gguf" bs=1024 count=1025
expect 0 "cached GGUF allows vsearch" "$vsearch_payload" env QMD_MODELS_DIR="$TMP/ready"

# Tiny placeholder is treated as not ready.
mkdir -p "$TMP/tiny"
printf 'x' > "$TMP/tiny/embeddinggemma-300M-Q8_0.gguf"
expect 2 "tiny placeholder still blocks" "$vsearch_payload" env QMD_MODELS_DIR="$TMP/tiny"

# stderr names the BM25 fallback
QMD_MODELS_DIR="$TMP/empty" bash "$HOOK" <<<"$vsearch_payload" >/dev/null 2>"$TMP/err"
if grep -q 'qmd search' "$TMP/err" && grep -q 'hq index background' "$TMP/err"; then
  ok "block message steers to qmd search + hq index background"
else
  bad "block message missing fallback (err=$(cat "$TMP/err"))"
fi

# Gate: all three profiles actually run the hook (not pass-through).
payload_gate='{"tool_name":"Bash","tool_input":{"command":"qmd vsearch foo"}}'
for p in minimal standard strict; do
  rc=0
  printf '%s' "$payload_gate" \
    | HQ_HOOK_PROFILE="$p" CLAUDE_PROJECT_DIR="$ROOT" QMD_MODELS_DIR="$TMP/empty" \
      bash "$GATE" block-qmd-model-download "$HOOK" >/dev/null 2>"$TMP/err" || rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "hook-gate profile $p blocks"
  else
    bad "hook-gate profile $p want 2 got $rc"
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "ALL PASS: block-qmd-model-download ($pass)"
  exit 0
fi
echo "FAILURES: block-qmd-model-download ($fail failed, $pass passed)"
exit 1
