#!/usr/bin/env bash
# Regression: image-context-guard.sh blocks oversized image reads and charges
# each agent context (parent or sub-agent) its own byte-weighted budget.
# Cost is bytes; a six-image call that stays under a count cap must still block
# when a file is over the byte limit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/image-context-guard.sh"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
CHARTER="$ROOT/.claude/CLAUDE.md"
PERSONAL="$ROOT/.claude/personal-context.md"
POLICY="$ROOT/core/policies/image-context-isolation.md"
DOC="$ROOT/core/docs/hq/HOOKS-NOT-FIRING.md"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/image-context-guard.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

SMALL="$TMP/icon.png"
LARGE="$TMP/packshot-full.png"
TEXT="$TMP/notes.txt"
printf 'tiny' >"$SMALL"
# 3 MiB of zeros: over the 2 MiB default, under any naive "count" cap.
dd if=/dev/zero of="$LARGE" bs=1024 count=3072 status=none 2>/dev/null \
  || dd if=/dev/zero of="$LARGE" bs=1024 count=3072
printf 'hello' >"$TEXT"

FIX="$TMP/hq-root"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/scripts" "$FIX/workspace/orchestrator/hook-state"
cp "$HOOK" "$FIX/.claude/hooks/image-context-guard.sh"
cp "$ROOT/core/scripts/hook-lib.sh" "$FIX/core/scripts/hook-lib.sh"
chmod +x "$FIX/.claude/hooks/image-context-guard.sh"
FIX_HOOK="$FIX/.claude/hooks/image-context-guard.sh"

read_payload() {
  local path="$1" sid="${2:-sess-a}"
  jq -nc --arg p "$path" --arg s "$sid" \
    '{tool_name:"Read",session_id:$s,tool_input:{file_path:$p}}'
}

expect() {
  local want="$1" desc="$2" payload="$3"
  shift 3
  local rc=0
  printf '%s' "$payload" | env CLAUDE_PROJECT_DIR="$FIX" HQ_ROOT="$FIX" "$@" \
    bash "$FIX_HOOK" >/dev/null 2>"$TMP/err" || rc=$?
  if [ "$rc" -eq "$want" ]; then
    ok "$desc"
  else
    bad "$desc (want $want got $rc; err=$(tr '\n' ' ' <"$TMP/err"))"
  fi
}

expect 0 "small png allowed" "$(read_payload "$SMALL")"
expect 2 "3MiB png blocked" "$(read_payload "$LARGE")"
expect 0 "plain text allowed" "$(read_payload "$TEXT")"
expect 0 "missing image fails open" "$(read_payload "$TMP/no-such.png")"
expect 0 "Bash payload fails open" \
  '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
expect 0 "escape hatch env allows large png" "$(read_payload "$LARGE")" \
  HQ_ALLOW_INLINE_IMAGE=1
expect 0 "escape hatch token allows large png" \
  "$(jq -nc --arg p "$LARGE" '{tool_name:"Read",tool_input:{file_path:$p},prompt:"ALLOW_INLINE_IMAGE"}')"

# stderr names the byte limit, not a count-only story.
printf '%s' "$(read_payload "$LARGE")" \
  | env CLAUDE_PROJECT_DIR="$FIX" HQ_ROOT="$FIX" bash "$FIX_HOOK" >/dev/null 2>"$TMP/err" || true
if grep -q 'inline-image limit' "$TMP/err" && grep -q 'bytes, not count' "$TMP/err"; then
  ok "size block names the byte limit"
else
  bad "size block message missing (err=$(cat "$TMP/err"))"
fi

# Codex original-resolution inline is denied even for a small file.
orig='{"tool_name":"view_image","session_id":"sess-codex","tool_input":{"path":"'"$SMALL"'","detail":"original"}}'
expect 2 "view_image detail=original blocked" "$orig"
expect 0 "view_image default detail on small png allowed" \
  '{"tool_name":"view_image","session_id":"sess-codex2","tool_input":{"path":"'"$SMALL"'"}}'

mkimg() {
  # mkimg <path> <KiB>
  dd if=/dev/zero of="$1" bs=1024 count="$2" status=none 2>/dev/null \
    || dd if=/dev/zero of="$1" bs=1024 count="$2" 2>/dev/null
}
agent_payload() {
  local path="$1" sid="$2" aid="$3"
  jq -nc --arg p "$path" --arg s "$sid" --arg a "$aid" \
    '{tool_name:"Read",session_id:$s,agent_id:$a,agent_type:"general-purpose",tool_input:{file_path:$p}}'
}

# feedback_2fdaf028: small screenshots cost little. Twelve 100 KiB
# screenshots and a 110 KiB logo all fit in the parent context; the old
# 8-image count cap blocked the ninth.
i=1
while [ "$i" -le 12 ]; do
  mkimg "$TMP/shot$i.png" 100
  expect 0 "parent small screenshot $i allowed" "$(read_payload "$TMP/shot$i.png" sess-small)"
  i=$((i + 1))
done
mkimg "$TMP/logo.jpg" 110
expect 0 "110KiB logo after twelve small screenshots allowed" "$(read_payload "$TMP/logo.jpg" sess-small)"

# Byte budget still protects the parent: four 1.9 MiB images (7.6 MiB) fit
# the 8 MiB budget, the fifth is blocked.
i=1
while [ "$i" -le 5 ]; do
  mkimg "$TMP/big$i.png" 1945
  i=$((i + 1))
done
i=1
while [ "$i" -le 4 ]; do
  expect 0 "parent 1.9MiB image $i allowed" "$(read_payload "$TMP/big$i.png" sess-budget)"
  i=$((i + 1))
done
expect 2 "parent fifth 1.9MiB image blocked by byte budget" "$(read_payload "$TMP/big5.png" sess-budget)"
expect 0 "re-read of an already-charged image allowed" "$(read_payload "$TMP/big1.png" sess-budget)"
expect 0 "other session has its own budget" "$(read_payload "$TMP/big5.png" sess-other)"

# Budget block message names the budget and the delegate route.
printf '%s' "$(read_payload "$TMP/big5.png" sess-budget)" \
  | env CLAUDE_PROJECT_DIR="$FIX" HQ_ROOT="$FIX" bash "$FIX_HOOK" >/dev/null 2>"$TMP/err" || true
if grep -q 'image budget' "$TMP/err" && grep -q 'spawn a sub-agent' "$TMP/err" \
  && grep -q 'own image budget' "$TMP/err" && grep -q 'OCR' "$TMP/err"; then
  ok "budget block names the budget, the delegate route, and OCR"
else
  bad "budget block message incomplete (err=$(cat "$TMP/err"))"
fi

# Distinct-image ceiling per context: 32 tiny images allowed, 33rd blocked.
i=1
while [ "$i" -le 33 ]; do
  printf 'x' >"$TMP/t$i.png"
  i=$((i + 1))
done
i=1
while [ "$i" -le 32 ]; do
  expect 0 "tiny image $i under ceiling allowed" "$(read_payload "$TMP/t$i.png" sess-count)"
  i=$((i + 1))
done
expect 2 "33rd distinct tiny image blocked by count ceiling" "$(read_payload "$TMP/t33.png" sess-count)"

# feedback_815f8f35 / feedback_2ecf53a7 / feedback_e71e5770: once the parent
# is out of budget, a sub-agent in the same session (same session_id, its own
# agent_id) can still read. A verification sub-agent reads 13 screenshots of
# about 300 KiB.
expect 2 "parent still blocked before delegation" "$(read_payload "$TMP/big5.png" sess-budget)"
i=1
while [ "$i" -le 13 ]; do
  mkimg "$TMP/verify$i.png" 300
  expect 0 "sub-agent screenshot $i allowed after parent budget is spent" \
    "$(agent_payload "$TMP/verify$i.png" sess-budget agent-qa-1)"
  i=$((i + 1))
done
expect 0 "sub-agent can read the image the parent was blocked on" \
  "$(agent_payload "$TMP/big5.png" sess-budget agent-qa-1)"

# Sub-agent reads do not spend the parent budget: with a 4-image ceiling the
# parent reads 3, a sub-agent reads 4 and is then blocked, and the parent
# still gets its 4th.
i=1
while [ "$i" -le 8 ]; do
  printf 'x' >"$TMP/c$i.png"
  i=$((i + 1))
done
for i in 1 2 3; do
  expect 0 "ceiling-4 parent image $i allowed" "$(read_payload "$TMP/c$i.png" sess-iso)" HQ_IMAGE_MAX_COUNT=4
done
for i in 4 5 6 7; do
  expect 0 "ceiling-4 sub-agent image $i allowed" "$(agent_payload "$TMP/c$i.png" sess-iso agent-a)" HQ_IMAGE_MAX_COUNT=4
done
expect 2 "ceiling-4 sub-agent fifth image blocked (sub-agent keeps its own cap)" \
  "$(agent_payload "$TMP/c8.png" sess-iso agent-a)" HQ_IMAGE_MAX_COUNT=4
expect 0 "ceiling-4 parent fourth image allowed after sub-agent reads" \
  "$(read_payload "$TMP/c8.png" sess-iso)" HQ_IMAGE_MAX_COUNT=4
expect 2 "ceiling-4 parent fifth image blocked" \
  "$(read_payload "$TMP/c4.png" sess-iso)" HQ_IMAGE_MAX_COUNT=4

# feedback_d8d269c2: one sub-agent spending its budget does not starve later
# sub-agents in the same session.
expect 0 "a later sub-agent has its own budget" \
  "$(agent_payload "$TMP/c8.png" sess-iso agent-b)" HQ_IMAGE_MAX_COUNT=4

# master-hook.sh exports HQ_HOOK_AGENT_ID; the hook honours it without a
# payload field, and a known-empty export stays on the parent ledger.
expect 0 "HQ_HOOK_AGENT_ID export gives a sub-agent ledger" \
  "$(read_payload "$TMP/big5.png" sess-budget)" HQ_HOOK_AGENT_ID=agent-env
expect 2 "known-empty HQ_HOOK_AGENT_ID stays on the parent ledger" \
  "$(read_payload "$TMP/big5.png" sess-budget)" HQ_HOOK_AGENT_ID=

# agent_type without agent_id (manual --agent main thread) is the parent.
expect 2 "agent_type alone does not open a sub-agent budget" \
  "$(jq -nc --arg p "$TMP/big5.png" '{tool_name:"Read",session_id:"sess-budget",agent_type:"reviewer",tool_input:{file_path:$p}}')"

# feedback_3d42bae3: image bytes are charged to the context that inlines them.
# Synthetic parent and sub-agent payloads share one session_id. The sub-agent
# is identified by its payload agent_id even when an empty HQ_HOOK_AGENT_ID is
# inherited from an outer process, or by a sub-agent transcript_path when the
# host sends no agent_id.
S3="sess-3d42"
S3_LEDGER="$FIX/workspace/orchestrator/hook-state/image-context/$S3/reads.txt"
transcript_payload() {
  local path="$1" sid="$2" transcript="$3"
  jq -nc --arg p "$path" --arg s "$sid" --arg t "$transcript" \
    '{tool_name:"Read",session_id:$s,transcript_path:$t,tool_input:{file_path:$p}}'
}
ledger_stat() {
  if [ -f "$1" ]; then
    awk -F '\t' '{ n += 1; b += $1 } END { printf "%d %d", n + 0, b + 0 }' "$1"
  else
    printf '0 0'
  fi
}
expect_ledger() {
  local want="$1" desc="$2" got
  got="$(ledger_stat "$S3_LEDGER")"
  if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc (want '$want' got '$got')"; fi
}
for i in 1 2 3 4 5; do mkimg "$TMP/p3-$i.png" 1900; done
mkimg "$TMP/p3-fill.png" 500
mkimg "$TMP/s3-a.png" 600
mkimg "$TMP/s3-b.png" 700
mkimg "$TMP/s3-c.png" 800

# Parent's own reads are counted: four 1.9 MiB images fit the 8 MiB budget.
for i in 1 2 3 4; do
  expect 0 "3d42 parent image $i counted and allowed" \
    "$(read_payload "$TMP/p3-$i.png" "$S3")" HQ_HOOK_AGENT_ID=
done
expect_ledger "4 7782400" "3d42 parent ledger holds the parent's four reads"

# Sub-agent read does not consume the parent budget.
expect 0 "3d42 sub-agent read (agent_id, empty inherited HQ_HOOK_AGENT_ID) allowed" \
  "$(agent_payload "$TMP/s3-a.png" "$S3" agent-3d42)" HQ_HOOK_AGENT_ID=
expect 0 "3d42 sub-agent read (transcript_path only) allowed" \
  "$(transcript_payload "$TMP/s3-b.png" "$S3" "/p/proj/$S3/subagents/agent-a3d42t.jsonl")"
expect_ledger "4 7782400" "3d42 sub-agent reads leave the parent ledger unchanged"
expect 0 "3d42 parent 500KiB read fits because sub-agent bytes were not charged" \
  "$(read_payload "$TMP/p3-fill.png" "$S3")" HQ_HOOK_AGENT_ID=
expect_ledger "5 8294400" "3d42 parent ledger charges the parent's own fifth read"

# Parent over budget does not block the sub-agent.
expect 2 "3d42 parent blocked at the 8 MiB budget" \
  "$(read_payload "$TMP/p3-5.png" "$S3")" HQ_HOOK_AGENT_ID=
expect 0 "3d42 sub-agent allowed while the parent is over budget" \
  "$(agent_payload "$TMP/p3-5.png" "$S3" agent-3d42)" HQ_HOOK_AGENT_ID=
expect 0 "3d42 transcript-keyed sub-agent allowed while the parent is over budget" \
  "$(transcript_payload "$TMP/s3-c.png" "$S3" "/p/proj/$S3/subagents/agent-a3d42t.jsonl")"
expect_ledger "5 8294400" "3d42 parent ledger unchanged after over-budget sub-agent reads"
# A dot-only id must not resolve the sub-agent ledger back onto the parent.
expect 0 "3d42 transcript id '..' gets its own ledger" \
  "$(transcript_payload "$TMP/s3-c.png" "$S3" "/p/proj/$S3/subagents/agent-...jsonl")"
expect 0 "3d42 agent_id '.' gets its own ledger" \
  "$(agent_payload "$TMP/s3-c.png" "$S3" ".")" HQ_HOOK_AGENT_ID=
expect_ledger "5 8294400" "3d42 dot-only sub-agent ids leave the parent ledger unchanged"
if [ -f "$FIX/workspace/orchestrator/hook-state/image-context/$S3/agents/a3d42t/reads.txt" ]; then
  ok "3d42 transcript-keyed sub-agent has its own ledger"
else
  bad "3d42 transcript-keyed sub-agent ledger missing"
fi

# The parent's own transcript path, or a look-alike outside subagents/, stays
# on the parent ledger and is still blocked.
expect 2 "3d42 parent with its own transcript_path still blocked" \
  "$(transcript_payload "$TMP/p3-5.png" "$S3" "/p/proj/$S3.jsonl")"
expect 2 "3d42 agent-*.jsonl outside subagents/ stays on the parent" \
  "$(transcript_payload "$TMP/p3-5.png" "$S3" "/p/proj/$S3/notes/agent-x.jsonl")"

# The 2 MiB per-image limit applies to parent and sub-agent alike.
expect 2 "3d42 parent 3MiB image blocked at the 2 MiB limit" \
  "$(read_payload "$LARGE" "$S3")" HQ_HOOK_AGENT_ID=
expect 2 "3d42 sub-agent 3MiB image blocked at the 2 MiB limit" \
  "$(agent_payload "$LARGE" "$S3" agent-3d42)" HQ_HOOK_AGENT_ID=

# 32-image ceiling: the parent's 33rd distinct image is blocked, and a
# sub-agent in the same session still reads.
S3C="sess-3d42-count"
i=1
while [ "$i" -le 33 ]; do
  printf 'x' >"$TMP/n3-$i.png"
  i=$((i + 1))
done
i=1
n_ok=0
while [ "$i" -le 32 ]; do
  rc=0
  printf '%s' "$(read_payload "$TMP/n3-$i.png" "$S3C")" \
    | env CLAUDE_PROJECT_DIR="$FIX" HQ_ROOT="$FIX" HQ_HOOK_AGENT_ID= bash "$FIX_HOOK" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && n_ok=$((n_ok + 1))
  i=$((i + 1))
done
if [ "$n_ok" -eq 32 ]; then ok "3d42 parent's 32 tiny images allowed"; else bad "3d42 parent tiny images allowed=$n_ok want 32"; fi
expect 2 "3d42 parent's 33rd distinct image blocked" \
  "$(read_payload "$TMP/n3-33.png" "$S3C")" HQ_HOOK_AGENT_ID=
expect 0 "3d42 sub-agent reads after the parent hits the 32-image ceiling" \
  "$(agent_payload "$TMP/n3-33.png" "$S3C" agent-3d42)" HQ_HOOK_AGENT_ID=

# Ledgers written by the count-only guard (bare paths) still load: each line
# is charged the 64 KiB floor and a re-read of a listed path stays free.
LEGACY="$FIX/workspace/orchestrator/hook-state/image-context/sess-legacy"
mkdir -p "$LEGACY"
: >"$LEGACY/reads.txt"
i=1
while [ "$i" -le 8 ]; do
  printf 'x' >"$TMP/legacy$i.png"
  printf '%s\n' "$TMP/legacy$i.png" >>"$LEGACY/reads.txt"
  i=$((i + 1))
done
printf 'x' >"$TMP/legacy9.png"
expect 0 "legacy ledger re-read allowed" "$(read_payload "$TMP/legacy1.png" sess-legacy)"
expect 0 "legacy ledger with 8 entries allows a ninth small image" "$(read_payload "$TMP/legacy9.png" sess-legacy)"

# Multi-image call.
multi="$(jq -nc --arg p "$SMALL" '{tool_name:"view_image",tool_input:{paths:[$p,$p]}}')"
expect 2 "two paths in one call blocked" "$multi"

# Gate: all three profiles actually run the hook (not pass-through).
payload_gate="$(read_payload "$LARGE")"
for p in minimal standard strict; do
  rc=0
  printf '%s' "$payload_gate" \
    | HQ_HOOK_PROFILE="$p" CLAUDE_PROJECT_DIR="$FIX" HQ_ROOT="$FIX" \
      bash "$GATE" image-context-guard "$FIX_HOOK" >/dev/null 2>"$TMP/err" || rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "hook-gate profile $p blocks"
  else
    bad "hook-gate profile $p want 2 got $rc"
  fi
done

# Wiring.
if jq -e '[.hooks.PreToolUse[] | select(.matcher == "Read") | .hooks[] | select(.id == "image-context-guard")] | length == 1' \
  "$REGISTRY" >/dev/null; then
  ok "registry binds image-context-guard to Read"
else
  bad "registry missing Read image-context-guard"
fi
if jq -e '[.hooks.PreToolUse[] | select(.matcher == "view_image") | .hooks[] | select(.id == "image-context-guard")] | length == 1' \
  "$REGISTRY" >/dev/null; then
  ok "registry binds image-context-guard to view_image"
else
  bad "registry missing view_image image-context-guard"
fi
if grep -q 'image-context-guard' "$ROOT/.claude/hooks/hook-gate.sh"; then
  ok "hook-gate lists image-context-guard"
else
  bad "hook-gate missing image-context-guard"
fi
if grep -q 'image-context-guard' "$ROOT/core/scripts/lib/hook-adapter-core.sh"; then
  ok "adapter fallback lists image-context-guard"
else
  bad "adapter fallback missing image-context-guard"
fi

# Policy and always-loaded native context measure bytes.
if grep -q '2 MiB\|2MB\|2 MB' "$POLICY" && grep -qi 'byte' "$POLICY"; then
  ok "policy bounds bytes"
else
  bad "policy still count-only"
fi
if grep -q 'image-context-guard' "$POLICY"; then
  ok "policy names the mechanical guard"
else
  bad "policy does not name PreToolUse enforcement"
fi
if grep -q 'file size' "$PERSONAL" && grep -q 'image-context-guard' "$PERSONAL"; then
  ok "personal-context names the byte cap"
else
  bad "personal-context missing image byte cap"
fi

# Charter warning must not claim app hooks never fire.
if grep -Fq 'are not dispatched' "$PERSONAL"; then
  bad "personal-context still claims hooks are not dispatched"
else
  ok "personal-context no longer claims hooks never fire"
fi
if grep -Fq 'HQ RUNTIME WARNING:' "$PERSONAL"; then
  ok "runtime warning heading kept"
else
  bad "runtime warning heading missing"
fi
if grep -Fq 'are not dispatched' "$DOC"; then
  bad "HOOKS-NOT-FIRING.md still claims hooks are not dispatched"
else
  ok "HOOKS-NOT-FIRING.md no longer claims hooks never fire"
fi
if grep -Fq 'check-hq-hooks.sh --root' "$DOC"; then
  ok "HOOKS-NOT-FIRING.md still names the doctor command"
else
  bad "HOOKS-NOT-FIRING.md lost the doctor command"
fi

if grep -Fq 'command hooks are not dispatched' "$ROOT/core/scripts/check-hq-hooks.sh"; then
  bad "check-hq-hooks.sh still claims app hooks never fire"
else
  ok "check-hq-hooks.sh no longer claims app hooks never fire"
fi

if [ -f "$ROOT/core/policies/hq-unenforced-core-policy-is-a-defect.md" ]; then
  ok "unenforced-core-policy defect class exists"
else
  bad "missing hq-unenforced-core-policy-is-a-defect.md"
fi

if [ "$fail" -eq 0 ]; then
  echo "ALL PASS: image-context-guard ($pass)"
  exit 0
fi
echo "FAILURES: image-context-guard ($fail failed, $pass passed)" >&2
exit 1
