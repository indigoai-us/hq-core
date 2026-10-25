#!/usr/bin/env bash
# hq-core: public
# Real decision-hook security regressions for scope guard PR 1597.
#
# Commands are submitted only as JSON data to the real decision hooks; none
# of the submitted payloads are executed. All file contents are synthetic.
# Computed read paths deliberately fail closed, even for benign echo/printf:
# inherited command bindings cannot be proven here. Literal reads and
# metadata-only uses remain distinct controls, not equivalent UX acceptance.
# Use the caller's OS network/credential denial sandbox for strict isolation.

set -euo pipefail

ROOT="${PUBLISHED_CORE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

REGRESSION_FAILURES=0
CASES=0

expect_exit() {
  local expected="$1" actual="$2" case_name="$3"
  CASES=$((CASES + 1))
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $case_name"
  else
    echo "FAIL: $case_name (expected exit $expected, got $actual)" >&2
    sed 's/^/      | /' "$TMP/err.txt" >&2 || true
    REGRESSION_FAILURES=$((REGRESSION_FAILURES + 1))
  fi
}

install_fixture() {
  local bound="${1:-}"
  rm -rf "${TMP:?}"/*
  mkdir -p "$TMP/.claude/hooks" "$TMP/core/scripts/lib" "$TMP/core/scripts" \
    "$TMP/companies/indigo/settings" "$TMP/companies/indigo/projects/x/reports" \
    "$TMP/companies/indigo/policies" \
    "$TMP/companies/otherco/settings" "$TMP/companies/otherco/policies" \
    "$TMP/companies/_template" "$TMP/core/docs" "$TMP/core/policies" "$TMP/personal" \
    "$TMP/workspace/sessions/sess-bound" "$TMP/workspace/logs" "$TMP/workspace/out" \
    "$TMP/workspace/worktrees/x/.claude" "$TMP/workspace/x/backend" "$TMP/workspace/x/frontend" \
    "$TMP/repos/private/cleanlogic-theme/snippets" "$TMP/repos/private/a" "$TMP/repos/private/b" \
    "$TMP/home/.hq" "$TMP/home/.claude/projects/x" "$TMP/.claude/state" "$TMP/.claude/skills/deploy/scripts"
  cp "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" "$TMP/.claude/hooks/"
  cp "$ROOT/core/scripts/lib/session-authz.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/hook-caller-lineage.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-id.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh" "$TMP/core/scripts/"
  mkdir -p "$TMP/.codex/hooks"
  cp "$ROOT/.codex/hooks/codex-explicit-path-flag.cjs" "$TMP/.codex/hooks/"
  cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/"
  cp "$ROOT/.claude/hooks/block-credential-file-read.sh" "$TMP/.claude/hooks/"
  chmod +x "$TMP/.claude/hooks/mandatory-scope-authorizer.sh"

  printf 'companies:\n  indigo:\n    name: Indigo\n  otherco:\n    name: otherco\n' \
    > "$TMP/companies/manifest.yaml"
  touch "$TMP/companies/indigo/settings/.keep" "$TMP/companies/otherco/settings/.keep"
  touch "$TMP/companies/indigo/README.md" "$TMP/companies/indigo/policies/a.md" \
    "$TMP/companies/indigo/projects/x/reports/r.md" "$TMP/companies/otherco/policies/x.md"
  touch "$TMP/core/docs/readme.md" "$TMP/personal/note.md" "$TMP/companies/_template/readme.md"
  touch "$TMP/core/policies/a.md" "$TMP/core/policies/b.md"
  touch "$TMP/workspace/a.md" "$TMP/workspace/a.txt" "$TMP/workspace/a.json" "$TMP/workspace/a.tgz" \
    "$TMP/workspace/a.sha" "$TMP/workspace/id" "$TMP/workspace/q.sql" "$TMP/workspace/req.json" \
    "$TMP/workspace/index.html" "$TMP/workspace/log.txt" "$TMP/workspace/deploy.sh" \
    "$TMP/workspace/logs/a.html" "$TMP/workspace/logs/b.html" "$TMP/workspace/s.txt" \
    "$TMP/workspace/x/deploy.sh" "$TMP/.claude/state/manual-title" \
    "$TMP/.claude/skills/deploy/scripts/deploy.sh" "$TMP/home/.claude/projects/x/y.jsonl"
  printf 'sess-bound\n' > "$TMP/workspace/sessions/.current"
  # A symlink under workspace/ that points into another tenant: a cd chain
  # through it must resolve to the tenant folder and be refused.
  ln -s "$TMP/companies/otherco" "$TMP/workspace/otherlink"
  mkdir -p "$TMP/workspace/logs2"
  ln -s "$TMP/companies/otherco/settings/.keep" "$TMP/workspace/logs2/evil"
  export HOME="$TMP/home"
  # The HQ root is a git work tree, so `$(git rev-parse --show-toplevel)`
  # resolves the way it does in a real install.
  git -C "$TMP" init -q 2>/dev/null || true

  if [ -n "$bound" ]; then
    printf 'company_slug: %s\n' "$bound" > "$TMP/workspace/sessions/sess-bound/meta.yaml"
    # shellcheck source=../lib/session-scope-capability.sh
    . "$ROOT/core/scripts/lib/session-scope-capability.sh"
    session_scope_mint "$TMP" "sess-bound" "$bound"
  fi
}

run_hook() {
  local payload="$1"
  local rc=0
  : > "$TMP/err.txt"
  printf '%s' "$payload" | "${BASH_BIN:-bash}" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" 2>"$TMP/err.txt" || rc=$?
  printf '%s' "$rc"
}

# bash_case <expected exit> <row> <command>
bash_case() {
  local expect="$1" name="$2" command="$3" rc

  payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" \
    '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
  rc="$(run_hook "$payload")"
  cp "$TMP/err.txt" "$EVIDENCE_DIR/$name.stderr"
  expect_exit "$expect" "$rc" "$name: $(printf '%s' "$command" | tr '\n' ' ' | cut -c1-140)"
}


credential_case() {
  local name="$1" command="$2" expected="${3:-2}" rc=0 payload
  payload="$(jq -cn --arg cwd "$TMP" --arg command "$command" '{tool_name:"Bash",session_id:"sess-bound",cwd:$cwd,tool_input:{command:$command}}')"
  printf '%s' "$payload" | "${BASH_BIN:-bash}" "$TMP/.claude/hooks/block-credential-file-read.sh" >"$TMP/cred.out" 2>"$TMP/err.txt" || rc=$?
  expect_exit "$expected" "$rc" "$name"
}
install_fixture indigo
EVIDENCE_DIR="${EVIDENCE_DIR:-$TMP}"
PRIVATE_EXTERNAL="${PRIVATE_EXTERNAL:-$TMP/external}"
mkdir -p "$TMP/workspace/loop" "$PRIVATE_EXTERNAL/loop" "$HOME/.aws"
printf 'SYNTHETIC_NOT_A_SECRET\n' > "$HOME/.aws/credentials"
ln -s "$TMP/companies/otherco/settings/.keep" "$TMP/workspace/loop/foreign"
ln -s "$TMP/companies/otherco/settings/.keep" "$PRIVATE_EXTERNAL/loop/foreign"
ln -s "$HOME/.aws/credentials" "$TMP/workspace/credlink"
printf 'https://example.invalid file://%s/companies/otherco/settings/.keep\n' "$TMP" > "$TMP/workspace/urls"
bash_case 2 regression-1-workspace-lsd 'for d in $(ls -d workspace/loop/*); do cat "$d"; done'
bash_case 2 regression-2-tmp-lsd "for d in \$(ls -d $PRIVATE_EXTERNAL/loop/*); do cat \"\$d\"; done"
bash_case 2 regression-3-split-url 'for u in $(grep -o "https://.*" workspace/urls); do curl "$u"; done'
credential_case regression-4-inline-credential 'cat "workspace/$(echo c)redlink"'
credential_case regression-5-globdots 'set -o globdots; cat ~/*/cred*'
# Allow controls prove that denials are not syntax/parser failures.
printf 'safe\n' > "$TMP/workspace/loop/safe"
mkdir -p "$TMP/workspace/safe-loop"
printf 'safe\n' > "$TMP/workspace/safe-loop/a"
bash_case 0 control-safe-lsd 'for d in $(ls -d workspace/safe-loop/*); do cat "$d"; done'
bash_case 2 control-mixed-lsd 'for d in $(ls -d workspace/loop/*); do cat "$d"; done'
bash_case 2 control-write-lsd 'for d in $(ls -d workspace/loop/*); do echo x > "$d"; done'
bash_case 2 control-unsafe-old-url 'for u in $(grep -o "https://[^\\\"]*" workspace/urls); do curl "$u"; done'
bash_case 0 control-safe-url 'for u in $(grep -o "https://[^[:space:]]*" workspace/urls); do curl "$u"; done'
bash_case 0 control-literal-url 'for u in https://example.invalid/a https://example.invalid/b; do curl "$u"; done'
credential_case compat-computed-read-denied 'cat "workspace/$(echo s)afe-loop/a"'
credential_case control-safe-print 'echo "workspace/$(echo c)redlink"' 0
credential_case control-literal-credential 'cat "$HOME/.aws/credentials"'
credential_case control-literal-credential-link 'cat workspace/credlink'
credential_case compat-computed-no-match-denied 'cat "workspace/$(echo nonexistent)file"'
credential_case control-dotglob 'shopt -s dotglob; cat ~/*/cred*'
credential_case control-globdots-upper 'set -o GLOBDOTS; cat ~/*/cred*'
mkdir -p "$TMP/.github/workflows"
printf 'safe\n' > "$TMP/.github/workflows/a.yml"
credential_case control-safe-project-glob 'cat .github/workflows/*.yml' 0
mkdir -p "$TMP/workspace/dangling-loop" "$TMP/workspace/space-loop" "$TMP/workspace/many-loop" "$TMP/workspace/computed-many"
ln -s "$TMP/companies/otherco/missing" "$TMP/workspace/dangling-loop/link"
printf safe > "$TMP/workspace/space-loop/space name"
bash_case 2 control-dangling-foreign-lsd 'for d in $(ls -d workspace/dangling-loop/*); do cat "$d"; done'
bash_case 2 control-split-name-lsd 'for d in $(ls -d workspace/space-loop/*); do cat "$d"; done'
for ((n=0;n<2049;n++)); do : > "$TMP/workspace/many-loop/a$n"; done
bash_case 2 control-lsd-cap 'for d in $(ls -d workspace/many-loop/*); do cat "$d"; done'
# The credential guard's literal-glob match cap is 10000 (feedback_0ae14829);
# one past it must still fail closed.
for ((n=0;n<10001;n++)); do : > "$TMP/workspace/computed-many/a$n"; done
credential_case control-glob-cap 'cat workspace/computed-many/*'
bash_case 2 control-grep-line-number-url 'for u in $(grep -on "https://[^[:space:]]*" workspace/urls); do curl "$u"; done'
bash_case 2 control-grep-filename-url 'for u in $(grep -oH "https://[^[:space:]]*" workspace/urls); do curl "$u"; done'
ln -s "$HOME/.aws/credentials" "$TMP/home/neutral"
mkdir -p "$TMP/workspace/nested/deeper"
ln -s "$HOME/.aws/credentials" "$TMP/workspace/nested/deeper/neutral"
credential_case separator-dotdot 'cat "workspace/$(echo ../home/)neutral"'
credential_case separator-multilevel 'cat "workspace/$(echo nested/deeper/)neutral"'
credential_case separator-absolute "cat \"\$(echo $TMP/home/)neutral\""
credential_case separator-printf 'cat "workspace/$(printf %s nested/deeper/)neutral"'
credential_case separator-printf-quoted 'cat "workspace/$(printf \"%s\" nested/deeper/)neutral"'
credential_case unknown-producer 'cat "workspace/$(cat workspace/id)neutral"'
credential_case unknown-pwd 'cat "$(pwd)/workspace/nested/deeper/neutral"'
credential_case unknown-nested 'cat "workspace/$(echo $(echo nested/deeper/))neutral"'
credential_case compat-computed-printf-denied 'cat "workspace/$(printf %s safe-loop/)a"'
credential_case safe-unknown-metadata 'echo "workspace/$(cat workspace/id)neutral"' 0
credential_case shadowed-echo 'echo(){ printf %s nested/deeper/; }; cat "workspace/$(echo safe-loop/)neutral"'
credential_case shadowed-printf 'printf(){ echo nested/deeper/; }; cat "workspace/$(printf %s safe-loop/)neutral"'
credential_case aliased-echo 'alias echo=evil; cat "workspace/$(echo safe-loop/)neutral"'
credential_case eval-before-constant 'eval x; cat "workspace/$(echo safe-loop/)neutral"'
credential_case source-before-constant 'source workspace/id; cat "workspace/$(echo safe-loop/)neutral"'
credential_case dot-source-before-constant '. workspace/id; cat "workspace/$(echo safe-loop/)neutral"'
credential_case safe-metadata-after-shadow 'echo(){ printf %s nested/deeper/; }; echo "workspace/$(echo safe-loop/)neutral"' 0
credential_case computed-echo-option-n 'cat "workspace/$(echo -n safe-loop/)a"'
credential_case computed-echo-option-e 'cat "workspace/$(echo -e safe-loop/)a"'
credential_case computed-printf-escape 'cat "workspace/$(printf %b safe-loop/)a"'
credential_case literal-safe-equivalent 'cat workspace/safe-loop/a' 0
# Reviewer inventory: these are refusal coverage, not all newly fixed regressions.
# The baseline matrix records which cases already refused at cdc95382/main.
bash_case 2 review-find-home-loop 'for f in $(find "$HOME/." -name "cred*"); do cat "$f"; done'
bash_case 2 review-git-positional-output 'show() { git show HEAD:$1; }; show "x --output=companies/otherco/settings/x"'
bash_case 2 review-git-positional-rev-output 'show() { git show origin/master:$1; }; show "src/a.ts --output=companies/otherco/settings/x"'
credential_case review-zsh-four 'zsh -4 -c "cat ~/*/cred*"'
credential_case review-zsh-globdots 'zsh -o globdots -c "cat ~/*/cred*"'
bash_case 2 review-printf-glob-loop 'for d in $(printf "%s\n" workspace/loop/*); do cat "$d"; done'
bash_case 2 review-braced-literal-link 'v=workspace/loop/foreign; cat "${v}"'
echo "RESULT: cases=$CASES failures=$REGRESSION_FAILURES"
[ "$REGRESSION_FAILURES" -eq 0 ]
