#!/usr/bin/env bash
# Regression: trigger migration must not promote trigger-less non-hard policies
# into the always-on SessionStart baseline. Hard-policy fallback and ordinary
# reactive trigger derivation/injection remain unchanged.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
MIGRATOR="$ROOT/core/scripts/migrate-policy-triggers.sh"
HOOK="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_line() { grep -qxF "$2" "$1" || fail "$3: missing '$2' in $1"; }
assert_no_field() { ! grep -q "^$2:" "$1" || fail "$3: unexpected $2 in $1"; }

mkdir -p "$TMP/core/policies" "$TMP/workspace/orchestrator/policy-trigger-state"

cat > "$TMP/core/policies/hard-triggerless.md" <<'EOF'
---
id: hard-triggerless
enforcement: hard
---

## Rule
Hard policies remain part of the startup baseline when no signal exists.
EOF

cat > "$TMP/core/policies/soft-triggerless.md" <<'EOF'
---
id: soft-triggerless
enforcement: soft
---

## Rule
Soft trigger-less policies must not become startup baseline noise.
EOF

cat > "$TMP/core/policies/unset-triggerless.md" <<'EOF'
---
id: unset-triggerless
---

## Rule
Unset trigger-less policies must not become startup baseline noise.
EOF

cat > "$TMP/core/policies/normal-triggered.md" <<'EOF'
---
id: normal-triggered
enforcement: soft
trigger: when deploying
---

## Rule
Normal triggered policies still inject when their signal appears.
EOF

HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  bash "$MIGRATOR" "$TMP/core/policies" 2>"$TMP/migrate.err"

assert_line "$TMP/core/policies/hard-triggerless.md" "when: always" \
  "hard trigger-less fallback"
assert_line "$TMP/core/policies/hard-triggerless.md" "on: [SessionStart]" \
  "hard trigger-less event"
assert_no_field "$TMP/core/policies/soft-triggerless.md" when \
  "soft trigger-less policy"
assert_no_field "$TMP/core/policies/soft-triggerless.md" on \
  "soft trigger-less policy"
assert_no_field "$TMP/core/policies/unset-triggerless.md" when \
  "unset trigger-less policy"
assert_no_field "$TMP/core/policies/unset-triggerless.md" on \
  "unset trigger-less policy"
assert_line "$TMP/core/policies/normal-triggered.md" "when: deploy" \
  "normal reactive trigger"
assert_line "$TMP/core/policies/normal-triggered.md" \
  "on: [PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]" \
  "normal reactive events"

run_hook() {
  printf '%s' "$1" | HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" 2>/dev/null || true
}

start_out="$(run_hook '{"hook_event_name":"SessionStart","session_id":"rebloat-start","cwd":"'"$TMP"'"}')"
grep -q 'hard-triggerless' <<<"$start_out" || fail "hard fallback did not inject at SessionStart: [$start_out]"
grep -q 'soft-triggerless' <<<"$start_out" && fail "soft trigger-less policy injected at SessionStart: [$start_out]"
grep -q 'unset-triggerless' <<<"$start_out" && fail "unset trigger-less policy injected at SessionStart: [$start_out]"
grep -q 'normal-triggered' <<<"$start_out" && fail "reactive policy injected at SessionStart: [$start_out]"

# Pre-warm the normal policy's session so the hard baseline is already deduped,
# then prove the ordinary deploy trigger still surfaces through the live path.
run_hook '{"hook_event_name":"SessionStart","session_id":"normal-session","cwd":"'"$TMP"'"}' >/dev/null
normal_out="$(run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"normal-session","cwd":"'"$TMP"'","prompt":"deploy the release"}')"
grep -q 'normal-triggered' <<<"$normal_out" || fail "normal triggered policy did not inject: [$normal_out]"
grep -q 'soft-triggerless' <<<"$normal_out" && fail "soft trigger-less policy injected on later event: [$normal_out]"
grep -q 'unset-triggerless' <<<"$normal_out" && fail "unset trigger-less policy injected on later event: [$normal_out]"

# Idempotence: a second migration must leave all files byte-for-byte unchanged.
before="$(sha256sum "$TMP/core/policies/"*.md)"
HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
  bash "$MIGRATOR" "$TMP/core/policies" 2>"$TMP/migrate-second.err"
after="$(sha256sum "$TMP/core/policies/"*.md)"
[ "$before" = "$after" ] || fail "second migration changed policy files"

echo "PASS: migrate-policy-triggers enforcement-gated fallback"
