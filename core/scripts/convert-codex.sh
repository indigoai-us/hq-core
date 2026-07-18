#!/usr/bin/env bash
#
# Additive Codex parity repair for Claude-first HQ roots.
#
# This script only creates missing Codex-facing files and bridges. It does not
# overwrite existing paths, edit existing content, or replace real directories
# with symlinks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY=false
ROOT_ARG=""
SYNC_SKILLS=true
GENERATE_OPENAI=true

usage() {
  cat <<'EOF'
Usage:
  core/scripts/convert-codex.sh [--dry-run] [--apply] [--root=<path>] [--no-skill-sync] [--no-openai-yaml]

Options:
  --dry-run          Preview the repair. This is the default.
  --apply            Create missing Codex parity files and bridges.
  --root=<path>      HQ root to repair. Defaults to the nearest parent with .claude/ and core/core.yaml.
  --no-skill-sync    Do not create/sync .agents/skills.
  --no-openai-yaml   Do not generate missing agents/openai.yaml files.

Safety:
  - Create-only: existing files, directories, and symlinks are left untouched.
  - Existing .agents/skills directories are synced by adding missing skills only.
  - Existing Codex config and AGENTS.md files are never rewritten.
  - Existing .codex/output-style.md files are never rewritten.
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
    if [[ -d "${dir}/.claude" && -f "${dir}/core/core.yaml" ]]; then
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
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
OUTPUT_STYLES_DIR="${CLAUDE_DIR}/output-styles"
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
    if [[ -d "${raw_target}" ]]; then
      cd "${raw_target}" 2>/dev/null
      pwd
    elif [[ -e "${raw_target}" ]]; then
      local resolved_dir resolved_base
      resolved_dir="$(cd "$(dirname "${raw_target}")" && pwd)"
      resolved_base="$(basename "${raw_target}")"
      printf '%s/%s\n' "${resolved_dir}" "${resolved_base}"
    fi
  )
}

ensure_symlink() {
  local label="$1"
  local link_path="$2"
  local relative_target="$3"
  local desired_abs resolved_dir resolved_base

  desired_abs="$(
    cd "$(dirname "${link_path}")" 2>/dev/null || cd "${HQ_ROOT}"
    if [[ -d "${relative_target}" ]]; then
      cd "${relative_target}" 2>/dev/null
      pwd
    elif [[ -e "${relative_target}" ]]; then
      resolved_dir="$(cd "$(dirname "${relative_target}")" && pwd)"
      resolved_base="$(basename "${relative_target}")"
      printf '%s/%s\n' "${resolved_dir}" "${resolved_base}"
    fi
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

active_output_style_name() {
  [[ -f "${SETTINGS_FILE}" ]] || return 1
  sed -n 's/.*"outputStyle"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${SETTINGS_FILE}" | tail -n 1
}

output_style_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[[:space:]_]\+/-/g; s/[^a-z0-9.-]/-/g; s/-\+/-/g; s/^-//; s/-$//'
}

ensure_output_style_bridge() {
  local style_name slug source
  style_name="$(active_output_style_name || true)"

  if [[ -z "${style_name}" ]]; then
    record_skip "no .claude/settings.json outputStyle configured"
    return
  fi

  slug="$(output_style_slug "${style_name}")"
  source="${OUTPUT_STYLES_DIR}/${slug}.md"
  if [[ ! -f "${source}" ]]; then
    record_block "active outputStyle '${style_name}' has no source file at $(rel_path "${source}")"
    return
  fi

  ensure_symlink "project Codex output-style bridge" "${CODEX_DIR}/output-style.md" "../.claude/output-styles/${slug}.md"
}

emit_openai_yaml() {
  local skill_md="$1"
  node "${SCRIPT_DIR}/validate-agent-runtime-contracts.mjs" emit-openai-yaml "${skill_md}"
}

list_skill_directories() {
  local skills_root="$1"
  local skill_dir

  [[ -d "${skills_root}" || -L "${skills_root}" ]] || return 0

  for skill_dir in "${skills_root}"/*; do
    [[ -e "${skill_dir}" ]] || continue
    [[ -d "${skill_dir}" || -L "${skill_dir}" ]] || continue
    [[ -f "${skill_dir}/SKILL.md" ]] || continue
    printf '%s\n' "${skill_dir}"
  done | LC_ALL=C sort
}

write_generated_openai_yaml() {
  local skill_md="$1"
  local yaml_path="$2"
  local tmp_path=""

  tmp_path="$(mktemp "${yaml_path}.tmp.XXXXXX")" || return 1
  if emit_openai_yaml "${skill_md}" > "${tmp_path}" && mv "${tmp_path}" "${yaml_path}"; then
    return 0
  fi

  rm -f "${tmp_path}"
  return 1
}

generate_openai_yaml_for_dir() {
  local skills_root="$1"
  local skill_dir skill_md yaml_path

  [[ -d "${skills_root}" || -L "${skills_root}" ]] || return

  while IFS= read -r skill_dir; do
    skill_md="${skill_dir}/SKILL.md"
    yaml_path="${skill_dir}/agents/openai.yaml"

    [[ -f "${skill_md}" ]] || continue

    if [[ -e "${yaml_path}" ]]; then
      continue
    fi

    if [[ "${APPLY}" == true ]]; then
      if mkdir -p "$(dirname "${yaml_path}")" && write_generated_openai_yaml "${skill_md}" "${yaml_path}"
      then
        record_create "${yaml_path}"
      else
        record_block "could not create $(rel_path "${yaml_path}")"
      fi
    else
      record_create "${yaml_path}"
    fi
  done < <(list_skill_directories "${skills_root}")
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
  done < <(list_skill_directories "${CLAUDE_SKILLS_DIR}")
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
  for cmd_file in "${COMMANDS_DIR}"/*.md; do
    [[ -f "${cmd_file}" ]] || continue
    cmd_name="$(basename "${cmd_file}" .md)"
    if [[ -f "${CLAUDE_SKILLS_DIR}/${cmd_name}/SKILL.md" ]]; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "${count}"
}

skill_dir_count() {
  local root="$1"
  local count=0 skill_dir
  [[ -d "${root}" || -L "${root}" ]] || {
    printf '0\n'
    return
  }
  while IFS= read -r skill_dir; do
    count=$((count + 1))
  done < <(list_skill_directories "${root}")
  printf '%s\n' "${count}"
}

skill_openai_count() {
  local root="$1"
  local count=0 skill_dir
  [[ -d "${root}" || -L "${root}" ]] || {
    printf '0\n'
    return
  }
  while IFS= read -r skill_dir; do
    [[ -f "${skill_dir}/agents/openai.yaml" ]] || continue
    count=$((count + 1))
  done < <(list_skill_directories "${root}")
  printf '%s\n' "${count}"
}

print_audit() {
  local skill_total skill_openai agent_skill_total
  skill_total="$(skill_dir_count "${CLAUDE_SKILLS_DIR}")"
  skill_openai="$(skill_openai_count "${CLAUDE_SKILLS_DIR}")"
  agent_skill_total="$(skill_dir_count "${AGENTS_SKILLS_DIR}")"

  echo
  echo "Codex parity audit:"
  echo "  Claude skills: ${skill_total} (${skill_openai} with agents/openai.yaml)"
  echo "  Repo Codex skills exposed: ${agent_skill_total}"
  [[ -e "${HQ_ROOT}/AGENTS.md" ]] && echo "  AGENTS.md: present" || echo "  AGENTS.md: missing"
  [[ -e "${CODEX_DIR}/config.toml" ]] && echo "  .codex/config.toml: present" || echo "  .codex/config.toml: missing"
  [[ -e "${CODEX_DIR}/claude" || -L "${CODEX_DIR}/claude" ]] && echo "  .codex/claude: present" || echo "  .codex/claude: missing"
  [[ -e "${CODEX_DIR}/output-style.md" || -L "${CODEX_DIR}/output-style.md" ]] && echo "  .codex/output-style.md: present" || echo "  .codex/output-style.md: missing"
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
  ensure_output_style_bridge
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
