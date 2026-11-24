#!/usr/bin/env bash
# hq-core: public
# Ordinary calls the scope guard used to refuse: a bound company's own skill
# and a plugin or pack skill when another company has a skill of the same
# bare name, and a multi-line interpreter one-liner. The neighbouring
# refusals stay.

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

skill_md() { # <folder> <frontmatter name>
  mkdir -p "$1"
  printf -- '---\nname: %s\ndescription: fixture\n---\nfixture body\n' "$2" > "$1/SKILL.md"
}
link_mirror() { # <mirror folder> <source folder, relative to the HQ root>
  mkdir -p "$1"
  ln -s "../../../$2/SKILL.md" "$1/SKILL.md"
}

install_fixture() { # [bound company]
  local bound="${1:-}" hook_source="${SCOPE_HOOK_SOURCE:-$ROOT/.claude/hooks/mandatory-scope-authorizer.sh}"
  rm -rf "$TMP/.claude" "$TMP/core" "$TMP/companies" "$TMP/workspace" "$TMP/personal" "$TMP/claude-config"
  mkdir -p "$TMP/.claude/hooks" "$TMP/.claude/skills" "$TMP/core/scripts/lib" \
    "$TMP/workspace/sessions/sess-1" "$TMP/workspace/proj" "$TMP/personal" "$TMP/claude-config/skills" \
    "$TMP/companies/otherco/skills" "$TMP/companies/ownco/skills"
  cp "$hook_source" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh"
  cp "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$TMP/.claude/hooks/"
  cp "$ROOT/core/scripts/lib/session-authz.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-id.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/"
  printf 'companies:\n  otherco:\n    name: otherco\n  ownco:\n    name: ownco\n' > "$TMP/companies/manifest.yaml"
  # Both companies have skills called signals and pdf.
  skill_md "$TMP/companies/ownco/skills/signals" signals
  link_mirror "$TMP/.claude/skills/ownco:signals" companies/ownco/skills/signals
  skill_md "$TMP/companies/otherco/skills/signals" signals
  link_mirror "$TMP/.claude/skills/otherco:signals" companies/otherco/skills/signals
  skill_md "$TMP/companies/otherco/skills/pdf" pdf
  link_mirror "$TMP/.claude/skills/otherco:pdf" companies/otherco/skills/pdf
  # A copied mirror of ownco, and one whose SKILL.md points at otherco.
  skill_md "$TMP/companies/ownco/skills/copied" pdf
  skill_md "$TMP/.claude/skills/ownco:copied" pdf
  mkdir -p "$TMP/.claude/skills/ownco:crossed"
  ln -s ../../../companies/otherco/skills/pdf/SKILL.md "$TMP/.claude/skills/ownco:crossed/SKILL.md"
  if [ -n "$bound" ]; then
    printf 'company_slug: %s\n' "$bound" > "$TMP/workspace/sessions/sess-1/meta.yaml"
  fi
}

run_case() { # <label> <tool> <skill name or command> <expected exit> [cwd]
  local label="$1" tool="$2" arg="$3" expected="$4" cwd="${5:-$TMP}"
  local tool_input payload rc=0 stderr_file
  checks=$((checks + 1))
  stderr_file="$TMP/stderr-$checks"
  case "$tool" in
    Skill) tool_input="$(jq -cn --arg v "$arg" '{skill:$v}')" ;;
    Bash) tool_input="$(jq -cn --arg v "$arg" '{command:$v}')" ;;
    *) fail "$label has unsupported tool $tool"; return ;;
  esac
  payload="$(jq -cn --arg tool "$tool" --arg cwd "$cwd" --argjson input "$tool_input" \
    '{tool_name:$tool,session_id:"sess-1",cwd:$cwd,tool_input:$input}')"
  printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$TMP/claude-config" CLAUDE_PROJECT_DIR="$TMP" \
    bash "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" 2>"$stderr_file" || rc=$?
  printf '%-66s exit=%s\n' "$label" "$rc"
  if [ "$rc" -ne "$expected" ]; then
    fail "$label expected exit $expected, got $rc: $(head -c 300 "$stderr_file" | tr '\n' ' ')"
  elif [ "$expected" -eq 2 ] && ! grep -q 'Cross-company scope violation' "$stderr_file"; then
    fail "$label was denied without the cross-company message"
  fi
}

install_fixture ownco
echo '[bound to ownco: its own skills load whatever otherco names its skills]'
run_case 'own skill loads when another company has that bare name' Skill 'ownco:signals' 0
run_case 'own copied mirror loads when another company has its frontmatter name' Skill 'ownco:copied' 0
run_case 'own-named mirror whose SKILL.md is another company file is refused' Skill 'ownco:crossed' 2
run_case 'the other company skill of that name is refused' Skill 'otherco:signals' 2
run_case 'the bare name both companies carry is refused' Skill 'signals' 2
echo '[bound to ownco: plugin and pack namespaces]'
run_case 'plugin skill loads when a company has that bare name' Skill 'anthropic-skills:pdf' 0
run_case 'pack-style name with no folder loads' Skill 'hq-pack-docs:pdf' 0
run_case 'bare name only the other company carries is refused' Skill 'pdf' 2
run_case 'company prefix inside a plugin-style name is refused' Skill 'plugin:otherco:pdf' 2
run_case 'hq- company prefix is refused' Skill 'hq-otherco:pdf' 2
run_case 'directory-scoped name keeps every spelling' Skill 'workspace:pdf' 2
run_case 'directory-scoped name from a cwd folder keeps every spelling' Skill 'proj:pdf' 2 "$TMP/workspace"
run_case 'directory path prefix keeps every spelling' Skill 'workspace/proj:pdf' 2
run_case 'upper-case plugin prefix still compares the whole name only' Skill 'Anthropic-Skills:pdf' 0
run_case 'malformed double-colon name keeps every spelling' Skill 'x::pdf' 2
run_case 'malformed colon-slash name keeps every spelling' Skill 'x:/pdf' 2
mkdir -p "$TMP/companies/otherco/projects" "$TMP/elsewhere/sub"
run_case 'a prefix that is a folder inside a company keeps every spelling' Skill 'projects:pdf' 2
run_case 'a prefix that is a folder of the project dir keeps every spelling' Skill 'workspace:pdf' 2 "$TMP/elsewhere"
# A company skill whose frontmatter name is the whole plugin-style name.
skill_md "$TMP/companies/otherco/skills/squat" 'anthropic-skills:pdf'
run_case 'plugin name a company frontmatter carries whole is refused' Skill 'anthropic-skills:pdf' 2
rm -rf "$TMP/companies/otherco/skills/squat"
# An undecodable company name still refuses a name no folder owns.
skill_md "$TMP/companies/otherco/skills/flow" '[flowname]'
run_case 'plugin name is refused beside an undecodable company name' Skill 'anthropic-skills:pdf' 2
run_case 'own skill folder still loads beside an undecodable company name' Skill 'ownco:signals' 0

install_fixture ''
echo '[unbound: every company is out of scope]'
run_case 'unbound: a company mirror is refused' Skill 'ownco:signals' 2
run_case 'unbound: plugin skill loads when a company has that bare name' Skill 'anthropic-skills:pdf' 0
run_case 'unbound: bare company name is refused' Skill 'pdf' 2

install_fixture ownco
echo '[a multi-line interpreter one-liner is program text, not a glob qualifier]'
printf '{}\n' > "$TMP/workspace/x.json"
py_multi='python3 -c "import json,sys
def k(v,p=\"\"):
    return v
" < workspace/x.json'
py_plain="python3 -c \"import json,sys
def k(v,p=''):
    if isinstance(v,dict):
        for k2 in v: k(v[k2],p+k2+'.')
    else: print(p)
k(json.load(sys.stdin))\" < workspace/x.json"
run_case 'multi-line python -c with k(v[k2],p+k2+.) passes' Bash "$py_plain" 0
run_case 'single-line python -c with the same call passes' Bash "python3 -c \"def k(v,p,k): return k(v,p+k+'.')\"" 0
run_case 'multi-line node -e passes' Bash "node -e \"const f=(v,e)=>v.map(k=>
  e+k+'/');
console.log(f(['a'],'x'))\"" 0
run_case 'a real zsh code qualifier is still refused' Bash 'ls workspace/*(e:REPLY=companies/otherco:)' 2
run_case 'a qualifier on the line after a python -c is still refused' Bash "python3 -c 'print(1)'
ls workspace/*(e:REPLY=companies/otherco:)" 2
run_case 'a qualifier beside a multi-line python -c is still refused' Bash "python3 -c \"print(1)
print(2)\"; ls workspace/*(+fn)" 2
run_case 'a multi-line program with an escaped quote is not dropped' Bash "$py_multi; ls workspace/*(+fn)" 2
run_case 'a company path in a multi-line python -c is still refused' Bash "python3 -c \"import os
print(open('companies/otherco/skills/pdf/SKILL.md').read())\"" 2

echo "[a python -c program quoted by shlex.quote is program text, not a glob qualifier]"
# A sandboxed agent runs terminal('python3 -c ' + shlex.quote(code)). Each
# apostrophe in the code becomes '"'"', so the program is several quoted
# pieces. print(r.stdout+r.stderr) in it used to read as the zsh (+fn) qualifier.
sq_prog="python3 -c 'import subprocess
r=subprocess.run(['\"'\"'hq'\"'\"','\"'\"'x'\"'\"'],capture_output=True,text=True)
print(r.stdout+r.stderr)
'"
run_case 'shlex-quoted multi-line python -c with print(r.stdout+r.stderr) passes' Bash "$sq_prog" 0
run_case 'shlex-quoted single-line python -c with the same call passes' Bash "python3 -c 'r=run('\"'\"'x'\"'\"');print(r.stdout+r.stderr);x=1'" 0
run_case 'a qualifier after a shlex-quoted python -c is still refused' Bash "$sq_prog; ls workspace/*(+fn)" 2
run_case 'a qualifier on the line after a shlex-quoted python -c is still refused' Bash "python3 -c 'print('\"'\"'a'\"'\"')'
ls workspace/*(e:REPLY=companies/otherco:)" 2
run_case 'a double-quoted variable piece keeps the program from being dropped' Bash "python3 -c 'print(r.stdout+r.stderr)'\"\$X\"'x'; ls workspace/*(+fn)" 2
run_case 'a shlex-quoted python -c beside a backtick substitution is not dropped' Bash "python3 -c 'print('\"'\"'a'\"'\"')'; echo \`true\`; ls workspace/*(+fn)" 2
run_case 'a shlex-quoted python -c inside a substitution is not dropped' Bash "x=\$(python3 -c 'print('\"'\"'a'\"'\"')'); ls workspace/*(+fn)" 2
run_case 'a company path in a shlex-quoted python -c is still refused' Bash "python3 -c 'print(open('\"'\"'companies/otherco/skills/pdf/SKILL.md'\"'\"').read())'" 2

echo "[a quoted heredoc writing a script for python/node is literal text, not a zsh glob qualifier]"
hd_write_run="$(cat <<'HD_END'
cat <<'PYEOF' > workspace/proj/ad_detail.py
result = get(time_range=rng, fields=F, limit=200)
PYEOF
python3 workspace/proj/ad_detail.py
HD_END
)"
hd_tab_run="$(cat <<'HD_END'
cat <<-"PYEOF" > workspace/proj/ad_detail.py
	result = get(time_range=rng, fields=F, limit=200)
	PYEOF
python3 workspace/proj/ad_detail.py
HD_END
)"
hd_otherco="$(cat <<'HD_END'
cat <<'PYEOF' > workspace/proj/ad_detail.py
print(open("companies/otherco/skills/pdf/SKILL.md").read())
PYEOF
python3 workspace/proj/ad_detail.py
HD_END
)"
hd_zsh_run="$(cat <<'HD_END'
cat <<'SHEOF' > workspace/proj/run.sh
ls workspace/*(e:REPLY=companies/otherco:)
SHEOF
zsh workspace/proj/run.sh
HD_END
)"
hd_direct_exec="$(cat <<'HD_END'
cat <<'SHEOF' > workspace/proj/run.sh
ls workspace/*(e:REPLY=companies/otherco:)
SHEOF
./workspace/proj/run.sh
HD_END
)"
hd_outside_qual="$(cat <<'HD_END'
cat <<'PYEOF' > workspace/proj/ad_detail.py
x = 1
PYEOF
ls workspace/*(e:REPLY=companies/otherco:)
HD_END
)"
hd_unquoted="$(cat <<'HD_END'
cat <<PYEOF > workspace/proj/ad_detail.py
result = get(time_range=rng, fields=F, limit=200)
PYEOF
python3 workspace/proj/ad_detail.py
HD_END
)"
hd_abs_shell="$(cat <<'HD_END'
cat <<'SHEOF' > workspace/proj/run.sh
ls workspace/*(e:REPLY=x:)
SHEOF
/bin/zsh workspace/proj/run.sh
HD_END
)"
hd_no_dot_exec="$(cat <<'HD_END'
cat <<'SHEOF' > workspace/proj/run.sh
ls workspace/*(e:REPLY=x:)
SHEOF
chmod +x workspace/proj/run.sh; workspace/proj/run.sh
HD_END
)"
hd_abs_exec="$(cat <<HD_END
cat <<'SHEOF' > workspace/proj/run.sh
ls workspace/*(e:REPLY=x:)
SHEOF
"$TMP/workspace/proj/run.sh"
HD_END
)"
hd_quoted_shell="$(cat <<'HD_END'
cat <<'SHEOF' > workspace/proj/run.sh
ls workspace/*(e:REPLY=x:)
SHEOF
python3 -c 'import os; os.system("zsh workspace/proj/run.sh")'
HD_END
)"
hd_procsub_in="$(cat <<'HD_END'
cat <<'A' > workspace/proj/run.sh
ls workspace/*(e:REPLY=x:)
A
cat <<'B' > workspace/proj/x.py <(zsh workspace/proj/run.sh)
x
B
HD_END
)"
hd_procsub_out="$(cat <<'HD_END'
cat <<'A' > workspace/proj/run.sh
ls workspace/*(e:REPLY=x:)
A
cat <<'B' > workspace/proj/x.py >(zsh workspace/proj/run.sh)
x
B
HD_END
)"
hd_backtick_writer="$(cat <<'HD_END'
cat <<'A' > workspace/proj/run.sh
ls workspace/*(e:REPLY=x:)
A
cat <<'B' > workspace/proj/x.py `zsh workspace/proj/run.sh`
x
B
HD_END
)"
hd_cmdsub_writer="$(cat <<'HD_END'
cat <<'A' > workspace/proj/run.sh
ls workspace/*(e:REPLY=x:)
A
cat <<'B' > workspace/proj/x.py $(zsh workspace/proj/run.sh)
x
B
HD_END
)"
run_case 'quoted heredoc writing Python with t(time_range=rng,...) + python3 passes' Bash "$hd_write_run" 0
run_case 'tab-stripped double-quoted heredoc writing Python + python3 passes' Bash "$hd_tab_run" 0
run_case 'cross-company path inside quoted heredoc Python + python3 is still refused' Bash "$hd_otherco" 2
run_case 'quoted heredoc executed by zsh with glob qualifier is still refused' Bash "$hd_zsh_run" 2
run_case 'quoted heredoc executed directly via ./ with glob qualifier is still refused' Bash "$hd_direct_exec" 2
run_case 'zsh glob qualifier outside quoted heredoc is still refused' Bash "$hd_outside_qual" 2
run_case 'unquoted heredoc with qualifier-like text + python3 is still refused' Bash "$hd_unquoted" 2
run_case 'quoted heredoc executed by absolute /bin/zsh path is still refused' Bash "$hd_abs_shell" 2
run_case 'quoted heredoc executed via chmod +x without ./ is still refused' Bash "$hd_no_dot_exec" 2
run_case 'quoted heredoc executed via absolute path without ./ is still refused' Bash "$hd_abs_exec" 2
run_case 'quoted heredoc executed via python3 -c os.system(zsh) is still refused' Bash "$hd_quoted_shell" 2
run_case 'quoted heredoc followed by <(zsh ...) on second writer line is still refused' Bash "$hd_procsub_in" 2
run_case 'quoted heredoc followed by >(zsh ...) on second writer line is still refused' Bash "$hd_procsub_out" 2
run_case 'quoted heredoc followed by backtick zsh on second writer line is still refused' Bash "$hd_backtick_writer" 2
run_case 'quoted heredoc followed by $(zsh ...) on second writer line is still refused' Bash "$hd_cmdsub_writer" 2

echo "Checks: $checks; failures: $failures"
[ "$failures" -eq 0 ]
