#!/bin/bash
# migrate-policy-triggers.sh — add `when:`/`on:` frontmatter to every policy
# that lacks it, derived from the policy's own metadata.
#
# `when:` is generated from TWO sources, OR-combined:
#   1. trigger content — the authored `trigger:` prose, mapped to a precise
#      expression for the cross-cutting actions tags don't capture (git
#      sub-commands, deploy, secret/credential, migration, pr, install, ...).
#      Compound expressions (`git && push`) are preserved verbatim.
#   2. tags — the `tags: [...]` frontmatter, the policy's topical vocabulary
#      (git, deploy, slack, supabase, auth, refactor, ...). `vendor:x` is
#      normalised to `x`; pure taxonomy/meta tags that never appear in a prompt
#      or command (infrastructure, consolidated, ux, safety, ...) are dropped so
#      they don't bloat the expression or over-fire on a generic word.
#
# Because fact derivation is now OPEN (derive-trigger-facts.sh emits every word
# token, not a fixed list), any surviving tag/trigger word is a live token — no
# expression is dead.
#
# `on:` = ALL hook events EXCEPT SessionStart — [PreToolUse, PostToolUse,
# UserPromptSubmit, AssistantIntent] — for any policy that gets a real `when:`.
# `on:` is the set of sites where the policy is even evaluated; the `when:`
# expression does the actual filtering, so evaluating broadly is cheap and
# correct. SessionStart is reserved for the `when: always` fallback (it has no
# command/prompt facts — only static facts + `always`), used when neither tags
# nor trigger yield a signal.
#
# STRICTLY IDEMPOTENT: a policy that already has a `when:` line is left
# untouched — the script only ever ADDS when/on to a policy that lacks them, and
# never rewrites an existing trigger. There is no force/regenerate mode: once a
# policy declares (or a human tunes) its trigger, that is authoritative.
#
# Runs at SessionStart (registered in .claude/settings.json) so any newly
# authored policy — personal, company, or repo — is auto-backfilled with a
# trigger on the next session, with zero writes in steady state.
#
# Edits in place via this script (Bash) — NOT the Edit tool — to avoid per-file
# autosave churn.
#
# Usage: bash core/scripts/migrate-policy-triggers.sh [--dry-run] [dir ...]
#   With no dir, scans core/policies plus the active company/repo policy dir
#   derived from the cwd (the SessionStart behaviour). Pass dir(s) to override.

set -uo pipefail

HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
DRY=0; DIRS=()
for a in "$@"; do case "$a" in
  --dry-run) DRY=1 ;;
  *)         DIRS+=("$a") ;;
esac; done

# Default scope: global core/policies + the active company's / repo's policies
# (tenant-safe — only the dir the session is actually in). Mirrors the scope the
# inject-policy-on-trigger hook evaluates.
if [ "${#DIRS[@]}" -eq 0 ]; then
  DIRS=("$HQ_ROOT/core/policies")
  case "$CWD" in
    *companies/*)
      co="$(printf '%s' "$CWD" | sed -nE 's#.*companies/([^/]+).*#\1#p')"
      [ -n "$co" ] && DIRS+=("$HQ_ROOT/companies/$co/policies") ;;
  esac
  case "$CWD" in
    *repos/public/*|*repos/private/*)
      rscope="$(printf '%s' "$CWD" | sed -nE 's#.*repos/(public|private)/.*#\1#p')"
      rname="$(printf '%s' "$CWD" | sed -nE 's#.*repos/[^/]+/([^/]+).*#\1#p')"
      [ -n "$rscope" ] && [ -n "$rname" ] && DIRS+=("$HQ_ROOT/repos/$rscope/$rname/.claude/policies") ;;
  esac
fi

ON_LIVE="[PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]"
ON_START="[SessionStart]"

# Meta / taxonomy tags that classify a policy but never appear as a word in a
# command, prompt, or AI message — dropping them keeps `when:` to live signals.
TAG_STOP=" infrastructure consolidated ux safety hq hq-core hq-cli hq-packages \
hq-discipline basic-users knowledge-repos quiet-mode capabilities narration \
voice intent delight orchestration abstraction workflow deliverable routing \
anchor rulesets data-handling shell-injection promotion docs knowledge "

# field extractor (first frontmatter occurrence)
fm() { awk -v k="$1" '/^---$/{d++;next} d==1 && $0 ~ ("^" k ":"){sub("^" k ":[[:space:]]*","");print;exit}' "$2"; }

# trigger_expr <lowercased-trigger-prose> — precise expression for a known
# action, or empty string. Mirrors the tokens derive-trigger-facts.sh emits.
trigger_expr() {
  local t="$1"
  case "$t" in
    *deploy*)                                            echo 'deploy' ;;
    *credential*|*secret*|*op://*|*aws_profile*|*.env*)  echo 'secret || credential' ;;
    *"git push"*|*"gh pr merge"*|*" push "*|*"push to"*) echo 'git && push' ;;
    *commitment*)                                        echo '' ;;   # "commitment(s)" is NOT a git commit — let tags drive
    *commit*)                                            echo 'git && commit' ;;
    *checkout*)                                          echo 'git && checkout' ;;
    *rebase*)                                            echo 'git && rebase' ;;
    *"git stash"*|*" stash "*)                           echo 'git && stash' ;;
    *"gh pr"*|*"pull request"*|*"pr merge"*)             echo 'pr' ;;
    *merge*)                                             echo 'git && merge' ;;
    *migration*|*migrate*|*schema*|*prisma*)             echo 'migrate || migration || schema' ;;
    *"npm install"*|*"pnpm "*|*"yarn "*|*" install "*|*"package install"*) echo 'install' ;;
    *grep*)                                              echo 'grep' ;;
    *slack*)                                             echo 'slack' ;;
    *email*)                                             echo 'email' ;;
    *" git "*|"git "*|*" git")                           echo 'git' ;;
    *)                                                   echo '' ;;
  esac
}

# tag_tokens <raw-tags-line-without-brackets> — normalised, filtered tag tokens
# (one per line). vendor:x -> x; meta tags dropped; lowercased.
tag_tokens() {
  printf '%s' "$1" | tr ',' '\n' | while IFS= read -r tag; do
    tag="$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    tag="${tag#vendor:}"                       # vendor:linear -> linear
    [ -n "$tag" ] || continue
    case "$TAG_STOP" in *" $tag "*) continue ;; esac
    printf '%s\n' "$tag"
  done
}

# build_when <trigger-prose> <raw-tags> — emit "WHEN<TAB>ON"
build_when() {
  local trig tags te t seen
  trig="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  tags="$2"
  te="$(trigger_expr "$trig")"

  # terms: the trigger expression first (parenthesised if it has operators),
  # then each tag token not already named inside the trigger expression.
  local -a terms=()
  seen=" "
  if [ -n "$te" ]; then
    # record identifiers already used so a tag doesn't loosen a precise expr
    for t in $(printf '%s' "$te" | grep -oE '[a-z_][a-z0-9_./-]*'); do seen="$seen$t "; done
    case "$te" in *" "*) terms+=("( $te )") ;; *) terms+=("$te") ;; esac
  fi
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$seen" in *" $t "*) continue ;; esac
    seen="$seen$t "
    terms+=("$t")
  done < <(tag_tokens "$tags")

  if [ "${#terms[@]}" -eq 0 ]; then
    printf 'always\t%s' "$ON_START"
  else
    local when=""; local i
    for i in "${!terms[@]}"; do
      [ -z "$when" ] && when="${terms[$i]}" || when="$when || ${terms[$i]}"
    done
    printf '%s\t%s' "$when" "$ON_LIVE"
  fi
}

total=0; migrated=0; skipped=0
declare -i n_session=0
for dir in "${DIRS[@]}"; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in _digest.md|example-policy.md|README.md) continue ;; esac
    total=$((total+1))
    # STRICTLY IDEMPOTENT: a policy that already declares a trigger is left as-is.
    if grep -q '^when:' "$f"; then skipped=$((skipped+1)); continue; fi

    trig="$(fm trigger "$f")"
    tags="$(fm tags "$f" | sed 's/^\[//; s/\]$//')"
    IFS=$'\t' read -r WHEN ON <<< "$(build_when "$trig" "$tags")"
    [ "$ON" = "$ON_START" ] && n_session=$((n_session+1))

    if [ "$DRY" = "1" ]; then
      printf '%-52s when: %-44s on: %s\n' "$(basename "$f")" "$WHEN" "$ON"
      migrated=$((migrated+1)); continue
    fi

    # insert when:/on: after trigger: (or id: if no trigger line exists)
    anchor='^trigger:'; grep -q '^trigger:' "$f" || anchor='^id:'
    tmp="$(mktemp)"
    awk -v w="$WHEN" -v o="$ON" -v anc="$anchor" '
      { print }
      !ins && $0 ~ anc { print "when: " w; print "on: " o; ins=1 }
    ' "$f" > "$tmp" && mv "$tmp" "$f"
    migrated=$((migrated+1))
  done
done

# Quiet in steady state: only report when something was actually backfilled.
[ "$migrated" -gt 0 ] && echo "migrate-policy-triggers: backfilled $migrated policy trigger(s) ($n_session -> SessionStart, $skipped already had when)" >&2
exit 0
