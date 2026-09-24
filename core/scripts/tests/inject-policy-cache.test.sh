#!/usr/bin/env bash
# hq-core: public
# Regression coverage for the persistent parsed-policy cache used by
# inject-policy-on-trigger.sh. The fixture deliberately spans company,
# personal, and core scope plus both hard and soft tiers.
set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$HQ_SRC/.claude/hooks/inject-policy-on-trigger.sh"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); printf '  ok %s\n' "$1"; }

[ -f "$HOOK" ] || fail "hook not found: $HOOK"
command -v jq >/dev/null || fail "jq required"

TMPROOT="$(mktemp -d)"
ROOT="$TMPROOT/hq"
CORE_SOFT_EXPECTED=CORE_SOFT_V1
REAL_BASH="$(command -v bash)"
export REAL_BASH
trap 'rm -rf "$TMPROOT"' EXIT

write_policy() {
  # write_policy <relative-path> <id> <enforcement> <rule> [body]
  local rel="$1" id="$2" enforcement="$3" rule="$4" body="${5:-}"
  mkdir -p "$(dirname "$ROOT/$rel")"
  cat >"$ROOT/$rel" <<EOF
---
id: $id
title: "$id"
scope: test
when: always
on: [SessionStart]
enforcement: $enforcement
---

## Rule

$rule
$body
EOF
}

setup_tree() {
  ROOT="$TMPROOT/hq${1:+-$1}"
  mkdir -p "$ROOT/core/policies" "$ROOT/personal/policies" \
    "$ROOT/companies/acme/policies" "$ROOT/core/scripts" \
    "$ROOT/workspace/orchestrator/policy-trigger-state" "$TMPROOT/bin"
  cat >"$TMPROOT/bin/bash" <<'EOF'
#!/usr/bin/bash
if [ "${1:-}" = "${DERIVE_SCRIPT:-}" ] && [ -n "${DERIVE_CALL_LOG:-}" ]; then
  printf '%s\n' "${*:2}" >> "$DERIVE_CALL_LOG"
fi
exec "$REAL_BASH" "$@"
EOF
  chmod +x "$TMPROOT/bin/bash"
  cp "$HQ_SRC/core/scripts/hook-lib.sh" "$ROOT/core/scripts/hook-lib.sh"
  cat >"$ROOT/core/scripts/derive-trigger-facts.sh" <<'EOF'
#!/usr/bin/env bash
[ -z "${DERIVE_CALL_LOG:-}" ] || printf '%s\n' "$*" >> "$DERIVE_CALL_LOG"
if [ "${1:-}" = "AssistantIntent" ]; then
  printf '%s\n' "${HQ_TEST_INTENT_FACTS:-always}"
elif [ "${2:-}" = "1" ] || [ "${2:-}" = "--with-assistant-intent" ]; then
  printf '%s\n%s\n' "${HQ_TEST_EVENT_FACTS:-always}" "${HQ_TEST_INTENT_FACTS:-always}"
else
  printf '%s\n' "${HQ_TEST_EVENT_FACTS:-always}"
fi
EOF
  cat >"$ROOT/core/scripts/eval-trigger.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$ROOT/core/scripts/derive-trigger-facts.sh" "$ROOT/core/scripts/eval-trigger.sh"
  write_policy core/policies/core-hard.md core-hard hard CORE_HARD_V1 'CORE_HARD_BODY_V1'
  write_policy core/policies/core-soft.md core-soft soft CORE_SOFT_V1
  write_policy personal/policies/personal-soft.md personal-soft soft PERSONAL_SOFT_V1
  write_policy companies/acme/policies/company-hard.md company-hard hard COMPANY_HARD_V1 'COMPANY_HARD_BODY_V1'
}

payload() {
  jq -cn --arg sid "$1" --arg cwd "$ROOT" --arg prompt "${2:-cache fixture}" \
    --arg transcript "${3:-}" \
    '{hook_event_name:"UserPromptSubmit",session_id:$sid,tool_name:"Bash",cwd:$cwd,prompt:$prompt,transcript_path:$transcript}'
}

run_hook() {
  local sid="$1" out="$2" emit_mode="${3:-}" prompt="${4:-cache fixture}"
  local facts="${5:-always}" transcript="${6:-}" status=0
  local intent_facts="${7:-$facts}"
  payload "$sid" "$prompt" "$transcript" | env HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" HQ_POLICY_COMPANY=acme \
    DERIVE_SCRIPT="$HQ_SRC/core/scripts/derive-trigger-facts.sh" \
    DERIVE_CALL_LOG="$TMPROOT/derive-calls.log" PATH="$TMPROOT/bin:$PATH" \
    HQ_TEST_EVENT_FACTS="$facts" HQ_TEST_INTENT_FACTS="$intent_facts" \
    HQ_POLICY_EMIT="$emit_mode" \
    bash "$HOOK" >"$out" 2>"$out.stderr" || status=$?
  [ "$status" -eq 0 ] || fail "hook exited $status: $(cat "$out.stderr")"
}

assert_full_output() {
  local out="$1"
  for marker in COMPANY_HARD_BODY_V1 CORE_HARD_BODY_V1 "$CORE_SOFT_EXPECTED" PERSONAL_SOFT_V1; do
    grep -Fq "$marker" "$out" || fail "expected $marker in output: $(cat "$out"); stderr: $(cat "$out.stderr")"
  done
}

cache_dir() { printf '%s\n' "$ROOT/workspace/orchestrator/hook-state/policy-trigger-cache"; }

assert_cache_written() {
  local count cache_file
  count="$({ find "$(cache_dir)" -type f -name '*.cache' 2>/dev/null || true; } | wc -l | tr -d ' ')"
  [ "$count" -gt 0 ] || fail "expected parsed-policy cache file in $(cache_dir)"
  cache_file="$(find "$(cache_dir)" -type f -name '*.cache' -print -quit)"
  head -n 1 "$cache_file" | grep -Fq 'hq-policy-cache-v1' \
    || fail "cache file is missing its complete-version header"
}

assert_evaluation_cache_written() {
  local eval_file
  eval_file="$(find "$(cache_dir)" -type f -name '*.eval' -print -quit)"
  [ -n "$eval_file" ] || fail "expected per-session evaluation cache file"
  head -n 1 "$eval_file" | grep -Fq 'hq-policy-eval-v4' \
    || fail "evaluation cache file is missing its complete-version header"
}

setup_tree

# 1. First fire has no state directory. It must still emit all tiers/scopes and
# create a cache whose second fire is byte-identical.
[ ! -d "$(cache_dir)" ] || fail "fixture cache directory must start absent"
run_hook cold "$TMPROOT/cold.out"
assert_full_output "$TMPROOT/cold.out"
grep -Fxq 'UserPromptSubmit --with-assistant-intent' "$TMPROOT/derive-calls.log" \
  || fail "hook did not request paired primary and AssistantIntent facts"
grep -Fxq 'AssistantIntent' "$TMPROOT/derive-calls.log" \
  && fail "hook fell back to a second AssistantIntent helper launch" || true
assert_cache_written
run_hook warm "$TMPROOT/warm.out"
cmp -s "$TMPROOT/cold.out" "$TMPROOT/warm.out" \
  || fail "cached output differs from cold output"
assert_evaluation_cache_written
# A ledger changes when first records are emitted, so its first repeat mints
# the empty-result entry; the following identical repeat is an evaluation-cache
# hit and must retain the same empty output.
run_hook warm "$TMPROOT/warm-repeat-1.out"
run_hook warm "$TMPROOT/warm-repeat-2.out"
[ ! -s "$TMPROOT/warm-repeat-1.out" ] || fail "deduped repeat unexpectedly emitted policies"
cmp -s "$TMPROOT/warm-repeat-1.out" "$TMPROOT/warm-repeat-2.out" \
  || fail "evaluation-cache hit changed the deduped output"
ok "cold and cached output are byte-identical across hard/soft and three scopes"

# 2. A content-only edit must invalidate the parsed cache even though no file is
# added or removed.
write_policy core/policies/core-soft.md core-soft soft CORE_SOFT_V2
CORE_SOFT_EXPECTED=CORE_SOFT_V2
run_hook modified "$TMPROOT/modified.out"
grep -Fq CORE_SOFT_V2 "$TMPROOT/modified.out" || fail "content edit did not invalidate cache"
grep -Fq CORE_SOFT_V1 "$TMPROOT/modified.out" && fail "stale policy content survived cache hit"
assert_cache_written
ok "content-only modification invalidates the cache"

# 3. A policy symlink is a valid candidate because the scanner's -f test and
# awk both follow it. Its target must therefore be fingerprinted too: changing
# target content without touching the link itself must invalidate the cache.
write_policy ../symlink-policy-target.md symlink-hard hard SYMLINK_TARGET_V1 'SYMLINK_HARD_BODY_V1'
ln -s "$TMPROOT/symlink-policy-target.md" "$ROOT/personal/policies/symlink-hard.md"
run_hook symlink-before "$TMPROOT/symlink-before.out" tsv
grep -Fq SYMLINK_TARGET_V1 "$TMPROOT/symlink-before.out" \
  || fail "symlinked hard policy was not surfaced"
write_policy ../symlink-policy-target.md symlink-hard hard SYMLINK_TARGET_V2 'SYMLINK_HARD_BODY_V2'
run_hook symlink-after "$TMPROOT/symlink-after.out" tsv
grep -Fq SYMLINK_TARGET_V2 "$TMPROOT/symlink-after.out" \
  || fail "symlink target edit did not invalidate cache"
grep -Fq SYMLINK_TARGET_V1 "$TMPROOT/symlink-after.out" \
  && fail "stale symlink target content survived cache hit"
assert_cache_written
ok "symlink target content modification invalidates the cache"

# 4. Added and deleted files both change the cache input set.
write_policy personal/policies/personal-added.md personal-added soft PERSONAL_ADDED_V1
run_hook added "$TMPROOT/added.out"
grep -Fq PERSONAL_ADDED_V1 "$TMPROOT/added.out" || fail "added policy was not surfaced"
rm -f "$ROOT/personal/policies/personal-added.md"
run_hook deleted "$TMPROOT/deleted.out"
grep -Fq PERSONAL_ADDED_V1 "$TMPROOT/deleted.out" && fail "deleted policy remained cached"
assert_cache_written
ok "add and delete invalidate the cache"

# 5. A cache-state path that resolves to a non-directory makes cache creation
# impossible for every uid, including root. The hook must treat that state as
# advisory and retain the exact uncached policy output.
rm -rf "$(cache_dir)"
rm -rf "$ROOT/workspace/orchestrator/hook-state"
ln -s /dev/null "$ROOT/workspace/orchestrator/hook-state"
run_hook unwritable "$TMPROOT/unwritable.out"
assert_full_output "$TMPROOT/unwritable.out"
[ ! -e "$(cache_dir)" ] || fail "unwritable cache state unexpectedly published a cache"
ok "unwritable cache state falls back to correct uncached output"

# 6. Parallel first fires sharing one cache directory must each see a complete
# reminder; an interrupted/partial cache reader would miss one of these bodies.
rm -f "$ROOT/workspace/orchestrator/hook-state"
mkdir -p "$ROOT/workspace/orchestrator/hook-state"
rm -rf "$(cache_dir)"
for n in 1 2 3 4 5 6 7 8; do
  run_hook "parallel-$n" "$TMPROOT/parallel-$n.out" &
done
wait
for n in 1 2 3 4 5 6 7 8; do
  assert_full_output "$TMPROOT/parallel-$n.out"
done
assert_cache_written
ok "concurrent fires never emit a partial cache result"

# 7. Session-specific evaluation state is kept in 64 fixed atomic slots per
# scope. More unique sessions than slots must not grow the cache without bound.
for n in $(seq 1 80); do
  run_hook "bounded-$n" "$TMPROOT/bounded-$n.out" tsv
done
eval_count="$({ find "$(cache_dir)/eval-v4" -maxdepth 1 -type f -name '*.eval' 2>/dev/null || true; } | wc -l | tr -d ' ')"
[ "$eval_count" -gt 0 ] || fail "expected bounded evaluation cache entries"
[ "$eval_count" -le 64 ] \
  || fail "evaluation cache grew to $eval_count entries; expected at most 64 per scope"
ok "evaluation cache remains bounded across more than 64 sessions"

# 8. A grammar change changes evaluation semantics even when policy files and
# facts do not. A v2 cache from the permissive parser must therefore never be
# read by the stricter parser: it could replay a now-invalid policy match.
setup_tree parser-revision
cat >"$ROOT/core/policies/legacy-permissive.md" <<'EOF'
---
id: legacy-permissive
title: "legacy-permissive"
scope: test
when: always && (always || never
on: [SessionStart]
enforcement: soft
---

## Rule

OLD_PARSER_CACHE_MARKER
EOF
run_hook parser-revision "$TMPROOT/parser-revision-first.out"
: > "$ROOT/workspace/orchestrator/policy-trigger-state/parser-revision.txt"
run_hook parser-revision "$TMPROOT/parser-revision-second.out"
v4_file="$(find "$(cache_dir)/eval-v4" -type f -name '*.eval' -print -quit)"
[ -n "$v4_file" ] || fail "expected a v4 evaluation cache before stale-cache test"
mkdir -p "$(cache_dir)/eval-v2"
v2_file="$(cache_dir)/eval-v2/$(basename "$v4_file")"
sed '1s/hq-policy-eval-v4/hq-policy-eval-v2/' "$v4_file" > "$v2_file"
printf 'legacy-permissive\tcore\t%s\tsoft\tOLD_PARSER_CACHE_MARKER\treactive\tonce\tok\t2\n' \
  "$ROOT/core/policies/legacy-permissive.md" >> "$v2_file"
rm -rf "$(cache_dir)/eval-v4"
: > "$ROOT/workspace/orchestrator/policy-trigger-state/parser-revision.txt"
run_hook parser-revision "$TMPROOT/parser-revision-stale-v2.out"
grep -Fq OLD_PARSER_CACHE_MARKER "$TMPROOT/parser-revision-stale-v2.out" \
  && fail "a v2 evaluation-cache verdict survived the parser revision"
find "$(cache_dir)/eval-v4" -type f -name '*.eval' -print -quit | grep -q . \
  || fail "parser revision did not create a v4 evaluation cache"
ok "parser revision ignores stale v2 evaluation-cache verdicts"

# A case-sensitive v3 cache can contain an empty verdict for a policy whose
# uppercase trigger should now match lowercase prompt facts. Recreate the same
# v3 key with an empty body and prove the runtime ignores that old verdict.
setup_tree case-fold-revision
cat >"$ROOT/core/policies/uppercase-trigger.md" <<'EOF'
---
id: uppercase-trigger
title: "uppercase-trigger"
scope: test
when: ENOENT
on: [UserPromptSubmit]
enforcement: soft
---

## Rule

CASE_FOLD_CACHE_MARKER
EOF
CASE_FOLD_SESSION="case-fold-cache-session"
run_hook "$CASE_FOLD_SESSION" "$TMPROOT/case-fold-first.out" tsv "enoent" "enoent"
grep -Fq CASE_FOLD_CACHE_MARKER "$TMPROOT/case-fold-first.out" \
  || fail "case-insensitive trigger did not match on the cold evaluation"
CASE_FOLD_DEDUPE="$ROOT/workspace/orchestrator/policy-trigger-state/$CASE_FOLD_SESSION.txt"
CASE_FOLD_TURN="$ROOT/workspace/orchestrator/policy-trigger-state/$CASE_FOLD_SESSION.turn.txt"
: > "$CASE_FOLD_DEDUPE"
: > "$CASE_FOLD_TURN"
run_hook "$CASE_FOLD_SESSION" "$TMPROOT/case-fold-cache-seed.out" tsv "enoent" "enoent"
grep -Fq CASE_FOLD_CACHE_MARKER "$TMPROOT/case-fold-cache-seed.out" \
  || fail "case-insensitive trigger did not match after parsed-cache warmup"
case_v4="$(find "$(cache_dir)/eval-v4" -type f -name '*.eval' -print -quit)"
[ -n "$case_v4" ] || fail "expected v4 evaluation entry for case-folded facts"
mkdir -p "$(cache_dir)/eval-v3"
case_v3="$(cache_dir)/eval-v3/$(basename "$case_v4")"
sed -n '1p' "$case_v4" | sed 's/hq-policy-eval-v4/hq-policy-eval-v3/' > "$case_v3"
rm -rf "$(cache_dir)/eval-v4"
: > "$CASE_FOLD_DEDUPE"
: > "$CASE_FOLD_TURN"
run_hook "$CASE_FOLD_SESSION" "$TMPROOT/case-fold-stale-v3.out" tsv "enoent" "enoent"
grep -Fq CASE_FOLD_CACHE_MARKER "$TMPROOT/case-fold-stale-v3.out" \
  || fail "stale case-sensitive v3 cache suppressed a case-insensitive policy match"
find "$(cache_dir)/eval-v4" -type f -name '*.eval' -print -quit | grep -q . \
  || fail "case-folded evaluation did not replace the stale namespace with v4"
ok "case-folding evaluator ignores stale v3 no-match verdicts"

# The evaluation cache key includes both derived fact channels. Clearing the
# ledgers holds every other key input constant so a change in AssistantIntent
# alone must invalidate the cached no-match result.
setup_tree assistant-intent-cache
cat >"$ROOT/core/policies/assistant-intent-cache.md" <<'EOF'
---
id: assistant-intent-cache
title: "assistant-intent-cache"
scope: test
when: assistant_intent_marker
on: [AssistantIntent]
enforcement: soft
---

## Rule

ASSISTANT_INTENT_CACHE_MARKER
EOF
INTENT_SESSION="assistant-intent-cache-session"
INTENT_TRANSCRIPT="$TMPROOT/assistant-intent-transcript.jsonl"
printf '{"type":"assistant","content":"unrelated intent"}\n' > "$INTENT_TRANSCRIPT"
run_hook "$INTENT_SESSION" "$TMPROOT/assistant-intent-cold.out" tsv \
  "intent cache fixture" "steady_event" "$INTENT_TRANSCRIPT" "steady_event"
grep -Fq ASSISTANT_INTENT_CACHE_MARKER "$TMPROOT/assistant-intent-cold.out" \
  && fail "AssistantIntent policy matched without its trigger fact"
INTENT_DEDUPE="$ROOT/workspace/orchestrator/policy-trigger-state/$INTENT_SESSION.txt"
INTENT_TURN="$ROOT/workspace/orchestrator/policy-trigger-state/$INTENT_SESSION.turn.txt"
: > "$INTENT_DEDUPE"
: > "$INTENT_TURN"
run_hook "$INTENT_SESSION" "$TMPROOT/assistant-intent-prime.out" tsv \
  "intent cache fixture" "steady_event" "$INTENT_TRANSCRIPT" "steady_event"
grep -Fq ASSISTANT_INTENT_CACHE_MARKER "$TMPROOT/assistant-intent-prime.out" \
  && fail "AssistantIntent policy matched while priming the unchanged facts"
: > "$INTENT_DEDUPE"
: > "$INTENT_TURN"
printf '{"type":"assistant","content":"assistant_intent_marker"}\n' > "$INTENT_TRANSCRIPT"
run_hook "$INTENT_SESSION" "$TMPROOT/assistant-intent-changed.out" tsv \
  "intent cache fixture" "steady_event" "$INTENT_TRANSCRIPT" "assistant_intent_marker"
grep -Fq ASSISTANT_INTENT_CACHE_MARKER "$TMPROOT/assistant-intent-changed.out" \
  || fail "changed AssistantIntent fact reused the previous no-match evaluation"
ok "evaluation cache invalidates when AssistantIntent facts change"

echo "PASS ($pass checks) inject-policy-cache"
