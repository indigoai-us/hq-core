#!/bin/bash
# block-policy-writes-bash.sh — PreToolUse hook for Bash.
#
# Shell writes cannot be validated as a resulting document. Reject them when
# their target resolves to a live policy directory, and route authors through
# Write/Edit or /learn instead. This scanner deliberately evaluates one simple
# command at a time: a later `cd` must not change how an earlier write is read.
#
# core/policies/ deliberately stays out of this guard. block-core-writes-bash
# runs first and owns that broader release-scaffold denial, so users get one
# clear reason rather than two competing denials.
#
# Exit codes: 0 = allow, 2 = block.

set -uo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || true
[[ -z "$CMD" ]] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"
PROJECT_DIR="$(hq_normpath "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")"
CURRENT_CWD="$PROJECT_DIR"
TRACKED_VAR_NAMES=()
TRACKED_VAR_VALUES=()

esc_re() { printf '%s' "$1" | sed 's/[][\\.*^$(){}?+|]/\\&/g'; }
PROJECT_DIR_RE="$(esc_re "$PROJECT_DIR")"
PERSONAL_POLICY_RE="^${PROJECT_DIR_RE}/personal/policies(/|$)"
COMPANY_POLICY_RE="^${PROJECT_DIR_RE}/companies/[^/]+/policies(/|$)"
REPO_POLICY_RE="^${PROJECT_DIR_RE}/repos/(public|private)/[^/]+/\\.claude/policies(/|$)"
REPO_CONTEXT_RE="^${PROJECT_DIR_RE}/(repos/|workspace/worktrees/)"

# The marker is a narrow, audited route for writers that validate before their
# own write. It is only accepted for a single complete invocation. Do not turn
# it into a whole-payload bypass: a newline, separator, substitution, or a
# trailing semicolon is a separate command surface and is denied below.
is_exact_sanctioned_policy_writer() {
  local cmd="$1"
  [[ "$cmd" != *$'\n'* && "$cmd" != *';'* && "$cmd" != *'|'* && "$cmd" != *'&'* \
     && "$cmd" != *'$('* && "$cmd" != *'`'* ]] || return 1
  printf '%s' "$cmd" | grep -Eq \
    '^[[:space:]]*HQ_ALLOW_POLICY_WRITE=1[[:space:]]+(env[[:space:]]+)?(bash[[:space:]]+)?(\./)?core/scripts/(migrate-policy-triggers|policy-retire)\.sh([[:space:]][^[:cntrl:];|&]*)?[[:space:]]*$'
}

# A malformed attempt at the narrowly sanctioned route is denied rather than
# falling through as an ordinary no-op. In particular, this makes a trailing
# separator fail closed instead of inviting agents to extend the payload.
is_sanctioned_route_attempt() {
  local cmd="$1"
  printf '%s' "$cmd" | grep -Eq \
    '^[[:space:]]*HQ_ALLOW_POLICY_WRITE=1[[:space:]]+(env[[:space:]]+)?(bash[[:space:]]+)?(\./)?core/scripts/(migrate-policy-triggers|policy-retire)\.sh'
}

strip_token_quotes() {
  local tok="$1"
  case "$tok" in
    \"*\") tok="${tok#\"}"; tok="${tok%\"}" ;;
    \'*\') tok="${tok#\'}"; tok="${tok%\'}" ;;
  esac
  printf '%s' "$tok"
}

expand_known_path_vars() {
  local path="$1"
  path="${path//\$\{CLAUDE_PROJECT_DIR\}/$PROJECT_DIR}"
  path="${path//\$CLAUDE_PROJECT_DIR/$PROJECT_DIR}"
  path="${path//\$\{HQ_ROOT\}/$PROJECT_DIR}"
  path="${path//\$HQ_ROOT/$PROJECT_DIR}"
  path="${path//\$\{REPO_ROOT\}/$PROJECT_DIR}"
  path="${path//\$REPO_ROOT/$PROJECT_DIR}"
  path="${path//\$\{PWD\}/$CURRENT_CWD}"
  path="${path//\$PWD/$CURRENT_CWD}"
  printf '%s' "$path"
}

tracked_var_value() { # <name>
  local name="$1" i
  for ((i=0; i<${#TRACKED_VAR_NAMES[@]}; i++)); do
    [[ "${TRACKED_VAR_NAMES[$i]}" = "$name" ]] && { printf '%s' "${TRACKED_VAR_VALUES[$i]}"; return 0; }
  done
  return 1
}

expand_tracked_path_var() {
  local path="$1" name rest value
  if [[ "$path" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ ]]; then
    name="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
  elif [[ "$path" =~ ^\$([A-Za-z_][A-Za-z0-9_]*)(.*)$ ]]; then
    name="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
  else
    printf '%s' "$path"; return 0
  fi
  value="$(tracked_var_value "$name")" || { printf '%s' "$path"; return 0; }
  printf '%s%s' "$value" "$rest"
}

resolve_from_cwd() { # <raw path> -> lexical absolute path, or nothing
  local path
  path="$(strip_token_quotes "$1")"
  path="$(expand_known_path_vars "$path")"
  path="$(expand_tracked_path_var "$path")"
  path="$(expand_known_path_vars "$path")"
  [[ -n "$path" ]] || return 1
  case "$path" in
    /*) ;;
    ~*|\$*) return 1 ;; # unknown expansion: not a reliable live-HQ target
    *) path="$CURRENT_CWD/$path" ;;
  esac
  hq_normpath "$path"
}

is_policy_target() {
  local resolved
  resolved="$(resolve_from_cwd "$1")" || return 1
  [[ "$resolved" =~ $PERSONAL_POLICY_RE || "$resolved" =~ $COMPANY_POLICY_RE || "$resolved" =~ $REPO_POLICY_RE ]]
}

in_repo_context() {
  [[ "$CURRENT_CWD" =~ $REPO_CONTEXT_RE ]]
}

# Relative paths in a source checkout are repository-development work. Absolute
# paths remain live-root paths and are still checked by is_policy_target().
is_relative_target() {
  local path
  path="$(strip_token_quotes "$1")"
  path="$(expand_known_path_vars "$path")"
  path="$(expand_tracked_path_var "$path")"
  path="$(expand_known_path_vars "$path")"
  [[ "$path" != /* ]]
}

is_protected_write_target() {
  local target="$1"
  is_policy_target "$target" || return 1
  if is_relative_target "$target" && in_repo_context; then
    return 1
  fi
  return 0
}

record_argv() {
  local record="$1"
  IFS=$'\037' read -r -a ARGV <<< "$record"
}

is_assignment() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]
}

record_assignments() {
  local i tok name value j found
  for ((i=0; i<${#ARGV[@]}; i++)); do
    tok="${ARGV[$i]}"
    is_assignment "$tok" || continue
    name="${tok%%=*}"; value="${tok#*=}"; found=0
    for ((j=0; j<${#TRACKED_VAR_NAMES[@]}; j++)); do
      if [[ "${TRACKED_VAR_NAMES[$j]}" = "$name" ]]; then TRACKED_VAR_VALUES[$j]="$value"; found=1; break; fi
    done
    if [[ "$found" = 0 ]]; then
      TRACKED_VAR_NAMES[${#TRACKED_VAR_NAMES[@]}]="$name"
      TRACKED_VAR_VALUES[${#TRACKED_VAR_VALUES[@]}]="$value"
    fi
  done
}

argv_as_record() {
  local IFS=$'\037'
  printf '%s' "${ARGV[*]}"
}

argv_leading_command() {
  local tok
  for tok in "${ARGV[@]}"; do
    is_assignment "$tok" && continue
    printf '%s' "$tok"
    return 0
  done
  return 1
}

# A process launched by a wrapper cannot change the parent shell's cwd or
# assignments. Scan its argv using the same command analysis, then restore the
# parent state regardless of whether that child was a writer.
scan_argv_as_simple_command() { # <parent isolate flag> <argv...>
  local parent_isolate="${1:-0}" rc child_cwd="$CURRENT_CWD"
  shift
  local -a saved_argv=(${ARGV[@]+"${ARGV[@]}"}) \
    saved_names=(${TRACKED_VAR_NAMES[@]+"${TRACKED_VAR_NAMES[@]}"}) \
    saved_values=(${TRACKED_VAR_VALUES[@]+"${TRACKED_VAR_VALUES[@]}"})
  ARGV=("$@")
  scan_current_argv "$parent_isolate"; rc=$?
  CURRENT_CWD="$child_cwd"
  TRACKED_VAR_NAMES=(${saved_names[@]+"${saved_names[@]}"})
  TRACKED_VAR_VALUES=(${saved_values[@]+"${saved_values[@]}"})
  ARGV=(${saved_argv[@]+"${saved_argv[@]}"})
  return "$rc"
}

update_cwd() { # record that invokes cd or pushd
  local exe="$1" i=0 arg resolved
  [[ "$exe" = cd || "$exe" = pushd ]] || return 1
  while ((i < ${#ARGV[@]})); do
    if is_assignment "${ARGV[$i]}"; then i=$((i + 1)); continue; fi
    case "${ARGV[$i]}" in
      cd|pushd) i=$((i + 1)); break ;;
      *) i=$((i + 1)); continue ;;
    esac
  done
  for ((; i<${#ARGV[@]}; i++)); do
    arg="${ARGV[$i]}"
    [[ "$arg" = -* ]] && continue
    resolved="$(resolve_from_cwd "$arg")" || return 0
    CURRENT_CWD="$resolved"
    return 0
  done
  return 0
}

record_redirects_to_policy() {
  local i target
  for ((i=0; i<${#ARGV[@]}; i++)); do
    case "${ARGV[$i]}" in
      '>'|'>>'|'>|')
        target="${ARGV[$((i + 1))]:-}"
        [[ -n "$target" ]] && is_protected_write_target "$target" && return 0
        ;;
    esac
  done
  return 1
}

record_write_op_targets_policy() {
  local exe="$1" i=0 tok target_dir=""
  local -a positional=()
  case "$exe" in
    rm|rmdir|touch|mkdir|tee)
      for ((i=0; i<${#ARGV[@]}; i++)); do
        tok="${ARGV[$i]}"
        is_assignment "$tok" && continue
        case "$tok" in
          "$exe"|-*|--) continue ;;
          *) is_protected_write_target "$tok" && return 0 ;;
        esac
      done
      ;;
    cp|mv|rsync|install)
      for ((i=0; i<${#ARGV[@]}; i++)); do
        tok="${ARGV[$i]}"
        is_assignment "$tok" && continue
        case "$tok" in
          -t|--target-directory)
            i=$((i + 1)); target_dir="${ARGV[$i]:-}"
            ;;
          --target-directory=*) target_dir="${tok#--target-directory=}" ;;
          "$exe"|-*|--) continue ;;
          *) positional+=("$tok") ;;
        esac
      done
      if [[ -n "$target_dir" ]]; then
        is_protected_write_target "$target_dir" && return 0
      elif [[ "$exe" = mv ]]; then
        for tok in "${positional[@]}"; do is_protected_write_target "$tok" && return 0; done
      elif ((${#positional[@]})); then
        is_protected_write_target "${positional[$(( ${#positional[@]} - 1 ))]}" && return 0
      fi
      ;;
    dd)
      for tok in "${ARGV[@]}"; do
        case "$tok" in of=*) is_protected_write_target "${tok#of=}" && return 0 ;; esac
      done
      ;;
    sed)
      local inplace=0 skip_next=0
      for ((i=0; i<${#ARGV[@]}; i++)); do
        tok="${ARGV[$i]}"
        [[ "$tok" = sed ]] || is_assignment "$tok" && continue
        if ((skip_next)); then skip_next=0; continue; fi
        case "$tok" in
          -i|--in-place|-i*) inplace=1 ;;
          -e|-f|--expression|--file) skip_next=1 ;;
          -e*|-f*|--expression=*|--file=*|-*) ;;
          *) ((inplace)) && is_protected_write_target "$tok" && return 0 ;;
        esac
      done
      ;;
    awk)
      local inplace=0 program_seen=0
      for ((i=0; i<${#ARGV[@]}; i++)); do
        tok="${ARGV[$i]}"
        [[ "$tok" = awk ]] || is_assignment "$tok" && continue
        if [[ "$tok" = -i && "${ARGV[$((i + 1))]:-}" = inplace ]]; then inplace=1; i=$((i + 1)); continue; fi
        [[ "$tok" = -* ]] && continue
        if ((program_seen)); then ((inplace)) && is_protected_write_target "$tok" && return 0
        else program_seen=1; fi
      done
      ;;
    ln)
      for ((i=${#ARGV[@]}-1; i>=0; i--)); do
        tok="${ARGV[$i]}"
        [[ "$tok" = -* || "$tok" = ln ]] && continue
        is_protected_write_target "$tok" && return 0
        break
      done
      ;;
    chmod|chown|chgrp)
      local seen=0
      for tok in "${ARGV[@]}"; do
        [[ "$tok" = "$exe" || "$tok" = -* ]] || is_assignment "$tok" && continue
        if ((seen)); then is_protected_write_target "$tok" && return 0; else seen=1; fi
      done
      ;;
    truncate)
      local skip_next=0
      for ((i=0; i<${#ARGV[@]}; i++)); do
        tok="${ARGV[$i]}"
        [[ "$tok" = truncate ]] || is_assignment "$tok" && continue
        if ((skip_next)); then skip_next=0; continue; fi
        case "$tok" in
          -s|--size) skip_next=1 ;;
          --size=*|-*) ;;
          *) is_protected_write_target "$tok" && return 0 ;;
        esac
      done
      ;;
  esac
  return 1
}

record_git_targets_policy() {
  local i tok action="" after_separator=0 skip_next=0 git_cwd="$CURRENT_CWD" resolved protected=1
  for ((i=0; i<${#ARGV[@]}; i++)); do
    tok="${ARGV[$i]}"
    [[ "$tok" = git ]] || is_assignment "$tok" && continue
    if ((skip_next)); then skip_next=0; continue; fi
    if [[ -z "$action" ]]; then
      case "$tok" in
        -C)
          i=$((i + 1))
          resolved="$(resolve_from_cwd "${ARGV[$i]:-}")" && CURRENT_CWD="$resolved"
          ;;
        -C*)
          resolved="$(resolve_from_cwd "${tok#-C}")" && CURRENT_CWD="$resolved"
          ;;
        --git-dir|--work-tree) skip_next=1 ;;
        --git-dir=*|--work-tree=*|-*) ;;
        checkout|restore) action="$tok" ;;
      esac
      continue
    fi
    if ((after_separator)); then
      is_protected_write_target "$tok" && { protected=0; break; }
    elif [[ "$tok" = -- ]]; then
      after_separator=1
    fi
  done
  CURRENT_CWD="$git_cwd"
  return "$protected"
}

record_tar_targets_policy() {
  local i tok extract=0 skip_next=0
  local -a target_dirs=()
  for ((i=0; i<${#ARGV[@]}; i++)); do
    tok="${ARGV[$i]}"
    [[ "$tok" = tar ]] || is_assignment "$tok" && continue
    if ((skip_next)); then target_dirs+=("$tok"); skip_next=0; continue; fi
    case "$tok" in
      -C|--directory) skip_next=1 ;;
      --directory=*) target_dirs+=("${tok#--directory=}") ;;
      -x|--extract|--get|--extract=*) extract=1 ;;
      -*x*) extract=1 ;;
    esac
  done
  ((extract)) || return 1
  if ((${#target_dirs[@]} == 0)); then
    is_protected_write_target . && return 0
  else
    for tok in "${target_dirs[@]}"; do is_protected_write_target "$tok" && return 0; done
  fi
  return 1
}

record_find_start_paths() {
  local i=0 tok found_find=0 parsing_starts=1
  FIND_STARTS=()
  for ((i=0; i<${#ARGV[@]}; i++)); do
    tok="${ARGV[$i]}"
    if (( ! found_find )); then
      [[ "$tok" = find ]] && found_find=1
      continue
    fi
    ((parsing_starts)) || break
    case "$tok" in
      -H|-L|-P) continue ;;
      -O|-D) i=$((i + 1)); continue ;;
      --) continue ;;
      -*|!|'('|')') parsing_starts=0 ;;
      *) FIND_STARTS+=("$tok") ;;
    esac
  done
}

find_start_may_reach_live_policy() { # <find start path>
  local start="$1" resolved
  resolved="$(resolve_from_cwd "$start")" || return 1
  if is_relative_target "$start" && in_repo_context; then
    return 1
  fi
  is_policy_target "$start" && return 0
  case "$resolved" in
    "$PROJECT_DIR"|"$PROJECT_DIR/personal"|"$PROJECT_DIR/companies"|"$PROJECT_DIR/repos"|"$PROJECT_DIR/repos/public"|"$PROJECT_DIR/repos/private")
      return 0
      ;;
  esac
  [[ "$resolved" =~ ^${PROJECT_DIR_RE}/companies/[^/]+$ \
     || "$resolved" =~ ^${PROJECT_DIR_RE}/repos/(public|private)/[^/]+(/\.claude)?$ ]]
}

record_find_delete_target() {
  local tok
  local has_delete=0
  for tok in "${ARGV[@]}"; do [[ "$tok" = -delete ]] && has_delete=1; done
  ((has_delete)) || return 1
  record_find_start_paths
  if ((${#FIND_STARTS[@]} == 0)); then
    find_start_may_reach_live_policy . && return 0
  else
    for tok in "${FIND_STARTS[@]}"; do find_start_may_reach_live_policy "$tok" && return 0; done
  fi
  return 1
}

# find -execdir changes the child cwd to each match's directory. If a static
# start path is a policy directory (or an ancestor which can contain one),
# inspect relative child targets from a policy cwd. This is intentionally
# conservative: a broad execdir traversal can execute inside policy paths.
find_execdir_scan_cwd() {
  local tok resolved fallback=""
  record_find_start_paths
  ((${#FIND_STARTS[@]})) || FIND_STARTS=(.)
  for tok in "${FIND_STARTS[@]}"; do
    resolved="$(resolve_from_cwd "$tok")" || continue
    [[ -n "$fallback" ]] || fallback="$resolved"
    if is_policy_target "$tok"; then
      printf '%s' "$resolved"
      return 0
    fi
    if find_start_may_reach_live_policy "$tok"; then
      printf '%s' "$PROJECT_DIR/personal/policies"
      return 0
    fi
  done
  [[ -n "$fallback" ]] || return 1
  printf '%s' "$fallback"
}

scan_current_argv() { # <parent isolate flag>; ARGV is one simple command
  local parent_isolate="${1:-0}" record exe wrapper
  record_assignments
  wrapper="$(argv_leading_command || true)"

  # These wrappers obscure the executable from hq_shell_command_executable.
  # Re-enter the same argv analysis for their direct child before considering
  # the wrapper itself, so static cp/tee/mv/etc. receive normal target checks.
  case "$wrapper" in
    env|nohup|timeout|stdbuf|nice|sudo|parallel)
      scan_wrapper_payload "$wrapper" "$parent_isolate" && return 0
      ;;
  esac

  record="$(argv_as_record)"
  exe="$(hq_shell_command_executable "$record" || true)"
  update_cwd "$exe" || true
  record_redirects_to_policy && return 0
  case "$exe" in
    rm|rmdir|cp|mv|mkdir|touch|chmod|chown|chgrp|tee|dd|rsync|sed|awk|ln|install|truncate)
      record_write_op_targets_policy "$exe" && return 0
      ;;
    git) record_git_targets_policy && return 0 ;;
    tar) record_tar_targets_policy && return 0 ;;
  esac
  scan_wrapper_payload "$exe" "$parent_isolate"
}

scan_payload() { # <shell text> <isolate child cwd: 0|1>
  local payload="$1" isolate="${2:-0}" record saved_cwd="$CURRENT_CWD"
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    record_argv "$record"
    scan_current_argv "$isolate" && { CURRENT_CWD="$saved_cwd"; return 0; }
  done < <(hq_shell_simple_commands "$payload")
  if [[ "$isolate" = 1 ]]; then CURRENT_CWD="$saved_cwd"; fi
  return 1
}

scan_shell_c_argv() { # argv index at shell executable, child cwd isolation
  local i="$1" script=""
  for ((i=i+1; i<${#ARGV[@]}; i++)); do
    [[ "${ARGV[$i]}" = -c ]] || continue
    script="${ARGV[$((i + 1))]:-}"
    [[ -n "$script" ]] && scan_payload "$script" 1 && return 0
    return 1
  done
  return 1
}

scan_xargs_argv() { # <parent isolate flag>
  local parent_isolate="${1:-0}" i=0 tok next=()
  for ((i=0; i<${#ARGV[@]}; i++)); do
    tok="${ARGV[$i]}"
    [[ "$tok" = xargs ]] && { i=$((i + 1)); break; }
  done
  for ((; i<${#ARGV[@]}; i++)); do
    tok="${ARGV[$i]}"
    case "$tok" in
      -I|-n|-P|-L|-s|-E|-d) i=$((i + 1)); continue ;;
      -*) continue ;;
      *) next=("${ARGV[@]:i}"); break ;;
    esac
  done
  ((${#next[@]})) || return 1
  scan_argv_as_simple_command "$parent_isolate" "${next[@]}"
}

scan_find_exec_argv() { # <parent isolate flag>
  local parent_isolate="${1:-0}" i=0 tok next=() found=0 execdir_cwd="" saved_cwd rc
  record_find_delete_target && return 0
  for ((i=0; i<${#ARGV[@]}; i++)); do
    [[ "${ARGV[$i]}" = -exec || "${ARGV[$i]}" = -execdir ]] || continue
    execdir_cwd=""
    [[ "${ARGV[$i]}" = -execdir ]] && execdir_cwd="$(find_execdir_scan_cwd || true)"
    next=()
    i=$((i + 1))
    for ((; i<${#ARGV[@]}; i++)); do
      tok="${ARGV[$i]}"
      [[ "$tok" = ';' || "$tok" = + ]] && break
      next+=("$tok")
    done
    ((${#next[@]})) || continue
    found=1
    if [[ -n "$execdir_cwd" ]]; then
      saved_cwd="$CURRENT_CWD"
      CURRENT_CWD="$execdir_cwd"
      scan_argv_as_simple_command "$parent_isolate" "${next[@]}"; rc=$?
      CURRENT_CWD="$saved_cwd"
      ((rc == 0)) && return 0
    else
      scan_argv_as_simple_command "$parent_isolate" "${next[@]}" && return 0
    fi
  done
  ((found)) || return 1
  return 1
}

scan_parallel_argv() { # <parent isolate flag>
  local parent_isolate="${1:-0}" i=0 tok next=()
  for ((i=0; i<${#ARGV[@]}; i++)); do
    [[ "${ARGV[$i]}" = parallel ]] && { i=$((i + 1)); break; }
  done
  for ((; i<${#ARGV[@]}; i++)); do
    tok="${ARGV[$i]}"
    case "$tok" in
      -j|--jobs|--delay|--timeout) i=$((i + 1)); continue ;;
      --jobs=*|--delay=*|--timeout=*|-*) continue ;;
      :::|::::|--arg-file) break ;;
      *) next=("${ARGV[@]:i}"); break ;;
    esac
  done
  ((${#next[@]})) || return 1
  for ((i=0; i<${#next[@]}; i++)); do
    [[ "${next[$i]}" = ::: || "${next[$i]}" = :::: || "${next[$i]}" = --arg-file ]] && { next=("${next[@]:0:i}"); break; }
  done
  ((${#next[@]})) || return 1
  scan_argv_as_simple_command "$parent_isolate" "${next[@]}"
}

scan_process_wrapper_argv() { # <wrapper> <parent isolate flag>
  local wrapper="$1" parent_isolate="${2:-0}" i=0 tok next=() duration_seen=0
  for ((i=0; i<${#ARGV[@]}; i++)); do
    [[ "${ARGV[$i]}" = "$wrapper" ]] && { i=$((i + 1)); break; }
  done
  for ((; i<${#ARGV[@]}; i++)); do
    tok="${ARGV[$i]}"
    case "$wrapper" in
      env)
        case "$tok" in
          -u|--unset|-C|--chdir) i=$((i + 1)); continue ;;
          --unset=*|--chdir=*|-*|[A-Za-z_][A-Za-z0-9_]*=*) continue ;;
        esac
        ;;
      nohup)
        [[ "$tok" = -- ]] && continue
        [[ "$tok" = -* ]] && continue
        ;;
      nice)
        case "$tok" in -n|--adjustment) i=$((i + 1)); continue ;; --adjustment=*|-*) continue ;; esac
        ;;
      timeout)
        case "$tok" in
          -k|--kill-after|-s|--signal) i=$((i + 1)); continue ;;
          --kill-after=*|--signal=*|-*) continue ;;
        esac
        if (( ! duration_seen )); then duration_seen=1; continue; fi
        ;;
      stdbuf)
        case "$tok" in -i|-o|-e|--input|--output|--error) i=$((i + 1)); continue ;; --input=*|--output=*|--error=*|-*) continue ;; esac
        ;;
      sudo)
        case "$tok" in
          -u|--user|-g|--group|-h|--host|-C|--close-from|-p|--prompt|-r|--role|-t|--type) i=$((i + 1)); continue ;;
          --user=*|--group=*|--host=*|--close-from=*|--prompt=*|--role=*|--type=*|-*) continue ;;
        esac
        ;;
    esac
    next=("${ARGV[@]:i}")
    break
  done
  ((${#next[@]})) || return 1
  scan_argv_as_simple_command "$parent_isolate" "${next[@]}"
}

scan_wrapper_payload() { # <executable> <parent isolate flag>
  local exe="$1" parent_isolate="$2" i script
  case "$exe" in
    sh|bash|dash|zsh) scan_shell_c_argv 0; return $? ;;
    eval)
      script=""
      for ((i=0; i<${#ARGV[@]}; i++)); do
        [[ "${ARGV[$i]}" = eval ]] && { i=$((i + 1)); break; }
      done
      for ((; i<${#ARGV[@]}; i++)); do script="${script}${script:+ }${ARGV[$i]}"; done
      [[ -n "$script" ]] && scan_payload "$script" "$parent_isolate"
      return $?
      ;;
    xargs) scan_xargs_argv "$parent_isolate"; return $? ;;
    find) scan_find_exec_argv "$parent_isolate"; return $? ;;
    parallel) scan_parallel_argv "$parent_isolate"; return $? ;;
    env|nohup|timeout|stdbuf|nice|sudo) scan_process_wrapper_argv "$exe" "$parent_isolate"; return $? ;;
  esac
  return 1
}

if is_exact_sanctioned_policy_writer "$CMD"; then
  exit 0
fi

if is_sanctioned_route_attempt "$CMD" || scan_payload "$CMD" 0; then
  cat >&2 <<EOF
BLOCKED: Bash command appears to write a policy file.
  Command: $CMD

Policy directories are protected: personal/policies/, companies/<slug>/policies/,
and repos/{public|private}/<repo>/.claude/policies/.

Use the Write/Edit tool or /learn instead; those paths are validated.
EOF
  exit 2
fi

exit 0
