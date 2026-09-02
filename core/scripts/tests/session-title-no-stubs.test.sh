#!/usr/bin/env bash
# session-title-no-stubs.test.sh
#
# The compute helper must print NOTHING when it has no project and no
# repo/product to name. Everything it could otherwise say in that state is
# information-free — a bare command word ("chat", "startwork") or a lone org
# token ("HQ") — and emitting it is worse than silence: the wrapper overwrites
# the host's written summary with a word that distinguishes nothing, and since
# the stub never changes, the change-only cadence then keeps the session quiet
# for good. Real sessions sat on 1281 prompts still titled "chat".
#
# Coverage:
#   T1 projectless session prints nothing (the "chat" case)
#   T2 the same for a bare command word that would survive as a stub
#   T3 hqwork's hq-core company fallback alone is still a stub
#   T4 a resolved project still titles normally (suppression is not too broad)
#   T5 a repo/product with no project still titles (product carries meaning)
#   T6 the wrapper emits nothing, records nothing, and mutes nothing on a stub
#   T7 once a project resolves, the wrapper takes the title back
set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "session-title-no-stubs: skipped (node missing)"; exit 0; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TITLE="$ROOT/core/scripts/session-title.sh"
HOOK="$ROOT/.claude/hooks/session-title.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/session-title-no-stubs.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
n=0
ok() { n=$((n + 1)); printf 'ok %s — %s\n' "$n" "$1"; }

# A fixture HQ with two companies (so the single-company fallback stays out of
# the way) and one personal project.
HQ="$TMP/hq"
mkdir -p "$HQ/companies/alpha" "$HQ/companies/beta" \
         "$HQ/personal/projects/widget-overhaul" "$HQ/.claude/state" \
         "$HQ/repos/public/thing-console"
printf 'companies:\n  alpha:\n  beta:\n' > "$HQ/companies/manifest.yaml"

compute() { HQ_ROOT="$HQ" bash "$TITLE" "$@"; }

# ── T1..T3: nothing to say -> say nothing ───────────────────────────────────
out="$(compute --session-id absent --command chat)"
[ -z "$out" ] || fail "T1: a projectless session must print nothing, got '$out'"
ok "T1 projectless session prints nothing"

out="$(compute --session-id absent --command startwork)"
[ -z "$out" ] || fail "T2: a bare command word must not become a title, got '$out'"
ok "T2 a bare command word is not a title"

out="$(compute --session-id absent --command hqwork)"
[ -z "$out" ] || fail "T3: a lone org token must not become a title, got '$out'"
ok "T3 a lone org token is not a title"

# ── T4/T5: suppression must not be too broad ───────────────────────────────
printf '%s\n' "$HQ/personal/projects/widget-overhaul" \
  > "$HQ/.claude/state/auto-session-project-withproj"
out="$(compute --session-id withproj --command chat)"
[ -n "$out" ] || fail "T4: a resolved project must still produce a title"
case "$out" in *widget-overhaul*) ;; *) fail "T4: expected the project in '$out'" ;; esac
ok "T4 a resolved project still titles normally"

out="$(compute --session-id absent --command chat --cwd "$HQ/repos/public/thing-console/src")"
[ -n "$out" ] || fail "T5: a repo/product must still produce a title"
case "$out" in *Thing*) ;; *) fail "T5: expected the repo in '$out'" ;; esac
ok "T5 a repo with no project still titles"

# ── T6/T7: wrapper behaviour on a stub ─────────────────────────────────────
# The host has already written its own summary. HQ must leave it entirely
# alone: no emission, no state, and above all no manual-rename marker (which
# would disable naming for the rest of the session).
cp -R "$ROOT/core/scripts/hook-lib.sh" "$HQ/core-hook-lib.sh" 2>/dev/null || true
SD="$HQ/.claude/state"
TR="$TMP/transcript.jsonl"
printf '%s\n' '{"type":"custom-title","customTitle":"Host Written Summary","sessionId":"stub1"}' > "$TR"

run_hook() {
  printf '%s' "$1" |
    HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" HQ_STATE_OVERRIDE="" bash "$HOOK"
}

# Drive the real wrapper against the real tree, but with a session id that has
# no project of its own — the production shape of the "chat" sessions.
SID="nostub-$$"
rm -f "$ROOT/.claude/state/session-title-$SID" \
      "$ROOT/.claude/state/session-title-$SID".* 2>/dev/null
payload="$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"hello","session_id":"%s","transcript_path":"%s"}' "$SID" "$TR")"
out="$(run_hook "$payload")"
[ -z "$out" ] || fail "T6: the wrapper must emit nothing for a stub, got '$out'"
[ -f "$ROOT/.claude/state/session-title-$SID.manual" ] &&
  fail "T6: a stub turn must never mark the session manually renamed"
[ -f "$ROOT/.claude/state/session-title-$SID.autoname" ] &&
  fail "T6: a stub turn must not spend the host-autoname free pass"
ok "T6 the wrapper stays silent and leaves the host's title alone"

printf '%s\n' "$ROOT/personal/projects/widget-overhaul" \
  > "$ROOT/.claude/state/auto-session-project-$SID"
mkdir -p "$ROOT/personal/projects/widget-overhaul"
out="$(run_hook "$payload")"
case "$out" in *sessionTitle*) ;; *) fail "T7: a resolved project must retake the title, got '$out'" ;; esac
rm -f "$ROOT/.claude/state/session-title-$SID" \
      "$ROOT/.claude/state/session-title-$SID".* \
      "$ROOT/.claude/state/auto-session-project-$SID" 2>/dev/null
rmdir "$ROOT/personal/projects/widget-overhaul" 2>/dev/null || true
ok "T7 a resolved project takes the title back"

printf '\nAll %s session-title stub-suppression checks passed.\n' "$n"
