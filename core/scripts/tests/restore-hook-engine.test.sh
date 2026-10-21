#!/usr/bin/env bash
# US-015: exercise the actual update healer in both JSON backends, isolated HOME.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
export HOME="$TASK_TMP/home" USERPROFILE="$TASK_TMP/home"
mkdir -p "$HOME" "$TASK_TMP/bin"
export HQ_TEST_PIN="$HOME/.hq/bin/hq-hook/1.2.3/hq-hook.exe"
mkdir -p "$(dirname "$HQ_TEST_PIN")"
touch "$HQ_TEST_PIN"
export HQ_TEST_PIN_NATIVE="$HQ_TEST_PIN"
if command -v cygpath >/dev/null 2>&1; then HQ_TEST_PIN_NATIVE="$(cygpath -w "$HQ_TEST_PIN")"; fi
export HQ_TEST_FLAG="$TASK_TMP/flag" HQ_TEST_CWD="$TASK_TMP/probe-cwd" HQ_TEST_GRANDCHILD="$TASK_TMP/grandchild.pid"
# A real file with the pinned layout but under another home: accepted, with a
# warning (the CLI printed its own pin; the adapters accept it the same way).
export HQ_TEST_OTHER_HOME_PIN="$TASK_TMP/elsewhere/.hq/bin/hq-hook/1.2.3/hq-hook.exe"
mkdir -p "$(dirname "$HQ_TEST_OTHER_HOME_PIN")"
touch "$HQ_TEST_OTHER_HOME_PIN"
# A real file outside the pinned layout: never accepted.
export HQ_TEST_FOREIGN="$TASK_TMP/elsewhere/bin/hq-hook.exe"
mkdir -p "$(dirname "$HQ_TEST_FOREIGN")"
touch "$HQ_TEST_FOREIGN"
cat > "$TASK_TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
set -eu
[ "$*" = 'core hook-engine-path --for-registration' ] || exit 3
pwd -P > "$HQ_TEST_CWD"
flag="$(cat "$HQ_TEST_FLAG" 2>/dev/null || true)"
[ "$flag" = hang ] && exec sleep 30
if [ "$flag" = grandchild ]; then
  sleep 30 &
  echo "$!" > "$HQ_TEST_GRANDCHILD"
  wait
fi
[ "$flag" = sh ] && { echo /bin/sh; exit 0; }
[ "$flag" = foreign ] && { printf '%s\n' "$HQ_TEST_FOREIGN"; exit 0; }
[ "$flag" = other-home ] && { printf '%s\n' "$HQ_TEST_OTHER_HOME_PIN"; exit 0; }
[ "$flag" = on ] || exit 1
printf '%s\n' "$HQ_TEST_PIN_NATIVE"
STUB
chmod +x "$TASK_TMP/bin/hq"
export PATH="$TASK_TMP/bin:$PATH"

# The --hq-root token hq-cli matches on (hq-cli PR 1992): reindex resolves
# fs.realpathSync(path.resolve(root)) (src/commands/reindex.ts resolveHqRoot)
# and isNativeEntry compares args against launcherRoot() of that
# (src/lib/hook-engine/registration.ts). Both lines are copied verbatim. Node
# receives the spelling the same way hq does, so Git Bash converts /c/... forms.
cli_root() {
  node -e '
    const fs = require("fs"), path = require("path");
    function launcherRoot(root) {
      const trimmed = root.replace(/[\\/]+$/, "");
      return trimmed === "" || /^[A-Za-z]:$/.test(trimmed) ? root : trimmed;
    }
    process.stdout.write(launcherRoot(fs.realpathSync(path.resolve(process.argv[1]))));
  ' "$1"
}

# Every engine entry in the fixture must carry exactly this --hq-root token.
assert_root() {
  local want="$1" label="$2"
  jq -e --arg root "$want" '[.hooks[][] .hooks[] | select(has("args")) | .args[2]] | length == 10 and all(. == $root)' "$fixture/.claude/settings.json" >/dev/null \
    || { echo "FAIL: $label: want '$want', got $(jq -c '.hooks.PreToolUse[0].hooks[0].args' "$fixture/.claude/settings.json")"; exit 1; }
}

for backend in jq node; do
  fixture="$TASK_TMP/$backend root"
  mkdir -p "$fixture/.claude"
  printf '%s\n' '{"env":{"KEEP":"yes"},"hooks":{}}' > "$fixture/.claude/settings.json"
  # Missing flag must retain the bash registrations.
  HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$fixture"
  jq -e '.hooks.PreToolUse[0].hooks[0] | (.command | contains("master-hook.sh")) and (has("args") | not)' "$fixture/.claude/settings.json" >/dev/null
  echo on > "$HQ_TEST_FLAG"
  HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$fixture"
  expected_root="$(cli_root "$fixture")"
  jq -e --arg engine "$HQ_TEST_PIN_NATIVE" --arg root "$expected_root" '
    .env.KEEP == "yes" and
    (.hooks.PreToolUse[0].hooks[0] | .command == $engine and .args == ["PreToolUse","--hq-root",$root,"--runtime","claude"]) and
    (.hooks.Stop[0].hooks[0].asyncRewake == true) and
    ([.hooks[][] .hooks[] | select(has("args"))] | length == 10)
  ' "$fixture/.claude/settings.json" >/dev/null
  before="$(cat "$fixture/.claude/settings.json")"
  HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$fixture"
  [ "$before" = "$(cat "$fixture/.claude/settings.json")" ]
  echo off > "$HQ_TEST_FLAG"
  HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$fixture"
  jq -e '[.hooks[][] .hooks[] | select(has("args"))] | length == 0' "$fixture/.claude/settings.json" >/dev/null
  jq -e '.hooks.PreToolUse[0].hooks[0].command | contains("master-hook.sh")' "$fixture/.claude/settings.json" >/dev/null
  echo on > "$HQ_TEST_FLAG"
  # An enabled flag with no installed engine still uses bash.
  mv "$HQ_TEST_PIN" "$HQ_TEST_PIN.missing"
  HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$fixture"
  jq -e '.hooks.PreToolUse[0].hooks[0].command | contains("master-hook.sh")' "$fixture/.claude/settings.json" >/dev/null
  mv "$HQ_TEST_PIN.missing" "$HQ_TEST_PIN"
  # Root spellings other than the realpath (trailing slashes, relative, through
  # a symlink) must still produce the token hq reindex matches, or a later
  # flag-off reindex would leave the engine entries in place. Each is checked
  # against hq-cli's spelling of the same input from the same directory. Off
  # Windows they must also all collapse to the plain root's token; on Windows
  # Git Bash maps /tmp to an 8.3 TEMP path while the process cwd is the long
  # form, and hq-cli's realpathSync keeps whichever form it is given.
  link="$TASK_TMP/$backend link"
  ln -s "$fixture" "$link" 2>/dev/null && [ -L "$link" ] || link=""
  for spelling in "$fixture/" "$fixture//" relative ${link:+"$link"}; do
    printf '%s\n' '{"hooks":{}}' > "$fixture/.claude/settings.json"
    if [ "$spelling" = relative ]; then
      (cd "$TASK_TMP" && HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$backend root")
      want="$(cd "$TASK_TMP" && cli_root "$backend root")"
    else
      HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$spelling"
      want="$(cli_root "$spelling")"
    fi
    assert_root "$want" "$backend root spelling '$spelling'"
    command -v cygpath >/dev/null 2>&1 || [ "$want" = "$expected_root" ] \
      || { echo "FAIL: $backend root spelling '$spelling' does not collapse to '$expected_root'"; exit 1; }
  done
  # Without Node the shell fallback resolves the directory itself, so it must
  # match what hq reindex computes when run inside the root (findHqRoot walks
  # up from process.cwd(), which Windows reports in long form).
  printf '%s\n' '{"hooks":{}}' > "$fixture/.claude/settings.json"
  HQ_HOOK_ROOT_RESOLVER=shell HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$fixture"
  assert_root "$(cd "$fixture" && cli_root .)" "$backend shell-fallback root"
  # Windows: the root has a space, and the TEMP path holds an 8.3 short name on
  # hosted runners. Native, mixed, lower-case drive and upper-case spellings must
  # each give the token hq-cli computes for that same spelling.
  if command -v cygpath >/dev/null 2>&1; then
    native="$(cygpath -w "$fixture")"
    mixed="$(cygpath -m "$fixture")"
    lower_drive="$(printf '%s' "${native:0:1}" | tr '[:upper:]' '[:lower:]')${native:1}"
    upper="$(printf '%s' "$native" | tr '[:lower:]' '[:upper:]')"
    for spelling in "$native" "$mixed" "$lower_drive" "$upper" "$native\\"; do
      printf '%s\n' '{"hooks":{}}' > "$fixture/.claude/settings.json"
      HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$spelling"
      assert_root "$(cli_root "$spelling")" "$backend windows spelling '$spelling'"
    done
  fi
  # A probe that hangs is cut off and keeps bash.
  echo hang > "$HQ_TEST_FLAG"
  printf '%s\n' '{"hooks":{}}' > "$fixture/.claude/settings.json"
  started=$SECONDS
  HQ_HOOK_ENGINE_PROBE_TIMEOUT=1 HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$fixture"
  [ $((SECONDS - started)) -lt 10 ] || { echo "FAIL: $backend probe timeout took $((SECONDS - started))s"; exit 1; }
  jq -e '[.hooks[][] .hooks[] | select(has("args"))] | length == 0' "$fixture/.claude/settings.json" >/dev/null
  jq -e '.hooks.PreToolUse[0].hooks[0].command | contains("master-hook.sh")' "$fixture/.claude/settings.json" >/dev/null
  # A hung probe's children go too: the whole process group is killed.
  echo grandchild > "$HQ_TEST_FLAG"
  rm -f "$HQ_TEST_GRANDCHILD"
  printf '%s\n' '{"hooks":{}}' > "$fixture/.claude/settings.json"
  HQ_HOOK_ENGINE_PROBE_TIMEOUT=1 HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$fixture"
  gc="$(cat "$HQ_TEST_GRANDCHILD" 2>/dev/null || true)"
  [ -n "$gc" ] || { echo "FAIL: $backend grandchild probe never started"; exit 1; }
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$gc" 2>/dev/null || break; sleep 0.2; done
  if kill -0 "$gc" 2>/dev/null; then
    kill "$gc" 2>/dev/null
    echo "FAIL: $backend probe timeout left grandchild $gc running"; exit 1
  fi
  jq -e '.hooks.PreToolUse[0].hooks[0].command | contains("master-hook.sh")' "$fixture/.claude/settings.json" >/dev/null
  # Only the pinned layout is accepted: /bin/sh, or an engine outside
  # <home>/.hq/bin/hq-hook/<semver>/, keeps bash.
  for bad in sh foreign; do
    echo "$bad" > "$HQ_TEST_FLAG"
    printf '%s\n' '{"hooks":{}}' > "$fixture/.claude/settings.json"
    HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$fixture" >/dev/null
    jq -e '[.hooks[][] .hooks[] | select(has("args"))] | length == 0' "$fixture/.claude/settings.json" >/dev/null \
      || { echo "FAIL: $backend accepted unpinned engine ($bad): $(jq -c '.hooks.PreToolUse' "$fixture/.claude/settings.json")"; exit 1; }
    grep -q 'master-hook.sh' "$fixture/.claude/settings.json" || { echo "FAIL: $backend $bad lost bash"; exit 1; }
  done
  # The pinned layout under another home is registered, with a warning, so the
  # healer agrees with the adapters (which run master-hook.sh for it).
  echo other-home > "$HQ_TEST_FLAG"
  printf '%s\n' '{"hooks":{}}' > "$fixture/.claude/settings.json"
  HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$fixture" >/dev/null 2>"$TASK_TMP/other-home.err"
  jq -e '[.hooks[][] .hooks[] | select(has("args"))] | length == 10' "$fixture/.claude/settings.json" >/dev/null \
    || { echo "FAIL: $backend dropped the pinned engine under another home: $(jq -c '.hooks.PreToolUse' "$fixture/.claude/settings.json")"; exit 1; }
  grep -q 'is not under this HOME' "$TASK_TMP/other-home.err" \
    || { echo "FAIL: $backend did not warn about the engine under another home"; exit 1; }
  # The home the CLI pins under is accepted however this shell spells it:
  # through a symlink, or (Windows) as USERPROFILE when Git Bash's HOME differs.
  echo on > "$HQ_TEST_FLAG"
  home_link="$TASK_TMP/home link"
  if ln -s "$HOME" "$home_link" 2>/dev/null && [ -L "$home_link" ]; then
    printf '%s\n' '{"hooks":{}}' > "$fixture/.claude/settings.json"
    HOME="$home_link" HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$fixture" >/dev/null
    jq -e '[.hooks[][] .hooks[] | select(has("args"))] | length == 10' "$fixture/.claude/settings.json" >/dev/null \
      || { echo "FAIL: $backend rejected the pinned engine with HOME through a symlink"; exit 1; }
    rm -f "$home_link"
  else
    echo "SKIP: $backend symlinked HOME (ln -s unavailable)"
  fi
  if command -v cygpath >/dev/null 2>&1; then
    mkdir -p "$TASK_TMP/git-bash-home"
    printf '%s\n' '{"hooks":{}}' > "$fixture/.claude/settings.json"
    HOME="$TASK_TMP/git-bash-home" HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$fixture" >/dev/null
    jq -e '[.hooks[][] .hooks[] | select(has("args"))] | length == 10' "$fixture/.claude/settings.json" >/dev/null \
      || { echo "FAIL: $backend rejected the engine under USERPROFILE when HOME differs"; exit 1; }
  fi
  # The probe runs from the HQ root, not the caller's directory, so the CLI
  # reads that root's scoped flag.
  echo on > "$HQ_TEST_FLAG"
  rm -f "$HQ_TEST_CWD"
  printf '%s\n' '{"hooks":{}}' > "$fixture/.claude/settings.json"
  (cd "$TASK_TMP" && HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$fixture" >/dev/null)
  [ "$(cat "$HQ_TEST_CWD" 2>/dev/null)" = "$(cd "$fixture" && pwd -P)" ] \
    || { echo "FAIL: $backend probe cwd '$(cat "$HQ_TEST_CWD" 2>/dev/null)' is not the root"; exit 1; }
  # Flag on with relocated hooks in settings.local.json: the local hooks key is
  # removed (permissions kept), the base gets engine entries, the message
  # names the engine, and each heal keeps its own backup dir.
  rm -rf "$fixture/workspace"
  printf '%s\n' '{"hooks":{}}' > "$fixture/.claude/settings.json"
  printf '%s\n' '{"permissions":{"allow":["Bash(ls)"]},"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"env BASH_ENV=/dev/null bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/master-hook.sh\" PreToolUse","timeout":300}]}]}}' > "$fixture/.claude/settings.local.json"
  out="$(HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$fixture")"
  jq -e '(has("hooks") | not) and .permissions.allow == ["Bash(ls)"]' "$fixture/.claude/settings.local.json" >/dev/null \
    || { echo "FAIL: $backend local hooks not removed: $(cat "$fixture/.claude/settings.local.json")"; exit 1; }
  jq -e --arg engine "$HQ_TEST_PIN_NATIVE" '[.hooks[][] .hooks[] | select(has("args") and .command == $engine)] | length == 10' "$fixture/.claude/settings.json" >/dev/null \
    || { echo "FAIL: $backend base lacks engine entries with local hooks present"; exit 1; }
  printf '%s' "$out" | grep -q 'registered the pinned hook engine' && printf '%s' "$out" | grep -q 'removed hooks key from .claude/settings.local.json' \
    || { echo "FAIL: $backend engine heal message: $out"; exit 1; }
  printf '%s\n' '{"hooks":{}}' > "$fixture/.claude/settings.json"
  HQ_HOOK_ENGINE="$backend" bash "$ROOT/core/scripts/restore-hook-settings.sh" "$fixture" >/dev/null
  n_bk="$(ls -d "$fixture"/workspace/.hq-update-check/settings-backups/*/ 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n_bk" = 2 ] || { echo "FAIL: $backend back-to-back heals share a backup dir ($n_bk)"; exit 1; }
  rm -f "$fixture/.claude/settings.local.json"
  rm "$HQ_TEST_FLAG"
  echo "PASS: $backend missing/on/idempotent/off/missing-engine/root-spelling/probe-timeout/grandchild/unpinned/other-home/cwd/local/backups"
done
