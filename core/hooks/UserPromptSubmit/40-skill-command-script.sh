#!/usr/bin/env bash
# hq-core: public
# UserPromptSubmit: when the operator invokes /<skill>, run that skill's
# command.sh (if it has one) and show its output to the operator only.
#
# The output goes out as {"systemMessage": ...}, which the harness renders to
# the human and does NOT place in the model's context. The prompt is never
# blocked: the turn proceeds normally after the script runs. Use
# hookSpecificOutput.additionalContext instead if the model should see it.
#
# Command folders searched, highest precedence first:
#   companies/<active-company>/skills/<name>/   (active company ONLY)
#   personal/skills/<name>/
#   core/packages/<pack>/skills/<name>/
#   .claude/skills/<name>/
#   core/skills/<name>/
#
# A namespaced invocation (/<ns>:<name>) pins the search to one root: <ns> is a
# company slug, "personal", or an installed pack name. A company namespace that
# is not the session's active company is refused -- cross-company execution is
# a tenant-isolation breach, so this fails closed rather than searching on.
#
# Env:
#   HQ_SKILL_COMMAND_SCRIPTS=0    disable entirely
#   HQ_DISABLED_HOOKS=skill-command-script   disable via the shared gate
#   HQ_SKILL_COMMAND_FILE         script basename (default: command.sh)
#   HQ_SKILL_COMMAND_TIMEOUT      seconds, default 5
#   HQ_SKILL_COMMAND_MAX_BYTES    output cap, default 4000
#
# The script receives the payload on stdin and these in the environment:
#   HQ_ROOT HQ_COMMAND_NAME HQ_COMMAND_ARGS HQ_COMMAND_SCOPE HQ_ACTIVE_COMPANY
#
# Always exits 0. A skill's command.sh must never be able to wedge a turn.
set -uo pipefail

case "${HQ_SKILL_COMMAND_SCRIPTS:-}" in 0|false|FALSE|no|NO|off|OFF) exit 0 ;; esac
case ",${HQ_DISABLED_HOOKS:-}," in
  *,skill-command-script,*|*,\*,*) exit 0 ;;
esac

INPUT=""
IFS= read -r -d '' INPUT || true
[ -n "$INPUT" ] || exit 0

# Cheap prefilter: no slash-command in the payload means no work to do, and
# this runs on every prompt. A superset match -- the real parse is below.
case "$INPUT" in
  *'"prompt":"/'*|*'"prompt": "/'*) : ;;
  *) exit 0 ;;
esac

HOOK_FILE="${BASH_SOURCE[0]}"
if [ -z "${HQ_ROOT:-}" ]; then
  HQ_ROOT="$(cd -P "${HOOK_FILE%/*}/../../.." 2>/dev/null && pwd)" || exit 0
fi
[ -d "$HQ_ROOT" ] || exit 0

# shellcheck source=core/scripts/hook-lib.sh
. "$HQ_ROOT/core/scripts/hook-lib.sh" 2>/dev/null || exit 0
command -v hq_json_get >/dev/null 2>&1 || exit 0

PROMPT="$(printf '%s' "$INPUT" | hq_json_get prompt 2>/dev/null)" || PROMPT=""
case "$PROMPT" in
  /*) : ;;
  *) exit 0 ;;
esac

# /<token><space-or-end><rest>
TOKEN="${PROMPT#/}"
ARGS=""
case "$TOKEN" in
  *[[:space:]]*)
    ARGS="${TOKEN#*[[:space:]]}"
    TOKEN="${TOKEN%%[[:space:]]*}"
    ;;
esac
[ -n "$TOKEN" ] || exit 0

NS=""
NAME="$TOKEN"
case "$TOKEN" in
  *:*)
    NS="${TOKEN%%:*}"
    NAME="${TOKEN#*:}"
    ;;
esac

# Slug guard. A skill name reaches the filesystem, so anything that is not a
# plain slug is refused before it is joined to a path -- no "..", no "/", no
# shell metacharacters.
valid_slug() {
  case "${1:-}" in
    ""|*[!a-zA-Z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}
valid_slug "$NAME" || exit 0
if [ -n "$NS" ]; then valid_slug "$NS" || exit 0; fi

# --- Active company (tenant isolation) -------------------------------------
# master-hook.sh resolves this too but does not export it, so read the same
# source of truth: workspace/sessions/<session_id>/meta.yaml.
ACTIVE_COMPANY=""
SID="${HQ_HOOK_SESSION_ID:-}"
if [ -z "$SID" ]; then
  SID="$(printf '%s' "$INPUT" | hq_json_get session_id 2>/dev/null)" || SID=""
fi
SID="$(printf '%s' "$SID" | tr -d '[:space:]')"
if valid_slug "$SID"; then
  META="$HQ_ROOT/workspace/sessions/$SID/meta.yaml"
  if [ -f "$META" ]; then
    ACTIVE_COMPANY="$(awk '$1 == "company_slug:" { sub(/^[^:]+:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$META" 2>/dev/null)" || ACTIVE_COMPANY=""
  fi
fi
case "$ACTIVE_COMPANY" in personal) ACTIVE_COMPANY="" ;; esac
if [ -n "$ACTIVE_COMPANY" ]; then
  valid_slug "$ACTIVE_COMPANY" || ACTIVE_COMPANY=""
fi

SCRIPT_NAME="${HQ_SKILL_COMMAND_FILE:-command.sh}"
valid_slug "${SCRIPT_NAME%.sh}" || exit 0

# --- Candidate roots --------------------------------------------------------
# Emitted as "<scope>|<dir>" lines, highest precedence first.
candidates() {
  if [ -n "$NS" ]; then
    if [ "$NS" = "personal" ]; then
      printf 'personal|%s\n' "$HQ_ROOT/personal/skills/$NAME"
      return 0
    fi
    if [ -d "$HQ_ROOT/core/packages/$NS/skills" ]; then
      printf 'pack:%s|%s\n' "$NS" "$HQ_ROOT/core/packages/$NS/skills/$NAME"
      return 0
    fi
    # Company namespace: only the session's own company may execute.
    if [ -n "$ACTIVE_COMPANY" ] && [ "$NS" = "$ACTIVE_COMPANY" ]; then
      printf 'company:%s|%s\n' "$NS" "$HQ_ROOT/companies/$NS/skills/$NAME"
    fi
    return 0
  fi

  if [ -n "$ACTIVE_COMPANY" ]; then
    printf 'company:%s|%s\n' "$ACTIVE_COMPANY" "$HQ_ROOT/companies/$ACTIVE_COMPANY/skills/$NAME"
  fi
  printf 'personal|%s\n' "$HQ_ROOT/personal/skills/$NAME"
  if [ -d "$HQ_ROOT/core/packages" ]; then
    find "$HQ_ROOT/core/packages" -mindepth 3 -maxdepth 3 -type d -path "*/skills/$NAME" 2>/dev/null \
      | sort \
      | while IFS= read -r d || [ -n "$d" ]; do
          [ -n "$d" ] || continue
          pack="${d%/skills/$NAME}"
          printf 'pack:%s|%s\n' "${pack##*/}" "$d"
        done
  fi
  printf 'core|%s\n' "$HQ_ROOT/.claude/skills/$NAME"
  printf 'core|%s\n' "$HQ_ROOT/core/skills/$NAME"
}

# --- Resolve ----------------------------------------------------------------
HQ_ROOT_REAL="$(cd -P "$HQ_ROOT" 2>/dev/null && pwd)" || exit 0
FOUND_SCRIPT=""
FOUND_SCOPE=""
FOUND_REL=""

CAND_LIST="$(candidates)"
while IFS='|' read -r scope dir || [ -n "$scope" ]; do
  IFS=$' \t\n'
  [ -n "$scope" ] && [ -n "$dir" ] || continue
  [ -d "$dir" ] || continue
  script="$dir/$SCRIPT_NAME"
  # A symlinked script is refused outright: the containment check below would
  # otherwise resolve it and approve a file the skill folder does not own.
  [ -f "$script" ] && [ ! -L "$script" ] || continue
  script_dir_real="$(cd -P "$dir" 2>/dev/null && pwd)" || continue
  case "$script_dir_real/" in
    "$HQ_ROOT_REAL"/*) : ;;
    *) continue ;;
  esac
  FOUND_SCRIPT="$script_dir_real/$SCRIPT_NAME"
  FOUND_SCOPE="$scope"
  FOUND_REL="${FOUND_SCRIPT#"$HQ_ROOT_REAL"/}"
  break
done <<EOF
$CAND_LIST
EOF
IFS=$' \t\n'

[ -n "$FOUND_SCRIPT" ] || exit 0

# --- Run --------------------------------------------------------------------
TIMEOUT_SECS="${HQ_SKILL_COMMAND_TIMEOUT:-5}"
case "$TIMEOUT_SECS" in ""|*[!0-9]*) TIMEOUT_SECS=5 ;; esac
MAX_BYTES="${HQ_SKILL_COMMAND_MAX_BYTES:-4000}"
case "$MAX_BYTES" in ""|*[!0-9]*) MAX_BYTES=4000 ;; esac

# Portable bounding: coreutils timeout, else perl alarm, else unbounded (the
# master dispatcher's own watchdog is the backstop). Never a bare `timeout` --
# BSD has no such binary and the wrapper would exit 0 having run nothing.
if command -v timeout >/dev/null 2>&1; then
  set -- timeout "$TIMEOUT_SECS" bash "$FOUND_SCRIPT"
elif command -v perl >/dev/null 2>&1; then
  set -- perl -e 'alarm shift; exec {$ARGV[0]} @ARGV' "$TIMEOUT_SECS" bash "$FOUND_SCRIPT"
else
  set -- bash "$FOUND_SCRIPT"
fi

rc=0
OUT="$(
  printf '%s' "$INPUT" | HQ_ROOT="$HQ_ROOT" \
    HQ_COMMAND_NAME="$NAME" \
    HQ_COMMAND_ARGS="$ARGS" \
    HQ_COMMAND_SCOPE="$FOUND_SCOPE" \
    HQ_ACTIVE_COMPANY="$ACTIVE_COMPANY" \
    "$@" 2>&1
)" || rc=$?

# Cap before encoding so a runaway script cannot produce a multi-megabyte
# systemMessage.
if [ "${#OUT}" -gt "$MAX_BYTES" ]; then
  OUT="$(printf '%s' "$OUT" | head -c "$MAX_BYTES")
... (truncated at ${MAX_BYTES} bytes)"
fi

MSG="[/$TOKEN] $FOUND_REL"
if [ "$rc" -eq 124 ] || [ "$rc" -eq 142 ]; then
  MSG="$MSG
timed out after ${TIMEOUT_SECS}s"
elif [ "$rc" -ne 0 ]; then
  MSG="$MSG
exited $rc"
fi
if [ -n "$OUT" ]; then
  MSG="$MSG
$OUT"
fi

ENCODED="$(printf '%s' "$MSG" | hq_json_encode 2>/dev/null)" || ENCODED=""
[ -n "$ENCODED" ] || exit 0
printf '{"systemMessage":%s}\n' "$ENCODED"
exit 0
