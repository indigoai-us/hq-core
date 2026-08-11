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
  core/scripts/codex-preflight.sh sandbox
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

# sandbox: probe whether Codex's OS sandbox can run HQ's workloads on THIS host,
# and whether HQ's shipped Codex posture is the danger-full-access one HQ relies
# on. Prevents harness finding 2.3 (Codex sandbox denials) from failing silently
# 726+ times: the workspace-write sandbox forced by `codex exec --full-auto`
# denies temp/cache/socket writes on macOS (git/Xcode/asdf/zsh heredocs) and
# cannot even initialize bubblewrap networking on some Linux hosts
# (`bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`). HQ's safety
# boundary is its hooks, not the Codex sandbox, so HQ ships danger-full-access.
# Exit 0 = OK; exit 1 = misconfigured posture or a broken host sandbox.
cmd_sandbox() {
  local root; root="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
  local rc=0
  echo "HQ Codex sandbox doctor"

  # 1) Shipped posture: HQ's .codex/config.toml must declare danger-full-access.
  # HQ_CODEX_CONFIG overrides the probed file (used by the regression test).
  local cfg="${HQ_CODEX_CONFIG:-${root}/.codex/config.toml}" mode=""
  if [[ -f "${cfg}" ]]; then
    # `|| true`: a config with no sandbox_mode key must reach the empty-mode
    # branch below, not abort the whole probe under `set -euo pipefail`.
    mode="$(grep -E '^[[:space:]]*sandbox_mode[[:space:]]*=' "${cfg}" 2>/dev/null \
      | head -1 | sed -E 's/.*=[[:space:]]*"?([a-z-]+)"?.*/\1/' || true)"
  fi
  case "${mode}" in
    danger-full-access)
      echo "  posture: sandbox_mode=danger-full-access (OK — HQ hooks are the safety boundary)."
      ;;
    workspace-write|read-only)
      echo "  posture: sandbox_mode=${mode} (BROKEN for HQ workflows). This over-restrictive sandbox denies temp/cache/socket writes (macOS) and bubblewrap setup (Linux). Set sandbox_mode=\"danger-full-access\" in ${cfg}." >&2
      rc=1
      ;;
    "")
      echo "  posture: no sandbox_mode found in ${cfg:-<missing .codex/config.toml>}; Codex will fall back to its default sandbox. HQ requires sandbox_mode=\"danger-full-access\"." >&2
      rc=1
      ;;
    *)
      echo "  posture: sandbox_mode=${mode} (unrecognized). HQ requires sandbox_mode=\"danger-full-access\"." >&2
      rc=1
      ;;
  esac

  # 2) Host capability probe follows. HQ_SANDBOX_OS overrides the detected OS
  # (used by the regression test to exercise the Linux bwrap path on any host).
  local os; os="${HQ_SANDBOX_OS:-$(uname -s 2>/dev/null || echo unknown)}"

  # 3) Host capability probe (best-effort; only the workspace-write/read-only
  # sandboxes invoke bubblewrap — danger-full-access bypasses it entirely). A
  # bwrap limitation is therefore only ACTIONABLE when the posture would use it;
  # under danger-full-access it is purely informational and must NOT fail the
  # probe, since danger-full-access is the very config that recovers such hosts.
  local bwrap_gates=1
  [[ "${mode}" == "danger-full-access" ]] && bwrap_gates=0
  case "${os}" in
    Linux)
      if command -v bwrap >/dev/null 2>&1; then
        # Reproduce Codex's network-namespace setup. On hosts lacking the
        # capability this fails exactly as the 2.3 rollouts did.
        local probe
        if probe="$(bwrap --ro-bind / / --unshare-net --dev /dev /bin/true 2>&1)"; then
          echo "  host: bubblewrap net-namespace sandbox initializes (OK). workspace-write would work here."
        elif [[ "${bwrap_gates}" -eq 1 ]]; then
          echo "  host: bubblewrap sandbox CANNOT initialize on this host: ${probe}. Under the current posture (${mode:-none}) Codex will fail before the task starts — you MUST use sandbox_mode=danger-full-access (HQ default), which bypasses bubblewrap." >&2
          rc=1
        else
          echo "  host: NOTE — bubblewrap cannot initialize here (${probe}), but the danger-full-access posture bypasses bubblewrap, so this host is fine. (workspace-write/read-only would NOT work here.)"
        fi
      else
        echo "  host: bwrap not on PATH; cannot probe the Linux sandbox directly. Rely on danger-full-access posture above."
      fi
      ;;
    Darwin)
      echo "  host: macOS Seatbelt workspace-write denies /tmp + \$TMPDIR + ~/.cache writes and local socket binds used by git/Xcode/asdf/zsh and agent-browser. Keep sandbox_mode=danger-full-access for HQ workflows; do not launch codex exec with --full-auto/--approve-for-me."
      ;;
    *)
      echo "  host: unrecognized OS '${os}'; cannot probe the sandbox. Rely on danger-full-access posture above."
      ;;
  esac

  if [[ "${rc}" -eq 0 ]]; then
    echo "  result: OK — Codex sandbox posture is safe to run HQ workloads on this host."
  else
    echo "  result: ACTION REQUIRED — see the messages above (finding 2.3)." >&2
  fi
  return "${rc}"
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
    echo "  grok: NOT trusted — run `hq reindex` (writes trusted_folders.toml + installs user bridge)." >&2
  fi
  if [ -d "$root/.grok/hooks" ]; then echo "  grok: .grok/hooks present (OK)."; else echo "  grok: .grok/hooks MISSING." >&2; fi
  if [ -x "$HOME/.grok/hooks/hq-hq-bridge.sh" ] && [ -f "$HOME/.grok/hooks/hq-hq-bridge.json" ]; then
    echo "  grok: user bridge installed (OK)."
  else
    echo "  grok: user bridge MISSING — run `hq reindex` so HQ guards enforce (project hooks often do not load)." >&2
  fi
  if command -v grok >/dev/null 2>&1; then
    local gv
    gv="$(grok --version 2>/dev/null | head -1 || true)"
    echo "  grok: ${gv:-installed}."
  else
    echo "  grok: not installed."
  fi
  # Codex sandbox posture + host capability (finding 2.3). Non-fatal in doctor;
  # run `codex-preflight.sh sandbox` directly for a gating exit code.
  cmd_sandbox || true
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
    sandbox) cmd_sandbox "$@" ;;
    doctor) cmd_doctor "$@" ;;
    -h|--help) usage ;;
    *) echo "Unknown command: ${command}" >&2; usage >&2; exit 1 ;;
  esac
}

main "$@"
