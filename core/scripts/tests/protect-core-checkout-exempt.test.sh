#!/usr/bin/env bash
# Regression: protect-core.sh must anchor on CLAUDE_PROJECT_DIR (the live HQ
# root), NOT `git rev-parse` from the hook's cwd. The harness runs Edit/Write
# hooks with cwd at/near the target file, so a file inside a checked-out repo
# (repos/<repo>/) or a git worktree (workspace/worktrees/<repo>/<name>/) must NOT
# be treated as the locked live-root scaffold merely because the checkout has its
# own .claude/ or core/. A naive `git rev-parse --show-toplevel` from the hook's
# cwd would resolve HQ_ROOT to the checkout and false-block legitimate dev edits.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/protect-core.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not available"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$HOOK" ] || fail "hook not found: $HOOK"

# Fake live HQ root with a minimal core.yaml locking the scaffold dirs and NO
# settings.local.json (so the HQ_BYPASS_CORE_PROTECT escape hatch is inert).
PROJ="$(mktemp -d)"; trap 'rm -rf "$PROJ"' EXIT
write_core_yaml() {
  mkdir -p "$1/core"
  cat > "$1/core/core.yaml" <<'YAML'
rules:
  locked:
    - .claude/
    - core/
  exclude:
    - .claude/settings.local.json
  reviewable: []
YAML
}
mkdir -p "$PROJ/.claude/hooks"
write_core_yaml "$PROJ"

# Two nested checkouts that are SEPARATE git repos, each carrying its own full
# scaffold (.claude/ + core/core.yaml) — exactly the shape that tricks a
# cwd-based `git rev-parse`. Without the CLAUDE_PROJECT_DIR anchor these would
# false-block.
REPO_CO="$PROJ/repos/private/hq-core-staging"
WT_CO="$PROJ/workspace/worktrees/hq-core-staging/wt"
for co in "$REPO_CO" "$WT_CO"; do
  mkdir -p "$co/.claude/hooks" "$co/core/scripts"
  write_core_yaml "$co"
  git init -q "$co"
done

export CLAUDE_PROJECT_DIR="$PROJ"

# Drive the hook from INSIDE the given cwd (mimics the harness running the Edit
# hook with cwd at the target file).
gate() { local fp="$1" cwd="$2"; ( cd "$cwd" && printf '{"tool_input":{"file_path":"%s"}}' "$fp" | bash "$HOOK" >/dev/null 2>&1; echo $? ); }
expect() { local want="$1" got; got="$(gate "$2" "$3")"; [ "$got" = "$want" ] || fail "want exit $want got $got for: $2 (cwd=$3)"; pass "exit $want :: $4"; }

echo "[1] live-root scaffold writes are BLOCKED"
expect 2 "$PROJ/.claude/hooks/evil.sh" "$PROJ" 'block live-root .claude/'
expect 2 "$PROJ/core/scripts/evil.sh"  "$PROJ" 'block live-root core/'

echo "[2] repos/ checkout scaffold writes are ALLOWED (cwd inside the checkout)"
expect 0 "$REPO_CO/.claude/hooks/x.sh"  "$REPO_CO" 'allow repos checkout .claude/'
expect 0 "$REPO_CO/core/scripts/x.sh"   "$REPO_CO" 'allow repos checkout core/'

echo "[3] workspace/worktrees/ checkout scaffold writes are ALLOWED (cwd inside the worktree)"
expect 0 "$WT_CO/.claude/hooks/x.sh"    "$WT_CO" 'allow worktree .claude/'
expect 0 "$WT_CO/core/scripts/x.sh"     "$WT_CO" 'allow worktree core/'

echo "ALL PASS: protect-core-checkout-exempt"
