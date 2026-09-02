#!/usr/bin/env bash
# session-title.sh — SessionStart + UserPromptSubmit hook.
#
# Sets the Claude Code session title (desktop sidebar "Recents" / terminal tab
# title / `/resume` picker) to an HQ status string:
#     {icon} {CATEGORY} · {subject} · {phase}
#
# The title string is computed by core/scripts/session-title.sh. This wrapper
# detects the active slash command from the prompt, persists it across turns,
# and emits hookSpecificOutput.sessionTitle — but ONLY when the title actually
# changes (live, change-only cadence).
#
# Manual-rename back-off: once the user sets their own title (launcher
# `claude --name`, `/rename`, or the desktop "Recents" rename), HQ must stop
# overwriting it. Any title Claude Code surfaces that HQ does not own is a
# manual title, so we mark the session (${STATE}.manual) and permanently stop
# emitting for it. Signals, in order:
#   PRIMARY   the documented `session_title` SessionStart hook input
#   SECONDARY the newest `custom-title` line in the session transcript, which
#             is how a mid-session /rename surfaces (the transcript format is
#             internal/version-fragile, so it is a labeled net, not the path)
#
# "HQ owns this title" is decided by three tests, because a session_title is
# inherited across fork/resume while the session id is not, and .claude/state
# can be wiped at any time:
#   1. the per-session ledger  (${STATE}.emitted)
#   2. the cross-session ledger of every title HQ has emitted on this machine
#      (${STATE_DIR}/session-title.hq-titles) — survives fork/resume/new ids
#   3. an exact match against the title HQ computes for this turn — survives a
#      wiped state directory
# Without those, HQ's own title echoed back on a forked session would look like
# a manual rename and would silently disable titling for that session.
#
# Opt out:  HQ_SESSION_TITLE=off (or 0/false/no)  |  HQ_DISABLED_HOOKS=session-title
set -uo pipefail

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
HELPER="$HQ_ROOT/core/scripts/session-title.sh"
STATE_DIR="$HQ_ROOT/.claude/state"

case "${HQ_SESSION_TITLE:-on}" in
  0|false|FALSE|off|OFF|no|NO) exit 0 ;;
esac

[ -x "$HELPER" ] || exit 0

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"

extract() {
  printf '%s' "$STDIN_JSON" | hq_json_get "$1"
}

EVENT="$(extract hook_event_name)"
SOURCE="$(extract source)"
PROMPT="$(extract prompt)"
SESSION_ID="$(extract session_id)"
TRANSCRIPT="$(extract transcript_path)"
# Documented, version-stable SessionStart field: Claude Code populates it with
# the user's title when the session was named via --name or renamed via /rename.
SESSION_TITLE_INPUT="$(extract session_title)"
[ -z "$SESSION_ID" ] && SESSION_ID="default"

# Infer the event if Claude Code did not provide hook_event_name.
if [ -z "$EVENT" ]; then
  if [ -n "$PROMPT" ]; then EVENT="UserPromptSubmit"; else EVENT="SessionStart"; fi
fi

# SessionStart sessionTitle is ignored on clear/compact — skip those.
if [ "$EVENT" = "SessionStart" ]; then
  case "$SOURCE" in clear|compact) exit 0 ;; esac
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true
SESSION_KEY="$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$SESSION_KEY" ] || SESSION_KEY="default"
STATE="$STATE_DIR/session-title-${SESSION_KEY}"
EMITTED="$STATE.emitted"   # ledger of titles HQ has emitted this session
MANUAL="$STATE.manual"     # marker: a manual title was seen -> stop emitting
# Cross-session ledger of every title HQ has emitted on this machine. A dotted
# name so per-session pruning ("session-title-*") never sweeps it away.
HQ_TITLES="$STATE_DIR/session-title.hq-titles"
HQ_TITLES_MAX=400          # keep the ledger bounded; newest entries win
AUTONAME="$STATE.autoname" # the one desktop auto-title HQ ignores per session

# Claude Desktop's built-in auto-titler writes the SAME transcript
# custom-title line as a user /rename — no field tells them apart, and there
# is no host setting to disable it. Under desktop_autoname=ignore-first
# (the default; set desktop_autoname: respect in settings/session-title.yaml
# to restore the old behavior) the FIRST transcript-borne foreign title per
# session is treated as the auto-titler and ignored — HQ retakes the title.
# A second, different foreign title is a genuine rename and backs off.
DESKTOP_AUTONAME="ignore-first"
CONFIG_HELPER="$HQ_ROOT/core/scripts/session-title-config.sh"
if [ -f "$CONFIG_HELPER" ]; then
  cfg_line="$(bash "$CONFIG_HELPER" --root "$HQ_ROOT" 2>/dev/null | grep '^desktop_autoname=' || true)"
  [ "${cfg_line#desktop_autoname=}" = "respect" ] && DESKTOP_AUTONAME="respect"
fi

hq_title_grammar() {
  # Does TITLE ($1) follow the HQ title grammar — "{icon} {CAT} · {subject}"?
  #
  # This is the load-bearing ownership test now that titles are also set
  # mid-session by the model via set_session_title. Those titles are HQ's, but
  # they are by design NOT in either ledger (the hook never computed them), so
  # a ledger-only test read them as a manual rename and permanently disabled
  # titling for the session. A human rename is free-form prose ("AGI book
  # translations"); it does not carry a SHOUTCASE category token followed by a
  # middot separator.
  #
  # Defined up here, rather than beside its sibling helpers further down,
  # because the stale-mute heal below runs before those definitions.
  printf '%s' "$1" | grep -qE '^([^ ]+ )?[A-Z][A-Z0-9]{1,7} · .+'
}

# --- manual-rename back-off (BEGIN) -----------------------------------------
# Permanent back-off once a manual title has been detected for this session.
# Refresh the marker's mtime on the way out so a long-lived named session is
# never swept by another session's 14-day prune below.
if [ -f "$MANUAL" ]; then
  # Stale-mute heal. Sessions muted by the withheld-free-pass bug (see
  # ignore_desktop_autoname) carry a .manual marker with NO .autoname sibling —
  # the pass was never granted, so nothing recorded why the session was muted.
  # If such a session is currently showing a title in HQ grammar, the mute was
  # provably wrong (a real manual rename is free-form prose), so clear it and
  # let HQ resume naming. A mute with an .autoname sibling was a genuine second
  # rename and is left alone.
  healed=0
  if [ ! -f "$AUTONAME" ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    live="$(grep -F '"custom-title"' "$TRANSCRIPT" 2>/dev/null | tail -n 1 |
            hq_json_get 'customTitle')"
    if [ -n "$live" ] && hq_title_grammar "$live"; then
      rm -f "$MANUAL" 2>/dev/null && healed=1
    fi
  fi
  if [ "$healed" != "1" ]; then
    touch "$MANUAL" 2>/dev/null || true
    exit 0
  fi
fi
# --- manual-rename back-off (END) -------------------------------------------

prune_stale_state() {
  # Per-session title state accumulates one to three small files per session.
  # Drop anything untouched for a fortnight; cheap and SessionStart-only.
  command -v find >/dev/null 2>&1 || return 0
  find "$STATE_DIR" -maxdepth 1 -type f -name 'session-title-*' -mtime +14 \
    -exec rm -f {} + 2>/dev/null || true
}
[ "$EVENT" = "SessionStart" ] && prune_stale_state

hq_emitted_title() {
  # Has HQ emitted TITLE ($1) — in this session, or in any session on this
  # machine? The cross-session ledger is what keeps a forked or resumed session
  # (new session id, inherited title) from mistaking HQ's own title for a
  # manual rename.
  local t="$1"
  if [ -f "$EMITTED" ] && grep -qxF -- "$t" "$EMITTED" 2>/dev/null; then return 0; fi
  if [ -f "$HQ_TITLES" ] && grep -qxF -- "$t" "$HQ_TITLES" 2>/dev/null; then return 0; fi
  return 1
}

mark_manual() {
  : > "$MANUAL" 2>/dev/null || true
}

transcript_custom_title() {
  # Newest custom-title value from a Claude Code transcript .jsonl, or "".
  # Real transcript lines carry the title under "customTitle":
  #   {"type":"custom-title","customTitle":"…","sessionId":"…"}
  # The plain "title" key is read as a defensive fallback only. The transcript
  # format is internal/version-fragile — this whole path is a net, not the API.
  local f="$1" last="" value=""
  last="$(grep -F '"custom-title"' "$f" 2>/dev/null | tail -n 1)"
  [ -n "$last" ] || { printf '%s' ""; return 0; }
  value="$(printf '%s' "$last" | hq_json_get 'customTitle')"
  [ -n "$value" ] || value="$(printf '%s' "$last" | hq_json_get 'title')"
  printf '%s' "$value"
}

# State file: line 1 = last command word, line 2 = last emitted title.
last_command=""; last_title=""
if [ -f "$STATE" ]; then
  last_command="$(sed -n '1p' "$STATE" 2>/dev/null || true)"
  last_title="$(sed -n '2p' "$STATE" 2>/dev/null || true)"
fi

# Detect a leading slash command in this prompt (UserPromptSubmit only); the
# command word persists across turns until a new command is issued.
command="$last_command"
if [ "$EVENT" = "UserPromptSubmit" ] && [ -n "$PROMPT" ]; then
  # First non-blank content must open with /command; keep the last :segment
  # (mirrors the old lstrip + regex + split(":")[-1] semantics).
  detected="$(printf '%s' "$PROMPT" | awk '
    !found && /[^ \t]/ {
      found = 1
      line = $0; sub(/^[ \t]+/, "", line)
      if (match(line, /^\/[A-Za-z0-9:_-]+/)) {
        s = substr(line, RSTART + 1, RLENGTH - 1)
        n = split(s, a, ":"); print a[n]
      }
    }' 2>/dev/null || true)"
  [ -n "$detected" ] && command="$detected"
fi

# --- project-marker wait (BEGIN) --------------------------------------------
# The auto-session-project hook (also UserPromptSubmit) writes the session's
# project marker, but hooks in one event run in PARALLEL — computing the title
# here often loses that race on the very first prompt and emits a projectless
# stub ("HQ", "chat"). Wait briefly for the marker, once per session, so the
# first emitted title already carries the project. The once-flag keeps
# projectless sessions from paying the wait on every prompt.
PROJ_MARKER="$STATE_DIR/auto-session-project-${SESSION_KEY}"
PROJWAIT="$STATE.projwait"
if [ "$EVENT" = "UserPromptSubmit" ] && [ ! -f "$PROJ_MARKER" ] && [ ! -f "$PROJWAIT" ]; then
  : > "$PROJWAIT" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -f "$PROJ_MARKER" ] && break
    sleep 0.1
  done
fi
# --- project-marker wait (END) ----------------------------------------------

title="$("$HELPER" --session-id "$SESSION_ID" --command "$command" 2>/dev/null || true)"
[ -n "$title" ] || exit 0

hq_owned_title() {
  # Is TITLE ($1) one of HQ's own, rather than a user's manual rename?
  # Ledger hit, an exact match against what HQ computes for this very turn
  # (survives a wiped/relocated .claude/state, where both ledgers are empty but
  # the inherited title is still plainly ours), or a title in HQ grammar.
  local t="$1"
  [ "$t" = "$title" ] && return 0
  [ -n "$last_title" ] && [ "$t" = "$last_title" ] && return 0
  hq_title_grammar "$t" && return 0
  hq_emitted_title "$t"
}

transcript_has_custom_title() {
  # Does the transcript carry TITLE ($1) as a custom-title line?
  [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || return 1
  grep -F '"custom-title"' "$TRANSCRIPT" 2>/dev/null |
    grep -qF "\"customTitle\":\"$1\""
}

FORCE_EMIT=0
ignore_desktop_autoname() {
  # Foreign TITLE ($1) seen VIA ($2: "transcript" when it arrived as a
  # transcript custom-title line). Returns 0 to ignore it as the desktop
  # auto-titler's work; 1 means treat it as a genuine manual rename.
  #
  # The free pass normally requires transcript proof, because a launcher
  # --name also arrives via session_title with no transcript line and must
  # keep backing off.
  #
  # One case cannot supply that proof: a desktop auto-title INHERITED ON
  # RESUME. It arrives in session_title at SessionStart, when the transcript is
  # frequently unreadable — the path may be absent, or the title line not yet
  # flushed. Proof failed, the pass was withheld, and the session was muted
  # permanently, leaving no .autoname behind to show why. Resumes are therefore
  # allowed to claim the pass unproven; startup (where --name is the only way a
  # title can exist before any turn) and every other event still require proof.
  local t="$1" via="${2:-}"
  [ "$DESKTOP_AUTONAME" = "ignore-first" ] || return 1
  if [ -f "$AUTONAME" ] && grep -qxF -- "$t" "$AUTONAME" 2>/dev/null; then
    FORCE_EMIT=1
    return 0
  fi
  [ -f "$AUTONAME" ] && return 1   # the free pass is already spent
  if [ "$via" != "transcript" ]; then
    [ "$EVENT" = "SessionStart" ] && [ "$SOURCE" = "resume" ] || return 1
  fi
  printf '%s\n' "$t" > "$AUTONAME" 2>/dev/null || true
  FORCE_EMIT=1
  return 0
}

manual_title_backoff() {
  # Returns 0 when a title HQ does not own is in play — the user renamed the
  # session and owns it from here on.
  #
  # PRIMARY: the documented `session_title` SessionStart input. Empty on an
  # unnamed session; set to the user's title after --name or /rename.
  if [ -n "$SESSION_TITLE_INPUT" ] && ! hq_owned_title "$SESSION_TITLE_INPUT"; then
    # A desktop auto-title inherited on resume shows up here too; it earns the
    # transcript-borne free pass only when the transcript proves its origin.
    local via=""
    transcript_has_custom_title "$SESSION_TITLE_INPUT" && via="transcript"
    ignore_desktop_autoname "$SESSION_TITLE_INPUT" "$via" || return 0
  fi
  # SECONDARY (labeled fallback): a mid-session /rename is not reflected in the
  # SessionStart input, so read the newest custom-title line in the transcript.
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    local ct
    ct="$(transcript_custom_title "$TRANSCRIPT")"
    if [ -n "$ct" ] && ! hq_owned_title "$ct"; then
      ignore_desktop_autoname "$ct" "transcript" || return 0
    fi
  fi
  return 1
}

# --- manual-rename back-off (BEGIN) -----------------------------------------
if manual_title_backoff; then
  mark_manual
  exit 0
fi
# --- manual-rename back-off (END) -------------------------------------------

record_emitted() {
  # Append TITLE ($1) to the per-session and cross-session HQ-emitted ledgers.
  hq_emitted_title "$1" && return 0
  printf '%s\n' "$1" >> "$EMITTED" 2>/dev/null || true
  printf '%s\n' "$1" >> "$HQ_TITLES" 2>/dev/null || true
  # Bound the shared ledger: keep the newest HQ_TITLES_MAX entries.
  local lines
  lines="$(wc -l < "$HQ_TITLES" 2>/dev/null || echo 0)"
  if [ "${lines:-0}" -gt "$((HQ_TITLES_MAX * 2))" ] 2>/dev/null; then
    tail -n "$HQ_TITLES_MAX" "$HQ_TITLES" > "$HQ_TITLES.tmp" 2>/dev/null &&
      mv -f "$HQ_TITLES.tmp" "$HQ_TITLES" 2>/dev/null || true
  fi
}

# Persist the command regardless; only emit when the title actually changed —
# unless a desktop auto-title was just ignored, in which case the host is
# showing the foreign title and HQ must re-emit to retake it.
if [ "$title" = "$last_title" ] && [ "$FORCE_EMIT" != "1" ]; then
  record_emitted "$title"
  printf '%s\n%s\n' "$command" "$last_title" > "$STATE" 2>/dev/null || true
  exit 0
fi

record_emitted "$title"
printf '%s\n%s\n' "$command" "$title" > "$STATE" 2>/dev/null || true

jq -n --arg ev "$EVENT" --arg t "$title" '{
  hookSpecificOutput: {
    hookEventName: $ev,
    sessionTitle: $t
  }
}'
exit 0
