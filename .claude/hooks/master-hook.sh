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
#   - Exit code: first non-zero exit, else 0.

set -uo pipefail

EVENT="${1:-}"
if [ -z "$EVENT" ]; then
  echo "USAGE: master-hook.sh <event-name>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

INPUT="$(cat)"

# Master registrations own one timeout budget, while their discovered children
# have none of their own. Keep a dispatcher watchdog active during discovery
# (and the no-child path); replace it with a child-specific watchdog while a
# child is running. Every replacement shares this registration's original start
# time, so a slow child warns roughly one lead interval before the parent's
# deadline.
HOOK_TIMEOUT_WATCHDOG="$SCRIPT_DIR/hook-timeout-watchdog.sh"
master_timeout_watchdog_pids=()
master_timeout_watchdog_sessions=()
master_timeout_started_at="$(date +%s 2>/dev/null || printf '0')"

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
      sed -n 's/^#[[:space:]]*hq-hook-match:[[:space:]]*//p' "$full" | head -n1 | tr -d '\n'
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

TOOL_NAME=""
if is_tool_event "$EVENT"; then
  TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
fi

# --- Resolve active company via workspace/sessions/<session_id>/meta.yaml ---
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
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
  printf '%s\n' "${group[@]}" | awk -F/ '{print $NF"\t"$0}' | sort | cut -f2-
}

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

exit_code=0
plain_buf=""
json_outputs=()
# Parallel array: absolute path of the hook that produced each json_outputs entry.
# Used so a selected {"decision":"block"} can be stamped with
# hookSpecificOutput.hqSessionBlockedBy (US-402 / agent-session blockedBy).
json_sources=()

is_json_object() {
  printf '%s' "$1" | jq -e 'type == "object"' >/dev/null 2>&1
}

for hook in ${hooks[@]+"${hooks[@]}"}; do
  base="$(basename "$hook")"
  matcher="$(parse_matcher "$base" "$hook")"

  if is_tool_event "$EVENT" && [ -n "$matcher" ]; then
    if ! matches_tool "$matcher" "$TOOL_NAME"; then
      continue
    fi
  fi

  rc=0
  # The dispatcher watchdog protects discovery before the first child. While a
  # child runs, replace it with a child-specific watchdog that shares the
  # registration deadline and therefore names the actual slow script. Do not
  # re-arm the dispatcher after a child: if that child consumed the budget, a
  # newly armed dispatcher would fire immediately and create a misleading,
  # duplicate master-hook warning during cheap output aggregation.
  stop_master_timeout_watchdog
  arm_master_timeout_watchdog master-child "$hook"
  if [ -x "$hook" ]; then
    out="$(printf '%s' "$INPUT" | "$hook" "$EVENT")" || rc=$?
  else
    out="$(printf '%s' "$INPUT" | bash "$hook" "$EVENT")" || rc=$?
  fi
  stop_master_timeout_watchdog
  if [ -n "$out" ]; then
    if is_json_object "$out"; then
      json_outputs+=("$out")
      json_sources+=("$hook")
    else
      plain_buf+="$out"$'\n'
    fi
  fi
  if [ "$rc" -ne 0 ] && [ "$exit_code" -eq 0 ]; then
    exit_code=$rc
  fi
done

# A block deliberately wins master aggregation. It must also leave timeout
# breadcrumbs pending, because a warning merged into any other JSON object
# would be suppressed by that correct block behavior.
has_blocking_json=0
for jo in "${json_outputs[@]}"; do
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
      json_outputs=("$timeout_warning_json" "${json_outputs[@]}")
      json_sources=("$HOOK_TIMEOUT_WATCHDOG" "${json_sources[@]}")
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
  if printf '%s' "${json_outputs[0]}" | jq -e '.decision == "block"' >/dev/null 2>&1; then
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
  for jo in "${json_outputs[@]}"; do
    if printf '%s' "$jo" | jq -e '.decision == "block"' >/dev/null 2>&1; then
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
    json_result="$(printf '%s\n' "${json_outputs[@]}" | jq -sc '
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

exit "$exit_code"
