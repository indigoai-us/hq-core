#!/usr/bin/env bash
# hq-core: public
# startwork-prefetch.sh — deterministic fast path for `/startwork <slug>`.
#
# Called from the UserPromptSubmit intent hook. When the prompt is
# `/startwork <slug> [args]` and <slug> is exactly a company slug in
# companies/manifest.yaml, this script does the company half of /startwork
# before the model sees the prompt, by running the same command the skill
# runs: `startwork-context.sh orient --company <slug> --mode Company`. That
# does the trusted bind (company and mode, with the hard-policy digest),
# renders the capability block with its Board summary, and adds the
# handoff.json last-thread line when that thread belongs to the same company.
#
# The model then skips the company steps (see "Fast path" at the top of
# .claude/skills/startwork/SKILL.md) and goes straight to orientation.
#
# Matching is exact on purpose. Anything else prints nothing and leaves the
# normal SKILL.md path in charge:
#   - first token not byte-equal to a manifest slug (typos, case, aliases,
#     repo names, project names, free text),
#   - remaining args that SKILL.md §1.0/§1.0b route elsewhere (a slash token,
#     bare deep-plan/prd or another hyphenated command name, or a
#     bounded-action word such as dm, inbox, meeting, signals, search, goals),
#   - remaining args that name a second company slug,
#   - a session already bound to a different company,
#   - no valid session id (a bind could land on another session).
#
# Usage:
#   core/scripts/startwork-prefetch.sh --prompt <text> --session-id <id>
#
# Env: HQ_ROOT; HQ_STARTWORK_PREFETCH=0 or HQ_DISABLED_HOOKS=startwork-prefetch
#      disables it; HQ_STARTWORK_PREFETCH_POLICY_BYTES caps the bind's policy
#      digest (default 5120) so the whole prompt-hook output stays under the
#      host's ~10 KB inline limit.
# Exit 0 always. Output is additive context.
set -uo pipefail
export LC_ALL=C

case "${HQ_STARTWORK_PREFETCH:-1}" in 0|false|FALSE|off|OFF|no|NO) exit 0 ;; esac
disabled=",${HQ_DISABLED_HOOKS:-},"
disabled="$(printf '%s' "$disabled" | tr -d '[:space:]')"
case "$disabled" in *,startwork-prefetch,*) exit 0 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
MANIFEST="$ROOT/companies/manifest.yaml"

PROMPT="" SID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prompt) PROMPT="${2:-}"; shift 2 ;;
    --session-id) SID="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

case "$SID" in ''|.|..|*[!A-Za-z0-9._-]*) exit 0 ;; esac
[ -f "$MANIFEST" ] || exit 0

# Flatten whitespace (newlines included) and require the exact command token.
flat="$(printf '%s' "$PROMPT" | tr '\n\r\t' '   ' | sed -E 's/^ +//; s/ +$//; s/  +/ /g')"
case "$flat" in "/startwork "*) ;; *) exit 0 ;; esac
args="${flat#/startwork }"
slug="${args%% *}"
rest=""
[ "$slug" = "$args" ] || rest="${args#* }"

# Exact slug: the same shape and manifest test startwork-context.sh uses, plus
# a real (non-symlink) company directory. No case folding, no prefix match.
printf '%s' "$slug" | grep -qE '^[a-z0-9][a-z0-9-]*$' || exit 0
grep -qE "^  $slug:[[:space:]]*$" "$MANIFEST" 2>/dev/null || exit 0
[ -d "$ROOT/companies/$slug" ] && [ ! -L "$ROOT/companies/$slug" ] || exit 0

if [ -n "$rest" ]; then
  words=" $(printf '%s' "$rest" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9/-' ' ' | tr -s ' ') "
  case "$words" in *" /"*) exit 0 ;; esac
  for w in $words; do
    case "$w" in
      deep-plan|prd|dm|dms|inbox|message|messages|messaging|thread|threads|meeting|meetings|notes|transcript|transcripts|recap|discussed|signals|signal|decisions|risks|commitments|wins|action|find|search|where|goals|goal|okr|okrs|whoami|login|identity)
        exit 0 ;;
      *-*)
        { [ -f "$ROOT/.claude/commands/$w.md" ] || [ -f "$ROOT/.claude/skills/$w/SKILL.md" ]; } && exit 0 ;;
    esac
    [ "$w" != "$slug" ] && grep -qE "^  $w:[[:space:]]*$" "$MANIFEST" 2>/dev/null && exit 0
  done
  case "$words" in *" who am i "*|*" key results "*) exit 0 ;; esac
fi

# A session already bound to another company keeps the normal skill path, so a
# company switch never happens silently from a hook.
current="$(sed -n 's/^company_slug:[[:space:]]*//p' "$ROOT/workspace/sessions/$SID/meta.yaml" 2>/dev/null | tail -1 | tr -d "\"' ")"
[ -z "$current" ] || [ "$current" = "$slug" ] || exit 0

# One call does the bind (fail closed: it prints nothing unless the session now
# carries this slug), the block with the Board summary, the last-thread line
# and the policy digest.
oriented="$(HQ_STARTWORK_POLICY_BYTES="${HQ_STARTWORK_PREFETCH_POLICY_BYTES:-5120}" \
  bash "$ROOT/core/scripts/startwork-context.sh" orient --company "$slug" --session-id "$SID" --mode Company 2>/dev/null)" || exit 0
[ -n "$oriented" ] || exit 0

printf '<startwork-prefetch company="%s">\n' "$slug"
printf 'Remaining args: %s\n' "${rest:-none}"
printf 'Fast path: follow "Fast path" at the top of .claude/skills/startwork/SKILL.md.\n'
printf '%s\n' "$oriented" | awk '/^<company-policy-digest/ { exit } { print }'
printf '</startwork-prefetch>\n'
printf '%s\n' "$oriented" | awk '/^<company-policy-digest/ { on = 1 } on { print }'
exit 0
