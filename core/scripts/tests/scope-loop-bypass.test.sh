#!/usr/bin/env bash
# hq-core: public
# Regression tests: loop-variable and recursive-glob paths into another
# company must be refused by .claude/hooks/mandatory-scope-authorizer.sh.
# Every command below is fed to the hook as JSON tool input; none is run.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
FAILURES=0

mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts/lib" "$TMP/.codex/hooks" \
  "$TMP/companies/indigo/settings" "$TMP/companies/indigo/projects/a" \
  "$TMP/companies/indigo/projects/b" "$TMP/companies/otherco/settings" \
  "$TMP/workspace/sessions/sess-bound" "$TMP/workspace/reports" \
  "$TMP/personal" "$TMP/home/.hq"
cp "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$TMP/.claude/hooks/"
for f in session-authz.sh session-scope-capability.sh hook-caller-lineage.sh session-id.sh; do
  cp "$ROOT/core/scripts/lib/$f" "$TMP/core/scripts/lib/"
done
cp "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/"
cp "$ROOT/.codex/hooks/codex-explicit-path-flag.cjs" "$TMP/.codex/hooks/"
printf 'companies:\n  indigo:\n    name: Indigo\n  otherco:\n    name: otherco\n' > "$TMP/companies/manifest.yaml"
printf 'sess-bound\n' > "$TMP/workspace/sessions/.current"
printf 'company_slug: indigo\n' > "$TMP/workspace/sessions/sess-bound/meta.yaml"
touch "$TMP/companies/indigo/projects/a/README.md" "$TMP/companies/indigo/projects/b/README.md" \
  "$TMP/companies/otherco/settings/x.yaml" "$TMP/workspace/reports/r1.md"
# A symlinked directory inside the bound company that points at another
# company: zsh `***` would follow it.
ln -s ../../otherco "$TMP/companies/indigo/projects/link"
export HOME="$TMP/home"
# shellcheck source=../lib/session-scope-capability.sh
. "$ROOT/core/scripts/lib/session-scope-capability.sh"
session_scope_mint "$TMP" "sess-bound" "indigo" >/dev/null 2>&1

check() {
  local expected="$1" cmd="$2" payload rc=0
  payload="$(jq -nc --arg c "$cmd" --arg cwd "$TMP" \
    '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$c}}')"
  printf '%s' "$payload" | "${BASH_BIN:-bash}" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$expected" ]; then
    echo "PASS: [$expected] $cmd"
  else
    echo "FAIL: expected $expected got $rc: $cmd" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

echo "[a] '..' after a loop variable bound to the session's company"
check 2 'for d in companies/indigo; do cp a.txt $d/../otherco/x; done'
check 2 'for d in companies/indigo; do cp a.txt "$d/../otherco/x"; done'
check 2 'for d in companies/indigo; do cp a.txt ${d}/../otherco/x; done'
check 2 'for d in companies/indigo; do cp a.txt "$d"/../otherco/x; done'
check 2 'for d in companies/indigo; do touch $d/../otherco/x; done'
check 2 'for d in companies/indigo; do echo x > $d/../otherco/x; done'
check 2 'for d in companies/indigo; do echo x >> "${d}/../otherco/x"; done'
check 2 'for d in companies/indigo; do cp a.txt $d/..; done'
check 2 'for d in companies/indigo/projects; do echo hi; cp a.txt $d/../../otherco/x; done'
check 2 'for d in companies/indigo/projects/a; do cp a.txt $d/sub/../../../../otherco/x; done'
check 2 'for d in a b; do cp x companies/indigo/projects/$d/../../../otherco/y; done'
check 2 'for d in companies/indigo
do
  cp a.txt $d/../otherco/x
done'

echo "[b] the loop variable rebound inside the body"
check 2 'for d in companies/indigo; do read d; cp a.txt $d/x; done'
check 2 'for d in companies/indigo; do "read" d; cp a.txt $d/x; done'
check 2 'for d in companies/indigo; do echo hi; "read" d; cp a.txt $d/x; done'
check 2 "for d in companies/indigo; do 'read' -r d; cp a.txt \$d/x; done"
check 2 'for d in companies/indigo; do r\ead d; cp a.txt $d/x; done'
check 2 'for d in companies/indigo; do read -r d
cp a.txt $d/x; done'
check 2 'for d in companies/indigo; do IFS= read -r d < list.txt; cp a.txt $d/x; done'
check 2 'for d in companies/indigo; do mapfile -t d < list.txt; cp a.txt $d/x; done'
check 2 'for d in companies/indigo; do readarray d < list.txt; cp a.txt $d/x; done'
check 2 'for d in companies/indigo; do printf -v d %s z; cp a.txt $d/x; done'
check 2 'for d in companies/indigo; do printf -vd %s z; cp a.txt $d/x; done'
check 2 'for d in companies/indigo; do declare d=z; cp a.txt $d/x; done'
check 2 'for d in companies/indigo; do typeset d; cp a.txt $d/x; done'
check 2 'f() { for d in companies/indigo; do local d=z; cp a.txt $d/x; done; }; f'
check 2 'for d in companies/indigo; do d[0]=z; cp a.txt $d/x; done'
check 2 'for d in companies/indigo; do "d"=z; cp a.txt $d/x; done'
check 2 'for d in companies/indigo; do : ${d:=z}; cp a.txt $d/x; done'
check 2 'for d in companies/indigo; do r=read; $r d; cp a.txt $d/x; done'
check 2 'for d in companies/indigo; do wait -p d; cp a.txt $d/x; done'
check 2 'for d in indigo; do cp x companies/$d:h/otherco/; done'
check 2 'for d in indigo; do cat companies/$d:h/otherco/settings/x.yaml; done'
check 2 'for d in indigo; do echo x > companies/$d:h/otherco/y; done'
check 2 'for d in indigo; do cp x companies/$d:s/indigo/otherco/; done'
check 2 'for d in indigo; do cp x companies/$d:gs/i/o/; done'
check 2 'for d in companies/indigo; do cp x $d:h/otherco/; done'
check 2 'for d in a; do cp x companies/indigo/projects/$d:h/../../otherco/; done'
check 2 'for d in indigo; do cp x companies/${d:h}/otherco/; done'
check 2 'd=indigo; cp x companies/$d:h/otherco/'
check 2 'cp x *(e:REPLY=companies/otherco:)'
check 2 'cp x *(.e:REPLY=companies/otherco:)'
check 2 'cp x *(+fn)'
check 2 'p=companies/indigo; cp x ${(j:/:)p}/../otherco/'
check 2 'p=companies/indigo; cp x ${(e)p}/../otherco/'
check 2 'p=companies/indigo; echo hi > ${(e)p}/../otherco/f'
check 2 'p=COMPANIES/OTHERCO; cp x ${(L)p}/'
check 2 'p=companies/indigo; cp x $p[1,10]otherco/'
check 2 'p=companies/indigo; cat $p[1,10]otherco/settings/x'
check 2 'p=companies/indigo; echo hi > $p[1,10]otherco/f'
check 2 'p=xcompanies/; cp x $p[2,-1]otherco/'
check 2 'p=companies/indigo; cp x $~p/../otherco/'
check 2 'p=companies/indigo; cp x $^p/../otherco/'
check 2 'p=companies/indigo; cp x $=p/../otherco/'
check 2 'p=companies/indigo; cp x ${~p}/../otherco/'
check 2 'p=/y; git show x > companies$p:hotherco/f'
check 2 'p=/y; git show HEAD:x > companies$p:hotherco/f'
check 2 'p=/y; git log >> companies$p:hotherco/f'
check 2 'p=/y; git show HEAD 2> companies$p:hotherco/f'
check 2 'p=/y; git diff < companies$p:hotherco/settings/x'
check 2 'p=/y; git push companies$p:hotherco HEAD'
check 2 'p=/y; git fetch companies$p:hotherco'
check 2 'p=/y; cp x companies$p:hotherco/settings/'
check 2 'for d in /y; do cp x companies$d:hotherco/settings/; done'
check 2 'p=/y; cat companies$p:hotherco/settings/x'
check 2 'for d in /y; do echo hi > companies$d:hotherco/settings/z; done'
check 2 'p=companies/indigo; cp x $p:h2/otherco/'
check 2 'p=companies/indigo; cp x $p:h/otherco/'
check 2 'p=companies/indigo; cp x "$p:h/otherco/"'
# zsh :F, :f, :w and :W also rewrite the value (`$p:F:1:s/a/b/` repeats a
# substitution, `$p:wh` takes the head of each word).
check 2 'for p in companies/indigo/x; do cp a.txt $p:F:1:s/indigo/otherco/; done'
check 2 'for d in indigo; do cp x companies/$d:F:1:s/indigo/otherco/; done'
check 2 'for p in companies/indigo; do cp a.txt $p:wh/otherco/; done'
check 2 'for d in indigo; do cp x companies/$d:wh/otherco/; done'
check 2 'for d in indigo; do cp x companies/$d:F:1:h/otherco/; done'
check 2 'for p in companies/indigo; do cp a.txt $p:fh/otherco/; done'
check 2 'for p in companies/indigo; do cp a.txt $p:Wh/otherco/; done'
check 2 'p=/y; cp x companies$p:whotherco/settings/'
check 2 'p=/y; git show x > companies$p:whotherco/f'
check 2 'p=companies/indigo/x; git show HEAD > $p:F:1:s/indigo/otherco/'
check 2 'cp x *(e_REPLY=companies/otherco_)'
check 2 'cp x *(e~REPLY=companies/otherco~)'
check 2 'cp x *(e^REPLY=companies/otherco^)'
check 2 'for d in indigo; do cp x companies/$d/*(e:REPLY=../otherco:); done'
check 2 'for d in indigo; do : ${d::=otherco}; cp x companies/$d/; done'
check 2 'for d in indigo; do x=d; : ${(P)x::=otherco}; cp x companies/$d/; done'
check 2 'for d in indigo; do : ${(P)${:-d}::=otherco}; cp x companies/$d/; done'
check 2 'for d in indigo; do : ${d=otherco}; cp x companies/$d/; done'
check 2 'for d in indigo; do zformat -f d otherco; cp x companies/$d/; done'
check 2 'for d in indigo; do zformat -f d otherco; cat companies/$d/settings/x; done'
check 2 'for d in indigo; do zstyle :a b otherco; zstyle -s :a b d; cp x companies/$d/settings/; done'
check 2 'zmodload zsh/datetime; for d in indigo; do strftime -s d otherco 0; cp x companies/$d/; done'
check 2 'for d in indigo; do vared d; cp x companies/$d/; done'
check 2 'for d in indigo; do zparseopts -a d x; cp x companies/$d/; done'
check 2 'for d in indigo; do somebuiltin -q d; cp x companies/$d/; done'
check 2 'for d in companies/indigo; do r=read; ( $r d; cp a.txt $d/x ); done'

echo "[c] recursive globs"
check 2 'cp a.txt companies/***/x'
check 2 'cp a.txt companies/indigo/***/x'
check 2 'cp a.txt companies/indigo/projects/***'
check 2 'ls companies/indigo/***.md'
check 2 'for d in companies/***; do cp a.txt $d/x; done'
check 2 'for d in workspace/***; do cp a.txt $d/x; done'
check 2 'for d in workspace/**/; do cp a.txt $d/x; done'

echo "[allow] ordinary loops over the session's own folders"
check 0 'for d in companies/indigo; do cp a.txt $d/x; done'
check 0 'ls companies/indigo/projects/a/*(.)'
check 0 'for f in r1.md; do echo "$f: done"; cat workspace/reports/$f; done'
check 0 'for d in /tmp/a /tmp/b; do python3 -c "open('"'"'$d/x'"'"','"'"'w'"'"')"; done'
check 0 'for p in a b; do cat companies/indigo/projects/$p/README.md; done'
check 0 'for f in r1.md; do echo "== $f"; cat workspace/reports/$f; done'
check 0 'for d in companies/indigo/projects/a companies/indigo/projects/b; do ls $d; done'
check 0 'for d in companies/indigo/projects/a; do cp $d/README.md $d/README.bak; done'
check 0 'cat companies/indigo/projects/a/README.md companies/indigo/projects/*/README.md'

if [ "$FAILURES" -gt 0 ]; then
  echo "FAILED: $FAILURES case(s)" >&2
  exit 1
fi
echo "all scope-loop-bypass cases passed"
