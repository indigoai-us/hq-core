#!/usr/bin/env bash
# Shared hq-cli version-floor helpers for setup and the standalone hook doctor.
# Keep this compatible with macOS Bash 3.2 and Linux Bash 5.

HQ_CLI_FLOOR_UPGRADE_COMMAND='npm install -g @indigoai-us/hq-cli@latest'

# Print the top-level requiresHqCli value from core/core.yaml without yq.
# Return 1 when the key/file is absent and 2 when the key is duplicated.
hq_cli_floor_required() {
  local hq_root="$1"
  local core_yaml="${hq_root%/}/core/core.yaml"
  [ -r "$core_yaml" ] || return 1

  awk '
    BEGIN { found = 0; invalid = 0 }
    /^requiresHqCli[[:space:]]*:/ {
      if (found) { invalid = 1; next }
      found = 1
      value = $0
      sub(/^requiresHqCli[[:space:]]*:[[:space:]]*/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      sub(/^[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      quote = sprintf("%c", 39)
      first = substr(value, 1, 1)
      last = substr(value, length(value), 1)
      if ((first == "\"" && last == "\"") || (first == quote && last == quote)) {
        value = substr(value, 2, length(value) - 2)
      }
    }
    END {
      if (invalid) exit 2
      if (!found) exit 1
      print value
    }
  ' "$core_yaml"
}

# Resolve an executable through symlinks using portable readlink calls.
_hq_cli_floor_resolve_executable() {
  local executable="$1" link_dir link_target hops=0
  case "$executable" in
    /*) ;;
    *) executable="$PWD/$executable" ;;
  esac

  while [ -L "$executable" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || return 1
    link_dir="${executable%/*}"
    [ -n "$link_dir" ] || link_dir="/"
    link_dir="$(cd -P "$link_dir" 2>/dev/null && pwd)" || return 1
    link_target="$(readlink "$executable" 2>/dev/null)" || return 1
    case "$link_target" in
      /*) executable="$link_target" ;;
      *) executable="$link_dir/$link_target" ;;
    esac
  done

  [ -f "$executable" ] || return 1
  link_dir="${executable%/*}"
  [ -n "$link_dir" ] || link_dir="/"
  link_dir="$(cd -P "$link_dir" 2>/dev/null && pwd)" || return 1
  printf '%s/%s\n' "${link_dir%/}" "${executable##*/}"
}

_hq_cli_floor_package_version() {
  local package_json="$1"
  awk -F '"' '
    {
      for (i = 2; i + 2 <= NF; i += 4) {
        key = $i
        value = $(i + 2)
        if (key == "name" && package_name == "") package_name = value
        else if (key == "version" && package_version == "") package_version = value
      }
    }
    END {
      if (package_name == "@indigoai-us/hq-cli" && package_version != "") {
        print package_version
      }
    }
  ' "$package_json"
}

# Read the package version using shell builtins on the warm path. The npm
# package's top-level version is the first version key in its package.json.
_hq_cli_floor_package_version_builtin() {
  local package_json="$1" line
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ \"version\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done < "$package_json"
  return 1
}

# Return the installed CLI version without starting another Node process on the
# hook path. A package's version field is the same version reported by its
# generated hq entry point. Unrecognized or malformed installations retain the
# historical --version probe as a fallback.
_hq_cli_floor_installed_version() {
  local hq_command cached_schema cached_command cached_target cached_package_json cached_version current_package_version
  local cache_dir cache_file resolved dir package_json package_version parent raw_version parsed_version

  hq_command="$(command -v hq 2>/dev/null)" || return 127
  [ -n "$hq_command" ] || return 127

  # The cache hit path is intentionally shell-only. Compare the selected hq
  # entry point and its current target with the entry recorded on the cold
  # lookup; -nt also catches an in-place replacement of that target.
  cache_dir="${XDG_CACHE_HOME:-${HOME:-}/.cache}/hq-cli-floor"
  cache_file="$cache_dir/version"
  if [ -r "$cache_file" ]; then
    {
      IFS= read -r cached_schema || cached_schema=""
      IFS= read -r cached_command || cached_command=""
      IFS= read -r cached_target || cached_target=""
      IFS= read -r cached_package_json || cached_package_json=""
      IFS= read -r cached_version || cached_version=""
    } < "$cache_file"
    if [ "$cached_schema" = "hq-cli-floor.v2" ] &&
      [ "$cached_command" = "$hq_command" ] && [ -n "$cached_target" ] &&
      [ -n "$cached_package_json" ] && [ -n "$cached_version" ] &&
      _hq_cli_floor_parse_semver "$cached_version" >/dev/null 2>&1 &&
      [ -e "$cached_target" ] && [ -f "$cached_package_json" ] &&
      [ "$hq_command" -ef "$cached_target" ] &&
      ! [[ "$cached_target" -nt "$cache_file" ]] &&
      ! [[ "$cached_package_json" -nt "$cache_file" ]] &&
      current_package_version="$( _hq_cli_floor_package_version_builtin "$cached_package_json" )" &&
      [ "$current_package_version" = "$cached_version" ]; then
      printf '%s\n' "$cached_version"
      return 0
    fi
  fi

  resolved="$( _hq_cli_floor_resolve_executable "$hq_command" 2>/dev/null )" || resolved=""
  if [ -n "$resolved" ]; then
    dir="${resolved%/*}"
    while [ -n "$dir" ] && [ "$dir" != / ]; do
      package_json="$dir/package.json"
      if [ -f "$package_json" ]; then
        package_version="$( _hq_cli_floor_package_version "$package_json" 2>/dev/null )" || package_version=""
        if [ -n "$package_version" ]; then
          if mkdir -p "$cache_dir" 2>/dev/null; then
            local cache_tmp="$cache_file.$$"
            if {
              printf 'hq-cli-floor.v2\n'
              printf '%s\n' "$hq_command"
              printf '%s\n' "$resolved"
              printf '%s\n' "$package_json"
              printf '%s\n' "$package_version"
            } > "$cache_tmp" 2>/dev/null; then
              mv -f "$cache_tmp" "$cache_file" 2>/dev/null || rm -f "$cache_tmp" 2>/dev/null || true
            fi
          fi
          printf '%s\n' "$package_version"
          return 0
        fi
      fi
      parent="${dir%/*}"
      [ -n "$parent" ] || parent="/"
      [ "$parent" != "$dir" ] || break
      dir="$parent"
    done
    raw_version="$("$resolved" --version 2>/dev/null)" || return 1
  else
    raw_version="$(hq --version 2>/dev/null)" || return 1
  fi
  parsed_version="$(printf '%s\n' "$raw_version" | awk '
    match($0, /[v]?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?/) {
      version = substr($0, RSTART, RLENGTH)
      sub(/^v/, "", version)
      print version
      exit
    }
  ')"
  [ -n "$parsed_version" ] || return 1
  printf '%s\n' "$parsed_version"
}

# Parse strict SemVer fields into private globals for the comparator.
_hq_cli_floor_parse_semver() {
  local version="$1" core prerelease="" build="" identifier
  local -a identifiers=()

  case "$version" in
    *+*)
      build="${version#*+}"
      [[ "$build" != *+* ]] || return 1
      version="${version%%+*}"
      [[ "$build" =~ ^[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*$ ]] || return 1
      ;;
  esac
  case "$version" in
    *-*)
      prerelease="${version#*-}"
      version="${version%%-*}"
      [[ "$prerelease" =~ ^[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*$ ]] || return 1
      IFS=. read -r -a identifiers <<< "$prerelease"
      for identifier in "${identifiers[@]}"; do
        if [[ "$identifier" =~ ^[0-9]+$ ]] && [ "${#identifier}" -gt 1 ] && [[ "$identifier" == 0* ]]; then
          return 1
        fi
      done
      ;;
  esac

  core="$version"
  [[ "$core" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || return 1
  HQ_CLI_FLOOR_MAJOR="${BASH_REMATCH[1]}"
  HQ_CLI_FLOOR_MINOR="${BASH_REMATCH[2]}"
  HQ_CLI_FLOOR_PATCH="${BASH_REMATCH[3]}"
  HQ_CLI_FLOOR_PRERELEASE="$prerelease"
}

_hq_cli_floor_numeric_compare() {
  local left="$1" right="$2"
  if [ "${#left}" -lt "${#right}" ]; then
    HQ_CLI_FLOOR_CMP=-1
  elif [ "${#left}" -gt "${#right}" ]; then
    HQ_CLI_FLOOR_CMP=1
  elif [ "$left" = "$right" ]; then
    HQ_CLI_FLOOR_CMP=0
  elif [[ "$left" > "$right" ]]; then
    HQ_CLI_FLOOR_CMP=1
  else
    HQ_CLI_FLOOR_CMP=-1
  fi
}

_hq_cli_floor_prerelease_compare() {
  local left="$1" right="$2" i left_id right_id left_num right_num
  local -a left_parts=() right_parts=()
  IFS=. read -r -a left_parts <<< "$left"
  IFS=. read -r -a right_parts <<< "$right"

  for ((i = 0; i < ${#left_parts[@]} && i < ${#right_parts[@]}; i++)); do
    left_id="${left_parts[$i]}"
    right_id="${right_parts[$i]}"
    left_num=0
    right_num=0
    [[ "$left_id" =~ ^[0-9]+$ ]] && left_num=1
    [[ "$right_id" =~ ^[0-9]+$ ]] && right_num=1
    if [ "$left_num" -eq 1 ] && [ "$right_num" -eq 1 ]; then
      _hq_cli_floor_numeric_compare "$left_id" "$right_id"
    elif [ "$left_num" -eq 1 ]; then
      HQ_CLI_FLOOR_CMP=-1
    elif [ "$right_num" -eq 1 ]; then
      HQ_CLI_FLOOR_CMP=1
    elif [ "$left_id" = "$right_id" ]; then
      HQ_CLI_FLOOR_CMP=0
    elif [[ "$left_id" > "$right_id" ]]; then
      HQ_CLI_FLOOR_CMP=1
    else
      HQ_CLI_FLOOR_CMP=-1
    fi
    [ "$HQ_CLI_FLOOR_CMP" -eq 0 ] || return 0
  done

  if [ "${#left_parts[@]}" -lt "${#right_parts[@]}" ]; then
    HQ_CLI_FLOOR_CMP=-1
  elif [ "${#left_parts[@]}" -gt "${#right_parts[@]}" ]; then
    HQ_CLI_FLOOR_CMP=1
  else
    HQ_CLI_FLOOR_CMP=0
  fi
}

# Pure-Bash SemVer comparison. Returns 0 when have >= want, 1 when older, 2 if invalid.
hq_cli_version_ge() {
  local LC_ALL=C field left right have_prerelease want_prerelease
  _hq_cli_floor_parse_semver "$1" || return 2
  local have_major="$HQ_CLI_FLOOR_MAJOR" have_minor="$HQ_CLI_FLOOR_MINOR"
  local have_patch="$HQ_CLI_FLOOR_PATCH"
  have_prerelease="$HQ_CLI_FLOOR_PRERELEASE"

  _hq_cli_floor_parse_semver "$2" || return 2
  want_prerelease="$HQ_CLI_FLOOR_PRERELEASE"

  for field in major minor patch; do
    case "$field" in
      major) left="$have_major"; right="$HQ_CLI_FLOOR_MAJOR" ;;
      minor) left="$have_minor"; right="$HQ_CLI_FLOOR_MINOR" ;;
      patch) left="$have_patch"; right="$HQ_CLI_FLOOR_PATCH" ;;
    esac
    _hq_cli_floor_numeric_compare "$left" "$right"
    if [ "$HQ_CLI_FLOOR_CMP" -gt 0 ]; then
      return 0
    elif [ "$HQ_CLI_FLOOR_CMP" -lt 0 ]; then
      return 1
    fi
  done

  if [ -z "$have_prerelease" ]; then
    return 0
  elif [ -z "$want_prerelease" ]; then
    return 1
  fi

  _hq_cli_floor_prerelease_compare "$have_prerelease" "$want_prerelease"
  [ "$HQ_CLI_FLOOR_CMP" -ge 0 ]
}

# Return 0 when hq satisfies the floor; otherwise print the required message and return 127.
hq_cli_floor_check() {
  local script_name="$1" required="$2" minimum have compare_status
  if ! command -v hq >/dev/null 2>&1; then
    printf '%s: requires the hq CLI — this script\047s implementation now ships with it.\n' "$script_name" >&2
    printf 'Install it with: npm install -g @indigoai-us/hq-cli\n' >&2
    return 127
  fi

  case "$required" in
    '>='*) minimum="${required#>=}" ;;
    *) minimum="$required" ;;
  esac
  if ! _hq_cli_floor_parse_semver "$minimum"; then
    printf '%s: requiresHqCli has unsupported value %s; expected >=X.Y.Z.\n' "$script_name" "$required" >&2
    return 64
  fi

  have="$( _hq_cli_floor_installed_version )" || have=""
  if [ -z "$have" ]; then
    printf '%s: could not read hq --version; required hq-cli >= %s.\n' "$script_name" "$minimum" >&2
    return 126
  fi
  if hq_cli_version_ge "$have" "$minimum"; then
    return 0
  else
    compare_status=$?
  fi
  if [ "$compare_status" -gt 1 ]; then
    printf '%s: hq --version returned invalid SemVer %s; required hq-cli >= %s.\n' "$script_name" "$have" "$minimum" >&2
    return 126
  fi

  printf '%s: this script needs hq-cli >= %s (found %s); upgrade with: %s\n' \
    "$script_name" "$minimum" "$have" "$HQ_CLI_FLOOR_UPGRADE_COMMAND" >&2
  return 127
}
