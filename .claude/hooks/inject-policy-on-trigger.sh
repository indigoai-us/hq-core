#!/bin/bash
# inject-policy-on-trigger.sh — the sole policy-surfacing path.
# hq-capability: worker-policy-dir v1
#
# The pre-built policy digest (and its always-on / stack-filtered tiers) was
# retired; this hook now both injects every on:[SessionStart] policy whose
# `when:` matches at session start AND injects a short `<policy-reminder>` when a
# reactive policy's trigger fires mid-session (~150 bytes per match), deduped
# per session.
#
# TWO trigger sources, unified and deduped by slug:
#   (A) `when:`/`on:` frontmatter on policy files — boolean expressions over an
#       open token set, evaluated by core/scripts/eval-trigger.sh against facts
#       derived by core/scripts/derive-trigger-facts.sh. This is the primary,
#       data-driven path. Runs on UserPromptSubmit and PostToolUse by default;
#       PreToolUse is available for explicit policies and legacy rollback.
#   (B) Legacy hardcoded regex map (below) — for precise patterns a coarse
#       boolean token can't express (e.g. `git checkout {ref} -- .`, `pgrep`,
#       `IFS=":"`). PreToolUse only. Kept so migrating policies to `when:` is
#       incremental and never regresses coverage.
#
# Injection DEPTH is tiered by `enforcement:` (see the emit block at the bottom):
#   hard → the policy's BINDING body is injected verbatim (everything after the
#          frontmatter up to the first archival heading), under a per-policy
#          cap and a shared byte budget whose overflow is reported, never
#          silent.
#   soft/unset → the one-line `## Rule` excerpt, as always.
#
# Event: taken from `hook_event_name` in stdin (default PreToolUse). Passive
# evaluation defaults to PostToolUse; the one-release
# HQ_POLICY_TOOL_EVENTS=legacy switch restores passive Bash PreToolUse
# evaluation and the historical omitted-on default.
# Scope (tenant-safe) and precedence: worker > company > repo > personal > core.
#   Company worker policies load only when their company is the session's own
#   active tenant. Repo policies load only when the session cwd is in that repo;
#   exactly ONE company's policies load, for the session's active tenant — resolved as
#   HQ_POLICY_COMPANY > cwd companies/<slug> > session-meta company_slug (US-004,
#   see the DIRS block). The session-meta step is what lets an HQ-root session
#   load its bound company; it never widens scope to a second company.
# Dedupe: per session-id; a slug never fires twice in one session.
# Exit: always 0 (advisory hook, never blocks).
#
# RELEVANCE SCORE (2026-10-22, reminder-ceiling design; mirror this table in
# any port of the emit stage). The evaluator prints a 14th TSV field, the
# integer score of each matched row. It is the sum over the `when:`
# identifiers present in the fact set (the trigger key), one weight each,
# the first matching line wins:
#   identifier contains "/" or "."  (path, extension, slash command)    3
#   synthetic fact: secret, apikey, shared_branch, completed             2
#   command head word (first word of a command segment; `cd`, `sudo`,
#     `env`, `time`, `nohup`, `exec` and VAR=value prefixes are skipped) 2
#   rare: used by at most HQ_POLICY_RARE_TOKEN_MAX (3) in-scope policies 2
#   common word: used by more than 20% of the in-scope policies          0
#   any other identifier                                                 1
# A row whose identifiers all weigh 0 but that matched two or more of them
# (specificity 2 or more) scores 1. Scope bonus when the identifier sum is
# above zero: worker +1, company +1, personal 0, core 0. A row whose
# identifiers sum to zero (one common word, or no identifier at all) is treated as
# a generic match under the generic cap, HARD or not. Groups stay
# (reactive before baseline, HARD before soft inside a relevance tier);
# inside a group the sort key is score desc, then specificity desc, then
# staleness asc, then scope and file order.
#
# SEEN SET (<sid>.seen.tsv, "slug<TAB>epoch<TAB>trigger-key"). A `once` row
# is written here, not to the session ledger, when it reached the reminder
# as anything less than its full text for a reason that can change:
#   - a HARD row with score 1 or more listed as a one-line summary because
#     the full-text budget or the output ceiling demoted it (a body that can
#     never print in full, or a score-0 row, goes to the session ledger
#     instead so the footer can tell it from a row parked unseen);
#   - a generic row (score 0 or one common word) parked by the generic cap.
# A row the output ceiling cut was never delivered: it is not recorded
# anywhere and stays eligible, so it rotates into the next call once the
# delivered rows have moved to the footer (that is the drain).
# While the entry is younger than HQ_POLICY_SEEN_TTL_SECONDS (1800) and the
# row matches again on the same trigger key, the row is not listed as its
# own line; a HARD row that was delivered (score 1 or more: such rows are
# never parked by the generic cap, so a seen entry means an emitted summary
# line) is named in the "Already shown this session" footer instead. A
# different trigger key or an expired entry makes it eligible again,
# including for full text. Rows shown in full stay in the session ledger and
# are named in the same footer when they match again. The footer never
# names a row that was not delivered.

set -euo pipefail

STDIN_JSON=""
IFS= read -r -d '' STDIN_JSON || true
while [[ "$STDIN_JSON" == *$'\n' ]]; do
  STDIN_JSON="${STDIN_JSON%$'\n'}"
done
STDIN_FILE=""
POLICY_TRIGGER_INPUT_FILE_LIMIT=65536

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_SOURCE%/*}"
[ "$SCRIPT_DIR" != "$SCRIPT_SOURCE" ] || SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"
HELPERS="${SCRIPT_DIR%/.claude/hooks}/core/scripts"
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

# Use master-hook's shared profile/disabled-hook predicate so the scan and its
# direct enforcement call are governed by the same gate registration state.
if [ -f "$HQ_ROOT/.claude/hooks/hook-gate.sh" ]; then
  # shellcheck disable=SC1091
  . "$HQ_ROOT/.claude/hooks/hook-gate.sh" --lib
fi
POLICY_ENFORCEMENT_GATE_ENABLED=0
if [ -f "$HQ_ROOT/.claude/hooks/policy-enforcement-gate.sh" ] \
  && command -v hq_hook_profile_allows >/dev/null 2>&1 \
  && hq_hook_profile_allows policy-enforcement-gate; then
  POLICY_ENFORCEMENT_GATE_ENABLED=1
fi

ACTIVE_ENFORCEMENT_LOCK=""
ACTIVE_ENFORCEMENT_TOKEN=""
ENFORCEMENT_LOCK_TTL_SECONDS=30
cleanup_enforcement_lock() {
  local current_token=""
  [ -n "$ACTIVE_ENFORCEMENT_LOCK" ] || return 0
  current_token="$(cat "$ACTIVE_ENFORCEMENT_LOCK/token" 2>/dev/null || true)"
  if [ "$current_token" = "$ACTIVE_ENFORCEMENT_TOKEN" ]; then
    rm -f "$ACTIVE_ENFORCEMENT_LOCK/pid" "$ACTIVE_ENFORCEMENT_LOCK/time" \
      "$ACTIVE_ENFORCEMENT_LOCK/token" 2>/dev/null || true
    rmdir "$ACTIVE_ENFORCEMENT_LOCK" 2>/dev/null || true
  fi
}

reclaim_stale_enforcement_lock() {
  local lock="$1" holder_pid="" holder_time="" holder_token="" current_pid="" \
    current_time="" current_token="" now="" lock_mtime="" stale=0
  [ -d "$lock" ] || return 0
  holder_pid="$(cat "$lock/pid" 2>/dev/null || true)"
  holder_time="$(cat "$lock/time" 2>/dev/null || true)"
  holder_token="$(cat "$lock/token" 2>/dev/null || true)"
  if [[ "$holder_pid" =~ ^[0-9]+$ ]] && (( holder_pid > 1 )) \
     && ! kill -0 "$holder_pid" 2>/dev/null; then
    stale=1
  fi
  now="$(date +%s 2>/dev/null || true)"
  if [[ "$holder_time" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] \
     && (( now >= holder_time && now - holder_time >= ENFORCEMENT_LOCK_TTL_SECONDS )); then
    stale=1
  elif [[ ! "$holder_time" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]]; then
    lock_mtime="$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || true)"
    if [[ "$lock_mtime" =~ ^[0-9]+$ ]] \
       && (( now >= lock_mtime && now - lock_mtime >= ENFORCEMENT_LOCK_TTL_SECONDS )); then
      stale=1
    fi
  fi
  [ "$stale" -eq 1 ] || return 1

  # Re-read ownership before reclaiming so a newly acquired lock is not removed
  # when another process released the observed stale directory during the check.
  current_pid="$(cat "$lock/pid" 2>/dev/null || true)"
  current_time="$(cat "$lock/time" 2>/dev/null || true)"
  current_token="$(cat "$lock/token" 2>/dev/null || true)"
  [ "$current_pid:$current_time:$current_token" = \
    "$holder_pid:$holder_time:$holder_token" ] || return 1
  rm -f "$lock/pid" "$lock/time" "$lock/token" 2>/dev/null || true
  rmdir "$lock" 2>/dev/null
}
trap cleanup_enforcement_lock EXIT

JQ="$(command -v jq || true)"

# The timeout watchdog and master hook use this exact session-hash convention
# for their per-dispatch journal. Adapter runtimes execute this hook before the
# master hook exports HQ_HOOK_TIMEOUT_JOURNAL_FILE, so derive the same path when
# the environment handoff has not happened yet.
policy_trigger_sha256() {
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s\0' "$@" | shasum -a 256 2>/dev/null)" || return 1
    printf '%s\n' "${digest%% *}"
  elif command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s\0' "$@" | sha256sum 2>/dev/null)" || return 1
    printf '%s\n' "${digest%% *}"
  elif command -v openssl >/dev/null 2>&1; then
    digest="$(printf '%s\0' "$@" | openssl dgst -sha256 2>/dev/null)" || return 1
    printf '%s\n' "${digest##* }"
  else
    return 1
  fi
}

policy_trigger_journal_file() {
  local journal_file="${HQ_HOOK_TIMEOUT_JOURNAL_FILE:-}" session_hash=""
  if [ -n "$journal_file" ]; then
    printf '%s' "$journal_file"
    return 0
  fi
  [ -n "${SESSION_ID:-}" ] || return 0
  session_hash="$(policy_trigger_sha256 "$SESSION_ID" 2>/dev/null || true)"
  [ -n "$session_hash" ] || return 0
  printf '%s/workspace/.hook-timeout-journal/%s.tsv' "$HQ_ROOT" "$session_hash"
}

extract() {
  if ! declare -F hq_json_get >/dev/null 2>&1; then
    . "$HELPERS/hook-lib.sh"
  fi
  printf '%s' "$STDIN_JSON" | hq_json_get "$1"
}

# These five scalar values are required on every invocation. When jq is
# available (the same prerequisite for policy evaluation below), extract them
# in one process rather than launching jq four times. NUL delimiters keep
# whitespace and embedded newlines intact; command substitution then matches
# hq_json_get's existing trailing-newline behavior. Fall back to the shared
# helper when jq or a complete scalar result is unavailable.
INITIAL_FIELDS=()
if [ -n "$JQ" ]; then
  while IFS= read -r -d '' initial_field; do
    INITIAL_FIELDS+=("$initial_field")
  done < <(
    # shellcheck disable=SC2016 # jq program intentionally uses single quotes.
    printf '%s' "$STDIN_JSON" | "$JQ" -j '
      def scalar($path):
        try (getpath($path) | if . == null or type == "object" or type == "array" then "" else tostring end)
        catch "";
      scalar(["hook_event_name"]) + "\u0000",
      scalar(["session_id"]) + "\u0000",
      scalar(["tool_name"]) + "\u0000",
      scalar(["cwd"]) + "\u0000",
      scalar(["tool_input", "command"]) + "\u0000",
      scalar(["prompt"]) + "\u0000"
    ' 2>/dev/null
  )
fi
if [ "${#INITIAL_FIELDS[@]}" -eq 6 ]; then
  EVENT="${INITIAL_FIELDS[0]}"
  SESSION_ID="${INITIAL_FIELDS[1]}"
  TOOL_NAME="${INITIAL_FIELDS[2]}"
  CWD="${INITIAL_FIELDS[3]}"
  ARG="${INITIAL_FIELDS[4]}"
  PROMPT="${INITIAL_FIELDS[5]}"
else
  EVENT="$(extract hook_event_name)"
  SESSION_ID="$(extract session_id)"
  TOOL_NAME="$(extract tool_name)"
  CWD="$(extract cwd)"
  ARG="$(extract tool_input.command)"
  PROMPT="$(extract prompt)"
fi
[ -z "$EVENT" ] && EVENT="PreToolUse"
[ -z "$CWD" ] && CWD="$HQ_ROOT"

# Background Bash completions and task-notification blocks are harness
# messages, not user requests. The Monitor expiry signal is classified once
# by master-hook.sh and handed down through the environment to keep its exact
# fast-path predicate as the single source of truth.
if [ "$EVENT" = "UserPromptSubmit" ]; then
  if [ "${HQ_HOOK_MONITOR_EXPIRY_NOTIFICATION:-0}" = "1" ]; then
    exit 0
  fi
  case "$PROMPT" in
    '<task-notification>'*'</task-notification>'|\
    'The following task has completed:'*'<task-notification>'*'</task-notification>'*|\
    'The following task has failed:'*'<task-notification>'*'</task-notification>'*|\
    'The following background task has completed:'*'<task-notification>'*'</task-notification>'*|\
    'The following background task has failed:'*'<task-notification>'*'</task-notification>'*)
      exit 0
      ;;
  esac
fi

# Plain PreToolUse stdout is not delivered as model context. Avoid passive
# policy scans there unless the one-release rollback switch is active. Blocking
# hooks are separate registry entries and remain unaffected. Grok does not
# deliver PostToolUse context, so do not evaluate or ledger policy slugs there.
if [ "$EVENT" = "PreToolUse" ] && [ "${HQ_POLICY_TOOL_EVENTS:-}" != "legacy" ]; then
  [ "$POLICY_ENFORCEMENT_GATE_ENABLED" -eq 1 ] || exit 0
fi
if [ "$EVENT" = "PostToolUse" ] && [ "${HQ_HARNESS:-}" = "grok" ]; then
  exit 0
fi

# Tool-event trigger evaluation is scoped to CLI/Bash only — the frequent
# Read/Write/Edit/Glob tool calls don't pay the policy scan. The message path
# (UserPromptSubmit) is unaffected and still evaluates on every prompt.
if { [ "$EVENT" = "PreToolUse" ] || [ "$EVENT" = "PostToolUse" ]; } && [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

# Per-session dedupe ledger (unchanged location for continuity).
DEDUPE_DIR="$HQ_ROOT/workspace/orchestrator/policy-trigger-state"
DEDUPE_FILE="$DEDUPE_DIR/${SESSION_ID:-default}.txt"
STATS_DIR="$HQ_ROOT/workspace/orchestrator/policy-emit-stats"

# Second ledger for `inject: always` policies (see the frontmatter field of the
# same name). Where the session ledger above fires a slug at most once for the
# WHOLE session, this TURN ledger fires an `always` slug at most once per TURN:
# it is truncated at the start of every UserPromptSubmit (turn boundary), so an
# always-policy re-injects on each new user message, but is still deduped across
# the mid-turn Bash calls of that same turn (no per-command spam). The two
# ledgers are disjoint by policy: a `once` slug is only ever recorded in the
# session ledger, an `always` slug only in the turn ledger.
TURN_FILE="$DEDUPE_DIR/${SESSION_ID:-default}.turn.txt"
# Seen set with a TTL (see SEEN SET in the header): rows delivered as less
# than their full text (summary line, cut by the ceiling, parked by the
# generic cap). Not written to the session ledger, so a later event can still
# deliver their full text, but the same rule for the same trigger is not
# repeated inside the window. Lines are "slug<TAB>epoch<TAB>trigger-key". A
# rule comes back after HQ_POLICY_SEEN_TTL_SECONDS, or at once when a
# different trigger matches it.
SEEN_FILE="$DEDUPE_DIR/${SESSION_ID:-default}.seen.tsv"
SEEN_TTL="${HQ_POLICY_SEEN_TTL_SECONDS:-1800}"
case "$SEEN_TTL" in ''|*[!0-9]*) SEEN_TTL=1800 ;; esac
FACTS_TMP_DIR=""
JOURNAL_FILE=""
JOURNAL_DIR=""
if [ -n "$JQ" ] && [ -f "$HELPERS/eval-trigger.sh" ] && [ -f "$HELPERS/derive-trigger-facts.sh" ]; then
  FACTS_TMP_DIR="$HQ_ROOT/workspace/orchestrator/hook-state"
  JOURNAL_FILE="$(policy_trigger_journal_file)"
  [ -z "$JOURNAL_FILE" ] || JOURNAL_DIR="${JOURNAL_FILE%/*}"
  STATE_DIRS=("$DEDUPE_DIR" "$FACTS_TMP_DIR")
  [ -z "$JOURNAL_DIR" ] || STATE_DIRS+=("$JOURNAL_DIR")
  mkdir -p "${STATE_DIRS[@]}" 2>/dev/null || true
else
  mkdir -p "$DEDUPE_DIR" 2>/dev/null || true
fi
if [ "$EVENT" = "UserPromptSubmit" ]; then
  : > "$TURN_FILE" 2>/dev/null || true
fi
touch "$DEDUPE_FILE" 2>/dev/null || true
touch "$TURN_FILE" 2>/dev/null || true

# Accumulate
# "slug<TAB>scope<TAB>abs_path<TAB>enforcement<TAB>rule<TAB>kind<TAB>inject<TAB>whenstate"
# matches. `kind`, `inject` and `whenstate` are internal metadata (the cap, the
# dedup ledger, and the malformed-trigger notice); the TSV
# contract remains its original five fields and retains its original ordering.
# Default emit still prints only slug+rule as <policy-reminder> prose; tsv mode
# (HQ_POLICY_EMIT=tsv, US-406) prints all five fields per line.
MATCHES=""
# already <slug> [inject]  — has this slug already fired in the ledger that
# governs its cadence? `once` (default) consults the session ledger; `always`
# consults the per-turn ledger.
already() {
  local ledger line
  if [ "${2:-once}" = "always" ]; then
    ledger="$TURN_FILE"
  else
    ledger="$DEDUPE_FILE"
  fi
  [ -r "$ledger" ] || return 1
  # This runs once for every policy match. An external grep here adds a child
  # process for each matching slug. Read the newline-delimited ledger with Bash
  # builtins so membership stays fresh for each match without another fork.
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" = "$1" ] && return 0
  done < "$ledger" 2>/dev/null
  return 1
}

# Copy a ledger byte-for-byte through Bash builtins for the evaluation-cache
# digest. Ledgers contain newline-delimited slugs; preserve a final unterminated
# line too, matching `cat` without launching a process for each ledger.
append_policy_ledger() {
  local ledger="$1" line=""
  [ -r "$ledger" ] || return 0
  while :; do
    line=""
    if IFS= read -r line; then
      printf '%s\n' "$line"
    else
      [ -n "$line" ] && printf '%s' "$line"
      break
    fi
  done < "$ledger" 2>/dev/null || true
}

# The ledgers are newline-separated policy slugs. Keep the normal path at the
# same process cost as before, but compact a ledger once it grows past 64 KiB.
# Compaction removes duplicate slugs without dropping an older policy, so the
# session-level dedupe contract remains intact while a noisy writer cannot make
# every later awk invocation scan an unbounded duplicate set. Both compaction
# and append take the same lock: replacing a ledger inode while another hook
# appends to the old inode would otherwise lose the new slug.
POLICY_LEDGER_COMPACT_THRESHOLD=65536
POLICY_LEDGER_LOCK_WAIT_ATTEMPTS=200
POLICY_LEDGER_LOCK_WAIT_SECONDS=2
POLICY_LEDGER_LOCK_STALE_SECONDS=30

policy_ledger_lock_is_stale() {
  local lock_dir="$1" mtime="" now="" age=""
  if stat -c '%Y' "$lock_dir" >/dev/null 2>&1; then
    mtime="$(stat -c '%Y' "$lock_dir" 2>/dev/null || true)"
  elif stat -f '%m' "$lock_dir" >/dev/null 2>&1; then
    mtime="$(stat -f '%m' "$lock_dir" 2>/dev/null || true)"
  else
    return 1
  fi
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s 2>/dev/null || true)"
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  age=$((now - mtime))
  [ "$age" -ge "$POLICY_LEDGER_LOCK_STALE_SECONDS" ]
}

acquire_policy_ledger_lock() {
  local ledger="$1" lock_dir="${1}.lock" stale_dir="" attempt=0 stale_checked=0
  local deadline=$((SECONDS + POLICY_LEDGER_LOCK_WAIT_SECONDS))
  while [ "$attempt" -lt "$POLICY_LEDGER_LOCK_WAIT_ATTEMPTS" ] \
    && [ "$SECONDS" -lt "$deadline" ]; do
    if mkdir "$lock_dir" 2>/dev/null; then
      if printf '%s\n' "$$" > "$lock_dir/pid" 2>/dev/null; then
        return 0
      fi
      rm -f "$lock_dir/pid" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null || true
      return 1
    fi

    # A fresh directory may not have its pid file yet. Preserve it through the
    # grace period and retry. Once a lock is older than the bounded critical
    # section, rename it away before reclaiming it so a new owner cannot be
    # deleted after the stale check.
    if [ "$stale_checked" -eq 0 ]; then
      stale_checked=1
      if policy_ledger_lock_is_stale "$lock_dir"; then
        stale_dir="${lock_dir}.stale.$$.$attempt"
        if mv "$lock_dir" "$stale_dir" 2>/dev/null; then
          rm -f "$stale_dir/pid" 2>/dev/null || true
          rmdir "$stale_dir" 2>/dev/null || true
          attempt=$((attempt + 1))
          continue
        fi
      fi
    fi
    sleep 0.01
    attempt=$((attempt + 1))
  done
  return 1
}

release_policy_ledger_lock() {
  local ledger="$1" lock_dir="${1}.lock" owner=""
  IFS= read -r owner < "$lock_dir/pid" 2>/dev/null || true
  [ "$owner" = "$$" ] || return 0
  rm -f "$lock_dir/pid" 2>/dev/null || true
  rmdir "$lock_dir" 2>/dev/null || true
}

# record_slugs <ledger> <newline-separated-slugs> — append a batch to the
# cadence ledger while holding its lock once.
record_slugs() {
  local ledger="$1" slugs="$2"
  [ -n "$slugs" ] || return 0
  if ! acquire_policy_ledger_lock "$ledger"; then
    printf 'inject-policy-on-trigger: could not lock policy ledger %s; slug was not recorded.\n' "$ledger" >&2
    return 0
  fi
  if ! printf '%s' "$slugs" >> "$ledger" 2>/dev/null; then
    printf 'inject-policy-on-trigger: could not append slug to policy ledger %s.\n' "$ledger" >&2
  fi
  release_policy_ledger_lock "$ledger"
}

# record_slug <slug> <inject> — record a one-off diagnostic in the ledger
# selected by its cadence.
record_slug() {
  local ledger slug_line
  if [ "${2:-once}" = "always" ]; then
    ledger="$TURN_FILE"
  else
    ledger="$DEDUPE_FILE"
  fi
  slug_line="$1"$'\n'
  record_slugs "$ledger" "$slug_line"
}

# Record a batch of evaluator rows with one lock and append per ledger. The
# evaluator already returns unique policy slugs in its established order.
record_match_rows() {
  local rows="$1" row slug scope path enf rule kind injv ws spec stale exempt rel tkey score
  local once_slugs="" always_slugs=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    # Tab is IFS whitespace: split on a non-blank separator so empty fields
    # do not shift `injv` (a shifted row was filed in the per-turn ledger).
    IFS=$'\x1f' read -r slug scope path enf rule kind injv ws spec stale exempt rel tkey score <<< "${row//$'\t'/$'\x1f'}"
    [ -n "$slug" ] || continue
    if [ "$injv" = "always" ]; then
      always_slugs+="$slug"$'\n'
    else
      once_slugs+="$slug"$'\n'
    fi
  done <<< "$rows"
  [ -z "$once_slugs" ] || record_slugs "$DEDUPE_FILE" "$once_slugs"
  [ -z "$always_slugs" ] || record_slugs "$TURN_FILE" "$always_slugs"
}

# Record what the final reminder delivered (see SEEN SET in the header).
#   - a row shown in full (binding rule or Rule section heading), a soft or
#     unset row listed, an `always` row listed: its cadence ledger;
#   - a HARD row with score 1 or more listed as a one-line summary whose
#     full text could still be shown later (body or Rule section within
#     HARD_MAX): the seen set under its trigger key. A body that can never
#     print in full, or a score-0 row (only common words), is recorded in
#     the session ledger instead, so the footer can name it as delivered;
#   - a row the output ceiling cut from the reminder: nothing. It was never
#     delivered, so it stays eligible and rotates into the next call once the
#     delivered rows have moved to the footer.
# Rows are MATCHES in emit order, so a row's position is its batch body-size
# index. When the reminder carries no policy line at all (a last-resort
# fallback) nothing is recorded, so the set stays eligible for the next event.
record_emitted_match_rows() {
  local rows="$1" output="$2" row slug scope path enf rule kind injv ws spec stale exempt rel tkey score
  local delivered="" seen="" row_index=0 size rule_size now
  case "$output" in
    *$'\n> Policy `'*) ;;
    *) return 0 ;;
  esac
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    row_index=$((row_index + 1))
    IFS=$'\x1f' read -r slug scope path enf rule kind injv ws spec stale exempt rel tkey score <<< "${row//$'\t'/$'\x1f'}"
    [ -n "$slug" ] || continue
    case "$output" in
      *$'\n> Policy `'"$slug"'` '*) ;;
      *)
        # Cut by the output ceiling: never delivered, not recorded, eligible
        # for the next call.
        continue
        ;;
    esac
    if [ "$HARD_FULL" != "0" ] && [ "$enf" = "hard" ] && [ "$injv" != "always" ] \
       && [ "$ws" != "malformed" ] && [ -n "$path" ] && [ -r "$path" ]; then
      case "$output" in
        *$'\n> Policy `'"$slug"'` (HARD — binding rule from `'*) ;;
        *$'\n> Policy `'"$slug"'` (HARD — Rule section from `'*) ;;
        *)
          if [ "$POLICY_BODY_BATCH_MODE" -eq 1 ]; then
            size="${POLICY_BODY_SIZES[$row_index]:-0}"
            rule_size="${POLICY_RULE_SIZES[$row_index]:-0}"
          else
            policy_value_bytes "$(policy_body "$path")"
            size="$POLICY_VALUE_BYTES"
            policy_value_bytes "$(policy_rule_body "$path")"
            rule_size="$POLICY_VALUE_BYTES"
          fi
          case "$score" in ''|*[!0-9]*) score=0 ;; esac
          if [ "$score" -ge 1 ] && { { [ "$size" -gt 0 ] && [ "$size" -le "$HARD_MAX" ]; } \
            || { [ "$rule_size" -gt 0 ] && [ "$rule_size" -le "$HARD_MAX" ]; }; }; then
            # Listed as its summary line by the full-text budget or the
            # output ceiling, although its text fits on its own: seen set,
            # so the same trigger does not list it again inside the window
            # and a new trigger or the window's end can show it in full.
            # A score-0 row (only common words) falls through to the session
            # ledger instead: the seen set also holds score-0 rows the
            # generic cap parked unseen, and the footer must name only rows
            # that were delivered, so a delivered score-0 row is recorded
            # where the footer can tell it apart.
            seen+="$slug"$'\t'"$tkey"$'\n'
            continue
          fi
          ;;
      esac
    fi
    delivered+="$row"$'\n'
  done <<< "$rows"
  [ -z "$delivered" ] || record_match_rows "$delivered"
  if [ -n "$seen" ]; then
    now="$(date +%s)"
    seen="$(printf '%s' "$seen" | awk -F '\t' -v now="$now" 'NF { print $1 "\t" now "\t" $2 }')"
    record_slugs "$SEEN_FILE" "$seen"$'\n'
  fi
}

# filter_seen_matches — drop `once` rows whose slug was delivered for the
# same trigger key within SEEN_TTL seconds (summary line, ceiling cut, or
# parked). One awk pass; a missing or empty seen file costs nothing. The
# valid HARD rows it drops that were delivered earlier are collected in
# SEEN_HARD_SLUGS for the "Already shown this session" footer.
SEEN_HARD_SLUGS=""
filter_seen_matches() {
  [ -s "$SEEN_FILE" ] && [ -n "$MATCHES" ] || return 0
  local now filtered row slug scope path enf rule kind injv ws spec stale exempt rel tkey score
  now="$(date +%s)"
  if filtered="$(awk -F '\t' -v now="$now" -v ttl="$SEEN_TTL" '
      FNR == NR {
        if (NF >= 2 && $2 ~ /^[0-9]+$/ && $2 <= now && now - $2 < ttl) recent[$1 "\t" $3] = 1
        next
      }
      $0 == "" { next }
      $7 != "always" && (($1 "\t" $13) in recent) { print "\037" $0; next }
      { print }
    ' "$SEEN_FILE" - <<< "$MATCHES")"; then
    MATCHES=""
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      case "$row" in
        $'\037'*)
          row="${row#$'\037'}"
          IFS=$'\x1f' read -r slug scope path enf rule kind injv ws spec stale exempt rel tkey score <<< "${row//$'\t'/$'\x1f'}"
          # Only a delivered row may reach the footer. A valid HARD row is
          # never parked by the generic cap, so its seen entry can only come
          # from an emitted summary line.
          if [ "$enf" = "hard" ] && [ "$ws" != "malformed" ]; then
            SEEN_HARD_SLUGS+="$slug"$'\n'
          fi
          ;;
        *) MATCHES+="$row"$'\n' ;;
      esac
    done <<< "$filtered"
  fi
}

# Invalid worker-policy configuration is advisory, but keep one diagnostic per
# reason in the existing per-session ledger so repeated hook events stay quiet.
worker_policy_diagnostic() {
  local marker="__worker-policy-dir-diagnostic-${1}"
  if grep -Fxq "$marker" "$DEDUPE_FILE" 2>/dev/null; then
    return 0
  fi
  record_slug "$marker" once
  printf 'inject-policy-on-trigger: ignored HQ_POLICY_WORKER_DIR (%s).\n' "$2" >&2
}

policy_file_bytes() {
  local LC_ALL=C line="" bytes=0 terminated=0
  while :; do
    line=""
    if IFS= read -r line; then
      terminated=1
    else
      terminated=0
    fi
    bytes=$((bytes + ${#line} + terminated))
    if [ "$bytes" -gt 131072 ]; then
      bytes=131073
      break
    fi
    [ "$terminated" -eq 1 ] || break
  done < "$1" 2>/dev/null || true
  printf '%s' "$bytes"
}

# Store the byte length in POLICY_VALUE_BYTES without spawning a counting
# utility. Bash counts characters under a multibyte locale, so keep this
# function's locale local and byte-oriented.
policy_value_bytes() {
  local LC_ALL=C
  POLICY_VALUE_BYTES=${#1}
}

policy_bytes_bucket() {
  local bytes="$1"
  case "$bytes" in
    ''|*[!0-9]*) bytes=0 ;;
  esac
  if [ "$bytes" -lt 16384 ]; then
    printf '<16K'
  elif [ "$bytes" -lt 65536 ]; then
    printf '16-64K'
  elif [ "$bytes" -lt 131072 ]; then
    printf '64-128K'
  else
    printf '>128K'
  fi
}

compact_policy_ledger() {
  local ledger="$1" bytes="$2" temporary=""
  case "$bytes" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$bytes" -gt "$POLICY_LEDGER_COMPACT_THRESHOLD" ] || return 0
  [ -f "$ledger" ] || return 0
  acquire_policy_ledger_lock "$ledger" || return 0
  temporary="$(mktemp "${ledger}.compact.XXXXXX" 2>/dev/null || true)"
  if [ -z "$temporary" ]; then
    release_policy_ledger_lock "$ledger"
    return 0
  fi
  if awk '!seen[$0]++' "$ledger" > "$temporary" 2>/dev/null; then
    mv -f "$temporary" "$ledger" 2>/dev/null || rm -f "$temporary" 2>/dev/null || true
  else
    rm -f "$temporary" 2>/dev/null || true
  fi
  release_policy_ledger_lock "$ledger"
}

# c015 already gives the hook-timeout journal a per-session metadata file.
# Append the current policy-input sizes there so a subsequent timeout warning
# carries the context that was observed by this hook. The master hook resets
# this metadata file at the start of each event, so the append remains bounded
# to the current dispatch and does not become a second unbounded ledger.
record_policy_trigger_sizes() {
  local journal_file metadata_file journal_dir temporary
  journal_file="$JOURNAL_FILE"
  [ -n "$journal_file" ] || return 0
  metadata_file="${journal_file}.meta"
  journal_dir="${journal_file%/*}"
  [ -d "$journal_dir" ] || mkdir -p "$journal_dir" 2>/dev/null || return 0
  if [ ! -f "$metadata_file" ]; then
    temporary="$(mktemp "${metadata_file}.XXXXXX" 2>/dev/null || true)"
    if [ -n "$temporary" ]; then
      if printf 'bash_env_set=unset\ntiming_precision=ms\n' > "$temporary" 2>/dev/null; then
        mv -f "$temporary" "$metadata_file" 2>/dev/null || rm -f "$temporary" 2>/dev/null || true
      else
        rm -f "$temporary" 2>/dev/null || true
      fi
    fi
  fi
  [ -f "$metadata_file" ] || return 0
  printf 'policy_trigger_script=inject-policy-on-trigger.sh\npolicy_trigger_event=%s\nledger_bytes_bucket=%s\nfacts_bytes_bucket=%s\n' \
    "$EVENT" "$LEDGER_BYTES_BUCKET" "$FACTS_BYTES_BUCKET" >> "$metadata_file" 2>/dev/null || true
}

FACTS_FILE=""
INTENT_FACTS_FILE=""
OUTPUT_FACTS_FILE=""
FACT_PAIR_FILE=""
# Set by resolve_policy_fact_bridge; defined here so the EXIT trap can read it.
POLICY_FACT_BRIDGE_OUT=""
POLICY_BODY_TMP_DIR=""
POLICY_ARG_INLINE_LIMIT=65536

cleanup_policy_fact_files() {
  [ -z "$STDIN_FILE" ] || rm -f "$STDIN_FILE" 2>/dev/null || true
  [ -z "$FACTS_FILE" ] || rm -f "$FACTS_FILE" 2>/dev/null || true
  [ -z "$INTENT_FACTS_FILE" ] || rm -f "$INTENT_FACTS_FILE" 2>/dev/null || true
  [ -z "$OUTPUT_FACTS_FILE" ] || rm -f "$OUTPUT_FACTS_FILE" 2>/dev/null || true
  [ -z "$FACT_PAIR_FILE" ] || rm -f "$FACT_PAIR_FILE" 2>/dev/null || true
  [ -z "$POLICY_BODY_TMP_DIR" ] || rm -rf "$POLICY_BODY_TMP_DIR" 2>/dev/null || true
  [ -z "$POLICY_FACT_BRIDGE_OUT" ] || rm -f "$POLICY_FACT_BRIDGE_OUT" "$POLICY_FACT_BRIDGE_OUT.fault" 2>/dev/null || true
}

trap cleanup_policy_fact_files EXIT

prepare_policy_trigger_input() {
  local temporary=""
  [ "${#STDIN_JSON}" -gt "$POLICY_TRIGGER_INPUT_FILE_LIMIT" ] || return 0
  [ -n "$STDIN_FILE" ] && return 0
  [ -n "$FACTS_TMP_DIR" ] || FACTS_TMP_DIR="$HQ_ROOT/workspace/orchestrator/hook-state"
  [ -d "$FACTS_TMP_DIR" ] || return 0
  temporary="$(mktemp "$FACTS_TMP_DIR/.policy-trigger-input.XXXXXX" 2>/dev/null || true)"
  [ -n "$temporary" ] || return 0
  if printf '%s' "$STDIN_JSON" > "$temporary" 2>/dev/null; then
    STDIN_FILE="$temporary"
  else
    rm -f "$temporary" 2>/dev/null || true
  fi
}

# core/scripts/derive-trigger-facts.sh is a forwarder: it execs
# `hq core derive-trigger-facts`, which boots Node. On the operator's Mac that
# boot is about 229 MB RSS, and the policy injector pays it once or twice for
# EVERY tool call (HQ-HOOK-COST-001). The implementation the CLI runs on this
# path is itself a shell script shipped inside the CLI package, so at hook time
# the Node boot buys nothing: same program, same ABI, one interpreter more.
#
# Resolve that companion from the `hq` entry on PATH with shell builtins and run
# it directly. The resolved path is memoised in the per-machine hook-state dir
# keyed by the `hq` entry it came from, so a session resolves it once instead of
# per event. Any doubt — no `hq` on PATH, companion or awk helper unreadable,
# recorded key stale — falls through to the forwarder, so the worst case is
# exactly today's behaviour and never a missing fact set.
POLICY_FACT_HELPER=""
POLICY_FACT_HELPER_RESOLVED=0
# Same floor the forwarder enforces via lib/hq-cli-floor.sh. Keep the two in step.
POLICY_FACT_HELPER_CLI_FLOOR="5.342.5"

# policy_fact_helper_npm_shim_entry <hq-bin> — when <hq-bin> is the shell shim
# npm writes for a global bin on Windows (cmd-shim), print the package entry it
# execs, or nothing. On Windows the global layout is <prefix>/hq (sh shim),
# <prefix>/hq.cmd, <prefix>/hq.ps1 and <prefix>/node_modules/@indigoai-us/hq-cli,
# and the shim is a regular file, so the symlink walk below finds nothing.
# Accept the shim only when its first lines exec this package's dist/index.js
# under its own directory, so a lookalike `hq` script keeps the forwarder.
# Builtins only, bounded read: this runs on the hook fast path.
policy_fact_helper_npm_shim_entry() {
  local bin="$1" prefix="" entry="" line="" lines=0
  [ -f "$bin" ] && [ ! -L "$bin" ] || return 0
  prefix="${bin%/*}"
  [ "$prefix" != "$bin" ] || return 0
  entry="$prefix/node_modules/@indigoai-us/hq-cli/dist/index.js"
  [ -r "$entry" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    lines=$((lines + 1))
    [ "$lines" -le 40 ] || break
    case "$line" in
      *'"$basedir/node_modules/@indigoai-us/hq-cli/dist/index.js"'*)
        printf '%s\n' "$entry"
        return 0
        ;;
    esac
  done < "$bin"
  return 0
}

# policy_fact_helper_from_bin <hq-bin> — print the companion path for an `hq`
# entry, or nothing. readlink is not a builtin and macOS readlink has no -f, so
# walk the link chain one bounded step at a time.
policy_fact_helper_from_bin() {
  local bin="$1" target="" dir="" hops=0 candidate="" shim_entry=""
  while [ -L "$bin" ] && [ "$hops" -lt 10 ]; do
    target="$(readlink "$bin" 2>/dev/null || true)"
    [ -n "$target" ] || break
    case "$target" in
      /*) bin="$target" ;;
      *) dir="${bin%/*}"; [ "$dir" != "$bin" ] || dir="."; bin="$dir/$target" ;;
    esac
    hops=$((hops + 1))
  done
  # Windows npm installs `hq` as a shell shim, not a symlink. Without this the
  # resolver returned nothing there and every event booted Node through the
  # forwarder, about 2 s per call on Git Bash (windows-hook-parity US-001).
  shim_entry="$(policy_fact_helper_npm_shim_entry "$bin")"
  [ -z "$shim_entry" ] || bin="$shim_entry"
  # .../@indigoai-us/hq-cli/dist/index.js -> .../hq-cli/assets/scaffold/core/scripts
  dir="${bin%/*}"
  [ "$dir" != "$bin" ] || return 0
  candidate="${dir%/dist}/assets/scaffold/core/scripts"
  [ "$candidate" != "$dir" ] || return 0
  [ -r "$candidate/derive-trigger-facts.sh" ] || return 0
  [ -r "$candidate/lib/trigger-fact-text.awk" ] || return 0
  [ -r "$candidate/lib/transcript-tail.sh" ] || return 0
  # The forwarder sources lib/hq-cli-floor.sh and refuses a CLI below
  # POLICY_FACT_HELPER_CLI_FLOOR. Bypassing the forwarder must not drop that
  # check: an older package's companion would answer with an older fact ABI,
  # and a wrong fact set silently changes which policies fire. Read the
  # package version with builtins and fall through to the forwarder — which
  # will refuse and say why — whenever the version is unreadable or below the
  # floor.
  policy_fact_helper_version_ok "${dir%/dist}/package.json" || return 0
  printf '%s\n' "$candidate/derive-trigger-facts.sh"
}

# policy_fact_helper_cli_version <package.json> — print the version string of
# the @indigoai-us/hq-cli package manifest, or nothing. Builtins only: this runs
# on the hook fast path and must not spawn.
policy_fact_helper_cli_version() {
  local manifest="$1" line="" rest="" name_seen=0 version=""
  [ -r "$manifest" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *'"name"'*'@indigoai-us/hq-cli'*) name_seen=1 ;;
    esac
    case "$line" in
      *'"version"'*)
        if [ -z "$version" ]; then
          rest="${line#*\"version\"}"
          rest="${rest#*:}"
          rest="${rest#*\"}"
          version="${rest%%\"*}"
        fi
        ;;
    esac
  done < "$manifest"
  [ "$name_seen" = "1" ] || return 1
  [ -n "$version" ] || return 1
  printf '%s\n' "$version"
}

# policy_fact_helper_version_ok <package.json> — true when the package version
# is at or above the floor. Numeric per-component compare, prerelease suffix
# dropped, so 5.342.5-rc.1 is treated as 5.342.5 exactly as a floor check that
# only cares about the fact ABI should.
policy_fact_helper_version_ok() {
  local version="" have="" want="" index=0 left=0 right=0
  version="$(policy_fact_helper_cli_version "$1")" || return 1
  version="${version%%-*}"
  version="${version%%+*}"
  local -a have_parts=() want_parts=()
  IFS=. read -r -a have_parts <<< "$version"
  IFS=. read -r -a want_parts <<< "$POLICY_FACT_HELPER_CLI_FLOOR"
  for index in 0 1 2; do
    have="${have_parts[$index]:-0}"
    want="${want_parts[$index]:-0}"
    case "$have" in ''|*[!0-9]*) return 1 ;; esac
    case "$want" in ''|*[!0-9]*) return 1 ;; esac
    left=$((10#$have))
    right=$((10#$want))
    [ "$left" -eq "$right" ] || { [ "$left" -gt "$right" ] && return 0 || return 1; }
  done
  return 0
}

# policy_forwarder_is_release_shipped <forwarder> — true when the tree's
# derive-trigger-facts.sh is the release forwarder whose whole job is to exec
# the CLI. A tree that carries a different script there (a test harness, a local
# patch) means something deliberately stands in that position, and running the
# packaged companion instead would ignore it. Builtins only, bounded read.
policy_forwarder_is_release_shipped() {
  local forwarder="$1" line="" lines=0
  [ -r "$forwarder" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    lines=$((lines + 1))
    [ "$lines" -le 12 ] || break
    case "$line" in
      '# FORWARDER'*) return 0 ;;
    esac
  done < "$forwarder"
  return 1
}

resolve_policy_fact_helper() {
  local hq_bin="" cache="" cached_key="" cached_path=""
  [ "$POLICY_FACT_HELPER_RESOLVED" = "1" ] && return 0
  POLICY_FACT_HELPER_RESOLVED=1
  [ -z "${HQ_POLICY_FACT_HELPER_DISABLE:-}" ] || return 0
  policy_forwarder_is_release_shipped "$HELPERS/derive-trigger-facts.sh" || return 0
  hq_bin="$(command -v hq 2>/dev/null || true)"
  [ -n "$hq_bin" ] || return 0
  if [ -n "$FACTS_TMP_DIR" ] && [ -d "$FACTS_TMP_DIR" ]; then
    cache="$FACTS_TMP_DIR/fact-helper-path"
  fi
  # The recorded key is the `command -v hq` path, which does not change when an
  # upgrade retargets a stable `hq` symlink at a new package. Without a second
  # condition the memo would keep pointing at the old package's companion for as
  # long as it stayed readable, which would answer with an older fact ABI and
  # silently change which policies fire — and would also outlive the version
  # floor, since the floor is checked at resolution time. `-nt` is a shell
  # builtin test that spawns nothing and follows the link, so a retargeted
  # symlink or a reinstalled package makes the memo stale and the hook resolves
  # again. Equal timestamps or clock skew resolve again too, which is the safe
  # direction.
  if [ -n "$cache" ] && [ -r "$cache" ] && [ "$cache" -nt "$hq_bin" ]; then
    # Both lines in one pass: two separate redirects would each read line 1.
    { IFS= read -r cached_key; IFS= read -r cached_path; } < "$cache" 2>/dev/null || true
    # A Windows npm shim is a regular file, so `-nt "$hq_bin"` above sees the
    # shim, not the package. Check the package manifest too, so a package
    # replaced under an unchanged shim resolves again and meets the floor.
    if [ "$cached_key" = "$hq_bin" ] && [ -n "$cached_path" ] && [ -r "$cached_path" ] \
      && [ "$cache" -nt "${cached_path%/assets/scaffold/core/scripts/derive-trigger-facts.sh}/package.json" ]; then
      POLICY_FACT_HELPER="$cached_path"
      return 0
    fi
  fi
  POLICY_FACT_HELPER="$(policy_fact_helper_from_bin "$hq_bin")"
  if [ -n "$cache" ]; then
    printf '%s\n%s\n' "$hq_bin" "$POLICY_FACT_HELPER" > "$cache" 2>/dev/null || true
  fi
  return 0
}

# hq-hook engine bridge for the fact helper (windows-hook-parity US-008).
# master-hook.sh resolves the bridge plan once per event and exports it as
# HQ_HOOK_BRIDGE_PLAN ("<id><TAB><shadow|on>" lines) with the engine path in
# HQ_HOOK_BRIDGE_BIN. When the plan names derive-trigger-facts, the helper runs
# through `hq-hook bridge` (flag hook-engine-port-derive-trigger-facts): shadow
# returns the shell helper's output and logs a comparison, on returns the
# native port's output. Builtins only, so a disabled bridge starts nothing.
# The kill switch is checked here as well as in master-hook and the engine.
#
# The bridge's stdout goes to POLICY_FACT_BRIDGE_OUT and is printed only when
# the exit code is an answer. In shadow mode (and on an `on` fallback) the
# engine returns the shell helper's own stdout and exit code, so a fault code
# can come with partial output; discarding it before the shell helper runs
# again keeps the facts from being duplicated. After a fault the marker file
# POLICY_FACT_BRIDGE_OUT.fault keeps the bridge off for the rest of the event,
# including calls made from $(...) subshells.
#
# resolve_policy_fact_bridge runs once in the hook's own shell, before the
# first helper call, so the output path is known to the EXIT cleanup.
POLICY_FACT_BRIDGE_MODE=""
POLICY_FACT_BRIDGE_RESOLVED=0
resolve_policy_fact_bridge() {
  local line="" mode=""
  [ "$POLICY_FACT_BRIDGE_RESOLVED" = "1" ] && return 0
  POLICY_FACT_BRIDGE_RESOLVED=1
  case "${HQ_HOOK_ENGINE:-}" in
    [Oo][Ff][Ff]) return 0 ;;
  esac
  [ ! -e "${HOME:-}/.hq/hook-engine.off" ] || return 0
  [ -n "${HQ_HOOK_BRIDGE_PLAN:-}" ] || return 0
  [ -n "${HQ_HOOK_BRIDGE_BIN:-}" ] && [ -f "$HQ_HOOK_BRIDGE_BIN" ] && [ -x "$HQ_HOOK_BRIDGE_BIN" ] || return 0
  [ -n "$FACTS_TMP_DIR" ] && [ -d "$FACTS_TMP_DIR" ] || return 0
  # A payload large enough to need STDIN_FILE can produce facts over the
  # engine's 64 KiB capture limit; that is a fault and a third derivation.
  [ -z "$STDIN_FILE" ] || return 0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [ "${line%%$'\t'*}" = "derive-trigger-facts" ] || continue
    mode="${line#*$'\t'}"
    case "$mode" in
      shadow|on) POLICY_FACT_BRIDGE_MODE="$mode" ;;
    esac
    break
  done <<< "$HQ_HOOK_BRIDGE_PLAN"
  [ -z "$POLICY_FACT_BRIDGE_MODE" ] || POLICY_FACT_BRIDGE_OUT="$FACTS_TMP_DIR/.policy-trigger-bridge.$$.${RANDOM}"
  return 0
}

# run_derive_trigger_facts_bridge <helper> <event> <with-intent 0|1> — the
# helper call through the engine, stdout to POLICY_FACT_BRIDGE_OUT. The inner
# timeout stays under the injector's 60 s registry timeout so a hung helper is
# killed by the engine (and the shell helper gets a turn) before master-hook
# kills the injector.
run_derive_trigger_facts_bridge() {
  local helper="$1" event="$2" with_intent="$3"
  local -a helper_args=("$event")
  [ "$with_intent" != "1" ] || helper_args+=(--with-assistant-intent)
  printf '%s' "$STDIN_JSON" | HQ_ROOT="$HQ_ROOT" CLAUDE_PROJECT_DIR="$HQ_ROOT" "$HQ_HOOK_BRIDGE_BIN" bridge derive-trigger-facts \
    --mode "$POLICY_FACT_BRIDGE_MODE" --event "$event" --timeout 20 --script "$helper" \
    -- "${helper_args[@]}" > "$POLICY_FACT_BRIDGE_OUT"
}

run_derive_trigger_facts() {
  local event="$1" with_intent="${2:-0}" helper="" helper_status=0
  resolve_policy_fact_helper
  helper="${POLICY_FACT_HELPER:-$HELPERS/derive-trigger-facts.sh}"
  resolve_policy_fact_bridge
  # The capture file must be writable first: a failed redirect would read as
  # the helper's own exit 1 and leave the event with no facts.
  if [ -n "$POLICY_FACT_BRIDGE_OUT" ] && [ ! -e "$POLICY_FACT_BRIDGE_OUT.fault" ] \
    && { : > "$POLICY_FACT_BRIDGE_OUT"; } 2>/dev/null; then
    local bridge_output="" bridge_fault=0
    if run_derive_trigger_facts_bridge "$helper" "$event" "$with_intent"; then
      helper_status=0
    else
      helper_status=$?
    fi
    # 70 (engine fault), 101 (panic), 124 (timeout), 126 and 127 (not
    # runnable) and any signal mean there is no usable result, whether the
    # engine or the helper inside it failed: drop the captured output and run
    # the shell helper below as if the bridge were off. The helper may run
    # twice then, but its facts are printed once. Any other code (the helper
    # answers 0 or 1) passes through with its output, as on the shell path.
    case "$helper_status" in
      70|101|124|126|127) bridge_fault=1 ;;
      *) [ "$helper_status" -lt 128 ] || bridge_fault=1 ;;
    esac
    if [ "$bridge_fault" -eq 0 ]; then
      IFS= read -r -d '' bridge_output < "$POLICY_FACT_BRIDGE_OUT" || true
      printf '%s' "$bridge_output"
      return "$helper_status"
    fi
    : > "$POLICY_FACT_BRIDGE_OUT.fault" 2>/dev/null || true
    helper_status=0
  fi
  # The companion derives HQ_ROOT from its own location, which inside the CLI
  # package is not an HQ root. The forwarder passes --hq-root for the same
  # reason; here the env carries it.
  if [ -n "$STDIN_FILE" ]; then
    if [ "$with_intent" = "1" ]; then
      if HQ_ROOT="$HQ_ROOT" CLAUDE_PROJECT_DIR="$HQ_ROOT" bash "$helper" "$event" --with-assistant-intent < "$STDIN_FILE"; then
        :
      else
        helper_status=$?
      fi
    else
      if HQ_ROOT="$HQ_ROOT" CLAUDE_PROJECT_DIR="$HQ_ROOT" bash "$helper" "$event" < "$STDIN_FILE"; then
        :
      else
        helper_status=$?
      fi
    fi
  elif [ "$with_intent" = "1" ]; then
    if printf '%s' "$STDIN_JSON" | HQ_ROOT="$HQ_ROOT" CLAUDE_PROJECT_DIR="$HQ_ROOT" bash "$helper" "$event" --with-assistant-intent; then
      :
    else
      helper_status=$?
    fi
  else
    if printf '%s' "$STDIN_JSON" | HQ_ROOT="$HQ_ROOT" CLAUDE_PROJECT_DIR="$HQ_ROOT" bash "$helper" "$event"; then
      :
    else
      helper_status=$?
    fi
  fi
  return "$helper_status"
}

# policy_output_structured_facts — print the non-literal facts a PostToolUse
# tool output establishes (secret, apikey, completed), using the same shared
# awk library as the fact helper. shared_branch is left out on purpose: the
# word "main" appears in almost any output, and the command facts already
# carry shared_branch from the command text and the checked-out branch.
policy_output_structured_facts() {
  local lib="$HELPERS/lib/trigger-fact-text.awk"
  [ -n "$JQ" ] && [ -r "$lib" ] || return 0
  {
    if [ -n "$STDIN_FILE" ]; then
      "$JQ" -r 'if .tool_response == null then "" elif (.tool_response|type) == "string" then .tool_response else (.tool_response|tostring) end' < "$STDIN_FILE"
    else
      printf '%s' "$STDIN_JSON" | "$JQ" -r 'if .tool_response == null then "" elif (.tool_response|type) == "string" then .tool_response else (.tool_response|tostring) end'
    fi
  } 2>/dev/null | awk -v mode=derived -v branch="" -f "$lib" 2>/dev/null \
    | while IFS= read -r structured_fact; do
        [ "$structured_fact" = "shared_branch" ] || printf '%s ' "$structured_fact"
      done
  return 0
}

spill_policy_facts() {
  local value="$1" label="$2" temporary=""
  [ "${#value}" -gt "$POLICY_ARG_INLINE_LIMIT" ] || return 0
  [ -n "$FACTS_TMP_DIR" ] || return 0
  [ -d "$FACTS_TMP_DIR" ] || return 0
  temporary="$(mktemp "$FACTS_TMP_DIR/.policy-trigger-$label.XXXXXX" 2>/dev/null || true)"
  [ -n "$temporary" ] || return 0
  if printf '%s\n' "$value" > "$temporary"; then
    case "$label" in
      facts) FACTS_FILE="$temporary" ;;
      intent-facts) INTENT_FACTS_FILE="$temporary" ;;
      output-facts) OUTPUT_FACTS_FILE="$temporary" ;;
    esac
  else
    rm -f "$temporary" 2>/dev/null || true
  fi
}
# Bash-native membership: a `printf "$MATCHES" | grep -q` pipe races under
# `set -o pipefail` — grep -q closes the pipe on first hit, printf takes SIGPIPE
# (141), and the pipeline fails the script before any reminder is emitted. The
# tab is the field delimiter, so match on "<slug><TAB>".
pending_has() { case "$MATCHES" in *"$1"$'\t'*) return 0 ;; *) return 1 ;; esac; }

# Valid HARD rows that matched this event again after an earlier delivery in
# full (kind `shown` from the evaluator). Never emitted as lines; named in the
# "Already shown this session" footer. Newline-separated slugs.
SHOWN_AGAIN_SLUGS=""
add_match() {
  # add_match <slug> <scope> <abs_path> <enforcement> <rule> [reactive|baseline|shown] [once|always] [ok|malformed] [specificity] [staleness] [exempt 0|1] [specific|direct|generic] [trigger-key] [score]
  # Back-compat: add_match <slug> <rule> → scope=core path= enf=unset
  local slug="$1" scope rule path enf kind injv ws spec stale exempt rel tkey score
  if [ "$#" -ge 5 ]; then
    scope="$2"; path="$3"; enf="$4"; rule="$5"
    kind="${6:-reactive}"
    injv="${7:-once}"
    ws="${8:-ok}"
    spec="${9:-0}"
    stale="${10:-0}"
    exempt="${11:-0}"
    rel="${12:-generic}"
    tkey="${13:-}"
    score="${14:-0}"
  else
    scope="core"; path=""; enf="unset"; rule="${2:-}"; kind="reactive"; injv="once"; ws="ok"; spec=0; stale=0; exempt=0; rel="generic"; tkey=""; score=0
  fi
  case "$spec" in ''|*[!0-9]*) spec=0 ;; esac
  case "$stale" in ''|*[!0-9]*) stale=0 ;; esac
  case "$score" in ''|*[!0-9]*) score=0 ;; esac
  if [ "$kind" = "shown" ]; then
    [ -n "$slug" ] || return 0
    case "$enf" in hard) ;; *) return 0 ;; esac
    [ "$ws" != "malformed" ] || return 0
    case $'\n'"$SHOWN_AGAIN_SLUGS" in *$'\n'"$slug"$'\n'*) return 0 ;; esac
    SHOWN_AGAIN_SLUGS+="$slug"$'\n'
    return 0
  fi
  [ "$exempt" = "1" ] || exempt=0
  # Relevance: `direct` rows matched identifiers in the action itself (the
  # command or tool input); `specific` rows are direct rows that matched on
  # two or more identifiers or on a rare one (see RARE_TOKEN_MAX); `generic`
  # rows matched on an unconditional or negation-only trigger, on tool output
  # words, or on assistant intent.
  case "$rel" in specific|direct) ;; *) rel="generic" ;; esac
  # The trigger key names what matched. The seen set compares it so a policy
  # can return inside its window when a different trigger fires it.
  tkey="${tkey//$'\t'/ }"
  tkey="${tkey//$'\n'/ }"
  [ -n "$slug" ] || return 0
  [ "$injv" = "always" ] || injv="once"
  already "$slug" "$injv" && return 0
  pending_has "$slug" && return 0
  [ -n "$enf" ] || enf="unset"
  [ "$kind" = "baseline" ] || kind="reactive"
  [ "$ws" = "malformed" ] || ws="ok"
  # Tabs inside rule would break the field layout — collapse them.
  rule="${rule//$'\t'/ }"
  MATCHES="${MATCHES}${slug}	${scope}	${path}	${enf}	${rule}	${kind}	${injv}	${ws}	${spec}	${stale}	${exempt}	${rel}	${tkey}	${score}
"
}

# ── (A) Frontmatter when:/on: evaluation ──────────────────────────────────
if [ -n "$JQ" ] && [ -f "$HELPERS/eval-trigger.sh" ] && [ -f "$HELPERS/derive-trigger-facts.sh" ]; then
  # Bash 3.2's command-substitution reader consumes a pipe one byte at a time
  # for this helper. Large tool commands therefore spend the entire adapter
  # deadline moving an already-buffered JSON string through a pipe. Hand the
  # helper a regular file once the payload crosses the inline threshold.
  prepare_policy_trigger_input
  # In this shell, not in a $(...) helper call: sets the bridge output path
  # that cleanup_policy_fact_files removes.
  resolve_policy_fact_bridge
  # AssistantIntent channel: AI-message-only facts, available where there is a
  # transcript look-back (PreToolUse + UserPromptSubmit). Policies with
  # `on: [AssistantIntent]` are evaluated against THIS set, not the event facts.
  INTENT_FACTS=""; INTENT_MODE=0; OUTPUT_FACTS=""
  if [ "$EVENT" = "PreToolUse" ] || [ "$EVENT" = "UserPromptSubmit" ]; then
    INTENT_MODE=1
    # Derive both fact channels from one payload parse and one helper launch.
    # The two records are deliberately newline-delimited: fact sets are
    # space-separated tokens, and the helper normalizes all text-derived
    # newlines before returning. Read the records from a file rather than using
    # `${pair#*newline}`; Bash's shortest-prefix matcher becomes quadratic on a
    # 200 KB first line and can consume the entire adapter deadline.
    FACT_PAIR_FILE="$(mktemp "$FACTS_TMP_DIR/.policy-trigger-pair.XXXXXX" 2>/dev/null || true)"
    if [ -n "$FACT_PAIR_FILE" ]; then
      run_derive_trigger_facts "$EVENT" 1 > "$FACT_PAIR_FILE" || true
      FACTS=""
      INTENT_FACTS=""
      pair_lines=0
      while IFS= read -r pair_line; do
        if [ "$pair_lines" -eq 0 ]; then
          FACTS="$pair_line"
          pair_lines=1
        else
          INTENT_FACTS="$pair_line"
          pair_lines=2
          break
        fi
      done < "$FACT_PAIR_FILE"
      if [ "$pair_lines" -lt 2 ]; then
        INTENT_FACTS="$(run_derive_trigger_facts AssistantIntent)" || true
      fi
    else
      FACTS="$(run_derive_trigger_facts "$EVENT")" || true
      INTENT_FACTS="$(run_derive_trigger_facts AssistantIntent)" || true
    fi
  else
    DERIVE_EVENT_OK=0
    if FACTS="$(run_derive_trigger_facts "$EVENT")"; then
      DERIVE_EVENT_OK=1
    else
      :
    fi
    if [ "$EVENT" = "PostToolUse" ] && [ "$DERIVE_EVENT_OK" = "1" ]; then
      # The PostToolUse payload retains tool_input.command. Include those
      # command facts as well as output facts so omitted-on policies that only
      # match a pre-call command still reach a delivering event. Drop
      # run_in_background because that host-provided marker is PreToolUse-only.
      COMMAND_FACTS="$(run_derive_trigger_facts PreToolUse)" || true
      COMMAND_FACTS=" ${COMMAND_FACTS} "
      COMMAND_FACTS="${COMMAND_FACTS// run_in_background / }"
      # Relevance: the ACTION is the command, not whatever text it printed.
      # Every word of a `cat`/`ls`/`gh` result used to become a fact, so a
      # plain file read matched dozens of unrelated policies keyed on words
      # the file merely contained (slack, deploy, feedback, done, ...). The
      # primary PostToolUse fact set is now the command facts plus the
      # structured facts the output alone can establish (a leaked credential
      # -> secret/apikey, a finished merge or deploy -> completed). The full
      # output-word set is kept only for policies that listen on PostToolUse
      # WITHOUT PreToolUse, which are written to key on what a tool printed.
      OUTPUT_FACTS="$FACTS $COMMAND_FACTS"
      FACTS="$COMMAND_FACTS $(policy_output_structured_facts)"
    fi
  fi

  # Keep large fact sets out of awk -v. Derived facts are ASCII tokens, so the
  # Bash lengths are byte lengths here and avoid adding wc subprocesses to the
  # fact derivation hot path. The ledger byte counts replace the two old cat
  # reads that previously materialized the whole ledgers in shell variables.
  spill_policy_facts "$FACTS" facts
  spill_policy_facts "$INTENT_FACTS" intent-facts
  spill_policy_facts "$OUTPUT_FACTS" output-facts
  FACTS_INLINE="$FACTS"
  INTENT_FACTS_INLINE="$INTENT_FACTS"
  OUTPUT_FACTS_INLINE="$OUTPUT_FACTS"
  [ -z "$FACTS_FILE" ] || FACTS_INLINE=""
  [ -z "$INTENT_FACTS_FILE" ] || INTENT_FACTS_INLINE=""
  [ -z "$OUTPUT_FACTS_FILE" ] || OUTPUT_FACTS_INLINE=""
  FACTS_BYTES=$((${#FACTS} + ${#INTENT_FACTS} + ${#OUTPUT_FACTS}))
  DEDUPE_BYTES="$(policy_file_bytes "$DEDUPE_FILE")"
  TURN_BYTES="$(policy_file_bytes "$TURN_FILE")"
  LEDGER_BYTES=$((DEDUPE_BYTES + TURN_BYTES))
  LEDGER_BYTES_BUCKET="$(policy_bytes_bucket "$LEDGER_BYTES")"
  FACTS_BYTES_BUCKET="$(policy_bytes_bucket "$FACTS_BYTES")"
  record_policy_trigger_sizes
  compact_policy_ledger "$DEDUPE_FILE" "$DEDUPE_BYTES"
  compact_policy_ledger "$TURN_FILE" "$TURN_BYTES"

  # Policies whose `on:` includes SessionStart form an always-injected per-session
  # BASELINE: they are injected on the FIRST qualifying event of a session (the
  # SessionStart event itself, or — if that was missed or lost to resume/
  # compaction — the first prompt or Bash command), gated by their `when:`
  # (`when: always` matches everywhere) and the per-session dedup ledger so each
  # fires at most once. There is no separate digest to dedup against; this hook is
  # the sole policy-surfacing path.
  # personal/policies is read DIRECTLY (not via the old reindex symlink mirror
  # into core/policies): personal is now the sole read source for the personal
  # overlay. Both core (shipped) and personal surface — no override semantics.
  #
  # ORDER IS LOAD-BEARING (US-003): both match paths downstream are
  # first-match-wins on the policy id, so DIRS order IS the precedence order.
  # Worker policies extend the existing precedence: worker > company > repo >
  # personal > core. A worker policy sharing an id with another source wins.
  DIRS=()
  # Company-scope precedence (highest first), US-004 / US-406:
  #   HQ_POLICY_COMPANY env override  (caller outside companies/<slug>)
  #   > cwd companies/<slug>
  #   > session-meta company_slug     (HQ-root orchestration sessions — so the
  #                                    active tenant's guardrails still load in
  #                                    the sessions most likely to touch infra)
  # EXACTLY ONE branch ever sets co_scope, so the company policy dir is appended
  # AT MOST ONCE even when cwd and session meta agree — the dedupe is structural,
  # not a filter. Fail-open: any resolution miss leaves co_scope empty and the
  # behaviour identical to today's unresolved-company path.
  co_scope=""
  co_scopes=()
  co_scope_source=""
  if [ -n "${HQ_POLICY_COMPANY:-}" ]; then
    co_scope="$HQ_POLICY_COMPANY"
    co_scope_source=override
  else
    case "$CWD" in
      *companies/*) co_scope="$(printf '%s' "$CWD" | sed -nE 's#.*companies/([^/]+).*#\1#p')"; co_scope_source=cwd ;;
    esac
    if [ -n "${SESSION_ID:-}" ]; then
      # Read THIS session's own meta.yaml directly, keyed off the session id in
      # the hook payload. Do not shell out to hq-session.sh get: it resolves the
      # session from this process's environment, which on a hook path is the
      # host's, not necessarily the one that fired the event.
      # awk idiom lifted verbatim from master-hook.sh:119 so both paths resolve
      # the company identically. READ ONLY: master-hook.sh bootstraps meta.yaml;
      # a second writer here would race.
      META="$HQ_ROOT/workspace/sessions/$SESSION_ID/meta.yaml"
      if [ -z "$co_scope" ]; then
        [ -f "$META" ] && co_scope="$(awk '$1 == "company_slug:" { sub(/^[^:]+:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$META")"
      fi
      if [ -n "$co_scope" ]; then
        co_scope_source=session
        # A capability is authoritative for the session lock set. The helper
        # keeps old capability files singleton and gates the set through hq-flags.
        if [ -f "$HQ_ROOT/core/scripts/lib/session-scope-capability.sh" ]; then
          . "$HQ_ROOT/core/scripts/lib/session-scope-capability.sh"
          while IFS= read -r locked_company; do
            [ -n "$locked_company" ] && co_scopes+=("$locked_company")
          done < <(session_scope_read_companies "$HQ_ROOT" "$SESSION_ID" 2>/dev/null || true)
        fi
      fi
    fi
  fi
  # HQ_POLICY_WORKER_DIR may name a worker profile directory or its policies
  # child. Relative paths are rooted at HQ_ROOT. Reject lexical traversal
  # before resolving symlinks, then check the physical directory remains under
  # the physical HQ root. Company worker trees are admitted only for the one
  # company resolved above.
  if [ -n "${HQ_POLICY_WORKER_DIR:-}" ]; then
    worker_root="$(cd "$HQ_ROOT" 2>/dev/null && pwd -P || true)"
    worker_configured="$HQ_POLICY_WORKER_DIR"
    while [ "$worker_configured" != "/" ] && [ "${worker_configured%/}" != "$worker_configured" ]; do
      worker_configured="${worker_configured%/}"
    done
    case "/$worker_configured/" in
      *"/../"*)
        worker_policy_diagnostic "path-dotdot" "the configured path contains a '..' segment"
        worker_configured=""
        ;;
    esac
    if [ -n "$worker_configured" ] && [ -n "$worker_root" ]; then
      case "$worker_configured" in
        /*) worker_candidate="$worker_configured" ;;
        *) worker_candidate="$worker_root/$worker_configured" ;;
      esac
      if [ ! -d "$worker_candidate" ]; then
        worker_policy_diagnostic "missing-directory" "the configured directory does not exist"
      else
        worker_candidate_resolved="$(cd "$worker_candidate" 2>/dev/null && pwd -P || true)"
        case "$worker_candidate_resolved" in
          "$worker_root"/*)
            case "$worker_candidate_resolved" in
              */policies) worker_policy_candidate="$worker_candidate_resolved" ;;
              *) worker_policy_candidate="$worker_candidate_resolved/policies" ;;
            esac
            if [ ! -d "$worker_policy_candidate" ]; then
              worker_policy_diagnostic "missing-policy-directory" "the worker's policies directory does not exist"
            else
              worker_policy_dir="$(cd "$worker_policy_candidate" 2>/dev/null && pwd -P || true)"
              case "$worker_policy_dir" in
                "$worker_root"/*)
                  worker_relative="${worker_policy_dir#"$worker_root"/}"
                  worker_company=""
                  worker_tail=""
                  case "$worker_relative" in
                    personal/workers/*)
                      worker_tail="${worker_relative#personal/workers/}"
                      ;;
                    companies/*/workers/*)
                      worker_company="$(printf '%s' "$worker_relative" | sed -nE 's#^companies/([^/]+)/workers/.*#\1#p')"
                      worker_tail="$(printf '%s' "$worker_relative" | sed -nE 's#^companies/[^/]+/workers/(.*)#\1#p')"
                      ;;
                    *)
                      worker_policy_diagnostic "not-worker-profile" "the directory is not inside personal/workers or companies/<company>/workers"
                      worker_tail=""
                      ;;
                  esac
                  if [ -n "$worker_tail" ]; then
                    case "$worker_tail" in
                      */policies) worker_id="${worker_tail%/policies}" ;;
                      *) worker_id="$worker_tail" ;;
                    esac
                    case "$worker_id" in
                      ''|.|..|*/*)
                        worker_policy_diagnostic "invalid-worker-profile" "the worker profile path is malformed"
                        ;;
                      *)
                        if [ -n "$worker_company" ] && [ "$co_scope" != "$worker_company" ] && [[ ! " ${co_scopes[*]} " =~ [[:space:]]${worker_company}[[:space:]] ]]; then
                          worker_policy_diagnostic "company-scope-mismatch-$worker_company" "company worker policies do not match the session company"
                        else
                          DIRS+=("$worker_policy_dir")
                        fi
                        ;;
                    esac
                  fi
                  ;;
                *)
                  worker_policy_diagnostic "outside-hq-root" "the resolved directory is outside HQ_ROOT"
                  ;;
              esac
            fi
            ;;
          *)
            worker_policy_diagnostic "outside-hq-root" "the resolved directory is outside HQ_ROOT"
            ;;
        esac
      fi
    fi
  fi

  if [ "$co_scope_source" = session ] && [ "${#co_scopes[@]}" -gt 0 ]; then
    for locked_company in "${co_scopes[@]}"; do
      [ -d "$HQ_ROOT/companies/$locked_company" ] && DIRS+=("$HQ_ROOT/companies/$locked_company/policies")
    done
  elif [ -n "$co_scope" ]; then
    DIRS+=("$HQ_ROOT/companies/$co_scope/policies")
  fi
  case "$CWD" in
    *repos/public/*|*repos/private/*)
      rscope="$(printf '%s' "$CWD" | sed -nE 's#.*repos/(public|private)/.*#\1#p')"
      rname="$(printf '%s' "$CWD" | sed -nE 's#.*repos/[^/]+/([^/]+).*#\1#p')"
      [ -n "$rscope" ] && [ -n "$rname" ] && DIRS+=("$HQ_ROOT/repos/$rscope/$rname/.claude/policies") ;;
  esac
  DIRS+=("$HQ_ROOT/personal/policies" "$HQ_ROOT/core/policies")

  # Repos this event touches, for the optional `repos:` policy field. A policy
  # that lists repos loads only when one of them is here; a policy without the
  # field is unaffected. Sources, all read without forking:
  #   - any repos/<public|private>/<name> path in the cwd or the command
  #     (covers `git -C <dir>` and file operands),
  #   - a workspace/worktrees/<name>/ path in the cwd or the command (HQ
  #     worktrees are grouped by repo name),
  #   - `-R owner/name` or `--repo owner/name` in the command (gh).
  # The awk evaluator lower-cases the set before matching.
  EVENT_REPOS=" "
  policy_collect_event_repos() {
    local src="$1" re
    for re in 'repos/(public|private)/([A-Za-z0-9._-]+)' 'workspace/worktrees/()([A-Za-z0-9._-]+)/'; do
      local rest="$src"
      while [[ $rest =~ $re ]]; do
        EVENT_REPOS="$EVENT_REPOS${BASH_REMATCH[2]} "
        rest="${rest#*"${BASH_REMATCH[0]}"}"
      done
    done
  }
  policy_collect_event_repos "$CWD"
  policy_collect_event_repos "$ARG"
  policy_repo_flag_re='(^|[[:space:]])(-R|--repo)([[:space:]]+|=)["'"'"']?[A-Za-z0-9._-]+/([A-Za-z0-9._-]+)'
  policy_repo_flag_rest="$ARG"
  while [[ $policy_repo_flag_rest =~ $policy_repo_flag_re ]]; do
    EVENT_REPOS="$EVENT_REPOS${BASH_REMATCH[4]} "
    policy_repo_flag_rest="${policy_repo_flag_rest#*"${BASH_REMATCH[0]}"}"
  done

  # Collect in-scope policy files (skip generated/template/readme AND sync
  # conflict/drift copies). A real policy filename is a kebab-case slug —
  # `<slug>.md`, never containing a space or a sync-conflict marker. Cross-
  # machine sync (iCloud/Dropbox/Syncthing/hq-sync) mints conflict copies like
  # `foo 2.md`, `foo (conflicted copy).md`, `foo.sync-conflict-<host>.md`. A
  # single runaway can leave TENS OF THOUSANDS of these (observed live: 23k
  # copies in one core/policies, one slug alone at 1000+). Because this hook
  # awks EVERY matched file on every prompt and every Bash call, that bloat
  # pushed the scan past the 60s hook timeout, so UserPromptSubmit output was
  # discarded and every request stalled a full minute. Skipping conflict/drift
  # copies keeps the scan proportional to the real policy set. It is also safe:
  # no legitimate policy slug contains a space, so this can never drop a real
  # policy — a same-slug conflict copy is a stale duplicate of one still
  # collected under its canonical name.
  POLICY_FILES=()
  for dir in "${DIRS[@]}"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.md; do
      [ -f "$f" ] || continue
      # `${f##*/}`, NOT `$(basename "$f")`. The command substitution forked a
      # process per candidate file: on a 3,419-policy install that was 3,419
      # forks on EVERY Bash tool call and EVERY prompt, and it dominated the
      # hook's wall time (18.4s in the loop vs 176ms to actually read and parse
      # the same files). Bash suffix removal is the exact equivalent for every
      # path a glob can produce, at zero processes. Regression test:
      # core/scripts/tests/inject-policy-no-per-file-fork.test.sh.
      case "${f##*/}" in
        example-policy.md|README.md) continue ;;
        *" "*) continue ;;              # any space => sync conflict/drift copy
        *.sync-conflict-*.md) continue ;;  # Syncthing-style conflict copy
        *.conflict-*) continue ;;          # HQ Sync conflict twin (<slug>.md.conflict-<ts>-<id>.md)
      esac
      POLICY_FILES+=("$f")
    done
  done

  # Parsed policy frontmatter is stable across hook fires far more often than
  # the event facts or session ledger. Cache that parsed representation in the
  # established per-machine hook-state directory, never beside policies. The
  # cache key is the ordered scope list and the invalidation fingerprint is a
  # SHA-256 digest of each selected regular file's pathname, inode, size,
  # nanosecond mtime, and nanosecond ctime. ctime is the important field: an
  # ordinary user can restore mtime after a content edit, but cannot restore
  # the kernel-maintained ctime. This catches content-only same-size edits,
  # additions, removals, replacement, and precedence-order changes without
  # trusting directory mtimes, which do not change for an in-place child-file
  # edit on many filesystems.
  #
  # SHA-256 and a metadata-capable stat are intentionally cache prerequisites
  # on the fast path: on a host without either we take the existing uncached
  # path rather than accept a weaker stale signal. One stat process accepts
  # every policy path, so metadata validation is thousands of stat syscalls but
  # not thousands of shell forks. -L is required because the scanner's -f test
  # and awk both follow a policy symlink: fingerprint the target, not the link,
  # so a target edit changes ctime and a retarget changes the reported inode.
  #
  # Both stat dialects are tried before any content hashing. GNU stat answers
  # -c; BSD stat (macOS) answers -f, and its %Fm/%Fc give mtime and ctime with
  # the same sub-second resolution GNU's %y/%z carry, so the BSD record is not
  # a weaker signal. Hashing every policy file's CONTENT is the last resort for
  # a host with neither dialect. On the operator's Mac that last resort was the
  # live path: it read all of core, personal and company policy text on every
  # tool call (HQ-HOOK-COST-001).
  POLICY_HASH_MODE=""
  if command -v sha256sum >/dev/null 2>&1; then
    POLICY_HASH_MODE="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    POLICY_HASH_MODE="shasum"
  fi
  POLICY_FINGERPRINT_MODE="auto"
  policy_hash() {
    case "$POLICY_HASH_MODE" in
      sha256sum) sha256sum "$@" 2>/dev/null ;;
      shasum) shasum -a 256 "$@" 2>/dev/null ;;
      *) return 1 ;;
    esac
  }
  policy_fingerprint() {
    local manifest digest
    # One complete metadata pass per stat dialect, GNU first. A dialect that
    # does not understand the format string exits non-zero and prints nothing,
    # and `set -o pipefail` carries that failure out of the pipe, so each
    # branch is selected by the host's own stat rather than by a separate
    # capability-probe process.
    digest="$(stat -Lc '%n\t%i\t%s\t%y\t%z' "$@" 2>/dev/null | policy_hash)" || {
      digest="$(stat -Lf '%N\t%i\t%z\t%Fm\t%Fc' "$@" 2>/dev/null | policy_hash)" || {
        manifest="$(policy_hash "$@")" || return 1
        digest="$(printf '%s\n' "$manifest" | policy_hash)" || return 1
      }
    }
    printf '%s\n' "${digest%% *}"
    return 0
  }

  # The cached records use ASCII FS (0x1c), outside valid policy frontmatter
  # syntax. The writer refuses to publish a cache if it sees this separator in
  # a record, retaining the uncached path instead of risking a lossy decode.
  CACHE_SEP=$'\034'
  CACHE_RECORDS=0
  CACHE_WRITE=0
  CACHE_TMP=""
  CACHE_STATUS=""
  CACHE_FILE=""
  # Bash 3.2 with nounset treats an empty array expansion as unbound even
  # after POLICY_FILES=(). Use the guarded form so a valid empty scope stays empty.
  EVAL_INPUTS=("${POLICY_FILES[@]+"${POLICY_FILES[@]}"}")
  # A `when:` identifier is rare when at most this many in-scope policies key
  # on it. A direct match on one rare identifier, on a file name, path or
  # slash command (`settings.json`, `/prd`), or on two or more identifiers of
  # any kind is `specific`; a match on one common word such as `deploy` or
  # `slack` is not. Part of the evaluation cache key below.
  RARE_TOKEN_MAX="${HQ_POLICY_RARE_TOKEN_MAX:-3}"
  case "$RARE_TOKEN_MAX" in ''|*[!0-9]*) RARE_TOKEN_MAX=3 ;; esac
  # HEAD_WORDS — the first word of each command segment (split on &&, ||, ;,
  # | and newlines), with VAR=value prefixes, wrapper words (`sudo`, `env`,
  # `time`, `nohup`, `exec`, ...), shell keywords and `$(` skipped, a `cd`
  # segment ignored (its operand is a directory), and a leading directory or
  # backslash removed. Builtins only, bounded to the first 4 KB of the command. Part of
  # the relevance score (see RELEVANCE SCORE in the header) and of the
  # evaluation cache key. Empty on prompt events.
  HEAD_WORDS=""
  policy_head_words() {
    local text="${1:0:4096}" seg word
    text="${text//&&/$'\n'}"; text="${text//||/$'\n'}"
    text="${text//;/$'\n'}"; text="${text//|/$'\n'}"
    set -f
    while IFS= read -r seg; do
      for word in $seg; do
        word="${word#\(}"; word="${word#\{}"; word="${word#\\}"
        case "$word" in
          # `cd` ends the segment: its operand is a directory, not a command.
          cd) break ;;
          ''|*=*|sudo|env|time|nohup|exec|command|builtin|then|do|done|else|fi|esac|if|while|until|for|'!'|'$('*) continue ;;
        esac
        word="${word##*/}"
        case "$word" in ''|-*) break ;; esac
        HEAD_WORDS="${HEAD_WORDS:+$HEAD_WORDS }$word"
        break
      done
    done <<< "$text"
    set +f
  }
  case "$EVENT" in PreToolUse|PostToolUse) [ -z "$ARG" ] || policy_head_words "$ARG" ;; esac
  if [ "${#POLICY_FILES[@]}" -gt 0 ] && [ -n "$POLICY_HASH_MODE" ] && [ -n "$POLICY_FINGERPRINT_MODE" ]; then
    POLICY_FINGERPRINT="$(policy_fingerprint "${POLICY_FILES[@]}" 2>/dev/null || true)"
    if [ -n "$POLICY_FINGERPRINT" ]; then
      scope_hash="$(printf '%s\n' "${DIRS[@]}" | policy_hash 2>/dev/null || true)"
      scope_key="${scope_hash%% *}"
      CACHE_DIR="$HQ_ROOT/workspace/orchestrator/hook-state/policy-trigger-cache"
      if [ -n "$scope_key" ]; then
        mkdir -p "$CACHE_DIR" "$CACHE_DIR/eval-v8" "$CACHE_DIR/eval-v10" "$STATS_DIR" 2>/dev/null || true
      fi
      if [ -n "$scope_key" ] && [ -d "$CACHE_DIR" ]; then
        CACHE_FILE="$CACHE_DIR/${scope_key}.cache"
        # The parser cache now stores PostToolUse as the omitted-on default;
        # invalidate v2 records, which baked in PreToolUse. v4 adds the parsed
        # `principals:` field to each record, so v3 records (one field short)
        # are never decoded with the new layout. v6 records carry the summary
        # rule line cut on a word boundary with an ellipsis.
        CACHE_HEADER="hq-policy-cache-v7${CACHE_SEP}${HQ_POLICY_TOOL_EVENTS:-default}${CACHE_SEP}${POLICY_FINGERPRINT}"
        cache_header=""
        if [ -r "$CACHE_FILE" ]; then
          IFS= read -r cache_header < "$CACHE_FILE" || true
        fi
        if [ "$cache_header" = "$CACHE_HEADER" ]; then
          CACHE_RECORDS=1
          EVAL_INPUTS=("$CACHE_FILE")
        else
          # mktemp creates a unique, private inode. The completed file below is
          # renamed over CACHE_FILE atomically, so a concurrent reader sees the
          # old complete cache or this complete one, never a partial write.
          CACHE_TMP="$(mktemp "$CACHE_DIR/.${scope_key}.tmp.XXXXXX" 2>/dev/null || true)"
          if [ -n "$CACHE_TMP" ] && printf '%s\n' "$CACHE_HEADER" > "$CACHE_TMP"; then
            CACHE_STATUS="${CACHE_TMP}.status"
            CACHE_WRITE=1
          else
            CACHE_TMP=""
          fi
        fi
      fi
    fi
  fi

  # SINGLE-PASS evaluator. One awk process parses every policy's frontmatter and
  # evaluates its `when:` boolean expression INTERNALLY — the eval-trigger.sh
  # recursive-descent grammar + safety gate are ported verbatim into evalexpr()
  # below, with identical semantics (0=TRUE, 1=FALSE, 2=empty/unsafe→fail-open).
  # It applies the per-session dedup itself and prints `slug<TAB>rule` per match.
  # This replaces a fork-per-policy loop
  # (~3 procs × N policies, one of them a `bash eval-trigger.sh` spawn) with a
  # SINGLE awk invocation. The hook runs on every Bash PreToolUse and every
  # prompt, so that fork count was the dominant latency. eval-trigger.sh itself
  # stays the spec'd standalone evaluator (tests + CLI); the hot path no longer
  # shells out to it.
  # The parsed-record cache still evaluates every policy for a new event. A
  # second small cache remembers that evaluation for the current session's
  # exact facts and ledger state. It has 64 fixed slots per scope, selected by
  # the first byte of the session digest modulo 64, rather than creating an unbounded
  # file per session. The full session digest remains in the header, so a slot
  # collision is a cache miss and reevaluation, never a cross-session hit.
  # Writers publish with rename; a concurrent reader sees a complete old entry
  # or a complete replacement, and never needs an unsafe deletion sweep.
  EVAL_CACHE_HIT=0
  EVAL_CACHE_WRITE=0
  EVAL_CACHE_TMP=""
  EVAL_CACHE_STATUS=""
  EVAL_CACHE_FILE=""
  EVAL_CACHE_DIR=""
  # Staleness inputs (see staleness() in the evaluator): today's UTC date and
  # the durable retrieval ledger written by record-policy-retrieval.sh.
  # HQ_INJECT_PERSONAL_SOFT=1 re-enables personal soft policies (default 0, D4).
  STALE_TODAY="${HQ_POLICY_STALE_TODAY:-$(date -u +%Y-%m-%d 2>/dev/null || true)}"
  STALE_LEDGER="$HQ_ROOT/workspace/orchestrator/policy-retrieval-ledger.jsonl"
  [ -r "$STALE_LEDGER" ] || STALE_LEDGER=""
  INJECT_PERSONAL_SOFT="${HQ_INJECT_PERSONAL_SOFT:-0}"
  # Session principal for the optional `principals:` policy audience field.
  # Builtins and file tests only: this runs on every hook event. Order:
  #   1. HQ_SESSION_PRINCIPAL=human|agent|bot (any other value is ignored)
  #   2. agent: fleet identity present (mirrors hq-cli fleetIdentityPresent and
  #      resolve-company.sh is_fleet_identity, including HQ_AGENT_ROOT_PREFIX)
  #   3. bot: HQ_BOT_AGENT_UID (personal bot turn) or HQ_MACHINE_CREDS_FILE
  #      (company bot turn)
  #   4. human
  SESSION_PRINCIPAL=""
  case "${HQ_SESSION_PRINCIPAL:-}" in
    human|agent|bot) SESSION_PRINCIPAL="$HQ_SESSION_PRINCIPAL" ;;
  esac
  if [ -z "$SESSION_PRINCIPAL" ]; then
    principal_agent_root="${HQ_AGENT_ROOT_PREFIX:-}"
    if [ -n "${HQ_AGENT_WORKDIR:-}" ] || [ -n "${HQ_AGENT_COMPANY_DIR:-}" ] \
      || [ -n "${HQ_AGENT_IDENTITY_FILE:-}" ] \
      || [ -f /etc/hq-agent/identity.json ] || [ -f /etc/hq-agent/machine-creds.json ] \
      || [ -f /var/lib/hq-agent/machine-creds.json ] \
      || { [ -n "$principal_agent_root" ] && [ -f "${principal_agent_root%/}/var/lib/hq-agent/identity.json" ]; } \
      || { [ -z "$principal_agent_root" ] && [ -f /var/lib/hq-agent/identity.json ]; }; then
      SESSION_PRINCIPAL="agent"
    elif [ -n "${HQ_BOT_AGENT_UID:-}" ] || [ -n "${HQ_MACHINE_CREDS_FILE:-}" ]; then
      SESSION_PRINCIPAL="bot"
    else
      SESSION_PRINCIPAL="human"
    fi
  fi
  if [ -n "$CACHE_FILE" ] && [ "$CACHE_WRITE" != "1" ]; then
    eval_session_key=""
    eval_slot=""
    if [ "$EVENT" = "SessionStart" ]; then
      # SessionStart work repeats in each new session. Share only when every
      # input that can change the evaluator result is identical. The session
      # ledgers remain inputs, so a non-empty or otherwise distinct ledger
      # never reuses another session's answer.
      eval_session_key="sessionstart"
      eval_slot="sessionstart"
    else
      eval_session_hash="$(printf '%s' "${SESSION_ID:-default}" | policy_hash 2>/dev/null || true)"
      eval_session_key="${eval_session_hash%% *}"
      eval_slot="$(printf '%02x' "$((16#${eval_session_key:0:2} % 64))" 2>/dev/null || true)"
    fi
    retrieval_ledger_key="none"
    if [ -n "$STALE_LEDGER" ]; then
      retrieval_ledger_hash="$(policy_hash "$STALE_LEDGER" 2>/dev/null || true)"
      retrieval_ledger_key="${retrieval_ledger_hash%% *}"
    fi
    eval_input_hash="$(
      {
        # SESSION_PRINCIPAL is part of the key: a verdict computed for one
        # principal must never be replayed for another.
        # EVENT_REPOS is part of the key for the same reason: a `repos:`
        # verdict computed in one repo must never be replayed in another.
        printf '%s\034%s\034%s\034%s\034output=%s\034%s\034%s\034%s\034%s\034principal=%s\034rare=%s\034heads=%s\034repos=%s\034' \
          "$EVENT" "$INTENT_MODE" "$FACTS" "$INTENT_FACTS" "$OUTPUT_FACTS" \
          "${HQ_POLICY_TOOL_EVENTS:-}" "$STALE_TODAY" "$INJECT_PERSONAL_SOFT" "$retrieval_ledger_key" \
          "$SESSION_PRINCIPAL" "$RARE_TOKEN_MAX" "$HEAD_WORDS" "$EVENT_REPOS"
        append_policy_ledger "$DEDUPE_FILE"
        printf '\034'
        append_policy_ledger "$TURN_FILE"
        printf '\n'
      } | policy_hash 2>/dev/null || true
    )"
    eval_input_key="${eval_input_hash%% *}"
    if [ -n "$eval_session_key" ] && [ -n "$eval_slot" ] && [ -n "$eval_input_key" ] \
      && { [ -z "$STALE_LEDGER" ] || [ -n "$retrieval_ledger_key" ]; }; then
      # Evaluation entries contain grammar verdicts, unlike the parsed-policy
      # cache above. A parser change can therefore make an otherwise matching
      # v3 entries were produced by a case-sensitive evaluator. Keep parsed
      # records at v1, but namespace evaluation results by evaluator semantics
      # so old verdicts cannot survive case-insensitive trigger matching.
      # v8/v9 rows carry two more fields: relevance class and trigger key.
      # v10 rows carry the relevance score as a 14th field and `shown`
      # rows (matched again after a full delivery) for the footer; the
      # command head words are part of the input key.
      # The `specific` relevance class needs no new version: the rare-token
      # threshold is part of the input key, so older entries never match.
      if [ "$EVENT" = "SessionStart" ]; then
        EVAL_CACHE_DIR="$CACHE_DIR/eval-v8"
      else
        EVAL_CACHE_DIR="$CACHE_DIR/eval-v10"
      fi
      if [ -d "$EVAL_CACHE_DIR" ]; then
        EVAL_CACHE_FILE="$EVAL_CACHE_DIR/${scope_key}.${eval_slot}.eval"
        if [ "$EVENT" = "SessionStart" ]; then
          EVAL_CACHE_HEADER="hq-policy-eval-v8${CACHE_SEP}${POLICY_FINGERPRINT}${CACHE_SEP}${eval_input_key}"
        else
          EVAL_CACHE_HEADER="hq-policy-eval-v10${CACHE_SEP}${POLICY_FINGERPRINT}${CACHE_SEP}${eval_session_key}${CACHE_SEP}${eval_input_key}"
        fi
        eval_cache_header=""
        if [ -r "$EVAL_CACHE_FILE" ]; then
          IFS= read -r eval_cache_header < "$EVAL_CACHE_FILE" || true
        fi
        if [ "$eval_cache_header" = "$EVAL_CACHE_HEADER" ]; then
          EVAL_CACHE_HIT=1
        else
          EVAL_CACHE_TMP="$(mktemp "$EVAL_CACHE_DIR/.${scope_key}.${eval_slot}.eval.tmp.XXXXXX" 2>/dev/null || true)"
          if [ -n "$EVAL_CACHE_TMP" ] && printf '%s\n' "$EVAL_CACHE_HEADER" > "$EVAL_CACHE_TMP"; then
            EVAL_CACHE_STATUS="${EVAL_CACHE_TMP}.status"
            EVAL_CACHE_WRITE=1
          else
            EVAL_CACHE_TMP=""
          fi
        fi
      fi
    fi
  fi
  if [ "${#POLICY_FILES[@]}" -gt 0 ]; then
    policy_evaluator() {
      # The ledgers are read from files with getline. This preserves the
      # newline-safe behavior that motivated the old ENVIRON handoff and also
      # avoids the Linux MAX_ARG_STRLEN limit when a long session has many
      # dedupe entries. Large fact sets are spilled to the same hook-state
      # directory and read through the same file-backed path.
      # Emit: slug<TAB>scope<TAB>abs_path<TAB>enforcement<TAB>rule<TAB>kind.
      # `kind` is consumed only inside this hook before prose emission; the
      # public HQ_POLICY_EMIT=tsv path continues to print five fields below.
      # LC_ALL=C keeps awk byte-oriented, like the other awk passes in this
      # hook. Under a UTF-8 locale BSD awk aborts the whole pass with
      # "towc: multibyte conversion failure" when a string op meets a split
      # code point, and then no policy loads.
      LC_ALL=C awk -v EVENT="$EVENT" -v LEGACY_TOOL_EVENTS="${HQ_POLICY_TOOL_EVENTS:-}" -v INTENT_MODE="$INTENT_MODE" \
          -v EVFACTS="$FACTS_INLINE" -v AIFACTS="$INTENT_FACTS_INLINE" \
          -v EVFACTS_FILE="$FACTS_FILE" -v AIFACTS_FILE="$INTENT_FACTS_FILE" \
          -v OUTFACTS="$OUTPUT_FACTS_INLINE" -v OUTFACTS_FILE="$OUTPUT_FACTS_FILE" \
          -v ALREADY_FILE="$DEDUPE_FILE" -v ALREADY_TURN_FILE="$TURN_FILE" \
          -v CACHE_RECORDS="$CACHE_RECORDS" -v CACHE_WRITE="$CACHE_WRITE" \
          -v CACHE_TMP="$CACHE_TMP" -v CACHE_STATUS="$CACHE_STATUS" \
          -v CSEP="$CACHE_SEP" -v TODAY="$STALE_TODAY" \
          -v RETRIEVAL_LEDGER="$STALE_LEDGER" -v PERSONAL_SOFT="$INJECT_PERSONAL_SOFT" \
          -v PRINCIPAL="$SESSION_PRINCIPAL" -v RARE_MAX="$RARE_TOKEN_MAX" -v HEADWORDS="$HEAD_WORDS" \
          -v EVREPOS="$EVENT_REPOS" '
      # Keep this hot-path parser structurally identical to eval-trigger.sh.
      # In particular, an opening paren needs a closing paren: accepting it
      # here while --check rejects it makes authoring and runtime disagree.
      function skipsp() { while (substr(E, pos, 1) ~ /[ \t]/) pos++ }
      function pOr(  v) {
        v=pAnd(); skipsp()
        while (valid && substr(E,pos,2)=="||") { pos+=2; rhs=pAnd(); v=(v || rhs); skipsp() }
        return v
      }
      function pAnd(  v) {
        v=pNot(); skipsp()
        while (valid && substr(E,pos,2)=="&&") { pos+=2; rhs=pNot(); v=(v && rhs); skipsp() }
        return v
      }
      function pNot(  c) { skipsp(); c=substr(E,pos,1); if(c=="!"){pos++; return (pNot()?0:1)} return pAtom() }
      function pAtom(  v,c) {
        skipsp(); c=substr(E,pos,1)
        if(c=="(") {
          pos++; v=pOr(); skipsp()
          if(substr(E,pos,1)!=")") { valid=0; return 0 }
          pos++; return v
        }
        if(c=="0" || c=="1") { pos++; return (c=="1") ? 1 : 0 }
        valid=0; return 0
      }
      # evalexpr(expr, which) -> 0 TRUE | 1 FALSE | 2 fail-open. which: "ev"|"ai".
      function evalexpr(expr, which,   e,s,out,tok,present,v) {
        e=expr; gsub(/[ \t]/,"",e); if(e=="") return 2            # empty -> fail open
        s=expr; out=""
        while (match(s, "[A-Za-z0-9_./][A-Za-z0-9_./-]*")) {
          tok=substr(s,RSTART,RLENGTH)
          present = (which=="ev") ? (tolower(tok) in evh) : ((which=="out") ? (tolower(tok) in outh) : (tolower(tok) in aih))
          out = out substr(s,1,RSTART-1) (present?"1":"0")
          s = substr(s,RSTART+RLENGTH)
        }
        out = out s
        if (out ~ /[^01&|!() \t]/) return 2                       # unsafe -> malformed
        E=out; pos=1; valid=1
        v=pOr()
        # Trailing garbage is malformed, NOT a shorter true expression. The
        # recursive-descent parser stops at the first token it cannot continue
        # from, so `merge || pull request` used to evaluate as `merge || pull`
        # and silently discard every term after the bare space. Requiring the
        # parse to consume the whole expression turns that into a detected
        # malformation the authoring validator and the linter both name.
        skipsp()
        if (!valid || pos <= length(E)) return 2
        return (v ? 0 : 1)
      }
      function base(p,   n,a,b){ n=split(p,a,"/"); b=a[n]; sub(/\.md$/,"",b); return b }
      function scopeof(p,   n,a,i) {
        n=split(p,a,"/")
        for (i=1; i<=n; i++) {
          if (a[i]=="personal" && a[i+1]=="workers" && a[i+2]!="") return "worker:" a[i+2]
          if (a[i]=="companies" && a[i+2]=="workers" && a[i+3]!="") return "worker:" a[i+3]
        }
        if (p ~ /\/companies\//) return "company"
        if (p ~ /\/repos\//) return "repo"
        if (p ~ /\/personal\//) return "personal"
        return "core"
      }
      # `always` is the documented canonical unconditional fact. A policy that
      # is eligible only through SessionStart and whose expression reduces to
      # TRUE once `always` is substituted is baseline; one with a real event
      # condition is reactive. This deliberately handles `always || token` as
      # baseline too, without making a non-tautological expression baseline.
      function cskipsp() { while (substr(C, cpos, 1) == " ") cpos++ }
      function cOr(   v,w) { v=cAnd(); cskipsp(); while(substr(C,cpos,2)=="||"){cpos+=2; w=cAnd(); if(v==1||w==1)v=1; else if(v==0&&w==0)v=0; else v=2; cskipsp()} return v }
      function cAnd(  v,w) { v=cNot(); cskipsp(); while(substr(C,cpos,2)=="&&"){cpos+=2; w=cNot(); if(v==0||w==0)v=0; else if(v==1&&w==1)v=1; else v=2; cskipsp()} return v }
      function cNot(  v,c) { cskipsp(); c=substr(C,cpos,1); if(c=="!"){cpos++; v=cNot(); return (v==2 ? 2 : (v ? 0 : 1))} return cAtom() }
      function cAtom( v,c) { cskipsp(); c=substr(C,cpos,1); if(c=="("){cpos++; v=cOr(); cskipsp(); if(substr(C,cpos,1)==")")cpos++; return v} cpos++; return (c=="1" ? 1 : (c=="0" ? 0 : 2)) }
      function unconditional(expr,   s,out,tok) {
        s=expr; out=""
        while (match(s, "[A-Za-z0-9_./][A-Za-z0-9_./-]*")) {
          tok=substr(s,RSTART,RLENGTH)
          out=out substr(s,1,RSTART-1) (tolower(tok)=="always" ? "1" : "x")
          s=substr(s,RSTART+RLENGTH)
        }
        out=out s
        if (out ~ /[^01x&|!() ]/) return 0
        C=out; cpos=1
        return (cOr()==1 && substr(C,cpos) ~ /^[ ]*$/)
      }
      function finalize(   onpad,ev_on,ai_on,ss_on,matched,r,sc,en,kind,ij,degraded,ws,cache_rule,evset,chan,rel,tkey,shown) {
        if (whenx=="") return
        if (id=="") id=base(fname)
        # An omitted `on:` defaults to the tool event. The `_omitted_` marker
        # (cached with the record) keeps such a policy keyed on the command:
        # it never opted into matching words in tool output.
        if (onx=="") onx=(LEGACY_TOOL_EVENTS=="legacy" ? "PreToolUse _omitted_" : "PostToolUse _omitted_")
        # On a cache miss, write the parsed record while this same pass has the
        # policy file open. A malformed cache record is never published: the
        # parent only renames the temp file when END writes an "ok" status.
        if (CACHE_WRITE) {
          cache_rule=rule
          gsub(/\t/," ",cache_rule)
          if (index(id,CSEP) || index(fname,CSEP) || index(whenx,CSEP) || index(onx,CSEP) || index(enf,CSEP) || index(injx,CSEP) || index(statx,CSEP) || index(crx,CSEP) || index(tagx,CSEP) || index(cache_rule,CSEP) || index(prx,CSEP) || index(rpx,CSEP)) cache_unsafe=1
          else print id CSEP scopeof(fname) CSEP fname CSEP whenx CSEP onx CSEP enf CSEP injx CSEP statx CSEP crx CSEP rwx CSEP tagx CSEP cache_rule CSEP prx CSEP rpx CSEP "." >> CACHE_TMP
        }
        # Count how many policies key on each `when:` identifier, before any
        # event filter, so rarity reflects the whole in-scope policy set.
        count_tokens(whenx)
        npolicies++
        # `principals:` audience filter. Runs before matching and ranking, so a
        # policy addressed to another principal never takes an output slot.
        # prx holds the normalized valid values; empty means everyone.
        if (prx!="" && index(" " prx " ", " " PRINCIPAL " ")==0) return
        # `repos:` filter. rpx holds the normalized repo names; empty means
        # every repo. The policy loads only when the event touches one of them.
        if (rpx!="" && !repo_in_event(rpx)) return
        onpad=" " onx " "
        ev_on = (index(onpad," " EVENT " ")>0)
        ai_on = (index(onpad," AssistantIntent ")>0)
        # on:[SessionStart] policies are an always-injected per-session BASELINE:
        # eligible on ANY triggering event, not just the SessionStart event, so a
        # session backfills any baseline slug not yet in the ledger on whatever
        # event fires first. Still gated by when: (vs the current event facts) and
        # the per-session dedup ledger, so each fires at most once per session.
        ss_on = (index(onpad," SessionStart ")>0)
        if (!ev_on && !ss_on && !(ai_on && INTENT_MODE)) return
        # `inject: always` (default `once`) picks which ledger governs dedup:
        # the per-turn ledger (re-injects each user turn) vs the per-session
        # ledger (fires at most once for the whole session).
        ij = (injx=="always" ? "always" : "once")
        # A `once` HARD policy already in the session ledger (delivered in
        # full earlier) is still evaluated: when it matches the action again
        # it is reported as a `shown` row for the footer, never as a line.
        shown=0
        if (ij=="always") { if (id in turnalready) return }        # per-turn dedup ledger
        else if (id in already) { if (enf=="hard") shown=1; else return }   # per-session dedup ledger
        if (id in emitted) return                                  # de-dup within this run
        if (statx=="retired") return                               # retired policies never inject (policy-retire.sh)
        # Owner decision D4: personal soft/unset policies are not emitted unless
        # HQ_INJECT_PERSONAL_SOFT=1. Core and company soft policies are unchanged.
        if (PERSONAL_SOFT!="1" && scopeof(fname)=="personal" && enf!="hard" && enf!="gate") return
        matched=0; degraded=0; spec=0; chan=""
        # Output words count only for a policy that explicitly listens on
        # PostToolUse and not PreToolUse: that policy keys on what a tool
        # printed. Every other policy is matched against the action (the
        # command) plus structured output facts.
        evset="ev"
        if (EVENT=="PostToolUse" && index(onpad," PostToolUse ")>0 && index(onpad," PreToolUse ")==0 && index(onpad," _omitted_ ")==0) evset="out"
        if (ev_on || ss_on) { r=evalexpr(whenx,evset); if(r==0) { matched=1; chan=evset; spec=specificity(whenx,evset) } else if(r==2) degraded=1 }
        if (!matched && ai_on && INTENT_MODE) { r=evalexpr(whenx,"ai"); if(r==0) { matched=1; chan="ai"; spec=specificity(whenx,"ai") } else if(r==2) degraded=1 }
        # An expression the grammar cannot parse used to MATCH — a blanket
        # fail-open that made every malformed policy fire on every event and
        # crowd the cap with alphabetical noise, burying the policies that
        # genuinely matched. The promise worth keeping is narrower: a typo must
        # never SUPPRESS A HARD RULE. So a malformed `when:` on an
        # enforcement: hard policy degrades to the once-per-session baseline
        # (deprioritized behind real reactive matches, deduped by the session
        # ledger) instead of re-firing forever, and a malformed soft/unset
        # policy does not inject at all. Both are reported by
        # core/scripts/lint-policy-triggers.sh and blocked at authoring time by
        # validate-policy-frontmatter.sh.
        if (!matched && degraded && enf=="hard") { matched=1 }
        if (matched) {
          emitted[id]=1
          sc=scopeof(fname)
          en=(enf=="" ? "unset" : enf)
          ws=(degraded ? "malformed" : "ok")
          # Policies whose current event is explicitly listed are reactive even
          # if they also carry SessionStart. Conditional SessionStart-only
          # policies are reactive as well: they matched facts from this event.
          # Only the unconditional SessionStart backfill is baseline.
          kind=((degraded || (ss_on && !ev_on && !(ai_on && INTENT_MODE) && unconditional(whenx))) ? "baseline" : "reactive")
          if (shown) { if (degraded || chan!="ev" || spec==0) return; kind="shown" }
          # Relevance to the actual trigger. A row is `direct` only when
          # identifiers in its `when:` are present in the action facts (the
          # command or tool input). Unconditional and negation-only triggers,
          # output-word listeners, and assistant-intent matches are `generic`.
          rel=((!degraded && chan=="ev" && spec>0) ? "direct" : "generic")
          # Trigger key: which channel and which `when:` identifiers fired the
          # row. The per-session seen set uses it to tell a repeat from a new
          # trigger.
          tkey=(degraded ? "malformed" : chan ":" trigger_key(whenx,chan))
          gsub(/\t/," ",rule)
          # Held until END: whether a direct row is `specific` depends on
          # token counts from policies that have not been read yet.
          nrows++
          rowhead[nrows]=id "\t" sc "\t" fname "\t" en "\t" rule "\t" kind "\t" ij "\t" ws "\t" spec "\t" staleness() "\t" stale_exempt(ij)
          rowrel[nrows]=rel; rowspec[nrows]=spec; rowkey[nrows]=tkey; rowsc[nrows]=sc
        }
      }
      # score_row(spec, tkey, scope): the RELEVANCE SCORE of the header. One
      # weight per present identifier, first matching line wins; scope bonus
      # only when the identifier sum is above zero. Malformed and legacy rows
      # never reach this function with a real trigger key.
      function score_row(spec, tkey, sc,   keys,n,i,k,base,w) {
        base=0
        if (tkey=="malformed") return 0
        sub(/^[a-z]*:/,"",tkey)
        n=split(tkey,keys,"+")
        for (i=1; i<=n; i++) {
          k=keys[i]; if (k=="") continue
          if (k ~ /[.\/]/) w=3
          else if (k=="secret" || k=="apikey" || k=="shared_branch" || k=="completed") w=2
          else if (k in headw) w=2
          else if (tokdf[k]<=RARE_MAX) w=2
          else if (tokdf[k]*5 > npolicies) w=0
          else w=1
          base+=w
        }
        # Two or more identifiers, all common, still beat one common word:
        # a HARD rule on `deploy && prod` is not a generic match.
        if (base==0 && spec>=2) base=1
        if (base>0 && (sc=="company" || sc ~ /^worker:/)) base++
        return base
      }
      function count_tokens(expr,   s,tok,tok_lc,seen) {
        s=expr; delete seen
        while (match(s, "[A-Za-z0-9_./][A-Za-z0-9_./-]*")) {
          tok=substr(s,RSTART,RLENGTH); s=substr(s,RSTART+RLENGTH)
          tok_lc=tolower(tok)
          if (tok_lc=="always" || tok_lc=="never" || (tok_lc in seen)) continue
          seen[tok_lc]=1; tokdf[tok_lc]++
        }
      }
      # specific_row(spec, tkey): a direct row that matched two or more
      # identifiers, or one identifier that at most RARE_MAX policies use, or
      # a file name, path or slash command (an identifier with "." or "/").
      function specific_row(spec, tkey,   keys,n,i) {
        if (spec>=2) return 1
        sub(/^[a-z]*:/,"",tkey)
        n=split(tkey,keys,"+")
        for (i=1; i<=n; i++) {
          if (keys[i]=="") continue
          if (keys[i] ~ /[.\/]/ || tokdf[keys[i]]<=RARE_MAX) return 1
        }
        return 0
      }
      # staleness(): integer score, higher = more likely out of date. Used only
      # to order equally specific matches; it never removes a match.
      #   status retired|superseded -> 1000000 (maximum). Retired rows are still
      #                                filtered above, so in practice this ranks
      #                                superseded rules last.
      #   otherwise                  -> base + (retire_when present ? 180 : 0)
      #   base = days since the newest retrieval in the durable ledger
      #          (workspace/orchestrator/policy-retrieval-ledger.jsonl), or, when
      #          never retrieved, days since `created:`. 0 when neither is known,
      #          so undated legacy policies keep their current order.
      function civil(dt,   y,m,dd) {
        if (dt !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) return -1
        y=substr(dt,1,4)+0; m=substr(dt,6,2)+0; dd=substr(dt,9,2)+0
        if (m<=2) { y--; m+=12 }
        return 365*y + int(y/4) - int(y/100) + int(y/400) + int((153*(m-3)+2)/5) + dd
      }
      function staleness(   st,stale_days,t,c) {
        st=statx; gsub(/[^a-z]/,"",st)
        if (st=="retired" || st=="superseded") return 1000000
        stale_days=0
        if (TODAY_D>0) {
          if (id in lastret) { t=civil(lastret[id]); if (t>0 && TODAY_D>t) stale_days=TODAY_D-t }
          else { c=civil(crx); if (c>0 && TODAY_D>c) stale_days=TODAY_D-c }
        }
        return stale_days + (rwx ? 180 : 0)
      }
      # stale_exempt(): 1 keeps the row at its current position. Safety-critical
      # hard rules, gate policies, and inject: always policies are never reordered.
      function stale_exempt(ij,   hay) {
        if (enf=="gate" || ij=="always") return 1
        hay=tolower(whenx " " tagx)
        if (enf=="hard" && hay ~ /credential|secret|destructive|company-isolation|tenant|cross-company/) return 1
        return 0
      }
      function add_principals(v,   n,a,i,t) {
        gsub(/[][,"\047]/," ",v)
        n=split(v,a,/[ \t]+/)
        for (i=1; i<=n; i++) { t=tolower(a[i]); if (t=="human" || t=="agent" || t=="bot") prx=(prx=="" ? t : prx " " t) }
      }
      # repos: [name, owner/name, repos/private/name]: each entry is reduced to
      # its last path segment and lower-cased, so it compares with EVREPOS.
      function add_repos(v,   n,a,i,t) {
        gsub(/[][,"\047]/," ",v)
        n=split(v,a,/[ \t]+/)
        for (i=1; i<=n; i++) {
          t=tolower(a[i]); sub(/\/+$/,"",t); sub(/.*\//,"",t)
          if (t ~ /^[a-z0-9._-]+$/) rpx=(rpx=="" ? t : rpx " " t)
        }
      }
      function repo_in_event(list,   n,a,i) {
        n=split(list,a,/ /)
        for (i=1; i<=n; i++) if (a[i]!="" && index(EVREPOS_LC, " " a[i] " ")) return 1
        return 0
      }
      function reset_file(){ d=0; id=""; whenx=""; onx=""; enf=""; injx=""; statx=""; crx=""; rwx=0; tagx=""; tsec=0; rule=""; rsec=0; rcap=0; prx=""; psec=0; rpx=""; rposec=0 }
      # specificity(expr, which): how many distinct identifiers in the `when:`
      # expression are present in the fact set. A policy keyed on
      # `deploy && vercel && indigo` outranks one keyed on `deploy` alone when
      # both match — it is more specific to this event. Used only for ordering.
      # trigger_key(expr, which): the sorted, distinct `when:` identifiers that
      # are present in the fact set, joined by "+". Empty for an unconditional
      # or negation-only match.
      function trigger_key(expr, which,   s,tok,tok_lc,n,i,j,t,seen,keys,out) {
        s=expr; n=0; delete seen
        while (match(s, "[A-Za-z0-9_./][A-Za-z0-9_./-]*")) {
          tok=substr(s,RSTART,RLENGTH); s=substr(s,RSTART+RLENGTH)
          tok_lc=tolower(tok)
          if (tok_lc=="always" || tok_lc=="never" || (tok_lc in seen)) continue
          seen[tok_lc]=1
          if ((which=="ev") ? (tok_lc in evh) : ((which=="out") ? (tok_lc in outh) : (tok_lc in aih))) keys[++n]=tok_lc
        }
        for (i=2; i<=n; i++) { t=keys[i]; for (j=i-1; j>=1 && keys[j]>t; j--) keys[j+1]=keys[j]; keys[j+1]=t }
        out=""
        for (i=1; i<=n; i++) out=out (i>1 ? "+" : "") keys[i]
        return out
      }
      function specificity(expr, which,   s,tok,tok_lc,n,seen) {
        s=expr; n=0; delete seen
        while (match(s, "[A-Za-z0-9_./][A-Za-z0-9_./-]*")) {
          tok=substr(s,RSTART,RLENGTH); s=substr(s,RSTART+RLENGTH)
          tok_lc=tolower(tok)
          if (tok_lc=="always" || tok_lc=="never") continue
          if (!(tok_lc in seen)) { seen[tok_lc]=1; if ((which=="ev") ? (tok_lc in evh) : ((which=="out") ? (tok_lc in outh) : (tok_lc in aih))) n++ }
        }
        return n
      }
      BEGIN {
        # UTF-8 continuation bytes 0x80-0xBF, used by the byte-safe summary cut.
        UTF8_CONT="\200\201\202\203\204\205\206\207\210\211\212\213\214\215\216\217\220\221\222\223\224\225\226\227\230\231\232\233\234\235\236\237"
        UTF8_CONT=UTF8_CONT "\240\241\242\243\244\245\246\247\250\251\252\253\254\255\256\257\260\261\262\263\264\265\266\267\270\271\272\273\274\275\276\277"
        if (EVFACTS_FILE != "") {
          while ((getline factline < EVFACTS_FILE) > 0) {
            n=split(factline,fa,/[ ,]+/)
            for(i=1;i<=n;i++) if(fa[i]!="") evh[fa[i]]=1
          }
          close(EVFACTS_FILE)
        } else {
          n=split(EVFACTS,fa,/[ ,]+/)
          for(i=1;i<=n;i++) if(fa[i]!="") evh[fa[i]]=1
        }
        if (OUTFACTS_FILE != "") {
          while ((getline outline < OUTFACTS_FILE) > 0) {
            n=split(outline,oa,/[ ,]+/)
            for(i=1;i<=n;i++) if(oa[i]!="") outh[oa[i]]=1
          }
          close(OUTFACTS_FILE)
        } else {
          n=split(OUTFACTS,oa,/[ ,]+/)
          for(i=1;i<=n;i++) if(oa[i]!="") outh[oa[i]]=1
        }
        if (AIFACTS_FILE != "") {
          while ((getline intentline < AIFACTS_FILE) > 0) {
            n=split(intentline,ga,/[ ,]+/)
            for(i=1;i<=n;i++) if(ga[i]!="") aih[ga[i]]=1
          }
          close(AIFACTS_FILE)
        } else {
          n=split(AIFACTS,ga,/[ ,]+/)
          for(i=1;i<=n;i++) if(ga[i]!="") aih[ga[i]]=1
        }
        while ((getline ledgerline < ALREADY_FILE) > 0) if(ledgerline!="") already[ledgerline]=1
        close(ALREADY_FILE)
        while ((getline turnline < ALREADY_TURN_FILE) > 0) if(turnline!="") turnalready[turnline]=1
        close(ALREADY_TURN_FILE)
        TODAY_D=civil(TODAY)
        EVREPOS_LC=" " tolower(EVREPOS) " "
        n=split(HEADWORDS,hw,/[ ,]+/)
        for(i=1;i<=n;i++) if(hw[i]!="") headw[tolower(hw[i])]=1
        if (RETRIEVAL_LEDGER!="") {
          while ((getline rl < RETRIEVAL_LEDGER) > 0) {
            if (match(rl, /"policy":"[^"]*"/)) rp=substr(rl,RSTART+10,RLENGTH-11); else continue
            if (match(rl, /"ts":"[0-9-]*/)) rt=substr(rl,RSTART+6,10); else continue
            if (!(rp in lastret) || rt > lastret[rp]) lastret[rp]=rt
          }
          close(RETRIEVAL_LEDGER)
        }
        reset_file()
      }
      # Cache files have one validated header followed by parsed records. The
      # cache is an optimization only; final matching still runs for current
      # event facts and current session dedupe ledgers.
      CACHE_RECORDS {
        if (FNR==1) next
        n=split($0,cr,CSEP)
        if (n < 15) next
        id=cr[1]; fname=cr[3]; whenx=cr[4]; onx=cr[5]; enf=cr[6]
        injx=cr[7]; statx=cr[8]; crx=cr[9]; rwx=cr[10]; tagx=cr[11]; rule=cr[12]; prx=cr[13]; rpx=cr[14]
        finalize()
        next
      }
      FNR==1 { if (seen) finalize(); reset_file(); seen=1 }
      { fname=FILENAME }
      /^---[ \t]*$/ { if (d<2) { d++; next } }
      d==1 && tsec && /^[^ \t-]/ { tsec=0 }
      d==1 && psec && /^[^ \t-]/ { psec=0 }
      d==1 && rposec && /^[^ \t-]/ { rposec=0 }
      # principals: [human, agent] or a block list. Unknown values are dropped
      # here (the linter rejects them); a list with no valid value applies to
      # everyone, so a typo never hides a policy.
      d==1 && /^principals:/ { s=$0; sub(/^principals:[ \t]*/,"",s); sub(/[ \t]*#.*/,"",s); add_principals(s); psec=(s==""); next }
      d==1 && psec && /^[ \t]*-/ { s=$0; sub(/^[ \t]*-[ \t]*/,"",s); sub(/[ \t]*#.*/,"",s); add_principals(s); next }
      # repos: [vyg] or a block list. Opt-in repo scope; see repo_in_event.
      d==1 && /^repos:/ { s=$0; sub(/^repos:[ \t]*/,"",s); sub(/[ \t]*#.*/,"",s); add_repos(s); rposec=(s==""); next }
      d==1 && rposec && /^[ \t]*-/ { s=$0; sub(/^[ \t]*-[ \t]*/,"",s); sub(/[ \t]*#.*/,"",s); add_repos(s); next }
      d==1 && /^id:/   { s=$0; sub(/^id:[ \t]*/,"",s);   gsub(/^["'"'"']|["'"'"']$/,"",s); id=s; next }
      d==1 && /^status:/ { s=$0; sub(/^status:[ \t]*/,"",s); gsub(/[ \t"]/,"",s); statx=s; next }
      d==1 && /^when:/ { s=$0; sub(/^when:[ \t]*/,"",s); sub(/[ \t]+#.*/,"",s); gsub(/^["'"'"']|["'"'"']$/,"",s); whenx=s; next }
      d==1 && /^on:/   { s=$0; sub(/^on:[ \t]*/,"",s);   gsub(/[][, ]/," ",s); onx=s; next }
      d==1 && /^enforcement:/ {
        s=$0; sub(/^enforcement:[ \t]*/,"",s); sub(/[ \t]+#.*/,"",s)
        gsub(/^["'"'"']|["'"'"']$/,"",s); enf=s; next
      }
      d==1 && /^created:/ { s=$0; sub(/^created:[ \t]*/,"",s); gsub(/[ \t"\047]/,"",s); crx=s; tsec=0; next }
      d==1 && /^retire_when:/ { s=$0; sub(/^retire_when:[ \t]*/,"",s); sub(/[ \t]*#.*/,"",s); if (s!="") rwx=1; tsec=0; next }
      d==1 && /^tags:/ { s=$0; sub(/^tags:[ \t]*/,"",s); gsub(/[][,"\047]/," ",s); tagx=s; tsec=1; next }
      d==1 && tsec && /^[ \t]+-/ { s=$0; sub(/^[ \t]+-[ \t]*/,"",s); gsub(/["\047]/,"",s); tagx=tagx " " s; next }
      d==1 && /^[^ \t]/ { tsec=0 }
      d==1 && /^inject:/ {
        s=$0; sub(/^inject:[ \t]*/,"",s); sub(/[ \t]+#.*/,"",s)
        gsub(/^["'"'"']|["'"'"']$/,"",s); injx=s; next
      }
      d>=2 && /^## Rule[ \t]*$/ { rsec=1; next }
      d>=2 && rsec && /^## / { rsec=0 }
      # The summary cap counts bytes (LC_ALL=C). Back the cut off any UTF-8
      # continuation byte so the kept prefix ends on a whole code point.
      d>=2 && rsec && !rcap && NF {
        line=$0; gsub(/\*\*/,"",line)
        if (length(line)>160) {
          cut=157
          while (cut>0 && index(UTF8_CONT, substr(line,cut+1,1))) cut--
          # Word boundary: back off to the last blank before the cut, then
          # drop trailing blanks and punctuation, so a summary line never
          # ends in a split token. A single 157-byte token keeps the
          # byte-safe cut.
          wb=cut
          while (wb>0 && substr(line,wb,1) !~ /[ \t]/) wb--
          if (wb>0) cut=wb
          while (cut>0 && substr(line,cut,1) ~ /[ \t.,;:]/) cut--
          line=substr(line,1,cut)"..."
        }
        rule=line; rcap=1
      }
      END {
        if (!CACHE_RECORDS && seen) finalize()
        for (i=1; i<=nrows; i++) {
          if (rowrel[i]=="direct" && specific_row(rowspec[i], rowkey[i])) rowrel[i]="specific"
          print rowhead[i] "\t" rowrel[i] "\t" rowkey[i] "\t" score_row(rowspec[i], rowkey[i], rowsc[i])
        }
        if (CACHE_WRITE) print (cache_unsafe ? "unsafe" : "ok") > CACHE_STATUS
      }
      ' "${EVAL_INPUTS[@]}" | {
        # Byte-oriented awk can cut through a multibyte code point. Some iconv
        # implementations still return nonzero after -c repairs the output.
        iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || true
      }
    }
    POLICY_EVALUATION_OK=1
    if [ "$EVAL_CACHE_HIT" = "1" ]; then
      eval_cache_first_line=1
      while IFS=$'\t' read -r slug scope path enf rule kind injv ws spec stale exempt rel tkey score; do
        if [ "$eval_cache_first_line" = "1" ]; then
          eval_cache_first_line=0
          continue
        fi
        add_match "$slug" "$scope" "$path" "$enf" "$rule" "$kind" "$injv" "$ws" "$spec" "$stale" "$exempt" "$rel" "$tkey" "$score"
      done < "$EVAL_CACHE_FILE"
    elif [ "$EVAL_CACHE_WRITE" = "1" ]; then
      EVAL_RESULTS_TMP="${EVAL_CACHE_TMP}.results"
      POLICY_EVALUATION_OK=0
      if policy_evaluator > "$EVAL_RESULTS_TMP"; then
        POLICY_EVALUATION_OK=1
        if cat "$EVAL_RESULTS_TMP" >> "$EVAL_CACHE_TMP" \
          && printf 'ok\n' > "$EVAL_CACHE_STATUS"; then
          :
        else
          POLICY_EVALUATION_OK=0
        fi
      fi
      while IFS=$'\t' read -r slug scope path enf rule kind injv ws spec stale exempt rel tkey score; do
        add_match "$slug" "$scope" "$path" "$enf" "$rule" "$kind" "$injv" "$ws" "$spec" "$stale" "$exempt" "$rel" "$tkey" "$score"
      done < "$EVAL_RESULTS_TMP"
      rm -f "$EVAL_RESULTS_TMP" 2>/dev/null || true
    else
      while IFS=$'\t' read -r slug scope path enf rule kind injv ws spec stale exempt rel tkey score; do
        add_match "$slug" "$scope" "$path" "$enf" "$rule" "$kind" "$injv" "$ws" "$spec" "$stale" "$exempt" "$rel" "$tkey" "$score"
      done < <(policy_evaluator)
    fi
    # The evaluator has completed before the process substitution returns. A
    # failed/unrepresentable cache write is discarded; policy output already
    # came from the original uncached evaluator in that case.
    if [ "$CACHE_WRITE" = "1" ]; then
      cache_status=""
      [ -r "$CACHE_STATUS" ] && IFS= read -r cache_status < "$CACHE_STATUS" || true
      if [ "$cache_status" = "ok" ] && [ "$POLICY_EVALUATION_OK" = "1" ]; then
        mv -f "$CACHE_TMP" "$CACHE_FILE" 2>/dev/null || true
      else
        rm -f "$CACHE_TMP" 2>/dev/null || true
      fi
      rm -f "$CACHE_STATUS" 2>/dev/null || true
    fi
    if [ "$EVAL_CACHE_WRITE" = "1" ]; then
      eval_cache_status=""
      [ -r "$EVAL_CACHE_STATUS" ] && IFS= read -r eval_cache_status < "$EVAL_CACHE_STATUS" || true
      if [ "$eval_cache_status" = "ok" ] && [ "$POLICY_EVALUATION_OK" = "1" ]; then
        mv -f "$EVAL_CACHE_TMP" "$EVAL_CACHE_FILE" 2>/dev/null || true
      else
        rm -f "$EVAL_CACHE_TMP" 2>/dev/null || true
      fi
      rm -f "$EVAL_CACHE_STATUS" 2>/dev/null || true
    fi
  fi
fi

# ── (B) Legacy hardcoded regex map (Bash PreToolUse only) ─────────────────
# Precise command patterns a coarse boolean `when:` token can't express. Only
# Bash rows remain — per the CLI/bash-only scope, this hook no longer fires on
# Edit/Write/MultiEdit, so the former settings/core-path file rows are dropped
# (those cases stay covered mechanically by warn-cross-company-settings.sh and
# protect-core.sh / block-core-writes.sh).
#
# Rows are kept ONLY where path (A) cannot reach the same slug as broadly. The
# former git-checkout-not-a-probe row was removed — the policy now carries
# `when: git && checkout`, so path (A) injects that slug on every `git checkout`
# (a superset of the old `-- .` pattern) and dedup made the legacy row dead.
# The pnpm row STAYS: its `(install|i|add)` aliases are NOT all reachable by the
# policy's `when: install` token (`add` is a different word; `i` is too short to
# tokenize), so it still covers cases path (A) misses. Rule of thumb: drop a
# legacy row only when an equivalent `when:` covers the SAME command surface.
if [ "$EVENT" = "PreToolUse" ] && [ "$TOOL_NAME" = "Bash" ]; then
  if [ -n "$ARG" ]; then
    TAB=$'\t'
    TRIGGERS=$(printf '%s\n' \
      "(^|[[:space:]])find[[:space:]]${TAB}hq-glob-scoped-path${TAB}\`find\` is unrestricted but Glob is hook-blocked. Prefer qmd/Grep over \`find\`; scope \`find\` to a known sub-tree." \
      "(^|[[:space:]])pgrep[[:space:]]${TAB}hq-bash-discipline${TAB}Never hardcode a \`pgrep\`-discovered PID into a follow-up command — re-discover and validate with \`ps\` each invocation." \
      "(^|[[:space:]])git[[:space:]]+filter-repo[[:space:]]${TAB}hq-git-discipline${TAB}\`git filter-repo --path\` is case-sensitive. Run separate passes for case variants (e.g. \`Foo\` and \`foo\`)." \
      "(^|[[:space:]])git[[:space:]]+reflog[[:space:]]+expire[[:space:]]${TAB}hq-git-discipline${TAB}\`git reflog expire --all --expire=now\` permanently destroys stashes too. Stash explicitly first or filter the expire." \
      "IFS=\":\"${TAB}hq-bash-discipline${TAB}\`IFS=\":\" read\` corrupts paths. Use \`IFS=\$'\\''\\\\t'\\''\` or read fields by index instead." \
      "(^|[[:space:]])(npm|yarn|bun|pnpm)[[:space:]]+(install|i|add)[[:space:]]+[^-]${TAB}hq-pnpm-min-release-age-supply-chain${TAB}Supply-chain guard: prefer \`pnpm\` with \`minimum-release-age=1440\` (24h). Raw \`npm/yarn/bun install <pkg>\` is hard-blocked by block-unsafe-package-install.sh.")
    while IFS=$'\t' read -r t_pat t_slug t_rule; do
      [ -z "$t_pat" ] && continue
      if [[ "$ARG" =~ $t_pat ]]; then
        # Legacy rows have no on-disk path; scope=core, enforcement=unset.
        # An exact command pattern is a direct match on the action.
        add_match "$t_slug" "core" "" "unset" "$t_rule" "reactive" "once" "ok" "1" "0" "0" "direct" "re:$t_pat" "1"
      fi
    done <<< "$TRIGGERS"
  fi
fi

# ── Other-company skip (feedback_9eda6433) ────────────────────────────────
# Per-company policy directories already load only for the session's own
# company set (DIRS above). A personal, repo, worker or core policy can still
# be written for one client. It is skipped only when it says so explicitly,
# with a frontmatter `company:` or `companies:` field (a slug or a list of
# slugs). A word in `when:` is never read as a company name, because
# company folder names are often ordinary words (live, team, beta, version).
# The skip applies only when the session holds a company lock (the scope
# capability hq-session.sh writes) and none of the policy's named companies
# is in that lock. With no lock, or a personal lock, nothing is skipped; a
# cwd or HQ_POLICY_COMPANY fallback is not a lock. Binding rules (any
# enforcement other than soft or unset) are never skipped on this path, and
# rows from the locked companies' own policy directories are never touched.
# One awk pass over the matched soft files only.
POLICY_ACTIVE_COMPANIES=""
policy_lock_set="${co_scopes[*]+${co_scopes[*]}}"
case " $policy_lock_set " in
  *" personal "*) ;;
  *) [ -n "${policy_lock_set// /}" ] && POLICY_ACTIVE_COMPANIES=" $policy_lock_set " ;;
esac
if [ -n "$MATCHES" ] && [ -n "$POLICY_ACTIVE_COMPANIES" ]; then
  other_paths=()
  while IFS=$'\x1f' read -r _o_slug _o_scope _o_path _o_enf _o_rest; do
    [ -n "$_o_path" ] && [ -f "$_o_path" ] || continue
    case "$_o_path" in "$HQ_ROOT"/companies/*|*/companies/*/policies/*) continue ;; esac
    case "$_o_enf" in soft|unset|'') other_paths+=("$_o_path") ;; esac
  done <<< "${MATCHES//$'\t'/$'\x1f'}"
  other_drop=""
  if [ "${#other_paths[@]}" -gt 0 ]; then
    # Only real companies count: a value with no company folder under
    # $HQ_ROOT/companies (a literal <slug>, a placeholder, a typo) names
    # nothing and hides nothing. Locked slugs always count.
    policy_known_companies="$POLICY_ACTIVE_COMPANIES"
    for _o_dir in "$HQ_ROOT"/companies/*/; do
      [ -d "$_o_dir" ] || continue
      _o_name="${_o_dir%/}"; _o_name="${_o_name##*/}"
      case "$_o_name" in _*|.*) continue ;; esac
      policy_known_companies="$policy_known_companies $_o_name"
    done
    # Prints each file that names at least one known company explicitly and
    # no locked company. A YAML comment (` #` onward) is not part of the value.
    other_drop="$(LC_ALL=C awk -v active="$POLICY_ACTIVE_COMPANIES" -v known="$policy_known_companies" '
      function emit(   k) { if (named && !mine) print FILENAME }
      function take(slug) { slug = tolower(slug); if (slug == "" || !(slug in kn)) return; named = 1; if (slug in act) mine = 1 }
      BEGIN { n = split(active, a, " "); for (i = 1; i <= n; i++) act[tolower(a[i])] = 1
              n = split(known, a, " "); for (i = 1; i <= n; i++) kn[tolower(a[i])] = 1 }
      FNR == 1 { fm = 0; done = 0; named = 0; mine = 0; sub(/\r$/, ""); if ($0 ~ /^(\357\273\277)?---[[:space:]]*$/) { fm = 1; next } }
      done || !fm { next }
      { sub(/\r$/, "") }
      /^---[[:space:]]*$/ { done = 1; emit(); next }
      /^compan(y|ies):/ {
        v = $0; sub(/^compan(y|ies):/, "", v); sub(/(^|[[:space:]])#.*$/, "", v)
        # Only whole slug items count; an item with any other text names nothing.
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); if (v ~ /^\[.*\]$/) v = substr(v, 2, length(v) - 2)
        m = split(v, t, ","); for (i = 1; i <= m; i++) { x = t[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", x); gsub(/^["\047]|["\047]$/, "", x); if (x ~ /^[A-Za-z0-9][A-Za-z0-9_-]*$/) take(x) }
        next
      }
    ' "${other_paths[@]}" 2>/dev/null || true)"
  fi
  if [ -n "$other_drop" ]; then
    other_kept=""
    while IFS= read -r other_row; do
      [ -n "$other_row" ] || continue
      IFS=$'\x1f' read -r _o_slug _o_scope _o_path _o_rest <<< "${other_row//$'\t'/$'\x1f'}"
      # Bash-native membership; a grep -q pipe races under pipefail.
      case $'\n'"$other_drop"$'\n' in
        *$'\n'"$_o_path"$'\n'*) [ -n "$_o_path" ] && continue ;;
      esac
      other_kept="${other_kept}${other_row}
"
    done <<< "$MATCHES"
    MATCHES="$other_kept"
  fi
fi

# ── Emit + record ─────────────────────────────────────────────────────────
# US-406: machine-readable records for the agent-session entrypoint. No prose
# wrapper, no interactive 16-cap (consumer applies HQ_SESSION_POLICY_MAX_*).
if [ "${HQ_POLICY_EMIT:-}" = "tsv" ]; then
  record_match_rows "$MATCHES"
  printf '%s' "$MATCHES" | while IFS=$'\t' read -r slug scope path enf rule kind injv ws spec stale exempt rel tkey score; do
    [ -z "$slug" ] && continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$slug" "$scope" "$path" "$enf" "$rule"
  done
  exit 0
fi

# Bound the SessionStart-heavy baseline so box preflight cannot fail closed
# (US-003 / former US-013). Crucially, stable-partition reactive matches ahead
# of the SessionStart baseline BEFORE applying the cap: scope order is preserved
# inside each group, but an event-specific policy must not lose its slot to a
# generic policy that would have fired on any event.
#
# This is Bash-native (portable to Bash 3.2) rather than sort -s so the stable
# ordering does not depend on GNU/BSD sort differences.
#
# Within each group, `enforcement: hard` policies are stable-partitioned ahead
# of soft/unset ones (2026-09-07). Before this, the 16-slot cap cut in glob
# order, so a hard rule about production credentials could lose its slot to a
# soft style note that happened to sort earlier in the same directory. Scope
# order (company > repo > personal > core) is still preserved inside each
# enforcement tier.
#
# Relevance to the actual trigger ranks first (2026-10-19). Reactive rows are
# split by the evaluator's relevance class: `direct` rows matched `when:`
# identifiers in the action itself (the command or tool input); `generic` rows
# matched through output words, assistant intent, or an unconditional or
# negation-only trigger. The group order is reactive-direct-hard,
# reactive-direct-other, reactive-generic-hard, reactive-generic-other,
# baseline-hard, baseline-other. So a HARD rule keyed on the current command
# leads the reminder, and it is the row the ceiling keeps in full.
#
# Specificity ranks ahead of plain relevance (2026-10-21, feedback
# feedback_34ab4b26). A `specific` row is a direct row whose `when:` matched
# two or more identifiers, one identifier few policies use, or a file name,
# path or slash command; it forms its own pair of groups ahead of the other
# direct rows. A rule that matched only
# on a common word such as `deploy` or `slack` no longer competes with it for
# the full-text budget or the relevance cap below.
ORDERED_MATCHES=""
GROUP_ROWS=()
GROUP_SPECS=()
GROUP_COUNT=0
# Parse each row once and assign its group number (0-7), so the eight group
# passes below compare integers instead of re-reading every row. The in-group
# sort key is the relevance score (RELEVANCE SCORE in the header) with the
# specificity count as the tie-breaker: score * 10000 + spec. Staleness then
# reorders equal keys, and scope and file order break the remaining ties.
ALL_ROWS=()
ALL_GROUPS=()
ALL_SPECS=()
ALL_COUNT=0
while IFS= read -r match; do
  [ -n "$match" ] || continue
  IFS=$'\x1f' read -r _m_slug _m_scope _m_path _m_enf _m_rule _m_kind _m_inj _m_ws _m_spec _m_stale _m_exempt _m_rel _m_tkey _m_score <<< "${match//$'\t'/$'\x1f'}"
  if [ "$_m_kind" = "reactive" ]; then
    case "$_m_rel" in
      specific) _m_group=0 ;;
      direct) _m_group=2 ;;
      *) _m_group=4 ;;
    esac
  else
    _m_group=6
  fi
  [ "$_m_enf" = "hard" ] || _m_group=$((_m_group + 1))
  case "$_m_spec" in ''|*[!0-9]*) _m_spec=0 ;; esac
  case "$_m_score" in ''|*[!0-9]*) _m_score=0 ;; esac
  _m_spec=$((_m_score * 10000 + _m_spec))
  ALL_ROWS[$ALL_COUNT]="$match"
  ALL_GROUPS[$ALL_COUNT]="$_m_group"
  ALL_SPECS[$ALL_COUNT]="$_m_spec"
  ALL_COUNT=$((ALL_COUNT + 1))
done <<< "$MATCHES"
for match_group in 0 1 2 3 4 5 6 7; do
    for ((all_index=0; all_index<ALL_COUNT; all_index++)); do
      [ "${ALL_GROUPS[$all_index]}" = "$match_group" ] || continue
      match="${ALL_ROWS[$all_index]}"
      _m_spec="${ALL_SPECS[$all_index]}"
      insert_at="$GROUP_COUNT"
      for ((group_index=0; group_index<GROUP_COUNT; group_index++)); do
        if [ "$_m_spec" -gt "${GROUP_SPECS[$group_index]}" ]; then
          insert_at="$group_index"
          break
        fi
      done
      if [ "$insert_at" -eq "$GROUP_COUNT" ]; then
        GROUP_ROWS[$GROUP_COUNT]="$match"
        GROUP_SPECS[$GROUP_COUNT]="$_m_spec"
      else
        group_shift=$GROUP_COUNT
        while [ "$group_shift" -gt "$insert_at" ]; do
          GROUP_ROWS[$group_shift]="${GROUP_ROWS[$((group_shift - 1))]}"
          GROUP_SPECS[$group_shift]="${GROUP_SPECS[$((group_shift - 1))]}"
          group_shift=$((group_shift - 1))
        done
        GROUP_ROWS[$insert_at]="$match"
        GROUP_SPECS[$insert_at]="$_m_spec"
      fi
      GROUP_COUNT=$((GROUP_COUNT + 1))
    done
    # Stable insertion order matches `sort -s -k9,9nr`: descending numeric
    # specificity, while equal values retain their original scope order.
    #
    # Staleness (policy-lifecycle US-003): inside each run of equal
    # specificity, non-exempt rows are stable-sorted by staleness ascending
    # and refill the slots non-exempt rows held. Exempt rows (safety-critical
    # hard rules, gate policies, inject: always) keep their exact index. This
    # only reorders; no row is ever removed here, so staleness cannot drop a
    # match on its own — the byte ceiling simply cuts stale rules first.
    run_start=0
    while [ "$run_start" -lt "$GROUP_COUNT" ]; do
      run_end="$run_start"
      while [ $((run_end + 1)) -lt "$GROUP_COUNT" ] \
        && [ "${GROUP_SPECS[$((run_end + 1))]}" = "${GROUP_SPECS[$run_start]}" ]; do
        run_end=$((run_end + 1))
      done
      if [ "$run_end" -gt "$run_start" ]; then
        STALE_SLOTS=()
        STALE_ROWS=()
        STALE_KEYS=()
        stale_n=0
        for ((group_index=run_start; group_index<=run_end; group_index++)); do
          IFS=$'\t' read -r _s1 _s2 _s3 _s4 _s5 _s6 _s7 _s8 _s9 _s_stale _s_exempt _s_rest <<< "${GROUP_ROWS[$group_index]}"
          [ "$_s_exempt" = "1" ] && continue
          case "$_s_stale" in ''|*[!0-9]*) _s_stale=0 ;; esac
          # Stable insertion sort by staleness ascending.
          ins="$stale_n"
          for ((k=0; k<stale_n; k++)); do
            if [ "$_s_stale" -lt "${STALE_KEYS[$k]}" ]; then ins="$k"; break; fi
          done
          for ((k=stale_n; k>ins; k--)); do
            STALE_ROWS[$k]="${STALE_ROWS[$((k - 1))]}"
            STALE_KEYS[$k]="${STALE_KEYS[$((k - 1))]}"
          done
          STALE_ROWS[$ins]="${GROUP_ROWS[$group_index]}"
          STALE_KEYS[$ins]="$_s_stale"
          STALE_SLOTS[$stale_n]="$group_index"
          stale_n=$((stale_n + 1))
        done
        for ((k=0; k<stale_n; k++)); do
          GROUP_ROWS[${STALE_SLOTS[$k]}]="${STALE_ROWS[$k]}"
        done
      fi
      run_start=$((run_end + 1))
    done
    for ((group_index=0; group_index<GROUP_COUNT; group_index++)); do
      ORDERED_MATCHES+="${GROUP_ROWS[$group_index]}"$'\n'
    done
    GROUP_ROWS=()
    GROUP_SPECS=()
    GROUP_COUNT=0
done
MATCHES="$ORDERED_MATCHES"
# A HARD rule shown as a summary for this same trigger inside the seen window
# is not repeated; a new trigger or an expired entry lets it through.
filter_seen_matches

# Relevance cap (2026-10-21, feedback feedback_34ab4b26). The cap limits soft
# and unset rows only; it never drops a HARD row (PR #1526 review). Every
# matched HARD row is kept, at least as an index line, and the full-text
# budget and output ceiling below bound its size. Reactive rows with a
# specific match, `inject: always` rows and malformed-trigger fallback rows
# are kept too. The other soft rows fill what is left of RELEVANCE_CAP slots
# after the kept rows (malformed fallbacks take no slot), in rank order, so a
# common-word soft hint never pads an event that already has enough matches.
# Rows over the cap are counted in a notice, are not recorded, and stay
# eligible for a later event. SessionStart is not capped: it introduces the
# baseline. An explicit legacy HQ_SESSION_POLICY_CAP replaces this cap.
# HQ_POLICY_RELEVANCE_CAP=0 turns the cap off.
RELEVANCE_CAP="${HQ_POLICY_RELEVANCE_CAP:-6}"
case "$RELEVANCE_CAP" in ''|*[!0-9]*) RELEVANCE_CAP=6 ;; esac
case "${HQ_SESSION_POLICY_CAP:-0}" in ''|0|*[!0-9]*) ;; *) RELEVANCE_CAP=0 ;; esac
# Generic cap (2026-10-21, RC4 hook noise: feedback_e5c5d107, _10ff20bf,
# _4e3f4b72, _0941bfc1, _7e2d3299, _b4602c17, _3c8e7c87, _03c2e4fe, _d39a7487,
# _e4cef868 and the other rows under that root cause). A direct row that
# matched on ONE common word (`git`, `deploy`, `slack`: hundreds of policies in
# a grown HQ key on each) is a weak signal for this event. Per tool or prompt
# event at most GENERIC_CAP such soft rows are shown, in rank order,
# inside the relevance cap. The generic rows over that cap are PARKED: written
# to the TTL seen set under their trigger key, so the same word does not
# surface them again for SEEN_TTL seconds. Before this, over-cap rows merely
# stayed eligible, so every later `git ...` call showed the next six in full
# until the whole set had been shown once: a 4-6 KB reminder on nearly every
# tool call. A specific row, an `inject: always` row and a malformed-trigger
# fallback row are never generic and are not parked, and neither is a valid
# HARD row: it is always kept (PR #1526/#1548 reviews). HQ_POLICY_GENERIC_CAP=0
# turns the generic cap off (over-cap rows then stay eligible, as under the
# relevance cap alone).
GENERIC_CAP="${HQ_POLICY_GENERIC_CAP:-2}"
case "$GENERIC_CAP" in ''|*[!0-9]*) GENERIC_CAP=2 ;; esac
# Tool events only. A prompt is one event per turn and keeps the relevance
# cap alone, so a one-word HARD rule such as "announce before deploy" still
# reaches a "please deploy to prod" prompt; a Bash call is one of dozens per
# turn, and a one-word match on its command text is where the per-call noise
# came from.
case "$EVENT" in PreToolUse|PostToolUse) ;; *) GENERIC_CAP=0 ;; esac
RELEVANCE_DROPPED=0
RELEVANCE_SOFT_HIDDEN=0
GENERIC_PARKED=0
GENERIC_PARKED_HARD=0
GENERIC_PARKED_HARD_NAMES=""
if [ "$RELEVANCE_CAP" -gt 0 ] && [ "$EVENT" != "SessionStart" ] && [ -n "$MATCHES" ]; then
  # Decide each row: 2 = always kept, 1 = kept in a cap slot, 0 = dropped.
  # Only always-kept HARD rows use up slots, and HARD rows take the slots
  # before soft rows, so specific soft hints can never push an applicable
  # HARD rule out of the reminder (PR #1526 review).
  RELEVANCE_ROWS=()
  RELEVANCE_HARD=()
  RELEVANCE_KEEP=()
  RELEVANCE_GENERIC=()
  relevance_n=0
  relevance_room="$RELEVANCE_CAP"
  generic_room="$GENERIC_CAP"
  while IFS= read -r match; do
    [ -n "$match" ] || continue
    # Tab is IFS whitespace, so `read` would merge the empty fields of a row
    # with no path and shift `kind` and `rel`. Split on a non-blank separator.
    IFS=$'\x1f' read -r slug scope path enf rule kind injv ws spec stale exempt rel tkey score <<< "${match//$'\t'/$'\x1f'}"
    RELEVANCE_ROWS[$relevance_n]="$match"
    RELEVANCE_HARD[$relevance_n]=0
    [ "$enf" = "hard" ] && RELEVANCE_HARD[$relevance_n]=1
    RELEVANCE_KEEP[$relevance_n]=0
    RELEVANCE_GENERIC[$relevance_n]=0
    case "$score" in ''|*[!0-9]*) score=0 ;; esac
    # A valid HARD row is always kept (as full text, a summary line or a
    # footer slug) and never parked, whatever its relevance score: a HARD
    # rule whose trigger words are common across policies (review, pr, test)
    # scores 0 even on the event it is about, and parking it would hide it
    # for SEEN_TTL seconds (PR #1600 review). The full-text budget and the
    # output ceiling bound its size; a row cut by the ceiling is held for a
    # later call.
    if { [ "$enf" = "hard" ] && [ "$ws" != "malformed" ]; } \
      || { [ "$rel" = "specific" ] && [ "$kind" = "reactive" ]; } \
      || [ "$injv" = "always" ] || { [ "$ws" = "malformed" ] && [ "$GENERIC_CAP" -eq 0 ]; }; then
      RELEVANCE_KEEP[$relevance_n]=2
      if [ "$enf" = "hard" ] && [ "$ws" != "malformed" ]; then
        relevance_room=$((relevance_room - 1))
      fi
    elif [ "$GENERIC_CAP" -gt 0 ] && [ "$ws" = "malformed" ]; then
      # A malformed-trigger fallback row did not match this command at all.
      # On a tool event it is one of the weak rows: at most GENERIC_CAP of
      # them per call, as summary lines (below), the rest parked on the
      # `malformed` key. On the live corpus these rows, always kept and in
      # full text, were what filled every `git status` reminder.
      RELEVANCE_GENERIC[$relevance_n]=1
    elif [ "$GENERIC_CAP" -gt 0 ] && [ "$kind" = "reactive" ]; then
      # Generic here means a weak match: exactly one plain identifier from the
      # event text (`git`, `deploy`, `slack`), or no identifier at all (a
      # match through a broader fact set). Two or more identifiers, or a file
      # name, path or slash command (`.mcp.json`, `/prd`) are not weak,
      # whichever channel matched them.
      case "${tkey#*:}" in *+*|*.*|*/*) ;; *) RELEVANCE_GENERIC[$relevance_n]=1 ;; esac
    elif [ "$GENERIC_CAP" -gt 0 ]; then
      # A baseline row (`when: always` and the rest of the SessionStart set)
      # did not match this command. SessionStart introduces it and a prompt
      # event backfills it; a tool event does not. On the live corpus these
      # rows refilled every Bash call four at a time, in full text, each time
      # their 30-minute seen-set entry expired.
      RELEVANCE_GENERIC[$relevance_n]=2
    fi
    relevance_n=$((relevance_n + 1))
  done <<< "$MATCHES"
  for relevance_pass in 1 0; do
    for ((relevance_i=0; relevance_i<relevance_n; relevance_i++)); do
      [ "$relevance_room" -gt 0 ] || break
      [ "${RELEVANCE_KEEP[$relevance_i]}" = 0 ] || continue
      [ "${RELEVANCE_HARD[$relevance_i]}" = "$relevance_pass" ] || continue
      if [ "${RELEVANCE_GENERIC[$relevance_i]}" = 1 ]; then
        [ "$generic_room" -gt 0 ] || continue
        generic_room=$((generic_room - 1))
      elif [ "${RELEVANCE_GENERIC[$relevance_i]}" = 2 ]; then
        continue
      fi
      RELEVANCE_KEEP[$relevance_i]=1
      relevance_room=$((relevance_room - 1))
    done
  done
  RELEVANCE_KEPT=""
  relevance_parked=""
  for ((relevance_i=0; relevance_i<relevance_n; relevance_i++)); do
    if [ "${RELEVANCE_KEEP[$relevance_i]}" = 0 ]; then
      RELEVANCE_DROPPED=$((RELEVANCE_DROPPED + 1))
      relevance_row="${RELEVANCE_ROWS[$relevance_i]}"
      IFS=$'\x1f' read -r slug scope path enf rule kind injv ws spec stale exempt rel tkey score <<< "${relevance_row//$'\t'/$'\x1f'}"
      if [ "${RELEVANCE_GENERIC[$relevance_i]}" = 1 ]; then
        # Parked on its trigger key. A row with no identifier (an
        # unconditional or negation-only trigger) has nothing to park on
        # and just stays eligible, as before.
        case "${tkey#*:}" in
          ''|always) [ "$enf" = "hard" ] || RELEVANCE_SOFT_HIDDEN=$((RELEVANCE_SOFT_HIDDEN + 1)) ;;
          *)
            relevance_parked+="$slug"$'\t'"$tkey"$'\n'
            GENERIC_PARKED=$((GENERIC_PARKED + 1))
            # A valid HARD row is never generic here, so this is a guard:
            # if one is ever parked, every such slug is named in the skip
            # notice, with no "+K more" (PR #1600 review).
            if [ "$enf" = "hard" ] && [ "$ws" != "malformed" ]; then
              GENERIC_PARKED_HARD=$((GENERIC_PARKED_HARD + 1))
              GENERIC_PARKED_HARD_NAMES="${GENERIC_PARKED_HARD_NAMES:+$GENERIC_PARKED_HARD_NAMES, }$slug"
            fi
            ;;
        esac
      elif [ "$enf" != "hard" ]; then
        RELEVANCE_SOFT_HIDDEN=$((RELEVANCE_SOFT_HIDDEN + 1))
      fi
    else
      RELEVANCE_KEPT+="${RELEVANCE_ROWS[$relevance_i]}"$'\n'
    fi
  done
  if [ -n "$relevance_parked" ]; then
    # Same row shape as the summary-only seen entries: slug, epoch, trigger key.
    relevance_now="$(date +%s)"
    relevance_parked="$(printf '%s' "$relevance_parked" | awk -F '\t' -v now="$relevance_now" 'NF { print $1 "\t" now "\t" $2 }')"
    record_slugs "$SEEN_FILE" "$relevance_parked"$'\n'
  fi
  MATCHES="$RELEVANCE_KEPT"
fi

# Truncation is NEVER silent. In addition to naming withheld policies below,
# record them now: the SessionStart baseline is a one-time introduction, so a
# policy that lost the cap was considered and dropped, not deferred to the next
# event where it could crowd out new reactive work again.
# INDEX MODE (2026-09-07, default): there is no session count cap. Every
# matching policy within the relevance cap above is listed as a one-line index
# entry (id, tier, scope, summary), and only reactive HARD matches carry full
# text, inside HARD_BUDGET (specific ones regardless of it). The whole
# emission is bounded by OUTPUT_CEILING below, so nothing is withheld by rank:
# at ~120 bytes a line, 50+ policies fit under the host ceiling, and the agent
# pulls any rule's full text on demand (`qmd get <slug>` or the file).
# Setting HQ_SESSION_POLICY_CAP to a positive number restores the legacy
# count cap (used by the box-preflight bounds tests).
SESSION_POLICY_CAP="${HQ_SESSION_POLICY_CAP:-0}"
MATCH_COUNT=0
while IFS= read -r match; do
  [ -n "$match" ] && MATCH_COUNT=$((MATCH_COUNT + 1))
done <<< "$MATCHES"
WITHHELD=0
WITHHELD_MATCHES=""
if [ "$SESSION_POLICY_CAP" -gt 0 ] && [ "$MATCH_COUNT" -gt "$SESSION_POLICY_CAP" ]; then
  WITHHELD=$((MATCH_COUNT - SESSION_POLICY_CAP))
  KEPT_MATCHES=""
  kept=0
  while IFS= read -r match; do
    [ -n "$match" ] || continue
    if [ "$kept" -lt "$SESSION_POLICY_CAP" ]; then
      KEPT_MATCHES="${KEPT_MATCHES}${match}
"
      kept=$((kept + 1))
    else
      WITHHELD_MATCHES="${WITHHELD_MATCHES}${match}
"
    fi
  done <<< "$MATCHES"
  MATCHES="$KEPT_MATCHES"
fi

WITHHELD_NAMES=""
WITHHELD_NAMED=0
if [ -n "$WITHHELD_MATCHES" ]; then
  # An explicit count cap intentionally consumes lower-ranked matches for this
  # session; preserve that existing contract. Output-ceiling omissions are
  # handled separately after the final reminder is assembled.
  record_match_rows "$WITHHELD_MATCHES"
  while IFS=$'\t' read -r slug scope path enf rule kind injv ws spec stale exempt rel tkey score; do
    [ -n "$slug" ] || continue
    if [ "$WITHHELD_NAMED" -lt 10 ]; then
      WITHHELD_NAMES="${WITHHELD_NAMES}${WITHHELD_NAMES:+, }${slug}"
      WITHHELD_NAMED=$((WITHHELD_NAMED + 1))
    fi
  done <<< "$WITHHELD_MATCHES"
fi

# Persist the final machine-readable match set for receipt-backed enforcement.
# Prompt prose remains advisory; this TSV is the deterministic hand-off from
# policy selection to the PreToolUse delivery gate.
if [ -n "${SESSION_ID:-}" ] \
   && { [ -n "$MATCHES" ] || [ "$EVENT" = "UserPromptSubmit" ]; } \
   && [ "${HQ_POLICY_EMIT:-}" != "tsv" ]; then
  ENFORCEMENT_DIR="$HQ_ROOT/workspace/orchestrator/policy-enforcement"
  ENFORCEMENT_MATCHES="$ENFORCEMENT_DIR/${SESSION_ID}.policies.tsv"
  mkdir -p "$ENFORCEMENT_DIR" 2>/dev/null || true
  ENFORCEMENT_LOCK="${ENFORCEMENT_MATCHES}.lock"
  ENFORCEMENT_ATTEMPTS=0
  until mkdir "$ENFORCEMENT_LOCK" 2>/dev/null; do
    reclaim_stale_enforcement_lock "$ENFORCEMENT_LOCK" || true
    ENFORCEMENT_ATTEMPTS=$((ENFORCEMENT_ATTEMPTS + 1))
    [ "$ENFORCEMENT_ATTEMPTS" -lt 100 ] || break
    sleep 0.02
  done
  if [ "$ENFORCEMENT_ATTEMPTS" -lt 100 ]; then
    ACTIVE_ENFORCEMENT_LOCK="$ENFORCEMENT_LOCK"
    ACTIVE_ENFORCEMENT_TOKEN="$$-${RANDOM}-${RANDOM}-$(date +%s)"
    printf '%s\n' "$$" > "$ENFORCEMENT_LOCK/pid"
    printf '%s\n' "$(date +%s)" > "$ENFORCEMENT_LOCK/time"
    printf '%s\n' "$ACTIVE_ENFORCEMENT_TOKEN" > "$ENFORCEMENT_LOCK/token"
  fi
  if [ "$ENFORCEMENT_ATTEMPTS" -ge 100 ]; then
    if [ "$EVENT" = "PreToolUse" ] && [ "$TOOL_NAME" = "Bash" ] \
       && printf '%s' "$ARG" | grep -Eqi '(^|[^[:alnum:]_])hq[[:space:]]+(cowork[[:space:]]+)?dm([^[:alnum:]_]|$)|chat\.postMessage|send-broadcast|slack\.com/api/chat\.postMessage|/broadcasts'; then
      jq -nc '{decision:"block",reason:"POLICY ENFORCEMENT BLOCK: policy match state is busy and cannot be verified safely; retry the outbound action."}'
      exit 2
    fi
  else
    ACTIVE_ENFORCEMENT_LOCK="$ENFORCEMENT_LOCK"
    # One atomic replace. A prompt keeps only the baseline rows and adds this
    # turn's matches in the same temp file; truncating first in a separate
    # rename left a window where a hook killed by its timeout published a
    # match set with no HARD rows for the turn, and the PreToolUse gate then
    # passed outbound actions it should block.
    ENFORCEMENT_TMP="$(mktemp "$ENFORCEMENT_DIR/.matches.XXXXXX")"
    {
      if [ "$EVENT" = "UserPromptSubmit" ]; then
        awk -F '\t' '$6 == "baseline"' "$ENFORCEMENT_MATCHES" 2>/dev/null || true
      else
        cat "$ENFORCEMENT_MATCHES" 2>/dev/null || true
      fi
      printf '%s' "$MATCHES" | while IFS=$'\t' read -r slug scope path enf rule kind injv ws spec stale exempt rel tkey score; do
        [ -n "$slug" ] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$slug" "$scope" "$path" "$enf" "$rule" "$kind"
      done
    } | awk -F '\t' '!seen[$1]++' > "$ENFORCEMENT_TMP"
    mv "$ENFORCEMENT_TMP" "$ENFORCEMENT_MATCHES"
    cleanup_enforcement_lock
    ACTIVE_ENFORCEMENT_LOCK=""
    ACTIVE_ENFORCEMENT_TOKEN=""
  fi
fi

# The declaration/conflict gate runs after the finalized policy hand-off is
# durable, avoiding a sibling-hook race on an empty match file.
ENFORCEMENT_CONTEXT=""
if [ "$EVENT" = "UserPromptSubmit" ] && [ "${HQ_POLICY_EMIT:-}" != "tsv" ] \
   && [ "$POLICY_ENFORCEMENT_GATE_ENABLED" -eq 1 ]; then
  ENFORCEMENT_OUTPUT="$(printf '%s' "$STDIN_JSON" | \
    bash "$HQ_ROOT/.claude/hooks/policy-enforcement-gate.sh" UserPromptSubmit 2>/dev/null || true)"
  ENFORCEMENT_CONTEXT="$(printf '%s' "$ENFORCEMENT_OUTPUT" | \
    jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
fi

# The registry run of policy-enforcement-gate.sh leaves a pass stamp when this
# Bash call was not outbound and matched no gate-fact policy (see the stamp
# comment there). If the stamp holds this exact payload (tool_use_id included)
# and the match TSV and state JSON are still byte-identical to the copies it
# holds, the re-run below would read the same inputs and pass again, so it is
# skipped. Any difference, a missing stamp, or a missing tool_use_id runs the
# gate as before. Keep pretool_pass_key and pretool_pass_snapshot identical to
# the gate's copies.
pretool_pass_key() { # <payload> -> REPLY ("" without a tool_use_id)
  local payload="$1" id=""
  [[ "$payload" =~ \"tool_use_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]+)\" ]] && id="${BASH_REMATCH[1]}"
  REPLY=""
  [ -n "$id" ] || return 0
  payload="${payload%"${payload##*[!$'\n']}"}"
  REPLY="id:${id}"$'\n'"payload:${#payload}"$'\n'"${payload}"$'\n'
}
pretool_pass_snapshot() { # <policies-tsv> <state-json> -> REPLY
  local file content out=""
  for file in "$1" "$2"; do
    if [ -f "$file" ]; then
      content=""
      IFS= read -r -d '' content < "$file" || true
      out="${out}present:${#content}"$'\n'"${content}"$'\n'
    else
      out="${out}missing"$'\n'
    fi
  done
  REPLY="$out"
}
pretool_gate_pass_is_current() {
  local dir stamp key stamp_content=""
  [ -n "${SESSION_ID:-}" ] || return 1
  case "$SESSION_ID" in */*|*..*) return 1 ;; esac
  # The gate resolves its root from CLAUDE_PROJECT_DIR first; match it.
  dir="${CLAUDE_PROJECT_DIR:-$HQ_ROOT}/workspace/orchestrator/policy-enforcement"
  stamp="$dir/${SESSION_ID}.pretool-pass"
  [ -f "$stamp" ] || return 1
  pretool_pass_key "$STDIN_JSON"; key="$REPLY"
  [ -n "$key" ] || return 1
  IFS= read -r -d '' stamp_content < "$stamp" || true
  pretool_pass_snapshot "$dir/${SESSION_ID}.policies.tsv" "$dir/${SESSION_ID}.json"
  [ "$stamp_content" = "$key$REPLY" ]
}

# Bash policies may first match on the outbound command itself. Run the
# enforcement gate only after that same-action match is durable.
if [ "$EVENT" = "PreToolUse" ] && [ "$TOOL_NAME" = "Bash" ] \
   && [ "${HQ_POLICY_EMIT:-}" != "tsv" ] \
   && [ "$POLICY_ENFORCEMENT_GATE_ENABLED" -eq 1 ] \
   && ! pretool_gate_pass_is_current; then
  ENFORCEMENT_RC=0
  ENFORCEMENT_OUTPUT="$(printf '%s' "$STDIN_JSON" | \
    bash "$HQ_ROOT/.claude/hooks/policy-enforcement-gate.sh" PreToolUse 2>/dev/null)" || ENFORCEMENT_RC=$?
  if [ "$ENFORCEMENT_RC" -eq 2 ]; then
    printf '%s\n' "$ENFORCEMENT_OUTPUT"
    exit 2
  fi
fi

# No new line to deliver. When every match was delivered earlier in this
# session (ledger or seen set) the reminder still carries the footer naming
# the HARD rules that apply again, so the model keeps the pointer.
if [ -z "$MATCHES" ] && [ -z "${SHOWN_AGAIN_SLUGS}${SEEN_HARD_SLUGS}" ]; then
  if [ -n "$ENFORCEMENT_CONTEXT" ]; then
    printf '<policy-enforcement>\n%s\n</policy-enforcement>\n' "$ENFORCEMENT_CONTEXT"
  fi
  exit 0
fi

# Enforcement-tiered injection depth:
#   enforcement: hard  → the policy's ENTIRE body (everything after the closing
#                        frontmatter `---`) is injected verbatim. A binding rule
#                        must never reach the agent as a 160-char paraphrase of
#                        its first line — the caveats, the exceptions and the
#                        escape hatches all live further down the file.
#   soft / unset       → unchanged: the one-line `## Rule` excerpt, exactly as
#                        before (the default-prose fixture pins this path).
#
# Full text is bounded by a byte budget across the whole injection, consumed in
# reactive-first MATCHES order. Scope precedence (company > repo > personal >
# core) is preserved within each group, so event-specific hard rules claim the
# budget ahead of the SessionStart baseline. Overflow is NEVER silent: a policy
# that does not fit falls back to its summary line and is named in a trailing
# notice, so a shortened set can't be misread as the full text.
# Escape hatches: HQ_POLICY_HARD_FULL_TEXT=0 restores summary-only for hard
# policies; HQ_POLICY_HARD_BUDGET_BYTES resizes the budget.
HARD_FULL="${HQ_POLICY_HARD_FULL_TEXT:-1}"
# Host ceiling (2026-09-07): Claude Code persists any hook stdout above ~10,000
# bytes to a file and shows the model a ~2 KB preview — everything past it is
# lost for that turn. 3,341 such truncated outputs were found on one install,
# most of them this hook. The full-text budget therefore lives well under that
# ceiling, and the WHOLE emission is capped by OUTPUT_CEILING below, with a
# non-silent fallback to summaries when the cap would otherwise be exceeded.
HARD_BUDGET="${HQ_POLICY_HARD_BUDGET_BYTES:-5120}"
case "$HARD_BUDGET" in ''|*[!0-9]*) HARD_BUDGET=5120 ;; esac
# Per-policy ceiling. Without it a single long hard policy can swallow most of
# the shared budget and push every other hard rule down to its summary line.
HARD_MAX="${HQ_POLICY_HARD_MAX_BYTES:-2048}"
# Absolute ceiling on this hook's stdout. Must stay below the host's ~10,000
# byte persist threshold with margin; core/scripts/tests/inject-policy-output-ceiling.test.sh
# fails if either default is raised past it. 4000 since 2026-10-22
# (reminder-ceiling design): measured on a live HQ root every call filled an
# 8000-byte reminder with the same summary lines. Operators who want the old
# size set HQ_POLICY_OUTPUT_CEILING_BYTES=8000; the semantics are unchanged.
OUTPUT_CEILING="${HQ_POLICY_OUTPUT_CEILING_BYTES:-4000}"
# A configured ceiling is an absolute stdout bound, not a request we may round
# up to a more convenient value. Refuse a malformed value explicitly instead
# of falling through to an arithmetic comparison (and a silent hook failure).
case "$OUTPUT_CEILING" in
  ''|*[!0-9]*)
    printf 'inject-policy-on-trigger: HQ_POLICY_OUTPUT_CEILING_BYTES must be a non-negative integer; emitted no stdout.\n' >&2
    exit 0
    ;;
esac
# Budget split (reminder-ceiling design §4). Full HARD text takes at most
# FULL_BUDGET bytes per call: the shared HARD_BUDGET, or the ceiling minus a
# reserve for the summary lines, the footer and the notices, whichever is
# smaller. At the 4000-byte default that is 2600 bytes, one or two bodies.
# The "Already shown this session" footer has its own small budget; overflow
# collapses to a count.
FULL_TEXT_RESERVE=1400
FULL_BUDGET="$HARD_BUDGET"
if [ $((OUTPUT_CEILING - FULL_TEXT_RESERVE)) -lt "$FULL_BUDGET" ]; then
  FULL_BUDGET=$((OUTPUT_CEILING - FULL_TEXT_RESERVE))
  [ "$FULL_BUDGET" -ge 0 ] || FULL_BUDGET=0
fi
FOOTER_BUDGET="${HQ_POLICY_FOOTER_BYTES:-400}"
case "$FOOTER_BUDGET" in ''|*[!0-9]*) FOOTER_BUDGET=400 ;; esac
# Everything from the first archival heading on is history and justification,
# not the binding rule: it is what the agent must NOT be made to re-read on
# every injection. `## Rule`, `## Scope`, `## Enforcement` and friends stay.
# Set HQ_POLICY_BODY_STOP='' to inject whole files again.
# Matched against a lowercased line, so keep the pattern lowercase.
BODY_STOP="${HQ_POLICY_BODY_STOP-^#+[[:space:]]*(rationale|rationale and context|background|change history|changelog|history|examples?|references?|related|see also|sources?|provenance|evidence)[[:space:]]*$}"

# Build the full-text bodies and byte sizes for all matched hard rules in one
# awk process. The per-policy function below remains the fallback when a path
# cannot be represented safely in the temporary TSV or batch extraction fails.
POLICY_BODY_BATCH_MODE=0
POLICY_BODY_SIZES=()
POLICY_RULE_SIZES=()
prepare_policy_bodies() {
  local map_file="" size_file="" row_index=0 slug scope path enf rule kind injv ws spec stale exempt rel tkey score
  [ "$HARD_FULL" != "0" ] || return 0
  [ -n "$MATCHES" ] || return 0
  [ -n "$FACTS_TMP_DIR" ] || FACTS_TMP_DIR="$HQ_ROOT/workspace/orchestrator/hook-state"
  [ -d "$FACTS_TMP_DIR" ] || return 0
  POLICY_BODY_TMP_DIR="$(mktemp -d "$FACTS_TMP_DIR/.policy-bodies.XXXXXX" 2>/dev/null || true)"
  [ -n "$POLICY_BODY_TMP_DIR" ] || return 0
  map_file="$POLICY_BODY_TMP_DIR/map.tsv"
  size_file="$POLICY_BODY_TMP_DIR/sizes.tsv"
  : > "$map_file" || return 0
  while IFS=$'\t' read -r slug scope path enf rule kind injv ws spec stale exempt rel tkey score; do
    [ -n "$slug" ] || continue
    row_index=$((row_index + 1))
    if [ "$enf" = "hard" ] && [ -n "$path" ] && [ -r "$path" ]; then
      case "$path" in
        *$'\t'*|*$'\n'*)
          rm -rf "$POLICY_BODY_TMP_DIR" 2>/dev/null || true
          POLICY_BODY_TMP_DIR=""
          return 0
          ;;
      esac
      printf '%s\t%s\n' "$row_index" "$path" >> "$map_file" || return 0
    else
      printf '%s\t\n' "$row_index" >> "$map_file" || return 0
    fi
  done <<< "$MATCHES"

  if ! LC_ALL=C awk -v map_file="$map_file" -v body_dir="$POLICY_BODY_TMP_DIR" \
    -v stop="$BODY_STOP" '
    BEGIN {
      while ((getline row < map_file) > 0) {
        split(row, fields, "\t")
        row_id=fields[1]
        path=fields[2]
        bytes=0
        rule_bytes=0
        if (path != "") {
          depth=0; started=0; count=0; inrule=0; rcount=0
          while ((getline line < path) > 0) {
            if (line ~ /^---[ \t]*$/ && depth < 2) { depth++; continue }
            if (depth >= 2) {
              if (!started && line ~ /^[ \t]*$/) continue
              if (stop != "" && tolower(line) ~ stop) break
              started=1
              body[++count]=line
              # The `## Rule` section alone: the floor a HARD policy is never
              # shortened below when its whole body is over the per-policy limit.
              if (line ~ /^## Rule[ \t]*$/) inrule=1
              else if (line ~ /^## /) inrule=0
              if (inrule) rbody[++rcount]=line
            }
          }
          close(path)
          while (count > 0 && body[count] ~ /^[ \t]*$/) { delete body[count]; count-- }
          while (rcount > 0 && rbody[rcount] ~ /^[ \t]*$/) { delete rbody[rcount]; rcount-- }
          if (count > 0) {
            output=body_dir "/" row_id ".body"
            for (i=1; i<=count; i++) {
              if (i > 1) { printf "\n" >> output; bytes++ }
              printf "%s", body[i] >> output
              bytes += length(body[i])
              delete body[i]
            }
            close(output)
          }
          if (rcount > 0 && rcount < count) {
            output=body_dir "/" row_id ".rule"
            for (i=1; i<=rcount; i++) {
              if (i > 1) { printf "\n" >> output; rule_bytes++ }
              printf "%s", rbody[i] >> output
              rule_bytes += length(rbody[i])
              delete rbody[i]
            }
            close(output)
          } else {
            for (i=1; i<=rcount; i++) delete rbody[i]
          }
        }
        print row_id "\t" bytes "\t" rule_bytes
      }
      close(map_file)
    }
  ' "$map_file" > "$size_file" 2>/dev/null; then
    rm -rf "$POLICY_BODY_TMP_DIR" 2>/dev/null || true
    POLICY_BODY_TMP_DIR=""
    return 0
  fi

  while IFS=$'\t' read -r row_index row_size rule_size; do
    case "$row_index" in ''|*[!0-9]*)
      rm -rf "$POLICY_BODY_TMP_DIR" 2>/dev/null || true
      POLICY_BODY_TMP_DIR=""
      POLICY_BODY_SIZES=()
      POLICY_RULE_SIZES=()
      return 0
      ;;
    esac
    case "$row_size" in ''|*[!0-9]*)
      rm -rf "$POLICY_BODY_TMP_DIR" 2>/dev/null || true
      POLICY_BODY_TMP_DIR=""
      POLICY_BODY_SIZES=()
      POLICY_RULE_SIZES=()
      return 0
      ;;
    esac
    case "$rule_size" in ''|*[!0-9]*) rule_size=0 ;; esac
    POLICY_BODY_SIZES[$row_index]="$row_size"
    POLICY_RULE_SIZES[$row_index]="$rule_size"
  done < "$size_file"
  POLICY_BODY_BATCH_MODE=1
}

prepare_policy_bodies

policy_body() {
  # Print the binding part of the policy: everything after the closing
  # frontmatter `---`, leading blank lines trimmed, stopping at the first
  # archival heading. A file with no frontmatter (or an unreadable one) prints
  # nothing, and the caller falls back to the summary line — fail-open to prior
  # behaviour, never a dropped policy.
  awk -v stop="$BODY_STOP" '
    /^---[ \t]*$/ && d < 2 { d++; next }
    d >= 2 {
      if (!started && $0 ~ /^[ \t]*$/) next
      if (stop != "" && tolower($0) ~ stop) exit
      started = 1; print
    }
  ' "$1" 2>/dev/null | awk '
    # trim trailing blank lines left behind by the cut
    { L[NR]=$0 }
    END { last=0; for(i=1;i<=NR;i++) if (L[i] ~ /[^ \t]/) last=i
          for(i=1;i<=last;i++) print L[i] }
  '
}

policy_rule_body() {
  # The `## Rule` section of a policy body (as policy_body prints it), up to
  # the next `## ` heading. Prints nothing when the body has no `## Rule`
  # heading or when the Rule section IS the whole body (then the full body
  # applies and there is no shorter floor).
  policy_body "$1" | awk '
    { L[NR]=$0; if ($0 ~ /^## Rule[ \t]*$/) inrule=1; else if ($0 ~ /^## /) inrule=0; if (inrule) { R[++n]=$0 } }
    END { if (n == 0 || n >= NR) exit
          last=0; for(i=1;i<=n;i++) if (R[i] ~ /[^ \t]/) last=i
          for(i=1;i<=last;i++) print R[i] }
  '
}

MALFORMED_MARKER_PREFIX="__malformed-trigger-reported:"
MALFORMED_NOTICE_PREFIX='> Malformed `when:` trigger'

# record_malformed_notice <delivered-output> — after the notice is delivered,
# mark each affected slug so later events do not repeat the diagnostic. Large
# sets are reported by count; individual policies still keep their own ledgers.
record_malformed_notice() {
  local output="$1" row slug ws markers=""
  case "$output" in
    *"$MALFORMED_NOTICE_PREFIX"*) ;;
    *) return 0 ;;
  esac
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r slug _ _ _ _ _ _ ws _ <<< "$row"
    [ "$ws" = "malformed" ] || continue
    already "${MALFORMED_MARKER_PREFIX}${slug}" once && continue
    markers+="${MALFORMED_MARKER_PREFIX}${slug}"$'\n'
  done <<< "$MATCHES"
  [ -z "$markers" ] || record_slugs "$DEDUPE_FILE" "$markers"
}

# ALREADY_FOOTER — one line naming the valid HARD policies that matched this
# event again after an earlier delivery (in full: session ledger; as a summary
# line, a ceiling cut or a parked row for the same trigger: seen set). Slugs
# are added in rank order while the line stays under FOOTER_BUDGET bytes;
# the rest collapse to "+K more", or to a bare count when no slug fits.
# Slugs of malformed-trigger fallback rows in MATCHES, space separated, for
# the output-ceiling trim: they are cut before any row that matched.
MALFORMED_SLUGS=""
while IFS= read -r _mf_row; do
  [ -n "$_mf_row" ] || continue
  IFS=$'\x1f' read -r _mf_slug _ _ _ _ _ _ _mf_ws _ <<< "${_mf_row//$'\t'/$'\x1f'}"
  [ "$_mf_ws" = "malformed" ] && MALFORMED_SLUGS="${MALFORMED_SLUGS:+$MALFORMED_SLUGS }$_mf_slug"
done <<< "$MATCHES"
ALREADY_FOOTER=""
build_already_footer() {
  local slugs="${SHOWN_AGAIN_SLUGS}${SEEN_HARD_SLUGS}" slug list="" count=0 named=0
  local prefix='> Already shown this session, still binding: ' line candidate
  [ -n "$slugs" ] || return 0
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    case $'\n'"$list" in *$'\n'"$slug"$'\n'*) continue ;; esac
    list+="$slug"$'\n'
    count=$((count + 1))
  done <<< "$slugs"
  [ "$count" -gt 0 ] || return 0
  line="$prefix"
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    if [ "$named" -gt 0 ]; then candidate="$line, $slug"; else candidate="$line$slug"; fi
    policy_value_bytes "$candidate"
    # Keep room for ", +NNN more." after the last named slug.
    [ $((POLICY_VALUE_BYTES + 14)) -le "$FOOTER_BUDGET" ] || break
    line="$candidate"
    named=$((named + 1))
  done <<< "$list"
  if [ "$named" -eq 0 ]; then
    line="${prefix}${count} HARD policies."
  elif [ "$named" -lt "$count" ]; then
    line="$line, +$((count - named)) more."
  else
    line="$line."
  fi
  ALREADY_FOOTER="$line"
}
build_already_footer

emit_reminder() {
printf '<policy-reminder>\n'
printf '%s' "$MATCHES" | {
  spent=0
  match_index=0
  hard_summary=0
  oversize=""
  malformed=""
  malformed_count=0
  # HARD_FULL_KEEP=N (set by fit_reminder when the full emission would pass
  # the output ceiling): only the first N HARD rules whose text fits keep it.
  # Every later HARD rule is a summary line, covered by the ceiling notice.
  # A malformed-trigger fallback row did not match this event, so it is never
  # the kept rule.
  kept_full=0
  while IFS=$'\t' read -r slug scope path enf rule kind injv ws spec stale exempt rel tkey score; do
    [ -z "$slug" ] && continue
    match_index=$((match_index + 1))
    row_oversize=0
    # The malformed-trigger notice names a slug once per session. A malformed
    # hard policy is a low-ranked baseline row, so the output ceiling often
    # cuts its line and leaves it eligible; without this marker the notice
    # re-listed every such slug on every later event.
    if [ "$ws" = "malformed" ] && ! already "${MALFORMED_MARKER_PREFIX}${slug}" once; then
      malformed_count=$((malformed_count + 1))
      # Bound diagnostic metadata independently of the policy rows. An unbounded
      # slug list cannot be trimmed by trim_policy_lines and used to force the
      # last-resort fallback, dropping even the highest-ranked reactive rule.
      if [ "$malformed_count" -le 5 ]; then
        malformed="${malformed:+$malformed, }$slug"
      fi
    fi
    body=""
    # HARD rules carry full text while the budget lasts. MATCHES is already
    # ordered reactive-before-baseline and by specificity, so rules that
    # matched THIS event claim the budget first; a baseline hard rule that
    # loses the budget is still an index line, one read away.
    if [ "$HARD_FULL" != "0" ] && [ "$enf" = "hard" ] && [ -n "$path" ] && [ -r "$path" ] \
       && { [ "$ws" != "malformed" ] || [ "$GENERIC_CAP" -eq 0 ]; } \
       && { [ "${HARD_FULL_KEEP:-0}" = "0" ] || { [ "$kept_full" -lt "$HARD_FULL_KEEP" ] && [ "$ws" != "malformed" ]; }; }; then
      if [ "$POLICY_BODY_BATCH_MODE" -eq 1 ]; then
        body_file="$POLICY_BODY_TMP_DIR/$match_index.body"
        [ ! -f "$body_file" ] || body="$(< "$body_file")"
        size="${POLICY_BODY_SIZES[$match_index]:-0}"
      else
        body="$(policy_body "$path")"
        policy_value_bytes "$body"
        size="$POLICY_VALUE_BYTES"
      fi
    fi
    body_kind="full"
    if [ -n "$body" ] && [ "$size" -gt "$HARD_MAX" ]; then
      # Over the per-policy limit: the floor for a HARD policy is its `## Rule`
      # section (feedback_f43754eb: a one-line summary hid the rule a draft
      # then violated). Only when even the Rule section is over the limit does
      # the policy fall back to its summary line, with the oversize notice.
      rule_body=""
      rule_size=0
      if [ "$POLICY_BODY_BATCH_MODE" -eq 1 ]; then
        rule_file="$POLICY_BODY_TMP_DIR/$match_index.rule"
        [ ! -f "$rule_file" ] || rule_body="$(< "$rule_file")"
        rule_size="${POLICY_RULE_SIZES[$match_index]:-0}"
      else
        rule_body="$(policy_rule_body "$path")"
        policy_value_bytes "$rule_body"
        rule_size="$POLICY_VALUE_BYTES"
      fi
      if [ -n "$rule_body" ] && [ "$rule_size" -gt 0 ] && [ "$rule_size" -le "$HARD_MAX" ]; then
        body="$rule_body"
        size="$rule_size"
        body_kind="rule"
      fi
    fi
    if [ -n "$body" ]; then
      if [ "$size" -gt "$HARD_MAX" ]; then
        # One policy must not crowd out every other hard rule in the budget.
        oversize="${oversize:+$oversize, }$slug"
        row_oversize=1
        body=""
      elif [ $((spent + size)) -le "$FULL_BUDGET" ]; then
        # Full bodies are added in rank order while they fit FULL_BUDGET
        # (reminder-ceiling design §3). A body is printed whole or not at
        # all; a row that does not fit is listed as its summary line and
        # recorded in the seen set, so it is not repeated for this trigger
        # and comes back in full on a new trigger or after the window.
        spent=$((spent + size))
        kept_full=$((kept_full + 1))
        if [ "$body_kind" = "rule" ]; then
          printf '> Policy `%s` (HARD — Rule section from `%s`; the full text is over the %s-byte per-policy limit, read the file for the rest):\n' "$slug" "${path#"$HQ_ROOT"/}" "$HARD_MAX"
        else
          printf '> Policy `%s` (HARD — binding rule from `%s`):\n' "$slug" "${path#"$HQ_ROOT"/}"
        fi
        # Quote every body line into the reminder block, and neutralise any
        # literal <policy-reminder> tag inside a policy body (one exists today)
        # so an injected body cannot close or nest this block. A body line
        # starting with "Policy `" becomes "Policy: `" so it can never look
        # like a policy line ("> Policy `slug` ..."): the ceiling trim would
        # cut it, and the delivery check would count the slug as delivered.
        printf '%s\n' "$body" \
          | sed -e 's#</policy-reminder>#[/policy-reminder]#g' \
                -e 's/^Policy `/Policy: `/' \
                -e 's#<policy-reminder>#[policy-reminder]#g' \
                -e 's/^/> /' -e 's/^> $/>/'
        continue
      fi
    fi
    if [ "$enf" = "hard" ]; then
      [ "$row_oversize" = 1 ] || hard_summary=$((hard_summary + 1))
      printf '> Policy `%s` applies here: %s  [HARD · %s] (`%s`)\n' "$slug" "$rule" "$scope" "${path#"$HQ_ROOT"/}"
    elif [[ "$scope" == worker:* ]]; then
      printf '> Policy `%s` applies here: %s  [%s] (`%s`)\n' "$slug" "$rule" "$scope" "${path#"$HQ_ROOT"/}"
    else
      printf '> Policy `%s` applies here: %s (`%s`)\n' "$slug" "$rule" "${path#"$HQ_ROOT"/}"
    fi
  done
  # Notices (reminder-ceiling design §5): one line each, in this order, only
  # when true. A HARD row listed as one line is recorded in the seen set by
  # record_emitted_match_rows, so no notice needs to promise a later full text.
  if [ -n "$oversize" ]; then
    printf '> Over the %s-byte per-policy limit, so shortened to one-line summaries — %s. Read each in full at its own file before acting on it, and consider trimming the rule.\n' \
      "$HARD_MAX" "$oversize"
  fi
  hard_word="policies"; [ "$hard_summary" -ne 1 ] || hard_word="policy"
  soft_word="matches"; [ "$RELEVANCE_SOFT_HIDDEN" -ne 1 ] || soft_word="match"
  if [ "$hard_summary" -gt 0 ] && [ "$RELEVANCE_SOFT_HIDDEN" -gt 0 ]; then
    printf '> Output budget %s bytes: %s HARD %s listed as one line; %s soft %s not shown.\n' \
      "$OUTPUT_CEILING" "$hard_summary" "$hard_word" "$RELEVANCE_SOFT_HIDDEN" "$soft_word"
  elif [ "$hard_summary" -gt 0 ]; then
    printf '> Output budget %s bytes: %s HARD %s listed as one line.\n' "$OUTPUT_CEILING" "$hard_summary" "$hard_word"
  elif [ "$RELEVANCE_SOFT_HIDDEN" -gt 0 ]; then
    printf '> Output budget %s bytes: %s soft %s not shown.\n' "$OUTPUT_CEILING" "$RELEVANCE_SOFT_HIDDEN" "$soft_word"
  fi
  [ -z "$ALREADY_FOOTER" ] || printf '%s\n' "$ALREADY_FOOTER"
  if [ "$GENERIC_PARKED" -gt 0 ]; then
    if [ "$GENERIC_PARKED_HARD" -gt 0 ]; then
      printf '> Skipped: %s matched only common words (parked %s min); HARD among them: %s.\n' \
        "$GENERIC_PARKED" "$((SEEN_TTL / 60))" "$GENERIC_PARKED_HARD_NAMES"
    else
      printf '> Skipped: %s matched only common words (parked %s min).\n' "$GENERIC_PARKED" "$((SEEN_TTL / 60))"
    fi
  fi
  if [ "$malformed_count" -gt 0 ]; then
    policy_value_bytes "$malformed"
    if [ "$malformed_count" -gt 5 ] || [ "$POLICY_VALUE_BYTES" -gt 512 ]; then
      malformed="$malformed_count policies (individual names omitted to preserve policy text)"
    fi
    printf '> Malformed `when:` trigger (does not parse, so it cannot be matched against this event) — %s. These are surfaced as a once-per-session fallback, not because they matched. Repair with: bash core/scripts/lint-policy-triggers.sh\n' \
      "$malformed"
  fi
}
if [ "$WITHHELD" -gt 0 ]; then
  more=""
  if [ "$WITHHELD" -gt "$WITHHELD_NAMED" ]; then
    more=" (+$((WITHHELD - WITHHELD_NAMED)) more)"
  fi
  # Do not start this line with "> Policy `": inject-policy-e2e's slugs()
  # parser intentionally recognises that prefix as an injected policy record.
  printf '> Session policy cap withheld %s policies (cap %s): %s%s. Reactive matches were prioritized over the SessionStart baseline.\n' \
    "$WITHHELD" "$SESSION_POLICY_CAP" "$WITHHELD_NAMES" "$more"
fi
printf '</policy-reminder>\n'
}

# The smallest useful delivery keeps the valid reminder wrapper and tells the
# model that policies matched, while directing it to the source files. Its
# measured size (including the final newline printed below) is the floor for a
# structured reminder. A lower configured ceiling emits no stdout and gets an
# explicit stderr explanation rather than a partial tag or an oversized blob.
compact_reminder() {
  printf '<policy-reminder>\n> Policies matched; read policy files.\n</policy-reminder>'
}

OUT="$(emit_reminder)"
if [ -n "$ENFORCEMENT_CONTEXT" ]; then
  OUT="${OUT%</policy-reminder>*}<policy-enforcement>\n${ENFORCEMENT_CONTEXT}\n</policy-enforcement>\n</policy-reminder>"
fi
# Measure precisely what the final `printf '%s\n'` below will write; command
# substitution strips emit_reminder's final newline.
# fit_reminder <ceiling> — fit FULL_OUT under <ceiling> bytes, setting OUT,
# OUT_BYTES and (when nothing fits) NO_STDOUT_REASON. PostToolUse calls it a
# second time with a smaller ceiling when JSON quoting grows the envelope past
# OUTPUT_CEILING, so the policies that fit are still delivered and recorded.
FULL_OUT="$OUT"
# trim_policy_lines — cut one-line policy entries from the bottom of OUT (the
# lowest-ranked first) until it fits under FIT_CEILING, in one byte-oriented
# awk pass. A full-text HARD heading is never cut. TRIM_SOFT_ONLY=1 cuts soft
# and unset lines only. Sets TRIM_STATUS to fit
# (OUT and OUT_BYTES updated), none (no cut count fits; TRIM_CUT is the most
# lines that could be cut), or error (NO_STDOUT_REASON says why).
trim_policy_lines() {
  TRIM_STATUS="error"
  TRIM_CUT=0
  TRIM_SEPARATOR=""
  TRIM_SEPARATOR_CANDIDATES=($'\034' $'\035' $'\036' $'\037')
  for candidate_separator in "${TRIM_SEPARATOR_CANDIDATES[@]}"; do
    case "$OUT" in
      *"$candidate_separator"*) ;;
      *) TRIM_SEPARATOR="$candidate_separator"; break ;;
    esac
  done
  if [ -z "$TRIM_SEPARATOR" ]; then
    NO_STDOUT_REASON="policy reminder contains all reserved output-trim separators"
    return 0
  fi
  TRIM_RESULT=""
  if ! TRIM_RESULT="$(LC_ALL=C awk -v ceiling="$FIT_CEILING" -v shown="$OUTPUT_CEILING" -v sep="$TRIM_SEPARATOR" -v soft_only="${TRIM_SOFT_ONLY:-0}" -v ttl_min="$((SEEN_TTL / 60))" -v malformed="$MALFORMED_SLUGS" '
          BEGIN { n=split(malformed, ma, " "); for (i=1; i<=n; i++) if (ma[i]!="") malf[ma[i]]=1 }
          {
            lines[NR]=$0
            total_bytes += length($0) + 1
            if ($0 ~ /^> Policy `/ && $0 !~ /^> Policy `[^`]*` \(HARD .* (binding rule|Rule section) from `/) {
              policy_line[NR]=($0 ~ / \[HARD · / ? 2 : 1)
              # A malformed-trigger fallback row did not match this event:
              # whatever its tier, it is the first line to go.
              slug=$0; sub(/^> Policy `/, "", slug); sub(/`.*$/, "", slug)
              if (slug in malf) policy_line[NR]=0
            }
          }
          END {
            # Cut order: soft and unset lines bottom-up first, then HARD
            # summary lines bottom-up; with soft_only, soft and unset only.
            # A HARD rule that matched this event outranks any soft hint
            # under the ceiling, whatever group order put the lines in.
            order_n=0
            for (i=NR; i>=1; i--) if ((i in policy_line) && policy_line[i]==0) order[++order_n]=i
            for (i=NR; i>=1; i--) if ((i in policy_line) && policy_line[i]==1) order[++order_n]=i
            if (!soft_only) for (i=NR; i>=1; i--) if ((i in policy_line) && policy_line[i]==2) order[++order_n]=i
            removed_bytes=0
            candidate_cut=0
            chosen_cut=0
            for (k=1; k<=order_n; k++) {
              i=order[k]
              removed_bytes += length(lines[i]) + 1
              candidate_cut++
              notice = "> Output ceiling of " shown " bytes: " candidate_cut " lower-ranked policy line(s) held for a later call; see the policy files."
              candidate_bytes = total_bytes - removed_bytes + length(notice) + 1
              if (candidate_bytes <= ceiling) {
                chosen_cut=candidate_cut
                chosen_bytes=candidate_bytes
                chosen_notice=notice
                break
              }
            }
            if (!chosen_cut) {
              printf "%snone%s%d%s0", sep, sep, candidate_cut, sep
              exit
            }
            hard_cut=0
            for (k=1; k<=chosen_cut; k++) { drop[order[k]]=1; if (policy_line[order[k]]==2) hard_cut++ }
            # The budget notice counted the HARD summary lines before the
            # cut (oversize and malformed summary lines excluded). Recount
            # from the surviving lines so the number stays true whatever the
            # cut removed: a surviving `[HARD · ` line that is neither a
            # malformed fallback nor named in the per-policy-limit notice.
            # The replacement is never longer than the original, so the fit
            # computed above still holds.
            if (hard_cut > 0) {
              over=""
              for (i=1; i<=NR; i++) if (match(lines[i], /^> Over the [0-9]+-byte per-policy limit, so shortened to one-line summaries — /)) {
                over=substr(lines[i], RLENGTH+1); sub(/\. Read each in full.*$/, "", over)
              }
              no=split(over, oa, ", "); for (i=1; i<=no; i++) if (oa[i]!="") overs[oa[i]]=1
              n_hard=0
              for (i=1; i<=NR; i++) {
                if ((i in drop) || !(i in policy_line) || policy_line[i]!=2) continue
                slug=lines[i]; sub(/^> Policy `/, "", slug); sub(/`.*$/, "", slug)
                if (!(slug in overs)) n_hard++
              }
              for (i=1; i<=NR; i++) {
                if (match(lines[i], /^> Output budget [0-9]+ bytes: [0-9]+ HARD polic(y|ies) listed as one line/)) {
                  head=lines[i]; sub(/: [0-9]+ HARD polic(y|ies) listed as one line.*$/, "", head)
                  rest=substr(lines[i], RLENGTH+1)
                  if (n_hard > 0) lines[i]=head ": " n_hard " HARD polic" (n_hard==1 ? "y" : "ies") " listed as one line" rest
                  else if (rest ~ /^; /) lines[i]=head ": " substr(rest, 3)
                  else drop[i]=1
                  break
                }
              }
            }
            for (i=1; i<=NR; i++) {
              if (lines[i] == "</policy-reminder>") {
                printf "%s\n", chosen_notice
                printf "%s", lines[i]
                if (i < NR) printf "\n"
              } else if (!(i in drop)) {
                printf "%s\n", lines[i]
              }
            }
            printf "%sfit%s%d%s%d", sep, sep, chosen_cut, sep, chosen_bytes
          }
      ' <<<"$OUT")"; then
    NO_STDOUT_REASON="output ceiling trim calculation failed"
    return 0
  fi
  trim_bytes="${TRIM_RESULT##*"$TRIM_SEPARATOR"}"
  trim_before_bytes="${TRIM_RESULT%"$TRIM_SEPARATOR"*}"
  trim_cut="${trim_before_bytes##*"$TRIM_SEPARATOR"}"
  trim_before_cut="${trim_before_bytes%"$TRIM_SEPARATOR"*}"
  trim_status="${trim_before_cut##*"$TRIM_SEPARATOR"}"
  trimmed_out="${trim_before_cut%"$TRIM_SEPARATOR"*}"
  case "$trim_cut" in ''|*[!0-9]*)
    NO_STDOUT_REASON="output ceiling trim result had an invalid cut count"
    return 0
    ;;
  esac
  case "$trim_status" in
    fit)
      case "$trim_bytes" in ''|*[!0-9]*)
        NO_STDOUT_REASON="output ceiling trim result had an invalid byte count"
        return 0
        ;;
      esac
      OUT="$trimmed_out"
      OUT_BYTES="$trim_bytes"
      TRIM_CUT="$trim_cut"
      TRIM_STATUS="fit"
      ;;
    none)
      TRIM_CUT="$trim_cut"
      TRIM_STATUS="none"
      ;;
    *)
      NO_STDOUT_REASON="output ceiling trim result had an unknown status"
      ;;
  esac
}

# keep_top_reminder <full-bytes> [n] — when the full emission is over the
# ceiling, try keeping the full text of the top n (default 1) HARD rules
# (MATCHES is ordered by relevance to this trigger) and summarising every
# other HARD rule. Sets OUT/OUT_BYTES and returns 0 when that fits under
# FIT_CEILING; returns 1 otherwise.
keep_top_reminder() {
  local keep_out keep_slug keep_names="" keep_line full_bytes="$1" keep_n="${2:-1}"
  case "$FULL_OUT" in
    *'(HARD — binding rule from `'*|*'(HARD — Rule section from `'*) ;;
    *) return 1 ;;
  esac
  keep_out="$(HARD_FULL_KEEP="$keep_n" emit_reminder)"
  case "$keep_out" in
    *'(HARD — binding rule from `'*|*'(HARD — Rule section from `'*) ;;
    *) return 1 ;;
  esac
  while IFS= read -r keep_line; do
    case "$keep_line" in
      '> Policy `'*'` (HARD — binding rule from `'*|'> Policy `'*'` (HARD — Rule section from `'*)
        keep_slug="${keep_line#'> Policy `'}"
        keep_slug="${keep_slug%%'`'*}"
        keep_names="${keep_names:+$keep_names, }\`${keep_slug}\`"
        ;;
    esac
  done <<< "$keep_out"
  case "$keep_names" in
    *', '*) keep_line="HARD policies ${keep_names} keep their full text as the top-ranked matches" ;;
    *) keep_line="HARD policy ${keep_names} keeps its full text as the top-ranked match" ;;
  esac
  OUT="${keep_out%</policy-reminder>*}> Output ceiling of ${OUTPUT_CEILING} bytes would have been exceeded (${full_bytes} bytes with full text): ${keep_line}; the other HARD policies above are listed as one line (a listed line is parked for this trigger for $((SEEN_TTL / 60)) min; a cut line is held for a later call). Read a listed rule at its file now if this task touches it.
</policy-reminder>"
  policy_value_bytes "$OUT"
  OUT_BYTES=$((POLICY_VALUE_BYTES + 1))
  [ "$OUT_BYTES" -gt "$FIT_CEILING" ] || return 0
  trim_policy_lines
  if [ "$TRIM_STATUS" = "fit" ]; then
    return 0
  fi
  NO_STDOUT_REASON=""
  return 1
}

fit_reminder_inner() {
  FIT_CEILING="$1"
  OUT="$FULL_OUT"
  NO_STDOUT_REASON=""
  policy_value_bytes "$OUT"
  OUT_BYTES=$((POLICY_VALUE_BYTES + 1))
  if [ "$OUT_BYTES" -gt "$FIT_CEILING" ] && [ "$HARD_FULL" != "0" ]; then
    # Too big for the host to deliver.
    local full_bytes="$OUT_BYTES" keep_n full_n=0 full_line
    local slug scope path enf rule kind injv ws spec stale exempt rel tkey score specific_n=0 reactive_hard_n=0
    while IFS=$'\t' read -r slug scope path enf rule kind injv ws spec stale exempt rel tkey score; do
      [ "$enf" = "hard" ] && [ "$kind" = "reactive" ] && [ "$ws" != "malformed" ] || continue
      reactive_hard_n=$((reactive_hard_n + 1))
      [ "$rel" = "specific" ] && specific_n=$((specific_n + 1))
    done <<< "$MATCHES"
    # When a HARD rule matched this event, first drop soft and unset lines,
    # lowest-ranked first, and keep every HARD rule as it is.
    if [ "$reactive_hard_n" -gt 0 ]; then
      TRIM_SOFT_ONLY=1 trim_policy_lines
      if [ "$TRIM_STATUS" = "fit" ]; then
        return 0
      fi
      OUT="$FULL_OUT"
      NO_STDOUT_REASON=""
    fi
    # Then keep the top-ranked HARD rule in full and summarise the rest. When
    # several HARD rules matched specifically, keep as many of them as fit
    # (most first). Cutting low-ranked index lines is allowed, but a kept
    # rule's text never is.
    while IFS= read -r full_line; do
      case "$full_line" in '> Policy `'*'` (HARD — binding rule from `'*|'> Policy `'*'` (HARD — Rule section from `'*) full_n=$((full_n + 1)) ;; esac
    done <<< "$FULL_OUT"
    # Start below the full-text count of FULL_OUT, which did not fit.
    keep_n=$((full_n - 1))
    [ "$keep_n" -le "$specific_n" ] || keep_n="$specific_n"
    [ "$keep_n" -ge 1 ] || keep_n=1
    while [ "$keep_n" -ge 1 ]; do
      if keep_top_reminder "$full_bytes" "$keep_n"; then
        return 0
      fi
      keep_n=$((keep_n - 1))
    done
    # Even that does not fit: fall back to one-line summaries for every
    # policy, and say so. A shortened set the model can read beats a full set
    # it never sees. keep_top_reminder overwrote OUT_BYTES, so report the
    # full-text size saved above.
    OUT="$(HARD_FULL=0 emit_reminder)"
    OUT="${OUT%</policy-reminder>*}> Output ceiling of ${OUTPUT_CEILING} bytes would have been exceeded (${full_bytes} bytes with full text): every HARD policy above is listed as one line (a listed line is parked for this trigger for $((SEEN_TTL / 60)) min; a cut line is held for a later call). Read a listed rule at its file now if this task touches it.
</policy-reminder>"
    policy_value_bytes "$OUT"
    OUT_BYTES=$((POLICY_VALUE_BYTES + 1))
  fi
  if [ "$OUT_BYTES" -gt "$FIT_CEILING" ]; then
    # Still over even as summaries: calculate the first fitting cut count in
    # one byte-oriented awk pass. The old loop rebuilt, measured, searched and
    # edited the reminder once per dropped policy line.
    trim_policy_lines
        case "$TRIM_STATUS" in
          fit) ;;
          none)
            # Policy lines cannot make room for an oversized withheld/malformed
            # notice. Preserve the more informative existing fallback whenever
            # it fits; only then shrink again to the compact form.
            cut="$TRIM_CUT"
            if [ "$cut" -gt 0 ]; then
              last_resort="<policy-reminder>
> Output ceiling of ${OUTPUT_CEILING} bytes: ${cut} lower-ranked policy line(s) cut from this reminder. Remaining reminder text was omitted to keep this event deliverable; see the policy files.
</policy-reminder>"
            else
              last_resort="<policy-reminder>
> Output ceiling of ${OUTPUT_CEILING} bytes: remaining reminder text was omitted to keep this event deliverable; see the policy files.
</policy-reminder>"
            fi
            policy_value_bytes "$last_resort"
            last_resort_bytes=$((POLICY_VALUE_BYTES + 1))
            if [ "$last_resort_bytes" -le "$FIT_CEILING" ]; then
              OUT="$last_resort"
              OUT_BYTES="$last_resort_bytes"
            else
              # The compact reminder is deliberately measured too: a ceiling
              # below its useful 76-byte floor must not leak a fixed-size fallback.
              compact_out="$(compact_reminder)"
              policy_value_bytes "$compact_out"
              compact_bytes=$((POLICY_VALUE_BYTES + 1))
              if [ "$compact_bytes" -le "$FIT_CEILING" ]; then
                OUT="$compact_out"
                OUT_BYTES="$compact_bytes"
              else
                OUT=""
                OUT_BYTES=0
                NO_STDOUT_REASON="HQ_POLICY_OUTPUT_CEILING_BYTES=${OUTPUT_CEILING} is below the ${compact_bytes}-byte minimum reminder"
              fi
            fi
            ;;
          *)
            OUT=""
            OUT_BYTES=0
            [ -n "${NO_STDOUT_REASON:-}" ] || NO_STDOUT_REASON="output ceiling trim result had an unknown status"
            ;;
        esac
  fi
}
# fit_reminder <ceiling> — fit_reminder_inner. Rows the ceiling cuts stay
# unrecorded and eligible; the cut notice counts them.
fit_reminder() {
  fit_reminder_inner "$@"
}
fit_reminder "$OUTPUT_CEILING"
# Footer-only repeat: once every matched HARD
# row has been delivered, each later event that matches the same rows emits a
# reminder whose only line is the "Already shown this session" footer. That
# block carried no new rule but was attached to every tool result. Emit a
# footer-only reminder only when its text differs from the last footer this
# session emitted, or when that footer is older than SEEN_TTL; otherwise emit
# nothing. A reminder with any policy line or notice is never suppressed, and
# the session and seen ledgers are untouched, so what binds is unchanged.
# HQ_POLICY_FOOTER_REPEAT=1 restores the footer on every event.
FOOTER_FILE="$DEDUPE_DIR/${SESSION_ID:-default}.footer.txt"
footer_only_reminder() {
  [ -n "$ALREADY_FOOTER" ] || return 1
  [ "$OUT" = "<policy-reminder>"$'\n'"$ALREADY_FOOTER"$'\n'"</policy-reminder>" ]
}
footer_repeat_is_fresh() {
  local stamp="" text="" now=""
  [ -n "${SESSION_ID:-}" ] && [ -f "$FOOTER_FILE" ] || return 1
  { IFS= read -r stamp; IFS= read -r text; } < "$FOOTER_FILE" 2>/dev/null || true
  [ "$text" = "$ALREADY_FOOTER" ] || return 1
  case "$stamp" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s 2>/dev/null || true)"
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ $((now - stamp)) -ge 0 ] && [ $((now - stamp)) -lt "$SEEN_TTL" ]
}
record_emitted_footer() {
  [ -n "${SESSION_ID:-}" ] && [ -n "$ALREADY_FOOTER" ] || return 0
  case "$OUT" in *"$ALREADY_FOOTER"*) ;; *) return 0 ;; esac
  local tmp=""
  tmp="$(mktemp "$DEDUPE_DIR/.footer.XXXXXX" 2>/dev/null)" || return 0
  if printf '%s\n%s\n' "$(date +%s 2>/dev/null || echo 0)" "$ALREADY_FOOTER" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$FOOTER_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}
if [ -z "${NO_STDOUT_REASON:-}" ] && [ -n "$OUT" ] && [ "${HQ_POLICY_FOOTER_REPEAT:-0}" != "1" ] \
  && footer_only_reminder && footer_repeat_is_fresh; then
  OUT=""
fi
HOOK_OUTPUT="$OUT"
if [ -z "${NO_STDOUT_REASON:-}" ] && [ -n "$OUT" ]; then
  if [ "$EVENT" = "PostToolUse" ]; then
    # Native Claude Code only treats plain stdout as context on selected events;
    # PostToolUse requires event-specific JSON additionalContext. Codex's adapter
    # also understands this shape and flattens it back into the same context.
    HOOK_OUTPUT="$(jq -cn --arg event "$EVENT" --arg context "$OUT" \
      '{hookSpecificOutput:{hookEventName:$event,additionalContext:$context}}' 2>/dev/null)"
    if [ -z "$HOOK_OUTPUT" ]; then
      NO_STDOUT_REASON="could not encode PostToolUse additionalContext"
    fi
  fi
fi
if [ -n "$HOOK_OUTPUT" ]; then
  policy_value_bytes "$HOOK_OUTPUT"
  OUT_BYTES=$((POLICY_VALUE_BYTES + 1))
  # JSON quoting (escaped quotes, backslashes and newlines) can grow the
  # PostToolUse envelope past the ceiling. Refit the reminder under a ceiling
  # reduced by the measured overflow, so the policies that fit are delivered
  # and recorded. The old fallback replaced everything with "Policies
  # matched.", recorded nothing, and so re-fired the same oversized set on
  # every later tool call.
  refit_attempt=0
  refit_ceiling="$OUTPUT_CEILING"
  while [ "$OUT_BYTES" -gt "$OUTPUT_CEILING" ] && [ "$EVENT" = "PostToolUse" ] \
    && [ "$refit_attempt" -lt 4 ]; do
    refit_attempt=$((refit_attempt + 1))
    refit_ceiling=$((refit_ceiling - (OUT_BYTES - OUTPUT_CEILING) - 64))
    [ "$refit_ceiling" -gt 0 ] || break
    fit_reminder "$refit_ceiling"
    if [ -n "${NO_STDOUT_REASON:-}" ] || [ -z "$OUT" ]; then OUT_BYTES=$((OUTPUT_CEILING + 1)); break; fi
    HOOK_OUTPUT="$(jq -cn --arg event "$EVENT" --arg context "$OUT" \
      '{hookSpecificOutput:{hookEventName:$event,additionalContext:$context}}' 2>/dev/null)"
    [ -n "$HOOK_OUTPUT" ] || break
    policy_value_bytes "$HOOK_OUTPUT"
    OUT_BYTES=$((POLICY_VALUE_BYTES + 1))
  done
  NO_STDOUT_REASON=""
  if [ "$OUT_BYTES" -gt "$OUTPUT_CEILING" ] && [ "$EVENT" = "PostToolUse" ]; then
    # Still over: retry with a compact, valid envelope and suppress it if
    # even that cannot fit.
    OUT='Policies matched.'
    HOOK_OUTPUT="$(jq -cn --arg event "$EVENT" --arg context "$OUT" \
      '{hookSpecificOutput:{hookEventName:$event,additionalContext:$context}}' 2>/dev/null)"
    if [ -n "$HOOK_OUTPUT" ]; then
      policy_value_bytes "$HOOK_OUTPUT"
      OUT_BYTES=$((POLICY_VALUE_BYTES + 1))
    else
      OUT_BYTES=0
    fi
    if [ "$OUT_BYTES" -gt "$OUTPUT_CEILING" ]; then
      HOOK_OUTPUT=""
      OUT_BYTES=0
      NO_STDOUT_REASON="HQ_POLICY_OUTPUT_CEILING_BYTES=${OUTPUT_CEILING} is below the minimum PostToolUse envelope"
    fi
  fi
  if [ -n "$HOOK_OUTPUT" ]; then
    record_emitted_match_rows "$MATCHES" "$OUT"
    record_malformed_notice "$OUT"
    record_emitted_footer
  fi
else
  OUT_BYTES=0
fi
# Emission stats (2026-09-07): one line per event so a live smoke or benchmark
# can prove, per session and per runtime, that every reminder stayed under the
# host ceiling. OUT_BYTES is the final stdout byte count, including a PostToolUse
# JSON envelope. Cheap append; failure is ignored.
{ [ -d "$STATS_DIR" ] || mkdir -p "$STATS_DIR" 2>/dev/null \
  && printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EVENT" "$OUT_BYTES" "$MATCH_COUNT" >> "$STATS_DIR/${SESSION_ID:-unknown}.txt"; } 2>/dev/null || true
if [ -n "${NO_STDOUT_REASON:-}" ]; then
  printf 'inject-policy-on-trigger: %s; emitted no stdout.\n' "$NO_STDOUT_REASON" >&2
else
  [ -z "$HOOK_OUTPUT" ] || printf '%s\n' "$HOOK_OUTPUT"
fi

exit 0
