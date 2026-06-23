#!/bin/bash
# hq-core: public
# protect-core.sh — PreToolUse hook for Edit and Write
#
# Blocks edits to files in core/core.yaml locked list.
# Warns (but allows) edits to core/core.yaml reviewable list.
# Fails open (logs + allows) if core/core.yaml is missing or malformed.
#
# Bypass: HQ_BYPASS_CORE_PROTECT must be set to "1" under "env" in
# .claude/settings.local.json. Inline env-var prefixes are NOT accepted.
#
# Trigger: PreToolUse on Edit and Write
# Exit codes: 0 = allow, 2 = block

set -uo pipefail

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || true

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

if [[ "$FILE_PATH" != /* ]]; then
  FILE_PATH="$(pwd)/$FILE_PATH"
fi

if command -v python3 >/dev/null 2>&1; then
  FILE_PATH="$(python3 -c 'import os.path,sys; sys.stdout.write(os.path.normpath(sys.argv[1]))' "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")"
fi

# Anchor on the LIVE session root (CLAUDE_PROJECT_DIR), NOT `git rev-parse` from
# the hook's cwd. The harness runs Edit/Write hooks with cwd at/near the target
# file, so when that target lives inside a checked-out repo (repos/<repo>/ or a
# git worktree under workspace/worktrees/<repo>/<name>/) `git rev-parse` resolves
# HQ_ROOT to the CHECKOUT's toplevel and then treats the checkout's own .claude/
# or core/ as the locked live root -- a false positive that blocks legitimate dev
# edits to a repo's scaffold. CLAUDE_PROJECT_DIR always points at the live HQ
# root the session was launched from, matching the companion block-core-writes.sh.
# Fall back to `git rev-parse` only when it is unset (e.g. non-Claude harnesses).
HQ_ROOT="${CLAUDE_PROJECT_DIR:-}"
if [[ -z "$HQ_ROOT" ]]; then
  HQ_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || HQ_ROOT=""
fi
if [[ -z "$HQ_ROOT" ]]; then
  echo "WARNING: protect-core.sh could not determine HQ root (no CLAUDE_PROJECT_DIR; git rev-parse failed). Skipping check." >&2
  exit 0
fi
if command -v python3 >/dev/null 2>&1; then
  HQ_ROOT="$(python3 -c 'import os.path,sys; sys.stdout.write(os.path.normpath(sys.argv[1]))' "$HQ_ROOT" 2>/dev/null || echo "$HQ_ROOT")"
fi

# ── Targeted guard: block learned-rule injection into the charter ──
# Fires BEFORE the HQ_BYPASS_CORE_PROTECT bypass below — learned rules must
# never be written into .claude/CLAUDE.md / AGENTS.md, even with the bypass on
# (policy learned-rules-never-in-claude-md). Only writes carrying a learned-rule
# signature are blocked, so legitimate charter edits still fall through to the
# normal lock logic. The wholesale /update-hq release path writes via cp (not
# the Edit/Write tool), so it is unaffected.
_norm() { if command -v python3 >/dev/null 2>&1; then python3 -c 'import os.path,sys; sys.stdout.write(os.path.normpath(sys.argv[1]))' "$1" 2>/dev/null || echo "$1"; else echo "$1"; fi; }
CHARTER_MD="$(_norm "$HQ_ROOT/.claude/CLAUDE.md")"
AGENTS_MD="$(_norm "$HQ_ROOT/AGENTS.md")"
if [[ "$FILE_PATH" == "$CHARTER_MD" || "$FILE_PATH" == "$AGENTS_MD" ]]; then
  ADDED=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // empty' 2>/dev/null) || ADDED=""
  if printf '%s' "$ADDED" | grep -qE '(<!--[[:space:]]*(user-correction|back-pressure-failure))|^##[[:space:]]+Learned Rules|^-[[:space:]]+\*\*(NEVER|ALWAYS)\*\*:.*<!--'; then
    cat >&2 <<MSG
BLOCKED: refusing to write a learned rule into the HQ charter.
  File: $FILE_PATH

Learned rules never go in .claude/CLAUDE.md / AGENTS.md
(policy learned-rules-never-in-claude-md). Route the rule to a policy file:
  • Operator / universal → personal/policies/{slug}.md (symlinked into core/policies/, survives upgrade)
  • Company-specific      → companies/{co}/policies/{slug}.md
  • Release-shipped       → core/policies/{slug}.md (enforcement: hard), then /promote-hq-core
MSG
    exit 2
  fi
fi

# ── Targeted guard: block CREATION of a new policy file under core/policies/ ──
# This is the /learn-leak guard. It fires BEFORE (and independently of) the
# broad HQ_BYPASS_CORE_PROTECT bypass below, because that bypass is commonly
# left enabled in settings.local.json — which is exactly the condition under
# which /learn silently writes a new operator/company rule into core/policies/,
# where /update-hq wipes it on the next upgrade (policy
# hq-customizations-live-in-personal-or-company).
#
# Scope is deliberately narrow:
#   • Only NEW files (path does not yet exist). Edits to existing release-shipped
#     core policies — the builder-mode + /promote-hq-core workflow — pass through.
#   • Writing THROUGH an existing personal→core symlink passes (-e follows it).
#   • reindex symlinks (ln), /update-hq copies (cp), and /promote-hq-core
#     writes (which target repos/private/hq-core-staging, not local core) never
#     hit the Edit/Write tool path, so they are unaffected.
# Sanctioned escape for tooling that must author a core policy locally:
#   HQ_ALLOW_CORE_POLICY_WRITE=1 (inline env is accepted here, unlike the broad
#   bypass — this is a narrow, single-purpose hatch).
if [[ "${HQ_ALLOW_CORE_POLICY_WRITE:-}" != "1" ]]; then
  CORE_POLICIES_DIR="$HQ_ROOT/core/policies"
  case "$FILE_PATH" in
    "$CORE_POLICIES_DIR"/*.md)
      base="$(basename "$FILE_PATH")"
      if [[ ! -e "$FILE_PATH" ]]; then
        cat >&2 <<MSG
BLOCKED: refusing to create a new policy file directly in core/policies/.
  File: $FILE_PATH

core/ is release-shipped scaffold — /update-hq replaces it wholesale, so a new
policy written here is lost on the next upgrade.

Route it instead:
  • Operator / universal rule  → personal/policies/$base
       (reindex.sh symlinks it into core/policies/ — it still loads as a
        global policy, but survives upgrade)
  • Company-specific rule      → companies/{co}/policies/$base
  • Repo-specific rule         → repos/{pub|priv}/{repo}/.claude/policies/$base
  • Genuine product-core rule  → author locally, then publish via
       repos/private/hq-core-staging/ + /promote-hq-core (staging gate)

See core/policies/hq-customizations-live-in-personal-or-company.md.
(Sanctioned tooling override: prefix the command with HQ_ALLOW_CORE_POLICY_WRITE=1.)
MSG
        exit 2
      fi
      ;;
  esac
fi

CORE_YAML="$HQ_ROOT/core/core.yaml"
SETTINGS_LOCAL="$HQ_ROOT/.claude/settings.local.json"

if [[ ! -f "$CORE_YAML" ]]; then
  echo "WARNING: protect-core.sh: core/core.yaml not found. Skipping check." >&2
  exit 0
fi

if ! which yq >/dev/null 2>&1; then
  echo "WARNING: protect-core.sh: yq not found. Install: brew install yq" >&2
  exit 0
fi

# Bypass: must be declared in .claude/settings.local.json env section.
is_bypass_authorized() {
  [[ -f "$SETTINGS_LOCAL" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local val
  val=$(jq -r '.env.HQ_BYPASS_CORE_PROTECT // empty' "$SETTINGS_LOCAL" 2>/dev/null) || return 1
  [[ "$val" == "1" || "$val" == "true" ]] && return 0
  return 1
}

if is_bypass_authorized; then
  exit 0
fi

norm_path() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os.path,sys; sys.stdout.write(os.path.normpath(sys.argv[1]))' "$1" 2>/dev/null || echo "$1"
  else
    echo "$1"
  fi
}

# Check exclude list first — always allowed.
EXCLUDE_PATHS=$(yq eval '.rules.exclude[]' "$CORE_YAML" 2>/dev/null) || EXCLUDE_PATHS=""
while IFS= read -r exc_path; do
  [[ -z "$exc_path" ]] && continue
  exc_abs="$(norm_path "${HQ_ROOT}/${exc_path%/}")"
  if [[ "$FILE_PATH" == "$exc_abs" ]] || [[ "$FILE_PATH" == "$exc_abs/"* ]]; then
    exit 0
  fi
done <<< "$EXCLUDE_PATHS"

# Specific file redirects — give a helpful pointer before the generic block.
CLAUDE_MD_ABS="$(norm_path "${HQ_ROOT}/.claude/CLAUDE.md")"
SETTINGS_JSON_ABS="$(norm_path "${HQ_ROOT}/.claude/settings.json")"
if [[ "$FILE_PATH" == "$CLAUDE_MD_ABS" ]]; then
  cat >&2 <<MSG
BLOCKED: .claude/CLAUDE.md is the locked HQ charter.
  Edit personal/CLAUDE.md for your personal additions instead.
MSG
  exit 2
fi
if [[ "$FILE_PATH" == "$SETTINGS_JSON_ABS" ]]; then
  cat >&2 <<MSG
BLOCKED: .claude/settings.json is locked.
  Edit .claude/settings.local.json for local overrides instead.
MSG
  exit 2
fi

# Check locked paths.
LOCKED_PATHS=$(yq eval '.rules.locked[]' "$CORE_YAML" 2>/dev/null) || {
  echo "WARNING: protect-core.sh: failed to parse locked paths (malformed?). Skipping check." >&2
  exit 0
}

while IFS= read -r locked_path; do
  [[ -z "$locked_path" ]] && continue
  locked_abs="$(norm_path "${HQ_ROOT}/${locked_path%/}")"
  if [[ "$FILE_PATH" == "$locked_abs" ]] || [[ "$FILE_PATH" == "$locked_abs/"* ]]; then
    cat >&2 <<MSG
BLOCKED: Edit to locked path is not allowed.
  File: $FILE_PATH
  Locked: $locked_path

To bypass: set "HQ_BYPASS_CORE_PROTECT": "1" under "env" in .claude/settings.local.json
(inline env-var prefixes are not accepted).
MSG
    exit 2
  fi
done <<< "$LOCKED_PATHS"

# Check reviewable paths (warn, allow).
REVIEWABLE_PATHS=$(yq eval '.rules.reviewable[]' "$CORE_YAML" 2>/dev/null) || REVIEWABLE_PATHS=""
while IFS= read -r reviewable_path; do
  [[ -z "$reviewable_path" ]] && continue
  reviewable_abs="$(norm_path "${HQ_ROOT}/${reviewable_path%/}")"
  if [[ "$FILE_PATH" == "$reviewable_abs" ]] || [[ "$FILE_PATH" == "$reviewable_abs/"* ]]; then
    cat >&2 <<MSG
WARNING: Editing reviewable path.
  File: $FILE_PATH
  Reviewable: $reviewable_path
Edit allowed — proceed with care.
MSG
    exit 0
  fi
done <<< "$REVIEWABLE_PATHS"

exit 0
