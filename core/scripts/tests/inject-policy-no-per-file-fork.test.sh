#!/usr/bin/env bash
# hq-core: public
# Regression: .claude/hooks/inject-policy-on-trigger.sh must collect policy
# files WITHOUT forking a helper process per file.
#
# The collection loop classified each candidate with
# `case "$(basename "$f")" in ...`. That command substitution is a fork + exec
# of basename for EVERY *.md in every in-scope policies dir. The hook fires on
# every Bash PreToolUse and every prompt, so on a real install the cost is
# (policy count) processes per tool call.
#
# Measured on the HQ controller against the live 3,419-file corpus: the
# collection loop alone accounted for 18.4s, while reading and awk-parsing the
# same 3,419 files cost 176ms. The fleet was forking ~1,265 processes/second
# and sitting at load 40-49 with zero I/O pressure — pure process churn.
# `${f##*/}` is the pure-Bash equivalent (identical result for every path a
# glob can produce) and costs zero processes.
#
# Contract: the number of helper processes the hook spawns while classifying
# policy filenames MUST NOT scale with the number of policy files. This test
# shims `basename` onto PATH, counts invocations against synthetic corpora of
# two very different sizes, and fails if the count tracks the corpus.

set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$HQ_SRC/.claude/hooks/inject-policy-on-trigger.sh"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { pass=$((pass+1)); printf '  ok %s\n' "$1"; }

[ -f "$HOOK" ] || fail "hook not found at $HOOK"

REAL_BASENAME="$(command -v basename 2>/dev/null || true)"
[ -x "$REAL_BASENAME" ] || fail "no basename on PATH to delegate to"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# ── A PATH shim that counts every `basename` fork the hook makes ─────────────
SHIM_DIR="$ROOT/shim"
COUNT_FILE="$ROOT/basename-calls"
mkdir -p "$SHIM_DIR"
: > "$COUNT_FILE"
cat > "$SHIM_DIR/basename" <<SHIMEOF
#!/usr/bin/env bash
printf 'x' >> "$COUNT_FILE"
exec "$REAL_BASENAME" "\$@"
SHIMEOF
chmod +x "$SHIM_DIR/basename"

# write_corpus <policies_dir> <count>  — N always-on baseline policies
write_corpus() {
  local dir="$1" n="$2" i
  mkdir -p "$dir"
  i=0
  while [ "$i" -lt "$n" ]; do
    cat > "$dir/perf-fixture-$i.md" <<EOF
---
id: perf-fixture-$i
title: "perf fixture $i"
scope: test
when: always
on: [SessionStart]
enforcement: soft
---

## Rule

Fixture policy $i.
EOF
    i=$((i + 1))
  done
}

# run_and_count <hq_root> -> echoes number of basename forks the hook made
run_and_count() {
  local hq_root="$1"
  : > "$COUNT_FILE"
  printf '{"hook_event_name":"PreToolUse","session_id":"nofork-%s","tool_name":"Bash","cwd":"%s","tool_input":{"command":"git status"}}' \
    "$$-${RANDOM}" "$hq_root" \
    | PATH="$SHIM_DIR:$PATH" HQ_ROOT="$hq_root" bash "$HOOK" >/dev/null 2>&1 || true
  wc -c < "$COUNT_FILE" | tr -d ' '
}

# ── Case 1: fork count must not scale with corpus size ───────────────────────
SMALL="$ROOT/small"
LARGE="$ROOT/large"
mkdir -p "$SMALL/.claude/hooks" "$LARGE/.claude/hooks"
write_corpus "$SMALL/core/policies" 25
write_corpus "$LARGE/core/policies" 400

SMALL_FORKS="$(run_and_count "$SMALL")"
LARGE_FORKS="$(run_and_count "$LARGE")"

# A 16x bigger corpus must not cost meaningfully more processes. A small
# constant slack covers any non-per-file basename use elsewhere on the path.
if [ "$LARGE_FORKS" -gt $((SMALL_FORKS + 8)) ]; then
  fail "basename forks scale with policy count: $SMALL_FORKS forks for 25 policies, $LARGE_FORKS for 400. The collection loop must use \${f##*/}, not \$(basename \"\$f\")."
fi
ok "fork count does not scale with corpus size (25 files: $SMALL_FORKS, 400 files: $LARGE_FORKS)"

# ── Case 2: absolute ceiling — no per-file forking at all ────────────────────
if [ "$LARGE_FORKS" -gt 8 ]; then
  fail "hook spawned $LARGE_FORKS basename processes for a 400-policy corpus; expected a small constant (<= 8)"
fi
ok "400-policy corpus costs $LARGE_FORKS basename processes"

# ── Case 3: filename classification is unchanged ─────────────────────────────
# Re-asserted here so a fork-removal refactor cannot silently change WHICH
# files are collected (the same contract inject-policy-skip-conflict-files
# pins, restated against the loop this test is about).
CLS="$ROOT/cls"
mkdir -p "$CLS/core/policies" "$CLS/.claude/hooks"
write_one() {
  cat > "$1" <<EOF
---
id: $2
title: "$2"
scope: test
when: always
on: [SessionStart]
enforcement: soft
---

## Rule

$3
EOF
}
write_one "$CLS/core/policies/canonical-slug.md"            "canonical-slug"   "CANONICAL_MARKER real rule."
write_one "$CLS/core/policies/canonical-slug 2.md"          "space-copy"       "SPACE_MARKER skip me."
write_one "$CLS/core/policies/weird.sync-conflict-hostA.md" "sync-copy"        "SYNC_MARKER skip me."
write_one "$CLS/core/policies/other.md.conflict-123-abc.md" "hq-conflict-copy" "HQCONF_MARKER skip me."
write_one "$CLS/core/policies/README.md"                    "readme-policy"    "README_MARKER skip me."
write_one "$CLS/core/policies/example-policy.md"            "example-policy"   "EXAMPLE_MARKER skip me."

OUT="$(printf '{"hook_event_name":"PreToolUse","session_id":"nofork-cls-%s","tool_name":"Bash","cwd":"%s","tool_input":{"command":"git status"}}' \
  "$$-${RANDOM}" "$CLS" | HQ_ROOT="$CLS" bash "$HOOK" 2>/dev/null || true)"

case "$OUT" in
  *canonical-slug*) ok "canonical <slug>.md is still collected" ;;
  *) fail "canonical-slug did not inject; collection regressed. Output: $OUT" ;;
esac

for skipped in space-copy sync-copy hq-conflict-copy readme-policy example-policy; do
  case "$OUT" in
    *"$skipped"*) fail "$skipped should have been skipped but was injected. Output: $OUT" ;;
    *) ;;
  esac
done
ok "space / sync-conflict / hq-conflict / README / example files are still skipped"

echo "PASS ($pass checks) inject-policy-no-per-file-fork"
