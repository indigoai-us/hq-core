#!/usr/bin/env bash
# Shared runtime for generated hq CLI forwarders.

forwarder_exec() {
  local script_name="$1" min_cli="$2" root_mode="$3" command="$4" stdin_closed="$5"
  shift 5
  local forwarder_library_dir="${BASH_SOURCE[0]%/*}"
  local path_rule index value path_option path_value
  local -a forwarded_args path_rules path_options path_values converted_values command_parts
  forwarded_args=("$@")
  local forwarded_arg_count=$#

  if [ "$root_mode" = live-project ]; then
    HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
  elif [ "$root_mode" = live ]; then
    HQ_ROOT="${HQ_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
  fi

  if ! command -v hq >/dev/null 2>&1; then
    printf "%s: requires the hq CLI — this script's implementation now ships with it.\n" "$script_name" >&2
    printf 'Install it with: npm install -g @indigoai-us/hq-cli\n' >&2
    exit 127
  fi

  [ "$forwarder_library_dir" != "${BASH_SOURCE[0]}" ] || forwarder_library_dir=.
  if [ -f "$forwarder_library_dir/hq-cli-floor.sh" ]; then
    # shellcheck source=lib/hq-cli-floor.sh
    . "$forwarder_library_dir/hq-cli-floor.sh"
    hq_cli_floor_check "$script_name" "$min_cli"
  fi

  if [ "$stdin_closed" = true ]; then
    if ! { true 3<&0; } 2>/dev/null; then
      export HQ_CORE_STDIN_CLOSED=1
    fi
  fi

  if [ "$root_mode" = live ] || [ "$root_mode" = live-project ]; then
    if command -v cygpath >/dev/null 2>&1; then
      HQ_ROOT="$(cygpath -m "$HQ_ROOT")"
    fi
  fi

  if command -v cygpath >/dev/null 2>&1; then
    IFS=';' read -r -a path_rules <<< "$PATH_OPERANDS"
    for path_rule in "${path_rules[@]}"; do
      case "$path_rule" in
        none) ;;
        position:*)
          index="${path_rule#position:}"
          if (( index < forwarded_arg_count )); then convert_forwarded_path "$index"; fi
          ;;
        first-nonoption)
          for ((index = 0; index < forwarded_arg_count; index++)); do
            case "${forwarded_args[index]}" in --*) ;; *) convert_forwarded_path "$index"; break ;; esac
          done
          ;;
        all-nonoptions)
          for ((index = 0; index < forwarded_arg_count; index++)); do
            case "${forwarded_args[index]}" in --*) ;; *) convert_forwarded_path "$index" ;; esac
          done
          ;;
        options:*)
          IFS=, read -r -a path_options <<< "${path_rule#options:}"
          for ((index = 0; index < forwarded_arg_count; index++)); do
            for path_option in "${path_options[@]}"; do
              case "${forwarded_args[index]}" in
                "$path_option")
                  index=$((index + 1))
                  if (( index < forwarded_arg_count )); then convert_forwarded_path "$index"; fi
                  break
                  ;;
                "$path_option"=*)
                  value="${forwarded_args[index]#*=}"
                  case "$value" in /*) forwarded_args[index]="${path_option}=$(cygpath -m "$value")" ;; esac
                  break
                  ;;
              esac
            done
          done
          ;;
        comma:*)
          path_option="${path_rule#comma:}"
          for ((index = 0; index < forwarded_arg_count; index++)); do
            case "${forwarded_args[index]}" in
              "$path_option")
                index=$((index + 1))
                if (( index < forwarded_arg_count )); then
                  IFS=, read -r -a path_values <<< "${forwarded_args[index]}"
                  converted_values=()
                  for path_value in "${path_values[@]}"; do
                    case "$path_value" in /*) converted_values+=("$(cygpath -m "$path_value")") ;; *) converted_values+=("$path_value") ;; esac
                  done
                  value="$(IFS=,; printf '%s' "${converted_values[*]}")"
                  forwarded_args[index]="$value"
                fi
                break
                ;;
              "$path_option"=*)
                value="${forwarded_args[index]#*=}"
                case "$value" in
                  /*,*|/*)
                    IFS=, read -r -a path_values <<< "$value"
                    converted_values=()
                    for path_value in "${path_values[@]}"; do
                      case "$path_value" in /*) converted_values+=("$(cygpath -m "$path_value")") ;; *) converted_values+=("$path_value") ;; esac
                    done
                    value="$(IFS=,; printf '%s' "${converted_values[*]}")"
                    forwarded_args[index]="${path_option}=$value"
                    ;;
                esac
                break
                ;;
            esac
          done
          ;;
        *) printf 'unknown path_operands rule: %s\n' "$path_rule" >&2; exit 70 ;;
      esac
    done
  fi

  IFS=' ' read -r -a command_parts <<< "$command"
  if [ "$root_mode" = live ] || [ "$root_mode" = live-project ]; then
    if [ "$forwarded_arg_count" -gt 0 ]; then
      MSYS2_ARG_CONV_EXCL='*' exec hq core --hq-root "$HQ_ROOT" "${command_parts[@]}" "${forwarded_args[@]}"
    else
      MSYS2_ARG_CONV_EXCL='*' exec hq core --hq-root "$HQ_ROOT" "${command_parts[@]}"
    fi
  elif [ "$forwarded_arg_count" -gt 0 ]; then
    MSYS2_ARG_CONV_EXCL='*' exec hq core "${command_parts[@]}" "${forwarded_args[@]}"
  else
    MSYS2_ARG_CONV_EXCL='*' exec hq core "${command_parts[@]}"
  fi
}

convert_forwarded_path() {
  local arg_index="$1"
  local value="${forwarded_args[$arg_index]}"
  case "$value" in
    /*) forwarded_args[$arg_index]="$(cygpath -m "$value")" ;;
  esac
}
