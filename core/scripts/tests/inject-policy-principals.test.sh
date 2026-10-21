#!/usr/bin/env bash
# hq-core: public
# inject-policy-principals.test.sh
#
# The optional `principals: [human|agent|bot]` policy field limits which
# session principal a policy is injected for. These tests pin:
#   [1] principals: [agent] is not injected for a human session and is injected
#       under HQ_SESSION_PRINCIPAL=agent; an untagged policy reaches everyone
#   [2] session principal resolution: override, invalid override, fleet env,
#       HQ_AGENT_ROOT_PREFIX identity file, bot env, human default
#   [3] block-list syntax and multi-value lists
#   [4] filtered policies do not consume the output ceiling
#   [5] parse and evaluation caches do not leak verdicts across principals
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HOOK="${HQ_POLICY_HOOK_UNDER_TEST:-$ROOT/.claude/hooks/inject-policy-on-trigger.sh}"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
NOAGENT_ROOT="$FX/no-agent-root"
mkdir -p "$FX/core/policies" "$FX/workspace/orchestrator/policy-trigger-state" \
  "$FX/core/scripts" "$FX/.claude/hooks" "$NOAGENT_ROOT"
cat > "$FX/core/scripts/hook-lib.sh" <<'LIB'
hq_json_get() { local key="$1"; jq -r --arg k "$key" 'if $k == "hook_event_name" or $k == "session_id" or $k == "tool_name" or $k == "cwd" then .[$k] | if . == null or type == "object" or type == "array" then "" else tostring end else "" end'; }
LIB
printf '#!/bin/bash\necho always\n' > "$FX/core/scripts/derive-trigger-facts.sh"
printf '#!/bin/bash\nexit 0\n' > "$FX/core/scripts/eval-trigger.sh"
chmod +x "$FX/core/scripts/"*.sh
cp "$HOOK" "$FX/.claude/hooks/inject-policy-on-trigger.sh"

wp() { # <id> <principals-line-or-empty> <rule-text>
  local principals_line=""
  [ -n "$2" ] && principals_line="$2"$'\n'
  printf -- '---\nid: %s\ntitle: "%s"\nscope: test\nwhen: always\non: [UserPromptSubmit]\nenforcement: soft\n%s---\n\n## Rule\n\n%s\n' \
    "$1" "$1" "$principals_line" "$3" > "$FX/core/policies/$1.md"
}
clear_policies() { rm -f "$FX/core/policies/"*.md; }

# Every run starts from a neutral principal environment so the host running
# the test cannot leak its own fleet or bot identity into the result.
run() { # <session-id> <extra env...>
  local sid="$1" input
  shift
  input="$(jq -cn --arg sid "$sid" --arg cwd "$FX" '{session_id:$sid,hook_event_name:"UserPromptSubmit",cwd:$cwd,prompt:"x"}')"
  env -u HQ_POLICY_WORKER_DIR -u HQ_SESSION_PRINCIPAL -u HQ_AGENT_WORKDIR -u HQ_AGENT_COMPANY_DIR \
    -u HQ_AGENT_IDENTITY_FILE -u HQ_BOT_AGENT_UID -u HQ_MACHINE_CREDS_FILE \
    HQ_AGENT_ROOT_PREFIX="$NOAGENT_ROOT" HQ_ROOT="$FX" CLAUDE_PROJECT_DIR="$FX" "$@" \
    bash "$FX/.claude/hooks/inject-policy-on-trigger.sh" <<<"$input" 2>/dev/null
}
sid() { printf 'principals-%s-%s-%s' "$1" "$$" "$RANDOM"; }

echo "[1] agent-only policy is filtered for humans; untagged policy reaches everyone"
if [ -f /etc/hq-agent/identity.json ] || [ -f /etc/hq-agent/machine-creds.json ] \
  || [ -f /var/lib/hq-agent/machine-creds.json ]; then
  echo "SKIP-HOST: this host has a fleet identity file; the human default cannot be observed here" >&2
  HOST_IS_AGENT=1
else
  HOST_IS_AGENT=0
fi
clear_policies
wp agent-only 'principals: [agent]' "AGENT ONLY rule"
wp everyone '' "EVERYONE rule"
out="$(run "$(sid human)")"
grep -q 'EVERYONE rule' <<<"$out" || fail "untagged policy missing for default session: $out"
if [ "$HOST_IS_AGENT" = "0" ]; then
  ! grep -q 'agent-only' <<<"$out" || fail "agent-only policy injected for a human session: $out"
fi
out="$(run "$(sid explicit-human)" HQ_SESSION_PRINCIPAL=human)"
! grep -q 'agent-only' <<<"$out" || fail "agent-only policy injected under HQ_SESSION_PRINCIPAL=human: $out"
grep -q 'EVERYONE rule' <<<"$out" || fail "untagged policy missing for human session: $out"
out="$(run "$(sid agent)" HQ_SESSION_PRINCIPAL=agent)"
grep -q 'AGENT ONLY rule' <<<"$out" || fail "agent-only policy missing under HQ_SESSION_PRINCIPAL=agent: $out"
grep -q 'EVERYONE rule' <<<"$out" || fail "untagged policy missing for agent session: $out"
out="$(run "$(sid bot)" HQ_SESSION_PRINCIPAL=bot)"
! grep -q 'agent-only' <<<"$out" || fail "agent-only policy injected for a bot session: $out"
grep -q 'EVERYONE rule' <<<"$out" || fail "untagged policy missing for bot session: $out"

echo "[2] session principal resolution"
clear_policies
wp p-human 'principals: [human]' "HUMAN rule"
wp p-agent 'principals: [agent]' "AGENT rule"
wp p-bot 'principals: [bot]' "BOT rule"
expect_only() { # <label> <expected human|agent|bot> <env...>
  local label="$1" want="$2" got
  shift 2
  got="$(run "$(sid "$label")" "$@")"
  for p in human agent bot; do
    up="$(printf '%s' "$p" | tr '[:lower:]' '[:upper:]')"
    if [ "$p" = "$want" ]; then
      grep -q "$up rule" <<<"$got" || fail "$label: expected principal $want, $p policy missing: $got"
    else
      ! grep -q "p-$p" <<<"$got" || fail "$label: expected principal $want, $p policy injected: $got"
    fi
  done
}
mkdir -p "$FX/fake-root/var/lib/hq-agent"
printf '{}\n' > "$FX/fake-root/var/lib/hq-agent/identity.json"
[ "$HOST_IS_AGENT" = "1" ] || expect_only default human
expect_only override-agent agent HQ_SESSION_PRINCIPAL=agent
expect_only override-bot bot HQ_SESSION_PRINCIPAL=bot
expect_only override-human-beats-fleet human HQ_SESSION_PRINCIPAL=human HQ_AGENT_WORKDIR=/tmp/w
expect_only invalid-override-ignored agent HQ_SESSION_PRINCIPAL=robot HQ_AGENT_WORKDIR=/tmp/w
expect_only agent-workdir agent HQ_AGENT_WORKDIR=/tmp/w
expect_only agent-company-dir agent HQ_AGENT_COMPANY_DIR=/tmp/c
expect_only agent-identity-file agent HQ_AGENT_IDENTITY_FILE=/tmp/i.json
expect_only agent-root-prefix agent HQ_AGENT_ROOT_PREFIX="$FX/fake-root"
expect_only agent-beats-bot agent HQ_AGENT_WORKDIR=/tmp/w HQ_BOT_AGENT_UID=u1
if [ "$HOST_IS_AGENT" = "0" ]; then
  expect_only bot-uid bot HQ_BOT_AGENT_UID=u1
  expect_only bot-machine-creds bot HQ_MACHINE_CREDS_FILE=/tmp/m.json
  expect_only empty-override-human human HQ_SESSION_PRINCIPAL=
  expect_only invalid-override-human human HQ_SESSION_PRINCIPAL=AGENT
fi

echo "[3] block lists and multi-value lists"
clear_policies
wp multi-inline 'principals: [human, "bot"]' "MULTI INLINE rule"
wp multi-block $'principals:\n  - agent\n  - bot' "MULTI BLOCK rule"
wp invalid-only 'principals: [robot]' "INVALID ONLY rule"
out="$(run "$(sid multi-human)" HQ_SESSION_PRINCIPAL=human)"
grep -q 'MULTI INLINE rule' <<<"$out" || fail "inline [human, bot] missing for human: $out"
! grep -q 'multi-block' <<<"$out" || fail "block [agent, bot] injected for human: $out"
out="$(run "$(sid multi-agent)" HQ_SESSION_PRINCIPAL=agent)"
grep -q 'MULTI BLOCK rule' <<<"$out" || fail "block [agent, bot] missing for agent: $out"
! grep -q 'multi-inline' <<<"$out" || fail "inline [human, bot] injected for agent: $out"
out="$(run "$(sid multi-bot)" HQ_SESSION_PRINCIPAL=bot)"
grep -q 'MULTI INLINE rule' <<<"$out" || fail "inline [human, bot] missing for bot: $out"
grep -q 'MULTI BLOCK rule' <<<"$out" || fail "block [agent, bot] missing for bot: $out"
# A list with no recognized value is a lint error; at runtime it must not hide
# the policy, so it falls back to everyone.
grep -q 'INVALID ONLY rule' <<<"$out" || fail "policy with only unknown principals was hidden: $out"

echo "[4] filtered policies do not consume the output ceiling"
clear_policies
long="$(printf 'agent filler text %.0s' $(seq 1 6))"
for i in 01 02 03 04 05 06 07 08 09 10; do
  wp "a-agent-$i" 'principals: [agent]' "AGENT $i $long"
done
wp z-everyone '' "Z EVERYONE rule"
CEIL=700
out="$(run "$(sid ceil-agent)" HQ_SESSION_PRINCIPAL=agent HQ_POLICY_OUTPUT_CEILING_BYTES=$CEIL)"
grep -q 'cut from this reminder\|shortened\|omitted' <<<"$out" \
  || fail "fixture does not exceed the ceiling for an agent session; the test proves nothing: $out"
out="$(run "$(sid ceil-human)" HQ_SESSION_PRINCIPAL=human HQ_POLICY_OUTPUT_CEILING_BYTES=$CEIL)"
grep -q 'Z EVERYONE rule' <<<"$out" || fail "filtered agent policies consumed the human ceiling: $out"
! grep -q 'a-agent-' <<<"$out" || fail "agent policy injected for human under ceiling: $out"
! grep -q 'cut from this reminder' <<<"$out" || fail "filtered policies counted against the ceiling: $out"

echo "[5] caches do not leak across principals"
clear_policies
rm -rf "$FX/workspace/orchestrator/hook-state/policy-trigger-cache"
wp cache-agent 'principals: [agent]' "CACHE AGENT rule"
leak_sid="$(sid cache)"
out="$(run "$leak_sid" HQ_SESSION_PRINCIPAL=human)"    # writes the parse cache
[ -z "$out" ] || ! grep -q 'cache-agent' <<<"$out" || fail "cache-agent injected for human (cold): $out"
out="$(run "$leak_sid" HQ_SESSION_PRINCIPAL=human)"    # parse cache hit, writes the eval cache
! grep -q 'cache-agent' <<<"$out" || fail "cache-agent injected for human (warm): $out"
cache_dir="$FX/workspace/orchestrator/hook-state/policy-trigger-cache"
find "$cache_dir" -maxdepth 1 -name '*.cache' -print -quit | grep -q . || fail "parse cache was not written"
head -n 1 "$(find "$cache_dir" -maxdepth 1 -name '*.cache' -print -quit)" | grep -Fq 'hq-policy-cache-v5' \
  || fail "parse cache header was not bumped to v5"
find "$cache_dir/eval-v9" -name '*.eval' -print -quit | grep -q . || fail "eval cache was not written"
out="$(run "$leak_sid" HQ_SESSION_PRINCIPAL=agent)"    # same session, same facts, same ledger
grep -q 'CACHE AGENT rule' <<<"$out" || fail "cached human verdict leaked into the agent session: $out"

# An older parse cache (v4 records lack the omitted-on marker) must be rebuilt, not decoded.
rm -rf "$cache_dir"
v3_sid="$(sid v3)"
run "$v3_sid" HQ_SESSION_PRINCIPAL=human >/dev/null
cf="$(find "$cache_dir" -maxdepth 1 -name '*.cache' -print -quit)"
sed '1s/hq-policy-cache-v5/hq-policy-cache-v4/' "$cf" > "$cf.tmp" && mv "$cf.tmp" "$cf"
out="$(run "$(sid v3-human)" HQ_SESSION_PRINCIPAL=human)"
! grep -q 'cache-agent' <<<"$out" || fail "stale v4 cache let agent policy through for human: $out"
head -n 1 "$cf" | grep -Fq 'hq-policy-cache-v5' || fail "stale v4 cache was not rewritten as v5"

echo "PASS: inject-policy principals filtering"
