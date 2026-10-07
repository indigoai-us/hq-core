#!/usr/bin/env bash
# hq-core: public
# Directory symlinks must not hide company-owned content from scope checks.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

failures=0
checks=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

install_fixture() {
  local bound="${1:-}" hook_source="${SCOPE_HOOK_SOURCE:-$ROOT/.claude/hooks/mandatory-scope-authorizer.sh}"
  rm -rf "$TMP/.claude" "$TMP/core" "$TMP/companies" "$TMP/workspace" "$TMP/personal"
  mkdir -p "$TMP/.claude/hooks" "$TMP/.claude/skills/own-skill" \
    "$TMP/core/scripts/lib" "$TMP/companies/otherco/skills/s" \
    "$TMP/workspace/sessions/sess-unbound" "$TMP/personal"
  cp "$hook_source" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh"
  cp "$ROOT/core/scripts/lib/session-authz.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-id.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/"
  printf 'companies:\n  otherco:\n    name: otherco\n' > "$TMP/companies/manifest.yaml"
  printf 'own skill fixture\n' > "$TMP/.claude/skills/own-skill/SKILL.md"
  printf 'other company skill fixture\n' > "$TMP/companies/otherco/skills/s/SKILL.md"
  printf 'canary fixture\n' > "$TMP/companies/otherco/skills/s/secret.md"
  ln -s ../../companies/otherco/skills/s "$TMP/.claude/skills/otherco:s"
  ln -s ../companies/otherco/skills/s "$TMP/workspace/lnk"
  ln -s ../companies/otherco/skills/s "$TMP/personal/lnk"
  if [ -n "$bound" ]; then
    printf 'company_slug: %s\n' "$bound" > "$TMP/workspace/sessions/sess-unbound/meta.yaml"
  fi
}

run_case() {
  local label="$1" tool="$2" session="$3" path="$4" pattern="$5" command="$6" expected="$7" case_cwd="${8:-$TMP}"
  local tool_input payload rc=0 stderr_file
  checks=$((checks + 1))
  stderr_file="$TMP/stderr-$checks"
  case "$tool" in
    Read) tool_input="$(jq -cn --arg path "$path" '{file_path:$path}')" ;;
    Grep)
      if [ "$path" = '__NO_PATH__' ]; then
        tool_input='{"pattern":"other company skill fixture"}'
      else
        tool_input="$(jq -cn --arg path "$path" '{path:$path,pattern:"other company skill fixture"}')"
      fi
      ;;
    Glob) tool_input="$(jq -cn --arg path "$path" --arg pattern "$pattern" '{path:$path,pattern:$pattern}')" ;;
    Bash) tool_input="$(jq -cn --arg command "$command" '{command:$command}')" ;;
    *) fail "$label has unsupported tool $tool"; return ;;
  esac
  payload="$(jq -cn --arg tool "$tool" --arg session "$session" --arg cwd "$case_cwd" --argjson input "$tool_input" \
    '{tool_name:$tool,session_id:$session,cwd:$cwd,tool_input:$input}')"
  printf '%s' "$payload" | bash "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" 2>"$stderr_file" || rc=$?
  printf '%-52s exit=%s\n' "$label" "$rc"
  if [ "$rc" -ne "$expected" ]; then
    fail "$label expected exit $expected, got $rc"
  elif [ "$expected" -eq 2 ] && ! grep -q 'Cross-company scope violation' "$stderr_file"; then
    fail "$label was denied without the cross-company message"
  fi
}

install_fixture ""
echo '[simple-command follow flags and wrapper chains]'
run_case 'grep operand before -R (GNU permutes)' Bash sess-unbound '' '' 'grep canary workspace -R' 2
run_case 'rg operand before -L' Bash sess-unbound '' '' 'rg canary workspace -L' 2
run_case 'rg operand before --follow' Bash sess-unbound '' '' 'rg canary workspace --follow' 2
run_case 'grep --include value before -R' Bash sess-unbound '' '' 'grep --include x -R canary workspace' 2
run_case 'grep --exclude-dir value before -R' Bash sess-unbound '' '' 'grep --exclude-dir x -R canary workspace' 2
run_case 'rg -A value before -L' Bash sess-unbound '' '' 'rg -A 2 -L canary workspace' 2
run_case 'rg -C value before -L' Bash sess-unbound '' '' 'rg -C 3 -L canary workspace' 2
run_case 'rg -T value before -L' Bash sess-unbound '' '' 'rg -T js -L canary workspace' 2
run_case 'rg -j value before -L' Bash sess-unbound '' '' 'rg -j 2 -L canary workspace' 2
run_case 'rg --max-depth value before -L' Bash sess-unbound '' '' 'rg --max-depth 5 -L canary workspace' 2
run_case 'env -i assignments grep -R' Bash sess-unbound '' '' 'env -i LC_ALL=C grep -R canary workspace' 2
run_case 'command -p grep -R' Bash sess-unbound '' '' 'command -p grep -R canary workspace' 2
run_case 'nice -n wrapper grep -R' Bash sess-unbound '' '' 'nice -n 5 grep -R canary workspace' 2
run_case 'egrep alias -R' Bash sess-unbound '' '' 'egrep -R canary workspace' 2
run_case 'LC_ALL assignment grep -R' Bash sess-unbound '' '' 'LC_ALL=C grep -R canary workspace' 2
run_case 'wrapper chain env then nice then grep -R' Bash sess-unbound '' '' 'env -u HOME nice -n 5 grep -R canary workspace' 2
run_case 'absolute grep basename with -R' Bash sess-unbound '' '' '/usr/bin/grep -R canary workspace' 2
run_case 'fgrep alias with -R' Bash sess-unbound '' '' 'fgrep -R canary workspace' 2
run_case 'zgrep alias with -R' Bash sess-unbound '' '' 'zgrep -R canary workspace' 2
run_case 'ggrep alias with -R' Bash sess-unbound '' '' 'ggrep -R canary workspace' 2
run_case 'builtin wrapper with grep -R' Bash sess-unbound '' '' 'builtin grep -R canary workspace' 2
run_case 'exec wrapper with grep -R' Bash sess-unbound '' '' 'exec -a grep grep -R canary workspace' 2
run_case 'nohup wrapper with grep -R' Bash sess-unbound '' '' 'nohup grep -R canary workspace' 2
run_case 'time wrapper with -p and grep -R' Bash sess-unbound '' '' 'time -p grep -R canary workspace' 2
run_case 'timeout wrapper with options and duration' Bash sess-unbound '' '' 'timeout -s TERM -k 2 5s grep -R canary workspace' 2
run_case 'stdbuf wrapper with attached modes' Bash sess-unbound '' '' 'stdbuf -i0 -oL -e0 grep -R canary workspace' 2
run_case 'ionice wrapper with -c value' Bash sess-unbound '' '' 'ionice -c 3 grep -R canary workspace' 2
run_case 'chrt wrapper with scheduling priority' Bash sess-unbound '' '' 'chrt -f 10 grep -R canary workspace' 2
run_case 'taskset wrapper with cpu list' Bash sess-unbound '' '' 'taskset -c 0 grep -R canary workspace' 2
run_case 'sudo wrapper with -n and -u' Bash sess-unbound '' '' 'sudo -n -u nobody grep -R canary workspace' 2
run_case 'doas wrapper with -u' Bash sess-unbound '' '' 'doas -u nobody grep -R canary workspace' 2
run_case 'xargs wrapper treats following command as command' Bash sess-unbound '' '' 'xargs -0 grep -R canary workspace' 2
run_case 'grep -r control remains allowed' Bash sess-unbound '' '' 'grep -r canary workspace' 0
run_case 'rg default control remains allowed' Bash sess-unbound '' '' 'rg canary workspace' 0
run_case 'env grep -r control remains allowed' Bash sess-unbound '' '' 'env grep -r canary workspace' 0
run_case 'grep -e -r treats -r as pattern and remains allowed' Bash sess-unbound '' '' 'grep -e -r canary workspace' 0
echo '[unbound session: symlinked company content must be denied]'
run_case 'Grep blocks nested company directory symlink under its search root' Grep sess-unbound '.claude/skills' '' '' 2
run_case 'Grep blocks nested company directory symlink under cwd fallback' Grep sess-unbound '__NO_PATH__' '' '' 2 "$TMP/.claude/skills"
run_case 'Grep with implicit HQ-root path avoids a broad symlink scan' Grep sess-unbound '__NO_PATH__' '' '' 0 "$TMP"
run_case 'Grep search root is company dir symlink' Grep sess-unbound '.claude/skills/otherco:s' '' '' 2
run_case 'Glob blocks nested company directory symlink under static pattern prefix' Glob sess-unbound '.' '.claude/skills/**/SKILL.md' '' 2
run_case 'Glob blocks nested company directory symlink under relative static prefix' Glob sess-unbound 'core' '../.claude/skills/**/SKILL.md' '' 2
run_case 'Glob without static prefix checks the search root' Glob sess-unbound '.' '**/SKILL.md' '' 2
run_case 'Glob search root is company dir symlink' Glob sess-unbound '.claude/skills/otherco:s' 'SKILL.md' '' 2
ln -s unresolvable "$TMP/.claude/skills/unresolvable"
run_case 'Grep root with nested unresolvable symlink fails closed' Grep sess-unbound '.claude/skills' '' '' 2
run_case 'Grep search root is unresolvable symlink' Grep sess-unbound '.claude/skills/unresolvable' '' '' 2
unlink "$TMP/.claude/skills/otherco:s"
unlink "$TMP/.claude/skills/unresolvable"
mkdir -p "$TMP/.claude/skills/a/b/c/d/e"
ln -s ../../../../../../../companies/otherco/skills/s "$TMP/.claude/skills/a/b/c/d/e/deep-link"
run_case 'Grep blocks company directory symlink within bounded depth' Grep sess-unbound '.claude/skills' '' '' 2
rm -rf "$TMP/.claude/skills/a"
mkdir -p "$TMP/.claude/skills/a/b/c/d/e/f/g"
ln -s "$TMP/companies/otherco/skills/s" "$TMP/.claude/skills/a/b/c/d/e/f/g/deep-link"
run_case 'Grep blocks company directory symlink below max-depth plus one' Grep sess-unbound '.claude/skills' '' '' 2
rm -rf "$TMP/.claude/skills/a"
ln -s ../../companies/otherco/skills/s "$TMP/.claude/skills/otherco:s"
mkdir -p "$TMP/find-fail-bin"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "synthetic find failure" >&2' 'exit 1' > "$TMP/find-fail-bin/find"
chmod +x "$TMP/find-fail-bin/find"
PATH="$TMP/find-fail-bin:$PATH" run_case 'Grep denies when the symlink scan find fails' Grep sess-unbound '.claude/skills' '' '' 2
grep -q 'synthetic find failure' "$TMP/stderr-$checks" || fail 'Grep hid the symlink scan find error'
rm -rf "$TMP/find-fail-bin"
mkdir -p "$TMP/find-limit-bin"
printf '%s\n' '#!/bin/bash' 'root="$1"' 'i=0' 'while [ "$i" -lt 4097 ]; do' '  printf "%s\0" "$root"' '  i=$((i + 1))' 'done' > "$TMP/find-limit-bin/find"
chmod +x "$TMP/find-limit-bin/find"
PATH="$TMP/find-limit-bin:$PATH" run_case 'Grep denies after the symlink scan entry ceiling' Grep sess-unbound '.claude/skills' '' '' 2
rm -rf "$TMP/find-limit-bin"
for tool in cat head 'grep -r' ls; do
  if [ "$tool" = 'grep -r' ]; then
    command="$tool fixture \"$TMP/.claude/skills/otherco:s/SKILL.md\""
    relative="$tool fixture \".claude/skills/otherco:s/SKILL.md\""
  else
    command="$tool \"$TMP/.claude/skills/otherco:s/SKILL.md\""
    relative="$tool \".claude/skills/otherco:s/SKILL.md\""
  fi
  run_case "Bash $tool absolute symlink path" Bash sess-unbound '' '' "$command" 2
  run_case "Bash $tool relative symlink path" Bash sess-unbound '' '' "$relative" 2
done
run_case 'Bash variable path fails closed' Bash sess-unbound '' '' 'skill=otherco:s; cat .claude/skills/$skill/SKILL.md' 2
run_case 'Bash repeated slash path resolves symlink' Bash sess-unbound '' '' 'cat .claude//skills/otherco:s/SKILL.md' 2
run_case 'Bash dot segment path resolves symlink' Bash sess-unbound '' '' 'cat .claude/./skills/otherco:s/SKILL.md' 2
run_case 'Bash cat workspace symlink path' Bash sess-unbound '' '' 'cat workspace/lnk/secret.md' 2
run_case 'Bash grep -r does not follow workspace symlink' Bash sess-unbound '' '' 'grep -r canary workspace' 0
run_case 'Bash cat personal symlink path' Bash sess-unbound '' '' 'cat personal/lnk/secret.md' 2
run_case 'Bash grep -r does not follow personal symlink' Bash sess-unbound '' '' 'grep -r canary personal' 0
run_case 'Bash grep -R follows workspace symlink' Bash sess-unbound '' '' 'grep -R canary workspace' 2
run_case 'Bash compound true; grep -R scans every segment' Bash sess-unbound '' '' 'true; grep -R canary workspace' 2
run_case 'Bash compound true && grep -R scans every segment' Bash sess-unbound '' '' 'true && grep -R canary workspace' 2
run_case 'Bash compound true || grep -R scans every segment' Bash sess-unbound '' '' 'true || grep -R canary workspace' 2
run_case 'Bash pipeline true | grep -R scans every segment' Bash sess-unbound '' '' 'true | grep -R canary workspace' 2
run_case 'Bash newline-separated grep -R scans its segment' Bash sess-unbound '' '' $'true\ngrep -R canary workspace' 2
run_case 'Bash command substitution grep -R scans its segment' Bash sess-unbound '' '' 'printf x $(grep -R canary workspace)' 2
run_case 'Bash grep -d recurse -R scans past option argument' Bash sess-unbound '' '' 'grep -d recurse -R canary workspace' 2
run_case 'Bash compound true; grep -r remains non-following' Bash sess-unbound '' '' 'true; grep -r canary workspace' 0
run_case 'Bash grep -Rn follows workspace symlink' Bash sess-unbound '' '' 'grep -Rn canary workspace' 2
run_case 'Bash grep -nR follows workspace symlink' Bash sess-unbound '' '' 'grep -nR canary workspace' 2
run_case 'Bash rg -uL follows workspace symlink' Bash sess-unbound '' '' 'rg -uL canary workspace' 2
run_case 'Bash rg default does not follow workspace symlink' Bash sess-unbound '' '' 'rg canary workspace' 0
run_case 'Bash recursive rg --follow workspace symlink root' Bash sess-unbound '' '' 'rg --follow canary workspace' 2
run_case 'Bash rg -L follows workspace symlink' Bash sess-unbound '' '' 'rg -L canary workspace' 2
run_case 'Bash find default does not follow workspace symlink' Bash sess-unbound '' '' 'find workspace -name secret.md' 0
run_case 'Bash recursive find -L workspace symlink root' Bash sess-unbound '' '' 'find -L workspace -name secret.md' 2
run_case 'Bash find -follow follows workspace symlink' Bash sess-unbound '' '' 'find workspace -follow -name x' 2
run_case 'Bash find -H follows command-line workspace link' Bash sess-unbound '' '' 'find -H workspace -name x' 2
run_case 'Bash env and nice wrappers preserve find follow detection' Bash sess-unbound '' '' 'env -u HOME nice -n 5 find -L workspace -name secret.md' 2
run_case 'Bash ls -R does not follow workspace symlink' Bash sess-unbound '' '' 'ls -R workspace' 0
run_case 'Bash grep -rn remains non-following' Bash sess-unbound '' '' 'grep -rn canary workspace' 0
run_case 'Bash quoted -R pattern is not a follow option' Bash sess-unbound '' '' 'grep "-R canary" workspace' 0

run_case 'Bash grep -R dot scans HQ-root descendants' Bash sess-unbound '' '' 'grep -R canary .' 2 "$TMP"
run_case 'Bash grep -R ./ scans HQ-root descendants' Bash sess-unbound '' '' 'grep -R canary ./' 2 "$TMP"
run_case "Bash grep -R absolute HQ root scans descendants" Bash sess-unbound '' '' "grep -R canary \"$TMP\"" 2 "$TMP"
run_case 'Bash grep -R no operand uses HQ cwd and scans' Bash sess-unbound '' '' 'grep -R canary' 2 "$TMP"
run_case 'Bash grep -R lnk resolves relative to workspace cwd' Bash sess-unbound '' '' 'grep -R canary lnk' 2 "$TMP/workspace"

mkdir -p "$TMP/workspace/a/b/c/d/e/f"
ln -s ../../../../../../../companies/otherco/skills/s "$TMP/workspace/a/b/c/d/e/f/deep-link"
run_case 'Bash grep -R blocks company symlink beyond scan bound' Bash sess-unbound '' '' 'grep -R canary workspace' 2
run_case 'Bash grep -r allows non-following traversal beyond scan bound' Bash sess-unbound '' '' 'grep -r canary workspace' 0

echo '[filesystem traversal behavior in the hermetic fixture]'
# The guard assertions above classify synthetic rg payloads; this probe does not
# execute rg because the merge-gate runner does not guarantee that binary.
if grep -r canary "$TMP/workspace" > "$TMP/tool-grep-r"; then grep_r=1; else grep_r=0; fi
if grep -R canary "$TMP/workspace" > "$TMP/tool-grep-R"; then grep_R=1; else grep_R=0; fi
find "$TMP/workspace" -name secret.md > "$TMP/tool-find-default" || true
find -L "$TMP/workspace" -name secret.md > "$TMP/tool-find-follow" || true
if grep -q 'secret.md' "$TMP/tool-find-default"; then find_default=1; else find_default=0; fi
if grep -q 'secret.md' "$TMP/tool-find-follow"; then find_follow=1; else find_follow=0; fi
ls -R "$TMP/workspace" > "$TMP/tool-ls-R" 2>/dev/null || true
if grep -q 'secret.md' "$TMP/tool-ls-R"; then ls_recursive=1; else ls_recursive=0; fi
printf 'grep -r=%s -R=%s; find default=%s -L=%s; ls -R reads target=%s\n' \
  "$grep_r" "$grep_R" "$find_default" "$find_follow" "$ls_recursive"
[ "$grep_r" -eq 0 ] && [ "$grep_R" -eq 1 ] || fail 'unexpected grep symlink traversal behavior'
[ "$find_default" -eq 0 ] && [ "$find_follow" -eq 1 ] || fail 'unexpected find symlink traversal behavior'
[ "$ls_recursive" -eq 0 ] || fail 'ls -R unexpectedly traversed the directory symlink'

echo '[positive controls: ordinary paths and the owning company remain allowed]'
run_case 'Read own real skill' Read sess-unbound "$TMP/.claude/skills/own-skill/SKILL.md" '' '' 0
run_case 'Grep own real skill' Grep sess-unbound '.claude/skills/own-skill' '' '' 0
run_case 'Glob own real skill' Glob sess-unbound '.claude/skills/own-skill' 'SKILL.md' '' 0
run_case 'Bash own real skill' Bash sess-unbound '' '' 'cat .claude/skills/own-skill/SKILL.md' 0
run_case 'Grep core path' Grep sess-unbound 'core/' '' '' 0

install_fixture ''
mkdir -p "$TMP/core/a/b/c/d/e/f/g/h/i/j/k/l"
run_case 'Grep permits a 12-level tree with no company symlink' Grep sess-unbound 'core/' '' '' 0

install_fixture 'otherco'
echo '[session bound to the symlink target company remains allowed]'
run_case 'Read symlinked otherco skill' Read sess-unbound "$TMP/.claude/skills/otherco:s/SKILL.md" '' '' 0
run_case 'Grep nested bound otherco link remains allowed' Grep sess-unbound '.claude/skills' '' '' 0
run_case 'Grep symlinked otherco skill' Grep sess-unbound '.claude/skills/otherco:s' '' '' 0
run_case 'Glob nested bound otherco link remains allowed' Glob sess-unbound '.' '.claude/skills/**/SKILL.md' '' 0
run_case 'Glob static prefix allows bound otherco link' Glob sess-unbound 'core' '../.claude/skills/**/SKILL.md' '' 0
run_case 'Glob symlinked otherco skill' Glob sess-unbound '.claude/skills/otherco:s' 'SKILL.md' '' 0
run_case 'Bash symlinked otherco skill' Bash sess-unbound '' '' 'cat .claude/skills/otherco:s/SKILL.md' 0

echo "Checks: $checks; failures: $failures"
[ "$failures" -eq 0 ]
