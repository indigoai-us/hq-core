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
#     calling `core/scripts/hq-session.sh set company <slug>` once context is
#     resolved. Until that happens, only top-level .claude/hooks fire.
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
  if [ -x "$hook" ]; then
    out="$(printf '%s' "$INPUT" | "$hook" "$EVENT")" || rc=$?
  else
    out="$(printf '%s' "$INPUT" | bash "$hook" "$EVENT")" || rc=$?
  fi
  if [ -n "$out" ]; then
    if is_json_object "$out"; then
      json_outputs+=("$out")
    else
      plain_buf+="$out"$'\n'
    fi
  fi
  if [ "$rc" -ne 0 ] && [ "$exit_code" -eq 0 ]; then
    exit_code=$rc
  fi
done

[ -n "$plain_buf" ] && printf '%s' "$plain_buf"

if [ ${#json_outputs[@]} -eq 1 ]; then
  printf '%s\n' "${json_outputs[0]}"
elif [ ${#json_outputs[@]} -gt 1 ]; then
  printf '%s\n' "${json_outputs[@]}" | jq -sc '
    (map(select(.decision == "block")) | .[0])
    // (reduce .[] as $h ({};
        . * $h
        | if (.hookSpecificOutput? and $h.hookSpecificOutput?)
          then .hookSpecificOutput = (.hookSpecificOutput * $h.hookSpecificOutput)
          else .
          end))
  '
fi

exit "$exit_code"
