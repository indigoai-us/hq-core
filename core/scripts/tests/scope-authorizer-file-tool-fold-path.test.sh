#!/usr/bin/env bash
# hq-core: public
# Regression (feedback_346a71a9): for Read, Write, Edit, MultiEdit and
# NotebookEdit the mandatory scope authorizer case-folds only the extracted
# path, not the whole hook payload.
#
# The payload of a Write or Edit carries the full new content. Before the fix
# the authorizer case-folded that whole payload on case-insensitive volumes
# (macOS APFS by default) before any check, and the fold's cost grows with
# every mention of the HQ root or of companies/ in it. Under the stock macOS
# /bin/bash 3.2, which Cursor and the Claude desktop app use for hooks, an
# edit of a path-dense company README ran past the 25 s guard cap and was
# refused with "guard timed out" (53 KB payload: 28 s; worse in a UTF-8
# locale). The checks for these tools only read the path, so the hook time
# must not depend on the content.
#
# Asserted here:
#   1. a Write and an Edit of about 200 KB, every line naming the HQ root and
#      the bound company's paths, on the bound company's README, are allowed
#      within a budget far below the 25 s cap, in the C locale and in a UTF-8
#      locale, with the hook run by /bin/bash when present (BASH_BIN
#      overrides);
#   2. the same Write aimed at another company is still denied, also when its
#      path spells the other company in another case where the volume folds;
#   3. content that names another company does not block a write to the bound
#      company (content is not a path; unchanged behaviour);
#   4. a JSON-escaped case variant in the path (Companies) is still
#      folded and denied where the volume folds;
#   5. NotebookEdit and MultiEdit case-variant paths to another company are
#      still denied where the volume folds.
# Payloads are fed to the hook as JSON input; nothing is written.
# jq filters and the child shell's $BASH_VERSION are single-quoted on purpose.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK_BASH="${BASH_BIN:-/bin/bash}"
[ -x "$HOOK_BASH" ] || HOOK_BASH="$(command -v bash)"
BUDGET="${HQ_FILE_TOOL_FOLD_BUDGET_S:-5}"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable" >&2; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
C="$TMP/companies"
mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts/lib" "$TMP/.codex/hooks" \
  "$C/indigo/settings" "$C/otherco/settings" "$C/_template" \
  "$TMP/workspace/sessions/sess-bound" "$TMP/home/.hq"
cp "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" "$TMP/.claude/hooks/"
cp "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$TMP/.claude/hooks/"
for f in session-authz.sh session-scope-capability.sh hook-caller-lineage.sh session-id.sh; do
  cp "$ROOT/core/scripts/lib/$f" "$TMP/core/scripts/lib/"
done
cp "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/"
cp "$ROOT/.codex/hooks/codex-explicit-path-flag.cjs" "$TMP/.codex/hooks/"
printf 'companies:\n  indigo:\n    name: Indigo\n  otherco:\n    name: otherco\n' > "$C/manifest.yaml"
touch "$C/indigo/README.md" "$C/otherco/README.md" "$C/indigo/settings/x" "$C/otherco/settings/x"
export HOME="$TMP/home"
printf 'company_slug: indigo\n' > "$TMP/workspace/sessions/sess-bound/meta.yaml"
# shellcheck source=../lib/session-scope-capability.sh
. "$ROOT/core/scripts/lib/session-scope-capability.sh"
session_scope_mint "$TMP" "sess-bound" "indigo" >/dev/null 2>&1

FOLDS=0
[ "$TMP/COMPANIES" -ef "$TMP/companies" ] && FOLDS=1
B=0
[ "$FOLDS" -eq 1 ] && B=2
echo "hook bash: $HOOK_BASH ($("$HOOK_BASH" -c 'echo "$BASH_VERSION"')); case-insensitive volume: $FOLDS"

UTF8_LOCALE=""
for l in en_US.UTF-8 C.UTF-8; do
  if locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/utf8/utf-8/' | grep -qx "$(printf '%s' "$l" | tr '[:upper:]' '[:lower:]')"; then
    UTF8_LOCALE="$l"; break
  fi
done

# About 200 KB of README text: every line names the absolute HQ root and the
# bound company's relative path, with quotes, as a project README would.
BODY_FILE="$TMP/body.txt"
python3 -I - "$TMP" "$BODY_FILE" <<'PY'
import sys
root, out = sys.argv[1], sys.argv[2]
with open(out, "w") as f:
    for i in range(1600):
        f.write("- see %s/companies/indigo/projects/p/doc%d.md and companies/indigo/notes/n%d.md ('step' \"%d\")\n" % (root, i, i, i))
PY

FAILURES=0
# check <expected rc> <label> <locale> <tool> <tool_input JSON file> [max seconds]
check() {
  local expected="$1" label="$2" loc="$3" tool="$4" input_file="$5" max="${6:-}" rc=0 start elapsed
  jq -c --arg t "$tool" --arg cwd "$TMP" '{tool_name:$t,session_id:"sess-bound",cwd:$cwd,tool_input:.}' \
    "$input_file" > "$TMP/payload.json"
  start=$SECONDS
  env LC_ALL="$loc" LANG="$loc" "$HOOK_BASH" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" \
    < "$TMP/payload.json" >/dev/null 2>"$TMP/err" || rc=$?
  elapsed=$((SECONDS - start))
  if [ "$rc" != "$expected" ]; then
    echo "FAIL: $label [$loc] expected rc $expected, got $rc" >&2
    sed 's/^/    /' "$TMP/err" | head -8 >&2
    FAILURES=$((FAILURES + 1))
  elif [ -n "$max" ] && [ "$elapsed" -gt "$max" ]; then
    echo "FAIL: $label [$loc] took ${elapsed}s, over the ${max}s budget" >&2
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: $label [$loc] rc $rc in ${elapsed}s"
  fi
}

mk() { # <out file> <jq filter> [args...]
  local out="$1" filter="$2"; shift 2
  jq -n --rawfile body "$BODY_FILE" "$@" "$filter" > "$out"
}

mk "$TMP/write-bound.json" '{file_path:$p,content:$body}' --arg p "$C/indigo/README.md"
mk "$TMP/edit-bound.json" '{file_path:$p,old_string:"x",new_string:$body}' --arg p "$C/indigo/README.md"
mk "$TMP/multiedit-bound.json" '{file_path:$p,edits:[{old_string:"x",new_string:$body}]}' --arg p "$C/indigo/README.md"
mk "$TMP/write-other.json" '{file_path:$p,content:$body}' --arg p "$C/otherco/README.md"
mk "$TMP/write-other-case.json" '{file_path:$p,content:$body}' --arg p "$TMP/Companies/OtherCo/README.md"
mk "$TMP/write-bound-names-other.json" '{file_path:$p,content:($body + "\nsee companies/otherco/settings/x\n")}' \
  --arg p "$C/indigo/README.md"

for loc in C $UTF8_LOCALE; do
  check 0 "Write ~200 KB path-dense content, bound company" "$loc" Write "$TMP/write-bound.json" "$BUDGET"
  check 0 "Edit ~200 KB path-dense new_string, bound company" "$loc" Edit "$TMP/edit-bound.json" "$BUDGET"
  check 0 "MultiEdit ~200 KB path-dense edit, bound company" "$loc" MultiEdit "$TMP/multiedit-bound.json" "$BUDGET"
done
check 2 "Write ~200 KB to another company" C Write "$TMP/write-other.json" "$BUDGET"
check "$B" "Write ~200 KB to another company in another case" C Write "$TMP/write-other-case.json" "$BUDGET"
check 0 "Write to bound company whose content names another company" C Write "$TMP/write-bound-names-other.json"

# A JSON-escaped case variant: C is C. The decoded path is folded.
printf '{"file_path":"%s/\\u0043ompanies/OTHERCO/settings/x"}\n' "$TMP" > "$TMP/read-escaped.json"
check "$B" "Read JSON-escaped Companies/OTHERCO" C Read "$TMP/read-escaped.json"
jq -n --arg p "$TMP/COMPANIES/otherco/settings/x" '{notebook_path:$p,new_source:"x"}' > "$TMP/nb-case.json"
check "$B" "NotebookEdit COMPANIES/otherco" C NotebookEdit "$TMP/nb-case.json"
jq -n --arg p "$TMP/Companies/OtherCo/settings/x" '{file_path:$p,edits:[{old_string:"a",new_string:"b"}]}' > "$TMP/me-case.json"
check "$B" "MultiEdit Companies/OtherCo" C MultiEdit "$TMP/me-case.json"
jq -n --arg p "$TMP/Companies/Indigo/settings/x" '{file_path:$p}' > "$TMP/read-bound-case.json"
check 0 "Read bound company in another case" C Read "$TMP/read-bound-case.json"

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES file-tool fold check(s) failed" >&2
  exit 1
fi
echo "all file-tool fold checks passed"
