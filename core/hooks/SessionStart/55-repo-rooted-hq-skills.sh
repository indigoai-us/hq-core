#!/usr/bin/env bash
# hq-core: public
# SessionStart: point a repo-rooted session at HQ's skills.
#
# Claude Code and Codex load project skills from .claude/skills (Codex:
# .agents/skills) in the start folder and its parents only up to the
# repository root. A session started in repos/private/<repo> or
# workspace/worktrees/<name> has its own repository root below HQ, so HQ's
# skills (/review, /handoff, personal:<name>, ...) are not in its skill list.
#
# When the session's repository root is a folder below HQ_ROOT, this hook adds
# one bounded context note that names the HQ skills directory, the
# `/add-dir <HQ_ROOT>` command that loads them natively in Claude Code, and the
# skill names with their SKILL.md path pattern. Names the session already loads
# (the repo's own .claude/skills or .agents/skills, ~/.claude/skills,
# ~/.agents/skills) are left out. Company-namespaced skill mirrors are left out
# so no other tenant's skill names reach the session.
#
# A session whose repository root is HQ_ROOT (or a folder outside HQ) gets no
# note.
#
# Bypass: HQ_NO_REPO_SKILLS_NOTE=1 or HQ_DISABLED_HOOKS=repo-skills-note.
# Exit code: always 0.
set -uo pipefail

# Cost: this runs on every SessionStart. The HQ-root and outside-HQ cases
# return after string checks only (no subshell, no jq, no extra process); the
# repo-rooted case uses builtins plus stat checks and no external command.
INPUT=""
IFS= read -r -d '' INPUT || true

[ "${HQ_NO_REPO_SKILLS_NOTE:-}" = "1" ] && exit 0
case ",${HQ_DISABLED_HOOKS:-}," in *,repo-skills-note,*|*,\*,*) exit 0 ;; esac

ROOT="${HQ_ROOT:-}"
if [ -z "$ROOT" ]; then
  HOOK_FILE="${BASH_SOURCE[0]}"
  case "$HOOK_FILE" in /*) : ;; *) HOOK_FILE="$PWD/$HOOK_FILE" ;; esac
  ROOT="${HOOK_FILE%/core/hooks/SessionStart/*}"
  [ "$ROOT" != "$HOOK_FILE" ] || exit 0
fi
ROOT="${ROOT%/}"

# cwd from the payload without jq. A value with an escape sequence falls back
# to the dispatcher's HQ_HOOK_CWD or PWD (both already decoded).
CWD=""
case "$INPUT" in
  *'"cwd"'*)
    rest="${INPUT#*\"cwd\"}"
    rest="${rest#*:}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    case "$rest" in
      \"*) rest="${rest#\"}"; CWD="${rest%%\"*}" ;;
    esac
    case "$CWD" in *\\*) CWD="" ;; esac
    ;;
esac
[ -n "$CWD" ] || CWD="${HQ_HOOK_CWD:-$PWD}"
CWD="${CWD%/}"

# Fast exits: HQ root itself, or a path that is not under HQ as given. A
# symlinked spelling of an HQ path is resolved below before deciding.
[ "$CWD" = "$ROOT" ] && exit 0
case "$CWD" in
  "$ROOT"/*) : ;;
  *)
    real_root="$(cd -P "$ROOT" 2>/dev/null && pwd -P)" || exit 0
    real_cwd="$(cd -P "$CWD" 2>/dev/null && pwd -P)" || exit 0
    case "$real_cwd" in "$real_root"/*) ROOT="$real_root"; CWD="$real_cwd" ;; *) exit 0 ;; esac
    ;;
esac
SKILLS_DIR="$ROOT/.claude/skills"
[ -d "$SKILLS_DIR" ] || exit 0

# Find the session's repository root: the nearest folder at or above CWD,
# strictly below ROOT, that holds a .git entry (directory for a clone, file for
# a worktree). None means the walk reaches HQ itself and HQ skills load.
PROJECT_ROOT=""
dir="$CWD"
PROJECT_DIRS=()
while [ "$dir" != "$ROOT" ] && [ "$dir" != "/" ] && [ -n "$dir" ]; do
  PROJECT_DIRS+=("$dir")
  if [ -e "$dir/.git" ]; then
    PROJECT_ROOT="$dir"
    break
  fi
  dir="${dir%/*}"
done
[ -n "$PROJECT_ROOT" ] || exit 0

# Skill folders this session already loads. Only folders that exist are kept,
# so the per-skill check below is usually zero or one stat.
LOADED_DIRS=()
for d in "${PROJECT_DIRS[@]}"; do
  [ -d "$d/.claude/skills" ] && LOADED_DIRS+=("$d/.claude/skills")
  [ -d "$d/.agents/skills" ] && LOADED_DIRS+=("$d/.agents/skills")
done
if [ -n "${HOME:-}" ]; then
  [ -d "$HOME/.claude/skills" ] && LOADED_DIRS+=("$HOME/.claude/skills")
  [ -d "$HOME/.agents/skills" ] && LOADED_DIRS+=("$HOME/.agents/skills")
fi

already_loaded() { # <name>
  local d
  for d in ${LOADED_DIRS[@]+"${LOADED_DIRS[@]}"}; do
    [ -f "$d/$1/SKILL.md" ] && return 0
  done
  return 1
}

# Core skills first, then personal mirrors, then pack mirrors, so the budget
# cut drops pack entries before /review or /handoff.
CORE_NAMES=()
PERSONAL_MIRRORS=()
PACK_NAMES=()
for skill_dir in "$SKILLS_DIR"/*/; do
  name="${skill_dir%/}"
  name="${name##*/}"
  case "$name" in _*|.*|*[[:cntrl:]]*) continue ;; esac
  [ -f "$skill_dir/SKILL.md" ] || continue
  case "$name" in
    *:*)
      ns="${name%%:*}"
      # Only personal and installed-pack mirrors. A company namespace is
      # another tenant's skill list and never goes into a repo session note.
      if [ "$ns" != "personal" ] && [ ! -d "$ROOT/core/packages/$ns" ]; then
        continue
      fi
      ;;
  esac
  already_loaded "$name" && continue
  case "$name" in
    personal:*) PERSONAL_MIRRORS+=("$name") ;;
    *:*) PACK_NAMES+=("$name") ;;
    *) CORE_NAMES+=("$name") ;;
  esac
done
NAMES=(${CORE_NAMES[@]+"${CORE_NAMES[@]}"} ${PERSONAL_MIRRORS[@]+"${PERSONAL_MIRRORS[@]}"} ${PACK_NAMES[@]+"${PACK_NAMES[@]}"})

# Personal skills without a .claude/skills/personal:<name> mirror (older
# installs read them only from personal/skills).
PERSONAL=()
if [ -d "$ROOT/personal/skills" ]; then
  for skill_dir in "$ROOT/personal/skills"/*/; do
    name="${skill_dir%/}"
    name="${name##*/}"
    case "$name" in _*|.*|*[[:cntrl:]]*) continue ;; esac
    [ -f "$skill_dir/SKILL.md" ] || continue
    [ -f "$SKILLS_DIR/personal:$name/SKILL.md" ] && continue
    already_loaded "$name" && continue
    PERSONAL+=("$name")
  done
fi

[ "${#NAMES[@]}" -gt 0 ] || [ "${#PERSONAL[@]}" -gt 0 ] || exit 0

MAX_CHARS="${HQ_REPO_SKILLS_NOTE_MAX_CHARS:-3000}"
case "$MAX_CHARS" in ''|*[!0-9]*) MAX_CHARS=3000 ;; esac

join_bounded() { # <budget> <names...>; sets JOINED to "a, b, c" plus "(+N more ...)"
  local budget="$1" out="" n shown=0 total
  shift
  total=$#
  for n in "$@"; do
    if [ $(( ${#out} + ${#n} + 2 )) -gt "$budget" ]; then
      break
    fi
    out="${out:+$out, }$n"
    shown=$((shown + 1))
  done
  if [ "$shown" -lt "$total" ]; then
    out="$out (+$((total - shown)) more; list them with ls)"
  fi
  JOINED="$out"
}

NOTE="This session's repository root is ${PROJECT_ROOT}, below HQ (${ROOT}), so HQ's skills are not in this session's skill list."
NOTE="$NOTE In Claude Code, run \`/add-dir ${ROOT}\` to load them as slash commands (it loads ${ROOT}/.claude/skills and .claude/commands)."
NOTE="$NOTE Until then, when the user asks for one of these skills (for example /review or /handoff), read its SKILL.md and follow it."
if [ "${#NAMES[@]}" -gt 0 ]; then
  personal_budget=0
  [ "${#PERSONAL[@]}" -gt 0 ] && personal_budget=$((MAX_CHARS / 4))
  join_bounded $((MAX_CHARS - personal_budget)) "${NAMES[@]}"
  NOTE="$NOTE
HQ skills (${SKILLS_DIR}/<name>/SKILL.md): ${JOINED}"
fi
if [ "${#PERSONAL[@]}" -gt 0 ]; then
  personal_budget=$MAX_CHARS
  [ "${#NAMES[@]}" -gt 0 ] && personal_budget=$((MAX_CHARS / 4))
  join_bounded "$personal_budget" "${PERSONAL[@]}"
  NOTE="$NOTE
Personal skills (${ROOT}/personal/skills/<name>/SKILL.md): ${JOINED}"
fi

# JSON-encode with builtins (no jq process). Control characters other than
# newline and tab cannot come from folder names we print, but strip CR anyway.
esc="${NOTE//\\/\\\\}"
esc="${esc//\"/\\\"}"
esc="${esc//$'\r'/}"
esc="${esc//$'\t'/\\t}"
esc="${esc//$'\n'/\\n}"
case "$esc" in *[[:cntrl:]]*) exit 0 ;; esac
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc"
exit 0
