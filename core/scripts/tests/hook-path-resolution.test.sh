#!/usr/bin/env bash
# Regression tests for hook HQ-root path resolution.
#
# Guards against the class of bug where shipped hooks either (a) are invoked by
# a relative path in .claude/settings.json (breaks when the session cwd is a
# subdirectory: "/bin/sh: .claude/hooks/<x>.sh: No such file or directory"), or
# (b) hardcode ${HOME}/Documents/HQ as the HQ root (operates on the wrong tree
# on a non-default install, and auto-checkpoint-trigger.sh exits 128 because
# `cd`/`git` run against a non-repo).
#
# Every hook must resolve the *active* HQ root regardless of install location
# or session cwd, via: CLAUDE_PROJECT_DIR -> HQ_ROOT -> its own on-disk
# location (<HQ>/.claude/hooks/) -> legacy default.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOKS="$ROOT/.claude/hooks"
SETTINGS="$ROOT/.claude/settings.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

# Build an isolated, non-default fake HQ root that is a real git repo, plus a
# nested subdirectory to run hooks from.
make_fake_root() {
  local d
  d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" -c user.email=fixture@example.test -c user.name=hooks-test commit -q --allow-empty -m init
  mkdir -p "$d/workspace" "$d/scripts" "$d/deep/nested/cwd"
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
echo "[1] .claude/settings.json invokes every hook by an absolute path"
# No command may invoke a hook via a bare relative ".claude/..." path.
if grep -nE '"command":[[:space:]]*"\.claude/' "$SETTINGS"; then
  fail "settings.json has relative .claude/ hook invocations (break in subdir cwd)"
fi
pass "no relative .claude/ invocations remain"
# master-hook.sh + reindex.sh specifically must be CLAUDE_PROJECT_DIR-anchored.
for needle in 'master-hook.sh' 'reindex.sh'; do
  while IFS= read -r line; do
    case "$line" in
      *'$CLAUDE_PROJECT_DIR/.claude/hooks/'*) : ;;
      *) fail "$needle invoked without \$CLAUDE_PROJECT_DIR anchor: $line" ;;
    esac
  done < <(grep -E "\"command\":.*${needle}" "$SETTINGS")
done
pass "master-hook.sh and reindex.sh anchored to \$CLAUDE_PROJECT_DIR"

# ---------------------------------------------------------------------------
echo "[2] auto-checkpoint-trigger.sh: resolves CLAUDE_PROJECT_DIR from a subdir (was exit 128)"
FR="$(make_fake_root)"; trap 'rm -rf "$FR"' EXIT
# The emitted nudge embeds the resolved root's HEAD short SHA — a value unique
# to this fake root, so it deterministically proves which tree the hook used.
EXPECT_SHA="$(git -C "$FR" rev-parse --short HEAD)"
payload='{"tool_name":"Bash","session_id":"s-acp","tool_input":{"command":"git commit -m demo"}}'
rc=0
out="$( cd "$FR/deep/nested/cwd" && CLAUDE_PROJECT_DIR="$FR" HQ_ROOT= \
        bash "$HOOKS/auto-checkpoint-trigger.sh" PostToolUse <<<"$payload" )" || rc=$?
[ "$rc" -eq 0 ] || fail "auto-checkpoint-trigger exited $rc (expected 0) on a non-default root"
printf '%s' "$out" | grep -qF "AUTO-CHECKPOINT REQUIRED" || fail "no checkpoint nudge emitted"
printf '%s' "$out" | grep -qF "current_commit: \"$EXPECT_SHA\"" \
  || fail "nudge did not reflect the fake root's HEAD ($EXPECT_SHA) — wrong root resolved"
pass "exit 0 + nudge reflects the fake root's HEAD ($EXPECT_SHA)"
rm -rf "$FR"; trap - EXIT

# ---------------------------------------------------------------------------
echo "[3] observe-patterns.sh: creates learnings under the resolved root, not \$HOME/Documents/HQ"
FR="$(make_fake_root)"; trap 'rm -rf "$FR"' EXIT
rc=0
( cd "$FR/deep/nested/cwd" && CLAUDE_PROJECT_DIR="$FR" HQ_ROOT= \
    bash "$HOOKS/observe-patterns.sh" Stop <<<'{"session_id":"s-obs"}' >/dev/null ) || rc=$?
[ "$rc" -eq 0 ] || fail "observe-patterns exited $rc (expected 0)"
[ -d "$FR/workspace/learnings" ] || fail "learnings dir not created under resolved root"
pass "learnings dir created under the fake root"
rm -rf "$FR"; trap - EXIT

# ---------------------------------------------------------------------------
echo "[4] precompact-thrashing-detector.sh: writes compaction history under the resolved root"
FR="$(make_fake_root)"; trap 'rm -rf "$FR"' EXIT
( cd "$FR/deep/nested/cwd" && CLAUDE_PROJECT_DIR="$FR" HQ_ROOT= \
    bash "$HOOKS/precompact-thrashing-detector.sh" PreCompact \
    <<<'{"session_id":"s-pc","transcript_path":"/dev/null"}' >/dev/null )
[ -f "$FR/workspace/.compact-history/s-pc.jsonl" ] \
  || fail "compaction history not written under the resolved root"
pass "compaction history written under the fake root"
rm -rf "$FR"; trap - EXIT

# ---------------------------------------------------------------------------
echo "[5] screenshot-resize-trigger.sh: invokes resize-screenshot.sh under the resolved root"
FR="$(make_fake_root)"; trap 'rm -rf "$FR"' EXIT
cat >"$FR/scripts/resize-screenshot.sh" <<EOF
#!/bin/bash
touch "$FR/.resize-invoked"
EOF
chmod +x "$FR/scripts/resize-screenshot.sh"
touch "$FR/shot.png"
payload="$(printf '{"tool_name":"Bash","tool_input":{"command":"agent-browser screenshot %s/shot.png"}}' "$FR")"
( cd "$FR/deep/nested/cwd" && CLAUDE_PROJECT_DIR="$FR" HQ_ROOT= \
    bash "$HOOKS/screenshot-resize-trigger.sh" PostToolUse <<<"$payload" >/dev/null )
[ -f "$FR/.resize-invoked" ] || fail "resize-screenshot.sh under the resolved root was not invoked"
pass "resize helper invoked from the fake root"
rm -rf "$FR"; trap - EXIT

# ---------------------------------------------------------------------------
echo "[6] block-on-active-run.sh + check-repo-active-runs.sh: consult the registry under the resolved root"
for hook_event in "block-on-active-run.sh:PreToolUse" "check-repo-active-runs.sh:SessionStart"; do
  hook="${hook_event%%:*}"; event="${hook_event##*:}"
  FR="$(make_fake_root)"; trap 'rm -rf "$FR"' EXIT
  cat >"$FR/scripts/repo-run-registry.sh" <<EOF
#!/bin/bash
touch "$FR/.registry-consulted"
echo "[]"
EOF
  chmod +x "$FR/scripts/repo-run-registry.sh"
  if [ "$hook" = "block-on-active-run.sh" ]; then
    payload="$(printf '{"tool_name":"Edit","session_id":"s-bar","tool_input":{"file_path":"%s/deep/nested/cwd/x.txt"}}' "$FR")"
  else
    payload='{"session_id":"s-cra"}'
  fi
  rc=0
  ( cd "$FR/deep/nested/cwd" && CLAUDE_PROJECT_DIR="$FR" HQ_ROOT= \
      bash "$HOOKS/$hook" "$event" <<<"$payload" >/dev/null 2>&1 ) || rc=$?
  [ -f "$FR/.registry-consulted" ] \
    || fail "$hook did not consult the registry under the resolved root (rc=$rc)"
  pass "$hook consulted the registry under the fake root"
  rm -rf "$FR"; trap - EXIT
done

# ---------------------------------------------------------------------------
echo "[7] install-location independence: a hook in a fresh non-default install resolves its OWN root with NO env vars"
# Copy a hook into a brand-new install tree and run it by absolute path with
# CLAUDE_PROJECT_DIR *and* HQ_ROOT unset, from a deep subdir. The hook must fall
# back to its own on-disk location ($0 / BASH_SOURCE), not $HOME/Documents/HQ.
FI="$(mktemp -d)/My Custom HQ Install"; mkdir -p "$FI/.claude/hooks" "$FI/workspace" "$FI/deep/cwd"; trap 'rm -rf "$(dirname "$FI")"' EXIT
cp "$HOOKS/observe-patterns.sh" "$FI/.claude/hooks/observe-patterns.sh"
git -C "$FI" init -q
git -C "$FI" -c user.email=fixture@example.test -c user.name=hooks-test commit -q --allow-empty -m init
rc=0
( cd "$FI/deep/cwd" && env -u CLAUDE_PROJECT_DIR -u HQ_ROOT \
    bash "$FI/.claude/hooks/observe-patterns.sh" Stop <<<'{"session_id":"s-fi"}' >/dev/null ) || rc=$?
[ "$rc" -eq 0 ] || fail "self-locating hook exited $rc (expected 0)"
[ -d "$FI/workspace/learnings" ] || fail "hook did not resolve its own install root via \$0 fallback"
pass "hook resolved its own install root with no env vars (cwd in a subdir, path with a space)"
rm -rf "$(dirname "$FI")"; trap - EXIT

echo "hook path resolution: ok"
