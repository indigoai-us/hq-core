#!/usr/bin/env bash
# Block Git repository creation inside companies/, which is synced to every
# member device. This guard only examines GitHub/Git executable commands and
# exits before tokenization for every other Bash call.

set -uo pipefail

if [[ "${HQ_HOOK_TOOL_NAME+set}" == set && "$HQ_HOOK_TOOL_NAME" != "Bash" ]]; then
  exit 0
fi
if [[ "${HQ_HOOK_COMMAND+set}" == set ]]; then
  CMD="$HQ_HOOK_COMMAND"
  TOOL_CWD="${HQ_HOOK_CWD:-}"
else
  INPUT="$(cat)"
  CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
  TOOL_CWD="${HQ_HOOK_CWD:-$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)}"
fi
[[ -n "$CMD" ]] || exit 0

# Cheap pre-filter before shell tokenization. A bare clone from a cwd under
# companies/ still contains git/gh in its command text, so no cwd scan is
# needed to decide whether the parser can possibly find a relevant operation.
case "$CMD" in
  *git*|*gh*) ;;
  *) exit 0 ;;
esac

# An exact, standalone status command cannot create or populate a repository.
# Keep this deliberately narrow; quoted, compound, or otherwise ambiguous
# commands continue through the full parser below.
if [[ "$CMD" =~ ^git[[:space:]]+-C[[:space:]]+/[[:alnum:]_.:/-]+[[:space:]]+status$ ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
HOOK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$HOOK_ROOT/core/scripts/hook-lib.sh"

norm() {
  local path="$1" base="${2:-$PROJECT_DIR}" resolved tilde_prefix
  tilde_prefix="$(printf '\176/')"
  case "$path" in
    "~") path="$HOME" ;;
    "$tilde_prefix"*) path="$HOME/${path#"$tilde_prefix"}" ;;
    /*) ;;
    *) path="$base/$path" ;;
  esac
  resolved="$(hq_realpath_lenient "$path" 2>/dev/null || hq_normpath "$path" 2>/dev/null || printf '%s' "$path")"
  hq_canonical_path "$resolved"
}

HQ_ROOT="$(norm "$PROJECT_DIR")"
COMPANIES_ROOT="$(norm "$HQ_ROOT/companies")"
LOWER_COMPANIES_ROOT="$(printf '%s' "$COMPANIES_ROOT" | tr '[:upper:]' '[:lower:]')"

path_is_under_companies() {
  local path_lower
  path_lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$path_lower" in
    "$LOWER_COMPANIES_ROOT"|"$LOWER_COMPANIES_ROOT"/*) return 0 ;;
  esac
  return 1
}

repo_name_from_url() {
  local value="$1" name
  value="${value%%\?*}"
  value="${value%%\#*}"
  while [[ "$value" == */ ]]; do value="${value%/}"; done
  name="${value##*/}"
  name="${name##*:}"
  name="${name%.git}"
  printf '%s' "$name"
}

PARSED_TARGET=""

check_candidate() {
  local candidate="$1" base="$2" resolved
  [[ -n "$candidate" ]] || return 1
  resolved="$(norm "$candidate" "$base")"
  if path_is_under_companies "$resolved"; then
    PARSED_TARGET="$resolved"
    return 0
  fi
  return 1
}

parse_error() {
  PARSE_ERROR="$1"
  return 2
}

# Unknown options may take a value or may leave the next token as an operand.
# Inspect every remaining token before the parser makes either assumption.
unknown_option_company_target() {
  local start="$1" base="$2" j token value
  for (( j=start + 1; j<${#argv[@]}; j++ )); do
    token="${argv[j]}"
    if [[ "$token" == *=* ]]; then
      value="${token#*=}"
      if check_candidate "$value" "$base"; then return 0; fi
    fi
    if check_candidate "$token" "$base"; then return 0; fi
  done
  return 1
}

# Parse the Git commands that create or populate a repository. Arguments are
# tokenized by hq_shell_simple_commands; no shell text is evaluated here.
parse_git_record() {
  local record="$1" cwd="$2" executable executable_base i token subcommand
  local base="$cwd" operand="" repository="" destination="" metadata_dir="" end_options=0
  local -a argv=()
  PARSE_ERROR=""
  IFS=$'\037' read -r -a argv <<< "$record"
  executable="$(hq_shell_command_executable "$record" 2>/dev/null || true)"
  executable_base="${executable##*/}"
  executable_base="${executable_base##*\\}"
  [[ "$executable_base" == "git" || "$executable_base" == "git.exe" ]] || return 1

  i=0
  while (( i < ${#argv[@]} )); do
    [[ "${argv[i]}" == "$executable" ]] && break
    i=$((i + 1))
  done
  i=$((i + 1))
  subcommand=""
  while (( i < ${#argv[@]} )); do
    token="${argv[i]}"
    case "$token" in
      -C)
        i=$((i + 1)); (( i < ${#argv[@]} )) || return 1
        base="$(norm "${argv[i]}" "$base")"
        ;;
      -C?*) base="$(norm "${token#-C}" "$base")" ;;
      -c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix)
        i=$((i + 1)); (( i < ${#argv[@]} )) || return 1
        ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|-c=*) ;;
      -p|--paginate|--no-pager|--no-replace-objects|--bare|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs) ;;
      -*) ;;
      *) subcommand="$token"; break ;;
    esac
    i=$((i + 1))
  done
  [[ -n "$subcommand" ]] || return 1
  i=$((i + 1))

  case "$subcommand" in
    init)
      operand=""
      end_options=0
      while (( i < ${#argv[@]} )); do
        token="${argv[i]}"
        if [[ "$end_options" == 1 ]]; then
          [[ -z "$operand" ]] || return 1
          operand="$token"
        else
          case "$token" in
            --) end_options=1 ;;
            --help|-h) return 1 ;;
            --separate-git-dir)
              i=$((i + 1)); (( i < ${#argv[@]} )) || { parse_error "git init is missing the value for --separate-git-dir"; return 2; }
              metadata_dir="${argv[i]}"
              ;;
            --separate-git-dir=*) metadata_dir="${token#*=}" ;;
            -b|--initial-branch|--no-initial-branch|--template|--no-template|--object-format|--no-object-format|--ref-format|--no-ref-format|--no-separate-git-dir)
              i=$((i + 1)); (( i < ${#argv[@]} )) || { parse_error "git init is missing the value for $token"; return 2; }
              ;;
            -b?*) ;;
            --initial-branch=*|--no-initial-branch=*|--template=*|--no-template=*|--object-format=*|--no-object-format=*|--ref-format=*|--no-ref-format=*|--no-separate-git-dir=*|--shared=*|--bare|--no-bare|--quiet|--no-quiet|-q) ;;
            --shared) ;;
            -*)
              if unknown_option_company_target "$i" "$base"; then return 0; fi
              parse_error "git init has an unrecognized option: $token"
              return 2
              ;;
            *)
              if [[ -n "$operand" ]]; then parse_error "git init has more than one target"; return 2; fi
              operand="$token"
              ;;
          esac
        fi
        i=$((i + 1))
      done
      if [[ -n "$metadata_dir" ]] && check_candidate "$metadata_dir" "$base"; then return 0; fi
      [[ -n "$operand" ]] || operand="."
      check_candidate "$operand" "$base"
      return $?
      ;;
    clone)
      local -a operands
      operands=()
      end_options=0
      while (( i < ${#argv[@]} )); do
        token="${argv[i]}"
        if [[ "$end_options" == 1 ]]; then
          operands+=("$token")
        else
          case "$token" in
            --) end_options=1 ;;
            --help|-h) return 1 ;;
            -b|-o|-u|-j|-c|--branch|--no-branch|--origin|--no-origin|--upload-pack|--no-upload-pack|--reference|--no-reference|--reference-if-able|--no-reference-if-able|--depth|--no-depth|--shallow-since|--no-shallow-since|--shallow-exclude|--no-shallow-exclude|--jobs|--no-jobs|--template|--no-template|--server-option|--no-server-option|--separate-git-dir|--no-separate-git-dir|--revision|--no-revision|--ref-format|--no-ref-format|--filter|--no-filter|--bundle-uri|--config|--no-config)
              i=$((i + 1)); (( i < ${#argv[@]} )) || { parse_error "git clone is missing the value for $token"; return 2; }
              if [[ "$token" == "--separate-git-dir" ]]; then metadata_dir="${argv[i]}"; fi
              ;;
            --branch=*|--no-branch=*|--origin=*|--no-origin=*|--upload-pack=*|--no-upload-pack=*|--reference=*|--no-reference=*|--reference-if-able=*|--no-reference-if-able=*|--depth=*|--no-depth=*|--shallow-since=*|--no-shallow-since=*|--shallow-exclude=*|--no-shallow-exclude=*|--jobs=*|--no-jobs=*|--template=*|--no-template=*|--server-option=*|--no-server-option=*|--separate-git-dir=*|--no-separate-git-dir=*|--revision=*|--no-revision=*|--ref-format=*|--no-ref-format=*|--filter=*|--no-filter=*|--bundle-uri=*|--config=*|--no-config=*|-c=*)
              [[ "$token" == --separate-git-dir=* ]] && metadata_dir="${token#*=}"
              ;;
            --config=*|-b?*|-o?*|-u?*|-j?*|-c?*) ;;
            -q|-v|-l|-s|-n|-4|-6|--verbose|--no-verbose|--quiet|--no-quiet|--progress|--no-progress|--reject-shallow|--no-reject-shallow|--bare|--no-bare|--mirror|--no-mirror|--local|--no-local|--no-hardlinks|--hardlinks|--shared|--shared=*|--no-shared|--no-checkout|--checkout|--single-branch|--no-single-branch|--tags|--no-tags|--dissociate|--no-dissociate|--also-filter-submodules|--no-also-filter-submodules|--remote-submodules|--no-remote-submodules|--shallow-submodules|--no-shallow-submodules|--sparse|--no-sparse|--recursive|--no-recursive|--recurse-submodules|--no-recurse-submodules|--recursive=*|--no-recursive=*|--recurse-submodules=*|--no-recurse-submodules=*) ;;
            -*)
              if unknown_option_company_target "$i" "$base"; then return 0; fi
              if path_is_under_companies "$(norm "$base")"; then
                PARSED_TARGET="$(norm "$base")"
                return 0
              fi
              ;;
            *) operands+=("$token") ;;
          esac
        fi
        i=$((i + 1))
      done
      (( ${#operands[@]} > 0 )) || { parse_error "git clone is missing its repository argument"; return 2; }
      repository="${operands[0]}"
      if (( ${#operands[@]} > 1 )); then
        destination="${operands[1]}"
      else
        destination="$(repo_name_from_url "$repository")"
      fi
      if [[ -n "$metadata_dir" ]] && check_candidate "$metadata_dir" "$base"; then return 0; fi
      check_candidate "$destination" "$base"
      return $?
      ;;
    worktree)
      if [[ "${argv[i]:-}" != "add" ]]; then
        if [[ "${argv[i]:-}" == -* ]]; then
          local j
          for (( j=i + 1; j<${#argv[@]}; j++ )); do
            if [[ "${argv[j]}" == "add" ]]; then parse_error "git worktree has an unrecognized option before add"; return 2; fi
          done
        fi
        return 1
      fi
      i=$((i + 1))
      operand=""
      end_options=0
      while (( i < ${#argv[@]} )); do
        token="${argv[i]}"
        if [[ "$end_options" == 1 ]]; then
          [[ -n "$operand" ]] || operand="$token"
        else
          case "$token" in
            --) end_options=1 ;;
            --help|-h) return 1 ;;
            -b|-B|--reason)
              i=$((i + 1)); (( i < ${#argv[@]} )) || { parse_error "git worktree add is missing the value for $token"; return 2; }
              ;;
            --reason=*|--track=*|--lock=*) ;;
            -f|--force|--detach|--checkout|--no-checkout|--lock|--track|--guess-remote|--orphan) ;;
            -*) if unknown_option_company_target "$i" "$base"; then return 0; fi ;;
            *) [[ -n "$operand" ]] || operand="$token" ;;
          esac
        fi
        i=$((i + 1))
      done
      [[ -n "$operand" ]] || { parse_error "git worktree add is missing its path argument"; return 2; }
      check_candidate "$operand" "$base"
      return $?
      ;;
    submodule)
      while (( i < ${#argv[@]} )); do
        case "${argv[i]}" in
          -q|--quiet|--cached) i=$((i + 1)) ;;
          --help|-h) return 1 ;;
          -*)
            local j
            for (( j=i + 1; j<${#argv[@]}; j++ )); do
              if [[ "${argv[j]}" == "add" ]]; then parse_error "git submodule has an unrecognized global option before add"; return 2; fi
            done
            return 1
            ;;
          *) break ;;
        esac
      done
      [[ "${argv[i]:-}" == "add" ]] || return 1
      i=$((i + 1))
      local -a operands
      operands=()
      end_options=0
      while (( i < ${#argv[@]} )); do
        token="${argv[i]}"
        if [[ "$end_options" == 1 ]]; then
          operands+=("$token")
        else
          case "$token" in
            --) end_options=1 ;;
            --help|-h) return 1 ;;
            -b|--branch|--name|--reference|--depth)
              i=$((i + 1)); (( i < ${#argv[@]} )) || { parse_error "git submodule add is missing the value for $token"; return 2; }
              ;;
            --branch=*|--name=*|--reference=*|--depth=*) ;;
            -f|-q|--force|--quiet|--progress|--dissociate|--recursive) ;;
            -*) if unknown_option_company_target "$i" "$base"; then return 0; fi ;;
            *) operands+=("$token") ;;
          esac
        fi
        i=$((i + 1))
      done
      (( ${#operands[@]} > 0 )) || { parse_error "git submodule add is missing its repository argument"; return 2; }
      repository="${operands[0]}"
      if (( ${#operands[@]} > 1 )); then destination="${operands[1]}"; else destination="$(repo_name_from_url "$repository")"; fi
      check_candidate "$destination" "$base"
      return $?
      ;;
  esac
  return 1
}

parse_gh_record() {
  local record="$1" cwd="$2" executable executable_base i token repository destination
  local -a argv=()
  PARSE_ERROR=""
  IFS=$'\037' read -r -a argv <<< "$record"
  executable="$(hq_shell_command_executable "$record" 2>/dev/null || true)"
  executable_base="${executable##*/}"
  executable_base="${executable_base##*\\}"
  [[ "$executable_base" == "gh" || "$executable_base" == "gh.exe" ]] || return 1
  i=0
  while (( i < ${#argv[@]} )); do
    [[ "${argv[i]}" == "$executable" ]] && break
    i=$((i + 1))
  done
  i=$((i + 1))
  while (( i < ${#argv[@]} )) && [[ "${argv[i]}" == -* ]]; do
    token="${argv[i]}"
    case "$token" in
      --hostname|--repo|-R) i=$((i + 1)) ;;
      *) ;;
    esac
    i=$((i + 1))
  done
  [[ "${argv[i]:-}" == "repo" ]] || return 1
  i=$((i + 1))
  [[ "${argv[i]:-}" == "clone" ]] || return 1
  i=$((i + 1))
  [[ "${argv[i]:-}" != "--help" && "${argv[i]:-}" != "-h" ]] || return 1
  repository="${argv[i]:-}"
  [[ -n "$repository" ]] || { parse_error "gh repo clone is missing its repository argument"; return 2; }
  i=$((i + 1))
  destination=""
  while (( i < ${#argv[@]} )); do
    token="${argv[i]}"
    case "$token" in
      --hostname|--repo|-R) i=$((i + 1)) ;;
      --help|-h) return 1 ;;
      -*) ;;
      *) destination="$token"; break ;;
    esac
    i=$((i + 1))
  done
  [[ -n "$destination" ]] || destination="$(repo_name_from_url "$repository")"
  check_candidate "$destination" "$cwd"
  return $?
}

block() {
  local target="$1"
  cat >&2 <<EOF
BLOCKED: Git repositories cannot be created or populated under companies/.
Company folders sync to every member's devices, so put code in repos/private/<name> or repos/public/<name> to keep Git data out of company sync.
  Target: $target
EOF
  exit 2
}

block_parse_error() {
  local reason="$1" cwd="$2"
  cat >&2 <<EOF
BLOCKED: Could not safely parse Git repository creation command.
Reason: $reason
Current directory: $cwd
EOF
  exit 2
}

scan_commands() {
  local source="$1" cwd="$2" depth="$3" previous_cwd="$2"
  local record executable executable_base target payload token i
  local -a words
  if (( depth >= 8 )); then
    case "$source" in
      *git*|*gh*)
        if path_is_under_companies "$cwd"; then block "$cwd"; fi
        ;;
    esac
    return 0
  fi
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    executable="$(hq_shell_command_executable "$record" 2>/dev/null || true)"
    executable_base="${executable##*/}"
    executable_base="${executable_base##*\\}"
    case "$executable_base" in
      cd)
        IFS=$'\037' read -r -a words <<< "$record"
        i=0
        while (( i < ${#words[@]} )); do
          [[ "${words[i]}" == "$executable" ]] && break
          i=$((i + 1))
        done
        i=$((i + 1))
        [[ "${words[i]:-}" == "--" ]] && i=$((i + 1))
        case "${words[i]:-}" in
          -P|-L) i=$((i + 1)) ;;
        esac
        if (( i < ${#words[@]} )); then
          if [[ "${words[i]}" == "-" ]]; then cwd="$previous_cwd"; else previous_cwd="$cwd"; cwd="$(norm "${words[i]}" "$cwd")"; fi
        else
          previous_cwd="$cwd"
          cwd="$(norm "$HOME" "$cwd")"
        fi
        ;;
      bash|bash.exe|sh|sh.exe|zsh|zsh.exe|eval)
        IFS=$'\037' read -r -a words <<< "$record"
        i=0
        while (( i < ${#words[@]} )); do
          [[ "${words[i]}" == "$executable" ]] && break
          i=$((i + 1))
        done
        i=$((i + 1))
        payload=""
        if [[ "$executable_base" == "eval" ]]; then
          while (( i < ${#words[@]} )); do
            [[ -n "$payload" ]] && payload+=" "
            payload+="${words[i]}"
            i=$((i + 1))
          done
        else
          while (( i < ${#words[@]} )); do
            token="${words[i]}"
            if [[ "$token" == -* && "$token" != --* && "$token" == *c* ]]; then
              i=$((i + 1))
              payload="${words[i]:-}"
              break
            fi
            i=$((i + 1))
          done
        fi
        [[ -n "$payload" ]] && scan_commands "$payload" "$cwd" "$((depth + 1))"
        ;;
      git|git.exe)
        PARSED_TARGET=""
        if parse_git_record "$record" "$cwd"; then
          target="$PARSED_TARGET"
          [[ -n "$target" ]] && block "$target"
        else
          local parse_status=$?
          if [[ "$parse_status" -eq 2 ]]; then block_parse_error "$PARSE_ERROR" "$cwd"; fi
        fi
        ;;
      gh|gh.exe)
        PARSED_TARGET=""
        if parse_gh_record "$record" "$cwd"; then
          target="$PARSED_TARGET"
          [[ -n "$target" ]] && block "$target"
        else
          local parse_status=$?
          if [[ "$parse_status" -eq 2 ]]; then block_parse_error "$PARSE_ERROR" "$cwd"; fi
        fi
        ;;
    esac
  done < <(hq_shell_simple_commands "$source")
}

BASE_CWD="${TOOL_CWD:-$PROJECT_DIR}"
BASE_CWD="$(norm "$BASE_CWD" "$HQ_ROOT")"
scan_commands "$CMD" "$BASE_CWD" 0
exit 0
