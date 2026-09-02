#!/usr/bin/env bash
# session-title-desktop-nudge.test.sh
#
# Outside the terminal CLI the hook's sessionTitle never lands — the desktop
# host reads only its own auto-titler and the model's set_session_title call.
# So on the first user prompt of a session (mode=full) the hook must inject an
# additionalContext instruction telling the model to name the session now, in
# HQ grammar, carrying the hook's own company/project hint.
#
# Coverage:
#   T1 first UserPromptSubmit in mode=full injects the nudge, with the hint
#   T2 the nudge fires once — the second prompt carries none
#   T3 SessionStart never nudges
#   T4 mode=auto never nudges
#   T5 a manually renamed session never nudges
#   T6 a stub session (no title emitted) STILL nudges — that is the point
#   T7 title and nudge travel together as one valid JSON envelope
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "session-title-desktop-nudge: skipped (jq missing)"; exit 0; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/session-title.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/session-title-nudge.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
n=0; ok() { n=$((n + 1)); printf 'ok %s — %s\n' "$n" "$1"; }

SD="$ROOT/.claude/state"
run() { printf '%s' "$1" | CLAUDE_PROJECT_DIR="$ROOT" HQ_ROOT="$ROOT" bash "$HOOK"; }
clean() { rm -f "$SD/session-title-$1" "$SD/session-title-$1".* "$SD/auto-session-project-$1" 2>/dev/null; }
prompt() { printf '{"hook_event_name":"UserPromptSubmit","prompt":"%s","session_id":"%s"}' "$2" "$1"; }
start()  { printf '{"hook_event_name":"SessionStart","source":"startup","session_id":"%s"}' "$1"; }
ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""'; }
PROJ="$ROOT/personal/projects/nudge-probe-$$"; mkdir -p "$PROJ"
trap 'rm -rf "$TMP" "$PROJ"; rm -f "$SD"/session-title-nudge*_$$ "$SD"/session-title-nudge*_$$.* "$SD"/auto-session-project-nudge*_$$' EXIT

# T1
S=nudge1_$$; clean "$S"
printf '%s\n' "$PROJ" > "$SD/auto-session-project-$S"
out="$(run "$(prompt "$S" "help me with widgets")")"
c="$(ctx "$out")"
[ -n "$c" ] || fail "T1: first prompt must inject additionalContext"
case "$c" in *set_session_title*) ;; *) fail "T1: nudge must name the rename tool" ;; esac
case "$c" in *"ME · nudge-probe-$$"*) ;; *) fail "T1: nudge must carry the hook's hint, got: $c" ;; esac
[ -f "$SD/session-title-$S.nudged" ] || fail "T1: once-marker missing"
ok "T1 first prompt injects the naming nudge with the hook's hint"

# T2
out="$(run "$(prompt "$S" "second message")")"
[ -z "$(ctx "$out")" ] || fail "T2: second prompt must not nudge again"
ok "T2 the nudge fires once per session"
clean "$S"

# T3
S=nudge3_$$; clean "$S"
out="$(run "$(start "$S")")"
[ -z "$(ctx "$out")" ] || fail "T3: SessionStart must never nudge"
[ -f "$SD/session-title-$S.nudged" ] && fail "T3: SessionStart must not spend the nudge"
ok "T3 SessionStart never nudges"
clean "$S"

# T4  (mode=auto via a temporary personal settings override)
PS="$ROOT/personal/settings/session-title.yaml"; BK="$TMP/session-title.yaml.bak"
[ -f "$PS" ] && cp "$PS" "$BK"
mkdir -p "$(dirname "$PS")"; printf 'version: 1\nenabled: true\nmode: auto\n' > "$PS"
S=nudge4_$$; clean "$S"
out="$(run "$(prompt "$S" "hello")")"
if [ -f "$BK" ]; then cp "$BK" "$PS"; else rm -f "$PS"; fi
[ -z "$(ctx "$out")" ] || fail "T4: mode=auto must never nudge"
ok "T4 mode=auto never nudges"
clean "$S"

# T5
S=nudge5_$$; clean "$S"; : > "$SD/session-title-$S.manual"
out="$(run "$(prompt "$S" "hello")")"
[ -z "$out" ] || fail "T5: a manually renamed session must emit nothing, got: $out"
ok "T5 a manually renamed session never nudges"
clean "$S"

# T6  (no project, no repo -> no title -> still nudge)
S=nudge6_$$; clean "$S"
out="$(run "$(prompt "$S" "quick question")")"
[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.sessionTitle // ""')" = "" ] || fail "T6: stub must not emit a title"
c="$(ctx "$out")"; [ -n "$c" ] || fail "T6: a stub session must still be nudged"
case "$c" in *"none resolved"*) ;; *) fail "T6: hint should say nothing resolved, got: $c" ;; esac
ok "T6 a stub session still gets the nudge"
clean "$S"

# T7
S=nudge7_$$; clean "$S"
printf '%s\n' "$PROJ" > "$SD/auto-session-project-$S"
out="$(run "$(prompt "$S" "hi")")"
printf '%s' "$out" | jq -e '.hookSpecificOutput.sessionTitle and .hookSpecificOutput.additionalContext' >/dev/null ||
  fail "T7: title and nudge must share one valid envelope, got: $out"
ok "T7 title and nudge travel in one valid JSON envelope"
clean "$S"

printf '\nAll %s session-title desktop-nudge checks passed.\n' "$n"
