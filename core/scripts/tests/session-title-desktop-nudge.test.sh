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
#   T8 HQ_SESSION_TITLE=auto overrides file mode and suppresses the nudge
#   T9 the nudge carries the hook's session id, JSON-quoted, and the rename
#      tool's real argument shape { session_id, title }
#   T10 hook input with no session id emits no rename instruction at all
#   T11 enabled: false in personal/settings/session-title.yaml silences the
#       hook: no title, no instruction, no state (feedback_abaac90d)
#   T12 the instruction tells the model to continue when the rename is
#       denied or fails (feedback_abaac90d)
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "session-title-desktop-nudge: skipped (jq missing)"; exit 0; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="${SESSION_TITLE_HOOK:-$ROOT/.claude/hooks/session-title.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/session-title-nudge.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
n=0; ok() { n=$((n + 1)); printf 'ok %s — %s\n' "$n" "$1"; }

SD="$ROOT/.claude/state"
mkdir -p "$SD"
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

# T8: the environment override beats file settings and disables the model nudge.
PS="$ROOT/personal/settings/session-title.yaml"; BK8="$TMP/session-title-t8.yaml.bak"
[ -f "$PS" ] && cp "$PS" "$BK8"
mkdir -p "$(dirname "$PS")"; printf 'version: 1\nenabled: true\nmode: full\n' > "$PS"
S=nudge8_$$; clean "$S"
out="$(HQ_SESSION_TITLE=auto run "$(prompt "$S" "hello")")"
if [ -f "$BK8" ]; then cp "$BK8" "$PS"; else rm -f "$PS"; fi
[ -z "$(ctx "$out")" ] || fail "T8: HQ_SESSION_TITLE=auto must override mode=full and suppress the nudge"
[ -f "$SD/session-title-$S.nudged" ] && fail "T8: auto mode must not spend the nudge"
ok "T8 HQ_SESSION_TITLE=auto overrides file mode"
clean "$S"

# T9: the instruction names this session and matches the tool's schema. The id
# holds a quote and a backslash, so it must arrive JSON-quoted, not spliced.
S='nudge9_"q\\'"_$$"
out="$(run "$(jq -cn --arg s "$S" '{hook_event_name:"UserPromptSubmit",prompt:"hello",session_id:$s}')")"
printf '%s' "$out" | jq -e . >/dev/null || fail "T9: output must be valid JSON, got: $out"
c="$(ctx "$out")"
want="$(jq -cn --arg s "$S" '$s')"
case "$c" in *"$want"*) ;; *) fail "T9: nudge must carry the hook session id as $want, got: $c" ;; esac
case "$c" in *'{"session_id":"self","title":'*) ;; *) fail "T9: nudge must show a { session_id, title } call, got: $c" ;; esac
case "$c" in *"session_id and title"*) ;; *) fail "T9: nudge must name both required arguments, got: $c" ;; esac
rm -f "$SD"/session-title-nudge9_* "$SD"/auto-session-project-nudge9_* 2>/dev/null
ok "T9 the nudge carries the session id and the tool's argument shape"

# T10: no session id in the hook input -> no instruction, and no spent marker.
rm -f "$SD/session-title-default.nudged"
out="$(run '{"hook_event_name":"UserPromptSubmit","prompt":"hello"}' 2>"$TMP/t10.err")"
[ -z "$(ctx "$out")" ] || fail "T10: no session id must emit no rename instruction, got: $out"
case "$out" in *set_session_title*) fail "T10: no session id must not mention the rename tool, got: $out" ;; esac
[ -f "$SD/session-title-default.nudged" ] && fail "T10: a skipped nudge must not spend the once-marker"
grep -q 'no session_id' "$TMP/t10.err" || fail "T10: the skip must be stated plainly on stderr"
out="$(run '{"hook_event_name":"UserPromptSubmit","prompt":"hello","session_id":""}' 2>/dev/null)"
[ -z "$(ctx "$out")" ] || fail "T10: an empty session id must emit no rename instruction, got: $out"
ok "T10 no session id means no rename instruction"
clean default

# T11: the documented file switch. Before the fix only HQ_SESSION_TITLE=off and
# HQ_DISABLED_HOOKS silenced the hook; enabled: false was read by nothing on
# the hook path, so the first-turn instruction still fired.
PS="$ROOT/personal/settings/session-title.yaml"; BK11="$TMP/session-title-t11.yaml.bak"
[ -f "$PS" ] && cp "$PS" "$BK11"
mkdir -p "$(dirname "$PS")"; printf 'version: 1\nenabled: false # off for this machine\nmode: full\n' > "$PS"
S=nudge11_$$; clean "$S"
printf '%s\n' "$PROJ" > "$SD/auto-session-project-$S"
out_start="$(run "$(start "$S")" 2>"$TMP/t11.err")"
out="$(run "$(prompt "$S" "help me with widgets")" 2>>"$TMP/t11.err")"
if [ -f "$BK11" ]; then cp "$BK11" "$PS"; else rm -f "$PS"; fi
[ -z "$out_start" ] || fail "T11: enabled: false must emit nothing on SessionStart, got: $out_start"
[ -z "$out" ] || fail "T11: enabled: false must emit nothing on the first prompt, got: $out"
[ -f "$SD/session-title-$S.nudged" ] && fail "T11: enabled: false must not spend the once-marker"
[ -f "$SD/session-title-$S" ] && fail "T11: enabled: false must not write title state"
ok "T11 enabled: false in the settings file silences the hook"
clean "$S"

# T12: a denied rename must not end the turn. The instruction says to continue.
S=nudge12_$$; clean "$S"
out="$(run "$(prompt "$S" "help me with widgets")")"
c="$(ctx "$out")"
[ -n "$c" ] || fail "T12: first prompt must inject the instruction"
case "$c" in *"denied"*"continue with the task the user asked for"*) ;; *) fail "T12: the instruction must cover the denied case and say to continue, got: $c" ;; esac
ok "T12 the instruction says to continue when the rename is denied"
clean "$S"

printf '\nAll %s session-title desktop-nudge checks passed.\n' "$n"
