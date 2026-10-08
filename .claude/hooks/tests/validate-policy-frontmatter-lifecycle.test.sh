#!/bin/bash
# validate-policy-frontmatter-lifecycle.test.sh — lifecycle and gate fields.
#
# Covers the optional fields documented in policies-spec.md "Lifecycle Fields"
# and "Gate Block" on BOTH analyzer engines (node and the jq/awk port), plus
# the --all batch mode.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/validate-policy-frontmatter.sh"

pass=0; fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

policy() {  # $1 = extra frontmatter lines
  printf -- '---\nid: test-lifecycle\ntitle: Test\nwhen: git && push\non: [PreToolUse]\nenforcement: soft\nversion: 1\ncreated: 2026-10-07\nupdated: 2026-10-07\n%s---\n\n## Rule\n\nDo the thing.\n' "$1"
}

run() {  # $1 engine, $2 content -> sets RC, ERR
  ERR="$(jq -n --arg c "$2" '{tool_input:{file_path:"/x/personal/policies/t.md", content:$c}}' \
    | HQ_HOOK_ENGINE="$1" HQ_ROOT="$ROOT" bash "$HOOK" 2>&1 >/dev/null)"
  RC=$?
}

expect() {  # $1 name, $2 want-rc, $3 field-or-empty, $4 frontmatter extra
  local engine
  for engine in node jq; do
    run "$engine" "$(policy "$4")"
    if [ "$RC" = "$2" ] && { [ -z "$3" ] || printf '%s' "$ERR" | grep -q "\`$3\`"; }; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1)); echo "FAIL [$engine] $1: rc=$RC want=$2 field=$3"; printf '%s\n' "$ERR" | head -3
    fi
  done
}

# accepted
expect "no lifecycle fields"          0 "" ""
expect "status active"                0 "" $'status: active\n'
expect "status superseded"            0 "" $'status: superseded\n'
expect "retired with all fields"      0 "" $'status: retired\nretired_at: 2026-09-08T01:40:32Z\nretired_by: policy-retire.sh\nretired_reason: superseded by x\n'
expect "last_confirmed date"          0 "" $'last_confirmed: 2026-10-01\n'
expect "retire_when plain text"       0 "" $'retire_when: hq-cli 6.0 ships the native fix\n'
expect "supersedes comma string"      0 "" $'supersedes: a-one, b-two\n'
expect "supersedes list"              0 "" $'supersedes: [a-one, b-two]\n'
expect "gate with tools"              0 "" $'gate:\n  tools: [mcp__hq-work__send_email]\n  requires: [recipients_confirmed]\n  freshness: 60\n  override: allowed\n'
expect "gate with bash only"          0 "" $'gate:\n  bash: [gws gmail send]\n  requires: [draft_approved]\n'
expect "gate line with comment"       0 "" $'enforcement: gate\ngate:   # c\n  bash: [gws]\n  requires: [x]\n'
expect "gate scalar is not a block"   0 "" $'gate: some note\n'
expect "retire_when comment ignored"  0 "" $'retire_when: tool ships # (later)\n'
expect "supersedes block list"        0 "" $'supersedes:\n  - a-one\n  - "b-two"\n'
expect "gate empty-string is scalar"  0 "" $'gate: ""\n'
expect "duplicate key first wins"     0 "" $'enforcement: gate\n'
expect "gate quoted freshness"        0 "" $'gate:\n  tools: [x]\n  requires: [y]\n  freshness: "60"\n'

# rejected, naming the field
expect "status outside enum"          2 status         $'status: archived\n'
expect "retired_at without retired"   2 retired_at     $'retired_at: 2026-09-08T01:40:32Z\n'
expect "retired_by with active"       2 retired_by     $'status: active\nretired_by: someone\n'
expect "last_confirmed not a date"    2 last_confirmed $'last_confirmed: last week\n'
expect "retire_when with quote"       2 retire_when    $'retire_when: "fixed"\n'
expect "retire_when with regex"       2 retire_when    $'retire_when: v6.* ships\n'
expect "supersedes bad id"            2 supersedes     $'supersedes: [ok-id, bad id!]\n'
expect "supersedes block bad id"      2 supersedes     $'supersedes:\n  - ok-id\n  - "bad id!"\n'
expect "gate missing tools and bash"  2 gate.tools     $'gate:\n  requires: [recipients_confirmed]\n'
expect "gate empty tools"             2 gate.tools     $'gate:\n  tools: []\n  requires: [recipients_confirmed]\n'
expect "gate missing requires"        2 gate.requires  $'gate:\n  tools: [x]\n'
expect "gate empty-string requires"   2 gate.requires  $'gate:\n  tools: [x]\n  requires: ""\n'
expect "gate unknown key"             2 gate.when      $'gate:\n  tools: [x]\n  requires: [draft_approved]\n  when: always\n'
expect "gate bad freshness"           2 gate.freshness $'gate:\n  tools: [x]\n  requires: [draft_approved]\n  freshness: soon\n'
expect "gate bad override"            2 gate.override  $'gate:\n  tools: [x]\n  requires: [draft_approved]\n  override: maybe\n'

# enforcement: gate without a gate block
for engine in node jq; do
  run "$engine" "$(policy "" | sed 's/^enforcement: soft$/enforcement: gate/')"
  if [ "$RC" = 2 ] && printf '%s' "$ERR" | grep -q '`gate`'; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "FAIL [$engine] enforcement gate without block: rc=$RC"; fi
done

# --all: names the offending file and field, exits 1; clean tree exits 0
mkdir -p "$TMP/core/policies" "$TMP/personal/policies" "$TMP/companies/acme/policies" "$TMP/core/scripts" "$TMP/.claude/hooks"
cp "$ROOT/core/scripts/eval-trigger.sh" "$TMP/core/scripts/"
cp "$HOOK" "$TMP/.claude/hooks/"
policy "" > "$TMP/core/policies/good.md"
policy $'status: retired\nretired_at: 2026-09-08\n' > "$TMP/personal/policies/good-retired.md"
OUT="$(HQ_ROOT="$TMP" bash "$TMP/.claude/hooks/validate-policy-frontmatter.sh" --all 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL --all clean tree: rc=$RC"; echo "$OUT"; fi
policy $'status: archived\n' > "$TMP/companies/acme/policies/bad.md"
OUT="$(HQ_ROOT="$TMP" bash "$TMP/.claude/hooks/validate-policy-frontmatter.sh" --all 2>&1)"; RC=$?
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'FAIL companies/acme/policies/bad.md: .*`status`'; then pass=$((pass + 1))
else fail=$((fail + 1)); echo "FAIL --all bad file: rc=$RC"; echo "$OUT"; fi

# --all is baseline-aware: a failure already present at the base ref is a
# WARN and does not fail the gate; a new or changed failing file does.
git -C "$TMP" init -q
git -C "$TMP" add -A
git -C "$TMP" -c user.email=t@example.com -c user.name=t commit -qm base
OUT="$(HQ_ROOT="$TMP" HQ_POLICY_BASELINE_REF=HEAD bash "$TMP/.claude/hooks/validate-policy-frontmatter.sh" --all 2>&1)"; RC=$?
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'WARN companies/acme/policies/bad.md: .*(pre-existing)' \
  && printf '%s' "$OUT" | grep -q 'baseline failing: 1 | current failing: 1'; then pass=$((pass + 1))
else fail=$((fail + 1)); echo "FAIL --all pre-existing failure should pass: rc=$RC"; echo "$OUT"; fi
OUT="$(HQ_ROOT="$TMP" HQ_POLICY_BASELINE_REF=HEAD bash "$TMP/.claude/hooks/validate-policy-frontmatter.sh" --all --strict 2>&1)"; RC=$?
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'FAIL companies/acme/policies/bad.md'; then pass=$((pass + 1))
else fail=$((fail + 1)); echo "FAIL --all --strict should fail on pre-existing: rc=$RC"; echo "$OUT"; fi
policy $'last_confirmed: last week\n' > "$TMP/personal/policies/new-bad.md"
OUT="$(HQ_ROOT="$TMP" HQ_POLICY_BASELINE_REF=HEAD bash "$TMP/.claude/hooks/validate-policy-frontmatter.sh" --all 2>&1)"; RC=$?
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'FAIL personal/policies/new-bad.md: .*`last_confirmed`' \
  && printf '%s' "$OUT" | grep -q 'baseline failing: 1 | current failing: 2'; then pass=$((pass + 1))
else fail=$((fail + 1)); echo "FAIL --all new failure should fail: rc=$RC"; echo "$OUT"; fi

echo "validate-policy-frontmatter-lifecycle: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
