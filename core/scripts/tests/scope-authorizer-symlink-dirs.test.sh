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
last_stderr_file=""

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

install_fixture() {
  local bound="${1:-}" hook_source="${SCOPE_HOOK_SOURCE:-$ROOT/.claude/hooks/mandatory-scope-authorizer.sh}"
  rm -rf "$TMP/.claude" "$TMP/core" "$TMP/companies" "$TMP/workspace" "$TMP/personal" "$TMP/claude-config" \
    "$TMP/repos"
  mkdir -p "$TMP/.claude/hooks" "$TMP/.claude/skills/own-skill" \
    "$TMP/core/scripts/lib" "$TMP/companies/otherco/skills/s" \
    "$TMP/workspace/sessions/sess-unbound" "$TMP/personal"
  cp "$hook_source" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh"
  cp "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$ROOT/.claude/hooks/path-fold-lib.sh" "$TMP/.claude/hooks/"
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
  last_stderr_file="$stderr_file"
  case "$tool" in
    Read) tool_input="$(jq -cn --arg path "$path" '{file_path:$path}')" ;;
    Write) tool_input="$(jq -cn --arg path "$path" '{file_path:$path,content:"x"}')" ;;
    Grep)
      if [ "$path" = '__NO_PATH__' ]; then
        tool_input='{"pattern":"other company skill fixture"}'
      else
        tool_input="$(jq -cn --arg path "$path" '{path:$path,pattern:"other company skill fixture"}')"
      fi
      ;;
    Glob) tool_input="$(jq -cn --arg path "$path" --arg pattern "$pattern" '{path:$path,pattern:$pattern}')" ;;
    Bash) tool_input="$(jq -cn --arg command "$command" '{command:$command}')" ;;
    Skill) tool_input="$(jq -cn --arg skill "$path" '{skill:$skill}')" ;;
    *) fail "$label has unsupported tool $tool"; return ;;
  esac
  payload="$(jq -cn --arg tool "$tool" --arg session "$session" --arg cwd "$case_cwd" --argjson input "$tool_input" \
    --arg agent "${CASE_AGENT_ID:-}" \
    '{tool_name:$tool,session_id:$session,cwd:$cwd,tool_input:$input}
     + (if $agent == "" then {} else {agent_id:$agent, agent_type:"general-purpose"} end)')"
  # A fixed Claude config dir inside the fixture, so the runner's own
  # user-level skills and launch folder never take part in a case.
  printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$TMP/claude-config" CLAUDE_PROJECT_DIR="$TMP" \
    bash "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" 2>"$stderr_file" || rc=$?
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
# Informational: grep -R symlink traversal differs by host grep (BSD vs GNU); the
# probe never calls the hook, and the guard cases above are the real assertions.
[ "$grep_r" -eq 0 ] && [ "$grep_R" -eq 1 ] || echo "note: host grep symlink traversal differs (grep -r=$grep_r -R=$grep_R); informational only"
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
run_case 'Skill tool loads the bound company skill' Skill sess-unbound 'otherco:s' '' '' 0

# The Skill tool reads SKILL.md itself, so no Read reaches the hook (desk
# follow-up to feedback_0a9cbd6a). Decision 2026-11-09 for #1862: a Skill
# call is refused when its name, in any spelling, matches a skill of a company
# outside the session's scope (folder name or frontmatter name under
# companies/<slug>/skills or companies/<slug>/.claude/skills, plus the
# `<slug>:` and `hq-<slug>:` forms), even when a core or own-company skill has
# the same name. Unbound sessions treat every company as out of scope. Each
# layout below is one an earlier review of #1862 found a bypass in.
assert_stderr() { # <label> <fixed text expected in the last case's stderr>
  checks=$((checks + 1))
  # Reads the stderr file run_case recorded, so back-to-back asserts all
  # read the same case's output.
  if [ -n "$last_stderr_file" ] && grep -qF -- "$2" "$last_stderr_file"; then
    printf '%-52s ok\n' "$1"
  else
    fail "$1: stderr lacks: $2"
  fi
}
copy_mirror() { # <slug> <skill> <SKILL.md text, printf %b escapes>
  mkdir -p "$TMP/companies/$1/skills/$2" "$TMP/.claude/skills/$1:$2"
  printf '%b' "$3" > "$TMP/companies/$1/skills/$2/SKILL.md"
  printf '%b' "$3" > "$TMP/.claude/skills/$1:$2/SKILL.md"
}
company_skill() { # <slug> <skill> <SKILL.md text>: a company skill with no mirror
  mkdir -p "$TMP/companies/$1/skills/$2"
  printf '%b' "$3" > "$TMP/companies/$1/skills/$2/SKILL.md"
}
add_ownco() {
  mkdir -p "$TMP/companies/ownco/skills"
  printf '  ownco:\n    name: ownco\n' >> "$TMP/companies/manifest.yaml"
}

install_fixture ''
copy_mirror otherco fm '---\nname: otherco-secret\ndescription: fixture\n---\nother company frontmatter fixture\n'
copy_mirror otherco anatomy '---\nname: anatomy\ndescription: fixture\n---\nother company copied fixture\n'
copy_mirror otherco plain 'other company copied fixture, no frontmatter\n'
mkdir -p "$TMP/.claude/skills/core-fm"
printf -- '---\nname: "core-fm-name"\n---\ncore fixture\n' > "$TMP/.claude/skills/core-fm/SKILL.md"
echo '[Skill tool, unbound: names and spellings (reviews of a9ac8128 and add32802a)]'
run_case 'Skill unbound refuses colon name' Skill sess-unbound 'otherco:s' '' '' 2
run_case 'Skill unbound refuses slash-prefixed name' Skill sess-unbound '/otherco:s' '' '' 2
run_case 'Skill unbound refuses upper-case slug' Skill sess-unbound 'OtherCo:s' '' '' 2
run_case 'Skill unbound refuses all-caps name' Skill sess-unbound 'OTHERCO:S' '' '' 2
run_case 'Skill unbound refuses dot-dot name' Skill sess-unbound 'otherco:../s' '' '' 2
run_case 'Skill unbound refuses slash after the colon' Skill sess-unbound 'otherco:/anatomy' '' '' 2
run_case 'Skill unbound refuses leading space' Skill sess-unbound ' otherco:s' '' '' 2
run_case 'Skill unbound refuses space then slash' Skill sess-unbound ' /otherco:s' '' '' 2
run_case 'Skill unbound refuses trailing newline' Skill sess-unbound $'otherco:s\n' '' '' 2
run_case 'Skill unbound refuses tab padding' Skill sess-unbound $'\totherco:s\t' '' '' 2
run_case 'Skill unbound refuses no-break-space padding' Skill sess-unbound $'\302\240otherco:s' '' '' 2
run_case 'Skill unbound refuses unknown name under a company prefix' Skill sess-unbound 'otherco:unmirrored' '' '' 2
run_case 'Skill unbound refuses hq- company prefix' Skill sess-unbound 'hq-otherco:anatomy' '' '' 2
run_case 'Skill unbound refuses frontmatter name' Skill sess-unbound 'otherco-secret' '' '' 2
run_case 'Skill unbound refuses padded frontmatter name' Skill sess-unbound ' otherco-secret' '' '' 2
run_case 'Skill unbound refuses copied mirror by bare name' Skill sess-unbound 'anatomy' '' '' 2
# Review of 0439675d0: each line of a requested name is looked up on its own,
# as #1862 did; canonicalising the whole name turned the line break into a
# space and let both of these through.
run_case 'Skill unbound refuses a name on the line after another' Skill sess-unbound $'x\nanatomy' '' '' 2
run_case 'Skill unbound refuses a name on the line before another' Skill sess-unbound $'anatomy\nx' '' '' 2
run_case 'Skill unbound refuses an upper-case name on a second line' Skill sess-unbound $'x\nANATOMY' '' '' 2
run_case 'Skill unbound allows a space-joined name (control)' Skill sess-unbound 'x anatomy' '' '' 0
# Claude Code does not load a `<slug>:<name>` folder under the bare `<name>`
# (with only `ownco:hello-world` present, `hello-world` is an unknown skill),
# so a company folder name with no frontmatter name no longer refuses the bare
# name; the company-addressed spellings still do.
run_case 'Skill unbound loads a bare name only a company folder name has' Skill sess-unbound 'plain' '' '' 0
run_case 'Skill unbound refuses that folder name with its company prefix' Skill sess-unbound 'otherco:plain' '' '' 2
run_case 'Skill unbound refuses directory-scoped company name' Skill sess-unbound 'companies/otherco:deploy' '' '' 2
run_case 'Skill unbound refuses dot-slash directory-scoped name' Skill sess-unbound './companies/otherco:anatomy' '' '' 2
run_case 'Skill unbound refuses a name with two colons' Skill sess-unbound 'otherco:a:anatomy' '' '' 2
run_case 'Skill unbound refuses a trailing slash' Skill sess-unbound 'otherco:anatomy/' '' '' 2
echo '[Skill tool, unbound: names no company skill carries still load]'
run_case 'Skill unbound loads a core skill' Skill sess-unbound 'own-skill' '' '' 0
run_case 'Skill unbound loads a core skill by frontmatter name' Skill sess-unbound 'core-fm-name' '' '' 0
run_case 'Skill unbound loads a plugin-shaped name' Skill sess-unbound 'someplugin:thing' '' '' 0
run_case 'Skill unbound loads a pack name' Skill sess-unbound 'hq-pack-cowork:hq-cowork' '' '' 0
run_case 'Skill unbound loads a personal name' Skill sess-unbound 'personal:mine' '' '' 0
run_case 'Skill unbound unknown name stays allowed' Skill sess-unbound 'no-such-skill' '' '' 0

# Frontmatter details (review of add32802a minor 3, b72e6a6e6 minor 4).
install_fixture ''
copy_mirror otherco cmt '---\nname: otherco-cmt # a comment\n---\nfixture\n'
copy_mirror otherco sq "---\nname: 'otherco''sq'\n---\nfixture\n"
copy_mirror otherco bom '\xEF\xBB\xBF---\nname: otherco-bom\n---\nfixture\n'
copy_mirror otherco folded '---\nname: >\n  otherco-folded\n---\nfixture\n'
copy_mirror otherco qkey '---\n"name": otherco-qkey\n---\nfixture\n'
copy_mirror otherco crlf '---\r\nname: otherco-crlf\r\n---\r\nfixture\r\n'
echo '[Skill tool, unbound: YAML spellings of the frontmatter name]'
run_case 'Skill unbound refuses a name followed by a comment' Skill sess-unbound 'otherco-cmt' '' '' 2
run_case 'Skill unbound refuses a doubled single quote name' Skill sess-unbound "otherco'sq" '' '' 2
run_case 'Skill unbound refuses a name after a byte-order mark' Skill sess-unbound 'otherco-bom' '' '' 2
run_case 'Skill unbound refuses a block-scalar name' Skill sess-unbound 'otherco-folded' '' '' 2
run_case 'Skill unbound refuses a quoted name key' Skill sess-unbound 'otherco-qkey' '' '' 2
run_case 'Skill unbound refuses a CRLF frontmatter name' Skill sess-unbound 'otherco-crlf' '' '' 2

# Frontmatter names decoded the way YAML reads them (review of e93e1c63e
# minor 2): tags, anchors, aliases, double-quoted escapes and scalars that
# continue on more-indented lines.
install_fixture ''
copy_mirror otherco tag '---\nname: !!str tagname\n---\nfixture\n'
copy_mirror otherco anch '---\nname: &a anchname\n---\nfixture\n'
copy_mirror otherco esc '---\nname: "esc\\x61pe"\n---\nfixture\n'
copy_mirror otherco multi '---\nname: multi\n  line\n---\nfixture\n'
copy_mirror otherco tagq '---\nname: !<tag:yaml.org,2002:str> &b "v\\u0065rbatim"\n---\nfixture\n'
copy_mirror otherco uni '---\nname: "caf\\u00e9-x"\n---\nfixture\n'
copy_mirror otherco alias '---\nx: &n aliasname\nname: *n\n---\nfixture\n'
copy_mirror otherco sqmulti "---\nname: 'sq\n  multi'\n---\nfixture\n"
copy_mirror otherco dqmulti '---\nname: "dq\\\n  join"\n---\nfixture\n'
copy_mirror otherco nextline '---\nname: !!str\n  nextname\n---\nfixture\n'
copy_mirror otherco cmt2 '---\nname: !!str # a comment\n  cmtname\n---\nfixture\n'
copy_mirror otherco folded2 '---\nname: >-\n  fold\n  two\n---\nfixture\n'
copy_mirror otherco indented '---\n  name: indentname\n  description: x\n---\nfixture\n'
echo '[Skill tool, unbound: frontmatter names decoded like YAML]'
run_case 'Skill unbound refuses a !!str-tagged name' Skill sess-unbound 'tagname' '' '' 2
run_case 'Skill unbound refuses an anchored name' Skill sess-unbound 'anchname' '' '' 2
run_case 'Skill unbound refuses a \x-escaped name' Skill sess-unbound 'escape' '' '' 2
run_case 'Skill unbound refuses a plain name on two lines' Skill sess-unbound 'multi line' '' '' 2
run_case 'Skill unbound refuses a verbatim-tagged \u-escaped name' Skill sess-unbound 'verbatim' '' '' 2
run_case 'Skill unbound refuses a non-ASCII \u-escaped name' Skill sess-unbound $'caf\303\251-x' '' '' 2
run_case 'Skill unbound refuses an aliased name' Skill sess-unbound 'aliasname' '' '' 2
run_case 'Skill unbound refuses a single-quoted name on two lines' Skill sess-unbound 'sq multi' '' '' 2
run_case 'Skill unbound refuses an escaped line break in a name' Skill sess-unbound 'dqjoin' '' '' 2
run_case 'Skill unbound refuses a tag with the name on the next line' Skill sess-unbound 'nextname' '' '' 2
run_case 'Skill unbound refuses a tag, comment, then name line' Skill sess-unbound 'cmtname' '' '' 2
run_case 'Skill unbound refuses a folded block-scalar name' Skill sess-unbound 'fold two' '' '' 2
run_case 'Skill unbound refuses a name in an indented mapping' Skill sess-unbound 'indentname' '' '' 2
run_case 'Skill unbound core skill loads beside decoded names' Skill sess-unbound 'own-skill' '' '' 0

# A name the guard cannot decode (a flow collection) could be any name:
# every Skill call for a name no skill folder owns is refused while that
# company is out of scope. A core skill folder still loads (owner direction
# 2026-11-14: a core skill is never refused because of a company skill; a
# request is resolved by folder name before any frontmatter name).
install_fixture ''
copy_mirror otherco flow '---\nname: [flowname]\n---\nfixture\n'
echo '[Skill tool: an undecodable frontmatter name]'
run_case 'Skill unbound loads a core skill beside an undecodable name' Skill sess-unbound 'own-skill' '' '' 0
run_case 'Skill unbound refuses an unowned name beside an undecodable name' Skill sess-unbound 'no-such-skill' '' '' 2
assert_stderr 'Undecodable refusal names the skill' 'otherco:flow, whose frontmatter name the guard cannot decode'
install_fixture 'otherco'
copy_mirror otherco flow '---\nname: [flowname]\n---\nfixture\n'
run_case 'Skill bound to otherco loads a core skill beside its own undecodable name' Skill sess-unbound 'own-skill' '' '' 0

# Review of c699363d1. A quoted block indicator (`name: "|"`) still emits the
# next indented line, as #1862 did. Names are stored in the spelling the
# request is compared in, so case, non-ASCII bytes and a tab inside the name
# do not make a request miss.
install_fixture ''
copy_mirror otherco qpipe '---\nname: "|"\n  qpipeline\n---\nfixture\n'
copy_mirror otherco sqfold "---\nname: '>'\n  sqfoldline\n---\nfixture\n"
copy_mirror otherco cafe '---\nname: "CAF\0303\0211"\n---\nfixture\n'
copy_mirror otherco tabname '---\nname: "a\\tb"\n---\nfixture\n'
echo '[Skill tool, unbound: quoted block indicators and canonical names]'
run_case 'Skill unbound refuses the line after a quoted |' Skill sess-unbound 'qpipeline' '' '' 2
run_case 'Skill unbound refuses the line after a quoted >' Skill sess-unbound 'sqfoldline' '' '' 2
run_case 'Skill unbound refuses an upper-case non-ASCII name' Skill sess-unbound $'CAF\303\211' '' '' 2
run_case 'Skill unbound refuses its lower-case spelling' Skill sess-unbound $'caf\303\251' '' '' 2
run_case 'Skill unbound refuses a name with a tab' Skill sess-unbound $'a\tb' '' '' 2
run_case 'Skill unbound core skill loads beside canonical names' Skill sess-unbound 'own-skill' '' '' 0

# A 600 KB quoted name (review of c699363d1 minor 2) is undecodable past
# 1024 bytes, so the name set builds in bounded time instead of timing out.
install_fixture 'otherco'
mkdir -p "$TMP/companies/otherco/skills/big"
{ printf -- '---\nname: "'; head -c 600000 /dev/zero | tr '\0' 'a'; printf '"\n---\nfixture\n'; } \
  > "$TMP/companies/otherco/skills/big/SKILL.md"
echo '[Skill tool: a very long frontmatter name]'
big_start=$SECONDS
# An unowned name, so the call reaches the name set (a core folder name skips it).
run_case 'Skill bound to otherco loads beside a 600 KB name' Skill sess-unbound 'no-such-skill' '' '' 0
checks=$((checks + 1))
if [ $((SECONDS - big_start)) -le 10 ]; then
  printf '%-52s ok\n' 'Name set with a 600 KB name builds within 10 s'
else
  fail "the name set with a 600 KB name took $((SECONDS - big_start)) s"
fi
rm -f "$TMP/workspace/sessions/sess-unbound/meta.yaml"
run_case 'Skill unbound refuses beside a 600 KB (undecodable) name' Skill sess-unbound 'no-such-skill' '' '' 2
run_case 'Skill unbound loads a core skill beside a 600 KB name' Skill sess-unbound 'own-skill' '' '' 0

# The name-set cache (review of c699363d1, present since #1862): writes into
# workspace/.scope-skill-names/ are refused, and a cache rewritten outside
# the guard no longer matches its stamp, so it is rebuilt.
install_fixture 'ownco'
add_ownco
copy_mirror otherco anatomy '---\nname: anatomy\n---\nother company copied fixture\n'
echo '[name-set cache: writes refused, outside rewrites rebuilt]'
run_case 'Skill bound to ownco refuses anatomy (builds the cache)' Skill sess-unbound 'anatomy' '' '' 2
run_case 'Bash refuses grep -v into the cache and mv' Bash sess-unbound '' '' 'grep -v otherco workspace/.scope-skill-names/v3 > workspace/t.tmp && mv workspace/t.tmp workspace/.scope-skill-names/v3' 2
run_case 'Bash refuses cp into the cache through a glob' Bash sess-unbound '' '' 'cp workspace/t.tmp workspace/.s*/v3' 2
run_case 'Bash refuses cp into the cache through a brace' Bash sess-unbound '' '' 'cp workspace/t.tmp workspace/.{scope-skill-names,x}/v3' 2
run_case 'Bash refuses rm of the stamp in another case' Bash sess-unbound '' '' 'rm workspace/.SCOPE-SKILL-NAMES/v3.stamp' 2
run_case 'Bash refuses a quoted spelling of the folder' Bash sess-unbound '' '' "mv workspace/t.tmp 'workspace/.scope-'skill-names/v3" 2
run_case 'Bash refuses ln into the cache' Bash sess-unbound '' '' 'ln -sf /tmp/x workspace/.scope-skill-names/v3' 2
run_case 'Bash refuses a read of the cache too' Bash sess-unbound '' '' 'cat workspace/.scope-skill-names/v3' 2
assert_stderr 'Bash cache refusal points reads at the Read tool' 'read the cache with the Read tool'
run_case 'Bash refuses a glob read of the cache' Bash sess-unbound '' '' 'cat workspace/.s*/v3' 2
assert_stderr 'Bash glob cache refusal points reads at the Read tool' 'read the cache with the Read tool'
run_case 'Write refuses the cache file' Write sess-unbound "$TMP/workspace/.scope-skill-names/v3" '' '' 2
run_case 'Write refuses the stamp through ..' Write sess-unbound "$TMP/workspace/x/../.scope-skill-names/v3.stamp" '' '' 2
run_case 'Read of the cache stays allowed' Read sess-unbound "$TMP/workspace/.scope-skill-names/v3" '' '' 0
run_case 'Bash glob outside the cache stays allowed' Bash sess-unbound '' '' 'rm -f workspace/*.log' 0
# Review of PR 1907 (2026-11-13): only a word that resolves into the cache is
# refused. A mention of the name or a dot glob that cannot reach it is allowed.
run_case 'Bash sed with a .* regex stays allowed' Bash sess-unbound '' '' "sed 's/.*//' notes.txt" 0
run_case 'Bash grep with a /.* regex stays allowed' Bash sess-unbound '' '' "grep -o '/.*' notes.txt" 0
run_case 'Bash ls -d .* at the HQ root stays allowed' Bash sess-unbound '' '' 'ls -d .*' 0
run_case 'Bash find -name .* stays allowed' Bash sess-unbound '' '' "find . -maxdepth 1 -name '.*'" 0
run_case 'Bash ls -la .[!.]* stays allowed' Bash sess-unbound '' '' 'ls -la .[!.]*' 0
run_case 'Bash grep for the cache name stays allowed' Bash sess-unbound '' '' 'grep -rn scope-skill-names core/' 0
run_case 'Bash echo naming the cache stays allowed' Bash sess-unbound '' '' "echo 'note about the scope-skill-names cache'" 0
run_case 'Bash refuses a redirect into the cache' Bash sess-unbound '' '' 'echo x > workspace/.scope-skill-names/v3' 2
run_case 'Bash refuses tee into the cache in upper case' Bash sess-unbound '' '' 'echo x | tee WORKSPACE/.Scope-Skill-Names/v3.stamp' 2
run_case 'Bash refuses an --opt= write into the cache' Bash sess-unbound '' '' 'curl -s --output=workspace/.scope-skill-names/v3 http://x' 2
run_case 'Bash refuses mv into the cache through ..' Bash sess-unbound '' '' 'mv /tmp/x workspace/a/../.scope-skill-names/v3' 2
run_case 'Bash refuses rm of a dot glob from inside workspace' Bash sess-unbound '' '' 'rm -rf .s*' 2 "$TMP/workspace"
run_case 'Bash refuses a glob write into the cache by absolute path' Bash sess-unbound '' '' "cp /tmp/x $TMP/workspace/.*/v3" 2
if [ -f "$TMP/workspace/.scope-skill-names/v3" ]; then
  grep -v otherco "$TMP/workspace/.scope-skill-names/v3" > "$TMP/poison.tmp"
  mv "$TMP/poison.tmp" "$TMP/workspace/.scope-skill-names/v3"
else
  fail 'the Skill call did not write workspace/.scope-skill-names/v3'
fi
run_case 'Skill refuses anatomy after an outside cache rewrite' Skill sess-unbound 'anatomy' '' '' 2
grep -v otherco "$TMP/workspace/.scope-skill-names/v3" > "$TMP/poison.tmp"
mv "$TMP/poison.tmp" "$TMP/workspace/.scope-skill-names/v3"
rm -f "$TMP/workspace/.scope-skill-names/v3.stamp"
run_case 'Skill refuses anatomy after a rewrite with no stamp' Skill sess-unbound 'anatomy' '' '' 2

# An unreadable or non-regular company SKILL.md (review of add32802a minor 4,
# b72e6a6e6 minor 3): its folder name still counts, and the pass goes on.
install_fixture ''
company_skill otherco aaa-locked '---\nname: locked-fm\n---\nfixture\n'
chmod 000 "$TMP/companies/otherco/skills/aaa-locked/SKILL.md"
copy_mirror otherco zlate '---\nname: zlate\n---\nfixture\n'
echo '[Skill tool, unbound: unreadable and FIFO SKILL.md files]'
run_case 'Skill unbound refuses a skill listed after an unreadable one' Skill sess-unbound 'zlate' '' '' 2
run_case 'Skill unbound refuses an unreadable skill by folder name' Skill sess-unbound 'aaa-locked' '' '' 2
run_case 'Skill unbound core skill loads beside an unreadable one' Skill sess-unbound 'own-skill' '' '' 0
chmod 644 "$TMP/companies/otherco/skills/aaa-locked/SKILL.md"
if command -v mkfifo >/dev/null 2>&1; then
  mkdir -p "$TMP/companies/otherco/skills/aaa-fifo"
  mkfifo "$TMP/companies/otherco/skills/aaa-fifo/SKILL.md"
  run_case 'Skill unbound unknown name passes beside a FIFO SKILL.md' Skill sess-unbound 'no-such-skill' '' '' 0
  run_case 'Skill unbound refuses a skill listed after a FIFO SKILL.md' Skill sess-unbound 'zlate' '' '' 2
  run_case 'Skill unbound refuses a FIFO skill by folder name' Skill sess-unbound 'aaa-fifo' '' '' 2
  rm -f "$TMP/companies/otherco/skills/aaa-fifo/SKILL.md"
fi

# Folders Claude Code may or may not load under the requested name (reviews
# of b72e6a6e6 critical 1 and 750863fec critical 1). An empty folder, a link
# or a folder in another case does not make the name a core skill's, so the
# name is still otherco's and is refused. A real folder of exactly that name
# with a regular SKILL.md is a core skill and loads (owner direction
# 2026-11-14; scope-skill-name-collision.test.sh has the full set).
install_fixture ''
copy_mirror otherco anatomy '---\nname: anatomy\n---\nother company copied fixture\n'
mkdir -p "$TMP/.claude/skills/signals" "$TMP/claude-config/skills"
printf -- '---\nname: signals\n---\ncore fixture\n' > "$TMP/.claude/skills/signals/SKILL.md"
echo '[Skill tool, unbound: same-name folders, links and dedup layouts]'
mkdir -p "$TMP/.claude/skills/anatomy"
run_case 'Skill unbound refuses beside an empty same-name folder' Skill sess-unbound 'anatomy' '' '' 2
mkdir -p "$TMP/.claude/skills/anatomy/SKILL.md"
run_case 'Skill unbound refuses beside a folder whose SKILL.md is a folder' Skill sess-unbound 'anatomy' '' '' 2
rm -rf "$TMP/.claude/skills/anatomy"
mkdir -p "$TMP/claude-config/skills/anatomy"
run_case 'Skill unbound refuses beside an empty user-level folder' Skill sess-unbound 'anatomy' '' '' 2
rm -rf "$TMP/claude-config/skills/anatomy"
mkdir -p "$TMP/.claude/skills/ANATOMY"
printf -- '---\nname: upper-core\n---\ncore fixture\n' > "$TMP/.claude/skills/ANATOMY/SKILL.md"
run_case 'Skill unbound refuses beside a case-variant folder' Skill sess-unbound 'anatomy' '' '' 2
rm -rf "$TMP/.claude/skills/ANATOMY"
ln -s signals "$TMP/.claude/skills/anatomy"
ln -s "$TMP/.claude/skills/signals" "$TMP/claude-config/skills/hq-signals"
run_case 'Skill unbound refuses a same-name link Claude Code dedups' Skill sess-unbound 'anatomy' '' '' 2
rm -f "$TMP/.claude/skills/anatomy"
ln -s "$TMP/.claude/skills/own-skill" "$TMP/claude-config/skills/aaa"
ln -s "$TMP/.claude/skills/own-skill" "$TMP/claude-config/skills/anatomy"
run_case 'Skill unbound refuses a user-level link sorted after its twin' Skill sess-unbound 'anatomy' '' '' 2
rm -f "$TMP/claude-config/skills/aaa" "$TMP/claude-config/skills/anatomy"
mkdir -p "$TMP/.claude/skills/anatomy"
printf -- '---\nname: anatomy\n---\nfresh core fixture\n' > "$TMP/.claude/skills/anatomy/SKILL.md"
run_case 'Skill unbound loads a real same-name core folder' Skill sess-unbound 'anatomy' '' '' 0
rm -rf "$TMP/.claude/skills/anatomy"

# Core skills whose name a company skill also carries (signals,
# work-broadcast, work-mesh on a real install) load in every session (owner
# direction 2026-11-14; before that they were refused outside the company).
# A name only the company carries is refused with a message that names the
# company skill and the two ways out.
install_fixture ''
copy_mirror otherco solo '---\nname: solo\n---\nother company copied fixture\n'
copy_mirror otherco signals '---\nname: signals\n---\nother company copied fixture\n'
mkdir -p "$TMP/.claude/skills/signals" "$TMP/claude-config/skills"
printf -- '---\nname: signals\n---\ncore fixture sharing a name\n' > "$TMP/.claude/skills/signals/SKILL.md"
ln -s "$TMP/.claude/skills/signals" "$TMP/claude-config/skills/hq-signals"
mkdir -p "$TMP/claude-config/skills/hq-otherco:signals"
printf -- '---\nname: signals\n---\nother company copied fixture\n' > "$TMP/claude-config/skills/hq-otherco:signals/SKILL.md"
echo '[Skill tool, unbound: core skill sharing a company skill name]'
run_case 'Skill unbound loads a core name a company shares' Skill sess-unbound 'signals' '' '' 0
run_case 'Skill unbound refuses a name only the company carries' Skill sess-unbound 'solo' '' '' 2
assert_stderr 'Refusal names the colliding company skill' 'Colliding company skill: otherco:solo'
assert_stderr 'Refusal names the bind command (unbound)' 'core/scripts/hq-session.sh set company_slug otherco'
assert_stderr 'Refusal mentions renaming' 'rename one of the two skills'
run_case 'Skill unbound refuses the core hq- link of that name' Skill sess-unbound 'hq-signals' '' '' 2
run_case 'Skill unbound refuses the company skill of that name' Skill sess-unbound 'otherco:signals' '' '' 2
# A plugin or pack namespace is compared by its whole name only (owner
# direction 2026-11-14; scope-guard-false-blocks.test.sh has the full set).
run_case 'Skill unbound loads a pack-prefixed name a company shares' Skill sess-unbound 'hq-core:signals' '' '' 0

install_fixture 'ownco'
add_ownco
copy_mirror otherco signals '---\nname: signals\n---\nother company copied fixture\n'
mkdir -p "$TMP/.claude/skills/signals"
printf -- '---\nname: signals\n---\ncore fixture sharing a name\n' > "$TMP/.claude/skills/signals/SKILL.md"
copy_mirror otherco solo '---\nname: solo\n---\nother company copied fixture\n'
echo '[Skill tool, bound to ownco: core skill sharing a company skill name]'
run_case 'Skill bound to ownco loads a core name otherco shares' Skill sess-unbound 'signals' '' '' 0
run_case 'Skill bound to ownco refuses a name only otherco carries' Skill sess-unbound 'solo' '' '' 2
assert_stderr 'Refusal names the add-company command (bound)' 'core/scripts/hq-session.sh add company otherco'
run_case 'Skill bound to ownco loads a core skill no company shares' Skill sess-unbound 'own-skill' '' '' 0

install_fixture 'otherco'
copy_mirror otherco signals '---\nname: signals\n---\nother company copied fixture\n'
mkdir -p "$TMP/.claude/skills/signals"
printf -- '---\nname: signals\n---\ncore fixture sharing a name\n' > "$TMP/.claude/skills/signals/SKILL.md"
echo '[Skill tool, bound to the company that shares the name]'
run_case 'Skill bound to otherco loads the shared core name' Skill sess-unbound 'signals' '' '' 0
run_case 'Skill bound to otherco loads its own skill' Skill sess-unbound 'otherco:signals' '' '' 0

# Session bound to another company (reviews of a9ac8128 through 750863fec).
install_fixture 'ownco'
add_ownco
copy_mirror otherco anatomy '---\nname: anatomy\n---\nother company copied fixture\n'
copy_mirror otherco fm '---\nname: otherco-secret\n---\nother company frontmatter fixture\n'
company_skill otherco copied '---\nname: copied-elsewhere\n---\nother company fixture\n'
company_skill otherco hidden '---\nname: hidden-fm\n---\nother company unmirrored fixture\n'
mkdir -p "$TMP/companies/otherco/.claude/skills/nested-only"
printf -- '---\nname: nested-only\n---\nother company nested fixture\n' > "$TMP/companies/otherco/.claude/skills/nested-only/SKILL.md"
copy_mirror ownco own-anatomy '---\nname: own-anatomy\n---\nown company copied fixture\n'
company_skill ownco t '---\nname: ownco-tool\n---\nown company fixture\n'
mkdir -p "$TMP/claude-config/skills/hq-otherco:copied"
printf -- '---\nname: copied-elsewhere\n---\nother company copied fixture\n' > "$TMP/claude-config/skills/hq-otherco:copied/SKILL.md"
ln -s "$TMP/.claude/skills/otherco:anatomy" "$TMP/claude-config/skills/hq-otherco:anatomy"
ln -s "$TMP/.claude/skills/ownco:own-anatomy" "$TMP/claude-config/skills/hq-ownco:own-anatomy"
ln -s "$TMP/.claude/skills/own-skill" "$TMP/claude-config/skills/hq-own-skill"
echo '[Skill tool, bound to ownco: the other company refuses, its own loads]'
run_case 'Skill bound to ownco refuses otherco colon name' Skill sess-unbound 'otherco:anatomy' '' '' 2
run_case 'Skill bound to ownco refuses otherco bare name' Skill sess-unbound 'anatomy' '' '' 2
run_case 'Skill bound to ownco refuses otherco frontmatter name' Skill sess-unbound 'otherco-secret' '' '' 2
run_case 'Skill bound to ownco refuses leading-space otherco name' Skill sess-unbound ' otherco:anatomy' '' '' 2
run_case 'Skill bound to ownco refuses user-level hq- link' Skill sess-unbound 'hq-otherco:anatomy' '' '' 2
run_case 'Skill bound to ownco refuses user-level hq- copy' Skill sess-unbound 'hq-otherco:copied' '' '' 2
run_case 'Skill bound to ownco refuses hq- copy by frontmatter' Skill sess-unbound 'copied-elsewhere' '' '' 2
run_case 'Skill bound to ownco refuses unmirrored frontmatter name' Skill sess-unbound 'hidden-fm' '' '' 2
run_case 'Skill bound to ownco refuses nested company .claude skill' Skill sess-unbound 'nested-only' '' '' 2
run_case 'Skill bound to ownco refuses dir-scoped nested skill' Skill sess-unbound 'companies/otherco:nested-only' '' '' 2
run_case 'Skill bound to ownco refuses one-segment dir-scoped name' Skill sess-unbound 'workspace:anatomy' '' '' 2
run_case 'Skill bound to ownco refuses from a workspace cwd' Skill sess-unbound 'anatomy' '' '' 2 "$TMP/workspace"
run_case 'Skill bound to ownco loads own colon name' Skill sess-unbound 'ownco:own-anatomy' '' '' 0
run_case 'Skill bound to ownco loads own bare name' Skill sess-unbound 'own-anatomy' '' '' 0
run_case 'Skill bound to ownco loads own frontmatter name' Skill sess-unbound 'ownco-tool' '' '' 0
run_case 'Skill bound to ownco loads own user-level hq- link' Skill sess-unbound 'hq-ownco:own-anatomy' '' '' 0
run_case 'Skill bound to ownco loads a core hq- link' Skill sess-unbound 'hq-own-skill' '' '' 0
run_case 'Skill bound to ownco loads a core skill' Skill sess-unbound 'own-skill' '' '' 0

# A subagent call (review of 750863fec critical 3): the rule needs no
# transcript, so a subagent is checked the same way. With no capability of
# its own or its parent's, it is unbound.
install_fixture ''
copy_mirror otherco anatomy '---\nname: anatomy\n---\nother company copied fixture\n'
# Stale mirrors (review of 4b756b911 minor 3): a copied mirror whose source
# in companies/ is gone still answers to its frontmatter name as that
# company's skill.
echo '[Skill tool: stale copied mirrors]'
mkdir -p "$TMP/.claude/skills/otherco:old" "$TMP/claude-config/skills/hq-otherco:stale"
printf -- '---\nname: old-fm\n---\nother company stale copy\n' > "$TMP/.claude/skills/otherco:old/SKILL.md"
printf -- '---\nname: stale-fm\n---\nother company stale copy\n' > "$TMP/claude-config/skills/hq-otherco:stale/SKILL.md"
run_case 'Skill unbound refuses a stale mirror by frontmatter name' Skill sess-unbound 'old-fm' '' '' 2
run_case 'Skill unbound loads the bare part of a stale mirror folder name' Skill sess-unbound 'old' '' '' 0
run_case 'Skill unbound refuses a stale mirror by its folder name' Skill sess-unbound 'otherco:old' '' '' 2
run_case 'Skill unbound refuses a stale user-level copy by name' Skill sess-unbound 'stale-fm' '' '' 2
rm -rf "$TMP/.claude/skills/otherco:old" "$TMP/claude-config/skills/hq-otherco:stale"
echo '[Skill tool: subagent call]'
CASE_AGENT_ID='agent-1' run_case 'Skill subagent refuses a company bare name' Skill sess-unbound 'anatomy' '' '' 2
CASE_AGENT_ID='agent-1' run_case 'Skill subagent loads a core skill' Skill sess-unbound 'own-skill' '' '' 0

# A company whose slug starts with hq-: `hq-<slug>:` and `<slug>:` both name it.
install_fixture ''
mkdir -p "$TMP/companies/hq-demo"
copy_mirror hq-demo tour '---\nname: tour\n---\nhq-demo fixture\n'
echo '[Skill tool: a company slug that starts with hq-]'
run_case 'Skill unbound refuses an hq- slug colon name' Skill sess-unbound 'hq-demo:tour' '' '' 2
run_case 'Skill unbound refuses an hq-hq- spelling' Skill sess-unbound 'hq-hq-demo:tour' '' '' 2
run_case 'Skill unbound refuses its bare name' Skill sess-unbound 'tour' '' '' 2

# Alias layouts (reviews of 2bf9641cb, b72e6a6e6 and 750863fec): a folder of
# another name that links to a company skill. The name rule does not follow
# links, so these are closed where the link is made: creating it names a
# company path or a copied mirror, which the path checks refuse.
install_fixture 'ownco'
add_ownco
copy_mirror otherco anatomy '---\nname: anatomy\n---\nother company copied fixture\n'
mkdir -p "$TMP/workspace/proj/.claude/skills" "$TMP/workspace/deep/sub/.claude/skills" "$TMP/.claude/commands"
echo '[alias layouts: planting the link is refused]'
run_case 'Bash refuses linking a company skill into a cwd chain' Bash sess-unbound '' '' 'ln -s ../../../../companies/otherco/skills/anatomy workspace/proj/.claude/skills/wsalias' 2
run_case 'Bash refuses linking a company skill by absolute path' Bash sess-unbound '' '' "ln -s $TMP/companies/otherco/skills/anatomy workspace/proj/.claude/skills/wsalias" 2
run_case 'Bash refuses linking a copied mirror as an alias' Bash sess-unbound '' '' 'ln -s otherco:anatomy .claude/skills/alias' 2 "$TMP/.claude/skills"
run_case 'Bash refuses linking a copied mirror into workspace' Bash sess-unbound '' '' "ln -s $TMP/.claude/skills/otherco:anatomy workspace/deep/sub/.claude/skills/mirroralias" 2
run_case 'Bash refuses copying a copied mirror' Bash sess-unbound '' '' 'cp -R .claude/skills/otherco:anatomy workspace/proj/.claude/skills/copyalias' 2
run_case 'Bash refuses linking a company SKILL.md as a command' Bash sess-unbound '' '' 'ln -s ../../companies/otherco/skills/anatomy/SKILL.md .claude/commands/cmdalias.md' 2

# Copied mirrors read directly (review of 750863fec, gap on main): a Read,
# cat or Grep of .claude/skills/<slug>:x or a user-level hq-<slug>:x copy is
# that company's path.
install_fixture ''
rm -f "$TMP/.claude/skills/otherco:s"
copy_mirror otherco anatomy '---\nname: anatomy\n---\nother company copied fixture\n'
mkdir -p "$TMP/claude-config/skills/hq-otherco:copied" "$TMP/.claude/skills/hq-otherco:hqcopy" "$TMP/companies/hq-demo"
printf 'other company copied fixture\n' > "$TMP/claude-config/skills/hq-otherco:copied/SKILL.md"
printf 'other company copied fixture\n' > "$TMP/.claude/skills/hq-otherco:hqcopy/SKILL.md"
copy_mirror hq-demo tour '---\nname: tour\n---\nhq-demo fixture\n'
echo '[copied mirrors, unbound: Read, cat and Grep are refused]'
run_case 'Read copied mirror by absolute path' Read sess-unbound "$TMP/.claude/skills/otherco:anatomy/SKILL.md" '' '' 2
assert_stderr 'Mirror refusal names the company' 'Target company: otherco'
run_case 'Read copied mirror by relative path' Read sess-unbound '.claude/skills/otherco:anatomy/SKILL.md' '' '' 2
run_case 'Read copied mirror with upper-case slug' Read sess-unbound '.claude/skills/OtherCo:anatomy/SKILL.md' '' '' 2
run_case 'Read hq- copy inside .claude/skills' Read sess-unbound '.claude/skills/hq-otherco:hqcopy/SKILL.md' '' '' 2
run_case 'Read user-level hq- copy' Read sess-unbound "$TMP/claude-config/skills/hq-otherco:copied/SKILL.md" '' '' 2
run_case 'Read copied mirror of an hq- slug company' Read sess-unbound '.claude/skills/hq-demo:tour/SKILL.md' '' '' 2
run_case 'Bash cat copied mirror' Bash sess-unbound '' '' 'cat .claude/skills/otherco:anatomy/SKILL.md' 2
run_case 'Bash cat copied mirror by absolute path' Bash sess-unbound '' '' "cat $TMP/.claude/skills/otherco:anatomy/SKILL.md" 2
run_case 'Bash cat a glob over copied mirrors' Bash sess-unbound '' '' 'cat .claude/skills/*/SKILL.md' 2
run_case 'Bash cat user-level hq- copy' Bash sess-unbound '' '' "cat $TMP/claude-config/skills/hq-otherco:copied/SKILL.md" 2
run_case 'Grep in a copied mirror' Grep sess-unbound '.claude/skills/otherco:anatomy' '' '' 2
run_case 'Grep over the skills folder holding a copied mirror' Grep sess-unbound '.claude/skills' '' '' 2
run_case 'Grep in a user-level hq- copy' Grep sess-unbound "$TMP/claude-config/skills/hq-otherco:copied" '' '' 2
# Shell quoting and braces (review of 4b756b911 minor 1): the mirror check
# reads the word's value after quote removal and brace expansion.
echo '[copied mirrors, unbound: quoted, escaped and brace spellings]'
run_case 'Bash cat mirror with an escaped colon' Bash sess-unbound '' '' 'cat .claude/skills/otherco\:anatomy/SKILL.md' 2
run_case 'Bash cat mirror with an escaped letter in skills' Bash sess-unbound '' '' 'cat .claude/sk\ills/otherco:anatomy/SKILL.md' 2
run_case 'Bash cat mirror with empty double quotes' Bash sess-unbound '' '' 'cat .claude/skills/otherco"":anatomy/SKILL.md' 2
run_case 'Bash cat mirror with a single-quoted colon' Bash sess-unbound '' '' "cat .claude/skills/otherco':'anatomy/SKILL.md" 2
run_case 'Bash cat mirror with an ANSI-C colon' Bash sess-unbound '' '' "cat .claude/skills/otherco\$':'anatomy/SKILL.md" 2
run_case 'Bash cat mirror with an ANSI-C hex escape' Bash sess-unbound '' '' "cat .claude/skills/otherco\$'\\x3a'anatomy/SKILL.md" 2
run_case 'Bash cat mirror through a brace list' Bash sess-unbound '' '' 'cat .claude/skills/{otherco:anatomy,x}/SKILL.md' 2
run_case 'Bash cat mirror through a brace in the slug' Bash sess-unbound '' '' 'cat .claude/skills/other{co,}:anatomy/SKILL.md' 2
run_case 'Bash -c cat mirror with an escaped colon' Bash sess-unbound '' '' "bash -c 'cat .claude/skills/otherco\\:anatomy/SKILL.md'" 2
run_case 'Bash quoted core skill path stays allowed' Bash sess-unbound '' '' 'cat ".claude/skills/own-skill/SKILL.md"' 0
run_case 'Bash brace list of core skills stays allowed' Bash sess-unbound '' '' 'ls .claude/skills/{own-skill,x}' 0
# Empty, `.` and `<dir>/..` segments before a quoted mirror name, and xargs
# placeholders next to a skills path (review of e93e1c63e minor 1).
mkdir -p "$TMP/.claude/skills/signals"
printf 'core fixture\n' > "$TMP/.claude/skills/signals/SKILL.md"
echo '[copied mirrors, unbound: path spellings before a quoted mirror name]'
run_case 'Bash cat mirror after a doubled slash' Bash sess-unbound '' '' 'cat .claude/skills//otherco\:anatomy/SKILL.md' 2
run_case 'Bash cat mirror after a dot segment' Bash sess-unbound '' '' 'cat .claude/skills/./otherco"":anatomy/SKILL.md' 2
run_case 'Bash cat mirror after a dir/.. segment' Bash sess-unbound '' '' 'cat .claude/skills/signals/../otherco\:anatomy/SKILL.md' 2
run_case 'Bash cat mirror after two dir/.. segments' Bash sess-unbound '' '' 'cat .claude/skills/a/b/../../otherco\:anatomy/SKILL.md' 2
run_case 'Bash cat mirror after slashes and dots' Bash sess-unbound '' '' 'cat .claude//skills///./otherco""\:anatomy/SKILL.md' 2
run_case 'Bash cat mirror after ../../skills//' Bash sess-unbound '' '' 'cat .claude/skills/own-skill/../../skills//otherco\:anatomy/SKILL.md' 2
run_case 'Bash cd into a mirror after a doubled slash' Bash sess-unbound '' '' 'cd .claude/skills//otherco\:anatomy && cat SKILL.md' 2
run_case 'Bash cd into a mirror after a dot segment' Bash sess-unbound '' '' 'cd .claude/skills/./otherco"":anatomy && cat SKILL.md' 2
run_case 'Bash cd into a mirror after a dir/.. segment' Bash sess-unbound '' '' 'cd .claude/skills/signals/../otherco\:anatomy && cat SKILL.md' 2
run_case 'Bash cp -R a mirror after a doubled slash' Bash sess-unbound '' '' 'cp -R .claude/skills//otherco\:anatomy /tmp/x' 2
run_case 'Bash cp -R a mirror after a dot segment' Bash sess-unbound '' '' 'cp -R .claude/skills/./otherco"":anatomy /tmp/x' 2
run_case 'Bash cp -R a mirror after a dir/.. segment' Bash sess-unbound '' '' 'cp -R .claude/skills/signals/../otherco\:anatomy /tmp/x' 2
run_case 'Bash xargs -I{} placeholder after a slug' Bash sess-unbound '' '' 'echo :anatomy/SKILL.md | xargs -I{} cat .claude/skills/otherco{}'  2
run_case 'Bash xargs -I {} placeholder as the folder' Bash sess-unbound '' '' 'echo otherco:anatomy/SKILL.md | xargs -I {} cat .claude/skills/{}' 2
run_case 'Bash xargs --replace placeholder after a slug' Bash sess-unbound '' '' 'echo :anatomy/SKILL.md | xargs --replace cat .claude/skills/otherco{}' 2
run_case 'Bash xargs placeholder inside a core skill folder' Bash sess-unbound '' '' 'echo ../otherco:anatomy/SKILL.md | xargs -I{} cat .claude/skills/own-skill/{}' 2
run_case 'Bash doubled slash before a core skill stays allowed' Bash sess-unbound '' '' 'cat .claude/skills//own-skill/SKILL.md' 0
run_case 'Bash quoted dir/.. before a core skill stays allowed' Bash sess-unbound '' '' 'cat ".claude/skills/signals/../own-skill/SKILL.md"' 0
run_case 'Bash quoted dot segment before a core skill stays allowed' Bash sess-unbound '' '' 'cat ".claude/skills/./own-skill/SKILL.md"' 0
# The five commands from the review of c699363d1 (trade-off a): a ${name}
# expansion and JSON punctuation are not literal braces; a literal brace
# and a python template are still refused, like the companies/ forms.
echo '[copied mirrors, unbound: ${name}, JSON punctuation and literal braces]'
run_case 'Bash ${n} in a quoted core skill path stays allowed' Bash sess-unbound '' '' 'n=own-skill; cat ".claude/skills/${n}/SKILL.md"' 0
run_case 'Bash ${n} in a for loop over core skills stays allowed' Bash sess-unbound '' '' 'for n in own-skill signals; do head -2 ".claude/skills/${n}/SKILL.md"; done' 0
run_case 'Bash jq object naming a core skill path stays allowed' Bash sess-unbound '' '' "jq '{path: \".claude/skills/own-skill\"}' /dev/null" 0
run_case 'Bash python f-string template in a skills path is refused' Bash sess-unbound '' '' "python3 -c 'n=\"own-skill\"; print(open(f\".claude/skills/{n}/SKILL.md\").read())'" 2
run_case 'Bash literal {name} in a skills path is refused' Bash sess-unbound '' '' 'ls .claude/skills/{own-skill}' 2
run_case 'Bash ${n} holding a mirror name is refused' Bash sess-unbound '' '' 'n=otherco:anatomy; cat ".claude/skills/${n}/SKILL.md"' 2
run_case 'Bash jq object naming a mirror path is refused' Bash sess-unbound '' '' "jq '{path: \".claude/skills/otherco:anatomy\"}' /dev/null" 2
echo '[copied mirrors, unbound: core skills stay readable]'
run_case 'Read core skill beside copied mirrors' Read sess-unbound '.claude/skills/own-skill/SKILL.md' '' '' 0
run_case 'Bash cat core skill beside copied mirrors' Bash sess-unbound '' '' 'cat .claude/skills/own-skill/SKILL.md' 0
run_case 'Grep core skill beside copied mirrors' Grep sess-unbound '.claude/skills/own-skill' '' '' 0
run_case 'Read a pack-named folder with no company' Read sess-unbound '.claude/skills/hq-pack-cowork:x/SKILL.md' '' '' 0

install_fixture 'ownco'
add_ownco
rm -f "$TMP/.claude/skills/otherco:s"
copy_mirror otherco anatomy '---\nname: anatomy\n---\nother company copied fixture\n'
copy_mirror ownco own-anatomy '---\nname: own-anatomy\n---\nown company copied fixture\n'
echo '[copied mirrors, bound to ownco]'
run_case 'Read otherco copied mirror bound to ownco' Read sess-unbound '.claude/skills/otherco:anatomy/SKILL.md' '' '' 2
run_case 'Bash cat otherco copied mirror bound to ownco' Bash sess-unbound '' '' 'cat .claude/skills/otherco:anatomy/SKILL.md' 2
run_case 'Grep otherco copied mirror bound to ownco' Grep sess-unbound '.claude/skills/otherco:anatomy' '' '' 2
run_case 'Bash cat otherco mirror after a doubled slash bound to ownco' Bash sess-unbound '' '' 'cat .claude/skills//otherco\:anatomy/SKILL.md' 2
run_case 'Bash cat own mirror after a doubled slash bound to ownco' Bash sess-unbound '' '' 'cat .claude/skills//ownco\:own-anatomy/SKILL.md' 0
run_case 'Read own copied mirror bound to ownco' Read sess-unbound '.claude/skills/ownco:own-anatomy/SKILL.md' '' '' 0
run_case 'Bash cat own copied mirror bound to ownco' Bash sess-unbound '' '' 'cat .claude/skills/ownco:own-anatomy/SKILL.md' 0
run_case 'Grep own copied mirror bound to ownco' Grep sess-unbound '.claude/skills/ownco:own-anatomy' '' '' 0

install_fixture 'otherco'
copy_mirror otherco anatomy '---\nname: anatomy\n---\nother company copied fixture\n'
echo '[copied mirrors, bound to the owning company]'
run_case 'Read copied mirror bound to its company' Read sess-unbound '.claude/skills/otherco:anatomy/SKILL.md' '' '' 0
run_case 'Grep over the skills folder bound to its company' Grep sess-unbound '.claude/skills' '' '' 0
run_case 'Bash cat mirror after a dir/.. segment bound to its company' Bash sess-unbound '' '' 'cat .claude/skills/x/../otherco\:anatomy/SKILL.md' 0

echo "Checks: $checks; failures: $failures"
[ "$failures" -eq 0 ]
