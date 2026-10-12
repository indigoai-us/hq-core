#!/usr/bin/env bash
# Regression: image-context-guard.sh blocks oversized / high-count image reads.
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

# Session count cap (byte-small files): 8 unique allowed, 9th blocked.
i=1
while [ "$i" -le 8 ]; do
  f="$TMP/s$i.png"
  printf 'x' >"$f"
  expect 0 "session image $i allowed" "$(read_payload "$f" sess-count)"
  i=$((i + 1))
done
printf 'x' >"$TMP/s9.png"
expect 2 "ninth unique image blocked" "$(read_payload "$TMP/s9.png" sess-count)"
expect 0 "re-read of an already-counted image allowed" "$(read_payload "$TMP/s1.png" sess-count)"
expect 0 "other session has its own count" "$(read_payload "$TMP/s9.png" sess-other)"

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
