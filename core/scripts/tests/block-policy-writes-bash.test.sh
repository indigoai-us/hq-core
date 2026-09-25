#!/usr/bin/env bash
# Regression coverage for the Bash policy-write funnel. Direct shell writes to
# policy directories must use a validated authoring path instead.

set -euo pipefail

ROOT="${HQ_TEST_ROOT:-$(git rev-parse --show-toplevel)}"
HOOK="${POLICY_BASH_HOOK:-$ROOT/.claude/hooks/block-policy-writes-bash.sh}"
CORE_GUARD="$ROOT/.claude/hooks/protect-core.sh"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
POLICY_TEST_BASH="${POLICY_TEST_BASH:-bash}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "  ok: $*"; PASS=$((PASS + 1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
[[ -f "$HOOK" ]] || { echo "FAIL: policy Bash guard is missing: $HOOK" >&2; exit 1; }

echo "[0] array snapshots stay safe under Bash 3.2 nounset semantics"
for safe_copy in \
  'saved_argv=(${ARGV[@]+"${ARGV[@]}"})' \
  'saved_names=(${TRACKED_VAR_NAMES[@]+"${TRACKED_VAR_NAMES[@]}"})' \
  'saved_values=(${TRACKED_VAR_VALUES[@]+"${TRACKED_VAR_VALUES[@]}"})' \
  'TRACKED_VAR_NAMES=(${saved_names[@]+"${saved_names[@]}"})' \
  'TRACKED_VAR_VALUES=(${saved_values[@]+"${saved_values[@]}"})' \
  'ARGV=(${saved_argv[@]+"${saved_argv[@]}"})'; do
  if grep -Fq -- "$safe_copy" "$HOOK"; then
    pass "empty-array snapshot is nounset-safe: $safe_copy"
  else
    fail "nounset-safe empty-array snapshot is missing: $safe_copy"
  fi
done

mkdir -p \
  "$TMP/core/scripts" \
  "$TMP/personal/policies" "$TMP/personal/knowledge" \
  "$TMP/companies/indigo/policies" "$TMP/companies/_template/policies" \
  "$TMP/companies/indigo/settings" \
  "$TMP/repos/private/widget/.claude/policies" \
  "$TMP/workspace/worktrees/widget/branch/.claude/policies"
cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/hook-lib.sh"

run() {
  local want="$1" cmd="$2" label="$3" rc=0 payload stderr
  payload="$(jq -nc --arg cmd "$cmd" '{tool_input:{command:$cmd}}')"
  stderr="$(mktemp)"
  printf '%s' "$payload" | env -i PATH="$PATH" HOME="$HOME" \
    CLAUDE_PROJECT_DIR="$TMP" "$POLICY_TEST_BASH" "$HOOK" >/dev/null 2>"$stderr" || rc=$?
  if [[ "$rc" == "$want" ]]; then
    pass "$label"
  else
    fail "$label (expected exit $want, got $rc; $(tr '\n' ' ' < "$stderr"))"
  fi
  if [[ "$want" == 2 ]] && ! grep -q '^BLOCKED:' "$stderr"; then
    fail "$label (guard denied without its required BLOCKED diagnostic: $(tr '\n' ' ' < "$stderr"))"
  fi
  if grep -q 'grep: warning' "$stderr"; then
    fail "$label (guard leaked a grep warning)"
  fi
  rm -f "$stderr"
}

P="$TMP/personal/policies/x.md"
I="$TMP/companies/indigo/policies/x.md"
T="$TMP/companies/_template/policies/x.md"

echo "[1] direct policy writes are blocked"
run 2 "cat > $P <<EOF
x
EOF" 'heredoc redirect into personal policy is blocked'
run 2 "tee $P < /tmp/policy-input" 'tee into personal policy is blocked'
run 2 "cp /tmp/policy-input $P" 'cp into personal policy is blocked'
run 2 "mv /tmp/policy-input $P" 'mv into personal policy is blocked'
run 2 "sed -i 's/a/b/' $P" 'sed -i into personal policy is blocked'
run 2 "cat > $I <<EOF
x
EOF" 'company policy is blocked'
run 2 "cat > $T <<EOF
x
EOF" 'template company policy is blocked'
run 2 "rm -rf $TMP/personal/policies" 'removing the personal policy directory itself is blocked'
run 2 "mv $TMP/personal/policies /tmp/policy-guard-away" 'moving the personal policy directory itself is blocked'

echo "[1b] adversarial compound commands cannot borrow a later exemption"
# Every case contains either a real write behind a command boundary or an
# invalid extension of the sanctioned route. The old whole-payload scanner
# allowed these because it found one good-looking clause and applied it to the
# rest of the text.
run 2 "cat > personal/policies/x.md <<EOF
x
EOF
cd repos/private/widget" 'later repo cd cannot exempt an earlier heredoc write'
run 2 "cd /tmp; cd \"\$CLAUDE_PROJECT_DIR\"; cat > personal/policies/x.md <<EOF
x
EOF" 'later return to HQ root revokes an external cwd exemption'
run 2 "HQ_ALLOW_POLICY_WRITE=1 bash core/scripts/policy-retire.sh x --reason t
tee $P < /tmp/policy-input" 'sanctioned first line cannot vouch for later tee'
run 2 "printf x >| $P" 'noclobber-override redirect into policy is blocked'
run 2 "cd personal/policies && cat > x.md <<EOF
x
EOF" 'write relative to a policy cwd is blocked'
run 2 "x=\$(cat > personal/policies/x.md <<EOF
x
EOF); cd repos/private/widget" 'command substitution write cannot borrow a later repo cd'
run 2 "bash -c 'cat > personal/policies/x.md <<EOF
x
EOF'; cd repos/private/widget" 'bash -c write cannot borrow a later repo cd'
run 2 "eval 'cat > personal/policies/x.md <<EOF
x
EOF'; cd repos/private/widget" 'eval write cannot borrow a later repo cd'
run 2 "cat > personal/policies/x.md <<EOF
x
EOF & cd repos/private/widget" 'background write cannot borrow a later repo cd'
run 2 "HQ_ALLOW_POLICY_WRITE=1 bash core/scripts/policy-retire.sh x --reason t;" 'sanctioned route with a trailing separator is blocked'
run 2 "printf x | xargs -I{} sh -c 'cat > personal/policies/x.md <<EOF
x
EOF'; cd repos/private/widget" 'xargs shell write cannot borrow a later repo cd'
run 2 "find . -exec sh -c 'cat > personal/policies/x.md <<EOF
x
EOF' \\; ; cd repos/private/widget" 'find -exec shell write cannot borrow a later repo cd'
run 2 "find /tmp -name '*.md' -exec cp {} $TMP/personal/policies/ \\;" 'find -exec cp into a policy directory is blocked'
run 2 "find /tmp -name '*.md' -exec cp {} $P \\;" 'find -exec cp into a policy file is blocked'
run 2 "find /tmp -name '*.md' -exec cp {} $TMP/personal/policies/ +" 'find -exec plus cp into a policy directory is blocked'
run 2 "find /tmp -exec tee $P \\;" 'find -exec tee into a policy file is blocked'
run 2 "find $TMP/personal/policies -name '*.md' -delete" 'find delete of a policy directory is blocked'
run 2 "find $TMP/personal -name '*.md' -delete" 'find delete from a parent that contains policy files is blocked'
run 2 "find /tmp -name '*.md' -execdir cp {} $P \\;" 'find execdir cp into a policy file is blocked'
run 2 "find $TMP/personal/policies -execdir cp {} x.md \\;" 'find execdir relative cp from a policy directory is blocked'
run 2 "find -H $TMP/personal/policies -name '*.md' -delete" 'find option-prefixed delete of a policy directory is blocked'
run 2 "find /tmp -name '*.md' -exec install {} $P \\;" 'find exec direct install into a policy file is blocked'
run 2 "printf x | xargs -I{} cp /tmp/policy-input $P" 'xargs direct cp into a policy file is blocked'
run 2 "nohup cp /tmp/policy-input $P" 'nohup-wrapped cp into a policy file is blocked'
run 2 "timeout 5 cp /tmp/policy-input $P" 'timeout-wrapped cp into a policy file is blocked'
run 2 "stdbuf -oL cp /tmp/policy-input $P" 'stdbuf-wrapped cp into a policy file is blocked'
run 2 "nice cp /tmp/policy-input $P" 'nice-wrapped cp into a policy file is blocked'
run 2 "sudo -u root cp /tmp/policy-input $P" 'sudo user-wrapped cp into a policy file is blocked'
run 2 "parallel cp {} $P ::: /tmp/policy-input" 'parallel direct cp into a policy file is blocked'
run 2 "tar -C $TMP/personal/policies/ -xf /tmp/policies.tar" 'tar extraction into a policy directory is blocked'
run 2 "git checkout -- personal/policies/x.md" 'git checkout into a policy path is blocked'
run 2 "cd /tmp && git -C $TMP checkout -- personal/policies/x.md" 'git checkout -C into a policy path is blocked'
run 2 "install /tmp/policy-input $P" 'install into a policy file is blocked'
run 2 "truncate -s 0 $P" 'truncate of a policy file is blocked'

echo "[2] neighbouring paths and policy reads remain allowed"
run 0 "cat > $TMP/personal/knowledge/x.md <<EOF
x
EOF" 'personal knowledge write is allowed'
run 0 "cat > $TMP/companies/indigo/settings/x.yaml <<EOF
x
EOF" 'company settings write is allowed'
run 0 "cat $P" 'cat policy read is allowed'
run 0 "grep rule $P" 'grep policy read is allowed'
run 0 "head -1 $P" 'head policy read is allowed'
run 0 "find /tmp -execdir cp {} personal/policies/x.md \\;" 'find execdir external relative target is allowed'
run 0 'bash core/scripts/lint-policy-triggers.sh --quiet' 'policy corpus linter invocation is allowed'

echo "[3] checkout-relative paths are exempt"
run 0 "cd $TMP/repos/private/widget && cat > core/policies/x.md <<EOF
x
EOF" 'repo checkout relative core policy path is allowed'
run 0 "cd $TMP/repos/private/widget && cat > .claude/policies/x.md <<EOF
x
EOF" 'repo checkout relative repo policy path is allowed'
run 0 "cd $TMP/workspace/worktrees/widget/branch && cat > core/policies/x.md <<EOF
x
EOF" 'worktree relative core policy path is allowed'
run 0 "cd $TMP/workspace/worktrees/widget/branch && cat > .claude/policies/x.md <<EOF
x
EOF" 'worktree relative repo policy path is allowed'

echo "[4] only audited, validating tooling gets the narrow shell route"
run 0 "HQ_ALLOW_POLICY_WRITE=1 bash core/scripts/migrate-policy-triggers.sh companies/indigo/policies" \
  'migrator route is allowed'
run 0 "HQ_ALLOW_POLICY_WRITE=1 bash core/scripts/policy-retire.sh x --reason test" \
  'retire route is allowed'
run 2 "HQ_ALLOW_POLICY_WRITE=1 tee $P < /tmp/policy-input" \
  'narrow route does not allow arbitrary shell writes'

echo "[5] deny wording and existing core-policy guard wording are hardened"
payload="$(jq -nc --arg cmd "cat > $P <<EOF
x
EOF" '{tool_input:{command:$cmd}}')"
policy_err="$(printf '%s' "$payload" | env -i PATH="$PATH" HOME="$HOME" CLAUDE_PROJECT_DIR="$TMP" "$POLICY_TEST_BASH" "$HOOK" 2>&1 >/dev/null || true)"
if grep -Fq 'Use the Write/Edit tool or /learn instead; those paths are validated.' <<<"$policy_err"; then
  pass 'policy guard names the validated alternatives'
else
  fail "policy guard omittted the validated-authoring instruction: $policy_err"
fi

core_payload="$(jq -nc --arg fp "$TMP/core/policies/new.md" --arg content '---\nid: x\nwhen: test\non: [PreToolUse]\n---\n' '{tool_input:{file_path:$fp,content:$content}}')"
core_rc=0
core_err="$(printf '%s' "$core_payload" | env -i PATH="$PATH" HOME="$HOME" CLAUDE_PROJECT_DIR="$TMP" "$POLICY_TEST_BASH" "$CORE_GUARD" 2>&1 >/dev/null)" || core_rc=$?
if [[ "$core_rc" == 2 ]] && grep -Fq 'explicit human permission' <<<"$core_err" \
  && grep -Fq 'never set, export, or write it on its own initiative' <<<"$core_err" \
  && ! grep -Fq 'prefix the command with HQ_ALLOW_CORE_POLICY_WRITE=1' <<<"$core_err"; then
  pass 'core policy guard requires human permission without a bare bypass recipe'
else
  fail "core policy guard wording is not hardened (rc=$core_rc; $core_err)"
fi
if ! grep -Fq 'prefix the command with HQ_ALLOW_CORE_POLICY_WRITE=1' "$ROOT/.claude/hooks/block-core-writes-bash.sh"; then
  pass 'Bash core guard contains no bare narrow-override recipe'
else
  fail 'Bash core guard contains a bare narrow-override recipe'
fi

echo "[6] hook registry registration is complete and the new guard is profile-live"
for matcher in Write Edit MultiEdit; do
  count="$(jq --arg matcher "$matcher" '[.hooks.PreToolUse[] | select(.matcher == $matcher) | .hooks[] | select(.id == "validate-policy-frontmatter")] | length' "$REGISTRY")"
  if [[ "$count" == 1 ]]; then
    pass "validate-policy-frontmatter is registered once for $matcher"
  else
    fail "validate-policy-frontmatter must be registered once for $matcher (got $count)"
  fi
done
bash_count="$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.id == "block-policy-writes-bash")] | length' "$REGISTRY")"
if [[ "$bash_count" == 1 ]]; then
  pass 'policy Bash guard is registered once'
else
  fail "policy Bash guard must be registered once (got $bash_count)"
fi
for profile in minimal standard strict; do
  rc=0
  printf '%s' "$payload" | env -i PATH="$PATH" HOME="$HOME" CLAUDE_PROJECT_DIR="$TMP" \
    HQ_HOOK_PROFILE="$profile" "$POLICY_TEST_BASH" "$GATE" block-policy-writes-bash "$HOOK" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == 2 ]]; then
    pass "policy Bash guard blocks through $profile profile"
  else
    fail "policy Bash guard is not live in $profile profile (got $rc)"
  fi
done

echo "block-policy-writes-bash: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
