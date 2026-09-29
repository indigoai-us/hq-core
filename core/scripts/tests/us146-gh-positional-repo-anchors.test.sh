#!/usr/bin/env bash
set -euo pipefail

ROOT="${US146_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
HOOK="$ROOT/.claude/hooks/block-hq-root-git-mutation.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/hq-root" "$TMP/home"

pass=0
fail=0

run() {
  local expected="$1" command="$2" label="$3" payload rc=0
  payload="$(jq -n --arg cwd "$TMP/hq-root" --arg command "$command" \
    '{cwd: $cwd, tool_input: {command: $command}}')"
  printf '%s' "$payload" | env -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID -u HQ_COMPANY_SLUG \
    HOME="$TMP/home" HQ_ALLOW_HQ_ROOT_GIT= CLAUDE_PROJECT_DIR="$TMP/hq-root" \
    bash "$HOOK" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq "$expected" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL [$label]: expected exit $expected, got $rc" >&2
  fi
}

# These arguments are the command's actual remote repository target.
run 0 'gh repo archive synthetic-owner/synthetic-repo' 'archive positional repo target is allowed'
run 0 'gh repo delete synthetic-owner/synthetic-repo --yes' 'delete positional repo target is allowed'
run 0 'gh repo edit synthetic-owner/synthetic-repo --description synthetic' 'edit positional repo target is allowed'
run 0 'gh api -X DELETE repos/synthetic-owner/synthetic-repo' 'api delete endpoint target is allowed'
run 0 'gh api -H accept:application/vnd.github+json -X PATCH repos/synthetic-owner/synthetic-repo/issues/12' \
  'api patch endpoint target is allowed'
run 0 'gh api -X DELETE repos/synthetic-owner/synthetic-repo 2>&1' \
  'api repo target remains recognized with stderr redirection'
run 0 'gh api 2>/dev/null -X DELETE repos/synthetic-owner/synthetic-repo' \
  'api repo target remains recognized with leading stderr redirection'

# A string that looks like a repo target elsewhere in argv is not an anchor.
run 2 'gh repo archive' 'archive with implicit repository stays blocked'
run 2 'gh repo fork synthetic-owner/synthetic-repo' 'fork source is not a positional mutation target'
run 2 'gh repo sync synthetic-owner/synthetic-repo' 'sync source is not a positional mutation target'
run 2 'gh pr create synthetic-owner/synthetic-repo' 'pr positional text is not a repo anchor'
run 2 'gh api -X DELETE orgs/synthetic-owner/repos' 'api org endpoint stays blocked'
run 2 'gh api --input repos/synthetic-owner/synthetic-repo -X DELETE orgs/synthetic-owner/repos' \
  'api input value is not mistaken for endpoint'
run 2 'gh api -X DELETE orgs/synthetic-owner/repos --jq repos/synthetic-owner/synthetic-repo' \
  'api jq expression is not mistaken for endpoint'

# A valid remote gh target must never let a separate local HQ-root mutation through.
run 2 'gh repo archive synthetic-owner/synthetic-repo && git push origin main' \
  'positional remote anchor does not bypass a local git mutation'
run 2 'gh pr create -R synthetic-owner/synthetic-repo && git push origin main' \
  'flag remote anchor does not bypass a local git mutation'
run 2 'gh repo archive synthetic-owner/synthetic-repo && gh issue create --title synthetic' \
  'one remote anchor does not bypass a second implicit gh mutation'

echo "US-146 gh positional anchor tests: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
