#!/usr/bin/env bash
# Regression coverage for the reusable /setup completeness probe and its
# throttled SessionStart reminder.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$(cd "$SRC_ROOT/.." && pwd)"
STATUS="$SRC_ROOT/scripts/setup-status.sh"
HOOK="$SRC_ROOT/hooks/SessionStart/20-setup-completeness-nag.sh"
TMP_ROOT="$(mktemp -d)"
TMP_HOME="$TMP_ROOT/home"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if ! grep -qF "$needle" <<<"$haystack"; then
    fail "$label: missing '$needle'"
  fi
}

assert_empty() {
  local value="$1" label="$2"
  if [ -n "$value" ]; then
    fail "$label: expected empty output, got: $value"
  fi
}

assert_json() {
  local json="$1" query="$2" expected="$3" label="$4"
  local actual
  actual="$(jq -r "$query" <<<"$json")"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

status_json() {
  local root="$1"
  HOME="$TMP_HOME" "$STATUS" --root "$root" --json
}

make_hook_root() {
  local root="$1"
  mkdir -p "$root/core/scripts" "$root/.claude"
  printf 'name: fixture\n' > "$root/core/core.yaml"
  ln -s "$STATUS" "$root/core/scripts/setup-status.sh"
}

populate_required() {
  local root="$1"
  mkdir -p "$root/repos/public" "$root/repos/private"
  mkdir -p "$root/personal/knowledge" "$root/personal/policies" "$root/personal/workers"
  mkdir -p "$root/personal/settings" "$root/personal/skills" "$root/personal/hooks"
  cat > "$root/personal/knowledge/profile.md" <<'EOF'
# Ada Example's Profile

## About
Engineer and operator.

## Goals
Build reliable systems.
EOF
  printf '# Ada Example - Profile\n' > "$root/agents-profile.md"
  printf '# Systems of Record\n' > "$root/personal/knowledge/systems-of-record.md"
  printf '# Voice Style\n' > "$root/personal/knowledge/voice-style.md"
  printf '# Company Contexts\n' > "$root/personal/agents-companies.md"
  printf '# Getting Started\n' > "$root/personal/knowledge/getting-started-next-steps.md"
}

[ -x "$STATUS" ] || fail "status script is not executable: $STATUS"
[ -x "$HOOK" ] || fail "hook is not executable: $HOOK"
mkdir -p "$TMP_HOME"

# 1. Empty installs report every required check and the hook points to /setup.
empty_root="$TMP_ROOT/empty"
mkdir -p "$empty_root"
make_hook_root "$empty_root"
empty_rc=0
empty_json="$(status_json "$empty_root")" || empty_rc=$?
[ "$empty_rc" -eq 1 ] || fail "empty fixture status exit: expected 1, got $empty_rc"
assert_json "$empty_json" '.complete' false "empty fixture complete flag"
for id in repos-dirs personal-scaffold profile agents-profile systems-of-record voice-style agents-companies next-steps; do
  jq -e --arg id "$id" '.missingRequired | index($id) != null' <<<"$empty_json" >/dev/null \
    || fail "empty fixture missingRequired: missing '$id'"
done

# 2. CI deliberately suppresses the advisory hook, even for incomplete setup.
ci_nag="$(CI=1 HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$empty_root" bash "$HOOK" </dev/null)"
assert_empty "$ci_nag" "CI setup nag opt-out"

empty_nag="$(env -u CI HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$empty_root" bash "$HOOK" </dev/null)"
assert_contains "$empty_nag" "/setup" "empty fixture hook nag"

# 3. A second incomplete-session hook run is throttled; zero interval re-enables it.
throttled_nag="$(env -u CI HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$empty_root" bash "$HOOK" </dev/null)"
assert_empty "$throttled_nag" "setup nag throttle"
unthrottled_nag="$(env -u CI HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$empty_root" HQ_SETUP_NAG_INTERVAL_HOURS=0 bash "$HOOK" </dev/null)"
assert_contains "$unthrottled_nag" "/setup" "zero-interval setup nag"

# 4. The opt-out remains silent even when setup is incomplete.
opted_out_nag="$(env -u CI HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$empty_root" HQ_NO_SETUP_NAG=1 bash "$HOOK" </dev/null)"
assert_empty "$opted_out_nag" "HQ_NO_SETUP_NAG opt-out"

# 5. Every durable setup artifact makes the required checklist complete.
complete_root="$TMP_ROOT/complete"
make_hook_root "$complete_root"
populate_required "$complete_root"
complete_rc=0
complete_json="$(status_json "$complete_root")" || complete_rc=$?
[ "$complete_rc" -eq 0 ] || fail "complete fixture status exit: expected 0, got $complete_rc"
assert_json "$complete_json" '.complete' true "complete fixture complete flag"
complete_nag="$(env -u CI HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$complete_root" bash "$HOOK" </dev/null)"
assert_empty "$complete_nag" "complete fixture hook"

# 6. A template-looking profile is not a completed profile.
placeholder_root="$TMP_ROOT/placeholder"
make_hook_root "$placeholder_root"
populate_required "$placeholder_root"
printf '# {Name}\n\n## About\n{Answer from Q2}\n' > "$placeholder_root/personal/knowledge/profile.md"
placeholder_rc=0
placeholder_json="$(status_json "$placeholder_root")" || placeholder_rc=$?
[ "$placeholder_rc" -eq 1 ] || fail "placeholder fixture status exit: expected 1, got $placeholder_rc"
assert_json "$placeholder_json" '.complete' false "placeholder fixture complete flag"
jq -e '.missingRequired | index("profile") != null' <<<"$placeholder_json" >/dev/null \
  || fail "placeholder fixture missingRequired: missing 'profile'"

# 7. Empty required content files are not setup artifacts.
empty_content_root="$TMP_ROOT/empty-content"
make_hook_root "$empty_content_root"
populate_required "$empty_content_root"
printf ' \n\t\n' > "$empty_content_root/personal/knowledge/profile.md"
for path in \
  personal/knowledge/systems-of-record.md \
  personal/knowledge/voice-style.md \
  personal/agents-companies.md \
  personal/knowledge/getting-started-next-steps.md; do
  printf ' \n\t\n' > "$empty_content_root/$path"
done
empty_content_rc=0
empty_content_json="$(status_json "$empty_content_root")" || empty_content_rc=$?
[ "$empty_content_rc" -eq 1 ] || fail "empty content fixture status exit: expected 1, got $empty_content_rc"
for id in profile systems-of-record voice-style agents-companies next-steps; do
  jq -e --arg id "$id" '.missingRequired | index($id) != null' <<<"$empty_content_json" >/dev/null \
    || fail "empty content fixture missingRequired: missing '$id'"
done

# 8. An accepted /import-context run suppresses a footprint-only reminder.
context_import_root="$TMP_ROOT/context-import"
make_hook_root "$context_import_root"
populate_required "$context_import_root"
mkdir -p "$context_import_root/companies" "$context_import_root/workspace/imports" "$TMP_HOME/.claude/plans"
printf 'companies: {}\n' > "$context_import_root/companies/manifest.yaml"
printf '# Prior plan\n' > "$TMP_HOME/.claude/plans/prior.md"
context_before_json="$(status_json "$context_import_root")"
assert_json "$context_before_json" '.checks[] | select(.id == "context-import") | .done' false \
  "prior footprint context import check"
printf '{}\n' > "$context_import_root/workspace/imports/index.json"
context_after_json="$(status_json "$context_import_root")"
assert_json "$context_after_json" '.checks[] | select(.id == "context-import") | .done' true \
  "recorded context import check"

# 9. A lock left by an interrupted process expires and does not suppress the nag.
stale_lock_root="$TMP_ROOT/stale-lock"
make_hook_root "$stale_lock_root"
mkdir -p "$stale_lock_root/.claude/state/setup-completeness-nag.lock"
touch -d '6 minutes ago' "$stale_lock_root/.claude/state/setup-completeness-nag.lock"
stale_lock_nag="$(env -u CI HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$stale_lock_root" \
  HQ_SETUP_NAG_INTERVAL_HOURS=0 bash "$HOOK" </dev/null)"
assert_contains "$stale_lock_nag" "/setup" "stale setup nag lock recovery"

# 10. Decimal intervals accept leading zeroes without octal parsing or errors.
interval_root="$TMP_ROOT/interval"
make_hook_root "$interval_root"
mkdir -p "$interval_root/.claude/state"
now="$(date +%s)"
printf '%s\n' "$((now - 9 * 3600))" > "$interval_root/.claude/state/setup-completeness-nag.last"
interval_ten_nag="$(env -u CI HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$interval_root" \
  HQ_SETUP_NAG_INTERVAL_HOURS=010 bash "$HOOK" </dev/null)"
assert_empty "$interval_ten_nag" "zero-padded ten-hour interval"
printf '%s\n' "$((now - 9 * 3600))" > "$interval_root/.claude/state/setup-completeness-nag.last"
interval_eight_nag="$(env -u CI HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$interval_root" \
  HQ_SETUP_NAG_INTERVAL_HOURS=08 bash "$HOOK" </dev/null)"
assert_contains "$interval_eight_nag" "/setup" "zero-padded eight-hour interval"
printf '%s\n' "$((now - 9 * 3600))" > "$interval_root/.claude/state/setup-completeness-nag.last"
invalid_interval_nag="$(env -u CI HOME="$TMP_HOME" CLAUDE_PROJECT_DIR="$interval_root" \
  HQ_SETUP_NAG_INTERVAL_HOURS=not-a-number bash "$HOOK" </dev/null)"
assert_empty "$invalid_interval_nag" "non-numeric interval falls back to default"

# 11. The nag throttle and its lock are local hook runtime state, never changes.
for state_path in \
  .claude/state/setup-completeness-nag.last \
  .claude/state/setup-completeness-nag.lock/; do
  git -C "$REPO_ROOT" check-ignore -q -- "$state_path" \
    || fail "runtime state is not ignored: $state_path"
done

echo "setup-completeness-nag smoke: ok"
