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

# Every project-root-derived path must be quoted, and each shipped hook
# entrypoint must be launched through Bash so setup can recover even when an
# archive or update strips executable bits.
#
# A project root whose path contains a space is the field failure this guards.
# An unquoted reference is word-split by /bin/sh, the hook execs a truncated
# path ("<parent>/My" for "<parent>/My HQ"), and the entire hook layer dies
# non-blocking and silent — no policy injection, no safety blockers, no
# automations, and no error the user ever sees. Two layers below: a static
# contract over the shipped command strings, and an execution pass that runs
# EVERY shipped command from a root containing a space. Both are functions so
# the negative controls at the end can prove they reject the broken forms.
hook_commands="$(jq -r '.. | objects | select(.type? == "command") | .command' "$SETTINGS")"

# The static guard is the same quote-aware scanner the runtime doctor
# (core/scripts/check-hq-hooks.sh) uses, sourced rather than re-implemented so
# the two can never drift on what counts as quoted. It splits a command the way
# /bin/sh would, so it catches the braced form ${CLAUDE_PROJECT_DIR}/… and
# embedded forms like --root=$CLAUDE_PROJECT_DIR/… that a "whitespace then
# $VAR" pattern silently lets through, while leaving genuinely quoted tokens
# alone. Both wrappers take one command per line and keep this file's
# convention that "refs found" is a successful exit.
# shellcheck source=core/scripts/lib/hook-command-scan.sh
. "$ROOT/core/scripts/lib/hook-command-scan.sh"

unquoted_project_dir_refs() {
  printf '%s\n' "$1" | hook_scan_encode | hook_scan_unquoted_commands | grep .
}

# Every $CLAUDE_PROJECT_DIR-relative path a command names, quoted or not.
project_dir_relpaths() {
  printf '%s\n' "$1" | hook_scan_encode | hook_scan_relpaths
}

if unquoted_project_dir_refs "$hook_commands"; then
  fail "settings.json has an unquoted \$CLAUDE_PROJECT_DIR-derived path (dies on a root containing a space)"
fi
if printf '%s\n' "$hook_commands" \
    | grep -vE '^bash "\$CLAUDE_PROJECT_DIR/\.claude/hooks/(hook-gate|master-hook|reindex)\.sh"([[:space:]]|$)'; then
  fail "settings.json has a hook entrypoint that is not invoked through bash"
fi
pass "all project-root paths are quoted and hook entrypoints use bash"

# A real shipped command string must drive its delegate to completion from a
# spaced root even when both files have lost their executable bit.
REP_PARENT="$(mktemp -d)"; REP_ROOT="$REP_PARENT/HQ With Spaces"
mkdir -p "$REP_ROOT/.claude/hooks"; trap 'rm -rf "$REP_PARENT"' EXIT
cat >"$REP_ROOT/.claude/hooks/hook-gate.sh" <<'EOF'
#!/usr/bin/env bash
[ "$#" -eq 2 ] || exit 10
[ "$1" = "session-title" ] || exit 11
[ "$2" = "$CLAUDE_PROJECT_DIR/.claude/hooks/session-title.sh" ] || exit 12
bash "$2"
EOF
cat >"$REP_ROOT/.claude/hooks/session-title.sh" <<'EOF'
#!/usr/bin/env bash
touch "$CLAUDE_PROJECT_DIR/.representative-hook-ran"
EOF
chmod 0644 "$REP_ROOT/.claude/hooks/hook-gate.sh" "$REP_ROOT/.claude/hooks/session-title.sh"
representative_command="$(jq -r '[.. | objects | select(.type? == "command") | .command | select(contains(" session-title "))][0] // empty' "$SETTINGS")"
[ -n "$representative_command" ] || fail "session-title command missing from settings.json"
rc=0
CLAUDE_PROJECT_DIR="$REP_ROOT" /bin/sh -c "$representative_command" || rc=$?
[ "$rc" -eq 0 ] || fail "representative command failed from a project root containing spaces (rc=$rc)"
[ -f "$REP_ROOT/.representative-hook-ran" ] || fail "representative command did not run its child hook"
pass "representative command works with spaces and non-executable hook files"
rm -rf "$REP_PARENT"; trap - EXIT

# Execute the shipped command strings against non-executable recording stubs in
# an install root whose path contains a space. This covers shell word splitting
# and the entrypoint executable-bit fallback for EVERY command, not a sample.
SPACE_PARENT="$(mktemp -d)"; SPACE_ROOT="$SPACE_PARENT/HQ With Spaces"
STUB_LOG="$SPACE_PARENT/stub.log"
trap 'rm -rf "$SPACE_PARENT"' EXIT
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  mkdir -p "$SPACE_ROOT/$(dirname "$rel")"
  cat >"$SPACE_ROOT/$rel" <<'STUB'
#!/usr/bin/env bash
# Recording stub: logs how it was invoked and flags any path-shaped argument
# that does not resolve — the signature of a word-split project root.
log="${HQ_STUB_LOG:?stub log path missing}"
printf 'self=%s\n' "$0" >>"$log"
for a in "$@"; do
  printf 'arg=%s\n' "$a" >>"$log"
  case "$a" in
    */*) [ -e "$a" ] || printf 'SPLIT_PATH=%s\n' "$a" >>"$log" ;;
  esac
done
STUB
  chmod 0644 "$SPACE_ROOT/$rel"
done < <(project_dir_relpaths "$hook_commands" | sort -u)

# Run one command string from the spaced root; non-zero means it would break.
run_command_in_spaced_root() {
  local cmd="$1" rc=0 rel
  : >"$STUB_LOG"
  CLAUDE_PROJECT_DIR="$SPACE_ROOT" HQ_STUB_LOG="$STUB_LOG" \
    /bin/sh -c "$cmd" </dev/null >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  command exited $rc" >&2
    return 1
  fi
  if grep -q '^SPLIT_PATH=' "$STUB_LOG"; then
    grep '^SPLIT_PATH=' "$STUB_LOG" >&2
    return 1
  fi
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    grep -qxF "self=$SPACE_ROOT/$rel" "$STUB_LOG" \
      || grep -qxF "arg=$SPACE_ROOT/$rel" "$STUB_LOG" \
      || { echo "  path did not arrive intact: $SPACE_ROOT/$rel" >&2; return 1; }
  done < <(project_dir_relpaths "$cmd")
  return 0
}

executed=0
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  run_command_in_spaced_root "$cmd" \
    || fail "shipped hook command breaks from a project root containing a space: $cmd"
  executed=$((executed + 1))
done <<<"$hook_commands"
[ "$executed" -ge 20 ] \
  || fail "expected the full shipped hook command set, executed only $executed"
pass "all $executed shipped hook commands run intact from a root containing a space"

# Negative controls: both guards must actually reject the broken forms. The
# braced and embedded variants split identically in the field but slipped past
# the earlier pattern-only check, so each is proven rejected here.
while IFS= read -r broken; do
  [ -n "$broken" ] || continue
  unquoted_project_dir_refs "$broken" >/dev/null \
    || fail "static guard missed an unquoted form: $broken"
  if run_command_in_spaced_root "$broken" 2>/dev/null; then
    fail "execution guard missed an unquoted form: $broken"
  fi
done <<'BROKEN'
bash "$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh" session-title $CLAUDE_PROJECT_DIR/.claude/hooks/session-title.sh
bash "$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh" session-title ${CLAUDE_PROJECT_DIR}/.claude/hooks/session-title.sh
bash $CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh session-title "$CLAUDE_PROJECT_DIR/.claude/hooks/session-title.sh"
bash "$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh" session-title "$CLAUDE_PROJECT_DIR/.claude/hooks/session-title.sh" --root=$CLAUDE_PROJECT_DIR/core/scripts
BROKEN
pass "guards reject bare, braced, unquoted-entrypoint, and embedded forms"

# Positive controls: a quoted token that merely *contains* the variable is
# split-safe, and calling it broken would be a false alarm that sends someone
# repairing a healthy config. Proven both ways — the static guard stays quiet
# and the command runs clean from the spaced root.
while IFS= read -r safe; do
  [ -n "$safe" ] || continue
  if unquoted_project_dir_refs "$safe" >/dev/null; then
    fail "static guard called a split-safe form unquoted: $safe"
  fi
done <<'SAFE'
bash "$CLAUDE_PROJECT_DIR/.claude/hooks/hook-gate.sh" session-title "$CLAUDE_PROJECT_DIR/.claude/hooks/session-title.sh" "--root=$CLAUDE_PROJECT_DIR"
bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/hook-gate.sh" session-title "${CLAUDE_PROJECT_DIR}/.claude/hooks/session-title.sh"
SAFE
run_command_in_spaced_root 'bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/hook-gate.sh" session-title "${CLAUDE_PROJECT_DIR}/.claude/hooks/session-title.sh"' \
  || fail "execution guard rejected a split-safe braced form"
pass "guards accept quoted plain, braced, and embedded-in-a-quoted-token forms"

# The existence sweep above is only as complete as this extraction: a path the
# helper skips is a path no assertion ever covers. One token can name two, and a
# quoted segment can contain a space.
relpaths_out="$(project_dir_relpaths 'bash "$CLAUDE_PROJECT_DIR/a dir/one.sh" "--pair=$CLAUDE_PROJECT_DIR/b/two.sh:$CLAUDE_PROJECT_DIR/c/three.sh"')"
for expected in 'a dir/one.sh' 'b/two.sh' 'c/three.sh'; do
  printf '%s\n' "$relpaths_out" | grep -qxF "$expected" \
    || fail "path extraction dropped $expected: $relpaths_out"
done
pass "every \$CLAUDE_PROJECT_DIR path in a token is extracted, spaces intact"
rm -rf "$SPACE_PARENT"; trap - EXIT

# setup.sh must restore executable bits in both release-shipped script trees.
SETUP="$ROOT/core/scripts/setup.sh"
for script_dir in '.claude/hooks' 'core/scripts'; do
  grep -Fq "find \"\$REPO_ROOT/$script_dir\" -name '*.sh' -exec chmod +x {} \\;" "$SETUP" \
    || fail "setup.sh does not repair executable bits under $script_dir"
done
if grep -nF 'find "$REPO_ROOT/scripts"' "$SETUP"; then
  fail "setup.sh still repairs the stale top-level scripts directory"
fi
pass "setup.sh repairs both release-shipped script trees"

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
printf '%s' "$out" | grep -qF "AUTO-CHECKPOINT SUGGESTED" || fail "no checkpoint nudge emitted"
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

echo "[8] hq-auto-acl-suggest.sh: resolves root via project env, cwd walk-up, then self-path"
for mode in env walkup selfpath; do
  FR="$(make_fake_root)"; trap 'rm -rf "$FR"' EXIT
  mkdir -p "$FR/.claude/hooks" "$FR/core/scripts" "$FR/workspace/sessions/s-acl-$mode" "$FR/companies/acme/data/reports"
  cp "$HOOKS/hq-auto-acl-suggest.sh" "$FR/.claude/hooks/hq-auto-acl-suggest.sh"
  cp "$ROOT/core/scripts/share-suggestion-state.sh" "$FR/core/scripts/share-suggestion-state.sh"
  chmod +x "$FR/.claude/hooks/hq-auto-acl-suggest.sh" "$FR/core/scripts/share-suggestion-state.sh"
  cat > "$FR/workspace/sessions/s-acl-$mode/meta.yaml" <<'YAML'
company_slug: acme
YAML
  payload="$(printf '{"hook_event_name":"PostToolUse","session_id":"s-acl-%s","cwd":"%s/deep/nested/cwd","tool_name":"Write","tool_input":{"file_path":"%s/companies/acme/data/reports/demo.md"},"tool_response":{"stdout":""}}' "$mode" "$FR" "$FR")"
  case "$mode" in
    env)
      ( cd "$FR/deep/nested/cwd" && CLAUDE_PROJECT_DIR="$FR" env -u HQ_ROOT \
          bash "$FR/.claude/hooks/hq-auto-acl-suggest.sh" <<<"$payload" >/dev/null )
      ;;
    walkup)
      ( cd "$FR/deep/nested/cwd" && env -u CLAUDE_PROJECT_DIR -u HQ_ROOT \
          bash "$FR/.claude/hooks/hq-auto-acl-suggest.sh" <<<"$payload" >/dev/null )
      ;;
    selfpath)
      ( cd /tmp && env -u CLAUDE_PROJECT_DIR -u HQ_ROOT \
          bash "$FR/.claude/hooks/hq-auto-acl-suggest.sh" <<<"$payload" >/dev/null )
      ;;
  esac
  [ -f "$FR/workspace/orchestrator/share-suggestions/s-acl-$mode.json" ] \
    || fail "hq-auto-acl-suggest did not queue under the resolved root in $mode mode"
  pass "hq-auto-acl-suggest queued under the fake root in $mode mode"
  rm -rf "$FR"; trap - EXIT
done

echo "hook path resolution: ok"
