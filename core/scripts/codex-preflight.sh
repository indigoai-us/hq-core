#!/usr/bin/env bash
# hq-core: public
#
# Explicit Codex preflight checks for HQ.
#
# Codex does not run .claude/settings.json hooks automatically. This script
# ports the safe, event-independent hook intent into an explicit command that
# Codex skills can call before high-risk searches, edits, shell commands, and
# repo work.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOKS_DIR="${HQ_ROOT}/.claude/hooks"

usage() {
  cat <<'EOF'
Usage:
  core/scripts/codex-preflight.sh search --pattern <pattern> [--path <path>]
  core/scripts/codex-preflight.sh edit --file <path> [--tool Edit|Write|NotebookEdit]
  core/scripts/codex-preflight.sh bash --command <command>
  core/scripts/codex-preflight.sh repo --path <path>
  core/scripts/codex-preflight.sh policies [--cwd <path>]
  core/scripts/codex-preflight.sh doctor

Purpose:
  Run portable HQ safety checks explicitly from Codex workflows. This does not
  install hooks, edit settings, or claim automatic enforcement.
EOF
}

need_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "codex-preflight requires jq for hook-compatible JSON." >&2
    exit 1
  fi
}

run_hook_json() {
  local hook="$1"
  local json="$2"
  local hook_path="${HOOKS_DIR}/${hook}"

  if [[ ! -x "${hook_path}" && ! -f "${hook_path}" ]]; then
    echo "skip: missing hook ${hook}" >&2
    return 0
  fi

  printf '%s' "${json}" | bash "${hook_path}"
}

abs_path() {
  local input="$1"
  if [[ "${input}" = /* ]]; then
    printf '%s\n' "${input}"
  else
    printf '%s\n' "${PWD}/${input}"
  fi
}

cmd_search() {
  local pattern=""
  local search_path="${PWD}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pattern) pattern="${2:-}"; shift 2 ;;
      --path) search_path="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown search argument: $1" >&2; usage >&2; exit 1 ;;
    esac
  done

  [[ -n "${pattern}" ]] || { echo "Missing --pattern" >&2; exit 1; }

  if [[ "${pattern}" =~ prd\.json|worker\.yaml ]]; then
    cat >&2 <<'EOF'
BLOCKED: Never use broad search for prd.json or worker.yaml discovery.

For discovery: qmd search "{name} prd.json" --json -n 5
For known path: read the specific project or worker file directly.
EOF
    exit 2
  fi

  local resolved_path
  resolved_path="$(abs_path "${search_path}")"
  case "${resolved_path%/}" in
    "${HQ_ROOT}")
      cat >&2 <<EOF
BLOCKED: broad search from HQ root is too expensive.

Use a scoped path such as companies/, core/workers/, projects/, workspace/, or a
specific repo path.
EOF
      exit 2
      ;;
  esac

  echo "ok: search preflight passed"
}

cmd_edit() {
  need_jq

  local file_path=""
  local tool_name="Edit"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file) file_path="${2:-}"; shift 2 ;;
      --tool) tool_name="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown edit argument: $1" >&2; usage >&2; exit 1 ;;
    esac
  done

  [[ -n "${file_path}" ]] || { echo "Missing --file" >&2; exit 1; }

  local json
  json="$(jq -n \
    --arg tool "${tool_name}" \
    --arg file "${file_path}" \
    --arg cwd "${PWD}" \
    --arg session "__codex_preflight__" \
    '{tool_name:$tool, cwd:$cwd, session_id:$session, tool_input:{file_path:$file}}')"

  run_hook_json "protect-core.sh" "${json}"
  run_hook_json "block-on-active-run.sh" "${json}"
  run_hook_json "block-inline-story-impl.sh" "${json}"

  echo "ok: edit preflight passed"
}

cmd_bash() {
  need_jq

  local command_text=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --command) command_text="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown bash argument: $1" >&2; usage >&2; exit 1 ;;
    esac
  done

  [[ -n "${command_text}" ]] || { echo "Missing --command" >&2; exit 1; }

  local json
  json="$(jq -n \
    --arg command "${command_text}" \
    --arg cwd "${PWD}" \
    '{tool_name:"Bash", cwd:$cwd, tool_input:{command:$command}}')"

  run_hook_json "detect-secrets.sh" "${json}"

  echo "ok: bash preflight passed"
}

cmd_repo() {
  local target_path="${PWD}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path) target_path="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown repo argument: $1" >&2; usage >&2; exit 1 ;;
    esac
  done

  local registry="${HQ_ROOT}/scripts/repo-run-registry.sh"
  if [[ ! -x "${registry}" ]]; then
    echo "skip: repo-run-registry.sh is not executable"
    return 0
  fi

  "${registry}" check --target "${target_path}" --pid 0 --session-id "__codex_preflight__"
  echo "ok: repo preflight passed"
}

cmd_policies() {
  local cwd="${PWD}"
  # Per-session dedupe: without a session_id the injection hook records fired
  # slugs in the shared persistent default.txt ledger, so the SECOND preflight
  # ever run on a machine emits nothing. $PPID is the invoking Codex process —
  # stable within a session, distinct across sessions.
  local session="codex-preflight-${PPID}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cwd) cwd="${2:-}"; shift 2 ;;
      --session) session="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown policies argument: $1" >&2; usage >&2; exit 1 ;;
    esac
  done

  # Resolve the real HQ-root hooks dir locally: this file lives at
  # core/scripts/, so the hooks are two levels up. (The global HOOKS_DIR derives
  # from HQ_ROOT=core, which is correct for ${HQ_ROOT}/scripts/ siblings but
  # points at a nonexistent core/.claude/hooks for hook scripts.)
  local hooks_root; hooks_root="$(cd "${SCRIPT_DIR}/../.." && pwd)/.claude/hooks"
  if [[ ! -f "${hooks_root}/inject-policy-on-trigger.sh" ]]; then
    echo "skip: missing inject-policy-on-trigger.sh"
    return 0
  fi

  # SessionStart policy surfacing is now the trigger hook's job — every
  # on:[SessionStart] policy whose when: matches is injected. The standalone
  # digest loader (load-policies-for-session.sh) was retired.
  (cd "${cwd}" && printf '%s' '{"hook_event_name":"SessionStart","source":"startup","session_id":"'"${session}"'","cwd":"'"${cwd}"'"}' | bash "${hooks_root}/inject-policy-on-trigger.sh")
}

# doctor: report whether headless hook enforcement is ready for Codex + Grok,
# so an HQ session can self-check parity with Claude Code's auto-enforced hooks.
cmd_doctor() {
  local root; root="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
  echo "HQ headless-enforcement doctor (Codex + Grok)"
  if command -v codex >/dev/null 2>&1; then
    local v maj min; v="$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    maj="$(printf '%s' "${v:-0}" | cut -d. -f1)"; min="$(printf '%s' "${v:-0}" | cut -d. -f2)"
    if { [ "${maj:-0}" -gt 0 ] 2>/dev/null; } || { [ "${min:-0}" -ge 142 ] 2>/dev/null; }; then
      echo "  codex ${v:-?}: OK (>= 0.142). Launch codex exec with --dangerously-bypass-hook-trust; project must be trusted in ~/.codex/config.toml."
    else
      echo "  codex ${v:-?}: NEEDS UPGRADE. codex exec runs NO PreToolUse hooks before 0.142 (silent). Upgrade (npm i -g @openai/codex) then launch with --dangerously-bypass-hook-trust." >&2
    fi
  else
    echo "  codex: not installed."
  fi
  # Grok trust: modern folder-trust store + legacy file + user bridge.
  # Project .grok/hooks/*.json alone is not enough on Grok 0.2.93 (project
  # hooks often never load); the user bridge under ~/.grok/hooks/ is required.
  local grok_trusted=0
  if [ -f "$HOME/.grok/trusted_folders.toml" ] && grep -Fq "folders.\"$root\"" "$HOME/.grok/trusted_folders.toml" 2>/dev/null; then
    grok_trusted=1
  fi
  if grep -qxF "$root" "$HOME/.grok/trusted-hook-projects" 2>/dev/null; then
    grok_trusted=1
  fi
  if [ "$grok_trusted" -eq 1 ]; then
    echo "  grok: project trusted (OK)."
  else
    echo "  grok: NOT trusted — run core/scripts/grok-trust.sh (writes trusted_folders.toml + installs user bridge)." >&2
  fi
  if [ -d "$root/.grok/hooks" ]; then echo "  grok: .grok/hooks present (OK)."; else echo "  grok: .grok/hooks MISSING." >&2; fi
  if [ -x "$HOME/.grok/hooks/hq-hq-bridge.sh" ] && [ -f "$HOME/.grok/hooks/hq-hq-bridge.json" ]; then
    echo "  grok: user bridge installed (OK)."
  else
    echo "  grok: user bridge MISSING — run core/scripts/grok-trust.sh so HQ guards enforce (project hooks often do not load)." >&2
  fi
  if command -v grok >/dev/null 2>&1; then
    local gv
    gv="$(grok --version 2>/dev/null | head -1 || true)"
    echo "  grok: ${gv:-installed}."
  else
    echo "  grok: not installed."
  fi
}

main() {
  local command="${1:-}"
  [[ -n "${command}" ]] || { usage; exit 1; }
  shift || true

  case "${command}" in
    search) cmd_search "$@" ;;
    edit) cmd_edit "$@" ;;
    bash) cmd_bash "$@" ;;
    repo) cmd_repo "$@" ;;
    policies) cmd_policies "$@" ;;
    doctor) cmd_doctor "$@" ;;
    -h|--help) usage ;;
    *) echo "Unknown command: ${command}" >&2; usage >&2; exit 1 ;;
  esac
}

main "$@"
