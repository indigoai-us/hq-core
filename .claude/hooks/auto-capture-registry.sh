#!/bin/bash
# Auto-capture registry hook — detects resource-creation events in PostToolUse Bash
# output and writes resource stubs into the matching company's registry folder.
#
# Detected events:
#   - `gh repo create {org}/{name}` → creates resources/repo-{name}.yaml
#   - `vercel deploy ... --scope team_XXX` → creates/updates resources/vercel-{project}.yaml
#
# The matching company is determined by:
#   - gh repo create: `companies.{co}.github_org` equals the org in the command
#   - vercel deploy:  `companies.{co}.vercel_team` equals the team id in the command
#
# Only companies with a `registry:` path declared in companies/manifest.yaml are
# considered. All write operations are local-only — the hook never runs git.
#
# Non-blocking: failures are logged but never interrupt the user's command.
# Gated behind HQ_HOOK_PROFILE=standard (not minimal).

set -uo pipefail

HQ_ROOT="${HQ_ROOT:-$HOME/hq}"
MANIFEST="$HQ_ROOT/companies/manifest.yaml"
LOG_FILE="/tmp/hq-auto-capture-registry.log"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] auto-capture-registry: $*" >> "$LOG_FILE"
}

# Read tool input from stdin (PostToolUse provides JSON with tool_input)
INPUT=$(cat)

COMMAND=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('tool_input', {}).get('command', ''))
except Exception:
    print('')
" 2>/dev/null)

[ -z "$COMMAND" ] && exit 0
[ ! -f "$MANIFEST" ] && exit 0
command -v yq >/dev/null 2>&1 || { log "yq not available — skipping"; exit 0; }

# Resolve company by predicate (github_org or vercel_team) via yq.
# Returns the company slug whose $field equals $value, or empty string.
resolve_company() {
  local field="$1"
  local value="$2"
  yq -r ".companies | to_entries[] | select(.value.${field} == \"${value}\") | .key" "$MANIFEST" 2>/dev/null | head -1
}

# Returns the registry path for a company, or empty string if none.
registry_path_for() {
  local slug="$1"
  yq -r ".companies.\"${slug}\".registry // \"\"" "$MANIFEST" 2>/dev/null
}

regen_index_if_possible() {
  local reg_dir="$1"
  local script="$reg_dir/scripts/generate-index.sh"
  if [ -x "$script" ]; then
    bash "$script" >> "$LOG_FILE" 2>&1 || true
    log "regenerated $reg_dir/registry.yaml"
  fi
}

# --- Detect: gh repo create {org}/{name} ---
if echo "$COMMAND" | grep -qE 'gh\s+repo\s+create\s+[A-Za-z0-9._-]+/[A-Za-z0-9._-]+'; then
  ORG=$(echo "$COMMAND" | grep -oE 'gh\s+repo\s+create\s+[A-Za-z0-9._-]+/' \
    | sed -E 's|gh[[:space:]]+repo[[:space:]]+create[[:space:]]+||; s|/$||' | head -1)
  REPO_NAME=$(echo "$COMMAND" | grep -oE "${ORG}/[A-Za-z0-9._-]+" | head -1 | sed "s|${ORG}/||")

  if [ -z "$ORG" ] || [ -z "$REPO_NAME" ]; then
    log "detected gh repo create but could not extract org/name from: $COMMAND"
    exit 0
  fi

  CO=$(resolve_company "github_org" "$ORG")
  if [ -z "$CO" ]; then
    log "gh repo create for org '$ORG' — no company matches in manifest.github_org; skipping"
    exit 0
  fi

  REG_PATH=$(registry_path_for "$CO")
  if [ -z "$REG_PATH" ] || [ "$REG_PATH" = "null" ]; then
    log "company '$CO' matched for org '$ORG' but has no registry declared; skipping"
    exit 0
  fi

  REG_DIR="$HQ_ROOT/$REG_PATH"
  RESOURCES_DIR="$REG_DIR/resources"
  if [ ! -d "$RESOURCES_DIR" ]; then
    log "registry '$REG_DIR' declared but resources/ dir missing for company '$CO'; skipping"
    exit 0
  fi

  RESOURCE_ID="repo-${REPO_NAME}"
  RESOURCE_FILE="$RESOURCES_DIR/${RESOURCE_ID}.yaml"
  if [ -f "$RESOURCE_FILE" ]; then
    log "resource file already exists: $RESOURCE_FILE — skipping"
    exit 0
  fi

  IS_PRIVATE="false"
  echo "$COMMAND" | grep -qE '\-\-private' && IS_PRIVATE="true"
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  cat > "$RESOURCE_FILE" <<YAML
# Auto-captured from: gh repo create
# Event: $COMMAND
id: ${RESOURCE_ID}
name: "${REPO_NAME}"
type: repo
purpose: "Auto-captured repository — update this description"
owner: ${CO}-engineering
status: active
dependencies: []
used_by: []
constraints:
  - "private: ${IS_PRIVATE}"
tags:
  - auto-captured
repo_url: "https://github.com/${ORG}/${REPO_NAME}"
created_at: "${NOW}"
updated_at: "${NOW}"
YAML

  log "created $RESOURCE_FILE for company '$CO' (from gh repo create)"
  regen_index_if_possible "$REG_DIR"
  exit 0
fi

# --- Detect: vercel deploy with a known company team ---
if echo "$COMMAND" | grep -qE 'vercel\s+deploy'; then
  TEAM=$(echo "$COMMAND" | grep -oE 'team_[A-Za-z0-9]+' | head -1)
  if [ -z "$TEAM" ]; then
    log "vercel deploy detected but no team_ id in command; skipping"
    exit 0
  fi

  CO=$(resolve_company "vercel_team" "$TEAM")
  if [ -z "$CO" ]; then
    log "vercel deploy with team '$TEAM' — no company matches in manifest.vercel_team; skipping"
    exit 0
  fi

  REG_PATH=$(registry_path_for "$CO")
  if [ -z "$REG_PATH" ] || [ "$REG_PATH" = "null" ]; then
    log "company '$CO' matched team '$TEAM' but has no registry declared; skipping"
    exit 0
  fi

  REG_DIR="$HQ_ROOT/$REG_PATH"
  RESOURCES_DIR="$REG_DIR/resources"
  if [ ! -d "$RESOURCES_DIR" ]; then
    log "registry '$REG_DIR' declared but resources/ dir missing for company '$CO'; skipping"
    exit 0
  fi

  PROJECT_NAME=$(echo "$COMMAND" | grep -oE '\-\-project\s+[A-Za-z0-9._-]+' | awk '{print $2}' | head -1)
  if [ -z "$PROJECT_NAME" ]; then
    log "vercel deploy for company '$CO' but --project name missing; skipping (avoid phantom stubs)"
    exit 0
  fi

  RESOURCE_ID="vercel-${PROJECT_NAME}"
  RESOURCE_FILE="$RESOURCES_DIR/${RESOURCE_ID}.yaml"
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [ -f "$RESOURCE_FILE" ]; then
    yq -i ".updated_at = \"${NOW}\"" "$RESOURCE_FILE" 2>/dev/null || true
    log "touched $RESOURCE_FILE (existing, bumped updated_at)"
    exit 0
  fi

  cat > "$RESOURCE_FILE" <<YAML
# Auto-captured from: vercel deploy
# Event: $COMMAND
id: ${RESOURCE_ID}
name: "${PROJECT_NAME} (Vercel)"
type: app
purpose: "Auto-captured Vercel deployment — update this description"
owner: ${CO}-engineering
status: active
dependencies: []
used_by: []
constraints:
  - "platform: vercel"
  - "team: ${TEAM}"
tags:
  - auto-captured
  - vercel
created_at: "${NOW}"
updated_at: "${NOW}"
YAML

  log "created $RESOURCE_FILE for company '$CO' (from vercel deploy)"
  regen_index_if_possible "$REG_DIR"
  exit 0
fi

exit 0
