#!/usr/bin/env bash
# Regression test for core/scripts/ci/should-run-provider-adapter-contract.sh:
# the provider-adapter-contract path filter must select adapter changes, skip
# unrelated changes, and fail closed (run=true) whenever the change set cannot
# be computed, including a forced git diff error.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FILTER="$ROOT/core/scripts/ci/should-run-provider-adapter-contract.sh"
WORKFLOW="$ROOT/.github/workflows/pr-checks.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -x "$FILTER" ]] || fail "filter must exist and be executable"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
git init -q -b main "$REPO"
gc() { git -C "$REPO" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
mkdir -p "$REPO/docs" "$REPO/core/scripts/lib/provider-adapters"
printf 'doc\n' > "$REPO/docs/readme.md"
printf 'adapter\n' > "$REPO/core/scripts/lib/provider-adapters/grok.sh"
gc add -A && gc commit -q -m base
BASE="$(git -C "$REPO" rev-parse HEAD)"

expect() { # <expected> <label> <base> <head>
  local out
  out="$(bash "$FILTER" "$3" "$4" "$REPO" 2>"$TMP/stderr")" || fail "$2: filter exited non-zero"
  [[ "$out" == "run=$1" ]] || fail "$2: expected run=$1, got '$out' ($(cat "$TMP/stderr"))"
  pass "$2 -> run=$1"
}

# Unrelated change on a branch: skip.
gc checkout -q -b docs-only
printf 'doc 2\n' > "$REPO/docs/readme.md"
gc commit -q -am docs
expect false 'docs-only change' "$BASE" HEAD

# Adapter change: run.
gc checkout -q -b adapter "$BASE"
printf 'adapter 2\n' > "$REPO/core/scripts/lib/provider-adapters/grok.sh"
gc commit -q -am adapter
expect true 'adapter change' "$BASE" HEAD

# A branch name as base works (the workflow passes origin/<base_ref>).
expect true 'adapter change against a branch-name base' main adapter

# Fail closed: empty base, unknown base, unknown head.
expect true 'empty base fails closed' '' HEAD
expect true 'unknown base fails closed' 0000000000000000000000000000000000000000 HEAD
expect true 'missing base ref fails closed' origin/main HEAD
expect true 'unknown head fails closed' "$BASE" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

# Fail closed: no merge-base (unrelated history), so the three-dot diff errors.
gc checkout -q --orphan unrelated
gc rm -rq --cached . && rm -rf "$REPO/docs" "$REPO/core"
printf 'other\n' > "$REPO/other.txt"
gc add other.txt && gc commit -q -m unrelated
expect true 'no merge-base fails closed' docs-only unrelated

# Fail closed: force git diff itself to error with a shim that fails only diff.
SHIM="$TMP/shim"
mkdir -p "$SHIM"
REAL_GIT="$(command -v git)"
cat > "$SHIM/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do [[ "\$arg" == diff ]] && { echo 'shim: forced diff failure' >&2; exit 128; }; done
exec "$REAL_GIT" "\$@"
SH
chmod +x "$SHIM/git"
out="$(PATH="$SHIM:$PATH" bash "$FILTER" "$BASE" docs-only "$REPO" 2>"$TMP/stderr")" || fail 'forced diff error: filter exited non-zero'
[[ "$out" == run=true ]] || fail "forced diff error: expected run=true, got '$out'"
grep -q 'git diff' "$TMP/stderr" || fail 'forced diff error: filter must say why it runs every suite'
pass 'forced git diff error fails closed -> run=true'
# Control: the same inputs without the shim skip, so run=true above comes from the error.
expect false 'control without the shim' "$BASE" docs-only

# The workflow must use this filter and gate the suites on its output.
job="$(awk '/^  provider-adapter-contract:$/ {f=1; print; next} f && /^  [[:alnum:]_-]+:$/ {exit} f {print}' "$WORKFLOW")"
grep -Fq 'bash core/scripts/ci/should-run-provider-adapter-contract.sh' <<< "$job" \
  || fail 'provider-adapter-contract must call should-run-provider-adapter-contract.sh'
grep -Fq '|| true' <<< "$(sed -n '/id: filter/,/GITHUB_OUTPUT/p' <<< "$job" | grep -v 'git fetch')" \
  && fail 'provider-adapter-contract filter must not swallow errors with || true outside the base fetch'
pass 'workflow wires the fail-closed filter'
