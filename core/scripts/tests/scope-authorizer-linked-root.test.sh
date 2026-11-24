#!/usr/bin/env bash
# hq-core: public
# A linked HQ root (a real directory whose .claude, core and companies are
# links into a shared install, as for the shell user on a company Outpost)
# keeps its own workspace/sessions. The scope authorizer must read the
# session binding from that root, not from the install the links point at.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HOOK_SOURCE="${SCOPE_HOOK_SOURCE:-$ROOT/.claude/hooks/mandatory-scope-authorizer.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

failures=0
checks=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

SID="0b6f3c1e-4d2a-4f8e-9c1b-7a5d2e8f9a10"
UNBOUND_SID="5c2e9a7b-1f3d-4e6a-8b0c-2d4f6a8c0e12"
RELEASE="$TMP/opt/hq-company-jobs"
LINKED="$TMP/home/shell-user/hq"
DECOY="$TMP/decoy-hq"

bind_session() {
  local root="$1" sid="$2" slug="$3"
  mkdir -p "$root/workspace/sessions/$sid"
  printf 'session_id: %s\ncompany_slug: %s\ncompany_source: spawn\n' "$sid" "$slug" \
    > "$root/workspace/sessions/$sid/meta.yaml"
  jq -cn --arg sid "$sid" --arg slug "$slug" '{session_id:$sid,company_slug:$slug,minted_at:"2026-11-20T00:00:00Z"}' \
    > "$root/workspace/sessions/$sid/scope-capability.json"
}

install_hooks() {
  local root="$1"
  mkdir -p "$root/.claude/hooks" "$root/core/scripts/lib"
  cp "$HOOK_SOURCE" "$root/.claude/hooks/mandatory-scope-authorizer.sh"
  cp "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$ROOT/.claude/hooks/path-fold-lib.sh" "$root/.claude/hooks/"
  cp "$ROOT/core/scripts/lib/session-authz.sh" "$ROOT/core/scripts/lib/session-scope-capability.sh" \
    "$ROOT/core/scripts/lib/session-id.sh" "$root/core/scripts/lib/"
  cp "$ROOT/core/scripts/hook-lib.sh" "$root/core/scripts/"
}

install_hooks "$RELEASE"
mkdir -p "$RELEASE/companies/indigo/knowledge" "$RELEASE/companies/otherco/knowledge" "$RELEASE/workspace/sessions"
printf 'companies:\n  indigo:\n    name: indigo\n  otherco:\n    name: otherco\n' > "$RELEASE/companies/manifest.yaml"
printf 'indigo fixture\n' > "$RELEASE/companies/indigo/knowledge/a.md"
printf 'otherco fixture\n' > "$RELEASE/companies/otherco/knowledge/b.md"

mkdir -p "$LINKED/workspace/sessions" "$LINKED/personal"
ln -s "$RELEASE/.claude" "$LINKED/.claude"
ln -s "$RELEASE/core" "$LINKED/core"
ln -s "$RELEASE/companies" "$LINKED/companies"
bind_session "$LINKED" "$SID" indigo

run_case() {
  local label="$1" project_dir="$2" hook="$3" session="$4" tool="$5" arg="$6" expected="$7"
  local tool_input payload rc=0 stderr_file
  checks=$((checks + 1))
  stderr_file="$TMP/stderr-$checks"
  case "$tool" in
    Read) tool_input="$(jq -cn --arg p "$arg" '{file_path:$p}')" ;;
    Bash) tool_input="$(jq -cn --arg c "$arg" '{command:$c}')" ;;
    *) fail "$label has unsupported tool $tool"; return ;;
  esac
  payload="$(jq -cn --arg tool "$tool" --arg session "$session" --arg cwd "$project_dir" --argjson input "$tool_input" \
    '{tool_name:$tool,session_id:$session,cwd:$cwd,tool_input:$input}')"
  printf '%s' "$payload" | (cd "$project_dir" && CLAUDE_CONFIG_DIR="$TMP/claude-config" CLAUDE_PROJECT_DIR="$project_dir" \
    bash "$hook" 2>"$stderr_file") || rc=$?
  printf '%-72s exit=%s\n' "$label" "$rc"
  if [ "$rc" -ne "$expected" ]; then
    fail "$label expected exit $expected, got $rc: $(head -c 400 "$stderr_file")"
  fi
}

LINKED_HOOK="$LINKED/.claude/hooks/mandatory-scope-authorizer.sh"
RELEASE_HOOK="$RELEASE/.claude/hooks/mandatory-scope-authorizer.sh"

echo '[linked root: the binding in its own workspace is honoured]'
run_case 'Read bound company through the install path' "$LINKED" "$LINKED_HOOK" "$SID" Read \
  "$RELEASE/companies/indigo/knowledge/a.md" 0
run_case 'Read bound company through the linked root path' "$LINKED" "$LINKED_HOOK" "$SID" Read \
  "$LINKED/companies/indigo/knowledge/a.md" 0
run_case 'Bash count of the bound company knowledge files' "$LINKED" "$LINKED_HOOK" "$SID" Bash \
  "find $RELEASE/companies/indigo/knowledge -type f | wc -l" 0
run_case 'Bash relative read of the bound company' "$LINKED" "$LINKED_HOOK" "$SID" Bash \
  'cat companies/indigo/knowledge/a.md' 0

echo '[linked root: other companies and unbound sessions stay blocked]'
run_case 'Read another company through the install path' "$LINKED" "$LINKED_HOOK" "$SID" Read \
  "$RELEASE/companies/otherco/knowledge/b.md" 2
run_case 'Bash relative read of another company' "$LINKED" "$LINKED_HOOK" "$SID" Bash \
  'cat companies/otherco/knowledge/b.md' 2
run_case 'Unbound session reading the company' "$LINKED" "$LINKED_HOOK" "$UNBOUND_SID" Read \
  "$RELEASE/companies/indigo/knowledge/a.md" 2

echo '[a project dir that does not run this install is not trusted]'
install_hooks "$DECOY"
ln -s "$RELEASE/companies" "$DECOY/companies"
bind_session "$DECOY" "$SID" otherco
run_case 'Decoy project dir with its own hook copy cannot rebind' "$DECOY" "$RELEASE_HOOK" "$SID" Read \
  "$RELEASE/companies/otherco/knowledge/b.md" 2
rm -rf "$DECOY"
mkdir -p "$DECOY/workspace" "$DECOY/core/scripts/lib"
ln -s "$RELEASE/.claude" "$DECOY/.claude"
ln -s "$RELEASE/companies" "$DECOY/companies"
cp "$ROOT/core/scripts/lib/session-authz.sh" "$DECOY/core/scripts/lib/"
bind_session "$DECOY" "$SID" otherco
run_case 'Decoy project dir with a copied core cannot rebind' "$DECOY" "$RELEASE_HOOK" "$SID" Read \
  "$RELEASE/companies/otherco/knowledge/b.md" 2

rm -rf "$DECOY"
mkdir -p "$DECOY/companies"
ln -s "$RELEASE/.claude" "$DECOY/.claude"
ln -s "$RELEASE/core" "$DECOY/core"
printf 'companies:\n' > "$DECOY/companies/manifest.yaml"
bind_session "$DECOY" "$SID" indigo
run_case 'Decoy project dir with its own near-empty companies folder' "$DECOY" "$DECOY/.claude/hooks/mandatory-scope-authorizer.sh" \
  "$SID" Read "$RELEASE/companies/otherco/knowledge/b.md" 2

rm -rf "$DECOY"
mkdir -p "$DECOY/workspace/sessions" "$DECOY/core/scripts/lib"
ln -s "$RELEASE/.claude" "$DECOY/.claude"
ln -s "$RELEASE/companies" "$DECOY/companies"
ln -s "$RELEASE/core/scripts/lib/session-authz.sh" "$DECOY/core/scripts/lib/session-authz.sh"
cp "$RELEASE/core/scripts/lib/session-id.sh" "$DECOY/core/scripts/lib/"
cp "$RELEASE/core/scripts/hook-lib.sh" "$DECOY/core/scripts/"
jq -cn --arg sid "$UNBOUND_SID" '{session_id:$sid,company_slug:"otherco",minted_at:"2026-11-20T00:00:00Z"}' > "$DECOY/forged.json"
{
  cat "$RELEASE/core/scripts/lib/session-scope-capability.sh"
  printf 'session_scope_capability_path() { printf %%s %q; }\n' "$DECOY/forged.json"
  printf 'session_scope_read() { printf otherco; }\n'
} > "$DECOY/core/scripts/lib/session-scope-capability.sh"
run_case 'Decoy project dir with a planted capability library' "$DECOY" "$DECOY/.claude/hooks/mandatory-scope-authorizer.sh" \
  "$UNBOUND_SID" Read "$RELEASE/companies/otherco/knowledge/b.md" 2
rm -rf "$DECOY"

echo '[plain root: unchanged]'
bind_session "$RELEASE" "$SID" otherco
run_case 'Plain root reads the binding from its own workspace' "$RELEASE" "$RELEASE_HOOK" "$SID" Read \
  "$RELEASE/companies/otherco/knowledge/b.md" 0
run_case 'Plain root still blocks the unbound company' "$RELEASE" "$RELEASE_HOOK" "$SID" Read \
  "$RELEASE/companies/indigo/knowledge/a.md" 2

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures of $checks checks failed" >&2
  exit 1
fi
echo "all $checks checks passed"
