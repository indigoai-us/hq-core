#!/usr/bin/env bash
# intent-hint.test.sh — the UserPromptSubmit intent hint prints the closest
# intent-index entries for a plain-language prompt, stays silent for slash
# commands and empty prompts, prefers a local index, caps the count, and can be
# disabled.
set -euo pipefail
HQ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$HQ_ROOT/.claude/hooks/intent-hint.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$TMP/core/scripts" "$TMP/core/settings" "$TMP/.claude/hooks"
cp "$HQ_ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/hook-lib.sh"
cat > "$TMP/core/settings/intent-index.yaml" <<'YAML'
# test index
version: 1
scope: shipped
builtins:
  - name: "web"
    use: "Facts outside HQ."
    keywords: "x, twitter, posts, links"
  - name: "integrations"
    use: "Connected apps through the HQ gateway."
    keywords: "slack, linear, gmail"
skills:
  - name: "/deploy"
    use: "Deploy or share generated HQ artifacts."
  - name: "/brainstorm"
    use: "Compare approaches before PRD work."
    args: "[company] <idea>"
  - name: "/search"
    use: "Search HQ content."
    keywords: "find, where, happened"
YAML
run() { printf '{"session_id":"t","prompt":%s}' "$(printf '%s' "$1" | jq -Rs .)" | HQ_ROOT="$TMP" bash "$HOOK"; }

out="$(run "summarize everything that happened in slack")"
grep -q '^<intent-hints>' <<<"$out" || fail "no hints block for slack prompt"
grep -q '^integrations: ' <<<"$out" || fail "slack prompt should hint integrations"
grep -q '^/search: ' <<<"$out" || fail "'happened' should hint /search"
grep -q 'web' <<<"$out" && fail "web should not match the slack prompt"
echo "ok 1 keyword hits"

out="$(run "get me links to the posts about us on X from last week")"
first="$(grep -m1 -v '^<' <<<"$out")"
case "$first" in "web: "*) ;; *) fail "web should rank first for the X prompt, got: $first" ;; esac
echo "ok 2 ranking by score"

out="$(run "please deploy the investor pitch and then brainstorm a follow-up")"
grep -q '^/deploy: ' <<<"$out" || fail "skill name as a word should hit /deploy"
grep -q '^/brainstorm: ' <<<"$out" || fail "skill name as a word should hit /brainstorm"
echo "ok 3 skill names"

[ -z "$(run "/startwork acme")" ] || fail "bare slash command must stay silent"
out="$(run "/startwork acme summarize everything that happened in slack")"
grep -q '^integrations: ' <<<"$out" || fail "slash command arguments should still be matched"
[ -z "$(run "/deploy now")" ] || fail "the command token itself must not hint its own skill"
[ -z "$(run "")" ] || fail "empty prompt must stay silent"
[ -z "$(run "hello there")" ] || fail "no match must stay silent"
[ -z "$(printf '{"session_id":"t","prompt":"slack"}' | HQ_ROOT="$TMP" HQ_INTENT_HINT=0 bash "$HOOK")" ] || fail "HQ_INTENT_HINT=0 must disable"
[ -z "$(printf '{"session_id":"t","prompt":"slack"}' | HQ_ROOT="$TMP" HQ_DISABLED_HOOKS=intent-hint bash "$HOOK")" ] || fail "HQ_DISABLED_HOOKS must disable"
echo "ok 4 silence and kill switches"

out="$(printf '{"session_id":"t","prompt":"slack x deploy brainstorm find"}' | HQ_ROOT="$TMP" HQ_INTENT_HINT_MAX=2 bash "$HOOK")"
[ "$(grep -c -E '^(/|[a-z]+: )' <<<"$out")" -le 2 ] || fail "cap of 2 exceeded: $out"
echo "ok 5 cap"

mkdir -p "$TMP/workspace/orchestrator"
printf 'skills:\n  - name: "/acme:crm"\n    use: "Company CRM."\n    keywords: "slack"\n' > "$TMP/workspace/orchestrator/intent-index.yaml"
out="$(run "post this in slack")"
grep -q '^/acme:crm: ' <<<"$out" || fail "local index should win when present"
echo "ok 6 local index wins"
echo "intent-hint.test.sh: 6/6 passed"
