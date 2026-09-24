#!/bin/bash
# Hosts like Claude Code export BASH_ENV to a user profile; each non-interactive
# bash on the hook path then pays nvm (~1-11s). Measured 2026-09-21 macOS:
# adapter 18-32s, bridge 28s, master-hook 4.5s; with BASH_ENV=/dev/null: 4.0s / 3.5s.
export BASH_ENV=/dev/null
# Master hook — dispatches a hook event to the active company's hook scripts.
#
# Usage (from settings.json):
#   .claude/hooks/master-hook.sh <event-name>
#
# Active company resolution (fail-closed for tenant isolation):
#   - Read session_id from stdin payload.
#   - Bootstrap workspace/sessions/<session_id>/meta.yaml on first event of
#     the session (with session_id, started_at, and senior: user). Update
#     workspace/sessions/.current to point at it.
#   - Read company_slug from meta.yaml. If unset, run NO company hooks.
#     This is intentional — startwork (or any skill) is responsible for
#     calling `core/scripts/hq-session.sh set company_slug <slug>` once context
#     is resolved. Until that happens, only top-level .claude/hooks fire.
#
# Discovery (in dispatch order):
#   .claude/hooks/hook-registry.json              — the gated project hooks
#                                                   (formerly one settings.json
#                                                   registration each; now run
#                                                   in-process, see below)
#   core/hooks/<event-name>/*.sh                  — always-on repo defaults
#   personal/hooks/<event-name>/*.sh              — always-on user-global
#   core/packages/*/hooks/<event-name>/*.sh       — always-on per installed pack
#   companies/<active-slug>/hooks/<event-name>/*.sh — active-company only
#
# Filename convention:
#   <NN>-<matcher>--<name>.sh   tool-scoped (PreToolUse/PostToolUse only)
#   <NN>-<name>.sh              no matcher — always runs
#   <name>.sh                   no matcher — always runs
#
#   <matcher> is a regex anchored with ^...$. Two conveniences:
#     `*` is rewritten to `.*`   (so `mcp__Claude_in_Chrome__*` works)
#     `,` is rewritten to `|`    (so `Write,Edit` is portable; `|` also works)
#
# Behavior:
#   - Reads stdin once and re-pipes it to each matched hook.
#   - Runs hooks in alphabetical order (by basename within the company dir).
#   - For PreToolUse/PostToolUse, scripts with a matcher segment are skipped
#     when `tool_name` from stdin doesn't match. Other events ignore the
#     matcher segment.
#   - Output handling — segregates each hook's stdout by shape:
#       * Plain-text outputs are concatenated and emitted verbatim.
#       * JSON outputs (single top-level object, parseable by jq) are merged
#         into a single object emitted at the end:
#           - First hook returning {"decision":"block", ...} wins (preserves
#             the "any hook can short-circuit" semantic from settings.json).
#           - Otherwise the JSON outputs are shallow-merged in order; later
#             keys overwrite earlier. hookSpecificOutput.updatedInput is
#             merged the same way (later wins) so chained transforms compose.
#             hookSpecificOutput.additionalContext is the exception: non-empty
#             values compose in hook order, separated by a blank line.
#   - Exit code: any blocking exit (2) wins; otherwise the first non-zero exit,
#     else 0.
#
# Registry dispatch (performance, Windows Git Bash in particular):
#   Every settings.json registration costs a gate bash, a watchdog, and a body
#   bash before the hook does any work; on Windows that floor is ~1 s per hook
#   and a Bash tool call carried 34 of them (~66 s measured). The registry
#   moves those hooks under this one dispatcher: stdin is read once, the
#   profile and HQ_DISABLED_HOOKS are evaluated in-process via
#   hook-gate.sh --lib, PATH is augmented once, one watchdog is armed for the
#   whole fire, and each entry's optional prefilter (a POSIX ERE over the tool_input
#   JSON text or prompt, an env var, or a file that must exist) skips hooks whose input
#   cannot trigger them. Prefilters must be supersets of the hook's own
#   trigger; the hook body is still the decision maker. Each child runs under
#   its own registry timeout (coreutils timeout, else perl alarm).

set -uo pipefail

master_now_ms() {
  local realtime seconds fraction now
  realtime="${EPOCHREALTIME:-}"
  if [ -n "$realtime" ]; then
    seconds="${realtime%%.*}"
    fraction="${realtime#*.}"
    fraction="${fraction}000"
    fraction="${fraction:0:3}"
    if [[ "$seconds" =~ ^[0-9]+$ ]] && [[ "$fraction" =~ ^[0-9]{3}$ ]]; then
      printf '%s%s' "$seconds" "$fraction"
      return 0
    fi
  fi
  now="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$now" =~ ^[0-9]+$ ]] && [ "${#now}" -gt 10 ]; then
    printf '%s' "$now"
    return 0
  fi
  if command -v perl >/dev/null 2>&1; then
    now="$(perl -MTime::HiRes=time -e 'printf "%.0f", time() * 1000' 2>/dev/null || true)"
    if [[ "$now" =~ ^[0-9]+$ ]]; then
      printf '%s' "$now"
      return 0
    fi
  fi
  now="$(date +%s 2>/dev/null || printf '0')"
  [[ "$now" =~ ^[0-9]+$ ]] || now=0
  printf '%s000' "$now"
}

master_timing_precision() {
  local candidate=""
  [ -n "${EPOCHREALTIME:-}" ] && { printf 'ms'; return; }
  candidate="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$candidate" =~ ^[0-9]+$ ]] && [ "${#candidate}" -gt 10 ]; then
    printf 'ms'
    return
  fi
  if command -v perl >/dev/null 2>&1; then
    candidate="$(perl -MTime::HiRes=time -e 'printf "%.0f", time() * 1000' 2>/dev/null || true)"
    if [[ "$candidate" =~ ^[0-9]+$ ]]; then
      printf 'ms'
      return
    fi
  fi
  printf 's'
}

EVENT="${1:-}"
if [ -z "$EVENT" ]; then
  echo "USAGE: master-hook.sh <event-name>" >&2
  # Drain first so a misregistered dispatcher reports THIS usage error (1)
  # rather than SIGPIPE-killing the harness's payload writer and surfacing as
  # 141 under pipefail.
  cat >/dev/null 2>&1 || true
  exit 1
fi

# One subshell each; dirname is avoided (a fork costs ~50 ms on Windows).
case "$0" in
  */*) SCRIPT_DIR="$(cd "${0%/*}" && pwd)" ;;
  *) SCRIPT_DIR="$(pwd)" ;;
esac
. "$SCRIPT_DIR/hook-timeout-probe.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MASTER_TRACE_START="${EPOCHREALTIME:-}"
INPUT="$(cat)"
MASTER_STARTED_MS="$(master_now_ms)"
MASTER_TIMING_PRECISION="$(master_timing_precision)"

# Shared gate helpers (profile lists, disabled list, PATH augmentation),
# loaded from hook-gate.sh in library mode so there is a single definition.
if [ -f "$SCRIPT_DIR/hook-gate.sh" ]; then
  . "$SCRIPT_DIR/hook-gate.sh" --lib
  hq_augment_path
fi

# Windows Git Bash: process creation is 10-30x macOS cost and the watchdog
# sentry is two extra setsid processes per fire. Default it off there unless
# the operator set HQ_HOOK_TIMEOUT_SENTRY explicitly.
case "${OSTYPE:-}" in
  msys*|cygwin*|win32*) : "${HQ_HOOK_TIMEOUT_SENTRY:=0}" ;;
esac

# Master registrations own one timeout budget, while their discovered children
# have none of their own. A single dispatcher watchdog covers discovery, the
# no-child path, and every child execution. This avoids per-child watchdog
# process startup on the hot path and reports the master registration deadline.
HOOK_TIMEOUT_WATCHDOG="$SCRIPT_DIR/hook-timeout-watchdog.sh"
master_timeout_watchdog_pids=()
master_timeout_watchdog_sessions=()
master_timeout_started_at="0"

master_timeout_watchdog_disabled() {
  local entry remaining
  remaining="${HQ_DISABLED_HOOKS:-}"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      *,*) entry="${remaining%%,*}"; remaining="${remaining#*,}" ;;
      *) entry="$remaining"; remaining="" ;;
    esac
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ "$entry" = "hook-timeout-sentry" ] && return 0
  done
  return 1
}

master_timeout_watchdog_enabled() {
  case "${HQ_HOOK_TIMEOUT_SENTRY:-1}" in
    0|false|FALSE|no|NO|off|OFF) return 1 ;;
  esac
  master_timeout_watchdog_disabled && return 1
  [ -f "$HOOK_TIMEOUT_WATCHDOG" ]
}

master_timeout_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s\0' "$@" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s\0' "$@" | sha256sum 2>/dev/null | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s\0' "$@" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
  fi
}

MASTER_INVOCATION_ID="$(master_timeout_sha256 "$$" "$MASTER_STARTED_MS" "$EVENT" 2>/dev/null || true)"
[ -n "$MASTER_INVOCATION_ID" ] || MASTER_INVOCATION_ID="$$-$MASTER_STARTED_MS"

stop_master_timeout_watchdog() {
  local i pid session
  for i in "${!master_timeout_watchdog_pids[@]}"; do
    pid="${master_timeout_watchdog_pids[$i]}"
    session="${master_timeout_watchdog_sessions[$i]}"
    if [ "$session" -eq 1 ]; then
      # Cover the tiny interval before setsid establishes the process group,
      # then interrupt the whole established watchdog session.
      kill -TERM "$pid" >/dev/null 2>&1 || true
      kill -TERM -- "-$pid" >/dev/null 2>&1 || true
    else
      kill "$pid" >/dev/null 2>&1 || true
    fi
    # Reap the session leader while its initial watchdog sleep is interruptible.
    # This gives master dispatch deterministic cleanup without foreground
    # configuration parsing or a lingering child process.
    wait "$pid" >/dev/null 2>&1 || true
  done
  master_timeout_watchdog_pids=()
  master_timeout_watchdog_sessions=()
  if [ -n "${timeout_journal_file:-}" ] && [ -n "${MASTER_INVOCATION_ID:-}" ]; then
    rm -f "$timeout_journal_file.$MASTER_INVOCATION_ID.active" >/dev/null 2>&1 || true
  fi
}

arm_master_timeout_watchdog() {
  local source_kind="$1" watched_path="$2" threshold session=0
  master_timeout_watchdog_enabled || return 0
  for threshold in absolute relative; do
    session=0
    if command -v setsid >/dev/null 2>&1; then
      setsid bash "$HOOK_TIMEOUT_WATCHDOG" \
        --root "$REPO_ROOT" \
        --source "$source_kind" \
        --hook-path "$watched_path" \
        --event "$EVENT" \
        --threshold "$threshold" \
        --started-at "$master_timeout_started_at" \
        --invocation-id "$MASTER_INVOCATION_ID" \
        --parent-pid "$$" \
        >/dev/null 2>&1 <<<"$INPUT" &
      session=1
    else
      bash "$HOOK_TIMEOUT_WATCHDOG" \
        --root "$REPO_ROOT" \
        --source "$source_kind" \
        --hook-path "$watched_path" \
        --event "$EVENT" \
        --threshold "$threshold" \
        --started-at "$master_timeout_started_at" \
        --invocation-id "$MASTER_INVOCATION_ID" \
        --parent-pid "$$" \
        >/dev/null 2>&1 <<<"$INPUT" &
    fi
    master_timeout_watchdog_pids+=("$!")
    master_timeout_watchdog_sessions+=("$session")
  done
}

if master_timeout_watchdog_enabled; then
  master_timeout_started_at="${EPOCHSECONDS:-$(date +%s 2>/dev/null || printf '0')}"
  arm_master_timeout_watchdog master-dispatch "$SCRIPT_DIR/master-hook.sh"
  trap stop_master_timeout_watchdog EXIT
fi

is_tool_event() {
  case "$1" in
    PreToolUse|PostToolUse) return 0 ;;
    *) return 1 ;;
  esac
}

parse_matcher() {
  local stem="${1%.sh}"
  local full="${2:-}"
  if [[ "$stem" != *"--"* ]]; then
    # No filename matcher. Check for a '# hq-hook-match:' frontmatter line so a
    # hook can carry a tool matcher containing characters that are illegal in
    # Windows filenames (e.g. '*', which causes ERROR_INVALID_NAME on NTFS and
    # makes 'git checkout' of the whole pack fail on Windows). Falls back to
    # empty (always-run) when absent, identical to prior behaviour for plain
    # <NN>-<name>.sh hooks.
    if [ -n "$full" ] && [ -f "$full" ]; then
      # Scan the leading comment block in-process (no sed/head/tr forks).
      local line n=0
      while IFS= read -r line && [ "$n" -lt 40 ]; do
        n=$((n + 1))
        case "$line" in
          \#*hq-hook-match:*)
            line="${line#*hq-hook-match:}"
            line="${line#"${line%%[![:space:]]*}"}"
            printf '%s' "$line"
            return
            ;;
        esac
      done < "$full"
    fi
    return
  fi
  local prefix="${stem%%--*}"
  if [[ "$prefix" =~ ^[0-9]+-(.+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$prefix"
  fi
}

matches_tool() {
  local matcher="$1" tool="$2"
  [ -z "$matcher" ] && return 0
  [ -z "$tool" ] && return 1
  local re="${matcher//\*/.*}"
  re="${re//,/|}"
  [[ "$tool" =~ ^(${re})$ ]]
}

# One jq call extracts every payload field the dispatcher needs.
TOOL_NAME=""
MATCH_KEY=""
SESSION_ID=""
PREFILTER_TEXT=""
PAYLOAD_CWD=""
PAYLOAD_AGENT_ID=""
{
  IFS=$'\x1f' read -r TOOL_NAME MATCH_KEY SESSION_ID PAYLOAD_CWD PAYLOAD_AGENT_ID PREFILTER_TEXT || true
} < <(printf '%s' "$INPUT" | jq -r --arg ev "$EVENT" '
  [ (.tool_name // ""),
    (if ($ev == "PreToolUse" or $ev == "PostToolUse") then (.tool_name // "")
     elif $ev == "PreCompact" then (.trigger // "")
     elif $ev == "SessionStart" then (.source // "")
     else "" end),
    (.session_id // ""),
    (.cwd // ""),
    (.agent_id // "" | tostring),
    ((if (.tool_input | type) == "object" then (.tool_input | tojson) else (.prompt // "") end)
     + (if $ev == "PostToolUse" and .tool_response != null then " " + (.tool_response | tojson) else "" end))
  ] | map(gsub("\u001f|\n"; " ")) | join("\u001f")' 2>/dev/null || printf '\n')
is_tool_event "$EVENT" || TOOL_NAME=""

# A Monitor timeout notice is system status text, not a user request. Keep
# request-routing/title and slow maintenance/status enrichers off this exact
# path; preserve the worktree guard, policy injection, turn start, and unknown
# hooks. The next actionable prompt receives the normal dispatch.
MONITOR_EXPIRY_NOTIFICATION=0
if [ "$EVENT" = "UserPromptSubmit" ] \
  && [ "$PREFILTER_TEXT" = "[Monitor timed out — re-arm if needed.]" ]; then
  MONITOR_EXPIRY_NOTIFICATION=1
fi

# Hand the already-parsed fields to children. A hook can use
# "${HQ_HOOK_TOOL_NAME+set}" style checks to skip its own jq parse (one jq is
# ~130 ms on Windows Git Bash). Values are exported even when empty so a hook
# can distinguish "known empty" from "not provided".
export HQ_HOOK_EVENT="$EVENT"
export HQ_HOOK_TOOL_NAME="$TOOL_NAME"
export HQ_HOOK_SESSION_ID="$SESSION_ID"
export HQ_HOOK_CWD="$PAYLOAD_CWD"
export HQ_HOOK_AGENT_ID="$PAYLOAD_AGENT_ID"
# Prefilters match against the tool input (command, file_path, content, ...)
# or the prompt, never the whole payload: cwd/session paths must not trigger
# path-shaped regexes. Newlines inside the text are flattened to spaces, which
# is fine for superset matching.

# --- Resolve active company via workspace/sessions/<session_id>/meta.yaml ---
ACTIVE_COMPANY=""
if [ -n "$SESSION_ID" ]; then
  SESSIONS_DIR="$REPO_ROOT/workspace/sessions"
  SESSION_DIR="$SESSIONS_DIR/$SESSION_ID"
  META_FILE="$SESSION_DIR/meta.yaml"
  mkdir -p "$SESSION_DIR"
  if [ ! -f "$META_FILE" ]; then
    printf 'session_id: %s\nstarted_at: "%s"\nsenior: user\n' \
      "$SESSION_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$META_FILE"
  fi
  printf '%s\n' "$SESSION_ID" > "$SESSIONS_DIR/.current"
  ACTIVE_COMPANY="$(awk '$1 == "company_slug:" { sub(/^[^:]+:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$META_FILE")"
fi

master_bash_env_state() {
  if [ -n "${BASH_ENV:-}" ]; then
    printf 'set'
  else
    printf 'unset'
  fi
}

master_shell_descriptor() {
  local shell_name="${BASH:-bash}" shell_version="${BASH_VERSION:-unknown}"
  shell_name="${shell_name##*/}"
  case "$shell_name" in
    *[!A-Za-z0-9._+-]*|'') shell_name="unknown" ;;
  esac
  printf '%s %s' "$shell_name" "$shell_version"
}

master_cwd_kind() {
  local cwd_root="$REPO_ROOT"
  while [ "$cwd_root" != "/" ] && [ "${cwd_root%/}" != "$cwd_root" ]; do
    cwd_root="${cwd_root%/}"
  done
  case "$PAYLOAD_CWD" in
    "$cwd_root") printf 'hq-root' ;;
    "$cwd_root/repos/public/"*|"$cwd_root/repos/private/"*) printf 'repo' ;;
    "$cwd_root/workspace/worktrees/"*) printf 'worktree' ;;
    *) printf 'other' ;;
  esac
}

master_nproc() {
  local result=""
  if command -v getconf >/dev/null 2>&1; then
    result="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi
  if ! [[ "$result" =~ ^[0-9]+$ ]] || [ "$result" -lt 1 ]; then
    if command -v sysctl >/dev/null 2>&1; then
      result="$(sysctl -n hw.ncpu 2>/dev/null || true)"
    fi
  fi
  if ! [[ "$result" =~ ^[0-9]+$ ]] || [ "$result" -lt 1 ]; then
    result=1
  fi
  printf '%s' "$result"
}

timeout_journal_file=""
active_child_file=""
if master_timeout_watchdog_enabled && [ -n "$SESSION_ID" ]; then
  journal_session_hash="$(master_timeout_sha256 "$SESSION_ID")"
  if [ -n "$journal_session_hash" ]; then
    timeout_journal_file="$REPO_ROOT/workspace/.hook-timeout-journal/$journal_session_hash.tsv"
    mkdir -p "${timeout_journal_file%/*}" >/dev/null 2>&1 || timeout_journal_file=""
    [ -z "$timeout_journal_file" ] || active_child_file="$timeout_journal_file.$MASTER_INVOCATION_ID.active"
  fi
fi
if [ -n "$timeout_journal_file" ]; then
  export HQ_HOOK_TIMEOUT_JOURNAL_FILE="$timeout_journal_file"
else
  unset HQ_HOOK_TIMEOUT_JOURNAL_FILE || true
fi

journal_hook_event() {
  local hook_path="$1" elapsed_ms="$2" script
  [ -n "$timeout_journal_file" ] || return 0
  script="${hook_path##*/}"
  case "$script" in
    ''|*[!A-Za-z0-9._-]*) return 0 ;;
  esac
  case "$EVENT" in
    ''|*[!A-Za-z0-9._-]*) return 0 ;;
  esac
  case "$elapsed_ms" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$script" "$EVENT" "$elapsed_ms" "$MASTER_INVOCATION_ID" \
    >> "$timeout_journal_file" 2>/dev/null || true
}

journal_active_child_start() {
  local hook_path="$1" script="${1##*/}" started_ms
  [ -n "$active_child_file" ] || return 0
  case "$script" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$EVENT" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$MASTER_INVOCATION_ID" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  started_ms="$(master_now_ms)"
  [[ "$started_ms" =~ ^[0-9]+$ ]] || return 0
  printf '%s\t%s\t%s\n' "$script" "$EVENT" "$started_ms" \
    > "$active_child_file" 2>/dev/null || true
}

journal_active_child_end() {
  [ -n "$active_child_file" ] || return 0
  : > "$active_child_file" 2>/dev/null || true
}

acquire_journal_compaction_lock() {
  local lock_dir="$timeout_journal_file.lock" owner attempt
  [ -n "$timeout_journal_file" ] || return 1
  for attempt in 1 2; do
    if mkdir "$lock_dir" >/dev/null 2>&1; then
      printf '%s\n' "$$" > "$lock_dir/pid" 2>/dev/null || {
        rm -f "$lock_dir/pid" >/dev/null 2>&1 || true
        rmdir "$lock_dir" >/dev/null 2>&1 || true
        return 1
      }
      return 0
    fi
    owner="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" >/dev/null 2>&1; then
      return 1
    fi
    [ "$attempt" -eq 1 ] || break
    sleep 0.01 >/dev/null 2>&1 || true
  done
  rm -f "$lock_dir/pid" >/dev/null 2>&1 || true
  rmdir "$lock_dir" >/dev/null 2>&1 || return 1
  if mkdir "$lock_dir" >/dev/null 2>&1; then
    printf '%s\n' "$$" > "$lock_dir/pid" 2>/dev/null || {
      rm -f "$lock_dir/pid" >/dev/null 2>&1 || true
      rmdir "$lock_dir" >/dev/null 2>&1 || true
      return 1
    }
    return 0
  fi
  return 1
}

release_journal_compaction_lock() {
  local lock_dir="$timeout_journal_file.lock"
  rm -f "$lock_dir/pid" >/dev/null 2>&1 || true
  rmdir "$lock_dir" >/dev/null 2>&1 || true
}

compact_timeout_journal() {
  local temporary journal_lines
  [ -n "$timeout_journal_file" ] || return 0
  [ -f "$timeout_journal_file" ] || return 0
  journal_lines="$(wc -l < "$timeout_journal_file" 2>/dev/null || printf '0')"
  journal_lines="${journal_lines//[[:space:]]/}"
  [[ "$journal_lines" =~ ^[0-9]+$ ]] || return 0
  [ "$journal_lines" -gt 40 ] || return 0
  acquire_journal_compaction_lock || return 0
  temporary="$timeout_journal_file.tmp.$$"
  if ! tail -n 40 "$timeout_journal_file" > "$temporary" 2>/dev/null; then
    rm -f "$temporary" >/dev/null 2>&1 || true
    release_journal_compaction_lock
    return 0
  fi
  mv -f "$temporary" "$timeout_journal_file" >/dev/null 2>&1 || rm -f "$temporary" >/dev/null 2>&1 || true
  release_journal_compaction_lock
}

master_hook_sequence_json() {
  local sequence
  [ -f "$timeout_journal_file" ] || { printf '[]'; return; }
  compact_timeout_journal
  sequence="$(tail -n 40 "$timeout_journal_file" 2>/dev/null | jq -Rsc '
    split("\n")
    | map(select(length > 0) | split("\t")
      | select((length == 3 or length == 4) and (.[2] | test("^[0-9]+$")))
      | {script: .[0], event: .[1], ms: (.[2] | tonumber)})
    | .[-20:]
  ' 2>/dev/null || true)"
  if [ -n "$sequence" ]; then
    printf '%s' "$sequence"
  else
    printf '[]'
  fi
}

master_policy_trigger_metadata_json() {
  local metadata_file="$timeout_journal_file.meta" key value
  local trigger_script="" trigger_event="" ledger_bucket="" facts_bucket=""
  [ -f "$metadata_file" ] || { printf '{}'; return; }
  while IFS='=' read -r key value; do
    case "$key" in
      policy_trigger_script) trigger_script="$value" ;;
      policy_trigger_event) trigger_event="$value" ;;
      ledger_bytes_bucket) ledger_bucket="$value" ;;
      facts_bytes_bucket) facts_bucket="$value" ;;
    esac
  done < "$metadata_file"
  [ "$trigger_script" = "inject-policy-on-trigger.sh" ] || { printf '{}'; return; }
  case "$ledger_bucket" in '<16K'|'16-64K'|'64-128K'|'>128K') ;; *) printf '{}'; return ;; esac
  case "$facts_bucket" in '<16K'|'16-64K'|'64-128K'|'>128K') ;; *) printf '{}'; return ;; esac
  jq -cn \
    --arg script "$trigger_script" \
    --arg event "$trigger_event" \
    --arg ledger "$ledger_bucket" \
    --arg facts "$facts_bucket" \
    '{policy_trigger_script: $script, policy_trigger_event: $event, ledger_bytes_bucket: $ledger, facts_bytes_bucket: $facts}'
}

write_journal_runtime_metadata() {
  local metadata_file temporary
  [ -n "$timeout_journal_file" ] || return 0
  metadata_file="$timeout_journal_file.meta"
  temporary="$metadata_file.tmp.$$"
  printf 'bash_env_set=%s\ntiming_precision=%s\n' "$(master_bash_env_state)" "$MASTER_TIMING_PRECISION" > "$temporary" 2>/dev/null || {
    rm -f "$temporary" >/dev/null 2>&1 || true
    return 0
  }
  mv -f "$temporary" "$metadata_file" >/dev/null 2>&1 || {
    rm -f "$temporary" >/dev/null 2>&1 || true
    return 0
  }
}

write_journal_runtime_metadata

# A watchdog cannot safely write to the slow hook's stdout: stdout is captured
# until the child exits and is discarded if the harness kills it. Instead it
# atomically leaves a local breadcrumb, which the next master fire consumes into
# hookSpecificOutput.additionalContext exactly once.
pending_timeout_warning=""
pending_breadcrumb_records=()
pending_breadcrumb_claims=()

restore_timeout_breadcrumbs() {
  local i record claim
  for i in "${!pending_breadcrumb_claims[@]}"; do
    record="${pending_breadcrumb_records[$i]}"
    claim="${pending_breadcrumb_claims[$i]}"
    [ -f "$claim" ] || continue
    [ -e "$record" ] || mv "$claim" "$record" 2>/dev/null || true
  done
  pending_breadcrumb_records=()
  pending_breadcrumb_claims=()
}

finalize_timeout_breadcrumbs() {
  local claim
  for claim in "${pending_breadcrumb_claims[@]}"; do
    rm -f "$claim" >/dev/null 2>&1 || true
  done
  pending_breadcrumb_records=()
  pending_breadcrumb_claims=()
}

timeout_warning_event_delivers_context() {
  local harness
  harness="$(printf '%s' "${HQ_HARNESS:-claude}" | tr '[:upper:]' '[:lower:]')"
  # The Grok adapter documents that passive-hook output is diagnostics only and
  # its PreToolUse channel is a deny decision, not additionalContext.
  [ "$harness" = "grok" ] && return 1
  # Repository hook producers establish these as the events whose
  # hookSpecificOutput.additionalContext reaches the model: SessionStart and
  # UserPromptSubmit producers, a PreToolUse producer, and the Codex/Claude
  # PostToolUse delivery path. Stop is deliberately absent: its model delivery
  # uses a block decision, while master emits additionalContext.
  case "$EVENT" in
    SessionStart|UserPromptSubmit|PreToolUse|PostToolUse) return 0 ;;
    *) return 1 ;;
  esac
}

consume_timeout_breadcrumbs() {
  local session_hash breadcrumb_dir record claim stale stale_pid text
  master_timeout_watchdog_enabled || return 0
  [ -n "$SESSION_ID" ] || return 0
  session_hash="$(master_timeout_sha256 "$SESSION_ID")"
  [ -n "$session_hash" ] || return 0
  breadcrumb_dir="$REPO_ROOT/workspace/.hook-timeout-breadcrumbs/$session_hash"
  [ -d "$breadcrumb_dir" ] || return 0

  # A master process can be killed between atomic claim and final emission.
  # Recover only claims whose owner PID is no longer alive; a concurrent live
  # consumer keeps its claim and will either emit or restore it itself.
  for stale in "$breadcrumb_dir"/*.json.consuming.*; do
    [ -f "$stale" ] || continue
    stale_pid="${stale##*.consuming.}"
    if [[ ! "$stale_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$stale_pid" >/dev/null 2>&1; then
      record="${stale%%.consuming.*}"
      [ -e "$record" ] || mv "$stale" "$record" 2>/dev/null || true
    fi
  done
  for record in "$breadcrumb_dir"/*.json; do
    [ -f "$record" ] || continue
    claim="${record}.consuming.$$"
    mv "$record" "$claim" 2>/dev/null || continue
    text="$(jq -r '
      if (.hook_path | type) == "string"
        and (.hook_event | type) == "string"
        and (.threshold | type) == "string"
        and (.elapsed_ms | type) == "number"
        and (.declared_timeout_ms | type) == "number"
      then
        if .threshold == "absolute" then
          "<hq-hook-timeout-warning>\nHook " + .hook_path + " ran for "
          + ((.elapsed_ms / 1000) | floor | tostring) + "s during " + .hook_event
          + ". This hook is taking too long; investigate why.\n</hq-hook-timeout-warning>"
        elif .threshold == "relative" then
          "<hq-hook-timeout-escalation>\nHook " + .hook_path + " ran for "
          + ((.elapsed_ms / 1000) | floor | tostring) + "s of its "
          + ((.declared_timeout_ms / 1000) | floor | tostring) + "s timeout during "
          + .hook_event + ". It is about to be killed by the harness and its output will be discarded. Investigate why.\n</hq-hook-timeout-escalation>"
        else empty end
      else empty end
    ' "$claim" 2>/dev/null || true)"
    if [ -z "$text" ]; then
      rm -f "$claim" >/dev/null 2>&1 || true
      continue
    fi
    pending_breadcrumb_records+=("$record")
    pending_breadcrumb_claims+=("$claim")
    if [ -n "$pending_timeout_warning" ]; then
      pending_timeout_warning+=$'\n\n'
    fi
    pending_timeout_warning+="$text"
  done
}

consume_timeout_breadcrumbs

collect_from_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  local f
  for f in "$dir"/*.sh; do
    [ -e "$f" ] || continue
    hooks+=("$f")
  done
}

# Collect within each source, sorted alphabetically by basename. Sources are
# concatenated in order so that core → personal → packs → active-company is the
# dispatch sequence.
sort_group() {
  local -a group=("$@")
  [ ${#group[@]} -gt 0 ] || return 0
  if [ ${#group[@]} -eq 1 ]; then
    printf '%s\n' "${group[0]}"
    return 0
  fi
  # Insertion sort by basename in-process: groups hold a handful of hooks and
  # the awk|sort|cut pipeline cost three forks per group on every event.
  local -a sorted=()
  local item key i
  for item in "${group[@]}"; do
    key="${item##*/}"
    i=${#sorted[@]}
    while [ "$i" -gt 0 ] && [[ "${sorted[$((i-1))]##*/}" > "$key" ]]; do
      sorted[$i]="${sorted[$((i-1))]}"
      i=$((i-1))
    done
    sorted[$i]="$item"
  done
  printf '%s\n' "${sorted[@]}"
}


# --- Registry dispatch (gated project hooks, in-process) --------------------
REGISTRY="$SCRIPT_DIR/hook-registry.json"
exit_code=0
plain_buf=""
json_outputs=()
json_sources=()
timed_out_child_paths=()
timed_out_child_elapsed_ms=()
timed_out_child_exit_codes=()
timed_out_child_timeout_seconds=()
completed_child_paths=()
completed_child_elapsed_ms=()
late_finish_seen_paths=()

is_json_object() {
  # Cheap shape check first so plain-text outputs never fork jq.
  case "$1" in
    \{*) ;;
    *[![:space:]]*) return 1 ;;
    *) return 1 ;;
  esac
  printf '%s' "$1" | jq -e 'type == "object"' >/dev/null 2>&1
}

# Per-child timeout runner. Prefers coreutils timeout (Linux, Git Bash), then
# perl alarm (macOS); otherwise runs unbounded under the master budget.
child_timeout_cmd=""
if command -v timeout >/dev/null 2>&1; then
  child_timeout_cmd="timeout"
elif command -v perl >/dev/null 2>&1; then
  child_timeout_cmd="perl"
fi
child_completion_dir="$REPO_ROOT/workspace/.hook-timeout-completions"
if [ -n "$child_timeout_cmd" ]; then
  mkdir -p "$child_completion_dir" >/dev/null 2>&1 || child_completion_dir=""
fi
child_sequence=0
run_child() { # <timeout-seconds> <script-path> <completion-marker> [args...]
  local t="$1" path="$2" completion_marker="$3"; shift 3
  local runner=()
  if [ -x "$path" ]; then runner=("$path"); else runner=(bash "$path"); fi
  journal_active_child_start "$path"
  # Build the command first so there is exactly ONE pipeline, and its status is
  # read from PIPESTATUS[1] on the line immediately after it. A hook that exits
  # before reading stdin kills `printf` with SIGPIPE; `pipefail` (set at the top
  # of this file) would otherwise make the pipeline 141 and report a hook that
  # exited 0 as a failure that fails the whole batch. Locals are declared BEFORE
  # the pipeline because every simple command resets PIPESTATUS.
  local cmd=()
  case "$child_timeout_cmd" in
    timeout)
      if [ -n "$completion_marker" ]; then
        cmd=(timeout "$t" bash -c 'marker="$1"; shift; "$@"; rc=$?; : > "$marker"; exit "$rc"' -- "$completion_marker" "${runner[@]}")
      else
        cmd=(timeout "$t" "${runner[@]}")
      fi
      ;;
    # Indirect-object exec never routes a one-element LIST through /bin/sh.
    # Bare `exec @ARGV` does when that element contains a space, the shell
    # word-splits, exec fails, and perl exits 0, so every argless registry
    # hook no-ops on macOS HQ roots like "SE HQ Pilot".
    perl)
      if [ -n "$completion_marker" ]; then
        cmd=(perl -e 'alarm shift; my $marker=shift; system { $ARGV[0] } @ARGV; my $rc=$?; open my $fh, ">", $marker; close $fh; exit($rc == -1 ? 128 : (($rc & 127) ? 128 + ($rc & 127) : ($rc >> 8)));' "$t" "$completion_marker" "${runner[@]}")
      else
        cmd=(perl -e 'alarm shift; exec {$ARGV[0]} @ARGV' "$t" "${runner[@]}")
      fi
      ;;
    *)
      cmd=("${runner[@]}")
      ;;
  esac
  local rc=0
  printf '%s' "$INPUT" | "${cmd[@]}" "$@"
  rc=${PIPESTATUS[1]}
  if [ "$rc" -eq 142 ] && [ -n "$completion_marker" ] && [ ! -f "$completion_marker" ]; then
    rc=124
  fi
  return "$rc"
}

record_child_execution() {
  local path="$1" started_ms="$2" ended_ms="$3" rc="$4" completion_marker="$5" timeout_seconds="$6" elapsed_ms=0 timed_out=0
  if [[ "$started_ms" =~ ^[0-9]+$ ]] && [[ "$ended_ms" =~ ^[0-9]+$ ]]; then
    elapsed_ms=$((ended_ms - started_ms))
    [ "$elapsed_ms" -ge 0 ] || elapsed_ms=0
  fi
  completed_child_paths+=("$path")
  completed_child_elapsed_ms+=("$elapsed_ms")
  journal_active_child_end
  journal_hook_event "$path" "$elapsed_ms"
  if [ -n "$completion_marker" ] && [ ! -f "$completion_marker" ]; then
    case "$rc" in
      124|142) timed_out=1 ;;
    esac
  fi
  [ -n "$completion_marker" ] || timed_out=0
  rm -f "$completion_marker" >/dev/null 2>&1 || true
  if [ "$timed_out" -eq 1 ]; then
    timed_out_child_paths+=("$path")
    timed_out_child_elapsed_ms+=("$elapsed_ms")
    timed_out_child_exit_codes+=("$rc")
    timed_out_child_timeout_seconds+=("$timeout_seconds")
  fi
}

prepare_child_completion_marker() {
  local marker_name
  child_sequence=$((child_sequence + 1))
  child_completion_marker=""
  [ -n "$child_completion_dir" ] || return 0
  case "$MASTER_INVOCATION_ID" in
    ''|*[!A-Za-z0-9._-]*) return 0 ;;
  esac
  marker_name="${MASTER_INVOCATION_ID}.${child_sequence}.done"
  child_completion_marker="$child_completion_dir/$marker_name"
  rm -f "$child_completion_marker" >/dev/null 2>&1 || true
}

trace_ran() { # <id> <rc> <start-epochrealtime>
  local id="$1" rc="$2" start="$3" ms=""
  if [ -n "$start" ] && [ -n "${EPOCHREALTIME:-}" ]; then
    ms="$(( (${EPOCHREALTIME/./} - ${start/./}) / 1000 ))ms"
  fi
  printf 'master-hook: run %s rc=%s %s\n' "$id" "$rc" "$ms" >&2
}

collect_output() { # <rc> <stdout> <source-path>
  local rc="$1" out="$2" src="$3"
  if [ -n "$out" ]; then
    if is_json_object "$out"; then
      json_outputs+=("$out")
      json_sources+=("$src")
    else
      plain_buf+="$out"$'\n'
    fi
  fi
  if [ "$rc" -eq 2 ]; then
    # Claude Code treats 2 as a block. Preserve it even if an earlier advisory
    # hook failed, so a broken sibling cannot downgrade a later guard.
    exit_code=2
  elif [ "$rc" -ne 0 ] && [ "$exit_code" -eq 0 ]; then
    exit_code=$rc
  fi
}

master_normalize_fingerprint_path() {
  local path="$1" original="$1" normalized
  while [ "${path#./}" != "$path" ]; do
    path="${path#./}"
  done
  while :; do
    normalized="${path//\/\.\//\/}"
    [ "$normalized" = "$path" ] && break
    path="$normalized"
  done
  while [ "$path" != "/" ] && [ "${path%/}" != "$path" ]; do
    path="${path%/}"
  done
  [ -n "$path" ] || [ -z "$original" ] || path="."
  printf '%s' "$path"
}

master_hook_fingerprint_identity() {
  local hook_path="$1" normalized_root normalized_hook relative_path=""
  normalized_root="$(master_normalize_fingerprint_path "$REPO_ROOT")"
  normalized_hook="$(master_normalize_fingerprint_path "$hook_path")"
  case "$normalized_root" in
    "") ;;
    "/")
      case "$normalized_hook" in
        /*) relative_path="${normalized_hook#/}" ;;
      esac
      ;;
    ".")
      case "$normalized_hook" in
        /*) ;;
        *) relative_path="$normalized_hook" ;;
      esac
      ;;
    *)
      case "$normalized_hook" in
        "$normalized_root"/*) relative_path="${normalized_hook#"$normalized_root"/}" ;;
      esac
      ;;
  esac
  if [ -n "$relative_path" ]; then
    master_normalize_fingerprint_path "$relative_path"
  else
    basename "$normalized_hook"
  fi
}

master_safe_hook_script() {
  local value="${1##*/}"
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) printf 'unknown' ;;
    *) value="${value:0:128}"; printf '%s' "$value" ;;
  esac
}

master_timeout_record_exists() {
  local session_hash breadcrumb_dir record
  [ -n "$SESSION_ID" ] || return 1
  session_hash="$(master_timeout_sha256 "$SESSION_ID")"
  [ -n "$session_hash" ] || return 1
  breadcrumb_dir="$REPO_ROOT/workspace/.hook-timeout-breadcrumbs/$session_hash"
  [ -d "$breadcrumb_dir" ] || return 1
  for record in "$breadcrumb_dir"/*.json; do
    [ -f "$record" ] || continue
    if jq -e --arg hook_path "$SCRIPT_DIR/master-hook.sh" --arg event "$EVENT" --arg invocation_id "$MASTER_INVOCATION_ID" '
      .hook_path == $hook_path and .hook_event == $event and .invocation_id == $invocation_id
    ' "$record" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

master_declared_timeout_ms() {
  local result="" harness
  harness="$(printf '%s' "${HQ_HARNESS:-claude}" | tr '[:upper:]' '[:lower:]')"
  case "$harness" in
    ''|claude)
      if [ -f "$REPO_ROOT/.claude/settings.json" ]; then
        result="$(jq -r --arg event "$EVENT" '
          [
            .hooks[$event][]?.hooks[]?
            | select(.type == "command" and ((.command // "") | contains("master-hook.sh")))
            | .timeout
          ]
          | map(select(type == "number" and . >= 1))
          | unique
          | if length == 1 then .[0] else empty end
        ' "$REPO_ROOT/.claude/settings.json" 2>/dev/null || true)"
      fi
      ;;
    codex)
      if [ -f "$REPO_ROOT/.codex/config.toml" ]; then
        result="$(awk -v event="$EVENT" '
          $0 == "[[hooks." event ".hooks]]" { in_event = 1; next }
          in_event && /^\[\[hooks\./ { exit }
          in_event && /^[[:space:]]*timeout[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            sub(/[[:space:]]*(#.*)?$/, "")
            if ($0 ~ /^[0-9]+$/) print
            exit
          }
        ' "$REPO_ROOT/.codex/config.toml" 2>/dev/null || true)"
      fi
      ;;
    grok)
      if [ -f "$REPO_ROOT/.grok/hooks/hq-grok-user-bridge.json" ]; then
        result="$(jq -r --arg event "$EVENT" '
          [
            .hooks[$event][]?.hooks[]?
            | .timeout
          ]
          | map(select(type == "number" and . >= 1))
          | unique
          | if length == 1 then .[0] else empty end
        ' "$REPO_ROOT/.grok/hooks/hq-grok-user-bridge.json" 2>/dev/null || true)"
      fi
      ;;
  esac
  if [[ "$result" =~ ^[0-9]+$ ]] && [ "$result" -ge 1 ]; then
    printf '%s000' "$result"
  else
    printf '30000'
  fi
}

master_watchdog_timeout_ms() {
  local declared_ms declared_seconds lead_seconds absolute_seconds relative_seconds selected
  declared_ms="$(master_declared_timeout_ms)"
  declared_seconds=$((declared_ms / 1000))
  lead_seconds="${HQ_HOOK_TIMEOUT_MASTER_WARN_LEAD_SECONDS:-20}"
  [[ "$lead_seconds" =~ ^[0-9]+$ ]] || lead_seconds=20
  absolute_seconds="${HQ_HOOK_TIMEOUT_MASTER_ABSOLUTE_SECONDS:-120}"
  [[ "$absolute_seconds" =~ ^[0-9]+$ ]] || absolute_seconds=120
  relative_seconds=$((declared_seconds - lead_seconds))
  [ "$relative_seconds" -ge 0 ] || relative_seconds=0
  selected="$absolute_seconds"
  [ "$relative_seconds" -lt "$selected" ] && selected="$relative_seconds"
  printf '%s000' "$selected"
}

wait_for_timeout_reporters() {
  local session_hash breadcrumb_dir record marker deadline now
  [ -z "${HQ_HOOK_TIMEOUT_SENTRY_TEST_WAIT_FILE:-}" ] \
    || : > "${HQ_HOOK_TIMEOUT_SENTRY_TEST_WAIT_FILE}" 2>/dev/null || true
  [ -n "$SESSION_ID" ] || return 0
  session_hash="$(master_timeout_sha256 "$SESSION_ID")"
  [ -n "$session_hash" ] || return 0
  breadcrumb_dir="$REPO_ROOT/workspace/.hook-timeout-breadcrumbs/$session_hash"
  [ -d "$breadcrumb_dir" ] || return 0
  deadline=$(( $(date +%s 2>/dev/null || printf '0') + 2 ))
  for record in "$breadcrumb_dir"/*.json; do
    [ -f "$record" ] || continue
    if ! jq -e --arg hook_path "$SCRIPT_DIR/master-hook.sh" --arg event "$EVENT" --arg invocation_id "$MASTER_INVOCATION_ID" '
      .hook_path == $hook_path and .hook_event == $event and .invocation_id == $invocation_id
    ' "$record" >/dev/null 2>&1; then
      continue
    fi
    marker="$record.reported"
    while [ ! -e "$marker" ]; do
      now="$(date +%s 2>/dev/null || printf '0')"
      [ "$now" -lt "$deadline" ] || break
      sleep 0.02 >/dev/null 2>&1 || break
    done
    [ -e "$marker" ] && rm -f "$marker" >/dev/null 2>&1 || true
  done
}

master_load_average() {
  hook_timeout_load_average "$(uname -s 2>/dev/null || printf 'unknown')" /proc/loadavg \
    "$(command -v sysctl 2>/dev/null || printf 'sysctl')"
}

master_spawn_probe_ms() {
  local os_name="$1" shell_bin
  shell_bin="$(command -v bash 2>/dev/null || true)"
  [ "$os_name" = windows ] || return 0
  [ -n "$timeout_journal_file" ] || return 0
  hook_timeout_spawn_ms "$timeout_journal_file.spawn-ms" "$shell_bin"
}

master_elapsed_ms() {
  local now="$MASTER_STARTED_MS" current elapsed
  current="$(master_now_ms)"
  elapsed=0
  if [[ "$now" =~ ^[0-9]+$ ]] && [[ "$current" =~ ^[0-9]+$ ]]; then
    elapsed=$((current - now))
    [ "$elapsed" -ge 0 ] || elapsed=0
  fi
  printf '%s' "$elapsed"
}

master_report_late_event() {
  local event_type="$1" hook_path="$2" final_elapsed_ms="$3" late_exit_code="$4"
  local child_timeout_seconds="${5:-}" declared_timeout_ms watchdog_timeout_ms
  local hook_name message hq_version platform load_average fingerprint_identity fingerprint_hash
  local bash_env_set shell_info cwd_kind_value nproc_count hook_sequence policy_trigger_metadata report_exit event_json
  local os_name spawn_ms slow_child="" slow_child_ms="" slow_child_duration=0 i
  command -v hq >/dev/null 2>&1 || return 0
  hook_name="$(master_safe_hook_script "$hook_path")"
  case "$event_type" in
    hook_timeout_exceeded) message="HQ hook exceeded configured timeout" ;;
    *) message="HQ hook completed after timeout warning" ;;
  esac
  hq_version="$(grep -E '^hqVersion:' "$REPO_ROOT/core/core.yaml" 2>/dev/null | head -n 1 | tr -d ' "' | cut -d: -f2)"
  [ -n "$hq_version" ] || hq_version="unknown"
  platform="$(uname -s 2>/dev/null || printf 'unknown')"
  os_name="$(hook_timeout_os_name "$platform")"
  load_average="$(master_load_average)"
  spawn_ms="$(master_spawn_probe_ms "$os_name")"
  if [ "$hook_name" = master-hook.sh ]; then
    for i in "${!completed_child_elapsed_ms[@]}"; do
      if [ "${completed_child_elapsed_ms[$i]}" -gt "$slow_child_duration" ]; then
        slow_child_duration="${completed_child_elapsed_ms[$i]}"
        slow_child="${completed_child_paths[$i]##*/}"
      fi
    done
  else
    slow_child="$hook_name"
    slow_child_ms="$final_elapsed_ms"
  fi
  [ -n "$slow_child_ms" ] || [ "$slow_child_duration" -le 0 ] || slow_child_ms="$slow_child_duration"
  fingerprint_identity="$(master_hook_fingerprint_identity "$hook_path")"
  fingerprint_hash="$(master_timeout_sha256 "$fingerprint_identity")"
  [ -n "$fingerprint_hash" ] || return 0
  bash_env_set="$(master_bash_env_state)"
  shell_info="$(master_shell_descriptor)"
  cwd_kind_value="$(master_cwd_kind)"
  nproc_count="$(master_nproc)"
  hook_sequence="$(master_hook_sequence_json)"
  policy_trigger_metadata='{}'
  case "$hook_name" in
    inject-policy-on-trigger.sh) policy_trigger_metadata="$(master_policy_trigger_metadata_json)" ;;
  esac
  if [[ "$child_timeout_seconds" =~ ^[0-9]+$ ]] && [ "$child_timeout_seconds" -ge 1 ]; then
    declared_timeout_ms=$((child_timeout_seconds * 1000))
    watchdog_timeout_ms="$declared_timeout_ms"
  else
    declared_timeout_ms="$(master_declared_timeout_ms)"
    watchdog_timeout_ms="$(master_watchdog_timeout_ms)"
  fi
  report_exit="$late_exit_code"
  [[ "$report_exit" =~ ^[0-9]+$ ]] || report_exit=1
  [[ "$final_elapsed_ms" =~ ^[0-9]+$ ]] || final_elapsed_ms=0
  event_json="$(jq -cn \
    --arg type "$event_type" \
    --arg message "$message" \
    --arg fingerprint "hook-timeout:$EVENT:$fingerprint_hash" \
    --arg level "warning" \
    --arg hook_name "$hook_name" \
    --arg hook_event "$EVENT" \
    --arg tool_name "${TOOL_NAME:-unknown}" \
    --arg session_id "${SESSION_ID:-unknown}" \
    --arg hook_path "$hook_path" \
    --arg hq_version "$hq_version" \
    --arg platform "$platform" \
    --arg load_average "$load_average" \
    --arg spawn_ms "$spawn_ms" \
    --arg slow_child "$slow_child" \
    --arg slow_child_ms "$slow_child_ms" \
    --arg bash_env_set "$bash_env_set" \
    --arg shell "$shell_info" \
    --arg cwd_kind "$cwd_kind_value" \
    --arg timing_precision "$MASTER_TIMING_PRECISION" \
    --arg hook_script "$hook_name" \
    --argjson declared_timeout_ms "$declared_timeout_ms" \
    --argjson elapsed_ms "$final_elapsed_ms" \
    --argjson remaining_ms 0 \
    --argjson watchdog_timeout_ms "$watchdog_timeout_ms" \
    --argjson final_elapsed_ms "$final_elapsed_ms" \
    --argjson exit_code "$report_exit" \
    --argjson nproc "$nproc_count" \
    --argjson hook_sequence "$hook_sequence" '
      {
        type: $type,
        message: $message,
        fingerprint: $fingerprint,
        level: $level,
        metadata: ({
          hook_name: $hook_name,
          hook_event: $hook_event,
          tool_name: $tool_name,
          session_id: $session_id,
          hook_path: $hook_path,
          declared_timeout_ms: $declared_timeout_ms,
          elapsed_ms: $elapsed_ms,
          remaining_ms: $remaining_ms,
          watchdog_timeout_ms: $watchdog_timeout_ms,
          final_elapsed_ms: $final_elapsed_ms,
          exit_code: $exit_code,
          hq_version: $hq_version,
          platform: $platform,
          load_average: $load_average,
          bash_env_set: $bash_env_set,
          shell: $shell,
          cwd_kind: $cwd_kind,
          timing_precision: $timing_precision,
          nproc: $nproc,
          hook_script: $hook_script,
          hook_sequence: $hook_sequence
        }
        + (if ($spawn_ms | test("^[0-9]+$")) then {spawn_ms: ($spawn_ms | tonumber)} else {} end)
        + (if ($slow_child | length) > 0 and ($slow_child_ms | test("^[0-9]+$"))
           then {slow_child: $slow_child, slow_child_ms: ($slow_child_ms | tonumber)} else {} end))
      }
    ')" || return 0
  [ -n "$event_json" ] || return 0
  if [ "$policy_trigger_metadata" != '{}' ]; then
    event_json="$(jq -c --argjson policy_trigger "$policy_trigger_metadata" \
      '.metadata += $policy_trigger' <<<"$event_json")" || return 0
  fi
  HQ_NO_UPDATE_CHECK=1 hq core sentry report --timeout-ms 750 <<<"$event_json" >/dev/null 2>&1 || true
}

late_finish_path_seen() {
  local candidate="$1" seen
  for seen in ${late_finish_seen_paths[@]+"${late_finish_seen_paths[@]}"}; do
    [ "$seen" = "$candidate" ] && return 0
  done
  return 1
}

emit_late_finish_event() {
  local event_type="$1" hook_path="$2" final_elapsed_ms="$3" late_exit_code="$4" timeout_seconds="${5:-}"
  late_finish_path_seen "$hook_path" && return 0
  late_finish_seen_paths+=("$hook_path")
  master_report_late_event "$event_type" "$hook_path" "$final_elapsed_ms" "$late_exit_code" "$timeout_seconds"
}

emit_pending_late_finish_events() {
  local pending=0 i final_elapsed_ms
  if master_timeout_record_exists; then pending=1; fi
  [ ${#timed_out_child_paths[@]} -gt 0 ] && pending=1
  [ "$pending" -eq 1 ] || return 0
  # The threshold workers may still be sending their warning report. Wait for
  # their bounded completion marker before stopping the process group.
  wait_for_timeout_reporters
  stop_master_timeout_watchdog
  if master_timeout_record_exists; then
    final_elapsed_ms="$(master_elapsed_ms)"
    emit_late_finish_event hook_late_finish "$SCRIPT_DIR/master-hook.sh" "$final_elapsed_ms" "$exit_code"
  fi
  for i in "${!timed_out_child_paths[@]}"; do
    emit_late_finish_event hook_timeout_exceeded \
      "${timed_out_child_paths[$i]}" \
      "${timed_out_child_elapsed_ms[$i]}" \
      "${timed_out_child_exit_codes[$i]}" \
      "${timed_out_child_timeout_seconds[$i]}"
  done
}

# The Codex and Grok adapters dispatch registry hooks themselves (through
# hook-gate.sh, via hook-adapter-core.sh) so they keep per-hook
# blocking/advisory semantics; skip the registry here for those harnesses.
registry_dispatch=1
case "${HQ_HARNESS:-}" in
  codex|grok) registry_dispatch=0 ;;
esac
# --- Policy trigger vocabulary prefilter (for inject-policy-on-trigger) -----
# The policy injector evaluates every policy's `when:` expression against
# word tokens derived from the tool input (PreToolUse: the Bash command;
# PostToolUse: the tool output). On Windows Git Bash that costs 4 to 7 s per
# fire. Most commands contain none of the words any tool-event policy keys
# on, so the dispatcher compiles, from the same policy directories the
# injector scans, the set of tokens at least one of which must appear for
# any tool-event policy to be true, and skips the injector when the tool
# text contains none of them. Structural facts the injector derives without
# text (`company`, `repo`) are handled by name: a policy that depends only
# on them runs until its slug is in the session ledger. Anything the
# compiler cannot prove (a `!` negation, `always`) disables the skip for
# that event. Recompiled when a policy directory's mtime changes (a policy
# file added, removed or renamed) or after HQ_POLICY_PREFILTER_TTL seconds
# (default 300); an in-place edit to an existing policy's `when:` line is
# therefore picked up within that window.
policy_prefilter_dirs() { # prints one policy dir per line, injector order
  local co="" cwd="${PAYLOAD_CWD:-}" rscope rname rest
  if [ -n "${HQ_POLICY_COMPANY:-}" ]; then
    co="$HQ_POLICY_COMPANY"
  else
    case "$cwd" in
      *companies/*) rest="${cwd#*companies/}"; co="${rest%%/*}" ;;
    esac
    [ -n "$co" ] || co="$ACTIVE_COMPANY"
  fi
  [ -n "$co" ] && printf '%s\n' "$REPO_ROOT/companies/$co/policies"
  case "$cwd" in
    *repos/public/*|*repos/private/*)
      rest="${cwd#*repos/}"; rscope="${rest%%/*}"; rest="${rest#*/}"; rname="${rest%%/*}"
      [ -n "$rscope" ] && [ -n "$rname" ] && printf '%s\n' "$REPO_ROOT/repos/$rscope/$rname/.claude/policies" ;;
  esac
  printf '%s\n%s\n' "$REPO_ROOT/personal/policies" "$REPO_ROOT/core/policies"
}

policy_prefilter_now() {
  if [ -n "${EPOCHSECONDS:-}" ]; then printf '%s' "$EPOCHSECONDS"; else date +%s 2>/dev/null || printf '0'; fi
}

# policy_prefilter_check <event>  -> 0 run the injector, 1 skip it
policy_prefilter_check() {
  local ev="$1" dir dirs=() key="" cache stale=0 now line
  case "$ev" in PreToolUse|PostToolUse) ;; *) return 0 ;; esac
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    dirs+=("$dir")
    key="$key${dir#"$REPO_ROOT"/}|"
  done < <(policy_prefilter_dirs)
  key="${key//\//_}"; key="${key//|/+}"
  case "$key" in *[!A-Za-z0-9_.+-]*) return 0 ;; esac
  cache="$REPO_ROOT/workspace/orchestrator/hook-state/policy-prefilter/${key}${ev}.v1"
  now="$(policy_prefilter_now)"
  if [ -f "$cache" ]; then
    # Fresh only when the cache is strictly newer than every policy dir. A
    # policy created in the same second as the build (bash 3.2 compares
    # mtimes at second granularity) therefore forces one extra rebuild
    # instead of going unnoticed until the TTL.
    for dir in "${dirs[@]}"; do
      [ -d "$dir" ] || continue
      [ "$cache" -nt "$dir" ] || stale=1
    done
    if [ "$stale" -eq 0 ]; then
      IFS= read -r line < "$cache" || line=""
      case "$line" in
        built=*) [ $(( now - ${line#built=} )) -lt "${HQ_POLICY_PREFILTER_TTL:-300}" ] || stale=1 ;;
        *) stale=1 ;;
      esac
    fi
  else
    stale=1
  fi
  if [ "$stale" -eq 1 ]; then
    mkdir -p "${cache%/*}" 2>/dev/null || return 0
    local files=() f
    for dir in "${dirs[@]}"; do
      [ -d "$dir" ] || continue
      for f in "$dir"/*.md; do
        [ -f "$f" ] || continue
        case "${f##*/}" in
          example-policy.md|README.md|*" "*|*.sync-conflict-*.md|*.conflict-*) continue ;;
        esac
        files+=("$f")
      done
    done
    # One awk pass: frontmatter on:/when: per file -> required-token analysis.
    # Output: built=<epoch>, then lines re=<ere>, struct=<slug>:<company|repo>,
    # unsafe=<slug>. Missing/empty when: is treated as unsafe (fail-open).
    if ! awk -v ev="$ev" -v now="$now" '
      function tokenize(s,    n, m) {
        split("", tok); ntok = 0
        while (length(s) > 0) {
          if (match(s, /^[[:space:]]+/)) { s = substr(s, RLENGTH + 1); continue }
          if (substr(s, 1, 2) == "&&" || substr(s, 1, 2) == "||") { tok[++ntok] = substr(s, 1, 2); s = substr(s, 3); continue }
          if (substr(s, 1, 1) == "(" || substr(s, 1, 1) == ")" || substr(s, 1, 1) == "!") { tok[++ntok] = substr(s, 1, 1); s = substr(s, 2); continue }
          if (match(s, /^[A-Za-z0-9_.\/][A-Za-z0-9_.\/-]*/)) { tok[++ntok] = tolower(substr(s, 1, RLENGTH)); s = substr(s, RLENGTH + 1); continue }
          tok[++ntok] = "?"; s = substr(s, 2)   # unknown byte -> unsafe
        }
      }
      function leaf(t) {
        if (t == "company" || t == "repo") { structural = structural " " t; return "NONE" }
        if (t == "always" || t == "?") { bad = 1; return "NONE" }
        return t
      }
      function pf(    t, r) {
        t = tok[pos]
        if (t == "!") { pos++; pf(); return "NONE" }   # a negation proves nothing; the other AND branch may
        if (t == "(") { pos++; r = pe(); if (tok[pos] == ")") pos++; else bad = 1; return r }
        if (t == "" ) { bad = 1; return "NONE" }
        pos++; return leaf(t)
      }
      function pt(    l, r) {
        l = pf()
        while (tok[pos] == "&&") {
          pos++; r = pf()
          if (l == "NONE") l = r
          else if (r != "NONE" && split(r, ra, " ") < split(l, la, " ")) l = r
        }
        return l
      }
      function pe(    l, r) {
        l = pt()
        while (tok[pos] == "||") {
          pos++; r = pt()
          if (l == "NONE" || r == "NONE") l = "NONE"; else l = l " " r
        }
        return l
      }
      function esc(t,    o, i, c) {
        o = ""
        for (i = 1; i <= length(t); i++) { c = substr(t, i, 1); if (c ~ /[.\/]/) o = o "\\" c; else o = o c }
        return o
      }
      BEGIN { print "built=" now }
      FNR == 1 { infm = 0; onl = ""; whenl = ""; fm_done = 0 }
      FNR == 1 && $0 == "---" { infm = 1; next }
      infm && $0 == "---" { infm = 0; fm_done = 1 }
      infm && /^on:/ { onl = $0 }
      infm && /^when:/ { whenl = $0; sub(/^when:[[:space:]]*/, "", whenl); sub(/[[:space:]]+$/, "", whenl) }
      fm_done && !seen[FILENAME]++ {
        slug = FILENAME; sub(/.*\//, "", slug); sub(/\.md$/, "", slug)
        if (index(onl, ev) == 0) next
        if (whenl == "") { print "unsafe=" slug; next }
        gsub(/^"|"$/, "", whenl)
        tokenize(whenl); pos = 1; bad = 0; structural = ""
        res = pe()
        if (pos <= ntok) bad = 1
        if (bad) { print "unsafe=" slug; next }
        if (res == "NONE") {
          n = split(structural, st, " ")
          if (n == 0) { print "unsafe=" slug; next }
          for (i = 1; i <= n; i++) print "struct=" slug ":" st[i]
          next
        }
        n = split(res, rt, " ")
        for (i = 1; i <= n; i++) {
          t = rt[i]
          if (t == "secret") { vocab["secret"] = 1; vocab["op://"] = 1; vocab["aws_profile"] = 1; vocab["\\.env"] = 1 }
          else if (t == "shared_branch") { vocab["shared_branch"] = 1; vocab["main"] = 1; vocab["master"] = 1; vocab["staging"] = 1; vocab["production"] = 1; vocab["release/"] = 1 }
          else vocab[esc(t)] = 1
        }
      }
      END {
        re = ""
        for (t in vocab) re = (re == "" ? t : re "|" t)
        if (re != "") print "re=" re
      }
    ' ${files[@]+"${files[@]}"} > "$cache.tmp.$$" 2>/dev/null; then
      rm -f "$cache.tmp.$$" 2>/dev/null; return 0
    fi
    mv -f "$cache.tmp.$$" "$cache" 2>/dev/null || { rm -f "$cache.tmp.$$" 2>/dev/null; return 0; }
  fi
  # Evaluate the compiled file: fork-free.
  local re="" ledger="" slug tokn bound=0
  [ -n "$ACTIVE_COMPANY" ] && bound=1
  case "${PAYLOAD_CWD:-}" in *companies/*) bound=1 ;; esac
  [ -n "${HQ_POLICY_COMPANY:-}" ] && bound=1
  if [ -n "$SESSION_ID" ] && [ -f "$REPO_ROOT/workspace/orchestrator/policy-trigger-state/$SESSION_ID.txt" ]; then
    ledger="$(<"$REPO_ROOT/workspace/orchestrator/policy-trigger-state/$SESSION_ID.txt")"
  fi
  while IFS= read -r line; do
    case "$line" in
      unsafe=*) return 0 ;;
      re=*) re="${line#re=}" ;;
      struct=*)
        slug="${line#struct=}"; tokn="${slug##*:}"; slug="${slug%:*}"
        case "$tokn" in
          company) [ "$bound" -eq 1 ] || continue ;;
          repo) case "${PAYLOAD_CWD:-}" in *repos/public/*|*repos/private/*) ;; *) continue ;; esac ;;
        esac
        case "$ledger" in *"$slug"*) continue ;; esac
        return 0 ;;
    esac
  done < "$cache"
  [ -n "$re" ] || return 1
  shopt -s nocasematch
  if [[ "$PREFILTER_TEXT" =~ $re ]]; then shopt -u nocasematch; return 0; fi
  shopt -u nocasematch
  return 1
}

# Registry rows for (event, match key), cached as a file while it is newer
# than the registry so the jq parse (one fork, ~130 ms on Windows) runs once
# per registry change instead of once per tool call.
registry_rows() {
  local key_safe="${MATCH_KEY//[^A-Za-z0-9_.-]/_}"
  local cache="$REPO_ROOT/workspace/orchestrator/hook-state/registry-rows/${EVENT}.${key_safe:-none}.rows"
  if [ -f "$cache" ] && [ "$cache" -nt "$REGISTRY" ] && [ "$cache" -nt "$SCRIPT_DIR/master-hook.sh" ]; then
    cat "$cache"
    return 0
  fi
  local rows
  rows="$(jq -r --arg ev "$EVENT" --arg key "$MATCH_KEY" '
    (.hooks[$ev] // [])[] as $entry
    | ($entry.matcher // "") as $m
    | select($m == "" or $m == "*" or ($key | test("^(" + $m + ")$")))
    | $entry.hooks[]
    | [ .id, .script, ((.timeout // 30) | tostring),
        (if .gated == false then "0" else "1" end),
        (.prefilter.re // ""), (.prefilter.env // ""), (.prefilter.file // ""),
        (if .prefilter.policy_vocab == true then "1" else "" end),
        ((.args // []) | join(" ")) ] | join("")' "$REGISTRY" 2>/dev/null)" || rows=""
  printf '%s\n' "$rows"
  if mkdir -p "${cache%/*}" 2>/dev/null; then
    printf '%s\n' "$rows" > "$cache.tmp.$$" 2>/dev/null && mv -f "$cache.tmp.$$" "$cache" 2>/dev/null || rm -f "$cache.tmp.$$" 2>/dev/null
  fi
}

if [ "$registry_dispatch" -eq 1 ] && [ -f "$REGISTRY" ] && command -v hq_hook_profile_allows >/dev/null 2>&1; then
  # Unit separator (0x1f) framing: tab is IFS whitespace, so consecutive empty
  # fields would collapse and shift later columns (a hook's args would land in
  # the prefilter slot and silently skip it).
  while IFS=$'\x1f' read -r rid rscript rtimeout rgated rpf_re rpf_env rpf_file rpf_vocab rargs; do
    [ -n "$rid" ] || continue
    if [ "$rgated" = "1" ]; then
      hq_hook_profile_allows "$rid"
      case $? in
        0) ;;
        2) echo "ERROR: Unknown profile '${HQ_HOOK_PROFILE:-}'. Use minimal|standard|strict" >&2; continue ;;
        *) continue ;;
      esac
    fi
    if [ -n "$rpf_env" ] && [ -z "${!rpf_env:-}" ]; then continue; fi
    if [ -n "$rpf_file" ] && [ ! -e "$REPO_ROOT/$rpf_file" ]; then continue; fi
    # Case-insensitive: hooks lowercase their signals; a superset match must too.
    shopt -s nocasematch
    prefilter_hit=1
    if [ -n "$rpf_re" ] && ! [[ "$PREFILTER_TEXT" =~ $rpf_re ]]; then prefilter_hit=0; fi
    shopt -u nocasematch
    if [ "$prefilter_hit" -eq 1 ] && [ -n "$rpf_vocab" ] && ! policy_prefilter_check "$EVENT"; then
      [ -z "${HQ_HOOK_TRACE:-}" ] || printf 'master-hook: skip %s (policy-vocab)\n' "$rid" >&2
      continue
    fi
    if [ "$prefilter_hit" -eq 0 ]; then
      [ -z "${HQ_HOOK_TRACE:-}" ] || printf 'master-hook: skip %s (prefilter)\n' "$rid" >&2
      continue
    fi
    if [ "$MONITOR_EXPIRY_NOTIFICATION" -eq 1 ]; then
      case "${rscript##*/}" in
        rewrite-resume-sentinel.sh|route-deep-plan-to-skill.sh|\
        auto-session-project.sh|natural-language-router.sh|session-title.sh|\
        repos-sync.sh|45-lanes-senior-monitor.sh)
          [ -z "${HQ_HOOK_TRACE:-}" ] || printf 'master-hook: skip %s (monitor-expiry-notification)\n' "$rid" >&2
          continue
          ;;
      esac
    fi
    if [ ! -f "$REPO_ROOT/$rscript" ]; then
      [ -z "${HQ_HOOK_TRACE:-}" ] || printf 'master-hook: skip %s (missing-script)\n' "$rid" >&2
      continue
    fi
    rc=0
    trace_start="${EPOCHREALTIME:-}"
    child_started_ms="$(master_now_ms)"
    prepare_child_completion_marker
    # shellcheck disable=SC2086 # args are space-separated literals from the registry.
    out="$(run_child "$rtimeout" "$REPO_ROOT/$rscript" "$child_completion_marker" $rargs)" || rc=$?
    child_ended_ms="$(master_now_ms)"
    record_child_execution "$REPO_ROOT/$rscript" "$child_started_ms" "$child_ended_ms" "$rc" "$child_completion_marker" "$rtimeout"
    [ -z "${HQ_HOOK_TRACE:-}" ] || trace_ran "$rid" "$rc" "$trace_start"
    collect_output "$rc" "$out" "$REPO_ROOT/$rscript"
  done < <(registry_rows)
fi

hooks=()
ordered_hooks=()

# 1. core/hooks/<event>
hooks=()
collect_from_dir "$REPO_ROOT/core/hooks/$EVENT"
if [ ${#hooks[@]} -gt 0 ]; then
  while IFS= read -r line; do ordered_hooks+=("$line"); done < <(sort_group "${hooks[@]}")
fi

# 2. personal/hooks/<event>
hooks=()
collect_from_dir "$REPO_ROOT/personal/hooks/$EVENT"
if [ ${#hooks[@]} -gt 0 ]; then
  while IFS= read -r line; do ordered_hooks+=("$line"); done < <(sort_group "${hooks[@]}")
fi

# 3. core/packages/*/hooks/<event>  (always-on per installed pack)
hooks=()
for pack_dir in "$REPO_ROOT"/core/packages/*/; do
  [ -d "$pack_dir" ] || continue
  collect_from_dir "${pack_dir}hooks/$EVENT"
done
if [ ${#hooks[@]} -gt 0 ]; then
  while IFS= read -r line; do ordered_hooks+=("$line"); done < <(sort_group "${hooks[@]}")
fi

# 4. companies/<active-slug>/hooks/<event>  (active-company only)
hooks=()
if [ -n "$ACTIVE_COMPANY" ]; then
  collect_from_dir "$REPO_ROOT/companies/$ACTIVE_COMPANY/hooks/$EVENT"
fi
if [ ${#hooks[@]} -gt 0 ]; then
  while IFS= read -r line; do ordered_hooks+=("$line"); done < <(sort_group "${hooks[@]}")
fi

hooks=("${ordered_hooks[@]+${ordered_hooks[@]}}")

# json_sources is index-aligned with json_outputs so a selected
# {"decision":"block"} can be stamped with hookSpecificOutput.hqSessionBlockedBy
# (US-402 / agent-session blockedBy).

for hook in ${hooks[@]+"${hooks[@]}"}; do
  base="$(basename "$hook")"
  matcher="$(parse_matcher "$base" "$hook")"

  if [ "$MONITOR_EXPIRY_NOTIFICATION" -eq 1 ]; then
    case "$base" in
      rewrite-resume-sentinel.sh|route-deep-plan-to-skill.sh|auto-session-project.sh|\
      natural-language-router.sh|session-title.sh|30-ensure-hq-cli.sh|\
      31-ensure-hq-desktop.sh|40-skill-command-script.sh|\
      repos-sync.sh|45-lanes-senior-monitor.sh|70-work-mesh-ground.sh)
        [ -z "${HQ_HOOK_TRACE:-}" ] || printf 'master-hook: skip %s (monitor-expiry-notification)\n' "$base" >&2
        continue
        ;;
    esac
  fi

  if is_tool_event "$EVENT" && [ -n "$matcher" ]; then
    if ! matches_tool "$matcher" "$TOOL_NAME"; then
      continue
    fi
  fi

  rc=0
  trace_start="${EPOCHREALTIME:-}"
  child_started_ms="$(master_now_ms)"
  prepare_child_completion_marker
  master_child_timeout="${HQ_MASTER_CHILD_TIMEOUT:-120}"
  # The single dispatcher watchdog armed at the top covers every child; the
  # previous per-child re-arm cost two setsid bash processes per hook.
  out="$(run_child "$master_child_timeout" "$hook" "$child_completion_marker" "$EVENT")" || rc=$?
  child_ended_ms="$(master_now_ms)"
  record_child_execution "$hook" "$child_started_ms" "$child_ended_ms" "$rc" "$child_completion_marker" "$master_child_timeout"
  [ -z "${HQ_HOOK_TRACE:-}" ] || trace_ran "$(basename "$hook")" "$rc" "$trace_start"
  collect_output "$rc" "$out" "$hook"
done

emit_pending_late_finish_events

# A block deliberately wins master aggregation. It must also leave timeout
# breadcrumbs pending, because a warning merged into any other JSON object
# would be suppressed by that correct block behavior.
# Empty-array [@] expansion aborts under bash 3.2 + set -u (stock macOS).
# Use the same ${arr[@]+"${arr[@]}"} guard as the hooks dispatch loop above;
# otherwise a layered PreToolUse blocker that exits 2 with plain-text stderr
# (no JSON) never reaches `exit "$exit_code"` and the process returns 1.
has_blocking_json=0
for jo in ${json_outputs[@]+"${json_outputs[@]}"}; do
  case "$jo" in *'"decision"'*) ;; *) continue ;; esac
  if printf '%s' "$jo" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    has_blocking_json=1
    break
  fi
done

timeout_warning_emitted=0
if [ -n "$pending_timeout_warning" ]; then
  # A successful stdout write is not sufficient evidence of delivery. Several
  # lifecycle events discard additionalContext (and Grok never delivers it),
  # so retain the claimed records until a demonstrated context-delivering event
  # can carry this warning. Delaying a warning is recoverable; deleting one
  # before the model can see it is not.
  if ! timeout_warning_event_delivers_context; then
    restore_timeout_breadcrumbs
  elif [ "$has_blocking_json" -eq 1 ]; then
    restore_timeout_breadcrumbs
  else
    timeout_warning_json="$(jq -cn --arg event "$EVENT" --arg warning "$pending_timeout_warning" '
      {hookSpecificOutput: {hookEventName: $event, additionalContext: $warning}}
    ' 2>/dev/null || true)"
    if [ -n "$timeout_warning_json" ]; then
      # Prepend context so the immediate warning is read before child context.
      # Adding a source keeps json_outputs/json_sources index-aligned for the
      # existing first-block provenance logic below.
      json_outputs=("$timeout_warning_json" ${json_outputs[@]+"${json_outputs[@]}"})
      json_sources=("$HOOK_TIMEOUT_WATCHDOG" ${json_sources[@]+"${json_sources[@]}"})
      timeout_warning_emitted=1
    else
      restore_timeout_breadcrumbs
    fi
  fi
fi

[ -n "$plain_buf" ] && printf '%s' "$plain_buf"

json_result=""
if [ ${#json_outputs[@]} -eq 1 ]; then
  # Single JSON result: if it is a block, stamp provenance.
  if [[ "${json_outputs[0]}" == *'"decision"'* ]] && printf '%s' "${json_outputs[0]}" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    json_result="$(printf '%s\n' "${json_outputs[0]}" | jq -c --arg src "${json_sources[0]}" '
      .hookSpecificOutput = ((.hookSpecificOutput // {}) + {hqSessionBlockedBy: $src})
    ')"
  else
    json_result="${json_outputs[0]}"
  fi
elif [ ${#json_outputs[@]} -gt 1 ]; then
  # Find first block (if any) and its source path; otherwise shallow-merge.
  block_idx=""
  i=0
  for jo in ${json_outputs[@]+"${json_outputs[@]}"}; do
    if [[ "$jo" == *'"decision"'* ]] && printf '%s' "$jo" | jq -e '.decision == "block"' >/dev/null 2>&1; then
      block_idx="$i"
      break
    fi
    i=$((i + 1))
  done
  if [ -n "$block_idx" ]; then
    json_result="$(printf '%s\n' "${json_outputs[$block_idx]}" | jq -c --arg src "${json_sources[$block_idx]}" '
      .hookSpecificOutput = ((.hookSpecificOutput // {}) + {hqSessionBlockedBy: $src})
    ')"
  else
    json_result="$(printf '%s\n' ${json_outputs[@]+"${json_outputs[@]}"} | jq -sc '
      reduce .[] as $h ({};
        . as $previous
        | . * $h
        | if ($previous.hookSpecificOutput? != null or $h.hookSpecificOutput? != null)
          then
            (($previous.hookSpecificOutput // {}) * ($h.hookSpecificOutput // {})) as $merged
            | ([
                 $previous.hookSpecificOutput.additionalContext?,
                 $h.hookSpecificOutput.additionalContext?
               ] | map(select(type == "string" and length > 0))) as $contexts
            | .hookSpecificOutput =
                (if ($contexts | length) > 0
                 then $merged + {additionalContext: ($contexts | join("\n\n"))}
                 else $merged | del(.additionalContext)
                 end)
          else .
          end)
    ')"
  fi
fi

if [ -n "$json_result" ]; then
  if printf '%s\n' "$json_result"; then
    [ "$timeout_warning_emitted" -eq 0 ] || finalize_timeout_breadcrumbs
  else
    [ "$timeout_warning_emitted" -eq 0 ] || restore_timeout_breadcrumbs
  fi
fi

[ -z "${HQ_HOOK_TRACE:-}" ] || trace_ran "master-hook:$EVENT total" "$exit_code" "${MASTER_TRACE_START:-}"
exit "$exit_code"
