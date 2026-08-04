#!/usr/bin/env bash
# hq-core: public
# session-id.sh — resolve the session id the CURRENT process belongs to.
#
# Sourced by core/scripts/hq-session.sh and .claude/hooks/mandatory-scope-authorizer.sh.
# Never execute directly.
#
# WHY THIS EXISTS
#
# workspace/sessions/.current is a single, global, last-writer-wins pointer
# maintained by .claude/hooks/master-hook.sh: every hook event overwrites it with
# the session id from that event's payload. With two sessions alive at once — an
# interactive session plus a scheduled/agent run, or two terminals — .current
# names whichever session fired a hook most recently, NOT the session the running
# command belongs to.
#
# That matters because the enforcement side does not use .current. The scope
# guard (.claude/hooks/mandatory-scope-authorizer.sh) reads the authoritative
# session id out of the hook payload. So a helper that resolved "this session"
# through .current could write company_slug into a DIFFERENT session's record,
# report success, and leave the calling session unbound — the guard keeps
# blocking, and a foreign session silently acquires a company binding it never
# asked for.
#
# The session id is also exported into every child process by the host, so an
# environment variable always describes the session that spawned this command.
# Prefer it, and keep .current only as a fallback for invocations that have no
# session environment at all (cron, CI, a bare shell).
#
# RESOLUTION ORDER (first syntactically valid, non-empty value wins)
#   1. HQ_SESSION_ID           — explicit caller/test override
#   2. CLAUDE_CODE_SESSION_ID  — Claude Code CLI and app
#   3. CLAUDE_SESSION_ID       — Claude Code (alternate/legacy)
#   4. CODEX_SESSION_ID        — Codex
#   5. CODEX_THREAD_ID         — Codex, thread-scoped runs
#   6. workspace/sessions/.current — no session env; last-writer-wins fallback
#
# The env precedence list matches .claude/skills/_shared/journal.sh so every
# per-session artifact (journal, session meta, scope capability) keys off the
# same identity.

# session_id_is_valid <id>
#   Session ids become a path segment under workspace/sessions/, so restrict them
#   to a conservative charset and reject the traversal spellings outright.
session_id_is_valid() {
  local id="${1:-}"
  [ -n "$id" ] || return 1
  case "$id" in
    .|..) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# session_id_from_env
#   Print the first valid session id found in the environment, or nothing.
#   An unset, empty, or malformed variable is skipped rather than fatal, so a
#   stray value in one host cannot wedge every helper.
session_id_from_env() {
  local var val
  for var in HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
             CODEX_SESSION_ID CODEX_THREAD_ID; do
    val="${!var:-}"
    val="$(printf '%s' "$val" | tr -d '[:space:]')"
    if session_id_is_valid "$val"; then
      printf '%s' "$val"
      return 0
    fi
  done
  return 0
}

# session_id_from_current_file <root>
#   Print the id in workspace/sessions/.current, or nothing when absent/invalid.
session_id_from_current_file() {
  local root="${1:-}" file val
  [ -n "$root" ] || return 0
  file="$root/workspace/sessions/.current"
  [ -f "$file" ] || return 0
  val="$(tr -d '[:space:]' < "$file" 2>/dev/null || true)"
  session_id_is_valid "$val" && printf '%s' "$val"
  return 0
}

# session_id_resolve <root>
#   Print this process's session id: environment first, .current as fallback.
#   Prints nothing (exit 0) when neither source yields a valid id — callers that
#   need one must fail loudly themselves.
session_id_resolve() {
  local root="${1:-}" id
  id="$(session_id_from_env)"
  if [ -z "$id" ]; then
    id="$(session_id_from_current_file "$root")"
  fi
  printf '%s' "$id"
}
