#!/usr/bin/env bash
# Regression coverage for the Codex output-style bridge.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_link_target() {
  local link_path="$1"
  local expected="$2"
  [[ -L "${link_path}" ]] || fail "${link_path} is not a symlink"
  local actual
  actual="$(readlink "${link_path}")"
  [[ "${actual}" == "${expected}" ]] || fail "${link_path}: expected '${expected}', got '${actual}'"
}

HQ_ROOT="${TMP}/HQ"
mkdir -p \
  "${HQ_ROOT}/.claude/commands" \
  "${HQ_ROOT}/.claude/hooks" \
  "${HQ_ROOT}/.claude/policies" \
  "${HQ_ROOT}/.claude/skills/demo/agents" \
  "${HQ_ROOT}/.claude/output-styles" \
  "${HQ_ROOT}/core/scripts"

cp "${ROOT}/core/scripts/codex-skill-bridge.sh" "${HQ_ROOT}/core/scripts/codex-skill-bridge.sh"
chmod +x "${HQ_ROOT}/core/scripts/codex-skill-bridge.sh"

cat > "${HQ_ROOT}/.claude/settings.json" <<'JSON'
{
  "outputStyle": "Cavebro"
}
JSON

cat > "${HQ_ROOT}/.claude/output-styles/cavebro.md" <<'MD'
---
name: Cavebro
---

Terse chat voice.
MD

cat > "${HQ_ROOT}/.claude/commands/demo.md" <<'MD'
# /demo
MD

cat > "${HQ_ROOT}/.claude/skills/demo/SKILL.md" <<'MD'
---
name: demo
description: Demo skill.
---
MD

HOME="${TMP}/home" bash "${HQ_ROOT}/core/scripts/codex-skill-bridge.sh" install --root "${HQ_ROOT}" >"${TMP}/codex-output-style-bridge.out"

assert_link_target "${HQ_ROOT}/.codex/output-style.md" "${HQ_ROOT}/.claude/output-styles/cavebro.md"

status="$(HOME="${TMP}/home" bash "${HQ_ROOT}/core/scripts/codex-skill-bridge.sh" status --root "${HQ_ROOT}")"
[[ "${status}" == *"Active output style: Cavebro"* ]] || fail "status did not report active Cavebro style"
[[ "${status}" == *"Project Codex output-style bridge"* ]] || fail "status did not report output-style bridge"
[[ "${status}" == *"status: healthy"* ]] || fail "status did not report healthy bridges"

echo "codex output-style bridge tests passed"
