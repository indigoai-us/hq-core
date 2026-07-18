#!/usr/bin/env bash
# hq-core: public
# DEV-1765 — prove the HQ-root git-mutation guard FIRES correctly under the
# Codex harness, end to end through the REAL adapter + gate + hook (no stubs).
#
# Root cause this guards against:
#   hq-codex-hook-adapter.sh used to resolve HQ_ROOT via
#   `git -C "$CWD" rev-parse --show-toplevel`. Every working repo is nested
#   under the HQ root, so when Codex's cwd was inside one (repos/*), HQ_ROOT
#   collapsed to that nested repo, the gate path had no hook-gate.sh, and the
#   adapter exited 0 — silently bypassing the git-mutation guard (and every
#   other Codex PreToolUse hook). A `cd <hq-root> && git push` from a nested
#   cwd reached the remote unblocked under Codex while Claude blocked it.
#
# The fix resolves HQ_ROOT from the adapter's own location and exports
# CLAUDE_PROJECT_DIR so the hook anchors on the true HQ root.
#
# This exercises the LITERAL `cd <abs> && <git mutation>` shape the report
# called out, plus the harness-stripped (bare) shape, THROUGH the adapter.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
ADAPTER_SRC="$ROOT/.codex/hooks/hq-codex-hook-adapter.sh"
GATE_SRC="$ROOT/.claude/hooks/hook-gate.sh"
HOOK_SRC="$ROOT/.claude/hooks/block-hq-root-git-mutation.sh"
HELPER_SRC="$ROOT/core/scripts/hook-lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake HQ root (a git repo) with a nested working repo — mirrors real layout
# where repos/* are their own git repos nested under the HQ root.
git -C "$TMP" init -q
mkdir -p "$TMP/.codex/hooks" "$TMP/.claude/hooks" "$TMP/core/scripts" "$TMP/repos/private/app"
git -C "$TMP/repos/private/app" init -q
cp "$ADAPTER_SRC" "$TMP/.codex/hooks/hq-codex-hook-adapter.sh"
cp "$GATE_SRC"    "$TMP/.claude/hooks/hook-gate.sh"
cp "$HOOK_SRC"    "$TMP/.claude/hooks/block-hq-root-git-mutation.sh"
cp "$HELPER_SRC"  "$TMP/core/scripts/hook-lib.sh"
chmod +x "$TMP/.codex/hooks/hq-codex-hook-adapter.sh" \
         "$TMP/.claude/hooks/hook-gate.sh" \
         "$TMP/.claude/hooks/block-hq-root-git-mutation.sh"

ADAPTER="$TMP/.codex/hooks/hq-codex-hook-adapter.sh"
NESTED="$TMP/repos/private/app"

# Keep this fixture focused on the mutation guard. The real adapter dispatches
# several other Bash hooks first; disable those rather than stubbing them.
export HQ_DISABLED_HOOKS="detect-secrets,block-core-writes-bash,block-on-active-run,inject-policy-on-trigger,block-unsafe-package-install"

PASS=0
FAIL=0

# run <expected_exit> <cwd> <command> <label>
# Drives the REAL Codex adapter with a Codex-shaped PreToolUse payload. The
# adapter must locate the gate from its own path, not from <cwd>, so it keeps
# firing even when <cwd> is a nested repo. We invoke from an unrelated cwd to
# prove cwd independence; the adapter is referenced by its absolute path so
# BASH_SOURCE self-location resolves the HQ root.
run() {
  local expect="$1" cwd="$2" cmd="$3" label="$4" rc=0 payload err
  payload=$(jq -n --arg cwd "$cwd" --arg cmd "$cmd" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", cwd:$cwd, tool_input:{command:$cmd}}')
  # Run from / (an unrelated dir) so any accidental pwd-dependence is exposed.
  err="$(printf '%s' "$payload" | ( cd / && bash "$ADAPTER" ) 2>&1 >/dev/null)" || rc=$?
  if [[ "$rc" -eq "$expect" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [$label]: expected exit $expect, got $rc — cmd: $cmd (cwd: $cwd)" >&2
    [ -n "$err" ] && printf '  adapter stderr: %s\n' "$err" >&2
  fi
}

# --- The literal report shape: `cd <abs> && <git mutation>` through Codex ----
# cd to HQ root then push: MUST block even when the reported cwd is a nested
# repo (the case the old adapter silently allowed).
run 2 "$NESTED" "cd $TMP && git push origin main"       'cd HQ-root && push, cwd=nested repo, BLOCKED (DEV-1765 regression)'
run 2 "$TMP"    "cd $TMP && git push origin main"        'cd HQ-root && push, cwd=HQ root, BLOCKED'
# cd to a nested repo then push: legitimate, MUST be allowed.
run 0 "$TMP"    "cd $NESTED && git commit -m x"          'cd nested && commit, ALLOWED'
run 0 "$NESTED" "cd $NESTED && git commit -m x"          'cd nested && commit, cwd=nested, ALLOWED'

# --- Harness-stripped (bare) shape through Codex -----------------------------
run 2 "$TMP"    'git push origin main'                   'bare push, cwd=HQ root, BLOCKED'
run 0 "$NESTED" 'git push origin main'                   'bare push, cwd=nested repo, ALLOWED (strip fallback)'

# --- Explicit anchors still honored under Codex ------------------------------
run 0 "$NESTED" "git -C $NESTED commit -m x"             'git -C nested, ALLOWED'
run 2 "$NESTED" "git -C $TMP push origin main"           'git -C HQ root, BLOCKED'
run 0 "$NESTED" 'gh pr create -R owner/repo --title x'   'gh -R, ALLOWED'
run 0 "$NESTED" 'git status'                             'read-only git, ALLOWED'

# --- The guard must actually be REACHED (not bypassed) -----------------------
# A bare push from a nested cwd is ALLOWED for the right reason (cwd fallback),
# but a bare push whose cwd is the HQ root must still be BLOCKED — proving the
# adapter routed into the real hook rather than exiting 0 on a missing gate.
run 2 "$TMP"    '( git push origin main )'               'paren bare push @ HQ root, BLOCKED (guard reached)'

echo "codex-git-mutation-firing: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
