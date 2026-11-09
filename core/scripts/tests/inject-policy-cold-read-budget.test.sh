#!/usr/bin/env bash
# hq-core: public
# Cold parsing must not scale with archival prose after the first Rule line.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="${HQ_POLICY_HOOK_UNDER_TEST:-$SRC/.claude/hooks/inject-policy-on-trigger.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
trap 'cat "$TMP"/*.time 2>/dev/null || true' ERR
ROOT="$TMP/hq"
mkdir -p "$ROOT/core/policies" "$ROOT/core/scripts" "$ROOT/.claude/hooks" "$TMP/bin"
cp "$HOOK" "$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
cp "$SRC/core/scripts/hook-lib.sh" "$ROOT/core/scripts/hook-lib.sh"
ln -s "$SRC/core/scripts/eval-trigger.sh" "$ROOT/core/scripts/eval-trigger.sh"
cat > "$ROOT/core/scripts/derive-trigger-facts.sh" <<'SH'
#!/usr/bin/env bash
printf 'always\n'
SH

# Count actual evaluator input records and logical bytes, not occurrences of
# nextfile in source. This also observes the cold parser on BSD and GNU awk.
export HQ_TEST_REAL_AWK
HQ_TEST_REAL_AWK="$(command -v awk)"
export HQ_TEST_READ_LOG="$TMP/reads"
cat > "$TMP/bin/awk" <<'SH'
#!/usr/bin/env bash
args=()
for arg in "$@"; do
  case "$arg" in
    *'function finalize('* )
      arg='{ budget_records++; budget_bytes+=length($0)+1 }
'"$arg"'
END { print budget_records, budget_bytes > ENVIRON["HQ_TEST_READ_LOG"] }'
      ;;
  esac
  args+=("$arg")
done
exec "$HQ_TEST_REAL_AWK" "${args[@]}"
SH
chmod +x "$TMP/bin/awk"

write_policy() {
  cat > "$ROOT/core/policies/$1.md" <<EOF
---
id: $1
when: always
on: [UserPromptSubmit]
enforcement: $2
---

## Rule

$3

Body retained for a hard policy.

## Rationale
EOF
}
write_policy a-first soft 'FIRST_RULE'
write_policy z-last hard 'LAST_RULE'
# A policy without a Rule section must still be finalized at EOF; a later
# valid file must not inherit rcap from the preceding file.
printf '%s\n' '---' 'id: m-no-rule' 'when: always' 'on: [UserPromptSubmit]' 'enforcement: soft' '---' > "$ROOT/core/policies/m-no-rule.md"

run_hook() {
  rm -rf "$ROOT/workspace"
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"cold-budget","cwd":"%s","prompt":"always"}' "$ROOT" \
    | {
      TIMEFORMAT=$'user %U\nsys %S'
      time env HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" HQ_POLICY_COMPANY='' \
        HQ_POLICY_FACT_HELPER_DISABLE=1 HQ_POLICY_OUTPUT_CEILING_BYTES=8000 \
        PATH="$TMP/bin:$PATH" bash "$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
    } > "$1" 2> "$2"
}
run_hook "$TMP/small.out" "$TMP/small.time"
# 20 MB of trailing prose used to enter every parser predicate. The record
# budget is deterministic even on contended CI; CPU checks exclude wall time.
awk 'BEGIN { for(i=0;i<200000;i++) print "Archived context that cannot change the closed frontmatter or the first captured summary. More context." }' >> "$ROOT/core/policies/a-first.md"
run_hook "$TMP/large.out" "$TMP/large.time"
cmp "$TMP/small.out" "$TMP/large.out"
grep -q 'FIRST_RULE' "$TMP/large.out"
grep -q 'LAST_RULE' "$TMP/large.out"
grep -q 'Body retained for a hard policy' "$TMP/large.out"
read -r records bytes < "$TMP/reads"
[ "$records" -lt 100 ] || { echo "FAIL: cold evaluator consumed $records records ($bytes bytes)"; exit 1; }
small_cpu="$(awk '/^(user|sys) / {n+=$2} END {print n+0}' "$TMP/small.time")"
large_cpu="$(awk '/^(user|sys) / {n+=$2} END {print n+0}' "$TMP/large.time")"
# A relative CPU latency budget plus 250 ms slack for coarse time resolution
# and process scheduling. Archival prose must not add linear parser work.
awk -v small="$small_cpu" -v large="$large_cpu" 'BEGIN {exit !(large <= small*2+0.25)}' \
  || { echo "FAIL: archival CPU budget: small=$small_cpu large=$large_cpu"; exit 1; }
printf 'PASS: cold evaluator records=%s logical_bytes=%s small_cpu_s=%s large_cpu_s=%s\n' "$records" "$bytes" "$small_cpu" "$large_cpu"
