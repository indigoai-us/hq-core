#!/usr/bin/env bash
# Ask hq-cli to enforce the company-gated repo merge hold before Bash calls.
# hq-cli intentionally treats every check error as allow; this shim does too,
# except that a merge command too large to pass to hq is denied.
set -uo pipefail

readonly HOOK_ID="lanes-repo-merge-hold"

allow_with_notice() {
  printf '%s: %s; allowing command\n' "$HOOK_ID" "$1" >&2
  exit 0
}

deny() {
  jq -cn --arg reason "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
}

if ! command -v jq >/dev/null 2>&1; then
  allow_with_notice "jq is unavailable"
fi

INPUT="$(cat 2>/dev/null || true)"
if ! printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  allow_with_notice "could not parse the PreToolUse payload"
fi

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ "$TOOL_NAME" = "Bash" ] || exit 0

# A sentinel keeps jq's raw output from losing command-ending newlines through
# Bash command substitution. Remove only the sentinel after the read.
RAW_COMMAND="$(printf '%s' "$INPUT" | jq -jr 'if (.tool_input.command | type) == "string" then .tool_input.command, "\u0001" else empty end' 2>/dev/null || true)"
case "$RAW_COMMAND" in
  *$'\001') COMMAND_TEXT="${RAW_COMMAND%$'\001'}" ;;
  *) allow_with_notice "the Bash command is missing or malformed" ;;
esac

# Bash concatenates adjacent quoted and unquoted word fragments before invoking
# a command (m"erge", m'erge', me\rge). hq-cli still parses the original
# command text unchanged. ${var//} is quadratic on bash 3.2, so a command that
# already contains the five letters skips the strip, and a command with a
# quote or backslash is stripped with one tr. Command substitution drops
# trailing newlines; they cannot contain merge, so the substring decision
# matches the old substitution. The sentinel trim above is a one-character
# suffix removal, not a global substitution.
case "$COMMAND_TEXT" in
  *[mM][eE][rR][gG][eE]*)
    ;;
  *[\'\"\\]*)
    # One linear tr into grep. The stripped text is only tested, never
    # stored, so no second copy of a large command is held.
    if ! command -v tr >/dev/null 2>&1 || ! command -v grep >/dev/null 2>&1; then
      allow_with_notice "quote prefilter could not run"
    fi
    # grep without -q reads the whole stream. grep -q under pipefail
    # returns 141 when tr is still writing, and this test would allow a
    # quote-split merge.
    if ! printf '%s' "$COMMAND_TEXT" | LC_ALL=C tr -d '\047\042\134' | LC_ALL=C grep '[mM][eE][rR][gG][eE]' >/dev/null; then
      exit 0
    fi
    ;;
  *) exit 0 ;;
esac

# Second prefilter: start hq-cli only when "merge" stands as its own word.
# hq-cli treats a command as a merge only when a shell word is exactly
# "merge", a word ends in "/merge" (REST merge endpoint), or a word contains
# "mergePullRequest" (GraphQL). Shell quotes and backslashes inside a word are
# dropped before that comparison, and its fallback scan of unparseable
# commands treats them as word breaks. So this regex lets quotes and
# backslashes appear between the five letters, counts every character that is
# not [A-Za-z0-9_] (quotes, $(, backticks, ;, |, &, /, whitespace, any byte
# above 0x7f) as a boundary on both sides, and passes "merge" followed by "p"
# for mergePullRequest. That keeps it a superset of what hq-cli can hold,
# while field names such as mergeable, mergeStateStatus and merged skip the
# node start. Only a clean "no match" skips: printf wrote the whole command
# (exit 0) and grep read it and found nothing (exit 1). Any other result runs
# the full check.
MERGE_Q='["'"'"'\\]*'
MERGE_M="[mM]${MERGE_Q}[eE]${MERGE_Q}[rR]${MERGE_Q}[gG]${MERGE_Q}[eE]"
MERGE_WORD_RE="(^|[^A-Za-z0-9_])${MERGE_M}([^A-Za-z0-9_]|\$)|${MERGE_M}${MERGE_Q}[pP]"
# BSD grep and GNU grep before 3.6 read GREP_OPTIONS ahead of their own
# flags, so an inherited -v, -x or -w would turn a merge into a skip.
# `command` also skips an exported shell function named grep.
unset GREP_OPTIONS
# grep without -q reads the whole stream. With -q it exits at the first
# match; when SIGPIPE is ignored, printf then fails with exit 1 on a command
# larger than the pipe buffer, and pipefail would report that 1 as "no
# match". The two exit codes are read separately for the same reason.
printf '%s' "$COMMAND_TEXT" | LC_ALL=C command grep -Ea -e "$MERGE_WORD_RE" >/dev/null 2>&1
word_pipe=("${PIPESTATUS[@]}")
if [ "${word_pipe[0]:-1}" -eq 0 ] && [ "${word_pipe[1]:-0}" -eq 1 ]; then
  exit 0
fi

HQ_BIN="$(command -v hq 2>/dev/null || true)"
[ -n "$HQ_BIN" ] || allow_with_notice "hq is unavailable"

TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
[ -n "$TIMEOUT_BIN" ] || allow_with_notice "a bounded timeout command is unavailable"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lanes-repo-merge-hold.XXXXXX" 2>/dev/null || true)"
[ -n "$TMP" ] && [ -d "$TMP" ] || allow_with_notice "temporary output files could not be created"
trap 'rm -rf "$TMP"' EXIT

# Linux rejects any single exec argument over MAX_ARG_STRLEN (131072 bytes
# with its NUL). `hq lanes hold check` only takes the command as --command, so
# a larger command made the exec fail and the hook fail open. Commands up to
# this size pass unchanged on every platform.
readonly MAX_COMMAND_ARG_BYTES=131071

# Prints a shorter command that hq-cli's merge parser reads the same way, or
# exits 2 when it cannot. It mirrors hq-cli's splitCommandChain and
# shellWords (src/lib/lanes/merge-command.ts):
#   1. hq-cli parses each `;` `|` `||` `&&` CR LF segment on its own, and a
#      segment can only yield a merge target when its quote- and
#      backslash-stripped text contains "merge". Other segments are dropped.
#   2. In a kept segment, a word made only of [A-Za-z0-9_.] plus delimiting
#      quotes, whose unquoted value starts with a letter or underscore, is at
#      least 4096 characters long, has no "merge", and has no quote-split piece
#      shorter than 4 characters, is replaced by the first 128 characters of
#      its unquoted value. Neither form can be an assignment, option, repo,
#      URL, PR number, duration or niceness, 40- or 64-character head SHA,
#      command name, or a gh/pr/api token, so the parser treats both the same
#      way. A digit-first word is never shortened: cutting it can turn an
#      invalid number such as 000...05 or 000...1e3 into a valid one.
# Input newlines arrive as \001 so awk reads one record; output segments are
# joined with \001 and the caller turns them back into newlines.
reduce_command_for_hold_check() {
  LC_ALL=C awk '
    function flush_word(   rep, k, n) {
      if (!inword) return
      if (wok && wfirst == 1 && !wmerge && ulen >= 4096 && (curpiece == 0 || curpiece >= 4) && minpiece >= 4) {
        rep = ""; n = 0
        for (k = wstart; k < i && n < 128; k++) {
          if (ch[k] != "\"" && ch[k] != "\047") { rep = rep ch[k]; n++ }
        }
        nw++; ws[nw] = wstart; we[nw] = i; wr[nw] = rep
      }
      inword = 0
    }
    function word_char(c, delim,   lc) {
      if (!inword) {
        inword = 1; wstart = i; wok = 1; wmerge = 0; wwin = ""
        ulen = 0; curpiece = 0; minpiece = 1e9; wfirst = -1
      }
      if (delim) {
        if (curpiece > 0 && curpiece < minpiece) minpiece = curpiece
        curpiece = 0
        return
      }
      if (c ~ /^[A-Za-z0-9_.]$/) {
        if (wfirst < 0) wfirst = (c ~ /^[A-Za-z_]$/) ? 1 : 0
        ulen++; curpiece++
        lc = wwin tolower(c); wwin = (length(lc) > 5) ? substr(lc, 2) : lc
        if (wwin == "merge") wmerge = 1
      } else {
        wok = 0
      }
    }
    function seg_char(c,   lc) {
      if (c == "\"" || c == "\047" || c == "\\") return
      lc = swin tolower(c); swin = (length(lc) > 5) ? substr(lc, 2) : lc
      if (swin == "merge") smerge = 1
    }
    function emit(from, to,   k) {
      for (k = from; k < to; k++) printf "%s", ch[k]
    }
    function flush_segment(end,   k, pos) {
      flush_word()
      if (smerge) {
        if (kept) printf "\001"
        kept++
        pos = segstart
        for (k = 1; k <= nw; k++) {
          emit(pos, ws[k]); printf "%s", wr[k]
          pos = we[k]
        }
        emit(pos, end)
      }
      nw = 0; smerge = 0; swin = ""
    }
    {
      n = split($0, ch, ""); q = ""; esc = 0; kept = 0
      segstart = 1; nw = 0; smerge = 0; swin = ""; inword = 0
      for (i = 1; i <= n; i++) {
        c = ch[i]
        if (esc) { esc = 0; seg_char(c); word_char(c, 0); continue }
        if (c == "\\" && q != "\047") { esc = 1; word_char(c, 0); continue }
        if (q != "") {
          if (c == q) { q = ""; word_char(c, 1) }
          else { seg_char(c); word_char(c, 0) }
          continue
        }
        if (c == "\"" || c == "\047") { q = c; word_char(c, 1); continue }
        if (c == ";" || c == "|" || c == "\001" || c == "\r") {
          flush_segment(i)
          if ((c == "|" && ch[i + 1] == "|") || (c == "\r" && ch[i + 1] == "\001")) i++
          segstart = i + 1
          continue
        }
        if (c == "&" && ch[i + 1] == "&") {
          flush_segment(i); i++; segstart = i + 1
          continue
        }
        if (c == " " || c == "\t" || c == "\013" || c == "\014") { flush_word(); seg_char(c); continue }
        seg_char(c); word_char(c, 0)
      }
      if (q != "" || esc) exit 2
      flush_segment(n + 1)
      if (!kept) exit 2
    }
  '
}

HOLD_COMMAND="$COMMAND_TEXT"
COMMAND_BYTES="$(LC_ALL=C; printf '%s' "${#COMMAND_TEXT}")"
if [ "$COMMAND_BYTES" -gt "$MAX_COMMAND_ARG_BYTES" ]; then
  too_large="this Bash command is $COMMAND_BYTES bytes and contains merge, over the $MAX_COMMAND_ARG_BYTES-byte limit for one argument on Linux"
  case "$COMMAND_TEXT" in
    *$'\001'*) deny "$HOOK_ID: $too_large, and it contains a \\001 byte, so the merge-hold check cannot run. If it runs a merge, run that merge as its own smaller command. If it only mentions the word, write the large text to a file another way." ;;
  esac
  status=0
  REDUCED_RAW="$(printf '%s' "$COMMAND_TEXT" | LC_ALL=C tr '\n' '\001' 2>/dev/null | reduce_command_for_hold_check 2>/dev/null)" || status=$?
  if [ "$status" -ne 0 ] || [ -z "$REDUCED_RAW" ]; then
    deny "$HOOK_ID: $too_large, and its merge segments could not be isolated (unclosed quote or escape, or a missing tr or awk), so the merge-hold check cannot run. If it runs a merge, run that merge as its own smaller command. If it only mentions the word, write the large text to a file another way."
  fi
  if ! HOLD_COMMAND="$(printf '%s' "$REDUCED_RAW" | LC_ALL=C tr '\001' '\n' 2>/dev/null)" || [ -z "$HOLD_COMMAND" ]; then
    deny "$HOOK_ID: $too_large, and its merge segments could not be rebuilt (tr failed), so the merge-hold check cannot run. If it runs a merge, run that merge as its own smaller command. If it only mentions the word, write the large text to a file another way."
  fi
  HOLD_BYTES="$(LC_ALL=C; printf '%s' "${#HOLD_COMMAND}")"
  if [ "$HOLD_BYTES" -gt "$MAX_COMMAND_ARG_BYTES" ]; then
    deny "$HOOK_ID: $too_large, and its merge segments are still $HOLD_BYTES bytes, so the merge-hold check cannot run. If it runs a merge, run that merge as its own smaller command. If it only mentions the word, write the large text to a file another way."
  fi
fi

status=0
# Keep HQ_NO_UPDATE_CHECK on every bounded hq invocation: startup must not
# trigger a global install while the five-second hook deadline is running.
HQ_NO_UPDATE_CHECK=1 "$TIMEOUT_BIN" -k 1s 5s "$HQ_BIN" lanes hold check \
  --command "$HOLD_COMMAND" --json >"$TMP/stdout" 2>"$TMP/stderr" || status=$?

if [ "$status" -eq 0 ]; then
  exit 0
fi

if [ "$status" -eq 3 ]; then
  if ! jq -e -s '
    length == 1
    and (.[0] | type == "object")
    and (.[0].ok == false)
    and (.[0].error | type == "string" and length > 0)
  ' "$TMP/stdout" >/dev/null 2>&1; then
    allow_with_notice "hq lanes hold check returned an invalid exit-3 response"
  fi

  error="$(jq -r '.error' "$TMP/stdout")"
  repo="$(jq -r 'if (.repo | type == "string" and length > 0) then .repo else empty end' "$TMP/stdout")"
  reason="$(jq -r 'if (.reason | type == "string" and length > 0) then .reason else empty end' "$TMP/stdout")"
  hold_until="$(jq -r 'if (.until | type == "string" and length > 0) then .until else empty end' "$TMP/stdout")"
  message="$(jq -r 'if (.message | type == "string" and length > 0) then .message else empty end' "$TMP/stdout")"

  if [ -n "$message" ]; then
    deny "$HOOK_ID: $message"
  fi

  if [ "$error" = "repo_merge_held" ]; then
    repo_label="${repo:-unknown repo}"
    reason_label="${reason:-unspecified hold reason}"
    until_label="${hold_until:-unknown}"
    details=""
    [ -n "$repo" ] && details=" For details, run: hq lanes hold show $repo."
    deny "Repo merge hold for $repo_label: $reason_label. Until $until_label.$details"
  fi

  repo_label="${repo:-unknown repo}"
  response="$error for $repo_label"
  [ -n "$reason" ] && response="$response. Reason: $reason"
  [ -n "$hold_until" ] && response="$response. Until $hold_until"
  [ -n "$repo" ] && response="$response. For details, run: hq lanes hold show $repo."
  deny "$response"
fi

# This gate fails open by design to match hq-cli, which treats all check
# errors (including older CLIs without `lanes hold`) as allow. Capture child
# stderr so a timeout wrapper or older CLI still produces only one line.
allow_with_notice "hq lanes hold check did not confirm a hold (exit $status)"
