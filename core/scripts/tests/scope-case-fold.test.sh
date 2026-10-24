#!/usr/bin/env bash
# hq-core: public
# Regression tests: on a case-insensitive volume, a case variant of the HQ
# root, of companies/, or of a company slug opens that company's real folder.
# The scope guard must classify it as that company path: another company's
# folder in any case blocks, the locked company's folder in any case passes.
# Commands are fed to the hook as JSON input and never executed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
C="$TMP/companies"

mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts/lib" "$TMP/.codex/hooks" \
  "$C/indigo/settings" "$C/otherco/settings" "$C/kiwi/settings" "$C/_template" \
  "$TMP/workspace/sessions/sess-bound" "$TMP/home/.hq" "$TMP/core/docs"
cp "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" "$TMP/.claude/hooks/"
for f in session-authz.sh session-scope-capability.sh hook-caller-lineage.sh session-id.sh; do
  cp "$ROOT/core/scripts/lib/$f" "$TMP/core/scripts/lib/"
done
cp "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/"
cp "$ROOT/.codex/hooks/codex-explicit-path-flag.cjs" "$TMP/.codex/hooks/"
printf 'companies:\n  indigo:\n    name: Indigo\n  otherco:\n    name: otherco\n' > "$C/manifest.yaml"
touch "$C/otherco/settings/x" "$C/kiwi/settings/x" "$C/indigo/settings/x" "$TMP/core/docs/x"
# A link inside the locked company whose target spells the other tenant in
# another case.
ln -s ../../COMPANIES/OtherCo "$C/indigo/peer"
export HOME="$TMP/home"
printf 'company_slug: indigo\n' > "$TMP/workspace/sessions/sess-bound/meta.yaml"
# shellcheck source=../lib/session-scope-capability.sh
. "$ROOT/core/scripts/lib/session-scope-capability.sh"
session_scope_mint "$TMP" "sess-bound" "indigo" >/dev/null 2>&1

FOLDS=0
[ "$TMP/COMPANIES" -ef "$TMP/companies" ] && FOLDS=1
echo "case-insensitive volume: $FOLDS"

FAILURES=0
check() {
  local expected="$1" tool="$2" arg="$3" input payload rc=0
  arg="${arg//@T@/$TMP}"
  if [ "$tool" = Bash ]; then
    input="$(jq -cn --arg v "$arg" '{command:$v}')"
  else
    input="$(jq -cn --arg v "$arg" '{file_path:$v}')"
  fi
  payload="$(jq -cn --arg t "$tool" --arg cwd "$TMP" --argjson ti "$input" \
    '{tool_name:$t,session_id:"sess-bound",cwd:$cwd,tool_input:$ti}')"
  printf '%s' "$payload" | "${BASH_BIN:-bash}" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$expected" ]; then
    echo "PASS: $tool $arg -> $rc"
  else
    echo "FAIL: $tool $arg (expected $expected, got $rc)" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# Exact-case paths behave the same on every volume.
check 2 Read "@T@/companies/otherco/settings/x"
check 2 Bash "cat companies/otherco/settings/x"
check 0 Read "@T@/companies/indigo/settings/x"
check 0 Bash "cat companies/indigo/settings/x"
check 0 Bash "cat core/docs/x"
check 0 Read "@T@/core/docs/x"
check 0 Bash "cat companies/manifest.yaml"
check 0 Read "@T@/companies/_template/readme.md"

# On a case-sensitive volume a case variant is a different, missing folder
# and is not a tenant, so it passes; on a folding volume it is the tenant.
B=0; A=0
[ "$FOLDS" -eq 1 ] && B=2

# Other company: companies/ spelled in another case, as literal paths.
check "$B" Read "@T@/Companies/otherco/settings/x"
check "$B" Read "@T@/COMPANIES/OTHERCO/settings/x"
check "$B" Bash "cat Companies/otherco/settings/x"
check "$B" Bash "cat ./COMPANIES/otherCO/settings/x"
check "$B" Bash "cat @T@/Companies/OtherCo/settings/x"
# The HQ root itself in another case.
ROOT_UP="$(printf '%s' "$TMP" | tr '[:lower:]' '[:upper:]')"
check "$B" Read "$ROOT_UP/companies/otherco/settings/x"
check "$B" Bash "cat $ROOT_UP/companies/otherco/settings/x"
# Through variables.
check "$B" Bash 'D=Companies/OTHERCO; cat $D/settings/x'
check "$B" Bash 'D=COMPANIES; cat $D/otherco/settings/x'
# After cd.
check "$B" Bash "cd Companies && cat otherco/settings/x"
check "$B" Bash "cd COMPANIES/OtherCo && cat settings/x"
# Through .. from the locked company.
check "$B" Read "@T@/Companies/Indigo/../otherco/settings/x"
check "$B" Bash "cat Companies/indigo/../OTHERCO/settings/x"
check "$B" Bash "cd Companies/Indigo && cat ../otherco/settings/x"
# Through a link whose target spells the tenant in another case.
check "$B" Read "@T@/companies/indigo/peer/settings/x"
check "$B" Bash "cat companies/indigo/peer/settings/x"
# A slug in another case under the canonical companies/ opens the other
# tenant only where the volume folds; there it is refused.
check "$B" Read "@T@/companies/OtherCo/settings/x"
check "$B" Bash "cat companies/OTHERCO/settings/x"
check "$B" Bash 'C=OtherCo; cat companies/$C/settings/x'
check "$B" Bash "for c in OtherCo; do cat companies/\$c/settings/x; done"

# Unicode letters that the volume folds onto ASCII: U+017F (long s) and
# U+212A (Kelvin sign), in the companies segment, the slug, and the root.
LS=$'\xc5\xbf'
KS=$'\xe2\x84\xaa'
check "$B" Read "@T@/companie$LS/otherco/settings/x"
check "$B" Read "@T@/COMPANIE$LS/OTHERCO/settings/x"
check "$B" Bash "cat companie$LS/otherco/settings/x"
check "$B" Bash "cd Companie$LS && cat otherco/settings/x"
check "$B" Bash "cat companie$LS/indigo/../otherco/settings/x"
check "$B" Write "@T@/companie$LS/otherco/settings/y"
check "$B" Edit "@T@/companie$LS/otherco/settings/x"
check "$B" Read "@T@/companies/${KS}iwi/settings/x"
ROOT_LS="${TMP/s/$LS}"
if [ "$ROOT_LS" != "$TMP" ]; then
  check "$B" Read "$ROOT_LS/companies/otherco/settings/x"
fi
check "$A" Read "@T@/companie$LS/indigo/settings/x"

# Locked company in any case.
check "$A" Read "@T@/Companies/INDIGO/settings/x"
check "$A" Bash "cat Companies/indigo/settings/x"
check "$A" Bash 'D=COMPANIES/INDIGO; cat $D/settings/x'
check "$A" Bash "cd Companies/Indigo && cat settings/x"
# A slug in another case is the locked company only where the volume folds.
S=2
[ "$FOLDS" -eq 1 ] && S=0
check "$S" Read "@T@/companies/Indigo/settings/x"
check "$S" Bash "cat companies/INDIGO/settings/x"
# Non-company text in another case.
check 0 Bash "echo Companies are listed in the manifest"
check 0 Bash "cat Core/docs/x"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES case-fold scope check(s) failed" >&2
  exit 1
fi
echo "all case-fold scope checks passed"
