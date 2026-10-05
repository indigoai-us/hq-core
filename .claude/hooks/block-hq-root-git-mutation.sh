#!/bin/bash
# block-hq-root-git-mutation.sh — PreToolUse hook for Bash.
#
# THE CONCEPT THIS GUARDS (one of the most important in HQ):
#   HQ root is itself a git repo, and every working repo is nested under it
#   (repos/* and other nested working directories). A git/gh MUTATION whose
#   target directory is ambient (depends on invisible shell cwd) will
#   silently operate on whichever .git it resolves to. From HQ root that is
#   HQ — which by hard policy (hq-root-never-push-remote, hq-git-discipline)
#   is NEVER committed or pushed. Shell cwd is unreliable across context
#   compaction, long-running tools, and parallel-call leakage
#   (hq-verify-cwd-pwd-after-long-running-tools, parallel-bash-cwd-prefix),
#   so "I cd'd earlier" is not a safe assumption for a mutation.
#
#   The safe form for a repo git mutation is an explicit per-command
#   anchor: `git -C /abs/path <cmd>` (git) or `-R owner/repo` (gh) in the
#   SAME Bash call. `gh repo archive|delete|edit <owner/repo>` and `gh api`
#   `repos/<owner>/<repo>` endpoints are remote anchors only on commands that
#   take them as mutation targets. Hard policies are model-facing prose; this
#   hook is the mechanical backstop that does not depend on the model remembering
#   to run a pre-flight `pwd`.
#
# Escape hatch (deliberate, distinct, audited — NOT the generic core
# bypass): HQ_ALLOW_HQ_ROOT_GIT=1 in the hook env, or prefixed inline on a
# single sanctioned call (e.g. intentionally repairing HQ git internals).
#
# REGRESSION NOTE — harness cd-strip (2026-06-08, re-verified 2026-06-09):
#   The Claude Code harness silently STRIPS a leading `cd /abs/path && `
#   (including inside `( ... )`) from a Bash command when /abs/path equals
#   the session's current cwd — this hook then receives the command WITHOUT
#   its cd anchor. Verified by sending `( cd <cwd> && git add --dry-run … )`
#   from <cwd>: the hook's own block message echoed the command minus the
#   cd prefix. Separately, the extraction regex below historically rejected
#   the parenthesized `( cd /abs && git … )` form even when it survived
#   (no `(` in the prefix class — fixed 2026-06-09). Consequences encoded
#   in this version:
#     (a) the cd-anchor form is no longer offered as a FIX — use `git -C`;
#     (b) when NO anchor is found, fall back to the harness-reported input
#         cwd: if it resolves to a git toplevel OTHER than HQ root, the
#         mutation cannot land on HQ root and is allowed (the stripped-
#         anchor case is by construction intended-anchor == actual cwd);
#     (c) `gh repo create` (which accepts neither `git -C` nor `-R`) is
#         self-anchoring: its target is named in its args and without
#         --source it never touches a local repo; --source must be an
#         absolute non-HQ path. Previously it was unanchorable — 5
#         consecutive blocks during the hq-aws-resources build 2026-06-08.
#   Strip behavior reported upstream via /hq-bug.
#
# Exit codes: 0 = allow, 2 = block.

set -uo pipefail

if [[ "${HQ_HOOK_TOOL_NAME+set}" == set && "$HQ_HOOK_TOOL_NAME" != "Bash" ]]; then
  exit 0
fi
if [[ "${HQ_HOOK_COMMAND+set}" == set ]]; then
  CMD="$HQ_HOOK_COMMAND"
  TOOL_CWD="${HQ_HOOK_CWD:-}"
else
  INPUT=$(cat)
  CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || true
  TOOL_CWD="${HQ_HOOK_CWD:-$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)}"
fi
[[ -z "$CMD" ]] && exit 0

if [[ "${HQ_ALLOW_HQ_ROOT_GIT:-}" == "1" ]]; then exit 0; fi
case "$CMD" in
  *git*|*gh*) ;;
  *) exit 0 ;;
esac
# This exact standalone read-only form needs no root lookup or git process.
# Keep the expression narrow so every compound or quoted form reaches the
# existing classifier.
if [[ "$CMD" =~ ^git[[:space:]]+-C[[:space:]]+(/[[:alnum:]_.:/-]+|[A-Za-z]:[/\\][[:alnum:]_.:/\\-]+)[[:space:]]+status$ ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
HOOK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$HOOK_ROOT/core/scripts/hook-lib.sh"

STRICT_GIT_GUARD=0
if [[ "$CMD" == *git* ]]; then
  if [[ -z "${HQ_CLI_BIN:-}" ]]; then
    HQ_CLI_BIN="$(command -v hq 2>/dev/null || true)"
    export HQ_CLI_BIN
  fi
  if command -v node >/dev/null 2>&1; then
    FLAG_ENABLED="$(node "$HOOK_ROOT/.claude/hooks/block-hq-root-git-mutation-flag.cjs")" || FLAG_ENABLED=false
  else
    FLAG_ENABLED=false
  fi
  [[ "$FLAG_ENABLED" == "true" ]] && STRICT_GIT_GUARD=1
fi

# Keep the historical marker-anywhere behavior exactly while the strict flag is
# off. With the flag on, the marker is checked against each resolved git command
# below and only a leading assignment on that same simple command is honored.
if [[ "$STRICT_GIT_GUARD" -eq 0 ]] && echo "$CMD" | grep -Eq '(^|[[:space:]])HQ_ALLOW_HQ_ROOT_GIT=1\b'; then
  exit 0
fi
# expanduser + realpath (symlink-resolving when the path exists), python-free:
# `realpath` ships with GNU coreutils (Linux, Git Bash) and modern macOS; fall
# back to the lexical hq_normpath when it is missing or the path is dangling.
norm() {
  local p="$1" resolved
  case "$p" in [~]) p="$HOME" ;; [~]/*) p="$HOME${p#\~}" ;; esac
  resolved="$(realpath "$p" 2>/dev/null || hq_normpath "$p" 2>/dev/null || printf '%s' "$p")"
  # Git for Windows reports repository roots as D:/..., while Git Bash may
  # receive the same path as /d/.... Canonicalize after physical resolution so
  # equality checks cannot mistake the HQ root for an unrelated repository.
  hq_canonical_path "$resolved"
}
HQ_ROOT="$(norm "$PROJECT_DIR")"

GIT_RE_MUTATION='^(push|pull|fetch|clone|commit|merge|rebase|cherry-pick|revert|am|apply|format-patch|reset|restore|rm|mv|add|stage|checkout|switch|clean|gc|prune|repack|reflog|update-ref|update-index|filter-repo|filter-branch|fast-import|replace|fsck)$'
GIT_RE_READONLY='^(status|log|diff|show|shortlog|whatchanged|rev-parse|rev-list|describe|blame|annotate|cat-file|ls-files|ls-remote|ls-tree|for-each-ref|symbolic-ref|name-rev|var|version|help|count-objects|verify-pack|grep|bisect|branch|tag|stash|remote|notes|config|worktree|submodule|check-ignore)$'

git_subcommand() {
  local arr; read -r -a arr <<<"$1"
  local i seen_git=0
  for ((i=0; i<${#arr[@]}; i++)); do
    local t="${arr[i]}"
    if [[ $seen_git -eq 0 ]]; then
      [[ "$t" == "git" ]] && seen_git=1
      continue
    fi
    case "$t" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix) ((i++)); continue ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|-c=*) continue ;;
      -p|--paginate|--no-pager|--no-replace-objects|--bare|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs) continue ;;
      -*) continue ;;
      *) echo "$t"; return 0 ;;
    esac
  done
  return 1
}

# hq_shell_simple_commands is the tokenizer of record. This only follows the
# already-parsed argv for the three explicit shell source forms and eval; it
# never evaluates a payload and does not parse shell syntax a second time.
RESOLVED_RECORDS=()
RESOLVED_COMMAND=""
UNCLASSIFIED_GIT_WRAPPER=0
SSH_REMOTE_PAYLOAD=""

# ssh forwards every argument after the destination as a remote command. Return
# that payload without evaluating it so the strict parser can classify nested
# git commands exactly like the explicit bash -c / eval forms below.
ssh_remote_payload() {
  local record="$1" executable token i j payload=""
  local -a words
  IFS=$'\037' read -r -a words <<<"$record"
  executable="$(hq_shell_command_executable "$record" || true)"
  [[ -n "$executable" ]] || return 1
  for ((i=0; i<${#words[@]}; i++)); do
    [[ "${words[i]}" == "$executable" ]] && break
  done
  [[ "$i" -lt "${#words[@]}" ]] || return 1
  i=$((i+1))
  while [[ "$i" -lt "${#words[@]}" ]]; do
    token="${words[i]}"
    if [[ "$token" == "--" ]]; then
      i=$((i+1))
      break
    fi
    [[ "$token" == -* ]] || break
    case "$token" in
      -b|-c|-D|-E|-e|-F|-I|-i|-J|-L|-l|-m|-O|-o|-p|-Q|-R|-S|-W|-w)
        i=$((i+2))
        ;;
      *) i=$((i+1)) ;;
    esac
  done
  # The destination is required even when ssh has no remote command.
  [[ "$i" -lt "${#words[@]}" ]] || return 1
  i=$((i+1))
  for ((j=i; j<${#words[@]}; j++)); do
    [[ -n "$payload" ]] && payload+=" "
    payload+="${words[j]}"
  done
  [[ -n "$payload" ]] || return 1
  SSH_REMOTE_PAYLOAD="$payload"
  return 0
}

collect_resolved_records() {
  local source="$1" depth="$2" record executable executable_base text index token payload expanded i
  local -a words
  if [[ "$depth" -ge 8 ]]; then
    [[ "$source" == *git* ]] && UNCLASSIFIED_GIT_WRAPPER=1
    return 0
  fi
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    executable="$(hq_shell_command_executable "$record" || true)"
    executable_base="${executable##*/}"
    executable_base="${executable_base##*\\}"
    expanded=0
    case "$executable_base" in
      bash|bash.exe|sh|sh.exe|zsh|zsh.exe|eval)
        if [[ "$STRICT_GIT_GUARD" -eq 1 ]]; then
          IFS=$'\037' read -r -a words <<<"$record"
          index=-1
          for ((i=0; i<${#words[@]}; i++)); do
            if [[ "${words[i]}" == "$executable" ]]; then index=$i; break; fi
          done
          if [[ "$index" -ge 0 ]]; then
            payload=""
            if [[ "$executable" == "eval" ]]; then
              for ((i=index+1; i<${#words[@]}; i++)); do
                [[ -n "$payload" ]] && payload+=" "
                payload+="${words[i]}"
              done
            else
              for ((i=index+1; i<${#words[@]}; i++)); do
                token="${words[i]}"
                if [[ "$token" == -* && "$token" != --* && "$token" == *c* ]]; then
                  if [[ "$((i+1))" -lt "${#words[@]}" ]]; then payload="${words[i+1]}"; fi
                  break
                fi
              done
            fi
            if [[ -n "$payload" ]]; then
              collect_resolved_records "$payload" "$((depth+1))"
              expanded=1
            fi
          fi
        fi
        ;;
      ssh|ssh.exe)
        if [[ "$STRICT_GIT_GUARD" -eq 1 ]] && ssh_remote_payload "$record"; then
          collect_resolved_records "$SSH_REMOTE_PAYLOAD" "$((depth+1))"
          expanded=1
        fi
        ;;
    esac
    if [[ "$expanded" -eq 0 ]]; then
      RESOLVED_RECORDS+=("$record")
      text="${record//$'\037'/ }"
      RESOLVED_COMMAND+="$text"$'\n'
    fi
  done < <(hq_shell_simple_commands "$source")
}

simple_command_has_escape_assignment() {
  local record="$1" executable token i
  local -a words
  IFS=$'\037' read -r -a words <<<"$record"
  executable="$(hq_shell_command_executable "$record" || true)"
  for ((i=0; i<${#words[@]}; i++)); do
    token="${words[i]}"
    [[ "$token" == "$executable" ]] && return 1
    if [[ "$token" == "HQ_ALLOW_HQ_ROOT_GIT=1" ]]; then return 0; fi
    [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || return 1
  done
  return 1
}

is_dual_mutation() {
  local sub="$1" cmd="$2"
  case "$sub" in
    branch) echo "$cmd" | grep -Eq 'git[^|;&]*\bbranch\b[^|;&]*( -[dDmMcC]\b| --delete| --move| --copy| --force)' && return 0 ;;
    tag)    echo "$cmd" | grep -Eq 'git[^|;&]*\btag\b[^|;&]*( -[dfasum]\b| --delete| --force| --sign| --annotate)' && return 0 ;;
    stash)  echo "$cmd" | grep -Eq 'git[^|;&]*\bstash\b[^|;&]*(push|pop|drop|apply|clear|save|create|store|branch)' && return 0
            echo "$cmd" | grep -Eq 'git[^|;&]*\bstash[[:space:]]*("|'"'"'| *$|\||&&|;)' && return 0 ;;
    remote) echo "$cmd" | grep -Eq 'git[^|;&]*\bremote\b[^|;&]*(add|remove|rm|rename|set-url|set-head|set-branches|prune)' && return 0 ;;
    notes)  echo "$cmd" | grep -Eq 'git[^|;&]*\bnotes\b[^|;&]*(add|append|copy|edit|remove|prune)' && return 0 ;;
    config) echo "$cmd" | grep -Eq 'git[^|;&]*\bconfig\b' && ! echo "$cmd" | grep -Eq 'git[^|;&]*\bconfig\b[^|;&]*(--get|--list|-l\b|--get-all|--get-regexp)' && return 0 ;;
    worktree)  echo "$cmd" | grep -Eq 'git[^|;&]*\bworktree\b[^|;&]*(add|remove|move|prune|repair|lock|unlock)' && return 0 ;;
    submodule) echo "$cmd" | grep -Eq 'git[^|;&]*\bsubmodule\b[^|;&]*(add|update|deinit|set-url|set-branch|sync)' && return 0 ;;
  esac
  return 1
}

GIT_IS_MUTATION=0
GH_IS_MUTATION=0
GIT_CMD=""
GH_CMD=""
GH_RECORD=""
SUB=""
GIT_MUTATION_COUNT=0
GH_MUTATION_COUNT=0

is_redirection_operator() {
  case "$1" in
    '>'|'>>'|'<'|'<<'|'>|') return 0 ;;
  esac
  return 1
}

gh_positional_repo_anchor() {
  local record="$1" executable executable_base token subcommand
  local command_index=-1 endpoint="" method="" i
  local -a words
  IFS=$'\037' read -r -a words <<<"$record"
  executable="$(hq_shell_command_executable "$record" || true)"
  executable_base="${executable##*/}"
  executable_base="${executable_base##*\\}"
  [[ "$executable_base" == gh ]] || return 1

  for ((i=0; i<${#words[@]}; i++)); do
    if [[ "${words[i]}" == "$executable" ]]; then
      command_index=$((i + 1))
      break
    fi
  done
  [[ "$command_index" -ge 0 && "$command_index" -lt "${#words[@]}" ]] || return 1

  subcommand="${words[command_index]}"
  if [[ "$subcommand" == repo ]]; then
    local target_index=$((command_index + 2))
    while [[ "$target_index" -lt "${#words[@]}" ]]; do
      token="${words[target_index]}"
      if [[ "$token" =~ ^[0-9]+$ ]] && is_redirection_operator "${words[target_index+1]:-}"; then
        target_index=$((target_index + 3))
        continue
      fi
      if is_redirection_operator "$token"; then
        target_index=$((target_index + 2))
        continue
      fi
      break
    done
    [[ "${words[command_index+1]:-}" =~ ^(archive|delete|edit)$ ]] || return 1
    [[ "${words[target_index]:-}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
    return $?
  fi

  [[ "$subcommand" == api ]] || return 1
  for ((i=command_index + 1; i<${#words[@]}; i++)); do
    token="${words[i]}"
    if [[ "$token" =~ ^[0-9]+$ ]] && is_redirection_operator "${words[i+1]:-}"; then
      i=$((i + 2))
      continue
    fi
    if is_redirection_operator "$token"; then
      i=$((i + 1))
      continue
    fi
    case "$token" in
      -X|--method)
        ((i++)); [[ "$i" -lt "${#words[@]}" ]] || return 1
        method="${words[i]}"
        ;;
      --method=*) method="${token#*=}" ;;
      -H|--header|-f|--field|-F|--raw-field|-q|--jq|-t|--template|--input|--hostname|--cache|--preview)
        ((i++)); [[ "$i" -lt "${#words[@]}" ]] || return 1
        ;;
      -i|-s|-p|--include|--silent|--paginate|--slurp|--verbose|--help) ;;
      --*=*) ;;
      -*) return 1 ;;
      *) [[ -n "$endpoint" ]] || endpoint="$token" ;;
    esac
  done

  method="$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')"
  [[ "$method" =~ ^(POST|PUT|PATCH|DELETE)$ ]] || return 1
  [[ "$endpoint" =~ ^/?repos/[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*([/?#]|$) ]]
}

ANCHOR_SCAN_COMMAND="$CMD"
collect_resolved_records "$CMD" 0
if [[ "$STRICT_GIT_GUARD" -eq 1 ]]; then ANCHOR_SCAN_COMMAND="$RESOLVED_COMMAND"; fi
# Classify executable words, not arbitrary command text. A git phrase inside a
# summary, JSON payload, echo, or grep pattern is an argument, never a git
# operation.
while IFS= read -r shell_record; do
  [ -n "$shell_record" ] || continue
  shell_exe="$(hq_shell_command_executable "$shell_record" || true)"
  shell_text="${shell_record//$'\037'/ }"
  case "$shell_exe" in
    git)
      shell_sub="$(git_subcommand "$shell_text" || true)"
      [ -n "$shell_sub" ] || continue
      shell_mutation=0
      if echo "$shell_sub" | grep -Eq "$GIT_RE_MUTATION"; then
        shell_mutation=1
      elif echo "$shell_sub" | grep -Eq "$GIT_RE_READONLY"; then
        is_dual_mutation "$shell_sub" "$shell_text" && shell_mutation=1
      else
        shell_mutation=1
      fi
      if [[ "$STRICT_GIT_GUARD" -eq 1 && "$shell_mutation" -eq 1 ]] \
         && simple_command_has_escape_assignment "$shell_record"; then
        shell_mutation=0
      fi
      if [ "$shell_mutation" -eq 1 ] && [ "$GIT_IS_MUTATION" -eq 0 ]; then
        GIT_IS_MUTATION=1; GIT_CMD="$shell_text"; SUB="$shell_sub"
      fi
      [ "$shell_mutation" -eq 1 ] && GIT_MUTATION_COUNT=$((GIT_MUTATION_COUNT + 1))
      ;;
    gh)
      if echo "$shell_text" | grep -Eq '^[^[:space:]]*[[:space:]]+(pr[[:space:]]+(create|merge|close|reopen|edit|comment|ready|review)|repo[[:space:]]+(create|delete|rename|archive|edit|sync|fork)|release[[:space:]]+(create|delete|edit|upload)|issue[[:space:]]+(create|close|edit|comment|delete)|api.*-X[[:space:]]*(POST|PUT|PATCH|DELETE))'; then
        if [ "$GH_IS_MUTATION" -eq 0 ]; then
          GH_IS_MUTATION=1
          GH_CMD="$shell_text"
          GH_RECORD="$shell_record"
        fi
        GH_MUTATION_COUNT=$((GH_MUTATION_COUNT + 1))
      fi
      ;;
  esac
done < <(printf '%s\n' "${RESOLVED_RECORDS[@]}")

if [[ "$STRICT_GIT_GUARD" -eq 1 && "$UNCLASSIFIED_GIT_WRAPPER" -eq 1 ]]; then
  GIT_IS_MUTATION=1
  GIT_CMD="git push"
  SUB="push"
  GIT_MUTATION_COUNT=$((GIT_MUTATION_COUNT + 1))
fi

[[ $GIT_IS_MUTATION -eq 0 && $GH_IS_MUTATION -eq 0 ]] && exit 0

ANCHOR_PATH=""
ANCHOR_KIND=""

if [[ $GIT_IS_MUTATION -eq 1 ]]; then
  GC=$(echo "$GIT_CMD" | grep -oE 'git[[:space:]]+([^|;&]*[[:space:]])?-C[[:space:]]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^ ;&|]+)' | head -1 \
       | sed -E 's/.*-C[[:space:]]+//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')
  if [[ -n "$GC" ]]; then ANCHOR_PATH="$GC"; ANCHOR_KIND="git -C"; fi
fi

if [[ -z "$ANCHOR_PATH" && $GH_IS_MUTATION -eq 1 && $GH_MUTATION_COUNT -eq 1 && $GIT_IS_MUTATION -eq 0 ]]; then
  if echo "$GH_CMD" | grep -Eq 'gh[^|;&]*[[:space:]](-R|--repo)[[:space:]]+[^ ;&|]+'; then
    exit 0
  fi
  if gh_positional_repo_anchor "$GH_RECORD"; then
    exit 0
  fi
fi

if [[ -z "$ANCHOR_PATH" ]]; then
  # Scan the WHOLE command for `cd <path>` anchors.
  #
  # Do NOT slice the command at the git/gh token first. The previous
  # implementation did:
  #
  #     PREFIX_GIT="${CMD%%git*}" ; PREFIX_GH="${CMD%%gh *}"
  #
  # Those are literal-substring cuts, so they also fire INSIDE the path being
  # cd'd to. An HQ root whose path ends in "gh" — or contains "git" anywhere —
  # truncated the prefix mid-path, the extracted anchor no longer equalled
  # HQ_ROOT, and the guard silently ALLOWED the push:
  #
  #     cd /tmp/tmp.VW3WsvCtgh && git push origin main
  #        └ "gh " matches here, prefix becomes "cd /tmp/tmp.VW3WsvCt"
  #
  # Real paths hit this (…/edinburgh, …/github, …/git-tools, …/hq.git, any repo
  # ending in "gh"), and CI hit it whenever mktemp produced such a name — which
  # read as a flaky test rather than the bypass it was.
  #
  # Collect every cd anchor instead, and fail CLOSED: if ANY of them lands on
  # HQ root, that is the anchor. Otherwise keep the previous behaviour of using
  # the last one. `git -C` is resolved earlier and still wins outright.
  CD_PATHS=$(echo "$ANCHOR_SCAN_COMMAND" | grep -oE '(^|[;&|(])[[:space:]]*cd[[:space:]]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^ ;&|)]+)' \
        | sed -E 's/.*cd[[:space:]]+//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')
  if [[ -n "$CD_PATHS" ]]; then
    while IFS= read -r CDP; do
      [[ -z "$CDP" ]] && continue
      ANCHOR_PATH="$CDP"
      ANCHOR_KIND="cd &&"
      [[ "$(norm "$CDP")" == "$HQ_ROOT" ]] && break
    done <<<"$CD_PATHS"
  fi
fi

block() {
  cat >&2 <<MSG
BLOCKED: $1

  Command: $CMD

WHY: A git/gh mutation must carry its OWN explicit repo anchor in the same
Bash call. Shell cwd is not a reliable anchor — it silently drifts across
context compaction, long-running tools, and parallel-call leakage, so a
bare mutation can land on the HQ root repo (never committed/pushed:
hq-root-never-push-remote, hq-git-discipline) or the wrong repo.

FIX — re-issue with an explicit anchor:
  git -C /abs/path/to/repo <subcommand> ...    # canonical for git
  gh pr create -R owner/repo ...               # canonical for gh
  gh repo archive owner/repo ...               # positional gh repo target
  gh api -X PATCH repos/owner/repo/issues/1    # positional API target
  gh repo create owner/name ...                # self-anchoring (--source, if
                                               # used, must be absolute, non-HQ)

Do NOT use \`( cd /abs/path && git ... )\` as the anchor: the Claude Code
harness silently strips a leading \`cd <path> && \` when <path> equals the
session cwd, so this hook never sees it (verified 2026-06-08, re-verified
2026-06-09). If your cwd is already inside the target non-HQ repo, bare
mutations are permitted via the cwd fallback — so seeing this block means
the effective cwd IS the HQ root repo (or not a repo at all), and the
mutation would land on HQ.

Mechanical backstop for a real incident (a bare \`git push\` after earlier
\`cd\`s — the DISABLED HQ push URL caught it only by luck). If you are
intentionally operating on HQ git internals, prefix the single command
with HQ_ALLOW_HQ_ROOT_GIT=1.

If this block is wrong or surprising, report it with /hq-bug.
MSG
  exit 2
}

if [[ "$STRICT_GIT_GUARD" -eq 1 && "$UNCLASSIFIED_GIT_WRAPPER" -eq 1 ]]; then
  block "A nested shell/eval payload containing git exceeded the strict parser depth limit."
fi

# `git init` is the one mutation for which upward git discovery can identify
# the wrong repository: before the new repository has a .git, a direct child
# of repos/private or repos/public resolves upward to HQ_ROOT. Parse the init
# invocation itself so the exception is based on Git's actual target directory,
# not merely on the process cwd. This intentionally accepts only a standalone
# `git init` command; compound commands continue through the normal guard.
git_init_target() {
  local cmd="$1" token value
  local -a arr
  local i=0 base="${TOOL_CWD:-$HQ_ROOT}" dir="" end_options=0

  [[ "$cmd" != *$'\n'* && "$cmd" != *$'\r'* ]] || return 1
  echo "$cmd" | grep -Eq '[;&|`$()<>]' && return 1
  read -r -a arr <<<"$cmd"
  [[ ${#arr[@]} -gt 0 && "${arr[0]}" == "git" ]] || return 1

  # Remove simple surrounding quotes without evaluating any command text.
  unquote_init_token() {
    local v="$1"
    if [[ "$v" == \"*\" && "$v" == *\" ]]; then
      v="${v#\"}"; v="${v%\"}"
    elif [[ "$v" == \'*\' && "$v" == *\' ]]; then
      v="${v#\'}"; v="${v%\'}"
    fi
    printf '%s\n' "$v"
  }

  # Apply global -C options in order, matching Git's relative -C semantics.
  i=1
  while (( i < ${#arr[@]} )); do
    token="${arr[i]}"
    case "$token" in
      -C)
        ((i++)); (( i < ${#arr[@]} )) || return 1
        value="$(unquote_init_token "${arr[i]}")"
        case "$value" in
          /*|\~*) base="$(norm "$value")" ;;
          *)      base="$(norm "$base/$value")" ;;
        esac
        ;;
      -c|--namespace|--exec-path|--super-prefix)
        ((i++)); (( i < ${#arr[@]} )) || return 1
        ;;
      -c=*|--namespace=*|--exec-path=*|-p|--paginate|--no-pager|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--bare)
        ;;
      init)
        ((i++))
        break
        ;;
      *) return 1 ;;
    esac
    ((i++))
  done
  [[ "${arr[i-1]:-}" == "init" ]] || return 1

  # git-init options that consume a following value must not be mistaken for
  # the optional directory. --separate-git-dir is deliberately excluded: it
  # initializes repository metadata at a second path and is not this carve-out.
  while (( i < ${#arr[@]} )); do
    token="${arr[i]}"
    if [[ $end_options -eq 1 ]]; then
      [[ -z "$dir" ]] || return 1
      dir="$(unquote_init_token "$token")"
    else
      case "$token" in
        --) end_options=1 ;;
        -q|--quiet|--bare|--shared) ;;
        --shared=*|--template=*|--object-format=*|--ref-format=*|--initial-branch=*|-b?*) ;;
        -b|--initial-branch|--template|--object-format|--ref-format)
          ((i++)); (( i < ${#arr[@]} )) || return 1
          ;;
        --separate-git-dir|--separate-git-dir=*) return 1 ;;
        -*) return 1 ;;
        *)
          [[ -z "$dir" ]] || return 1
          dir="$(unquote_init_token "$token")"
          ;;
      esac
    fi
    ((i++))
  done

  if [[ -n "$dir" ]]; then
    case "$dir" in
      /*|\~*) printf '%s\n' "$(norm "$dir")" ;;
      *)      printf '%s\n' "$(norm "$base/$dir")" ;;
    esac
  else
    printf '%s\n' "$(norm "$base")"
  fi
}

is_new_direct_child_repo_target() {
  local target="$1" parent existing_git_dir hq_git_dir
  parent="$(norm "$target/..")"
  [[ "$parent" == "$(norm "$HQ_ROOT/repos/private")" ||
     "$parent" == "$(norm "$HQ_ROOT/repos/public")" ]] || return 1
  [[ ! -e "$target" || -d "$target" ]] || return 1
  [[ ! -e "$target/.git" && ! -L "$target/.git" ]] || return 1

  # A bare repository has no .git child. Reject it (and any other nested repo)
  # by comparing its resolved git dir with the HQ git dir inherited by a plain
  # uninitialized child directory.
  if [[ -d "$target" ]]; then
    existing_git_dir="$(git -C "$target" rev-parse --absolute-git-dir 2>/dev/null || true)"
    hq_git_dir="$(git -C "$HQ_ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)"
    if [[ -n "$existing_git_dir" &&
          "$(norm "$existing_git_dir")" != "$(norm "$hq_git_dir")" ]]; then
      return 1
    fi
  fi
  return 0
}

if [[ $GIT_IS_MUTATION -eq 1 && $GIT_MUTATION_COUNT -eq 1 && $GH_IS_MUTATION -eq 0 && "$SUB" == "init" ]]; then
  INIT_TARGET="$(git_init_target "$GIT_CMD" || true)"
  if [[ -n "$INIT_TARGET" ]] && is_new_direct_child_repo_target "$INIT_TARGET"; then
    exit 0
  fi
fi

# `gh repo create` names its target in its own args (owner/name, or name under
# the authenticated account) and accepts neither `git -C` nor `-R` — requiring
# an external anchor made it impossible to invoke. Without --source it never
# touches a local repo, so the HQ-root guard has nothing to protect. The one
# cwd-dependent part is --source: require it absolute and outside the HQ root
# repo. Only applies when the command carries no other git/gh mutation.
if [[ $GIT_IS_MUTATION -eq 0 && $GH_IS_MUTATION -eq 1 && $GH_MUTATION_COUNT -eq 1 && -z "$ANCHOR_PATH" ]] \
   && echo "$GH_CMD" | grep -Eq 'gh[[:space:]]+repo[[:space:]]+create' \
   && ! echo "$GH_CMD" | grep -Eq 'gh[[:space:]]+repo[[:space:]]+(delete|rename|archive|edit|sync|fork)'; then
  SRC=$(echo "$GH_CMD" | grep -oE -- '--source(=|[[:space:]]+)("[^"]+"|'"'"'[^'"'"']+'"'"'|[^ ;&|)]+)' | head -1 \
        | sed -E 's/^--source(=|[[:space:]]+)//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')
  if [[ -z "$SRC" ]]; then
    exit 0
  fi
  case "$SRC" in
    /*)
      SRC_TOP="$(git -C "$(norm "$SRC")" rev-parse --show-toplevel 2>/dev/null || true)"
      if [[ -n "$SRC_TOP" && "$(norm "$SRC_TOP")" == "$HQ_ROOT" ]]; then
        block "gh repo create --source ($SRC) resolves to the HQ root git repo (never pushed to a remote)."
      fi
      exit 0
      ;;
    *)
      block "gh repo create --source must be an ABSOLUTE path ('$SRC' is relative — ambient-cwd dependent)."
      ;;
  esac
fi

if [[ -z "$ANCHOR_PATH" ]]; then
  # Harness-strip fallback (see REGRESSION NOTE in header): a correctly
  # cd-anchored command can reach this hook bare because the harness strips
  # `cd <path> && ` when <path> equals the session cwd — and in exactly that
  # case the intended anchor IS the input cwd. If the harness-reported cwd
  # resolves to a git toplevel other than HQ root, the mutation mechanically
  # cannot land on the HQ root repo — allow it. Bare mutations whose
  # effective cwd is HQ root (or not a repo) remain blocked: that is the
  # incident class this hook exists for.
  if [[ -n "$TOOL_CWD" ]]; then
    CWD_TOP="$(git -C "$TOOL_CWD" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$CWD_TOP" && "$(norm "$CWD_TOP")" != "$HQ_ROOT" ]]; then
      exit 0
    fi
  fi
  block "Unanchored git/gh mutation with effective cwd at the HQ root (no \`git -C\`, no \`gh -R\`)."
fi

case "$ANCHOR_PATH" in
  /*|\~*) RESOLVED="$ANCHOR_PATH" ;;
  *)      RESOLVED="$HQ_ROOT/$ANCHOR_PATH" ;;
esac
RESOLVED="$(norm "$RESOLVED")"

TOPLEVEL="$(git -C "$RESOLVED" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$TOPLEVEL" ]]; then
  TOPLEVEL="$(norm "$TOPLEVEL")"
  if [[ "$TOPLEVEL" == "$HQ_ROOT" ]]; then
    block "Anchor ($ANCHOR_KIND -> $ANCHOR_PATH) resolves to the HQ root git repo."
  fi
fi

exit 0
