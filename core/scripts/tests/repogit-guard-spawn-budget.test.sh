#!/usr/bin/env bash
set -euo pipefail
TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
DEFAULT_ROOT="$(git -C "$TEST_DIR/../../.." rev-parse --show-toplevel)"
ROOT="${HOOK_ROOT_OVERRIDE:-$DEFAULT_ROOT}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SHIMS="$TMP/shims"
mkdir -p "$SHIMS"
ORIGINAL_PATH="$PATH"
COUNT_FILE="$TMP/external-commands.log"
# Deny-output hashes below come from origin/main 395c5d5005075f27b1ada44413468dd4f1a93472,
# with only the temporary fixture root replaced by <FIXTURE>.
for name in cat jq dirname basename realpath tr grep sed head git node hq awk cut sort; do
  real="$(type -P "$name" || true)"
  [[ -n "$real" ]] || continue
  {
    printf '#!/bin/bash\n'
    printf 'printf "%%s\\n" %q >> "$HQ_TEST_COUNT_FILE"\n' "$name"
    printf 'exec %q "$@"\n' "$real"
  } > "$SHIMS/$name"
  chmod +x "$SHIMS/$name"
done
FIXTURE="$TMP/hq-root"
COMPANY_COMPONENT=com
COMPANY_COMPONENT+=panies
mkdir -p "$FIXTURE/$COMPANY_COMPONENT/indigo" "$TMP/repo"
git -C "$FIXTURE" init -q
FAIL=0
PASS=0
run_hook() {
  local hook="$1" command_text="$2" label="$3" cwd="${4:-$FIXTURE}"
  local payload out err rc
  out="$TMP/$label.out"; err="$TMP/$label.err"; : > "$COUNT_FILE"
  payload="$(jq -cn --arg cwd "$cwd" --arg cmd "$command_text" \
    '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}')"
  rc=0
  printf '%s' "$payload" \
    | HQ_HOOK_TOOL_NAME=Bash HQ_HOOK_CWD="$cwd" HQ_HOOK_COMMAND="$command_text" \
      HQ_TEST_COUNT_FILE="$COUNT_FILE" CLAUDE_PROJECT_DIR="$FIXTURE" \
      PATH="$SHIMS:$ORIGINAL_PATH" /bin/bash "$ROOT/.claude/hooks/$hook" \
      >"$out" 2>"$err" || rc=$?
  printf '%s\n' "$rc" > "$TMP/$label.rc"
}
assert_budget() {
  local label="$1" budget="$2" count
  count="$(wc -l < "$COUNT_FILE" | tr -d ' ')"
  if (( count <= budget )); then
    PASS=$((PASS + 1)); printf 'PASS %s external_commands=%s budget=%s\n' "$label" "$count" "$budget"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %s external_commands=%s budget=%s helpers=%s\n' \
      "$label" "$count" "$budget" "$(tr '\n' ',' < "$COUNT_FILE")" >&2
  fi
}
hash_output() {
  local label="$1" normalized="$TMP/$label.normalized"
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "${line//"$FIXTURE"/<FIXTURE>}"
  done < "$TMP/$label.err" > "$normalized"
  sha256sum "$normalized" | awk '{print $1}'
}
assert_deny() {
  local label="$1" expected_rc="$2" expected_hash="$3" actual_rc actual_hash
  actual_rc="$(<"$TMP/$label.rc")"
  actual_hash="$(hash_output "$label")"
  if [[ "$actual_rc" == "$expected_rc" && ! -s "$TMP/$label.out" && ( -z "$expected_hash" || "$actual_hash" == "$expected_hash" ) ]]; then
    PASS=$((PASS + 1)); printf 'PASS %s denied exit=%s output_sha256=%s\n' "$label" "$actual_rc" "$actual_hash"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %s expected_exit=%s actual_exit=%s expected_sha=%s actual_sha=%s\n' \
      "$label" "$expected_rc" "$actual_rc" "$expected_hash" "$actual_hash" >&2
  fi
}
run_hook block-company-repo-creation.sh 'printf ready' bash-allow
assert_budget bash-allow 0
run_hook block-hq-root-git-mutation.sh 'printf ready' bash-allow-root
assert_budget bash-allow-root 0
run_hook block-company-repo-creation.sh 'git -C /tmp/repo status' git-status-allow
assert_budget git-status-allow 0
run_hook block-hq-root-git-mutation.sh 'git -C /tmp/repo status' git-status-allow-root
assert_budget git-status-allow-root 0
COMPANY_TARGET="$FIXTURE/$COMPANY_COMPONENT/indigo/new-repo"
run_hook block-company-repo-creation.sh \
  "git clone https://example.invalid/indigo/new-repo.git \"$COMPANY_TARGET\"" company-clone-deny
assert_deny company-clone-deny 2 687b18fe3a2a2ce68960332d555b0f9bb4d309fdfd7f253e3a2bf9a9eb0a611c
MULTILINE_CMD=$'git status\n git clone https://example.invalid/indigo/multiline.git "'"${COMPANY_TARGET}-multi"'"'
run_hook block-company-repo-creation.sh "$MULTILINE_CMD" company-multiline-deny
assert_deny company-multiline-deny 2 81580e9342d818018273a919c5b643c21d4c4e1c81cfe3cfc1e68365b8448cf0
run_hook block-company-repo-creation.sh \
  "git -C \"$FIXTURE/$COMPANY_COMPONENT/indigo\" init" company-quoted-c-deny
assert_deny company-quoted-c-deny 2 b5139f75fde8e60b7f16ff357629407440ffa287d23c739ddaf2125aefa74477
run_hook block-hq-root-git-mutation.sh 'git push origin main' root-bare-push-deny
assert_deny root-bare-push-deny 2 e09aa0c10aa8d5a01c329ae3dcd094e4e8bf244a68c9bc5f5ec8e007c9831aec
run_hook block-hq-root-git-mutation.sh \
  "git -C \"$FIXTURE\" commit -m test" root-quoted-c-deny
assert_deny root-quoted-c-deny 2 f8a5c03d89a29d20f4588318bfba98c62ac5f407a47e5f3df1f01a1e2fd5674b
if (( FAIL > 0 )); then
  printf 'repogit-guard-spawn-budget: %s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
printf 'repogit-guard-spawn-budget: %s passed, %s failed\n' "$PASS" "$FAIL"
