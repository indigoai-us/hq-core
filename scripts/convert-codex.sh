#!/usr/bin/env bash
#
# Additive Codex parity repair for Claude-first HQ roots.
#
# This script only creates missing Codex-facing files and bridges. It does not
# overwrite existing paths, edit existing content, or replace real directories
# with symlinks.

set -euo pipefail

APPLY=false
ROOT_ARG=""
SYNC_SKILLS=true
GENERATE_OPENAI=true

usage() {
  cat <<'EOF'
Usage:
  scripts/convert-codex.sh [--dry-run] [--apply] [--root=<path>] [--no-skill-sync] [--no-openai-yaml]

Options:
  --dry-run          Preview the repair. This is the default.
  --apply            Create missing Codex parity files and bridges.
  --root=<path>      HQ root to repair. Defaults to the nearest parent with .claude/ and core.yaml.
  --no-skill-sync    Do not create/sync .agents/skills.
  --no-openai-yaml   Do not generate missing agents/openai.yaml files.

Safety:
  - Create-only: existing files, directories, and symlinks are left untouched.
  - Existing .agents/skills directories are synced by adding missing skills only.
  - Existing Codex config and AGENTS.md files are never rewritten.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) APPLY=false ;;
    --apply) APPLY=true ;;
    --root=*) ROOT_ARG="${arg#--root=}" ;;
    --no-skill-sync) SYNC_SKILLS=false ;;
    --no-openai-yaml) GENERATE_OPENAI=false ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: ${arg}" >&2; usage >&2; exit 1 ;;
  esac
done

find_hq_root() {
  local dir="${PWD}"
  while [[ "${dir}" != "/" ]]; do
    if [[ -d "${dir}/.claude" && -f "${dir}/core.yaml" ]]; then
      printf '%s\n' "${dir}"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  return 1
}

if [[ -n "${ROOT_ARG}" ]]; then
  HQ_ROOT="$(cd "${ROOT_ARG}" && pwd)"
else
  HQ_ROOT="$(find_hq_root)" || {
    echo "Could not find an HQ root. Pass --root=<path>." >&2
    exit 1
  }
fi

CLAUDE_DIR="${HQ_ROOT}/.claude"
COMMANDS_DIR="${CLAUDE_DIR}/commands"
CLAUDE_SKILLS_DIR="${CLAUDE_DIR}/skills"
CODEX_DIR="${HQ_ROOT}/.codex"
AGENTS_DIR="${HQ_ROOT}/.agents"
AGENTS_SKILLS_DIR="${AGENTS_DIR}/skills"

created=0
skipped=0
blocked=0

rel_path() {
  local path="$1"
  printf '%s\n' "${path#"${HQ_ROOT}/"}"
}

mode_prefix() {
  if [[ "${APPLY}" == true ]]; then
    printf 'create'
  else
    printf 'would create'
  fi
}

record_create() {
  local path="$1"
  printf '  + %s %s\n' "$(mode_prefix)" "$(rel_path "${path}")"
  created=$((created + 1))
}

record_skip() {
  local message="$1"
  printf '  = %s\n' "${message}"
  skipped=$((skipped + 1))
}

record_block() {
  local message="$1"
  printf '  ! %s\n' "${message}"
  blocked=$((blocked + 1))
}

ensure_parent_dir() {
  local path="$1"
  if [[ "${APPLY}" == true ]]; then
    mkdir -p "$(dirname "${path}")"
  fi
}

write_agents_md() {
  local target="${HQ_ROOT}/AGENTS.md"
  if [[ -e "${target}" ]]; then
    record_skip "AGENTS.md already exists"
    return
  fi

  if [[ "${APPLY}" != true ]]; then
    record_create "${target}"
    return
  fi

  if cat > "${target}" <<'EOF'
# HQ for Codex

This repository is an HQ filesystem. Codex should treat it as a working personal OS with Claude-era source material and Codex-facing bridges.

## Orientation
- Canonical HQ commands, skills, hooks, and policies live under `.claude/`.
- Codex skills are exposed through `.agents/skills`.
- Codex project references live under `.codex/`.
- Prefer additive repairs. Do not replace user content or remove Claude Code support.

## Safety
- Preserve existing behavior for Claude Code users.
- When adding Codex parity, create missing files and bridges without overwriting existing paths.
- If a repair requires editing existing content instead of adding new content, pause for review.
EOF
  then
    record_create "${target}"
  else
    record_block "could not create $(rel_path "${target}")"
  fi
}

write_codex_config() {
  local target="${CODEX_DIR}/config.toml"
  if [[ -e "${target}" ]]; then
    record_skip ".codex/config.toml already exists"
    return
  fi

  if [[ "${APPLY}" != true ]]; then
    record_create "${target}"
    return
  fi

  if mkdir -p "${CODEX_DIR}" && cat > "${target}" <<'EOF'
sandbox_mode = "workspace-write"

[shell_environment_policy]
inherit = "core"

[sandbox_workspace_write]
network_access = true
EOF
  then
    record_create "${target}"
  else
    record_block "could not create $(rel_path "${target}")"
  fi
}

resolve_link_target() {
  local link_path="$1"
  local raw_target
  raw_target="$(readlink "${link_path}")"
  if [[ "${raw_target}" = /* ]]; then
    printf '%s\n' "${raw_target}"
    return
  fi
  (
    cd "$(dirname "${link_path}")"
    cd "${raw_target}" 2>/dev/null
    pwd
  )
}

ensure_symlink() {
  local label="$1"
  local link_path="$2"
  local relative_target="$3"
  local desired_abs

  desired_abs="$(
    cd "$(dirname "${link_path}")" 2>/dev/null || cd "${HQ_ROOT}"
    cd "${relative_target}" 2>/dev/null
    pwd
  )"

  if [[ -L "${link_path}" ]]; then
    local resolved
    resolved="$(resolve_link_target "${link_path}")"
    if [[ "${resolved}" == "${desired_abs}" ]]; then
      record_skip "${label} already points to ${relative_target}"
    else
      record_block "${label} points elsewhere: $(rel_path "${link_path}") -> $(readlink "${link_path}")"
    fi
    return
  fi

  if [[ -e "${link_path}" ]]; then
    record_block "${label} blocked; $(rel_path "${link_path}") exists and is not a symlink"
    return
  fi

  if [[ "${APPLY}" == true ]]; then
    mkdir -p "$(dirname "${link_path}")"
    if ln -s "${relative_target}" "${link_path}"; then
      record_create "${link_path}"
    else
      record_block "${label} could not be created at $(rel_path "${link_path}")"
    fi
  else
    record_create "${link_path}"
  fi
}

extract_frontmatter_field() {
  local file="$1"
  local field="$2"
  awk -v field="${field}" '
    /^---$/ { fm++; next }
    fm == 1 && $0 ~ "^" field ":" {
      sub("^" field ":[ ]*", "")
      gsub(/^["'\''"]|["'\''"]$/, "")
      print
      exit
    }
    fm > 1 { exit }
  ' "${file}" 2>/dev/null || true
}

yaml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

first_sentence() {
  printf '%s' "$1" | sed 's/\. .*/./' | cut -c1-140
}

display_name_for() {
  printf '%s' "$1" | tr '-' ' '
}

generate_openai_yaml_for_dir() {
  local skills_root="$1"
  local skill_dir skill_name skill_md yaml_path name description display short

  [[ -d "${skills_root}" || -L "${skills_root}" ]] || return

  while IFS= read -r skill_dir; do
    skill_name="$(basename "${skill_dir}")"
    skill_md="${skill_dir}/SKILL.md"
    yaml_path="${skill_dir}/agents/openai.yaml"

    [[ -f "${skill_md}" ]] || continue

    if [[ -e "${yaml_path}" ]]; then
      continue
    fi

    name="$(extract_frontmatter_field "${skill_md}" "name")"
    description="$(extract_frontmatter_field "${skill_md}" "description")"
    [[ -n "${name}" ]] || name="${skill_name}"
    [[ -n "${description}" ]] || description="Use the ${name} HQ skill with Codex."

    display="$(yaml_escape "$(display_name_for "${name}")")"
    short="$(yaml_escape "$(first_sentence "${description}")")"

    if [[ "${APPLY}" == true ]]; then
      if mkdir -p "$(dirname "${yaml_path}")" && cat > "${yaml_path}" <<EOF
interface:
  display_name: "${display}"
  short_description: "${short}"
EOF
      then
        record_create "${yaml_path}"
      else
        record_block "could not create $(rel_path "${yaml_path}")"
      fi
    else
      record_create "${yaml_path}"
    fi
  done < <(find "${skills_root}" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) | sort)
}

sync_agents_skills() {
  if [[ "${SYNC_SKILLS}" != true ]]; then
    record_skip "skill sync disabled"
    return
  fi

  if [[ ! -d "${CLAUDE_SKILLS_DIR}" ]]; then
    record_block "missing Claude skills source: $(rel_path "${CLAUDE_SKILLS_DIR}")"
    return
  fi

  if [[ ! -e "${AGENTS_SKILLS_DIR}" && ! -L "${AGENTS_SKILLS_DIR}" ]]; then
    ensure_symlink "repo Codex skills bridge" "${AGENTS_SKILLS_DIR}" "../.claude/skills"
    return
  fi

  if [[ -L "${AGENTS_SKILLS_DIR}" ]]; then
    local resolved
    resolved="$(resolve_link_target "${AGENTS_SKILLS_DIR}")"
    if [[ "${resolved}" == "${CLAUDE_SKILLS_DIR}" ]]; then
      record_skip ".agents/skills symlink already points to .claude/skills"
    else
      record_block ".agents/skills symlink points elsewhere: $(readlink "${AGENTS_SKILLS_DIR}")"
    fi
    return
  fi

  if [[ ! -d "${AGENTS_SKILLS_DIR}" ]]; then
    record_block ".agents/skills exists but is not a directory or symlink"
    return
  fi

  local source_skill skill_name target_skill
  while IFS= read -r source_skill; do
    skill_name="$(basename "${source_skill}")"
    target_skill="${AGENTS_SKILLS_DIR}/${skill_name}"
    if [[ -e "${target_skill}" || -L "${target_skill}" ]]; then
      continue
    fi

    if [[ "${APPLY}" == true ]]; then
      mkdir -p "${AGENTS_SKILLS_DIR}"
      if cp -R "${source_skill}" "${AGENTS_SKILLS_DIR}/"; then
        record_create "${target_skill}"
      else
        record_block "could not create $(rel_path "${target_skill}")"
      fi
    else
      record_create "${target_skill}"
    fi
  done < <(find "${CLAUDE_SKILLS_DIR}" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) | sort)
}

count_paths() {
  local root="$1"
  shift
  if [[ ! -d "${root}" ]]; then
    printf '0\n'
    return
  fi
  find -H "${root}" "$@" | wc -l | tr -d '[:space:]'
}

commands_with_skills_count() {
  local count=0 cmd_file cmd_name
  [[ -d "${COMMANDS_DIR}" && -d "${CLAUDE_SKILLS_DIR}" ]] || {
    printf '0\n'
    return
  }
  while IFS= read -r cmd_file; do
    cmd_name="$(basename "${cmd_file}" .md)"
    if [[ -d "${CLAUDE_SKILLS_DIR}/${cmd_name}" || -L "${CLAUDE_SKILLS_DIR}/${cmd_name}" ]]; then
      count=$((count + 1))
    fi
  done < <(find "${COMMANDS_DIR}" -mindepth 1 -maxdepth 1 -type f -name '*.md' | sort)
  printf '%s\n' "${count}"
}

print_audit() {
  local command_total skill_total skill_openai command_skills agent_skill_total
  command_total="$(count_paths "${COMMANDS_DIR}" -mindepth 1 -maxdepth 1 -type f -name '*.md')"
  skill_total="$(count_paths "${CLAUDE_SKILLS_DIR}" -mindepth 1 -maxdepth 1 \( -type d -o -type l \))"
  skill_openai="$(count_paths "${CLAUDE_SKILLS_DIR}" -mindepth 3 -maxdepth 3 -path '*/agents/openai.yaml')"
  command_skills="$(commands_with_skills_count)"
  agent_skill_total="$(count_paths "${AGENTS_SKILLS_DIR}" -mindepth 1 -maxdepth 1 \( -type d -o -type l \))"

  echo
  echo "Codex parity audit:"
  echo "  Claude commands: ${command_total}"
  echo "  Claude skills: ${skill_total} (${skill_openai} with agents/openai.yaml)"
  echo "  Commands with same-name skills: ${command_skills}/${command_total}"
  echo "  Repo Codex skills exposed: ${agent_skill_total}"
  [[ -e "${HQ_ROOT}/AGENTS.md" ]] && echo "  AGENTS.md: present" || echo "  AGENTS.md: missing"
  [[ -e "${CODEX_DIR}/config.toml" ]] && echo "  .codex/config.toml: present" || echo "  .codex/config.toml: missing"
  [[ -e "${CODEX_DIR}/claude" || -L "${CODEX_DIR}/claude" ]] && echo "  .codex/claude: present" || echo "  .codex/claude: missing"
  [[ -e "${CODEX_DIR}/prompts" || -L "${CODEX_DIR}/prompts" ]] && echo "  .codex/prompts: present" || echo "  .codex/prompts: missing"
}

main() {
  if [[ ! -d "${CLAUDE_DIR}" ]]; then
    echo "Missing .claude directory under ${HQ_ROOT}" >&2
    exit 1
  fi

  echo "HQ Codex conversion"
  echo "  root: ${HQ_ROOT}"
  if [[ "${APPLY}" == true ]]; then
    echo "  mode: apply"
  else
    echo "  mode: dry-run"
  fi
  echo

  echo "Repair plan:"
  write_agents_md
  write_codex_config
  ensure_symlink "project Claude mirror" "${CODEX_DIR}/claude" "../.claude"
  ensure_symlink "project command bridge" "${CODEX_DIR}/prompts" "../.claude/commands"
  sync_agents_skills

  if [[ "${GENERATE_OPENAI}" == true ]]; then
    generate_openai_yaml_for_dir "${CLAUDE_SKILLS_DIR}"
    if [[ -d "${AGENTS_SKILLS_DIR}" && ! -L "${AGENTS_SKILLS_DIR}" ]]; then
      generate_openai_yaml_for_dir "${AGENTS_SKILLS_DIR}"
    fi
  else
    record_skip "openai.yaml generation disabled"
  fi

  print_audit

  echo
  echo "Summary: ${created} create actions, ${skipped} already safe, ${blocked} blocked."
  if [[ "${APPLY}" != true ]]; then
    echo "Dry-run only. Re-run with --apply to repair missing Codex parity files."
  elif (( blocked > 0 )); then
    echo "Completed with blocked items. Existing paths were left untouched."
  else
    echo "Codex conversion repair complete."
  fi
}

main "$@"
