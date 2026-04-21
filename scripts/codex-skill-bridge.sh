#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILLS_SOURCE_DIR="${HQ_ROOT}/.claude/skills"
CLAUDE_SOURCE_DIR="${HQ_ROOT}/.claude"
COMMANDS_SOURCE_DIR="${CLAUDE_SOURCE_DIR}/commands"
GLOBAL_SKILLS_TARGET_DIR="${HOME}/.codex/skills/hq"
GLOBAL_AGENTS_SKILLS_TARGET_DIR="${HOME}/.agents/skills/hq"
REPO_AGENTS_SKILLS_TARGET_DIR="${HQ_ROOT}/.agents/skills"
PROJECT_CODEX_DIR="${HQ_ROOT}/.codex"
PROJECT_CLAUDE_TARGET_DIR="${PROJECT_CODEX_DIR}/claude"
PROJECT_PROMPTS_TARGET_DIR="${PROJECT_CODEX_DIR}/prompts"

usage() {
  cat <<'EOF'
Usage:
  scripts/codex-skill-bridge.sh install
  scripts/codex-skill-bridge.sh status

Commands:
  install  Install the HQ Claude -> Codex bridges for skills, commands, and runtime docs.
  status   Show whether each bridge is installed and where it points.
EOF
}

skill_count() {
  # Count all skill dirs (real + symlinked)
  find "${SKILLS_SOURCE_DIR}" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) | wc -l | tr -d '[:space:]'
}

command_count() {
  find "${COMMANDS_SOURCE_DIR}" -mindepth 1 -maxdepth 1 -type f -name '*.md' | wc -l | tr -d '[:space:]'
}

hook_count() {
  find "${CLAUDE_SOURCE_DIR}/hooks" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]'
}

policy_count() {
  find "${CLAUDE_SOURCE_DIR}/policies" -mindepth 1 -maxdepth 1 -type f -name '*.md' | wc -l | tr -d '[:space:]'
}

openai_yaml_count() {
  find "${SKILLS_SOURCE_DIR}" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -exec test -f '{}/agents/openai.yaml' \; -print | wc -l | tr -d '[:space:]'
}

commands_with_skills_count() {
  local count=0
  while IFS= read -r cmd_file; do
    local cmd_name
    cmd_name="$(basename "${cmd_file}" .md)"
    if [[ -d "${SKILLS_SOURCE_DIR}/${cmd_name}" ]]; then
      (( count++ )) || true
    fi
  done < <(find "${COMMANDS_SOURCE_DIR}" -mindepth 1 -maxdepth 1 -type f -name '*.md')
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
    done < <(find "${COMMANDS_SOURCE_DIR}" -mindepth 1 -maxdepth 1 -type f -name '*.md' | sort)
  else
    echo "All commands have corresponding skills."
  fi
}

resolve_dir_link() {
  local target="$1"
  local current_target

  current_target="$(readlink "${target}")"
  if [[ "${current_target}" = /* ]]; then
    printf '%s\n' "${current_target}"
    return
  fi

  (
    cd "$(dirname "${target}")"
    cd "${current_target}"
    pwd
  )
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
    resolved_target="$(resolve_dir_link "${target}")"
    echo "  bridge: installed"
    echo "  points to: ${resolved_target}"
    if [[ "${resolved_target}" == "${source}" ]]; then
      echo "  status: healthy"
    else
      echo "  status: unexpected target"
      return 1
    fi
  elif [[ -e "${target}" ]]; then
    echo "  bridge: blocked"
    echo "  status: target exists and is not a symlink"
    return 1
  else
    echo "  bridge: not installed"
  fi
}

ensure_dir_symlink() {
  local label="$1"
  local source="$2"
  local target="$3"

  mkdir -p "$(dirname "${target}")"

  if [[ -L "${target}" ]]; then
    local resolved_target
    resolved_target="$(resolve_dir_link "${target}")"
    if [[ "${resolved_target}" == "${source}" ]]; then
      echo "${label} already installed."
      return
    fi

    echo "Refusing to replace existing symlink: ${target} -> ${resolved_target}" >&2
    exit 1
  fi

  if [[ -e "${target}" ]]; then
    echo "Refusing to overwrite existing path: ${target}" >&2
    exit 1
  fi

  ln -s "${source}" "${target}"
  echo "Installed ${label}."
}

print_status() {
  local skill_total skill_with skill_without
  skill_total="$(skill_count)"
  skill_with="$(openai_yaml_count)"
  skill_without=$(( skill_total - skill_with ))

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
}

install_bridge() {
  if [[ ! -d "${SKILLS_SOURCE_DIR}" ]]; then
    echo "Missing skills source directory: ${SKILLS_SOURCE_DIR}" >&2
    exit 1
  fi

  if [[ ! -d "${CLAUDE_SOURCE_DIR}" ]]; then
    echo "Missing Claude source directory: ${CLAUDE_SOURCE_DIR}" >&2
    exit 1
  fi

  if [[ ! -d "${COMMANDS_SOURCE_DIR}" ]]; then
    echo "Missing commands source directory: ${COMMANDS_SOURCE_DIR}" >&2
    exit 1
  fi

  ensure_dir_symlink "global Codex skill bridge (legacy)" "${SKILLS_SOURCE_DIR}" "${GLOBAL_SKILLS_TARGET_DIR}"
  ensure_dir_symlink "global agents skill bridge" "${SKILLS_SOURCE_DIR}" "${GLOBAL_AGENTS_SKILLS_TARGET_DIR}"
  ensure_dir_symlink "repo agents skill bridge" "${SKILLS_SOURCE_DIR}" "${REPO_AGENTS_SKILLS_TARGET_DIR}"
  ensure_dir_symlink "project Codex Claude mirror" "${CLAUDE_SOURCE_DIR}" "${PROJECT_CLAUDE_TARGET_DIR}"
  ensure_dir_symlink "project Codex command bridge" "${COMMANDS_SOURCE_DIR}" "${PROJECT_PROMPTS_TARGET_DIR}"

  echo
  print_status
}

main() {
  local command="${1:-}"

  case "${command}" in
    install)
      install_bridge
      ;;
    status)
      print_status
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
