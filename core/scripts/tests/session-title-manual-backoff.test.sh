#!/usr/bin/env bash
# session-title-manual-backoff.test.sh
#
# feedback_0919db0c / feedback_1f573b9f — the session-title hook must stop
# overwriting a user's manually set title (launcher `claude --name`, `/rename`,
# or the desktop "Recents" rename). The PRIMARY, version-stable signal is the
# documented `session_title` SessionStart hook input; the transcript
# `custom-title` scan is a labeled secondary net for a mid-session /rename.
#
# Coverage:
#   T1  fresh unnamed session emits an HQ title
#   T2  our own prior emitted title (echoed back via session_title) is NOT a
#       manual title — a real command change still emits
#   T3  launcher --name (session_title set on first SessionStart) backs off
#   T4  once a manual title is seen, back-off is permanent
#   T5  documented path: a mid-session rename surfaced via session_title backs off
#   T6  secondary path: a mid-session /rename seen only in the transcript backs off
#   T7  a transcript custom-title that HQ itself emitted does NOT trigger back-off
#   T8  opt-out (HQ_SESSION_TITLE=off) emits nothing
#   T9  teeth: a back-off-stripped hook clobbers a manual title (bug reproduces)
#
# Target hook is overridable via SESSION_TITLE_HOOK for candidate/A-B runs.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="${SESSION_TITLE_HOOK:-$ROOT/.claude/hooks/session-title.sh}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/session-title-backoff.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

pass_count=0
ok() { pass_count=$((pass_count + 1)); printf 'ok %s — %s\n' "$pass_count" "$1"; }

# --- deterministic HQ_ROOT with a stub title helper -------------------------
# The wrapper reads the emitted title from $HQ_ROOT/core/scripts/session-title.sh.
# A stub keeps the emitted title deterministic and command-driven so change
# detection and back-off can be asserted precisely.
HQ_ROOT="$TMP/hq"
mkdir -p "$HQ_ROOT/core/scripts" "$HQ_ROOT/.claude/state"
cat > "$HQ_ROOT/core/scripts/session-title.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
cmd=""
while [ $# -gt 0 ]; do
  case "$1" in
    --command) cmd="${2:-}"; shift 2 ;;
    --session-id) shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$cmd" ] || cmd="chat"
printf 'hq · %s\n' "$cmd"
STUB
chmod +x "$HQ_ROOT/core/scripts/session-title.sh"

# run_hook <hook> <json-stdin> -> stdout of the hook
run_hook() {
  local hook="$1" json="$2"
  printf '%s' "$json" | HQ_ROOT="$HQ_ROOT" HQ_SESSION_TITLE="${HQ_SESSION_TITLE:-on}" bash "$hook" 2>/dev/null
}

emitted() { printf '%s' "$1" | grep -q '"sessionTitle"'; }
state_file() { printf '%s/.claude/state/session-title-%s' "$HQ_ROOT" "$1"; }
reset_state() { rm -f "$HQ_ROOT/.claude/state/session-title-"* 2>/dev/null || true; }

json_start() { # <session_id> [session_title]
  if [ -n "${2:-}" ]; then
    printf '{"hook_event_name":"SessionStart","source":"startup","session_id":"%s","session_title":"%s"}' "$1" "$2"
  else
    printf '{"hook_event_name":"SessionStart","source":"startup","session_id":"%s"}' "$1"
  fi
}
json_prompt() { # <session_id> <prompt> [session_title] [transcript_path]
  local s="$1" p="$2" t="${3:-}" tr="${4:-}"
  local extra=""
  [ -n "$t" ]  && extra="$extra,\"session_title\":\"$t\""
  [ -n "$tr" ] && extra="$extra,\"transcript_path\":\"$tr\""
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","prompt":"%s"%s}' "$s" "$p" "$extra"
}

# ── T1: fresh unnamed session emits an HQ title ─────────────────────────────
reset_state
out="$(run_hook "$HOOK" "$(json_start S1)")"
emitted "$out" || fail "T1: fresh unnamed session should emit a title"
printf '%s' "$out" | grep -q 'hq · chat' || fail "T1: expected computed HQ title"
ok "T1 fresh unnamed session emits an HQ title"

# ── T2: our own emitted title echoed back is not manual; command change emits ─
out="$(run_hook "$HOOK" "$(json_prompt S1 '/plan ship it' 'hq · chat')")"
emitted "$out" || fail "T2: a real command change should still emit"
printf '%s' "$out" | grep -q 'hq · plan' || fail "T2: expected new command title"
[ -f "$(state_file S1).manual" ] && fail "T2: our own prior title must not mark manual"
ok "T2 own emitted title echoed via session_title is not manual"

# ── T3: launcher --name backs off on the first SessionStart ─────────────────
reset_state
out="$(run_hook "$HOOK" "$(json_start S2 'My Named Session')")"
emitted "$out" && fail "T3: a launcher --name title must not be overwritten"
[ -f "$(state_file S2).manual" ] || fail "T3: expected manual marker for --name"
ok "T3 launcher --name title backs off"

# ── T4: back-off is permanent for the session ───────────────────────────────
out="$(run_hook "$HOOK" "$(json_prompt S2 '/plan more work' 'My Named Session')")"
emitted "$out" && fail "T4: back-off must persist once a manual title is seen"
ok "T4 manual back-off is permanent"

# ── T5: documented path — mid-session rename via session_title backs off ─────
reset_state
out="$(run_hook "$HOOK" "$(json_start S3)")"
emitted "$out" || fail "T5: setup — first turn should emit"
out="$(run_hook "$HOOK" "$(json_prompt S3 'keep going' 'Renamed By User')")"
emitted "$out" && fail "T5: a rename surfaced via session_title must back off"
[ -f "$(state_file S3).manual" ] || fail "T5: expected manual marker (documented path)"
ok "T5 mid-session rename via documented session_title backs off"

# ── T6: secondary path — /rename seen only in the transcript backs off ──────
reset_state
out="$(run_hook "$HOOK" "$(json_start S4)")"
emitted "$out" || fail "T6: setup — first turn should emit"
TR="$TMP/transcript-S4.jsonl"
{
  printf '%s\n' '{"type":"user","text":"hi"}'
  printf '%s\n' '{"type":"custom-title","title":"Transcript Rename"}'
} > "$TR"
out="$(run_hook "$HOOK" "$(json_prompt S4 'still going' '' "$TR")")"
emitted "$out" && fail "T6: a transcript custom-title rename must back off"
[ -f "$(state_file S4).manual" ] || fail "T6: expected manual marker (transcript path)"
ok "T6 mid-session /rename via transcript backs off"

# ── T7: a transcript custom-title HQ itself emitted does NOT back off ────────
reset_state
out="$(run_hook "$HOOK" "$(json_start S5)")"          # emits + records "hq · chat"
emitted "$out" || fail "T7: setup — first turn should emit"
TR2="$TMP/transcript-S5.jsonl"
printf '%s\n' '{"type":"custom-title","title":"hq · chat"}' > "$TR2"   # HQ's own title
out="$(run_hook "$HOOK" "$(json_prompt S5 '/plan onward' '' "$TR2")")"
emitted "$out" || fail "T7: HQ's own transcript title must not be treated as manual"
[ -f "$(state_file S5).manual" ] && fail "T7: HQ's own title must not mark manual"
ok "T7 HQ-emitted transcript title is not a manual rename"

# ── T8: opt-out emits nothing ───────────────────────────────────────────────
reset_state
out="$(HQ_SESSION_TITLE=off run_hook "$HOOK" "$(json_start S6)")"
emitted "$out" && fail "T8: HQ_SESSION_TITLE=off must not emit"
ok "T8 opt-out emits nothing"

# ── T9: teeth — a back-off-stripped hook clobbers a manual title ────────────
# Regenerate the hook without the manual-rename back-off block (the pre-fix
# behavior). It must EMIT over a launcher --name title, proving the assertions
# above have teeth and catch a regression that drops the back-off.
# The hook sources hook-lib.sh relative to its own location, so stage the strip
# in a mirror package tree with a copy of the real hook-lib alongside it.
STRIPDIR="$TMP/pkg/.claude/hooks"
mkdir -p "$STRIPDIR" "$TMP/pkg/core/scripts"
cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/pkg/core/scripts/hook-lib.sh"
STRIP="$STRIPDIR/session-title.sh"
sed -e '/^# --- manual-rename back-off/,/^# State file: line 1/{/^# State file: line 1/!d}' \
    -e '/^record_emitted() {/,/^}/d' \
    -e 's/record_emitted "[^"]*"/:/' \
    "$HOOK" > "$STRIP"
chmod +x "$STRIP"
reset_state
out="$(run_hook "$STRIP" "$(json_start S7 'My Named Session')")"
emitted "$out" || fail "T9: stripped hook should reproduce the bug (emit over --name)"
ok "T9 back-off-stripped hook reproduces the clobber (coverage has teeth)"

printf '\nAll %s session-title manual back-off checks passed.\n' "$pass_count"
