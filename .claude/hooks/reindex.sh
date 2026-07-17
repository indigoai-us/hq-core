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
#   - mirrors personal/{knowledge,policies,workers,settings} into core/
#   - prunes orphan wrappers + legacy command symlinks
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# No CLI → nothing to do.
command -v hq >/dev/null 2>&1 || exit 0

# --- what counts as a reindex-relevant path (REPO_ROOT-relative) --------------
# companies/<slug>/{skills,workers}/…   core/{skills,workers}/…
# core/packages/<pack>/{skills,workers}/…
# personal/{skills,workers,knowledge,policies,settings}/…
# .claude/skills/…                      (the generated wrappers themselves)
REL_RE='^(companies/[^/]+/(skills|workers)|core/(skills|workers)|core/packages/[^/]+/(skills|workers)|personal/(skills|workers|knowledge|policies|settings)|\.claude/skills)/'
# Same set, matched anywhere in a shell command string (paths there may be
# absolute or root-relative). Kept in lock-step with REL_RE above.
CMD_PATH_RE='(companies/[^/]+/(skills|workers)|core/(skills|workers)|core/packages/[^/]+/(skills|workers)|personal/(skills|workers|knowledge|policies|settings)|\.claude/skills)/'
# Mutating verbs that create / move / delete files (word-bounded).
CMD_VERB_RE='(^|[^[:alnum:]_])(rm|rmdir|unlink|mv|cp|trash)([^[:alnum:]_]|$)'

# Extract a string field from the payload (jq-first, node fallback — hook-lib).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"
_field() { # $1 = jq path, e.g. .tool_input.file_path
  printf '%s' "$PAYLOAD" | hq_json_get "${1#.}"
}

relevant=0
[ -z "$PAYLOAD" ] && exit 0
tool="$(_field .tool_name)"

case "$tool" in
  Write|Edit|MultiEdit)
    fp="$(_field .tool_input.file_path)"
    case "$fp" in
      "$REPO_ROOT"/*) rel="${fp#"$REPO_ROOT"/}" ;;
      *)              rel="" ;;
    esac
    if [ -n "$rel" ] && printf '%s' "$rel" | grep -Eq "$REL_RE"; then
      relevant=1
    fi
    ;;
  Bash)
    cmd="$(_field .tool_input.command)"
    # A mutation (create/move/delete) that names a reindex-relevant path. The
    # verb check keeps read-only bash (ls/cat/grep over skills/) from triggering
    # a reindex.
    if printf '%s' "$cmd" | grep -Eq "$CMD_VERB_RE" \
       && printf '%s' "$cmd" | grep -Eq "$CMD_PATH_RE"; then
      relevant=1
    fi
    ;;
esac

[ "$relevant" -eq 1 ] || exit 0

HQ_NO_UPDATE_CHECK=1 HQ_OP_LOCK_TIMEOUT=0 hq reindex --repo-root "$REPO_ROOT" 1>&2 || true

exit 0
