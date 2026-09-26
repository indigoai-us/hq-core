#!/bin/bash
# migrate-policy-triggers.sh — add `when:`/`on:` frontmatter to every policy
# that lacks it, derived from the policy's own metadata.
#
# NOTE: `trigger:` was removed from the policy schema (superseded by when/on).
# This backfill still reads a `trigger:` line if a legacy/external policy has
# one, but newly authored policies derive `when:` from tags alone. When no
# signal can be derived, only hard-enforcement policies receive the
# `when: always` fallback; soft/unset policies remain untriggered. The
# create/edit guard validate-policy-frontmatter.sh is now the primary
# enforcement that every authored policy declares when/on.
#
# `when:` is generated from up to TWO sources, OR-combined:
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
# correct. SessionStart is reserved for the hard-policy `when: always` fallback
# (it has no command/prompt facts — only static facts + `always`), used when
# neither tags nor trigger yield a signal. A non-hard policy with no derivable
# signal is left unchanged so it cannot silently join the SessionStart baseline.
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
#
# COOLDOWN
#
# A full policy scan is idempotent but expensive, and this script runs on every
# SessionStart. Completed non-dry runs are therefore limited to one per
# cooldown window (default 60 minutes). The stamp records only a SUCCESSFUL
# completion — never a run in progress — so an interrupted SessionStart cannot
# suppress the next migration.
#
# Env overrides:
#   HQ_MIGRATE_POLICY_TRIGGERS_COOLDOWN_SECONDS  default 3600; 0 disables cooldown
#   HQ_MIGRATE_POLICY_TRIGGERS_FORCE=1           run now regardless of cooldown
#   HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR          where the per-host stamp lives
#
# The stamp is per-host runtime state, so it lives under $XDG_STATE_HOME
# (default $HOME/.local/state), never under this repo or workspace/, which HQ
# Sync reconciles. It is scoped to both HQ_ROOT and the resolved policy
# directories, so one tenant cannot suppress another tenant's first scan. If
# neither a state override, XDG_STATE_HOME, nor HOME is available, the script
# safely runs without a cooldown. --dry-run neither consults nor updates it.

set -uo pipefail

HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
DRY=0; DIRS=()
for a in "$@"; do case "$a" in
  --dry-run) DRY=1 ;;
  *)         DIRS+=("$a") ;;
esac; done

# Default scope: global core and personal policies, every personal worker
# profile, and only the active company's and repo's policies. Company worker
# profiles remain tenant-scoped to the active company.
if [ "${#DIRS[@]}" -eq 0 ]; then
  # personal/policies is read DIRECTLY (the reindex symlink mirror into
  # core/policies is retired). Mirrors the scope inject-policy-on-trigger reads.
  DIRS=("$HQ_ROOT/core/policies" "$HQ_ROOT/personal/policies")
  for d in "$HQ_ROOT"/personal/workers/*/policies; do
    [ -d "$d" ] && DIRS+=("$d")
  done
  co="${HQ_POLICY_COMPANY:-}"
  if [ -z "$co" ]; then
    case "$CWD" in
      *companies/*) co="$(printf '%s' "$CWD" | sed -nE 's#.*companies/([^/]+).*#\1#p')" ;;
    esac
  fi
  case "$co" in
    ''|.|..|*/*) ;;
    *)
      DIRS+=("$HQ_ROOT/companies/$co/policies")
      for d in "$HQ_ROOT/companies/$co"/workers/*/policies; do
        [ -d "$d" ] && DIRS+=("$d")
      done
      ;;
  esac
  case "$CWD" in
    *repos/public/*|*repos/private/*)
      rscope="$(printf '%s' "$CWD" | sed -nE 's#.*repos/(public|private)/.*#\1#p')"
      rname="$(printf '%s' "$CWD" | sed -nE 's#.*repos/[^/]+/([^/]+).*#\1#p')"
      [ -n "$rscope" ] && [ -n "$rname" ] && DIRS+=("$HQ_ROOT/repos/$rscope/$rname/.claude/policies") ;;
  esac
fi

STATE_DIR="${HQ_MIGRATE_POLICY_TRIGGERS_STATE_DIR:-}"
if [ -z "$STATE_DIR" ]; then
  if [ -n "${XDG_STATE_HOME:-}" ]; then
    STATE_DIR="$XDG_STATE_HOME/hq-migrate-policy-triggers"
  elif [ -n "${HOME:-}" ]; then
    STATE_DIR="$HOME/.local/state/hq-migrate-policy-triggers"
  fi
fi
COOLDOWN_SECONDS="${HQ_MIGRATE_POLICY_TRIGGERS_COOLDOWN_SECONDS:-3600}"
STAMP=""
LOCK=""
STATE_READY=0

# Hash the resolved scope rather than using a shared per-root stamp: the
# default scan deliberately includes tenant-specific directories.
scope_key() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s\0' "$HQ_ROOT" "${DIRS[@]}" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s\0' "$HQ_ROOT" "${DIRS[@]}" | shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

if [ -n "$STATE_DIR" ] && SCOPE_KEY="$(scope_key)"; then
  STAMP="$STATE_DIR/$SCOPE_KEY/last-success"
  LOCK="$STATE_DIR/$SCOPE_KEY/migrate.lock"
  mkdir -p "$(dirname "$STAMP")" 2>/dev/null && STATE_READY=1
fi

cooldown_note() {
  printf 'migrate-policy-triggers: cooldown stamp %s; running\n' "$1" >&2
}

# Three stamp states are intentionally distinct:
#   absent                         -> this scope has not completed a run; run
#   present but unreadable/future   -> cannot trust the clock; log and run
#   present and fresh               -> exit quietly
cooldown_blocks_run() {
  [ "$DRY" = "1" ] && return 1
  [ "$STATE_READY" = "1" ] || return 1
  [ "${HQ_MIGRATE_POLICY_TRIGGERS_FORCE:-0}" = "1" ] && return 1
  [ "$COOLDOWN_SECONDS" -gt 0 ] 2>/dev/null || return 1
  { [ -e "$STAMP" ] || [ -L "$STAMP" ]; } || return 1

  local last now age
  last="$(cat "$STAMP" 2>/dev/null)"
  case "$last" in
    ''|*[!0-9]*) cooldown_note "is unreadable"; return 1 ;;
  esac

  now="$(date -u '+%s')"
  age=$((now - last))
  if [ "$age" -lt 0 ]; then
    cooldown_note "is in the future"
    return 1
  fi
  [ "$age" -lt "$COOLDOWN_SECONDS" ]
}

write_success_stamp() {
  local stamp_tmp
  [ "$DRY" = "1" ] && return 0
  [ "$STATE_READY" = "1" ] || return 0
  stamp_tmp="$(mktemp "$(dirname "$STAMP")/.last-success.XXXXXX")" || return 0
  if printf '%s\n' "$(date -u '+%s')" >"$stamp_tmp" && mv "$stamp_tmp" "$STAMP"; then
    return 0
  fi
  rm -f "$stamp_tmp"
}

if cooldown_blocks_run; then
  exit 0
fi

# A scope-local advisory lock prevents concurrent SessionStart hooks from both
# observing the same absent/stale stamp. Recheck after acquiring it because a
# prior holder may have completed while this invocation waited to acquire it.
if [ "$STATE_READY" = "1" ] && [ "$DRY" != "1" ] && command -v flock >/dev/null 2>&1; then
  if ! exec 9>"$LOCK"; then
    exit 0
  fi
  if ! flock -n 9; then # command -v flock checked above
    exit 0
  fi
  if cooldown_blocks_run; then
    exit 0
  fi
fi

ON_LIVE="[PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]"
ON_START="[SessionStart]"

# A synthesized `when:` is written to disk without a human ever reading it, and
# the write-time validator does not see a `bash`-authored edit. So every derived
# expression is checked against the canonical grammar before it lands — a tag
# token carrying a character outside the identifier charset would otherwise
# produce a `when:` the evaluator cannot parse, and the policy would never match
# for the reason it was backfilled.
EVAL_TRIGGER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/eval-trigger.sh"
when_parses() {
  [ -f "$EVAL_TRIGGER" ] || return 0                    # no evaluator -> don't block the backfill
  [ "$(printf 'x\t%s\n' "$1" | bash "$EVAL_TRIGGER" --check | cut -f2)" = "ok" ]
}

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

# build_when <trigger-prose> <raw-tags> <enforcement> — emit "WHEN<TAB>ON".
# Returns 1 without output when no signal is derivable for a non-hard policy.
build_when() {
  local trig tags enforcement te t seen
  trig="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  tags="$2"
  enforcement="${3%%#*}"
  enforcement="$(printf '%s' "$enforcement" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  enforcement="${enforcement#\"}"; enforcement="${enforcement%\"}"
  enforcement="${enforcement#\'}"; enforcement="${enforcement%\'}"
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
    [ "$enforcement" = "hard" ] || return 1
    printf 'always\t%s' "$ON_START"
  else
    local when=""; local i
    for i in "${!terms[@]}"; do
      [ -z "$when" ] && when="${terms[$i]}" || when="$when || ${terms[$i]}"
    done
    printf '%s\t%s' "$when" "$ON_LIVE"
  fi
}

policy_has_when() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      when:*) return 0 ;;
    esac
  done < "$1"
  return 1
}

total=0; migrated=0; skipped=0; untriggered=0; unparseable=0
declare -i n_session=0
for dir in "${DIRS[@]}"; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    file_name="${f##*/}"
    case "$file_name" in example-policy.md|README.md) continue ;; esac
    total=$((total+1))
    # STRICTLY IDEMPOTENT: a policy that already declares a trigger is left as-is.
    if policy_has_when "$f"; then skipped=$((skipped+1)); continue; fi

    trig="$(fm trigger "$f")"
    tags="$(fm tags "$f" | sed 's/^\[//; s/\]$//')"
    enforcement="$(fm enforcement "$f")"
    if ! built="$(build_when "$trig" "$tags" "$enforcement")"; then
      untriggered=$((untriggered+1))
      continue
    fi
    IFS=$'\t' read -r WHEN ON <<< "$built"
    if ! when_parses "$WHEN"; then
      unparseable=$((unparseable+1))
      printf 'migrate-policy-triggers: refusing to write unparseable when: %s -> `%s`\n' \
        "$file_name" "$WHEN" >&2
      continue
    fi
    [ "$ON" = "$ON_START" ] && n_session=$((n_session+1))

    if [ "$DRY" = "1" ]; then
      printf '%-52s when: %-44s on: %s\n' "$file_name" "$WHEN" "$ON"
      migrated=$((migrated+1)); continue
    fi

    # insert when:/on: after trigger: (or id: if no trigger line exists)
    anchor='^trigger:'; grep -q '^trigger:' "$f" || anchor='^id:'
    tmp="$(mktemp)" || exit 1
    if ! awk -v w="$WHEN" -v o="$ON" -v anc="$anchor" '
      { print }
      !ins && $0 ~ anc { print "when: " w; print "on: " o; ins=1 }
    ' "$f" > "$tmp"; then
      rm -f "$tmp"
      exit 1
    fi
    if ! mv "$tmp" "$f"; then
      rm -f "$tmp"
      exit 1
    fi
    migrated=$((migrated+1))
  done
done

# Quiet in steady state: only report when something was actually backfilled.
[ "$migrated" -gt 0 ] && echo "migrate-policy-triggers: backfilled $migrated policy trigger(s) ($n_session hard -> SessionStart, $untriggered non-hard triggerless left unchanged, $unparseable unparseable derivations skipped, $skipped already had when)" >&2
write_success_stamp
exit 0
