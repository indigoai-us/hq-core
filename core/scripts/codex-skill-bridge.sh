#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "${SCRIPT_DIR}/../.claude" ]]; then
  DEFAULT_HQ_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
else
  DEFAULT_HQ_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi

HQ_ROOT="${HQ_ROOT:-${DEFAULT_HQ_ROOT}}"
COMMAND=""
REPAIR_LOCAL_CONFIG=0
DRY_RUN=0
OLD_ROOTS=()
STATUS_FAILURES=0

usage() {
  cat <<'EOF'
Usage:
  scripts/codex-skill-bridge.sh status [--root <path>]
  scripts/codex-skill-bridge.sh install [--root <path>] [--repair-local-config] [--old-root <path>]
  scripts/codex-skill-bridge.sh doctor [--root <path>] [--old-root <path>] [--dry-run]

Commands:
  status   Show bridge health, output-style bridge health, and stale HQ roots without changing files.
  install  Install or repair HQ-owned Claude -> Codex bridges.
  doctor   Repair bridges and rewrite local machine config from old HQ roots to this root.

Options:
  --root <path>             HQ root to repair. Defaults to this script's parent.
  --old-root <path>         Old HQ root to rewrite. Repeatable. Auto-detected when omitted.
  --repair-local-config     With install, also rewrite local config paths.
  --dry-run                 With doctor, print intended config rewrites without changing files.
EOF
}

fail() {
  echo "$*" >&2
  exit 1
}

canonical_dir() {
  local path="$1"
  (cd "${path}" && pwd)
}

configure_paths() {
  HQ_ROOT="$(canonical_dir "${HQ_ROOT}")"
  SKILLS_SOURCE_DIR="${HQ_ROOT}/.claude/skills"
  CLAUDE_SOURCE_DIR="${HQ_ROOT}/.claude"
  COMMANDS_SOURCE_DIR="${CLAUDE_SOURCE_DIR}/commands"
  HOOKS_SOURCE_DIR="${CLAUDE_SOURCE_DIR}/hooks"
  POLICIES_SOURCE_DIR="${CLAUDE_SOURCE_DIR}/policies"
  SETTINGS_SOURCE_FILE="${CLAUDE_SOURCE_DIR}/settings.json"
  OUTPUT_STYLES_SOURCE_DIR="${CLAUDE_SOURCE_DIR}/output-styles"
  GLOBAL_SKILLS_TARGET_DIR="${HOME}/.codex/skills/hq"
  GLOBAL_AGENTS_SKILLS_TARGET_DIR="${HOME}/.agents/skills/hq"
  REPO_AGENTS_SKILLS_TARGET_DIR="${HQ_ROOT}/.agents/skills"
  PROJECT_CODEX_DIR="${HQ_ROOT}/.codex"
  PROJECT_CLAUDE_TARGET_DIR="${PROJECT_CODEX_DIR}/claude"
  PROJECT_PROMPTS_TARGET_DIR="${PROJECT_CODEX_DIR}/prompts"
  PROJECT_OUTPUT_STYLE_TARGET_FILE="${PROJECT_CODEX_DIR}/output-style.md"
  LEGACY_CODEX_DIR="${HQ_ROOT}/.Codex"
  LEGACY_CLAUDE_TARGET_DIR="${LEGACY_CODEX_DIR}/claude"
  LEGACY_PROMPTS_TARGET_DIR="${LEGACY_CODEX_DIR}/prompts"
  LEGACY_OUTPUT_STYLE_TARGET_FILE="${LEGACY_CODEX_DIR}/output-style.md"
}

parse_args() {
  while (($#)); do
    case "$1" in
      status|install|doctor)
        [[ -z "${COMMAND}" ]] || fail "Only one command may be provided."
        COMMAND="$1"
        shift
        ;;
      --root)
        [[ $# -ge 2 ]] || fail "--root requires a path."
        HQ_ROOT="$2"
        shift 2
        ;;
      --root=*)
        HQ_ROOT="${1#--root=}"
        shift
        ;;
      --old-root)
        [[ $# -ge 2 ]] || fail "--old-root requires a path."
        OLD_ROOTS+=("$2")
        shift 2
        ;;
      --old-root=*)
        OLD_ROOTS+=("${1#--old-root=}")
        shift
        ;;
      --repair-local-config)
        REPAIR_LOCAL_CONFIG=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done

  [[ -n "${COMMAND}" ]] || {
    usage
    exit 1
  }
}

skill_count() {
  find "${SKILLS_SOURCE_DIR}" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -exec test -f '{}/SKILL.md' \; -print 2>/dev/null | wc -l | tr -d '[:space:]'
}

command_count() {
  find "${COMMANDS_SOURCE_DIR}" -mindepth 1 -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]'
}

hook_count() {
  find "${HOOKS_SOURCE_DIR}" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d '[:space:]'
}

policy_count() {
  find "${POLICIES_SOURCE_DIR}" -mindepth 1 -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]'
}

openai_yaml_count() {
  find "${SKILLS_SOURCE_DIR}" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -exec sh -c 'test -f "$1/SKILL.md" && test -f "$1/agents/openai.yaml"' _ '{}' \; -print 2>/dev/null | wc -l | tr -d '[:space:]'
}

commands_with_skills_count() {
  local count=0
  while IFS= read -r cmd_file; do
    local cmd_name
    cmd_name="$(basename "${cmd_file}" .md)"
    if [[ -f "${SKILLS_SOURCE_DIR}/${cmd_name}/SKILL.md" ]]; then
      (( count++ )) || true
    fi
  done < <(find "${COMMANDS_SOURCE_DIR}" -mindepth 1 -maxdepth 1 -type f -name '*.md' 2>/dev/null)
  echo "${count}"
}

print_coverage_report() {
  local total_cmds with_skills without_skills
  total_cmds="$(command_count)"
  with_skills="$(commands_with_skills_count)"
  without_skills=$(( total_cmds - with_skills ))

  echo "Codex coverage: ${with_skills}/${total_cmds} commands have skills"

  if (( without_skills > 0 )); then
    echo
    echo "Commands without skills (${without_skills}):"
    while IFS= read -r cmd_file; do
      local cmd_name
      cmd_name="$(basename "${cmd_file}" .md)"
      if [[ ! -d "${SKILLS_SOURCE_DIR}/${cmd_name}" ]]; then
        echo "  - ${cmd_name}"
      fi
    done < <(find "${COMMANDS_SOURCE_DIR}" -mindepth 1 -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)
  else
    echo "All commands have corresponding skills."
  fi
}

normalize_link_target() {
  local target="$1"
  local link_target

  link_target="$(readlink "${target}")"
  if [[ "${link_target}" = /* ]]; then
    printf '%s\n' "${link_target}"
    return
  fi

  local target_dir resolved_path
  target_dir="$(cd "$(dirname "${target}")" && pwd)"
  resolved_path="${target_dir}/${link_target}"

  if [[ -e "${resolved_path}" ]]; then
    if [[ -d "${resolved_path}" ]]; then
      (cd "${resolved_path}" && pwd)
    else
      local resolved_dir resolved_base
      resolved_dir="$(cd "$(dirname "${resolved_path}")" && pwd)"
      resolved_base="$(basename "${resolved_path}")"
      printf '%s/%s\n' "${resolved_dir}" "${resolved_base}"
    fi
    return
  fi

  printf '%s\n' "${resolved_path}"
}

strip_known_hq_subpath() {
  local path="$1"

  case "${path}" in
    */.claude/output-styles/*.md) printf '%s\n' "${path%%/.claude/output-styles/*}" ;;
    */.claude/skills) printf '%s\n' "${path%/.claude/skills}" ;;
    */.claude/commands) printf '%s\n' "${path%/.claude/commands}" ;;
    */.claude) printf '%s\n' "${path%/.claude}" ;;
    *) return 1 ;;
  esac
}

active_output_style_name() {
  [[ -f "${SETTINGS_SOURCE_FILE}" ]] || return 1
  sed -n 's/.*"outputStyle"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${SETTINGS_SOURCE_FILE}" | tail -n 1
}

output_style_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[[:space:]_]\+/-/g; s/[^a-z0-9.-]/-/g; s/-\+/-/g; s/^-//; s/-$//'
}

resolve_output_style_source_file() {
  local style_name slug source
  style_name="$(active_output_style_name || true)"
  [[ -n "${style_name}" ]] || return 1
  slug="$(output_style_slug "${style_name}")"
  source="${OUTPUT_STYLES_SOURCE_DIR}/${slug}.md"
  [[ -f "${source}" ]] || return 1
  printf '%s\n' "${source}"
}

print_output_style_status() {
  local style_name source
  style_name="$(active_output_style_name || true)"
  echo "Active output style: ${style_name:-not configured}"

  if source="$(resolve_output_style_source_file)"; then
    print_link_status "Project Codex output-style bridge" "${source}" "${PROJECT_OUTPUT_STYLE_TARGET_FILE}"
    if [[ -e "${LEGACY_CODEX_DIR}" || -L "${LEGACY_OUTPUT_STYLE_TARGET_FILE}" ]]; then
      echo
      print_link_status "Legacy .Codex output-style bridge" "${source}" "${LEGACY_OUTPUT_STYLE_TARGET_FILE}"
    fi
  else
    echo "Project Codex output-style bridge:"
    echo "  source: unavailable"
    echo "  target: ${PROJECT_OUTPUT_STYLE_TARGET_FILE}"
    echo "  status: active output style has no .claude/output-styles/*.md bridge source"
    STATUS_FAILURES=$(( STATUS_FAILURES + 1 ))
  fi
}

is_hq_root_like() {
  local path="$1"
  [[ "${path}" != *'{'* ]] || return 1
  [[ "${path}" != *'}'* ]] || return 1
  [[ "${path}" != "/Documents/HQ" ]] || return 1
  [[ "$(basename "${path}")" == "HQ" ]]
}

bridge_target_is_repairable() {
  local current_target="$1"
  local source="$2"
  local expected_suffix target_root

  expected_suffix="${source#"${HQ_ROOT}"}"
  target_root="$(strip_known_hq_subpath "${current_target}" 2>/dev/null || true)"

  [[ -n "${target_root}" ]] || return 1
  is_hq_root_like "${target_root}" || return 1
  [[ "${target_root}" != "${HQ_ROOT}" ]] || return 1
  [[ "${current_target#"${target_root}"}" == "${expected_suffix}" ]]
}

print_link_status() {
  local label="$1"
  local source="$2"
  local target="$3"

  echo "${label}:"
  echo "  source: ${source}"
  echo "  target: ${target}"

  if [[ -L "${target}" ]]; then
    local resolved_target
    resolved_target="$(normalize_link_target "${target}")"
    echo "  bridge: installed"
    echo "  points to: ${resolved_target}"
    if [[ "${resolved_target}" == "${source}" ]]; then
      echo "  status: healthy"
    elif bridge_target_is_repairable "${resolved_target}" "${source}"; then
      echo "  status: stale HQ root (repairable)"
      STATUS_FAILURES=$(( STATUS_FAILURES + 1 ))
    else
      echo "  status: unexpected target"
      STATUS_FAILURES=$(( STATUS_FAILURES + 1 ))
    fi
  elif [[ -e "${target}" ]]; then
    echo "  bridge: blocked"
    echo "  status: target exists and is not a symlink"
    STATUS_FAILURES=$(( STATUS_FAILURES + 1 ))
  else
    echo "  bridge: not installed"
    STATUS_FAILURES=$(( STATUS_FAILURES + 1 ))
  fi
}

repair_or_create_symlink() {
  local label="$1"
  local source="$2"
  local target="$3"

  mkdir -p "$(dirname "${target}")"

  if [[ -L "${target}" ]]; then
    local resolved_target
    resolved_target="$(normalize_link_target "${target}")"
    if [[ "${resolved_target}" == "${source}" ]]; then
      echo "${label} already installed."
      return
    fi

    if bridge_target_is_repairable "${resolved_target}" "${source}"; then
      if (( DRY_RUN )); then
        echo "Would repair ${label}: ${resolved_target} -> ${source}"
        return
      fi
      rm "${target}"
      ln -s "${source}" "${target}"
      echo "Repaired ${label}: ${resolved_target} -> ${source}"
      return
    fi

    echo "Refusing to replace existing symlink: ${target} -> ${resolved_target}" >&2
    exit 1
  fi

  if [[ -e "${target}" ]]; then
    echo "Refusing to overwrite existing path: ${target}" >&2
    exit 1
  fi

  if (( DRY_RUN )); then
    echo "Would install ${label}: ${target} -> ${source}"
    return
  fi

  ln -s "${source}" "${target}"
  echo "Installed ${label}."
}

config_files() {
  for file in \
    "${HQ_ROOT}/.mcp.json" \
    "${HQ_ROOT}/.claude/settings.json" \
    "${HQ_ROOT}/.claude/settings.local.json" \
    "${HQ_ROOT}/.codex/config.toml" \
    "${HQ_ROOT}/.Codex/config.toml"
  do
    [[ -f "${file}" ]] && printf '%s\n' "${file}"
  done
}

extract_hq_roots_from_file() {
  local file="$1"
  grep -Eoh '/[^"[:space:]]+/HQ(/|$)' "${file}" 2>/dev/null | sed 's#/$##' || true
}

collect_stale_roots() {
  local include_explicit="${1:-0}"
  local roots_file
  roots_file="$(mktemp)"

  if (( include_explicit )); then
    for root in "${OLD_ROOTS[@]-}"; do
      [[ -n "${root}" ]] && printf '%s\n' "${root}" >> "${roots_file}"
    done
  fi

  for target in \
    "${GLOBAL_SKILLS_TARGET_DIR}" \
    "${GLOBAL_AGENTS_SKILLS_TARGET_DIR}" \
    "${REPO_AGENTS_SKILLS_TARGET_DIR}" \
    "${PROJECT_CLAUDE_TARGET_DIR}" \
    "${PROJECT_PROMPTS_TARGET_DIR}" \
    "${PROJECT_OUTPUT_STYLE_TARGET_FILE}" \
    "${LEGACY_CLAUDE_TARGET_DIR}" \
    "${LEGACY_PROMPTS_TARGET_DIR}" \
    "${LEGACY_OUTPUT_STYLE_TARGET_FILE}"
  do
    if [[ -L "${target}" ]]; then
      strip_known_hq_subpath "$(normalize_link_target "${target}")" 2>/dev/null >> "${roots_file}" || true
    fi
  done

  while IFS= read -r file; do
    extract_hq_roots_from_file "${file}" >> "${roots_file}"
  done < <(config_files)

  sort -u "${roots_file}" | while IFS= read -r root; do
    [[ -n "${root}" ]] || continue
    [[ "${root}" != "${HQ_ROOT}" ]] || continue
    is_hq_root_like "${root}" || continue
    printf '%s\n' "${root}"
  done

  rm -f "${roots_file}"
}

print_stale_root_report() {
  local roots
  roots="$(collect_stale_roots 0)"

  if [[ -z "${roots}" ]]; then
    echo "Stale HQ roots: none detected"
    return
  fi

  echo "Stale HQ roots detected:"
  printf '%s\n' "${roots}" | sed 's/^/  - /'
}

rewrite_local_config_roots() {
  local roots rewritten_any=0
  roots="$(collect_stale_roots 1)"

  if [[ -z "${roots}" ]]; then
    echo "No stale local config roots to rewrite."
    return
  fi

  while IFS= read -r file; do
    local changed_file=0
    while IFS= read -r old_root; do
      [[ -n "${old_root}" ]] || continue
      if grep -qF "${old_root}" "${file}"; then
        if (( DRY_RUN )); then
          echo "Would rewrite ${file}: ${old_root} -> ${HQ_ROOT}"
        else
          OLD_ROOT="${old_root}" NEW_ROOT="${HQ_ROOT}" perl -0pi -e 's/\Q$ENV{OLD_ROOT}\E/$ENV{NEW_ROOT}/g' "${file}"
          changed_file=1
        fi
      fi
    done <<< "${roots}"

    if (( changed_file )); then
      echo "Rewrote local config paths in ${file}."
      rewritten_any=1
    fi
  done < <(config_files)

  if (( ! rewritten_any && ! DRY_RUN )); then
    echo "No local config files needed rewriting."
  fi
}

print_status() {
  local skill_total skill_with skill_without
  skill_total="$(skill_count)"
  skill_with="$(openai_yaml_count)"
  skill_without=$(( skill_total - skill_with ))
  STATUS_FAILURES=0

  echo "HQ Claude source: ${CLAUDE_SOURCE_DIR}"
  echo "Skills in source: ${skill_total} (${skill_with} with agents/openai.yaml, ${skill_without} without)"
  echo "Commands in source: $(command_count)"
  echo "Hooks in source: $(hook_count)"
  echo "Policies in source: $(policy_count)"
  echo
  print_coverage_report
  echo

  print_link_status "Global skills bridge (legacy)" "${SKILLS_SOURCE_DIR}" "${GLOBAL_SKILLS_TARGET_DIR}"
  echo
  print_link_status "Global agents skills bridge" "${SKILLS_SOURCE_DIR}" "${GLOBAL_AGENTS_SKILLS_TARGET_DIR}"
  echo
  print_link_status "Repo agents skills bridge" "${SKILLS_SOURCE_DIR}" "${REPO_AGENTS_SKILLS_TARGET_DIR}"
  echo
  print_link_status "Project Claude mirror" "${CLAUDE_SOURCE_DIR}" "${PROJECT_CLAUDE_TARGET_DIR}"
  echo
  print_link_status "Project command bridge" "${COMMANDS_SOURCE_DIR}" "${PROJECT_PROMPTS_TARGET_DIR}"
  echo
  print_output_style_status

  if [[ -e "${LEGACY_CODEX_DIR}" || -L "${LEGACY_CLAUDE_TARGET_DIR}" || -L "${LEGACY_PROMPTS_TARGET_DIR}" ]]; then
    echo
    print_link_status "Legacy .Codex Claude mirror" "${CLAUDE_SOURCE_DIR}" "${LEGACY_CLAUDE_TARGET_DIR}"
    echo
    print_link_status "Legacy .Codex command bridge" "${COMMANDS_SOURCE_DIR}" "${LEGACY_PROMPTS_TARGET_DIR}"
  fi

  echo
  print_stale_root_report

  return "${STATUS_FAILURES}"
}

validate_sources() {
  [[ -d "${SKILLS_SOURCE_DIR}" ]] || fail "Missing skills source directory: ${SKILLS_SOURCE_DIR}"
  [[ -d "${CLAUDE_SOURCE_DIR}" ]] || fail "Missing Claude source directory: ${CLAUDE_SOURCE_DIR}"
  [[ -d "${COMMANDS_SOURCE_DIR}" ]] || fail "Missing commands source directory: ${COMMANDS_SOURCE_DIR}"
}

install_bridge() {
  local output_style_source

  validate_sources
  output_style_source="$(resolve_output_style_source_file)" || fail "Active outputStyle must have a matching ${OUTPUT_STYLES_SOURCE_DIR}/<style>.md file."

  repair_or_create_symlink "global Codex skill bridge (legacy)" "${SKILLS_SOURCE_DIR}" "${GLOBAL_SKILLS_TARGET_DIR}"
  repair_or_create_symlink "global agents skill bridge" "${SKILLS_SOURCE_DIR}" "${GLOBAL_AGENTS_SKILLS_TARGET_DIR}"
  repair_or_create_symlink "repo agents skill bridge" "${SKILLS_SOURCE_DIR}" "${REPO_AGENTS_SKILLS_TARGET_DIR}"
  repair_or_create_symlink "project Codex Claude mirror" "${CLAUDE_SOURCE_DIR}" "${PROJECT_CLAUDE_TARGET_DIR}"
  repair_or_create_symlink "project Codex command bridge" "${COMMANDS_SOURCE_DIR}" "${PROJECT_PROMPTS_TARGET_DIR}"
  repair_or_create_symlink "project Codex output-style bridge" "${output_style_source}" "${PROJECT_OUTPUT_STYLE_TARGET_FILE}"

  if [[ -e "${LEGACY_CODEX_DIR}" || -L "${LEGACY_CLAUDE_TARGET_DIR}" || -L "${LEGACY_PROMPTS_TARGET_DIR}" ]]; then
    repair_or_create_symlink "legacy .Codex Claude mirror" "${CLAUDE_SOURCE_DIR}" "${LEGACY_CLAUDE_TARGET_DIR}"
    repair_or_create_symlink "legacy .Codex command bridge" "${COMMANDS_SOURCE_DIR}" "${LEGACY_PROMPTS_TARGET_DIR}"
    repair_or_create_symlink "legacy .Codex output-style bridge" "${output_style_source}" "${LEGACY_OUTPUT_STYLE_TARGET_FILE}"
  fi

  if (( REPAIR_LOCAL_CONFIG )); then
    echo
    rewrite_local_config_roots
  fi

  echo
  print_status
}

doctor_bridge() {
  validate_sources
  REPAIR_LOCAL_CONFIG=1
  install_bridge
}

main() {
  parse_args "$@"
  configure_paths

  case "${COMMAND}" in
    status)
      print_status
      ;;
    install)
      install_bridge
      ;;
    doctor)
      doctor_bridge
      ;;
  esac
}

main "$@"
