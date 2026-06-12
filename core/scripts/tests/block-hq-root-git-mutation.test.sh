#!/usr/bin/env bash
# hq-core: public
# Regression tests for block-hq-root-git-mutation.sh.
#
# Covers the 2026-06-09 reconciliation with the Claude Code harness:
#   - the harness silently strips a leading `cd /abs/path && ` when the path
#     equals the session cwd, so a cd-anchored mutation reaches the hook bare
#     -> cwd fallback must allow it when input cwd is a non-HQ-root repo;
#   - `gh repo create` accepts neither `git -C` nor `-R` and is
#     self-anchoring (target named in args; --source guarded);
#   - the parenthesized `( cd /abs && git ... )` form historically failed
#     anchor extraction even when it survived the harness (regex fix).

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/block-hq-root-git-mutation.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake HQ root (a git repo) with a nested working repo, mirroring real layout.
git -C "$TMP" init -q
mkdir -p "$TMP/repos/private/app"
git -C "$TMP/repos/private/app" init -q
mkdir -p "$TMP/not-a-repo"

PASS=0
FAIL=0

# run <expected_exit> <cwd> <command...>
run() {
  local expect="$1" cwd="$2" cmd="$3" label="$4"
  local payload rc=0
  payload=$(jq -n --arg cwd "$cwd" --arg cmd "$cmd" '{cwd: $cwd, tool_input: {command: $cmd}}')
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$TMP" HQ_ALLOW_HQ_ROOT_GIT= bash "$HOOK" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq "$expect" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [$label]: expected exit $expect, got $rc — cmd: $cmd (cwd: $cwd)" >&2
  fi
}

NESTED="$TMP/repos/private/app"

# --- Original guard: bare mutations from the HQ root stay blocked ---------
run 2 "$TMP" 'git commit -m x'                       'bare commit @ HQ root blocked'
run 2 "$TMP" 'git push origin main'                  'bare push @ HQ root blocked'
run 2 "$TMP" '( git add --dry-run README.md )'       'paren bare add @ HQ root blocked (post-strip shape, 2026-06-08 incident)'
run 2 "$TMP" 'gh pr create --title x'                'bare gh pr create @ HQ root blocked'
run 2 "$TMP/not-a-repo" 'git commit -m x'            'bare commit, cwd not a repo, blocked'

# --- Explicit anchors still work ------------------------------------------
run 0 "$TMP" "git -C $NESTED commit -m x"            'git -C nested repo allowed'
run 2 "$TMP" "git -C $TMP push origin main"          'git -C HQ root blocked'
run 0 "$TMP" 'gh pr create -R owner/repo --title x'  'gh -R allowed'
run 0 "$TMP" 'git status'                            'read-only git allowed'

# --- Harness-strip cwd fallback (REGRESSION 2026-06-08/09) ----------------
# The harness strips `cd <path> && ` when <path> == session cwd, so an
# anchored mutation arrives bare. With input cwd inside a nested (non-HQ-root)
# repo the mutation cannot land on HQ root and must be ALLOWED.
run 0 "$NESTED" 'git commit -m x'                    'bare commit, cwd = nested repo, allowed (strip fallback)'
run 0 "$NESTED" '( git push origin main )'           'paren bare push, cwd = nested repo, allowed (strip fallback)'
run 0 "$NESTED" 'gh pr create --title x'             'bare gh pr create, cwd = nested repo, allowed (strip fallback)'

# --- cd-anchor form, when it DOES survive the harness ----------------------
# (path != session cwd). The parenthesized form historically failed
# extraction; the regex now accepts `(` before `cd`.
run 0 "$TMP" "( cd $NESTED && git commit -m x )"     'surviving paren cd-anchor to nested repo allowed'
run 0 "$TMP" "cd $NESTED && git commit -m x"         'surviving bare cd-anchor to nested repo allowed'
run 2 "$NESTED" "( cd $TMP && git push origin main )" 'cd-anchor to HQ root blocked even from nested cwd'

# --- gh repo create is self-anchoring (accepts neither -C nor -R) ----------
run 0 "$TMP" 'gh repo create my-org/new-repo --private' 'gh repo create org/name allowed'
run 0 "$TMP" 'gh repo create solo-name --private'    'gh repo create bare name allowed (no local repo touched)'
run 0 "$TMP" "gh repo create my-org/x --source=$NESTED --push" 'gh repo create abs non-HQ --source allowed'
run 2 "$TMP" "gh repo create my-org/x --source=$TMP --push" 'gh repo create --source = HQ root blocked'
run 2 "$TMP" 'gh repo create my-org/x --source=. --push' 'gh repo create relative --source blocked'
run 2 "$TMP" 'gh repo create my-org/x && git push origin main' 'gh repo create + bare git mutation @ HQ root still blocked'
run 2 "$TMP" 'gh repo create my-org/x && gh api orgs/o/repos -X POST' 'gh repo create + other gh mutation @ HQ root still blocked'

# --- DEV-1765: cd-prefix shapes evaluate identically here as under Codex -----
# The Codex side is proven end-to-end in codex-git-mutation-firing.test.sh
# (real adapter + gate + hook). These assert the SAME verdicts on the Claude
# side so the two harnesses agree on the literal `cd <abs> && <git mutation>`
# shape — both the surviving (path != cwd) and harness-stripped (path == cwd)
# forms.
run 2 "$NESTED" "cd $TMP && git push origin main"     'DEV-1765 cd HQ-root && push from nested cwd blocked'
run 0 "$TMP"    "cd $NESTED && git push origin main"  'DEV-1765 cd nested && push allowed'
run 2 "$TMP"    'git push origin main'                'DEV-1765 stripped bare push @ HQ root blocked'
run 0 "$NESTED" 'git push origin main'                'DEV-1765 stripped bare push, cwd=nested, allowed'

# --- Escape hatch unchanged -------------------------------------------------
run 0 "$TMP" 'HQ_ALLOW_HQ_ROOT_GIT=1 git commit -m x' 'inline escape hatch allowed'

echo "block-hq-root-git-mutation: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
