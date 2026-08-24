#!/usr/bin/env bash
# hq-core: public
# jobs-validate.sh — validate Outpost scheduled job YAML registry files.
#
# Usage:
#   core/scripts/jobs-validate.sh <file-or-dir> [file-or-dir...]
#
# Exits 0 when all jobs are valid; non-zero with per-field errors on stderr.
# Schema: core/knowledge/public/hq-core/outpost-jobs-spec.md
#
# Requires: yq (mikefarah), jq. Timezone checked via IANA-looking regex only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/secret-patterns.sh
. "$SCRIPT_DIR/lib/secret-patterns.sh"

ERRORS=0
declare -a SEEN_IDS=()

die_usage() {
  echo "usage: jobs-validate.sh <file-or-dir> [file-or-dir...]" >&2
  exit 2
}

err() {
  # err <file> <field> <message>
  printf 'jobs-validate: %s: %s: %s\n' "$1" "$2" "$3" >&2
  ERRORS=$((ERRORS + 1))
}

command -v yq >/dev/null 2>&1 || {
  echo "jobs-validate: yq is required (mikefarah/yq)" >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || {
  echo "jobs-validate: jq is required" >&2
  exit 2
}

[ "$#" -ge 1 ] || die_usage

collect_files() {
  local arg="$1"
  if [ -f "$arg" ]; then
    case "$arg" in
      *.yaml|*.yml) printf '%s\n' "$arg" ;;
      *) err "$arg" "path" "not a .yaml/.yml job file" ;;
    esac
    return
  fi
  if [ -d "$arg" ]; then
    # Prefer find -print0 / sort for stable duplicate-id detection order
    find "$arg" \( -name '*.yaml' -o -name '*.yml' \) -type f | sort
    return
  fi
  err "$arg" "path" "file or directory not found"
}

cron_num_in_range() {
  local n="$1" min="$2" max="$3"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  ((10#$n >= min && 10#$n <= max))
}

is_valid_cron_field() {
  # $1=value $2=min $3=max — *, */n, a-b, a-b/n, lists, dow/month names
  local v="$1" min="$2" max="$3" part base step a b
  local IFS=','
  set -f
  # shellcheck disable=SC2086
  set -- $v
  set +f
  for part in "$@"; do
    case "$part" in
      \*) continue ;;
      \*/*)
        step="${part#*/}"
        [[ "$step" =~ ^[1-9][0-9]*$ ]] || return 1
        continue
        ;;
      sun|mon|tue|wed|thu|fri|sat|SUN|MON|TUE|WED|THU|FRI|SAT)
        [ "$max" -eq 7 ] || return 1
        continue
        ;;
      jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)
        [ "$max" -eq 12 ] || return 1
        continue
        ;;
    esac
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)(/([1-9][0-9]*))?$ ]]; then
      a="${BASH_REMATCH[1]}"
      b="${BASH_REMATCH[2]}"
      cron_num_in_range "$a" "$min" "$max" || return 1
      cron_num_in_range "$b" "$min" "$max" || return 1
      ((10#$a <= 10#$b)) || return 1
      continue
    fi
    if [[ "$part" =~ ^([0-9]+)(/([1-9][0-9]*))?$ ]]; then
      base="${BASH_REMATCH[1]}"
      cron_num_in_range "$base" "$min" "$max" || return 1
      continue
    fi
    return 1
  done
  return 0
}

validate_cron() {
  local file="$1" cron="$2"
  # strip surrounding quotes leftovers
  cron="${cron#"${cron%%[![:space:]]*}"}"
  cron="${cron%"${cron##*[![:space:]]}"}"
  local -a fields
  # noglob: cron uses '*' which must not expand against the filesystem
  set -f
  # shellcheck disable=SC2206
  fields=($cron)
  set +f
  if [ "${#fields[@]}" -ne 5 ]; then
    err "$file" "schedule" "invalid cron — expected 5 fields (minute hour dom month dow), got ${#fields[@]}"
    return
  fi
  is_valid_cron_field "${fields[0]}" 0 59 || err "$file" "schedule" "invalid cron minute field '${fields[0]}'"
  is_valid_cron_field "${fields[1]}" 0 23 || err "$file" "schedule" "invalid cron hour field '${fields[1]}'"
  is_valid_cron_field "${fields[2]}" 1 31 || err "$file" "schedule" "invalid cron day-of-month field '${fields[2]}'"
  is_valid_cron_field "${fields[3]}" 1 12 || err "$file" "schedule" "invalid cron month field '${fields[3]}'"
  is_valid_cron_field "${fields[4]}" 0 7 || err "$file" "schedule" "invalid cron day-of-week field '${fields[4]}'"
}

looks_like_secret_name_ok() {
  # vault key name: UPPER_SNAKE / mixed alnum._:- without whitespace or credential shapes
  local s="$1"
  [[ "$s" =~ ^[A-Za-z][A-Za-z0-9._:/-]{0,127}$ ]] || return 1
  return 0
}

scan_string_for_secrets() {
  local file="$1" field="$2" value="$3"
  local tmp entry pattern name
  tmp="$(mktemp "${TMPDIR:-/tmp}/jobs-validate-secret.XXXXXX")"
  printf '%s' "$value" >"$tmp"
  for entry in "${SECRET_PATTERNS[@]}"; do
    pattern="${entry%%:*}"
    name="${entry#*:}"
    if grep -Eq "$pattern" "$tmp" 2>/dev/null; then
      err "$file" "$field" "inline credential-shaped value matched pattern '$name' (names only; never values)"
    fi
  done
  rm -f "$tmp"
}

validate_timezone() {
  local file="$1" tz="$2"
  if [[ ! "$tz" =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)+$ ]] && [[ "$tz" != "UTC" ]]; then
    err "$file" "timezone" "not an IANA-looking timezone '$tz'"
    return
  fi
}

json_type() {
  jq -r "$1 | type" <<<"$2" 2>/dev/null || echo "null"
}

# cwd must be HQ-root-relative: no absolute paths, no "."/".." components.
# Runtime resolves under HQ_ROOT; validate shape only (directory need not exist).
assert_cwd_safe() {
  local file="$1" field="$2" cwd="$3"
  [ -z "$cwd" ] && return 0
  case "$cwd" in
    /*)
      err "$file" "$field" "absolute cwd not allowed — use an HQ-root-relative path"
      return
      ;;
  esac
  local part
  local IFS='/'
  # shellcheck disable=SC2086
  for part in $cwd; do
    case "$part" in
      ''|.) ;;
      ..)
        err "$file" "$field" "cwd must not contain '..' path components"
        return
        ;;
    esac
  done
}

validate_job_file() {
  local file="$1"
  local json
  if ! json="$(yq -o=json '.' "$file" 2>/dev/null)"; then
    err "$file" "yaml" "failed to parse YAML"
    return
  fi
  if [ "$(jq -r 'type' <<<"$json")" != "object" ]; then
    err "$file" "yaml" "job root must be a mapping"
    return
  fi

  local id name schedule timezone runtime timeout notify enabled owner created_at
  id="$(jq -r '.id // empty' <<<"$json")"
  name="$(jq -r '.name // empty' <<<"$json")"
  schedule="$(jq -r '.schedule // empty' <<<"$json")"
  timezone="$(jq -r '.timezone // empty' <<<"$json")"
  runtime="$(jq -r '.runtime // empty' <<<"$json")"
  timeout="$(jq -r '.timeout_seconds // empty' <<<"$json")"
  notify="$(jq -r '.notify // empty' <<<"$json")"
  # jq's // treats boolean false as missing — use has() for enabled.
  enabled="$(jq -r 'if has("enabled") then (.enabled|tostring) else empty end' <<<"$json")"
  owner="$(jq -r '.owner // empty' <<<"$json")"
  created_at="$(jq -r '.created_at // empty' <<<"$json")"

  [ -n "$id" ] || err "$file" "id" "missing required field"
  [ -n "$name" ] || err "$file" "name" "missing required field"
  [ -n "$schedule" ] || err "$file" "schedule" "missing required field"
  [ -n "$timezone" ] || err "$file" "timezone" "missing required field"
  [ -n "$runtime" ] || err "$file" "runtime" "missing required field"
  [ -n "$timeout" ] || err "$file" "timeout_seconds" "missing required field"
  [ -n "$notify" ] || err "$file" "notify" "missing required field"
  [ -n "$enabled" ] || err "$file" "enabled" "missing required field"
  [ -n "$owner" ] || err "$file" "owner" "missing required field"
  [ -n "$created_at" ] || err "$file" "created_at" "missing required field"

  if [ -n "$id" ]; then
    if [[ ! "$id" =~ ^[a-z][a-z0-9-]{1,62}$ ]]; then
      err "$file" "id" "must match [a-z][a-z0-9-]{1,62}, got '$id'"
    fi
    local seen
    for seen in "${SEEN_IDS[@]+"${SEEN_IDS[@]}"}"; do
      if [ "$seen" = "$id" ]; then
        err "$file" "id" "duplicate id '$id'"
        break
      fi
    done
    SEEN_IDS+=("$id")
  fi

  # Reject natural-language leftovers — canonical form is 5 cron fields only.
  if [ -n "$schedule" ]; then
    local -a sf
    set -f
    # shellcheck disable=SC2206
    sf=($schedule)
    set +f
    if [ "${#sf[@]}" -ne 5 ]; then
      if [[ "$schedule" =~ [[:alpha:]] ]]; then
        err "$file" "schedule" "natural-language schedule is not allowed — store canonical cron only"
      else
        err "$file" "schedule" "invalid cron — expected 5 fields (minute hour dom month dow), got ${#sf[@]}"
      fi
    else
      validate_cron "$file" "$schedule"
    fi
  fi

  [ -n "$timezone" ] && validate_timezone "$file" "$timezone"

  case "$runtime" in
    '' ) ;;
    claude|codex) ;;
    *) err "$file" "runtime" "unknown runtime '$runtime' (allowed: claude|codex)" ;;
  esac

  # exec
  local exec_type prompt skill
  exec_type="$(json_type '.exec' "$json")"
  if [ "$exec_type" = "null" ]; then
    err "$file" "exec" "missing required field"
  elif [ "$exec_type" != "object" ]; then
    err "$file" "exec" "must be an object with prompt or skill"
  else
    prompt="$(jq -r '.exec.prompt // empty' <<<"$json")"
    skill="$(jq -r '.exec.skill // empty' <<<"$json")"
    if [ -z "$prompt" ] && [ -z "$skill" ]; then
      err "$file" "exec" "must set prompt or skill"
    elif [ -n "$prompt" ] && [ -n "$skill" ]; then
      err "$file" "exec" "set exactly one of prompt or skill, not both"
    fi
    [ -n "$prompt" ] && scan_string_for_secrets "$file" "exec.prompt" "$prompt"
    [ -n "$skill" ] && scan_string_for_secrets "$file" "exec.skill" "$skill"
    # scan args values
    if jq -e '.exec.args != null' <<<"$json" >/dev/null 2>&1; then
      if [ "$(json_type '.exec.args' "$json")" != "object" ]; then
        err "$file" "exec.args" "must be a mapping when present"
      else
        while IFS= read -r aval; do
          [ -z "$aval" ] && continue
          scan_string_for_secrets "$file" "exec.args" "$aval"
        done < <(jq -r '.exec.args | .. | strings' <<<"$json" 2>/dev/null)
      fi
    fi
  fi

  # timeout
  if [ -n "$timeout" ]; then
    if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
      err "$file" "timeout_seconds" "must be an integer, got '$timeout'"
    else
      if ((timeout < 60 || timeout > 14400)); then
        err "$file" "timeout_seconds" "must be between 60 and 14400, got $timeout"
      fi
    fi
  fi

  case "$notify" in
    '' ) ;;
    dm|none|profile) ;;
    *) err "$file" "notify" "unknown notify '$notify' (allowed: dm|none|profile)" ;;
  esac

  case "$enabled" in
    '' ) ;;
    true|false) ;;
    *)
      # yq may emit boolean; jq -r on bool gives true/false — if someone used string "yes"
      err "$file" "enabled" "must be boolean true|false, got '$enabled'"
      ;;
  esac

  if [ -n "$created_at" ]; then
    if [[ ! "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$ ]]; then
      err "$file" "created_at" "must be ISO-8601 datetime, got '$created_at'"
    fi
  fi

  # requirements — fixed vocabulary
  if jq -e '.requirements != null' <<<"$json" >/dev/null 2>&1; then
    if [ "$(json_type '.requirements' "$json")" != "object" ]; then
      err "$file" "requirements" "must be a mapping"
    else
      local key
      while IFS= read -r key; do
        [ -z "$key" ] && continue
        case "$key" in
          runtime|secrets|company|cwd|tools) ;;
          readiness|last_probe|last_run|failure_class|pending_probe)
            # status-shaped keys under requirements are unknown requirements keys
            err "$file" "requirements.$key" "unknown requirements key (status belongs in hq-pro, not requirements)"
            ;;
          *) err "$file" "requirements.$key" "unknown requirements key (allowed: runtime, secrets, company, cwd, tools)" ;;
        esac
      done < <(jq -r '.requirements | keys[]' <<<"$json")

      local req_runtime
      req_runtime="$(jq -r '.requirements.runtime // empty' <<<"$json")"
      if [ -n "$req_runtime" ]; then
        case "$req_runtime" in
          claude|codex) ;;
          *) err "$file" "requirements.runtime" "unknown runtime '$req_runtime' (allowed: claude|codex)" ;;
        esac
        if [ -n "$runtime" ] && [ "$req_runtime" != "$runtime" ]; then
          err "$file" "requirements.runtime" "mismatches top-level runtime ('$req_runtime' vs '$runtime')"
        fi
      fi

      if jq -e '.requirements.secrets != null' <<<"$json" >/dev/null 2>&1; then
        if [ "$(json_type '.requirements.secrets' "$json")" != "array" ]; then
          err "$file" "requirements.secrets" "must be an array of vault key names"
        else
          local secret
          while IFS= read -r secret; do
            [ -z "$secret" ] && continue
            scan_string_for_secrets "$file" "requirements.secrets" "$secret"
            if ! looks_like_secret_name_ok "$secret"; then
              # If it already matched a secret pattern, we still want the name-shape error for odd values
              err "$file" "requirements.secrets" "invalid vault key name '$secret' (use names only)"
            fi
            # Heuristic: KEY=value or PEM-ish or long high-entropy blob
            if [[ "$secret" == *"="* ]]; then
              err "$file" "requirements.secrets" "looks like KEY=value inline credential — names only"
            fi
          done < <(jq -r '.requirements.secrets[]?' <<<"$json")
        fi
      fi

      if jq -e '.requirements.tools != null' <<<"$json" >/dev/null 2>&1; then
        if [ "$(json_type '.requirements.tools' "$json")" != "array" ]; then
          err "$file" "requirements.tools" "must be an array of strings"
        fi
      fi

      local req_cwd
      req_cwd="$(jq -r '.requirements.cwd // empty' <<<"$json")"
      if [ -n "$req_cwd" ]; then
        assert_cwd_safe "$file" "requirements.cwd" "$req_cwd"
      fi

      local req_company
      req_company="$(jq -r '.requirements.company // empty' <<<"$json")"
      if [ -n "$req_company" ]; then
        if [[ ! "$req_company" =~ ^[a-z0-9]([a-z0-9_-]*[a-z0-9])?$ ]]; then
          err "$file" "requirements.company" "invalid company slug '$req_company' (lowercase kebab/underscore)"
        fi
      fi
    fi
  fi

  # Top-level cwd (legacy) — same containment rules
  local top_cwd
  top_cwd="$(jq -r '.cwd // empty' <<<"$json")"
  if [ -n "$top_cwd" ]; then
    assert_cwd_safe "$file" "cwd" "$top_cwd"
  fi

  # Top-level readiness is informational only — ignore (no error). Documented SoT is hq-pro.
}

# Expand args → file list
FILES=()
for arg in "$@"; do
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    FILES+=("$f")
  done < <(collect_files "$arg")
done

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "jobs-validate: no job YAML files found" >&2
  exit 1
fi

for f in "${FILES[@]}"; do
  validate_job_file "$f"
done

if [ "$ERRORS" -gt 0 ]; then
  echo "jobs-validate: $ERRORS error(s)" >&2
  exit 1
fi

exit 0
