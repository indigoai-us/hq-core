#!/usr/bin/env bash
# hq-core: public
# Regression tests for the always-writable path mask (feedback_fff53135).
#
# block-core-writes-bash.sh removes every word that names an always-writable
# path (.claude/settings.local.json, .claude/personal-context.md and core.yaml
# rules.exclude paths) before it parses the command, through two hook-lib
# helpers: hq_bash_strip_core_yaml_exclude_tokens and
# hq_strip_tokens_containing_literals. Removing the destination of
# `cp .claude/settings.backup.json .claude/settings.local.json` moved the
# source into the destination slot, so the copy was refused.
#
# The guard is frozen (merged-write-guard-shadow.test.sh), so the helpers now
# mask a word whose whole path is always writable in place when every command
# is a plain cp/mv/rsync/mkdir/touch/tee or a text command. Any other shape
# (ln, cp -s/-l/-a/-r, rsync -a, sudo, ...) keeps the old removal, so a link
# planted at an always-writable path that points into a protected directory
# stays blocked. A word that merely contains such a path, or has a `..`
# segment, is never masked.
#
# This suite is not replayed by block-guard-hooks-parity.test.sh: that harness
# pins main's hook-lib.sh, which has no mask.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/block-core-writes-bash.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude/hooks" "$TMP/.claude/scheduled-tasks" "$TMP/.claude/kit" "$TMP/core/scripts"
printf '{}' > "$TMP/.claude/settings.local.json"

PASS=0
FAIL=0

# run <expected_exit> <command> <label>
run() {
  local expect="$1" cmd="$2" label="$3" rc=0 payload
  payload=$(jq -n --arg cmd "$cmd" '{tool_input: {command: $cmd}}')
  printf '%s' "$payload" | (cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK") >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$expect" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [$label]: expected exit $expect, got $rc -- cmd: $cmd" >&2
  fi
}

# --- feedback_fff53135: the fixed exceptions stay writable ------------------
run 0 "cp .claude/settings.backup.json .claude/settings.local.json" \
  'cp of a .claude backup onto settings.local.json allowed'
run 0 "cp -f \".claude/settings.backup.json\" \".claude/settings.local.json\"" \
  'quoted cp -f onto settings.local.json allowed'
run 0 "rsync .claude/bak/local.json .claude/settings.local.json" \
  'rsync of a .claude backup onto settings.local.json allowed'
run 0 "cp .claude/backup.md .claude/personal-context.md" \
  'cp of a .claude backup onto personal-context.md allowed'
run 0 "cp ./.claude/settings.backup.json ./.claude//settings.local.json" \
  'cp onto settings.local.json with ./ and a doubled slash allowed'
run 0 "mv .claude/settings.local.json.new .claude/settings.local.json" \
  'atomic rewrite through a sibling temp file allowed'
run 0 "cp .claude/settings.local.json .claude/settings.local.json.bak" \
  'backup copy next to settings.local.json allowed'
run 0 "cd .claude && cp settings.backup.json settings.local.json" \
  'cd into .claude then cp onto settings.local.json allowed'
run 0 "echo x >.claude/settings.local.json; echo done" \
  'redirect with no space onto settings.local.json allowed'
run 0 "f=$TMP/.claude/personal-context.md; cat > \"\$f\"" \
  'assignment of personal-context.md then redirect allowed'

# --- other targets in the same command are still checked --------------------
run 2 "cp .claude/settings.local.json .claude/hooks/x.sh" \
  'cp from settings.local.json into .claude/hooks blocked'
run 2 "mv .claude/hooks/x.sh .claude/settings.local.json" \
  'mv of a hook onto settings.local.json blocked (mv removes the source)'
run 2 "cp /tmp/a .claude/settings.local.json .claude/hooks/" \
  'cp with settings.local.json as one of several sources into .claude/hooks blocked'
run 2 "tee .claude/settings.json < .claude/settings.local.json" \
  'tee into settings.json reading settings.local.json blocked'
run 2 "echo \"see .claude/settings.local.json\" > .claude/hooks/x.sh" \
  'quoted mention of settings.local.json does not hide a later redirect'
run 2 "echo \\\"settings.local.json > .claude/hooks/x.sh" \
  'escaped double quote before settings.local.json does not hide a redirect'
run 2 "mv .claude/settings.local.json .claude/hooks/settings.local.json.bak" \
  'a backup name inside .claude/hooks is a protected write'
run 2 "cd .claude/hooks && cp x settings.local.json" \
  'a bare settings.local.json after cd into .claude/hooks is a protected write'

# --- a containing word is not an always-writable path ------------------------
run 2 "mkdir -p .claude/hooks/settings.local.json" \
  'a directory named settings.local.json inside .claude/hooks is a protected write'
run 2 "cp evil.sh .claude/hooks/settings.local.json/../block-core-writes-bash.sh" \
  'a .. segment after settings.local.json does not mask a write into .claude/hooks'
run 2 "mkdir -p .claude/hooks/settings.local.json && cp evil.sh .claude/hooks/settings.local.json/../block-core-writes-bash.sh" \
  'mkdir then climb out of a fake settings.local.json directory is blocked'
run 2 "cp evil.sh .claude/settings.local.json/../hooks/x.sh" \
  'a .. segment after the real settings.local.json path is blocked'
run 2 "cp evil.sh .claude/settings.local.json.x/../hooks/x.sh" \
  'a .. segment after a sibling name is blocked'
run 2 "cp evil.sh core/.claude/settings.local.json" \
  'settings.local.json under core/ is a protected write'
run 2 "echo x > .claude/hooks/personal-context.md" \
  'personal-context.md inside .claude/hooks is a protected write'
run 2 "cp evil.sh .claude/settings.local.json.d/x.sh" \
  'a sibling directory of settings.local.json is not a sibling file'

# --- links planted at an always-writable path keep the old decision ----------
run 2 "ln -sf $TMP/.claude/hooks/block-core-writes-bash.sh .claude/settings.local.json && cp evil.sh .claude/settings.local.json" \
  'symlink settings.local.json to a hook, then write through it, blocked'
run 2 "cp -s $TMP/.claude/hooks/block-core-writes-bash.sh .claude/settings.local.json" \
  'cp -s of a hook onto settings.local.json blocked'
run 2 "sudo ln -s $TMP/.claude/hooks .claude/settings.local.json" \
  'a wrapped ln onto settings.local.json blocked'

# --- core.yaml exclude paths (need yq) ---------------------------------------
if command -v yq >/dev/null 2>&1; then
  cp "$ROOT/core/core.yaml" "$TMP/core/core.yaml"
  run 0 "cp .claude/launch.json.bak .claude/launch.json" \
    'cp onto an excluded file allowed'
  run 0 "cp .claude/hooks/x.json .claude/kit/x.json" \
    'cp from .claude into an excluded directory allowed'
  run 0 "echo x > .claude/scheduled-tasks/job.json" \
    'a file inside an excluded directory stays writable'
  run 0 "echo x > $TMP/.claude/launch.json" \
    'an excluded file stays writable'
  run 0 "cd .claude/kit && cp a b" \
    'cd into an excluded directory then cp allowed'
  run 2 "cd .claude/kit && cp evil.sh /x && cp evil core/x" \
    'a masked cd target does not turn off checks of later relative writes'
  run 2 "cp .claude/launch.json .claude/hooks/x.sh" \
    'cp from an excluded file into .claude/hooks blocked'
  run 2 "cp evil.sh .claude/kit/../hooks/block-core-writes-bash.sh" \
    'a .. segment after an excluded directory does not mask a write into .claude/hooks'
  run 2 "cp evil.sh $TMP/.claude/kit/../hooks/block-core-writes-bash.sh" \
    'absolute form of the kit climb is blocked'
  run 2 "cp evil.sh .claude/scheduled-tasks/../hooks/x.sh" \
    'a .. segment after scheduled-tasks does not mask a write into .claude/hooks'
  run 2 "cp evil.sh .claude/kit/../../core/scripts/hook-lib.sh" \
    'a .. climb from kit into core/scripts is blocked'
  run 2 "touch .claude/kit.sh" \
    'a sibling of an excluded directory gets no allowance'
  # Review of fff53135 head 3fb8f31d, critical 2: a link planted at an
  # always-writable path must not open a later write into .claude/hooks.
  run 2 "ln -s $TMP/.claude/hooks .claude/kit/h && cp evil.sh .claude/kit/h/block-core-writes-bash.sh" \
    'symlink from kit into .claude/hooks, then write through it, blocked'
  run 2 "cp -rs $TMP/.claude/hooks .claude/kit/h" \
    'cp -rs of .claude/hooks into kit blocked'
  run 2 "ln $TMP/.claude/hooks/block-core-writes-bash.sh .claude/kit/g && cp evil.sh .claude/kit/g" \
    'hard link of a hook into kit, then write through it, blocked'
  run 2 "cp -l $TMP/.claude/hooks/block-core-writes-bash.sh .claude/kit/g" \
    'cp -l of a hook into kit blocked'
  run 2 "cp --symbolic-link $TMP/.claude/hooks .claude/kit/h" \
    'cp --symbolic-link of .claude/hooks into kit blocked'
  run 2 "cp -a .claude/hooks .claude/kit/h" \
    'cp -a (copies links as links) of .claude/hooks into kit blocked'
  run 2 "rsync -a $TMP/.claude/hooks/ .claude/kit/h/" \
    'rsync -a of .claude/hooks into kit blocked'
  run 2 "env ln -s $TMP/.claude/hooks .claude/kit/h" \
    'env-wrapped ln into kit blocked'
else
  echo "SKIP: core.yaml exclude cases (yq not available)"
fi

# --- helper output: mask for a plain shape, removal for any other -----------
# shellcheck source=../hook-lib.sh
. "$ROOT/core/scripts/hook-lib.sh"
masked="$(CLAUDE_PROJECT_DIR="$TMP" hq_strip_tokens_containing_literals \
  'cp .claude/settings.backup.json .claude/settings.local.json' settings.local.json personal-context.md)"
if [ "$masked" = 'cp .claude/settings.backup.json /dev/null' ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "FAIL [plain cp is masked in place]: got [$masked]" >&2
fi
removed="$(CLAUDE_PROJECT_DIR="$TMP" hq_strip_tokens_containing_literals \
  'ln -s ../hooks .claude/settings.local.json' settings.local.json personal-context.md)"
if [ "$removed" = 'ln -s ../hooks ' ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "FAIL [ln keeps the old removal]: got [$removed]" >&2
fi
kept="$(CLAUDE_PROJECT_DIR="$TMP" hq_strip_tokens_containing_literals \
  'cp evil.sh .claude/hooks/settings.local.json/../x.sh' settings.local.json personal-context.md)"
if [ "$kept" = 'cp evil.sh .claude/hooks/settings.local.json/../x.sh' ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "FAIL [a containing word is kept]: got [$kept]" >&2
fi

echo "block-core-writes-bash-writable-mask: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
