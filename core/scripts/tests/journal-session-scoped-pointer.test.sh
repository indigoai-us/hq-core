#!/usr/bin/env bash
# Regression: journal pointers are isolated by session and owned by project.

set -euo pipefail

CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HQ_ROOT="$(cd "$CORE_ROOT/.." && pwd)"
HELPER="$HQ_ROOT/.claude/skills/_shared/journal.sh"
AUTOCAPTURE="$HQ_ROOT/.claude/hooks/journal-autocapture.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

assert_file_contains() {
  grep -qF "$2" "$1" || fail "$3: missing '$2' in $1"
}

assert_file_not_contains() {
  if grep -qF "$2" "$1"; then
    fail "$3: unexpectedly found '$2' in $1"
  fi
}

[ -x "$HELPER" ] || fail "journal helper is not executable"
[ -x "$AUTOCAPTURE" ] || fail "autocapture hook is not executable"

mkdir -p "$TMP_ROOT/.claude/state" \
  "$TMP_ROOT/.claude/skills/_shared" \
  "$TMP_ROOT/companies/alpha/projects/one" \
  "$TMP_ROOT/companies/beta/projects/two" \
  "$TMP_ROOT/personal/projects/legacy"
ln -s "$HELPER" "$TMP_ROOT/.claude/skills/_shared/journal.sh"

ALPHA="$TMP_ROOT/companies/alpha/projects/one"
BETA="$TMP_ROOT/companies/beta/projects/two"
LEGACY="$TMP_ROOT/personal/projects/legacy"

alpha_journal=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_JOURNAL_SESSION='alpha/session' "$HELPER" open brainstorm "$ALPHA" alpha-thread)
beta_journal=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_JOURNAL_SESSION='beta/session' "$HELPER" open plan "$BETA" beta-thread)
[ "$alpha_journal" != "$beta_journal" ] || fail "sessions opened the same journal"

alpha_pointer=$(grep -rlF "$alpha_journal" "$TMP_ROOT/.claude/state/active-journal.d" | head -1)
beta_pointer=$(grep -rlF "$beta_journal" "$TMP_ROOT/.claude/state/active-journal.d" | head -1)
[ -n "$alpha_pointer" ] || fail "alpha scoped pointer was not created"
[ -n "$beta_pointer" ] || fail "beta scoped pointer was not created"
case "$(basename "$alpha_pointer")" in *'/'*) fail "session pointer name was not sanitized" ;; esac

assert_eq "$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_JOURNAL_SESSION='alpha/session' "$HELPER" path)" "$alpha_journal" "alpha pointer lookup"
assert_eq "$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_JOURNAL_SESSION='beta/session' "$HELPER" path)" "$beta_journal" "beta pointer lookup"

CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_JOURNAL_SESSION='alpha/session' "$HELPER" append "$ALPHA" decisions "alpha decision"
assert_file_contains "$alpha_journal" "alpha decision" "owned append"
assert_file_not_contains "$beta_journal" "alpha decision" "cross-session append isolation"

CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_JOURNAL_SESSION='alpha/session' "$HELPER" append "$BETA" decisions "wrong company" >/dev/null
assert_file_not_contains "$alpha_journal" "wrong company" "project mismatch append rejection"

printf 'wrong attachment' | CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_JOURNAL_SESSION='alpha/session' "$HELPER" attach "$BETA" attachment - --ext txt >/dev/null
[ ! -d "$ALPHA/journal/attachments" ] || fail "project mismatch attach wrote an attachment"

auto_payload='{"session_id":"alpha/session","tool_name":"Agent","tool_input":{"description":"alpha worker"},"tool_response":"alpha capture"}'
CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$AUTOCAPTURE" <<<"$auto_payload"
auto_payload='{"session_id":"beta/session","tool_name":"Agent","tool_input":{"description":"beta worker"},"tool_response":"beta capture"}'
CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$AUTOCAPTURE" <<<"$auto_payload"
assert_file_contains "$alpha_journal" "alpha capture" "alpha autocapture"
assert_file_not_contains "$alpha_journal" "beta capture" "autocapture session isolation"
assert_file_contains "$beta_journal" "beta capture" "beta autocapture"

attachment=$(printf 'owned attachment' | CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_JOURNAL_SESSION='beta/session' "$HELPER" attach "$BETA" attachment - --ext txt)
[ -f "$attachment" ] || fail "owned attach did not write attachment"
case "$attachment" in "$BETA"/*) ;; *) fail "owned attachment escaped its project" ;; esac

CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_JOURNAL_SESSION='alpha/session' "$HELPER" close "$ALPHA" "alpha complete"
[ ! -e "$alpha_pointer" ] || fail "close did not clear its session pointer"
[ -e "$beta_pointer" ] || fail "close cleared another session pointer"
assert_file_contains "$alpha_journal" 'status: closed' "close status"

printf '%s' "$alpha_journal" > "$alpha_pointer"
CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_JOURNAL_SESSION='alpha/session' "$HELPER" append "$ALPHA" decisions "closed mutation" >/dev/null
assert_file_not_contains "$alpha_journal" "closed mutation" "closed journal append rejection"
sed -i 's/^status: closed$/status: abandoned/' "$alpha_journal"
CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_JOURNAL_SESSION='alpha/session' "$HELPER" append "$ALPHA" decisions "abandoned mutation" >/dev/null
assert_file_not_contains "$alpha_journal" "abandoned mutation" "abandoned journal append rejection"

legacy_journal=$(env -u HQ_JOURNAL_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u CODEX_SESSION_ID -u CODEX_THREAD_ID CLAUDE_PROJECT_DIR="$TMP_ROOT" "$HELPER" open legacy "$LEGACY" legacy-thread)
assert_eq "$(env -u HQ_JOURNAL_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u CODEX_SESSION_ID -u CODEX_THREAD_ID CLAUDE_PROJECT_DIR="$TMP_ROOT" "$HELPER" path)" "$legacy_journal" "legacy fallback"
scoped_missing=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_JOURNAL_SESSION='no-fallback' "$HELPER" path 2>/dev/null || true)
[ -z "$scoped_missing" ] || fail "scoped caller fell back to the legacy pointer"
legacy_payload='{"tool_name":"Agent","tool_input":{"description":"legacy worker"},"tool_response":"legacy capture"}'
CLAUDE_PROJECT_DIR="$TMP_ROOT" bash "$AUTOCAPTURE" <<<"$legacy_payload"
assert_file_not_contains "$legacy_journal" "legacy capture" "autocapture without a session ID"

stale_journal=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_JOURNAL_SESSION='stale/session' "$HELPER" open stale "$ALPHA" stale-thread)
stale_pointer=$(grep -rlF "$stale_journal" "$TMP_ROOT/.claude/state/active-journal.d" | head -1)
rm -f "$stale_journal"
stale_lookup=$(CLAUDE_PROJECT_DIR="$TMP_ROOT" HQ_JOURNAL_SESSION='stale/session' "$HELPER" path 2>/dev/null || true)
[ -z "$stale_lookup" ] || fail "stale pointer returned a missing journal"
[ ! -e "$stale_pointer" ] || fail "stale scoped pointer was not garbage-collected"

echo "journal session-scoped pointers: ok"
