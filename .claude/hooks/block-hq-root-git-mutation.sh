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
CMD_FROM_PAYLOAD=0
if [[ "${HQ_HOOK_COMMAND+set}" == set ]]; then
  CMD="$HQ_HOOK_COMMAND"
  TOOL_CWD="${HQ_HOOK_CWD:-}"
else
  # master-hook leaves HQ_HOOK_COMMAND unset for commands over its env cap,
  # and the adapters never set it. Read cwd and command in one `jq -j` call
  # inside one command substitution. `read` from a pipe takes one byte per
  # read() call, and on Git Bash each call is slow enough that a 10,000-line
  # command spent seconds here. Each field ends in a US byte, so the trailing
  # LF of the command survives the substitution (`jq -r` would leave jq.exe's
  # CR behind). The cwd goes first, with any US bytes removed, so only the
  # first US splits the fields. CRLF is collapsed after hook-lib.sh is
  # sourced below.
  CMD_FROM_PAYLOAD=1
  PAYLOAD_FIELDS="$(jq -j '(if (.cwd | type) == "string" then (.cwd | gsub("\u001f"; "")) else "" end), "\u001f", (.tool_input.command // ""), "\u001f"' 2>/dev/null)"
  PAYLOAD_CWD=""
  CMD=""
  if [[ "$PAYLOAD_FIELDS" == *$'\037'* ]]; then
    CMD="${PAYLOAD_FIELDS#*$'\037'}"
    PAYLOAD_CWD="${PAYLOAD_FIELDS:0:${#PAYLOAD_FIELDS} - ${#CMD} - 1}"
    CMD="${CMD%$'\037'}"
  fi
  PAYLOAD_FIELDS=""
  TOOL_CWD="${HQ_HOOK_CWD:-$PAYLOAD_CWD}"
fi
[[ -z "$CMD" ]] && exit 0

if [[ "${HQ_ALLOW_HQ_ROOT_GIT:-}" == "1" ]]; then exit 0; fi

GIT_MUTATION_WORDS='push|pull|fetch|clone|commit|merge|rebase|cherry-pick|revert|am|apply|format-patch|reset|restore|rm|mv|add|stage|checkout|switch|clean|gc|prune|repack|reflog|update-ref|update-index|filter-repo|filter-branch|fast-import|replace|fsck'

# Cheap prefilter. Quotes and backslashes can split a command name without
# changing what runs (g''it, "g"it, g\it), so a command with no literal "git"
# is matched again with those characters removed. One tr fork is used because
# ${CMD//...} is quadratic on bash 3.2 for long commands. A command name hidden
# behind $VAR, ${VAR}, $(...), or backticks leaves no "git" text at all, so a
# command with an expansion and a git mutation word also goes to the parser.
CMD_GIT_QUOTE_SPLIT=0
cmd_may_mutate_git() {
  case "$CMD" in *git*|*gh*|*hq-pr-create.sh*) return 0 ;; esac
  case "$CMD" in
    *[\'\"\\]*)
      case "$(printf '%s' "$CMD" | tr -d '\047\042\134')" in
        *git*) CMD_GIT_QUOTE_SPLIT=1; return 0 ;;
        *gh*|*hq-pr-create.sh*) return 0 ;;
      esac
      ;;
  esac
  case "$CMD" in
    *'$'*|*'`'*)
      [[ "$CMD" =~ (^|[^A-Za-z0-9_-])($GIT_MUTATION_WORDS)([^A-Za-z0-9_-]|$) ]] && return 0
      ;;
  esac
  return 1
}
cmd_may_mutate_git || exit 0
# This exact standalone read-only form needs no root lookup or git process.
# Keep the expression narrow so every compound or quoted form reaches the
# existing classifier.
if [[ "$CMD" =~ ^git[[:space:]]+-C[[:space:]]+(/[[:alnum:]_.:/-]+|[A-Za-z]:[/\\][[:alnum:]_.:/\\-]+)[[:space:]]+status$ ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
HOOK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$HOOK_ROOT/core/scripts/hook-lib.sh"
[[ "$CMD_FROM_PAYLOAD" -eq 1 ]] && hq_crlf_to_lf CMD TOOL_CWD
CMD="$(hq_shell_strip_standalone_data_heredoc "$CMD")"

STRICT_GIT_GUARD=0
if [[ "$CMD" == *git* || "$CMD_GIT_QUOTE_SPLIT" -eq 1 ]]; then
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

GIT_RE_MUTATION="^($GIT_MUTATION_WORDS)\$"
GIT_RE_READONLY='^(status|log|diff|show|shortlog|whatchanged|rev-parse|rev-list|describe|blame|annotate|cat-file|ls-files|ls-remote|ls-tree|for-each-ref|symbolic-ref|name-rev|var|version|help|count-objects|verify-pack|grep|archive|bisect|branch|tag|stash|remote|notes|config|worktree|submodule|check-ignore)$'

# git_subcommand <record> <executable>: set GIT_SUBCOMMAND to the first
# non-option word after the executable word of a US-delimited record, or
# return 1. It sets a variable instead of printing so the per-record classifier
# below starts no subshell. Matching the executable word itself, not the
# literal "git", covers /usr/bin/git, git.exe, and an unresolved $VAR.
GIT_SUBCOMMAND=""
git_subcommand() {
  local executable="$2" i t
  local -a arr
  hq_shell_record_words "$1"
  arr=(${HQ_SHELL_WORDS[@]+"${HQ_SHELL_WORDS[@]}"})
  GIT_SUBCOMMAND=""
  for ((i=0; i<${#arr[@]}; i++)); do
    [[ "${arr[i]}" == "$executable" ]] && break
  done
  for ((i=i+1; i<${#arr[@]}; i++)); do
    t="${arr[i]}"
    case "$t" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix) ((i++)); continue ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|-c=*) continue ;;
      -p|--paginate|--no-pager|--no-replace-objects|--bare|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs) continue ;;
      -*) continue ;;
      *) GIT_SUBCOMMAND="$t"; return 0 ;;
    esac
  done
  return 1
}

# hq_shell_simple_commands is the tokenizer of record. This only follows the
# already-parsed argv for the three explicit shell source forms and eval; it
# never evaluates a payload and does not parse shell syntax a second time.
RESOLVED_RECORDS=()
RESOLVED_TEXTS=()
RESOLVED_COMMAND=""
EXPANDED_PAYLOAD_TEXT=""
UNCLASSIFIED_GIT_WRAPPER=0
SSH_REMOTE_PAYLOAD=""

# Shell variables assigned anywhere in the command, in order, as parallel
# arrays (bash 3.2 has no associative arrays). A name assigned two different
# values cannot be resolved statically. GIT_ENV_PATHS holds every GIT_DIR and
# GIT_WORK_TREE value: once set or exported they redirect later git commands
# without any -C or cd, so each one is checked against the HQ repo.
ASSIGN_NAMES=()
ASSIGN_VALUES=()
GIT_ENV_PATHS=()

add_assignment() {
  [[ "$1" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || return 0
  ASSIGN_NAMES+=("${BASH_REMATCH[1]}")
  ASSIGN_VALUES+=("${BASH_REMATCH[2]}")
  case "${BASH_REMATCH[1]}" in
    GIT_DIR|GIT_WORK_TREE) GIT_ENV_PATHS+=("${BASH_REMATCH[2]}") ;;
  esac
}

# Record NAME=value words of one record: leading assignments (including those
# after env), and the arguments of export, declare, typeset, readonly, local.
record_assignments() {
  local record="$1" executable i n scan_args=0
  local -a words
  hq_shell_record_executable "$record" || true
  executable="$HQ_SHELL_EXECUTABLE"
  hq_shell_record_words "$record"
  words=(${HQ_SHELL_WORDS[@]+"${HQ_SHELL_WORDS[@]}"})
  n=${#words[@]}
  for ((i=0; i<n; i++)); do
    if [[ -n "$executable" && "${words[i]}" == "$executable" ]]; then
      case "$executable" in export|declare|typeset|readonly|local) scan_args=1 ;; esac
      break
    fi
    add_assignment "${words[i]}"
  done
  if [[ "$scan_args" -eq 1 ]]; then
    for ((i=i+1; i<n; i++)); do add_assignment "${words[i]}"; done
  fi
  return 0
}

# lookup_assignment <name>: set ASSIGN_VALUE to the one value the command
# assigns to <name>. HOME falls back to the environment; no other inherited
# variable is trusted, because the hook's environment is not the tool's.
ASSIGN_VALUE=""
lookup_assignment() {
  local name="$1" i found=0 value=""
  for ((i=0; i<${#ASSIGN_NAMES[@]}; i++)); do
    [[ "${ASSIGN_NAMES[i]}" == "$name" ]] || continue
    if [[ "$found" -eq 0 ]]; then
      value="${ASSIGN_VALUES[i]}"; found=1
    elif [[ "${ASSIGN_VALUES[i]}" != "$value" ]]; then
      return 1
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    [[ "$name" == HOME && -n "${HOME:-}" ]] || return 1
    value="$HOME"
  fi
  ASSIGN_VALUE="$value"
}

# resolve_shell_word <word>: set RESOLVED_WORD to <word> with each $NAME and
# ${NAME} replaced by its one assigned value. Return 1 for a name with no
# assignment or two values, for ${NAME<op>...}, special parameters ($1, $@),
# command substitution, backticks, or more than 32 replacements.
RESOLVE_RE_BRACED='^([^$]*)[$][{]([A-Za-z_][A-Za-z0-9_]*)[}](.*)$'
RESOLVE_RE_BARE='^([^$]*)[$]([A-Za-z_][A-Za-z0-9_]*)(.*)$'
RESOLVED_WORD=""
resolve_shell_word() {
  local word="$1" rounds=0 before name after
  RESOLVED_WORD=""
  while [[ "$word" == *'$'* || "$word" == *'`'* ]]; do
    rounds=$((rounds + 1))
    [[ "$rounds" -le 32 ]] || return 1
    case "$word" in *'`'*|*'$('*) return 1 ;; esac
    if [[ "$word" =~ $RESOLVE_RE_BRACED ]] || [[ "$word" =~ $RESOLVE_RE_BARE ]]; then
      before="${BASH_REMATCH[1]}"; name="${BASH_REMATCH[2]}"; after="${BASH_REMATCH[3]}"
      lookup_assignment "$name" || return 1
      word="$before$ASSIGN_VALUE$after"
    else
      return 1
    fi
  done
  RESOLVED_WORD="$word"
}

# Replace the executable word of a record with the whitespace-split words of
# its resolved value (G="git -C /x" runs `git -C /x`). Sets REWRITTEN_RECORD.
REWRITTEN_RECORD=""
rewrite_record_executable() {
  local executable="$2" value="$3" i done_exe=0 part
  local -a words
  hq_shell_record_words "$1"
  words=(${HQ_SHELL_WORDS[@]+"${HQ_SHELL_WORDS[@]}"})
  REWRITTEN_RECORD=""
  for ((i=0; i<${#words[@]}; i++)); do
    if [[ "$done_exe" -eq 0 && "${words[i]}" == "$executable" ]]; then
      done_exe=1
      while :; do
        value="${value#"${value%%[![:space:]]*}"}"
        [[ -n "$value" ]] || break
        part="${value%%[[:space:]]*}"
        value="${value#"$part"}"
        [[ -n "$REWRITTEN_RECORD" ]] && REWRITTEN_RECORD+=$'\037'
        REWRITTEN_RECORD+="$part"
      done
      continue
    fi
    [[ -n "$REWRITTEN_RECORD" ]] && REWRITTEN_RECORD+=$'\037'
    REWRITTEN_RECORD+="${words[i]}"
  done
}

# ssh forwards every argument after the destination as a remote command. Return
# that payload without evaluating it so the strict parser can classify nested
# git commands exactly like the explicit bash -c / eval forms below.
ssh_remote_payload() {
  local record="$1" executable token i j payload=""
  local -a words
  hq_shell_record_words "$record"
  words=(${HQ_SHELL_WORDS[@]+"${HQ_SHELL_WORDS[@]}"})
  hq_shell_record_executable "$record" || true
  executable="$HQ_SHELL_EXECUTABLE"
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

# split_lines <text>: store the non-empty lines of <text> in SPLIT_LINES.
# The record loops used to read records with `while read ... < <(...)`. Bash
# reads a pipe one byte per read() call, and on Git Bash those calls made a
# 10,000-line command take over 20 s. Splitting on IFS gives the same
# non-empty lines in-process. Globbing is off so a `*` word stays literal.
split_lines() {
  local IFS=$'\n' split_noglob=0
  case "$-" in *f*) split_noglob=1 ;; esac
  set -f
  # shellcheck disable=SC2206  # split on LF with globbing off, as above
  SPLIT_LINES=($1)
  [ "$split_noglob" -eq 1 ] || set +f
}

# join_lines <item>...: store the items joined by LF in JOINED_LINES.
join_lines() {
  local IFS=$'\n'
  JOINED_LINES="$*"
}

collect_resolved_records() {
  local source="$1" depth="$2" record executable executable_base text index token payload expanded i
  local -a words records
  if [[ "$depth" -ge 8 ]]; then
    case "$source" in *git*|*'$'*|*'`'*) UNCLASSIFIED_GIT_WRAPPER=1 ;; esac
    return 0
  fi
  # Copy the split records into a local array: the recursive calls below
  # overwrite SPLIT_LINES.
  split_lines "$(hq_shell_simple_commands "$source")"
  records=(${SPLIT_LINES[@]+"${SPLIT_LINES[@]}"})
  for record in ${records[@]+"${records[@]}"}; do
    [[ -n "$record" ]] || continue
    [[ "$record" == *=* ]] && record_assignments "$record"
    hq_shell_record_executable "$record" || true
    executable="$HQ_SHELL_EXECUTABLE"
    # A command name spelled through a variable ($G, ${G}, ${X}t) runs the
    # assigned value. Substitute it when the command assigns exactly one
    # value; an unresolved name is classified in the main loop below.
    if [[ "$executable" == *'$'* ]] && resolve_shell_word "$executable"; then
      rewrite_record_executable "$record" "$executable" "$RESOLVED_WORD"
      record="$REWRITTEN_RECORD"
      [[ -n "$record" ]] || continue
      hq_shell_record_executable "$record" || true
      executable="$HQ_SHELL_EXECUTABLE"
    fi
    executable_base="${executable##*/}"
    executable_base="${executable_base##*\\}"
    expanded=0
    # eval and the -c forms of bash, sh, and zsh run their payload in the
    # same cwd, so the payload is classified as if it were typed directly.
    # This runs with the strict flag off too: on main, `bash -c 'git push'`
    # at the HQ root was allowed unless the flag was on.
    case "$executable_base" in
      bash|bash.exe|sh|sh.exe|zsh|zsh.exe|eval)
        hq_shell_record_words "$record"
        words=(${HQ_SHELL_WORDS[@]+"${HQ_SHELL_WORDS[@]}"})
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
            EXPANDED_PAYLOAD_TEXT+="$payload"$'\n'
            collect_resolved_records "$payload" "$((depth+1))"
            expanded=1
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
      RESOLVED_TEXTS+=("${record//$'\037'/ }")
    fi
  done
}

simple_command_has_escape_assignment() {
  local record="$1" executable token i
  local -a words
  hq_shell_record_words "$record"
  words=(${HQ_SHELL_WORDS[@]+"${HQ_SHELL_WORDS[@]}"})
  hq_shell_record_executable "$record" || true
  executable="$HQ_SHELL_EXECUTABLE"
  for ((i=0; i<${#words[@]}; i++)); do
    token="${words[i]}"
    [[ "$token" == "$executable" ]] && return 1
    if [[ "$token" == "HQ_ALLOW_HQ_ROOT_GIT=1" ]]; then return 0; fi # gitleaks:allow
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
GH_MUTATION_RECORDS=()
GIT_MUTATION_RECORDS=()
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
  hq_shell_record_words "$record"
  words=(${HQ_SHELL_WORDS[@]+"${HQ_SHELL_WORDS[@]}"})
  hq_shell_record_executable "$record" || true
  executable="$HQ_SHELL_EXECUTABLE"
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

# join_git_path <base> <path>: <path> as git reads it after `-C <base>`.
join_git_path() {
  case "$2" in
    /*|\~*|[A-Za-z]:[/\\]*) JOINED_GIT_PATH="$2" ;;
    *) if [[ -n "$1" ]]; then JOINED_GIT_PATH="$1/$2"; else JOINED_GIT_PATH="$2"; fi ;;
  esac
}

# git_record_anchor <record>: find which repository and work tree a git record
# operates on. Only options before the subcommand count, so
# `git commit -C HEAD` is not an anchor. Sets:
#   GIT_REC_ANCHOR  the repository anchor: the git dir when GIT_DIR= or
#                   --git-dir names one, else the -C directory (-C options
#                   apply in order, as git does), else empty;
#   GIT_REC_EXTRA   a further path the command touches (the work tree from
#                   GIT_WORK_TREE= or --work-tree, or the -C directory when a
#                   git dir is named), checked like the anchor;
#   GIT_REC_IMPLICIT_TREE  1 when the work tree is the shell cwd. A git dir
#                   without a work tree uses the cwd as its work tree, so
#                   `GIT_DIR=<other>/.git git checkout -- .` at the HQ root
#                   still writes HQ files and stays under the cwd checks.
# A relative git dir or work tree is relative to the -C directory.
GIT_REC_ANCHOR=""
GIT_REC_EXTRA=""
GIT_REC_IMPLICIT_TREE=1
JOINED_GIT_PATH=""
git_record_anchor() {
  local record="$1" executable token i n c_target="" git_dir="" work_tree=""
  local -a words
  GIT_REC_ANCHOR=""; GIT_REC_EXTRA=""; GIT_REC_IMPLICIT_TREE=1
  hq_shell_record_executable "$record" || true
  executable="$HQ_SHELL_EXECUTABLE"
  [[ -n "$executable" ]] || return 0
  hq_shell_record_words "$record"
  words=(${HQ_SHELL_WORDS[@]+"${HQ_SHELL_WORDS[@]}"})
  n=${#words[@]}
  for ((i=0; i<n; i++)); do
    token="${words[i]}"
    [[ "$token" == "$executable" ]] && break
    case "$token" in
      GIT_DIR=*) git_dir="${token#GIT_DIR=}" ;;
      GIT_WORK_TREE=*) work_tree="${token#GIT_WORK_TREE=}" ;;
    esac
  done
  for ((i=i+1; i<n; i++)); do
    token="${words[i]}"
    case "$token" in
      -C)
        ((i++)); [[ "$i" -lt "$n" ]] || break
        join_git_path "$c_target" "${words[i]}"
        c_target="$JOINED_GIT_PATH"
        ;;
      --git-dir)
        ((i++)); [[ "$i" -lt "$n" ]] || break
        git_dir="${words[i]}"
        ;;
      --git-dir=*) git_dir="${token#--git-dir=}" ;;
      --work-tree)
        ((i++)); [[ "$i" -lt "$n" ]] || break
        work_tree="${words[i]}"
        ;;
      --work-tree=*) work_tree="${token#--work-tree=}" ;;
      -c|--namespace|--exec-path|--super-prefix) ((i++)) ;;
      -*) ;;
      *) break ;;
    esac
  done
  if [[ -n "$git_dir" ]]; then
    join_git_path "$c_target" "$git_dir"
    GIT_REC_ANCHOR="$JOINED_GIT_PATH"
    if [[ -n "$work_tree" ]]; then
      join_git_path "$c_target" "$work_tree"
      GIT_REC_EXTRA="$JOINED_GIT_PATH"
      GIT_REC_IMPLICIT_TREE=0
    elif [[ -n "$c_target" ]]; then
      GIT_REC_EXTRA="$c_target"
      GIT_REC_IMPLICIT_TREE=0
    fi
  elif [[ -n "$c_target" ]]; then
    GIT_REC_ANCHOR="$c_target"
    GIT_REC_IMPLICIT_TREE=0
    if [[ -n "$work_tree" ]]; then
      join_git_path "$c_target" "$work_tree"
      GIT_REC_EXTRA="$JOINED_GIT_PATH"
    fi
  elif [[ -n "$work_tree" ]]; then
    GIT_REC_EXTRA="$work_tree"
  fi
  return 0
}

# True when a gh record carries -R/--repo as its own argv word with a value:
# `-R o/r`, `--repo o/r`, `--repo=o/r`, `-Ro/r`. Matching argv words, not
# command text, keeps a quoted body such as `--body "see -R o/r"` from counting
# as an anchor.
gh_record_has_repo_flag() {
  local record="$1" executable token i command_index=-1
  local -a words
  hq_shell_record_words "$record"
  words=(${HQ_SHELL_WORDS[@]+"${HQ_SHELL_WORDS[@]}"})
  hq_shell_record_executable "$record" || true
  executable="$HQ_SHELL_EXECUTABLE"
  [[ -n "$executable" ]] || return 1
  for ((i=0; i<${#words[@]}; i++)); do
    if [[ "${words[i]}" == "$executable" ]]; then
      command_index=$((i + 1))
      break
    fi
  done
  [[ "$command_index" -ge 0 ]] || return 1
  for ((i=command_index; i<${#words[@]}; i++)); do
    token="${words[i]}"
    case "$token" in
      --) return 1 ;;
      -R|--repo)
        [[ -n "${words[i+1]:-}" && "${words[i+1]}" != -* ]] && return 0
        ;;
      --repo=?*|-R?*) return 0 ;;
    esac
  done
  return 1
}

# core/scripts/hq-pr-create.sh wraps `gh pr create`, so `bash <wrapper> ARGS`
# (or running the wrapper directly) is the same gh mutation. Rewrite the record
# to `gh pr create ARGS` in WRAPPER_GH_RECORD so the -R/--repo and cd anchor
# rules below apply to it unchanged.
WRAPPER_GH_RECORD=""
hq_pr_create_wrapper_record() {
  local record="$1" executable executable_base i
  local -a words
  # Every match below names hq-pr-create.sh, so skip the split otherwise.
  [[ "$record" == *hq-pr-create.sh* ]] || return 1
  hq_shell_record_words "$record"
  words=(${HQ_SHELL_WORDS[@]+"${HQ_SHELL_WORDS[@]}"})
  hq_shell_record_executable "$record" || true
  executable="$HQ_SHELL_EXECUTABLE"
  [[ -n "$executable" ]] || return 1
  for ((i=0; i<${#words[@]}; i++)); do
    [[ "${words[i]}" == "$executable" ]] && break
  done
  [[ "$i" -lt "${#words[@]}" ]] || return 1
  executable_base="${executable##*/}"
  case "$executable_base" in
    bash|bash.exe|sh|sh.exe|zsh|zsh.exe) i=$((i+1)) ;;
  esac
  case "${words[i]:-}" in
    core/scripts/hq-pr-create.sh|./core/scripts/hq-pr-create.sh|*/core/scripts/hq-pr-create.sh) ;;
    *) return 1 ;;
  esac
  WRAPPER_GH_RECORD="gh"$'\037'"pr"$'\037'"create"
  for ((i=i+1; i<${#words[@]}; i++)); do
    WRAPPER_GH_RECORD+=$'\037'"${words[i]}"
  done
  return 0
}

collect_resolved_records "$CMD" 0
# RESOLVED_COMMAND is every resolved record, words joined by spaces, one per
# line. It is built once here: appending to it per record copied the whole
# string each time, which grew with the square of the command length. The
# substitution runs per record because ${x//a/b} on one long string is also
# quadratic on Bash 3.2.
if [[ "${#RESOLVED_TEXTS[@]}" -gt 0 ]]; then
  join_lines "${RESOLVED_TEXTS[@]}"
  RESOLVED_COMMAND="$JOINED_LINES"$'\n'
fi
# The cd scan reads the command text plus every eval / sh -c payload, so a
# `cd` inside `bash -c '...'` anchors the git command next to it.
ANCHOR_SCAN_COMMAND="$CMD"
if [[ -n "$EXPANDED_PAYLOAD_TEXT" ]]; then
  ANCHOR_SCAN_COMMAND+=$'\n'"$EXPANDED_PAYLOAD_TEXT"
fi
if [[ "$STRICT_GIT_GUARD" -eq 1 ]]; then ANCHOR_SCAN_COMMAND="$RESOLVED_COMMAND"; fi
# Classify executable words, not arbitrary command text. A git phrase inside a
# summary, JSON payload, echo, or grep pattern is an argument, never a git
# operation. A record can hold an LF from a quoted word, so the records are
# joined and split again, as the earlier printf-and-read loop did.
join_lines ${RESOLVED_RECORDS[@]+"${RESOLVED_RECORDS[@]}"}
split_lines "$JOINED_LINES"
for shell_record in ${SPLIT_LINES[@]+"${SPLIT_LINES[@]}"}; do
  [ -n "$shell_record" ] || continue
  hq_shell_record_executable "$shell_record" || true
  shell_exe="$HQ_SHELL_EXECUTABLE"
  shell_text="${shell_record//$'\037'/ }"
  # Match the command's base name, so /usr/bin/git, git.exe, and a Windows
  # ...\Git\cmd\git.exe path are git too. A name still holding $ or a
  # backtick could not be resolved; it is treated as git only when the word
  # after it is a git mutation subcommand (`$GIT_BIN commit`).
  shell_exe_base="${shell_exe##*/}"
  shell_exe_base="${shell_exe_base##*\\}"
  case "$shell_exe_base" in
    [Gg][Ii][Tt]|[Gg][Ii][Tt].[Ee][Xx][Ee]) shell_kind=git ;;
    [Gg][Hh]|[Gg][Hh].[Ee][Xx][Ee]) shell_kind=gh ;;
    *'$'*|*'`'*) shell_kind=unresolved ;;
    *) shell_kind=other ;;
  esac
  case "$shell_kind" in
    git|unresolved)
      git_subcommand "$shell_record" "$shell_exe" || true
      shell_sub="$GIT_SUBCOMMAND"
      [ -n "$shell_sub" ] || continue
      shell_mutation=0
      if [[ "$shell_sub" =~ $GIT_RE_MUTATION ]]; then
        shell_mutation=1
      elif [[ "$shell_sub" =~ $GIT_RE_READONLY ]]; then
        is_dual_mutation "$shell_sub" "git ${shell_text#*"$shell_exe"}" && shell_mutation=1
      elif [[ "$shell_kind" == git ]]; then
        shell_mutation=1
      fi
      if [[ "$STRICT_GIT_GUARD" -eq 1 && "$shell_mutation" -eq 1 ]] \
         && simple_command_has_escape_assignment "$shell_record"; then
        shell_mutation=0
      fi
      if [ "$shell_mutation" -eq 1 ] && [ "$GIT_IS_MUTATION" -eq 0 ]; then
        GIT_IS_MUTATION=1; GIT_CMD="$shell_text"; SUB="$shell_sub"
      fi
      if [ "$shell_mutation" -eq 1 ]; then
        GIT_MUTATION_COUNT=$((GIT_MUTATION_COUNT + 1))
        GIT_MUTATION_RECORDS+=("$shell_record")
      fi
      ;;
    gh)
      if echo "$shell_text" | grep -Eq '^[^[:space:]]*[[:space:]]+(pr[[:space:]]+(create|merge|close|reopen|edit|comment|ready|review)|repo[[:space:]]+(create|delete|rename|archive|edit|sync|fork)|release[[:space:]]+(create|delete|edit|upload)|issue[[:space:]]+(create|close|edit|comment|delete)|api.*-X[[:space:]]*(POST|PUT|PATCH|DELETE))'; then
        if [ "$GH_IS_MUTATION" -eq 0 ]; then
          GH_IS_MUTATION=1
          GH_CMD="$shell_text"
        fi
        GH_MUTATION_RECORDS+=("$shell_record")
        GH_MUTATION_COUNT=$((GH_MUTATION_COUNT + 1))
      fi
      ;;
    *)
      if hq_pr_create_wrapper_record "$shell_record"; then
        if [ "$GH_IS_MUTATION" -eq 0 ]; then
          GH_IS_MUTATION=1
          GH_CMD="${WRAPPER_GH_RECORD//$'\037'/ }"
        fi
        GH_MUTATION_RECORDS+=("$WRAPPER_GH_RECORD")
        GH_MUTATION_COUNT=$((GH_MUTATION_COUNT + 1))
      fi
      ;;
  esac
done

# A command substitution in command position, `$(echo git) commit` or
# `\`which git\` push`, splits into records the classifier above cannot join
# back together. Match the text instead: a $(...) or backtick word at the start
# of a command, then options, then a git mutation subcommand. The match becomes
# an unanchored git record, so it is judged by the cd and cwd checks.
case "$CMD$EXPANDED_PAYLOAD_TEXT" in
  *'$('*|*'`'*)
    SUBST_TEXT="$CMD"$'\n'"$EXPANDED_PAYLOAD_TEXT"
    SUBST_LEAD='(^|[;&|({!'$'\n'']|then|do|else)[[:space:]]*'
    SUBST_WORD='([$][(][^()]*[)]|`[^`]*`)'
    SUBST_OPTS='([[:space:]]+(-[Cc][[:space:]]+[^[:space:];&|]+|-[^[:space:];&|]*))*'
    SUBST_RE="$SUBST_LEAD$SUBST_WORD${SUBST_OPTS}[[:space:]]+($GIT_MUTATION_WORDS)([[:space:];&|)]|\$)"
    if [[ "$SUBST_TEXT" =~ $SUBST_RE ]]; then
      if [ "$GIT_IS_MUTATION" -eq 0 ]; then
        GIT_IS_MUTATION=1; GIT_CMD="${BASH_REMATCH[0]}"; SUB="${BASH_REMATCH[5]}"
      fi
      GIT_MUTATION_COUNT=$((GIT_MUTATION_COUNT + 1))
      GIT_MUTATION_RECORDS+=("git"$'\037'"${BASH_REMATCH[5]}")
    fi
    ;;
esac

if [[ "$UNCLASSIFIED_GIT_WRAPPER" -eq 1 ]]; then
  GIT_IS_MUTATION=1
  GIT_CMD="git push"
  SUB="push"
  GIT_MUTATION_COUNT=$((GIT_MUTATION_COUNT + 1))
  GIT_MUTATION_RECORDS+=("git"$'\037'"push")
fi

[[ $GIT_IS_MUTATION -eq 0 && $GH_IS_MUTATION -eq 0 ]] && exit 0

ANCHOR_PATH=""
ANCHOR_KIND=""

# Each git mutation is judged on its own anchor. A `-C` on one git command does
# not apply to the next one: in `git -C <repo> commit && git push` the push runs
# in the shell cwd. GIT_C_ANCHORS holds the anchor (git dir or -C target) of
# every git mutation that has one, and GIT_EXTRA_PATHS the work trees they
# name. GIT_UNANCHORED is set when any git mutation has no anchor or uses the
# shell cwd as its work tree; those are judged through the cd / cwd checks.
GIT_C_ANCHORS=()
GIT_EXTRA_PATHS=()
GIT_UNANCHORED=0
if [[ $GIT_IS_MUTATION -eq 1 ]]; then
  for git_mutation_record in "${GIT_MUTATION_RECORDS[@]}"; do
    git_record_anchor "$git_mutation_record"
    [[ -n "$GIT_REC_ANCHOR" ]] && GIT_C_ANCHORS+=("$GIT_REC_ANCHOR")
    [[ -n "$GIT_REC_EXTRA" ]] && GIT_EXTRA_PATHS+=("$GIT_REC_EXTRA")
    [[ "$GIT_REC_IMPLICIT_TREE" -eq 1 ]] && GIT_UNANCHORED=1
  done
fi

# A gh mutation that names its repository (-R/--repo, or a positional repo
# target) runs against that remote repository whatever the shell cwd is, so a
# `cd` elsewhere in the command cannot redirect it. When EVERY gh mutation in
# the command carries its own anchor, the gh side is satisfied:
#   - with no git mutation, allow (a preceding `cd <HQ root>` is irrelevant);
#   - with a git mutation, drop the gh side and judge the git mutation alone
#     through the -C / cd / cwd checks below.
# One unanchored gh mutation keeps the whole gh side under the cd/cwd checks,
# so `gh pr merge 12 && gh pr view 12 -R o/r` at the HQ root stays blocked.
if [[ $GH_IS_MUTATION -eq 1 && ${#GH_MUTATION_RECORDS[@]} -gt 0 ]]; then
  all_gh_anchored=1
  for gh_mutation_record in "${GH_MUTATION_RECORDS[@]}"; do
    if ! gh_record_has_repo_flag "$gh_mutation_record" \
       && ! gh_positional_repo_anchor "$gh_mutation_record"; then
      all_gh_anchored=0
      break
    fi
  done
  if [[ "$all_gh_anchored" -eq 1 ]]; then
    [[ $GIT_IS_MUTATION -eq 0 ]] && exit 0
    GH_IS_MUTATION=0
  fi
fi

# Every mutation carries its own -C: the first -C is the primary anchor and the
# rest are verified below. Otherwise the unanchored ones fall to the cd scan.
if [[ $GIT_IS_MUTATION -eq 1 && $GIT_UNANCHORED -eq 0 && $GH_IS_MUTATION -eq 0 \
      && ${#GIT_C_ANCHORS[@]} -gt 0 ]]; then
  ANCHOR_PATH="${GIT_C_ANCHORS[0]}"
  ANCHOR_KIND="git -C"
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
      # `cd "$D"` is compared through D's assigned value. One that cannot be
      # resolved is kept as the anchor; check_anchor_not_hq_root blocks it.
      cd_compare="$CDP"
      if [[ "$CDP" == *'$'* || "$CDP" == *'`'* ]]; then
        resolve_shell_word "$CDP" || break
        cd_compare="$RESOLVED_WORD"
      fi
      [[ "$(norm "$cd_compare")" == "$HQ_ROOT" ]] && break
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

if [[ "$UNCLASSIFIED_GIT_WRAPPER" -eq 1 ]]; then
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

# HQ's own git dir, for the comparisons below. If HQ_ROOT has a .git entry but
# git cannot resolve it (dubious ownership, a broken gitdir file, a path
# spelling git rejects), an empty value would make every comparison allow.
# Deny instead: the target cannot be proven to be outside the HQ repo.
hq_root_git_dir() {
  hq_git="$(git -C "$HQ_ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [[ -z "$hq_git" ]] && [[ -e "$HQ_ROOT/.git" || -L "$HQ_ROOT/.git" ]]; then
    block "HQ root has a .git entry, but git could not resolve its git dir. Cannot prove the target is outside the HQ root repo."
  fi
}

# Block when a git anchor path resolves to the HQ root repository.
# Compare git's own absolute git dir for both paths. norm(PROJECT_DIR) and
# norm(git show-toplevel) are different strings on Git Bash when one side is
# /tmp and the other is C:/Users/.../Temp, or when a drive path was prefixed
# onto HQ_ROOT because it did not match "/*". Git prints one spelling for
# both -C invocations, so that comparison still matches.
#
# A path holding $NAME is compared through the name's one assigned value; one
# that cannot be resolved blocks. A relative path is checked from the cwd the
# harness reported, or from the HQ root when it reported none.
check_anchor_not_hq_root() {
  local kind="$1" path="$2" literal="$2"
  if [[ "$path" == *'$'* || "$path" == *'`'* ]]; then
    resolve_shell_word "$path" \
      || block "Anchor ($kind -> $path) uses a shell expansion the guard cannot resolve. Use a literal path."
    literal="$RESOLVED_WORD"
  fi
  if hq_path_is_absolute "$literal" || [[ "$literal" == \~* ]]; then
    check_git_dir_not_hq_root "$kind" "$path" "$literal"
  elif [[ -n "$TOOL_CWD" ]] && hq_path_is_absolute "$TOOL_CWD"; then
    # A relative -C (for example `git -C .`) runs against the shell cwd the
    # harness reported, not the HQ root (feedback_a6e3a675). A worktree below
    # HQ has its own git dir, so it no longer reads as an HQ-root mutation.
    check_git_dir_not_hq_root "$kind" "$path" "$TOOL_CWD/$literal"
  else
    check_git_dir_not_hq_root "$kind" "$path" "$HQ_ROOT/$literal"
  fi
}

check_git_dir_not_hq_root() {
  local kind="$1" path="$2" resolved target_git grok_worktrees
  resolved="$(norm "$3")"
  target_git="$(git -C "$resolved" rev-parse --absolute-git-dir 2>/dev/null || true)"
  [[ -n "$target_git" ]] || return 0
  hq_root_git_dir
  [[ -n "$hq_git" && "$(norm "$target_git")" == "$(norm "$hq_git")" ]] || return 0
  # grok --worktree materializes a full HQ-shaped clone under
  # ~/.grok/worktrees. The adapter then adopts that clone as HQ_ROOT, so
  # every `git -C <worktree>` looks like a mutation of the orchestration
  # repo. That clone is the repo the session is editing. The orchestration
  # checkout (any HQ root outside that directory) stays blocked.
  # (Ported from #1328, fix/hook-false-denials.)
  grok_worktrees="$(norm "${HOME:-}/.grok/worktrees")"
  case "$HQ_ROOT" in
    "$grok_worktrees"/*) return 0 ;;
  esac
  block "Anchor ($kind -> $path) resolves to the HQ root git repo."
}

# Every git -C target must be outside the HQ root repo, including the ones
# after the first. This runs before the cwd fallback so a non-HQ cwd cannot
# excuse a `git -C <HQ root>` elsewhere in the command.
for git_c_target in "${GIT_C_ANCHORS[@]+"${GIT_C_ANCHORS[@]}"}"; do
  check_anchor_not_hq_root "git -C" "$git_c_target"
done
for git_extra_path in "${GIT_EXTRA_PATHS[@]+"${GIT_EXTRA_PATHS[@]}"}"; do
  check_anchor_not_hq_root "git work tree" "$git_extra_path"
done
# GIT_DIR / GIT_WORK_TREE assigned or exported anywhere in the command redirect
# every later git command, whatever its -C or cwd.
if [[ $GIT_IS_MUTATION -eq 1 ]]; then
  for git_env_path in "${GIT_ENV_PATHS[@]+"${GIT_ENV_PATHS[@]}"}"; do
    check_anchor_not_hq_root "GIT_DIR/GIT_WORK_TREE" "$git_env_path"
  done
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
    # Same git-dir comparison as the -C check. A /tmp cwd whose git toplevel
    # is C:/Users/.../Temp used to look like a different repo and allow.
    cwd_git="$(git -C "$TOOL_CWD" rev-parse --absolute-git-dir 2>/dev/null || true)"
    [[ -n "$cwd_git" ]] && hq_root_git_dir
    if [[ -n "$cwd_git" && "$(norm "$cwd_git")" != "$(norm "$hq_git")" ]]; then
      exit 0
    fi
  fi
  block "Unanchored git/gh mutation with effective cwd at the HQ root (no \`git -C\`, no \`gh -R\`)."
fi

check_anchor_not_hq_root "$ANCHOR_KIND" "$ANCHOR_PATH"

exit 0
