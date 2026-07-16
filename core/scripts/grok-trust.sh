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

  if command -v node >/dev/null 2>&1; then
    node - "$TRUST_TOML" "$path" "$now" <<'JS'
const fs = require("fs");
const [tomlPath, folder, now] = process.argv.slice(2);
let text = "";
try { text = fs.readFileSync(tomlPath, "utf8"); } catch (e) {}
// Match [folders."/abs/path"] blocks (path may contain spaces rarely; HQ roots don't).
const esc = folder.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const pat = new RegExp('^\\[folders\\."' + esc + '"\\]\\s*\\n(?:^[^\\[]*\\n)*', "m");
const block = '[folders."' + folder + '"]\ntrusted = true\ndecided_at = ' + now + "\n";
if (pat.test(text)) {
  text = text.replace(pat, block);
  // Ensure trailing newline separation
  if (!text.endsWith("\n")) text += "\n";
} else {
  if (text && !text.endsWith("\n")) text += "\n";
  if (text && !text.endsWith("\n\n")) text += "\n";
  text += block;
  if (!text.endsWith("\n")) text += "\n";
}
fs.writeFileSync(tomlPath, text);
console.log("grok-trust: folder-trust OK -> " + folder);
JS
  else
    # Minimal append if node missing and path not already present.
    if grep -Fq "folders.\"${path}\"" "${TRUST_TOML}" 2>/dev/null; then
      echo "grok-trust: folder-trust entry present (node missing; not rewritten) -> ${path}"
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
  if ! command -v node >/dev/null 2>&1; then
    echo "grok-trust: note — node missing; set [compat.claude] hooks = false in ${config} by hand." >&2
    return 0
  fi
  node - "$config" <<'JS'
const fs = require("fs");
const path = require("path");
const config = process.argv[2];
let text = "";
try { text = fs.readFileSync(config, "utf8"); } catch (e) {}
const orig = text;
const comment =
  "# HQ grok-trust: Grok enforces via hq-hq-bridge → adapter → .claude/hooks.\n" +
  "# Do not also load every .claude/settings.json hook (double work + noisy UI).\n";
if (/^\[compat\.claude\]/m.test(text)) {
  const section = /^\[compat\.claude\]\n(?:(?!\[)[^\n]*\n)*/m;
  const m = text.match(section);
  if (m) {
    let body = m[0];
    if (/^hooks\s*=/m.test(body)) {
      body = body.replace(/^hooks\s*=\s*.*$/m, "hooks = false");
    } else {
      body = body.replace(/\n+$/, "") + "\nhooks = false\n";
    }
    text = text.replace(section, body);
  }
} else {
  if (text && !text.endsWith("\n")) text += "\n";
  if (text && !text.endsWith("\n\n")) text += "\n";
  text += comment + "[compat.claude]\nhooks = false\n";
}
if (text !== orig) {
  fs.mkdirSync(path.dirname(config), { recursive: true });
  fs.writeFileSync(config, text);
  console.log("grok-trust: set [compat.claude] hooks = false -> " + config);
} else {
  // Confirm value is false even if we did not rewrite
  if (/^\[compat\.claude\]\n(?:(?!\[)[^\n]*\n)*hooks\s*=\s*false\b/m.test(text)) {
    console.log("grok-trust: [compat.claude] hooks already false -> " + config);
  } else {
    process.stderr.write("grok-trust: note — could not confirm hooks=false in " + config + "\n");
  }
}
JS
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
