#!/usr/bin/env bash
# hq-core: public
# Trust this HQ tree for Grok and install the user-global HQ hook bridge so
# HQ's .grok/ lifecycle adapter enforces under interactive + headless `grok -p`.
#
# Background (Grok Build 0.2.93):
#   - Project hooks under <repo>/.grok/hooks/*.json require folder trust, but
#     on current builds they often never appear in `grok inspect` even when
#     the project is trusted.
#   - User hooks under ~/.grok/hooks/ always load.
#   - This script therefore:
#       1) records the HQ root in the modern folder-trust store
#          (~/.grok/trusted_folders.toml) and the legacy trusted-hook-projects
#          file (back-compat with older docs/doctors);
#       2) installs a user-global bridge (~/.grok/hooks/hq-hq-bridge.*) that
#          walks from cwd to the nearest HQ root and execs the project
#          adapter (.grok/hooks/hq-grok-hook-adapter.sh);
#       3) sets [compat.claude] hooks = false in ~/.grok/config.toml so Grok
#          does not also load every project .claude/settings.json hook (that
#          double-runs guardrails and floods TUI hook annotations). HQ policy
#          still runs via bridge → adapter → .claude/hooks/hook-gate.sh.
#
# Idempotent; safe to re-run after /update-hq or promote-hq-core.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
GROK_HOME="${HOME}/.grok"
USER_HOOKS="${GROK_HOME}/hooks"
BRIDGE_SH="${USER_HOOKS}/hq-hq-bridge.sh"
BRIDGE_JSON="${USER_HOOKS}/hq-hq-bridge.json"
LEGACY_TP="${GROK_HOME}/trusted-hook-projects"
TRUST_TOML="${GROK_HOME}/trusted_folders.toml"
GROK_CONFIG="${GROK_HOME}/config.toml"
SRC_BRIDGE_SH="${ROOT}/.grok/hooks/hq-grok-user-bridge.sh"
SRC_BRIDGE_JSON="${ROOT}/.grok/hooks/hq-grok-user-bridge.json"
SRC_ADAPTER="${ROOT}/.grok/hooks/hq-grok-hook-adapter.sh"

mkdir -p "${GROK_HOME}" "${USER_HOOKS}"

# --- 1. Folder trust (modern) ---
trust_folder_toml() {
  local path="$1"
  local now
  now="$(date +%s 2>/dev/null || echo 0)"
  touch "${TRUST_TOML}"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$TRUST_TOML" "$path" "$now" <<'PY'
import re, sys
from pathlib import Path
toml_path, folder, now = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = toml_path.read_text() if toml_path.exists() else ""
# Match [folders."/abs/path"] blocks (path may contain spaces rarely; HQ roots don't).
pat = re.compile(
    r'(?m)^\[folders\."' + re.escape(folder) + r'"\]\s*\n(?:^[^\[]*\n)*'
)
block = f'[folders."{folder}"]\ntrusted = true\ndecided_at = {now}\n'
if pat.search(text):
    text = pat.sub(block + ("\n" if not block.endswith("\n") else ""), text, count=1)
    # Ensure trailing newline separation
    if not text.endswith("\n"):
        text += "\n"
else:
    if text and not text.endswith("\n"):
        text += "\n"
    if text and not text.endswith("\n\n"):
        text += "\n"
    text += block
    if not text.endswith("\n"):
        text += "\n"
toml_path.write_text(text)
print(f"grok-trust: folder-trust OK -> {folder}")
PY
  else
    # Minimal append if python missing and path not already present.
    if grep -Fq "folders.\"${path}\"" "${TRUST_TOML}" 2>/dev/null; then
      echo "grok-trust: folder-trust entry present (python missing; not rewritten) -> ${path}"
    else
      {
        echo ""
        echo "[folders.\"${path}\"]"
        echo "trusted = true"
        echo "decided_at = ${now}"
      } >> "${TRUST_TOML}"
      echo "grok-trust: folder-trust appended -> ${path}"
    fi
  fi
}

trust_folder_toml "${ROOT}"

# --- 2. Legacy trusted-hook-projects (back-compat) ---
touch "${LEGACY_TP}"
if grep -qxF "${ROOT}" "${LEGACY_TP}" 2>/dev/null; then
  echo "grok-trust: legacy trusted-hook-projects already has -> ${ROOT}"
else
  printf '%s\n' "${ROOT}" >> "${LEGACY_TP}"
  echo "grok-trust: legacy trusted-hook-projects added -> ${ROOT}"
fi

# --- 3. User-global bridge (works when project hooks don't load) ---
if [ ! -x "${SRC_ADAPTER}" ]; then
  echo "grok-trust: WARNING — project adapter missing: ${SRC_ADAPTER}" >&2
fi
if [ ! -f "${SRC_BRIDGE_SH}" ] || [ ! -f "${SRC_BRIDGE_JSON}" ]; then
  echo "grok-trust: ERROR — bridge sources missing under ${ROOT}/.grok/hooks/" >&2
  exit 1
fi

cp "${SRC_BRIDGE_SH}" "${BRIDGE_SH}"
chmod +x "${BRIDGE_SH}"
# Keep the JSON command path stable (${HOME}/.grok/hooks/hq-hq-bridge.sh).
cp "${SRC_BRIDGE_JSON}" "${BRIDGE_JSON}"
echo "grok-trust: user bridge installed -> ${BRIDGE_SH}"
echo "grok-trust: user bridge config  -> ${BRIDGE_JSON}"

if [ -d "${ROOT}/.grok/hooks" ]; then
  echo "grok-trust: project .grok/hooks present (shipped adapter + hq-grok.json)."
else
  echo "grok-trust: WARNING — ${ROOT}/.grok/hooks not found; ship the .grok/ dir into this tree." >&2
fi

# --- 4. Quiet Claude-compat settings hooks (adapter is the HQ path) ---
# Grok loads project/user .claude/settings.json hooks when [compat.claude]
# hooks=true (default). Under HQ that means ~50 shell handlers *plus* the
# bridge/adapter per tool call — noisy scrollback and wasted latency.
# Keep project .grok/hooks + user bridge; only disable Claude settings scan.
quiet_claude_compat_hooks() {
  local config="${GROK_CONFIG}"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "grok-trust: note — python3 missing; set [compat.claude] hooks = false in ${config} by hand." >&2
    return 0
  fi
  python3 - "$config" <<'PY'
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text() if path.exists() else ""
orig = text
comment = (
    "# HQ grok-trust: Grok enforces via hq-hq-bridge → adapter → .claude/hooks.\n"
    "# Do not also load every .claude/settings.json hook (double work + noisy UI).\n"
)
if re.search(r"(?m)^\[compat\.claude\]", text):
    def fix_section(m: re.Match[str]) -> str:
        body = m.group(0)
        if re.search(r"(?m)^hooks\s*=", body):
            body = re.sub(r"(?m)^hooks\s*=\s*.*$", "hooks = false", body, count=1)
        else:
            body = body.rstrip("\n") + "\nhooks = false\n"
        return body

    text, n = re.subn(
        r"(?ms)^\[compat\.claude\]\n(?:(?!^\[).*\n)*",
        fix_section,
        text,
        count=1,
    )
    if n == 0:
        text = orig
else:
    if text and not text.endswith("\n"):
        text += "\n"
    if text and not text.endswith("\n\n"):
        text += "\n"
    text += comment + "[compat.claude]\nhooks = false\n"
if text != orig:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    print(f"grok-trust: set [compat.claude] hooks = false -> {path}")
else:
    # Confirm value is false even if we did not rewrite
    if re.search(r"(?ms)^\[compat\.claude\]\n(?:(?!^\[).*\n)*hooks\s*=\s*false\b", text):
        print(f"grok-trust: [compat.claude] hooks already false -> {path}")
    else:
        print(f"grok-trust: note — could not confirm hooks=false in {path}", file=sys.stderr)
PY
}

quiet_claude_compat_hooks

# Quick self-check: does grok inspect see the user bridge?
# `grok inspect` can abort (SIGABRT) on some builds when piped; treat that as soft.
if command -v grok >/dev/null 2>&1; then
  if (cd "${ROOT}" && grok inspect --json 2>/dev/null || true) | grep -q 'hq-hq-bridge'; then
    echo "grok-trust: grok inspect sees hq-hq-bridge (OK)."
  elif [ -f "${BRIDGE_JSON}" ] && [ -x "${BRIDGE_SH}" ]; then
    echo "grok-trust: bridge files on disk (OK). Re-run \`grok inspect\` in a fresh shell if needed."
  else
    echo "grok-trust: note — bridge not visible yet; check ${USER_HOOKS}." >&2
  fi
fi

echo "grok-trust: done. HQ guards route through the user bridge → project adapter → .claude/hooks/."
echo "grok-trust: Claude settings.json hooks are off for Grok ([compat.claude] hooks = false); restart the session to refresh the TUI."
