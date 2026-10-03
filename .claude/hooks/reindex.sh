#!/bin/bash
# reindex.sh — path-gated hook shim.
#
# Runs `hq reindex` ONLY when a reindex-relevant file is created, edited, or
# deleted — i.e. a skill, a worker, or a personal-overlay entry (knowledge /
# policies / settings). Everything else is a fast no-op.
#
# Wiring (.claude/settings.json):
#   - PostToolUse Write / Edit / MultiEdit → create + edit (gated by file_path)
#   - PostToolUse Bash                      → delete + move (gated by command)
# The historical Stop / SessionStart / UserPromptSubmit triggers were removed:
# they carry no file path, so they could only ever run reindex unconditionally
# on every turn / prompt / session — exactly the needless churn this gate ends.
# The trade-off: out-of-band changes that DON'T flow through the tools above
# (a `git pull` / `hq sync` that lands new skills, an `/update-hq`) no longer
# auto-reindex; run `hq reindex` by hand after those. `hq reindex` is idempotent,
# so an occasional manual run is safe.
#
# What `hq reindex` does (see the @indigoai-us/hq-cloud package):
#   - surfaces namespaced skills as .claude/skills/<ns>:<skill>/ wrappers
#   - prunes orphan wrappers + legacy command symlinks (and, as a migration,
#     retired personal/{knowledge,policies,workers,settings} mirror symlinks in
#     core/ — that overlay is now read DIRECTLY from personal/, not mirrored)
#   - regenerates the workers registry
#
# Robustness: if the hq CLI isn't on PATH (e.g. a partial install), the shim
# exits cleanly so a missing binary never breaks a session. HQ_NO_UPDATE_CHECK
# is set so this hot hook never blocks on the CLI's network version gate or
# triggers an auto-update mid-session. HQ_OP_LOCK_TIMEOUT=0 makes `hq reindex`
# refuse-fast (never wait) for the per-root operation lock it shares with
# `sync`/`rescue`, so a hook fired while a sync/rescue holds the lock can never
# stall the session.

set -uo pipefail

# Read the hook payload (JSON on stdin). Never let a read failure abort.
PAYLOAD="$(cat 2>/dev/null || true)"
[ -n "$PAYLOAD" ] || exit 0

# No CLI → nothing to do. Keep this early exit ahead of JSON parsing.
command -v hq >/dev/null 2>&1 || exit 0

# The dispatcher already parsed this field for routing. Fall back to JSON only
# when this hook is run directly (for example by its test suite).
_hook_lib_loaded=0
tool="${HQ_HOOK_TOOL_NAME-}"
if [ "${HQ_HOOK_TOOL_NAME+x}" != x ]; then
  . "${BASH_SOURCE[0]%/*}/../../core/scripts/hook-lib.sh"
  _hook_lib_loaded=1
  tool="$(printf '%s' "$PAYLOAD" | hq_json_get tool_name)"
fi

case "$tool" in
  Write|Edit|MultiEdit|Bash) ;;
  *) exit 0 ;;
esac

REL_RE='^(companies/[^/]+/(skills|workers)|core/(skills|workers)|core/packages/[^/]+/(skills|workers)|personal/(skills|workers|knowledge|policies|settings)|\.claude/skills)/'
# Same set, matched anywhere in a shell command string (paths there may be
# absolute or root-relative). Kept in lock-step with REL_RE above.
CMD_PATH_RE='(companies/[^/]+/(skills|workers)|core/(skills|workers)|core/packages/[^/]+/(skills|workers)|personal/(skills|workers|knowledge|policies|settings)|\.claude/skills)/'
# Mutating verbs that create / move / delete files (word-bounded).
CMD_VERB_RE='(^|[^[:alnum:]_])(rm|rmdir|unlink|mv|cp|trash)([^[:alnum:]_]|$)'

# grep -E treats each newline-delimited record independently. Preserve that
# behavior with Bash builtins while avoiding a grep process per check.
__reindex_has_matching_line() {
  local __value="$1" __regex="$2" __line
  while IFS= read -r __line || [ -n "$__line" ]; do
    [[ "$__line" =~ $__regex ]] && return 0
  done <<<"$__value"
  return 1
}

# Extract each needed input field once. Bash's ERE matcher has the same
# expressions as the former grep calls without launching grep on no-op events.
if [ "$_hook_lib_loaded" -eq 0 ]; then
  . "${BASH_SOURCE[0]%/*}/../../core/scripts/hook-lib.sh"
fi
_field() { printf '%s' "$PAYLOAD" | hq_json_get "${1#.}"; }

relevant=0
case "$tool" in
  Write|Edit|MultiEdit)
    fp="$(_field .tool_input.file_path)"
    # Parameter expansion avoids forking dirname. Keep the HQ root anchored to
    # the installed hook, since dispatcher cwd can be a nested project.
    SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
    [ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR=.
    REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
    case "$fp" in
      "$REPO_ROOT"/*) rel="${fp#"$REPO_ROOT"/}" ;;
      *)              rel="" ;;
    esac
    if [ -n "$rel" ] && __reindex_has_matching_line "$rel" "$REL_RE"; then
      relevant=1
    fi
    ;;
  Bash)
    cmd="$(_field .tool_input.command)"
    # A mutation that names a reindex-relevant path; read-only shell commands
    # remain no-ops.
    if __reindex_has_matching_line "$cmd" "$CMD_VERB_RE" \
       && __reindex_has_matching_line "$cmd" "$CMD_PATH_RE"; then
      relevant=1
    fi
    ;;
esac

[ "$relevant" -eq 1 ] || exit 0

# Bash mutations need the same HQ-root argument as file edits.
if [ -z "${REPO_ROOT:-}" ]; then
  SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
  [ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR=.
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
HQ_NO_UPDATE_CHECK=1 HQ_OP_LOCK_TIMEOUT=0 hq reindex --from-hook --repo-root "$REPO_ROOT" 1>&2 || true

exit 0
