#!/usr/bin/env bash
# session-title-manual-backoff.test.sh
#
# feedback_0919db0c / feedback_1f573b9f — the session-title hook must stop
# overwriting a user's manually set title (launcher `claude --name`, `/rename`,
# or the desktop "Recents" rename), and must never mistake one of its own
# titles for a manual rename.
#
# Fixture fidelity matters here: transcript custom-title lines are copied from
# the shape Claude Code actually writes,
#   {"type":"custom-title","customTitle":"…","sessionId":"…"}
# not an invented {"title":…} shape. A suite built on the wrong key stays green
# while the production path is dead.
#
# Coverage:
#   T1  fresh unnamed session emits an HQ title
#   T2  our own prior emitted title (echoed back via session_title) is NOT a
#       manual title — a real command change still emits
#   T3  launcher --name (session_title set on first SessionStart) backs off
#   T4  once a manual title is seen, back-off is permanent
#   T5  first foreign transcript title (the Claude Desktop auto-titler) is
#       ignored and retaken; a second, different foreign title (a real
#       mid-session /rename, feedback_0919db0c) backs off
#   T5r desktop_autoname=respect restores back-off on the first foreign title
#   T5a resume inheriting the desktop auto-title via session_title keeps titling
#   T6  a transcript custom-title HQ itself emitted does NOT back off
#   T7  legacy/defensive: a custom-title line carrying a plain "title" key is
#       still honored
#   T8  fork: a new session id inheriting HQ's own title keeps titling
#   T9  resume: same, via source=resume
#   T10 wiped .claude/state: HQ's own title inherited with no ledger at all is
#       still recognised (exact match against the computed title)
#   T11 defensive (undocumented): session_title on a non-SessionStart payload
#       backs off if a host ever surfaces it there
#   T12 stale per-session state is pruned on SessionStart
#   T13 opt-out (HQ_SESSION_TITLE=off) emits nothing
#   T14 teeth: a back-off-stripped hook clobbers a manual title (bug reproduces)
#   T15 a live named session's marker outlives another session's stale-state
#       prune, so a long-open named session keeps its title
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
# Real config resolver, so desktop_autoname resolution is exercised for real.
cp "$ROOT/core/scripts/session-title-config.sh" "$HQ_ROOT/core/scripts/"

# run_hook <hook> <json-stdin> -> stdout of the hook
run_hook() {
  local hook="$1" json="$2"
  printf '%s' "$json" | HQ_ROOT="$HQ_ROOT" HQ_SESSION_TITLE="${HQ_SESSION_TITLE:-on}" bash "$hook" 2>/dev/null
}

# Substring assertions use case globs, never `printf | grep -q`: grep -q exits
# on first match, printf can take SIGPIPE, and `set -o pipefail` then reports
# 141 for a string that plainly matched. That pattern makes a suite flaky.
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
emitted() { contains "$1" '"sessionTitle"'; }

state_file() { printf '%s/.claude/state/session-title-%s' "$HQ_ROOT" "$1"; }
hq_ledger() { printf '%s/.claude/state/session-title.hq-titles' "$HQ_ROOT"; }
reset_state() {
  rm -f "$HQ_ROOT/.claude/state/session-title-"* 2>/dev/null || true
  rm -f "$(hq_ledger)" 2>/dev/null || true
}

json_start() { # <session_id> [session_title] [source] [transcript_path]
  local s="$1" t="${2:-}" src="${3:-startup}" tr="${4:-}"
  local extra=""
  [ -n "$t" ]  && extra="$extra,\"session_title\":\"$t\""
  [ -n "$tr" ] && extra="$extra,\"transcript_path\":\"$tr\""
  printf '{"hook_event_name":"SessionStart","source":"%s","session_id":"%s"%s}' "$src" "$s" "$extra"
}
json_prompt() { # <session_id> <prompt> [session_title] [transcript_path]
  local s="$1" p="$2" t="${3:-}" tr="${4:-}"
  local extra=""
  [ -n "$t" ]  && extra="$extra,\"session_title\":\"$t\""
  [ -n "$tr" ] && extra="$extra,\"transcript_path\":\"$tr\""
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","prompt":"%s"%s}' "$s" "$p" "$extra"
}
# custom_title_line <title> <session_id>
# Verbatim shape of a real Claude Code transcript custom-title line.
custom_title_line() {
  printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$1" "$2"
}

# ── T1: fresh unnamed session emits an HQ title ─────────────────────────────
reset_state
out="$(run_hook "$HOOK" "$(json_start S1)")"
emitted "$out" || fail "T1: fresh unnamed session should emit a title"
contains "$out" 'hq · chat' || fail "T1: expected computed HQ title"
ok "T1 fresh unnamed session emits an HQ title"

# ── T2: our own emitted title echoed back is not manual; command change emits ─
out="$(run_hook "$HOOK" "$(json_prompt S1 '/plan ship it' 'hq · chat')")"
emitted "$out" || fail "T2: a real command change should still emit"
contains "$out" 'hq · plan' || fail "T2: expected new command title"
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

# ── T5: transcript foreign titles — first is the desktop auto-titler and is ─
# ignored (HQ retakes the title, force-emitting even though its computed
# title is unchanged); a SECOND, different foreign title is a real rename
# and backs off permanently.
reset_state
TR="$TMP/transcript-S3.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' > "$TR"
out="$(run_hook "$HOOK" "$(json_start S3 '' startup "$TR")")"
emitted "$out" || fail "T5: setup — first turn should emit"
custom_title_line 'hq · chat' S3 >> "$TR"            # HQ's own emission is logged
custom_title_line 'Desktop Auto Title' S3 >> "$TR"   # desktop auto-titler fires
out="$(run_hook "$HOOK" "$(json_prompt S3 'still going' '' "$TR")")"
emitted "$out" || fail "T5: first foreign transcript title must be ignored and retaken"
[ -f "$(state_file S3).manual" ] && fail "T5: first foreign title must not mark manual"
custom_title_line 'My Manual Rename' S3 >> "$TR"     # then the user really renames
out="$(run_hook "$HOOK" "$(json_prompt S3 '/plan keep going' '' "$TR")")"
emitted "$out" && fail "T5: a second foreign title (real rename) must not be clobbered"
[ -f "$(state_file S3).manual" ] || fail "T5: expected manual marker (transcript path)"
ok "T5 first foreign transcript title ignored, second backs off"

# ── T5r: desktop_autoname=respect restores the pre-fix behavior ─────────────
mkdir -p "$HQ_ROOT/personal/settings"
printf 'version: 1\ndesktop_autoname: respect\n' > "$HQ_ROOT/personal/settings/session-title.yaml"
reset_state
TRR="$TMP/transcript-S3R.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' > "$TRR"
out="$(run_hook "$HOOK" "$(json_start S3R '' startup "$TRR")")"
emitted "$out" || fail "T5r: setup — first turn should emit"
custom_title_line 'My Manual Rename' S3R >> "$TRR"
out="$(run_hook "$HOOK" "$(json_prompt S3R 'still going' '' "$TRR")")"
emitted "$out" && fail "T5r: under respect, the first foreign title must back off"
[ -f "$(state_file S3R).manual" ] || fail "T5r: expected manual marker under respect"
rm -f "$HQ_ROOT/personal/settings/session-title.yaml"
ok "T5r desktop_autoname=respect backs off on the first foreign title"

# ── T5a: resume inheriting the desktop auto-title via session_title ─────────
# On resume the auto-title arrives in the SessionStart input; the transcript
# proves its origin, so it is ignored and HQ retakes the title.
reset_state
TRA="$TMP/transcript-S3A.jsonl"
custom_title_line 'Desktop Auto Title' S3A > "$TRA"
out="$(run_hook "$HOOK" "$(json_start S3A 'Desktop Auto Title' resume "$TRA")")"
emitted "$out" || fail "T5a: resumed desktop auto-title must be ignored and retaken"
[ -f "$(state_file S3A).manual" ] && fail "T5a: resumed auto-title must not mark manual"
ok "T5a resumed session inheriting the desktop auto-title keeps titling"

# ── T5b: resume inheriting the desktop auto-title with NO transcript proof ──
# The regression this suite previously missed. On resume the transcript is
# often unreadable — the path may be absent, or the auto-title line not yet
# flushed — so the origin cannot be proven. Withholding the free pass there
# muted the session permanently and left no .autoname behind to explain it,
# which is exactly how live desktop sessions lost HQ naming for good.
reset_state
out="$(run_hook "$HOOK" "$(json_start S3B 'Desktop Auto Title' resume)")"
emitted "$out" ||
  fail "T5b: an unproven resumed auto-title must still be ignored and retaken"
[ -f "$(state_file S3B).manual" ] &&
  fail "T5b: an unproven resumed auto-title must not mute the session"
[ -f "$(state_file S3B).autoname" ] ||
  fail "T5b: the spent free pass must be recorded in .autoname"
# ...and the pass is still only good once: a second, different title is real.
out="$(run_hook "$HOOK" "$(json_start S3B 'A Different Rename' resume)")"
emitted "$out" && fail "T5b: a second differing title must back off"
[ -f "$(state_file S3B).manual" ] || fail "T5b: expected a manual marker"
ok "T5b unproven resumed auto-title is ignored once, then backs off"

# ── T5c: startup --name with no transcript proof still backs off ────────────
# The resume allowance must not leak to startup: before any turn has run,
# `claude --name` is the only way a session_title can exist.
reset_state
out="$(run_hook "$HOOK" "$(json_start S3C 'My Hand Written Name' startup)")"
emitted "$out" && fail "T5c: launcher --name must back off, not be retaken"
[ -f "$(state_file S3C).manual" ] || fail "T5c: expected a manual marker"
[ -f "$(state_file S3C).autoname" ] &&
  fail "T5c: --name must not consume the desktop free pass"
ok "T5c launcher --name at startup still backs off without transcript proof"

# ── T6: a transcript custom-title HQ itself emitted does NOT back off ───────
reset_state
out="$(run_hook "$HOOK" "$(json_start S4)")"          # emits + records "hq · chat"
emitted "$out" || fail "T6: setup — first turn should emit"
TR2="$TMP/transcript-S4.jsonl"
custom_title_line 'hq · chat' S4 > "$TR2"            # HQ's own title, logged back
out="$(run_hook "$HOOK" "$(json_prompt S4 '/plan onward' '' "$TR2")")"
emitted "$out" || fail "T6: HQ's own transcript title must not be treated as manual"
[ -f "$(state_file S4).manual" ] && fail "T6: HQ's own title must not mark manual"
ok "T6 HQ-emitted transcript title is not a manual rename"

# ── T7: defensive — a custom-title line with a plain "title" key still counts ─
reset_state
out="$(run_hook "$HOOK" "$(json_start S5)")"
emitted "$out" || fail "T7: setup — first turn should emit"
TR3="$TMP/transcript-S5.jsonl"
printf '%s\n' '{"type":"custom-title","title":"Legacy Shape Autoname"}' > "$TR3"
out="$(run_hook "$HOOK" "$(json_prompt S5 'still going' '' "$TR3")")"
emitted "$out" || fail "T7: first legacy-shaped foreign title gets the auto-titler pass"
printf '%s\n' '{"type":"custom-title","title":"Legacy Shape Rename"}' >> "$TR3"
out="$(run_hook "$HOOK" "$(json_prompt S5 'onward' '' "$TR3")")"
emitted "$out" && fail "T7: a second legacy-shaped custom-title rename must back off"
ok "T7 legacy title-key custom-title line is still honored"

# ── T8: fork — new session id inheriting HQ's own title keeps titling ───────
# session_title is inherited across a fork; the session id is not. A ledger
# keyed only by session id would read HQ's own title as a manual rename and
# permanently disable titling for the child.
reset_state
out="$(run_hook "$HOOK" "$(json_start PARENT)")"
emitted "$out" || fail "T8: setup — parent should emit"
out="$(run_hook "$HOOK" "$(json_start CHILD 'hq · chat' fork)")"
[ -f "$(state_file CHILD).manual" ] && fail "T8: a forked session must not be marked manual"
emitted "$out" || fail "T8: forked session should keep titling"
ok "T8 forked session inheriting HQ's title keeps titling"

# ── T9: resume — same guarantee via source=resume ───────────────────────────
reset_state
out="$(run_hook "$HOOK" "$(json_start ORIG)")"
emitted "$out" || fail "T9: setup — original session should emit"
out="$(run_hook "$HOOK" "$(json_start RESUMED 'hq · chat' resume)")"
[ -f "$(state_file RESUMED).manual" ] && fail "T9: a resumed session must not be marked manual"
emitted "$out" || fail "T9: resumed session should keep titling"
ok "T9 resumed session inheriting HQ's title keeps titling"

# ── T10: wiped state — no ledger at all, HQ's own title still recognised ────
reset_state
out="$(run_hook "$HOOK" "$(json_start FRESH 'hq · chat' startup)")"
[ -f "$(state_file FRESH).manual" ] && fail "T10: HQ's computed title must never mark manual"
emitted "$out" || fail "T10: an empty state dir must not silently disable titling"
ok "T10 wiped state dir does not turn HQ's own title into a manual rename"

# ── T11: defensive — session_title on a non-SessionStart payload ────────────
# The documented UserPromptSubmit input carries no session_title. This asserts
# the defensive branch only: if a host ever surfaces it there, back off.
reset_state
out="$(run_hook "$HOOK" "$(json_start S6)")"
emitted "$out" || fail "T11: setup — first turn should emit"
out="$(run_hook "$HOOK" "$(json_prompt S6 'keep going' 'Renamed By User')")"
emitted "$out" && fail "T11: an out-of-band session_title rename must back off"
[ -f "$(state_file S6).manual" ] || fail "T11: expected manual marker (defensive path)"
ok "T11 session_title on a non-SessionStart payload backs off (defensive)"

# ── T12: stale per-session state is pruned on SessionStart ──────────────────
reset_state
STALE="$(state_file STALEID)"
printf 'chat\nhq · chat\n' > "$STALE"
: > "$STALE.emitted"
touch -t 202001010000 "$STALE" "$STALE.emitted" 2>/dev/null ||
  fail "T12: could not age the fixture state files"
out="$(run_hook "$HOOK" "$(json_start S7)")"
emitted "$out" || fail "T12: pruning turn should still emit normally"
[ -f "$STALE" ] && fail "T12: stale session-title state should be pruned"
[ -f "$STALE.emitted" ] && fail "T12: stale ledger should be pruned"
[ -f "$(hq_ledger)" ] || fail "T12: the machine-wide ledger must survive pruning"
ok "T12 stale per-session state is pruned, shared ledger survives"

# ── T13: opt-out emits nothing ──────────────────────────────────────────────
reset_state
out="$(HQ_SESSION_TITLE=off run_hook "$HOOK" "$(json_start S8)")"
emitted "$out" && fail "T13: HQ_SESSION_TITLE=off must not emit"
ok "T13 opt-out emits nothing"

# ── T14: teeth — a back-off-stripped hook clobbers a manual title ───────────
# Regenerate the hook without the manual-rename back-off (the pre-fix
# behavior). It must EMIT over a launcher --name title, proving the assertions
# above have teeth and catch a regression that drops the back-off.
# The hook sources hook-lib.sh relative to its own location, so stage the strip
# in a mirror package tree with a copy of the real hook-lib alongside it.
STRIPDIR="$TMP/pkg/.claude/hooks"
mkdir -p "$STRIPDIR" "$TMP/pkg/core/scripts"
cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/pkg/core/scripts/hook-lib.sh"
STRIP="$STRIPDIR/session-title.sh"
sed -e 's/^if \[ -f "\$MANUAL" \]; then$/if false; then/' \
    -e 's/^if manual_title_backoff; then$/if false; then/' \
    "$HOOK" > "$STRIP"
chmod +x "$STRIP"
# Both sentinels must have matched, or the strip silently tests nothing.
for sentinel in 'if [ -f "$MANUAL" ]; then' 'if manual_title_backoff; then'; do
  grep -qxF -- "$sentinel" "$HOOK" ||
    fail "T14: sentinel not found in the hook — it was refactored, update the strip: $sentinel"
  grep -qxF -- "$sentinel" "$STRIP" &&
    fail "T14: sentinel survived the strip — update the strip: $sentinel"
done
reset_state
out="$(run_hook "$STRIP" "$(json_start S9 'My Named Session')")"
emitted "$out" || fail "T14: stripped hook should reproduce the bug (emit over --name)"
# And the real hook must not, on the identical payload.
reset_state
out="$(run_hook "$HOOK" "$(json_start S9 'My Named Session')")"
emitted "$out" && fail "T14: the shipped hook must back off on the same payload"
ok "T14 back-off-stripped hook reproduces the clobber (coverage has teeth)"

# ── T15: a live named session's marker outlives another session's prune ─────
# Pruning is keyed on mtime, so a session named weeks ago and still open must
# refresh its marker on every backed-off turn or the prune would silently hand
# its title back to HQ.
reset_state
run_hook "$HOOK" "$(json_start SLIVE 'Long Lived Name')" >/dev/null
[ -f "$(state_file SLIVE).manual" ] || fail "T15: setup — expected a manual marker"
touch -t 202001010000 "$(state_file SLIVE).manual" 2>/dev/null ||
  fail "T15: could not age the marker"
out="$(run_hook "$HOOK" "$(json_prompt SLIVE 'still working' 'Long Lived Name')")"
emitted "$out" && fail "T15: a named session must stay backed off"
out="$(run_hook "$HOOK" "$(json_start SOTHER)")"     # another session prunes
emitted "$out" || fail "T15: the pruning session should title normally"
[ -f "$(state_file SLIVE).manual" ] ||
  fail "T15: a live named session's marker was pruned — its title would be clobbered"
ok "T15 an active named session's marker survives another session's prune"

# ── T16: stale-mute heal for sessions muted by the withheld free pass ───────
# Sessions already muted by the T5b bug would stay muted forever, because the
# marker check short-circuits before any of the fixed logic runs. A mute with
# NO .autoname sibling and a live title in HQ grammar is provably wrong — a
# real manual rename is free-form prose — so it is cleared and naming resumes.
reset_state
TRH="$TMP/transcript-SHEAL.jsonl"
custom_title_line '🔧 FIX · Session auto-naming in the app' SHEAL > "$TRH"
: > "$(state_file SHEAL).manual"
out="$(run_hook "$HOOK" "$(json_prompt SHEAL 'carry on' '' "$TRH")")"
[ -f "$(state_file SHEAL).manual" ] &&
  fail "T16: a wrongly muted session must be healed"
emitted "$out" || fail "T16: a healed session must resume titling"
ok "T16 a mute with no autoname and an HQ-grammar title is healed"

# ── T17: the heal must not resurrect a genuine manual rename ────────────────
# Two guards: free-form prose is a real rename, and a mute carrying an
# .autoname sibling was the documented second-rename back-off.
reset_state
TRP="$TMP/transcript-SPROSE.jsonl"
custom_title_line 'AGI book translations' SPROSE > "$TRP"
: > "$(state_file SPROSE).manual"
out="$(run_hook "$HOOK" "$(json_prompt SPROSE 'carry on' '' "$TRP")")"
[ -f "$(state_file SPROSE).manual" ] ||
  fail "T17: a prose title is a real rename and must stay muted"
emitted "$out" && fail "T17: a genuinely renamed session must not be retitled"

TRG="$TMP/transcript-SGEN.jsonl"
custom_title_line '🔧 FIX · Session auto-naming in the app' SGEN > "$TRG"
: > "$(state_file SGEN).manual"
printf 'Some Earlier Auto Title\n' > "$(state_file SGEN).autoname"
out="$(run_hook "$HOOK" "$(json_prompt SGEN 'carry on' '' "$TRG")")"
[ -f "$(state_file SGEN).manual" ] ||
  fail "T17: a mute with a spent free pass was a real rename and must persist"
ok "T17 the heal spares prose renames and mutes with a spent free pass"

printf '\nAll %s session-title manual back-off checks passed.\n' "$pass_count"
