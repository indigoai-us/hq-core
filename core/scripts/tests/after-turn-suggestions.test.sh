#!/usr/bin/env bash
# Smoke tests for the global after-turn suggestion Stop hook.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HQ_ROOT="$(cd "$SRC_ROOT/.." && pwd)"
HOOK="$SRC_ROOT/hooks/Stop/50-after-turn-suggestions.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if ! printf '%s' "$haystack" | grep -qF "$needle"; then
    fail "$label: missing '$needle'"
  fi
}

assert_empty() {
  local value="$1"
  local label="$2"
  if [ -n "$value" ]; then
    fail "$label: expected empty output, got: $value"
  fi
}

[ -x "$HOOK" ] || fail "hook is not executable: $HOOK"

mkdir -p "$TMP_ROOT/.claude/state" "$TMP_ROOT/.claude/skills/_shared" "$TMP_ROOT/workspace" "$TMP_ROOT/projects/demo/journal" "$TMP_ROOT/projects/other"
ln -s "$HQ_ROOT/.claude/skills/_shared/journal.sh" "$TMP_ROOT/.claude/skills/_shared/journal.sh"

cat > "$TMP_ROOT/projects/demo/journal/active.md" <<'EOF'
---
skill: prd
started_at: 2026-05-13T00:00:00Z
thread_id: test
project: projects/demo
status: active
auto_capture: true
summary: ""
---

## Decisions
EOF

JOURNAL_HELPER="$TMP_ROOT/.claude/skills/_shared/journal.sh"
CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_JOURNAL_SESSION=s-test "$JOURNAL_HELPER" open prd "$TMP_ROOT/projects/demo" s-test >/dev/null

cat > "$TMP_ROOT/projects/demo/prd.json" <<'EOF'
{
  "name": "demo",
  "userStories": [
    { "id": "US-001", "title": "First story", "passes": false },
    { "id": "US-002", "title": "Second story", "passes": true }
  ]
}
EOF

TRANSCRIPT="$TMP_ROOT/transcript.jsonl"
cat > "$TRANSCRIPT" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"Project **demo** created with 2 user stories.\nFiles:\n  projects/demo/prd.json"}]}}
EOF

payload=$(printf '{"session_id":"s-test","transcript_path":"%s"}' "$TRANSCRIPT")

out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_AFTER_TURN_SUGGESTIONS=1 bash "$HOOK" <<<"$payload")
assert_contains "$out" "<hq-suggestions>" "suggestion wrapper"
assert_contains "$out" "/execute-task demo/US-001" "next incomplete story suggestion"
assert_contains "$out" "HQ_AFTER_TURN_SUGGESTIONS=0" "first-run disable hint"

out_disabled=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_AFTER_TURN_SUGGESTIONS=0 bash "$HOOK" <<<"$payload")
assert_empty "$out_disabled" "HQ_AFTER_TURN_SUGGESTIONS=0 disables hook"

out_disabled_hook=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_DISABLED_HOOKS=after-turn-suggestions bash "$HOOK" <<<"$payload")
assert_empty "$out_disabled_hook" "HQ_DISABLED_HOOKS disables hook"

touch "$TMP_ROOT/.claude/state/after-turn-suggestions.disabled"
out_disabled_file=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$payload")
assert_empty "$out_disabled_file" "state file disables hook"
rm -f "$TMP_ROOT/.claude/state/after-turn-suggestions.disabled"

cat > "$TMP_ROOT/projects/other/prd.json" <<'EOF'
{
  "name": "other",
  "userStories": [
    { "id": "US-999", "title": "Other story", "passes": false }
  ]
}
EOF

CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_JOURNAL_SESSION=session-demo "$JOURNAL_HELPER" open prd "$TMP_ROOT/projects/demo" session-demo >/dev/null
CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_JOURNAL_SESSION=session-other "$JOURNAL_HELPER" open prd "$TMP_ROOT/projects/other" session-other >/dev/null

demo_payload=$(printf '{"session_id":"session-demo","transcript_path":"%s"}' "$TRANSCRIPT")
other_payload=$(printf '{"session_id":"session-other","transcript_path":"%s"}' "$TRANSCRIPT")
demo_out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$demo_payload")
other_out=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$HOOK" <<<"$other_payload")
assert_contains "$demo_out" "/execute-task demo/US-001" "session demo journal selection"
assert_contains "$other_out" "/execute-task other/US-999" "session other journal selection"
if printf '%s' "$demo_out" | grep -qF "/execute-task other/US-999"; then
  fail "session demo read another session's journal"
fi

# Regression: the hook runs after every turn, and long sessions grow their
# transcript to hundreds of MB. A full-file scan there cost ~6s per run (one
# 270 MB session spent 25-60s per turn in Stop hooks), so the hook must read
# only a bounded tail of the transcript. Shim every full-file reader the hook
# could plausibly use and fail if one of them is handed the transcript path.
#
# The shims are POSIX sh with builtins only, and the hook runs with BASH_ENV
# and ENV unset. A bash shim would source BASH_ENV (often ~/.bashrc) at
# startup; if that file calls any shimmed tool, every call starts another
# shim and the test becomes a fork bomb.
SHIM_DIR="$TMP_ROOT/shim-bin"
SHIM_LOG="$TMP_ROOT/shim.log"
mkdir -p "$SHIM_DIR"
: > "$SHIM_LOG"
#
# Reverse readers count as full-file readers too: an uncapped reverse scan
# (tac, or BSD tail -r) walks back toward the start of the file whenever the
# newest assistant record is far from EOF. Plain tail -c / tail -n read from
# the end and stay bounded, so only tail -r is flagged.
for tool in awk cat grep sed jq perl python3 head wc cut sort tac tail; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  case "$real" in /*) ;; *) continue ;; esac
  flagged_tool=1
  [ "$tool" = tail ] && flagged_tool=0
  cat > "$SHIM_DIR/$tool" <<EOF
#!/bin/sh
flag=$flagged_tool
for arg in "\$@"; do
  [ "\$arg" = "-r" ] && flag=1
done
if [ "\$flag" = 1 ]; then
  for arg in "\$@"; do
    case "\$arg" in
      *big-transcript.jsonl) printf '%s %s\n' "$tool" "\$arg" >> "$SHIM_LOG" ;;
    esac
  done
fi
exec "$real" "\$@"
EOF
  chmod +x "$SHIM_DIR/$tool"
done
run_hook_with_shims() {
  env -u BASH_ENV -u ENV CLAUDE_PROJECT_DIR="$TMP_ROOT" PATH="$SHIM_DIR:$PATH" \
    bash "$HOOK"
}

BIG="$TMP_ROOT/big-transcript.jsonl"
filler="$(printf '%*s' 8192 '' | tr ' ' 'x')"
{
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Old turn: the build failed and I was blocked."}]}}'
  i=0
  while [ "$i" -lt 300 ]; do
    printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"%s"}]}}\n' "$filler"
    i=$((i + 1))
  done
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Handoff ready. To continue in a fresh session, run startwork."}]}}'
} > "$BIG"
big_size="$(wc -c < "$BIG" | tr -d ' ')"
[ "$big_size" -gt 2000000 ] || fail "fixture transcript too small to exercise the bounded read: $big_size bytes"

big_payload=$(printf '{"session_id":"s-big","transcript_path":"%s"}' "$BIG")
big_out=$(run_hook_with_shims <<<"$big_payload")
assert_contains "$big_out" "resume from the handoff" "large transcript uses the newest assistant turn"
if printf '%s' "$big_out" | grep -qF "/investigate"; then
  fail "large transcript: suggestion came from an older assistant turn"
fi
if [ -s "$SHIM_LOG" ]; then
  fail "large transcript was read in full by: $(tr '\n' ';' < "$SHIM_LOG")"
fi

# When more than the bounded window of records follows the newest assistant
# record, the hook must not scan backward to find it: these suggestions are
# advisory, so it falls back to the generic ones. It must never pick an older
# assistant turn instead.
TRAILING="$TMP_ROOT/trailing-big-transcript.jsonl"
{
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Old turn: the build failed and I was blocked."}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Handoff ready for the next session."}]}}'
  i=0
  while [ "$i" -lt 300 ]; do
    printf '{"type":"system","content":"%s"}\n' "$filler"
    i=$((i + 1))
  done
} > "$TRAILING"
: > "$SHIM_LOG"
trailing_payload=$(printf '{"session_id":"s-trailing","transcript_path":"%s"}' "$TRAILING")
trailing_out=$(run_hook_with_shims <<<"$trailing_payload")
assert_contains "$trailing_out" "<hq-suggestions>" "long tail still emits suggestions"
if printf '%s' "$trailing_out" | grep -qF "/investigate"; then
  fail "long tail: suggestion came from an older assistant turn"
fi
if [ -s "$SHIM_LOG" ]; then
  fail "long-tail transcript was read in full by: $(tr '\n' ';' < "$SHIM_LOG")"
fi

echo "after-turn-suggestions smoke: ok"
