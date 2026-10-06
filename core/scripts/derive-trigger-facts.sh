#!/usr/bin/env bash
# FORWARDER — the implementation of this script now lives in the hq CLI.
#
# It ships at assets/scaffold/core/scripts/derive-trigger-facts.sh inside @indigoai-us/hq-cli and
# runs as the hidden command `hq core derive-trigger-facts`. This file stays behind so every
# existing caller — skills, other scripts, CI, and muscle memory — keeps working
# against the path it already knows.
#
# This hook-time helper runs on the hq core fast path and retains its
# bundled shell fallback while the core-native-hook-helpers flag is off.
#
# The ABI is preserved exactly: arguments are forwarded unchanged, stdin is never
# read by this file, stdout and stderr are inherited untouched, and the child
# replaces this process so its exit code and signal disposition become the
# caller's.

set -euo pipefail

# Hook-time helpers must not run the CLI self-updater inside the hook deadline.
export HQ_NO_UPDATE_CHECK=1

FORWARDER_PATH="${BASH_SOURCE[0]}"
FORWARDER_DIR="${FORWARDER_PATH%/*}"
[ "$FORWARDER_DIR" != "$FORWARDER_PATH" ] || FORWARDER_DIR=.
SCRIPT_DIR="$(cd "$FORWARDER_DIR" && pwd)"

# Preserve the original root precedence: HQ_ROOT, CLAUDE_PROJECT_DIR, then this tree.
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

if ! command -v hq >/dev/null 2>&1; then
  echo "derive-trigger-facts.sh: requires the hq CLI — this script's implementation now ships with it." >&2
  echo "Install it with: npm install -g @indigoai-us/hq-cli" >&2
  exit 127
fi

if [ -f "$SCRIPT_DIR/lib/hq-cli-floor.sh" ]; then
  # shellcheck source=lib/hq-cli-floor.sh
  . "$SCRIPT_DIR/lib/hq-cli-floor.sh"
  hq_cli_floor_check "derive-trigger-facts.sh" "5.342.5"
fi

# MSYS path conversion is disabled for the hq process so slash commands arrive unchanged.
# Convert only this generated root path to Windows form for the native CLI.
if command -v cygpath >/dev/null 2>&1; then
  HQ_ROOT="$(cygpath -m "$HQ_ROOT")"
fi

forwarded_args=("$@")
forwarded_arg_count=$#
PATH_OPERANDS=none
convert_forwarded_path() {
  local arg_index="$1"
  local value="${forwarded_args[$arg_index]}"
  case "$value" in
    /*) forwarded_args[$arg_index]="$(cygpath -m "$value")" ;;
  esac
}

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
      *) echo "unknown path_operands rule: $path_rule" >&2; exit 70 ;;
    esac
  done
fi
if [ "$forwarded_arg_count" -gt 0 ]; then
  MSYS2_ARG_CONV_EXCL='*' exec hq core --hq-root "$HQ_ROOT" derive-trigger-facts "${forwarded_args[@]}"
else
  MSYS2_ARG_CONV_EXCL='*' exec hq core --hq-root "$HQ_ROOT" derive-trigger-facts
fi
