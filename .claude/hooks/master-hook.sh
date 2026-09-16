#!/bin/bash
# Master hook — dispatches a hook event to the active company's hook scripts.
#
# Usage (from settings.json):
#   .claude/hooks/master-hook.sh <event-name>
#
# Active company resolution (fail-closed for tenant isolation):
#   - Read session_id from stdin payload.
#   - Bootstrap workspace/sessions/<session_id>/meta.yaml on first event of
#     the session (with session_id and started_at). Update
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

EVENT="${1:-}"
if [ -z "$EVENT" ]; then
  echo "USAGE: master-hook.sh <event-name>" >&2
  exit 1
fi

# One subshell each; dirname is avoided (a fork costs ~50 ms on Windows).
case "$0" in
  */*) SCRIPT_DIR="$(cd "${0%/*}" && pwd)" ;;
  *) SCRIPT_DIR="$(pwd)" ;;
esac
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MASTER_TRACE_START="${EPOCHREALTIME:-}"
INPUT="$(cat)"

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
    printf 'session_id: %s\nstarted_at: "%s"\n' \
      "$SESSION_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$META_FILE"
  fi
  printf '%s\n' "$SESSION_ID" > "$SESSIONS_DIR/.current"
  ACTIVE_COMPANY="$(awk '$1 == "company_slug:" { sub(/^[^:]+:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$META_FILE")"
fi

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
  local item key i j
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
run_child() { # <timeout-seconds> <script-path> [args...]  (stdout captured by caller)
  local t="$1" path="$2"; shift 2
  local runner=()
  if [ -x "$path" ]; then runner=("$path"); else runner=(bash "$path"); fi
  case "$child_timeout_cmd" in
    timeout) printf '%s' "$INPUT" | timeout "$t" "${runner[@]}" "$@" ;;
    perl) printf '%s' "$INPUT" | perl -e 'alarm shift; exec @ARGV' "$t" "${runner[@]}" "$@" ;;
    *) printf '%s' "$INPUT" | "${runner[@]}" "$@" ;;
  esac
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
    if [ ! -f "$REPO_ROOT/$rscript" ]; then
      [ -z "${HQ_HOOK_TRACE:-}" ] || printf 'master-hook: skip %s (missing-script)\n' "$rid" >&2
      continue
    fi
    rc=0
    trace_start="${EPOCHREALTIME:-}"
    # shellcheck disable=SC2086 # args are space-separated literals from the registry.
    out="$(run_child "$rtimeout" "$REPO_ROOT/$rscript" $rargs)" || rc=$?
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

  if is_tool_event "$EVENT" && [ -n "$matcher" ]; then
    if ! matches_tool "$matcher" "$TOOL_NAME"; then
      continue
    fi
  fi

  rc=0
  trace_start="${EPOCHREALTIME:-}"
  # The single dispatcher watchdog armed at the top covers every child; the
  # previous per-child re-arm cost two setsid bash processes per hook.
  out="$(run_child "${HQ_MASTER_CHILD_TIMEOUT:-120}" "$hook" "$EVENT")" || rc=$?
  [ -z "${HQ_HOOK_TRACE:-}" ] || trace_ran "$(basename "$hook")" "$rc" "$trace_start"
  collect_output "$rc" "$out" "$hook"
done

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
