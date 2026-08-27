#!/usr/bin/env bash

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/route-company-skill-creation.sh"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/companies/acme/skills/stamped" \
  "$TMP/companies/acme/skills/legacy" \
  "$TMP/.claude/skills"
cat >"$TMP/companies/manifest.yaml" <<'YAML'
companies:
  acme:
    prefix: acm
YAML
cat >"$TMP/companies/acme/skills/stamped/SKILL.md" <<'MD'
---
name: Stamped
description: Registered
skill_uid: skl_ABC123
---
MD
cat >"$TMP/companies/acme/skills/legacy/SKILL.md" <<'MD'
---
name: Legacy
description: Missing identity
---
MD

payload() {
  jq -nc --arg path "$1" '{tool_name:"Write",tool_input:{file_path:$path}}'
}

run_gate() {
  local profile="$1" path="$2"
  payload "$path" | CLAUDE_PROJECT_DIR="$TMP" HQ_HOOK_PROFILE="$profile" \
    bash "$GATE" route-company-skill-creation "$HOOK"
}

for profile in minimal standard strict; do
  run_gate "$profile" "$TMP/companies/acme/skills/stamped/SKILL.md" \
    || { echo "FAIL: stamped skill blocked in $profile" >&2; exit 1; }

  if run_gate "$profile" "$TMP/companies/acme/skills/new-skill/SKILL.md" \
      >"$TMP/new.out" 2>"$TMP/new.err"; then
    echo "FAIL: new unstamped skill passed in $profile" >&2
    exit 1
  fi
  grep -Fq 'hq skill --company acme create new-skill --no-sync' "$TMP/new.err" \
    || { echo "FAIL: new-skill remedy missing in $profile" >&2; exit 1; }

  if run_gate "$profile" "$TMP/companies/acme/skills/legacy/SKILL.md" \
      >"$TMP/legacy.out" 2>"$TMP/legacy.err"; then
    echo "FAIL: legacy unstamped skill passed in $profile" >&2
    exit 1
  fi

  if run_gate "$profile" "$TMP/.claude/skills/acme:stamped/SKILL.md" \
      >"$TMP/wrapper.out" 2>"$TMP/wrapper.err"; then
    echo "FAIL: namespaced generated wrapper passed in $profile" >&2
    exit 1
  fi
  grep -Fq 'companies/acme/skills/stamped/SKILL.md' "$TMP/wrapper.err" \
    || { echo "FAIL: namespaced wrapper remedy missing in $profile" >&2; exit 1; }

  if run_gate "$profile" "$TMP/.claude/skills/acme%3Astamped/SKILL.md" \
      >"$TMP/windows-wrapper.out" 2>"$TMP/windows-wrapper.err"; then
    echo "FAIL: Windows-encoded generated wrapper passed in $profile" >&2
    exit 1
  fi
done

echo "PASS: company skill creation is identity-gated in every hook profile"
