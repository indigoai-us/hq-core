#!/usr/bin/env bash
# Regression tests for the /import-context scanner (.claude/skills/import-context/scan.sh).
#
# Guards the DEV-1740 / feedback_4c76eff2 bug: the scanner reported 0 skills /
# 0 hooks against a populated ~/.claude because directory discovery built its
# `find` prune expression as a string and ran it through `eval`, where the bare
# `(` / `)` tokens were re-parsed as shell subshell syntax — find died with a
# syntax error, returned nothing, and the failure was swallowed by 2>/dev/null,
# yielding a confident (and wrong) "0 found". A second defect injected phantom
# "residue" entries from empty bash arrays expanded with "${arr[@]:-}".
#
# Two mandatory invariants:
#   1. Discovery actually finds what exists (populated fixture → non-zero counts).
#   2. A discovery failure surfaces LOUDLY and is distinguishable from "found
#      none" (permission-denied fixture → discovery.ok=false, loud stderr).
#   3. Large discovered payloads are file-backed, never passed to jq in argv
#      (DEV-1973 / feedback_01065ffc-f06c-4be0-b7ad-f20bd314b3fb).

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCAN="$SRC_ROOT/.claude/skills/import-context/scan.sh"

TMP_ROOT="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP_ROOT" 2>/dev/null || true; rm -rf "$TMP_ROOT"' EXIT

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { PASS=$((PASS + 1)); echo "ok - $*"; }

command -v jq >/dev/null 2>&1 || fail "jq is required to run these tests"
[ -f "$SCAN" ] || fail "scanner not found: $SCAN"

# ── helper: run the scanner with HOME pointed at a fixture ───────────────────
run_scan() { # <home> <scope> <out.json> <out.err>
  local home="$1" scope="$2" outj="$3" oute="$4"
  HOME="$home" bash "$SCAN" \
    --hq-root="$SRC_ROOT" \
    --no-default-scopes \
    --scope="$scope" \
    >"$outj" 2>"$oute" || true
}

count() { jq -r ".counts.$2" "$1"; }

# ── Test 1: populated fixture → discovery finds what exists ──────────────────
P="$TMP_ROOT/populated"
mkdir -p "$P/.claude/skills" "$P/.claude/hooks" "$P/.claude/commands" "$P/.claude/policies"
for i in $(seq 1 12); do
  mkdir -p "$P/.claude/skills/skill-$i"
  printf 'name: skill-%s\n' "$i" > "$P/.claude/skills/skill-$i/SKILL.md"
done
for i in $(seq 1 7); do printf '#!/usr/bin/env bash\necho hi\n' > "$P/.claude/hooks/hook-$i.sh"; done
for i in $(seq 1 4); do printf '# command %s\n' "$i" > "$P/.claude/commands/cmd-$i.md"; done
for i in $(seq 1 3); do printf '# policy %s\n' "$i" > "$P/.claude/policies/pol-$i.md"; done

run_scan "$P" "$P" "$TMP_ROOT/t1.json" "$TMP_ROOT/t1.err"
jq -e '.categories' "$TMP_ROOT/t1.json" >/dev/null 2>&1 || fail "T1: report is not valid JSON"

[ "$(count "$TMP_ROOT/t1.json" skills)"   = "12" ] || fail "T1: expected 12 skills, got $(count "$TMP_ROOT/t1.json" skills)"
[ "$(count "$TMP_ROOT/t1.json" hooks)"    = "7"  ] || fail "T1: expected 7 hooks, got $(count "$TMP_ROOT/t1.json" hooks)"
[ "$(count "$TMP_ROOT/t1.json" commands)" = "4"  ] || fail "T1: expected 4 commands, got $(count "$TMP_ROOT/t1.json" commands)"
[ "$(count "$TMP_ROOT/t1.json" policies)" = "3"  ] || fail "T1: expected 3 policies, got $(count "$TMP_ROOT/t1.json" policies)"
[ "$(jq -r '.discovery.ok' "$TMP_ROOT/t1.json")" = "true" ] || fail "T1: discovery.ok should be true on a clean scan"
ok "populated fixture: non-zero skill/hook/command/policy counts, discovery.ok=true"

# ── Test 2: empty fixture → genuine zero, no phantom residue ─────────────────
E="$TMP_ROOT/empty/home"
mkdir -p "$E"
run_scan "$E" "$E" "$TMP_ROOT/t2.json" "$TMP_ROOT/t2.err"
jq -e '.categories' "$TMP_ROOT/t2.json" >/dev/null 2>&1 || fail "T2: report is not valid JSON"
# Every category must be a real zero — no residue entries from empty arrays.
for c in skills hooks commands policies claude_md claude_repos mcp_servers; do
  [ "$(count "$TMP_ROOT/t2.json" "$c")" = "0" ] || fail "T2: expected 0 $c on empty fixture, got $(count "$TMP_ROOT/t2.json" "$c") (residue?)"
done
# Guard the specific historical residue: claude_repos source_path "." .
[ "$(jq -r '[.categories.claude_repos[].source_path] | index(".") // "none"' "$TMP_ROOT/t2.json")" = "none" ] \
  || fail "T2: phantom claude_repos entry with source_path '.' reappeared"
[ "$(jq -r '.discovery.ok' "$TMP_ROOT/t2.json")" = "true" ] || fail "T2: discovery.ok should be true when genuinely empty"
ok "empty fixture: clean zeros, no phantom residue, discovery.ok=true"

# ── Test 3: permission-denied fixture → loud failure, NOT a silent zero ──────
if [ "$(id -u)" -eq 0 ]; then
  echo "ok - (skipped T3: running as root, chmod 000 does not deny root)"
else
  D="$TMP_ROOT/denied"
  mkdir -p "$D/.claude/skills/s1"
  printf 'name: s1\n' > "$D/.claude/skills/s1/SKILL.md"
  chmod 000 "$D/.claude/skills"
  run_scan "$D" "$D" "$TMP_ROOT/t3.json" "$TMP_ROOT/t3.err"
  chmod 755 "$D/.claude/skills" 2>/dev/null || true
  jq -e '.categories' "$TMP_ROOT/t3.json" >/dev/null 2>&1 || fail "T3: report is not valid JSON"

  [ "$(jq -r '.discovery.ok' "$TMP_ROOT/t3.json")" = "false" ] \
    || fail "T3: discovery.ok must be false when a directory could not be read"
  [ "$(jq -r '.discovery.errors | length' "$TMP_ROOT/t3.json")" -gt 0 ] \
    || fail "T3: discovery.errors must record the failure"
  grep -q "DISCOVERY INCOMPLETE" "$TMP_ROOT/t3.err" \
    || fail "T3: a loud 'DISCOVERY INCOMPLETE' banner must be printed to stderr"
  ok "permission-denied fixture: discovery.ok=false, errors recorded, loud stderr banner"
fi

# ── Test 4: large fixture → no jq ARG_MAX overflow ──────────────────────────
# 240 SKILL.md files with 40 previewable long lines make the serialized skills
# payload exceed the argv budget that previously failed at scan.sh's tree-object
# jq call. The scanner must finish and preserve every discovered skill.
L="$TMP_ROOT/large"
mkdir -p "$L/.claude/skills"
long_line='xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
for i in $(seq 1 240); do
  mkdir -p "$L/.claude/skills/skill-$i"
  for _ in $(seq 1 80); do printf '%s\n' "$long_line"; done > "$L/.claude/skills/skill-$i/SKILL.md"
done

set +e
HOME="$L" bash "$SCAN" \
  --hq-root="$SRC_ROOT" \
  --no-default-scopes \
  --scope="$L" \
  >"$TMP_ROOT/t4.json" 2>"$TMP_ROOT/t4.err"
scan_status=$?
set -e

[ "$scan_status" -eq 0 ] || fail "T4: large fixture scan exited $scan_status: $(sed -n '1p' "$TMP_ROOT/t4.err")"
jq -e '.categories' "$TMP_ROOT/t4.json" >/dev/null 2>&1 || fail "T4: report is not valid JSON"
[ "$(count "$TMP_ROOT/t4.json" skills)" = "240" ] \
  || fail "T4: expected 240 skills, got $(count "$TMP_ROOT/t4.json" skills)"
if grep -q 'Argument list too long' "$TMP_ROOT/t4.err"; then
  fail "T4: scanner must not hit ARG_MAX"
fi
ok "large fixture: 240 skills scan without jq ARG_MAX overflow"

# ── Test 5: conversation stores → store-level entries with session counts ────
C="$TMP_ROOT/convos"
mkdir -p "$C/.claude/projects/-Users-me-proj" \
         "$C/.codex/sessions/2026/01/01" \
         "$C/.grok/sessions/%2FUsers%2Fme/abc-123"
printf '{"type":"user"}\n' > "$C/.claude/projects/-Users-me-proj/s1.jsonl"
printf '{"type":"user"}\n' > "$C/.claude/projects/-Users-me-proj/s2.jsonl"
printf '{}\n' > "$C/.codex/sessions/2026/01/01/rollout-1.jsonl"
printf '{}\n' > "$C/.grok/sessions/%2FUsers%2Fme/abc-123/updates.jsonl"
printf '[{"name":"chat 1","chat_messages":[]},{"name":"chat 2","chat_messages":[]}]' > "$C/conversations.json"

HOME="$C" bash "$SCAN" \
  --hq-root="$SRC_ROOT" \
  --no-default-scopes \
  --scope="$C" \
  --claude-export="$C" \
  >"$TMP_ROOT/t5.json" 2>"$TMP_ROOT/t5.err" || true

cval() { jq -r ".categories.conversations[] | select(.source==\"$1\").sessions" "$TMP_ROOT/t5.json"; }
[ "$(cval claude-code)" = "2" ] || fail "T5: expected 2 claude-code sessions, got '$(cval claude-code)'"
[ "$(cval codex)"       = "1" ] || fail "T5: expected 1 codex session, got '$(cval codex)'"
[ "$(cval grok)"        = "1" ] || fail "T5: expected 1 grok session, got '$(cval grok)'"
[ "$(cval claude-ai)"   = "2" ] || fail "T5: expected 2 claude.ai conversations, got '$(cval claude-ai)'"
[ "$(jq '[.categories.conversations[] | select(has("preview"))] | length' "$TMP_ROOT/t5.json")" = "0" ] \
  || fail "T5: conversation entries must be store-level (no file previews/contents)"
ok "conversation stores: claude-code/codex/grok/claude-ai counted at store level, no contents"

# ── Test 6: missing claude-export path → discovery error, not silent zero ────
HOME="$E" bash "$SCAN" \
  --hq-root="$SRC_ROOT" \
  --no-default-scopes \
  --scope="$E" \
  --claude-export="$TMP_ROOT/nonexistent-export" \
  >"$TMP_ROOT/t6.json" 2>"$TMP_ROOT/t6.err" || true
[ "$(jq -r '.discovery.ok' "$TMP_ROOT/t6.json")" = "false" ] \
  || fail "T6: bad --claude-export path must set discovery.ok=false"
jq -r '.discovery.errors[]' "$TMP_ROOT/t6.json" | grep -q "claude-export" \
  || fail "T6: discovery.errors must name the claude-export failure"
ok "missing claude-export path: recorded as discovery error, never a silent zero"

echo "PASS: $PASS import-context scanner assertion group(s) green"
