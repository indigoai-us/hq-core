#!/usr/bin/env bash
# hq-core: public
# inject-policy-repos-scope.test.sh
#
# The optional `repos: [name, ...]` policy field limits a policy to events
# that touch one of the listed repos. These tests pin:
#   [1] repos: [vyg] fires for `git -C repos/private/vyg commit` and does not
#       fire for a commit in another repo; an unscoped policy fires in both
#   [2] cwd inside the repo, an HQ worktree of the repo, and `gh -R owner/vyg`
#       all count; entries may be written as owner/name or repos/x/name
#   [3] block lists and multi-value lists; `repos: []` means every repo
#   [4] parse and evaluation caches do not leak verdicts across repos
#   [5] a company policy with repos: is filtered the same way
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HOOK="${HQ_POLICY_HOOK_UNDER_TEST:-$ROOT/.claude/hooks/inject-policy-on-trigger.sh}"
fail() { echo "FAIL: $*" >&2; [ -f "$FX/err.log" ] && tail -5 "$FX/err.log" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
CO="acme"
CO_POL="$FX/companies/$CO/policies"
mkdir -p "$FX/core/policies" "$FX/workspace/orchestrator/policy-trigger-state" \
  "$FX/core/scripts" "$FX/.claude/hooks" "$FX/repos/private/vyg" "$FX/repos/private/other" \
  "$FX/workspace/worktrees/vyg/feature-x" "$CO_POL"
cat > "$FX/core/scripts/hook-lib.sh" <<'LIB'
hq_json_get() { local key="$1"; jq -r --arg k "$key" 'if $k == "tool_input.command" then (.tool_input.command // "") elif $k == "hook_event_name" or $k == "session_id" or $k == "tool_name" or $k == "cwd" then .[$k] | if . == null or type == "object" or type == "array" then "" else tostring end else "" end'; }
LIB
printf '#!/bin/bash\necho always\n' > "$FX/core/scripts/derive-trigger-facts.sh"
printf '#!/bin/bash\nexit 0\n' > "$FX/core/scripts/eval-trigger.sh"
chmod +x "$FX/core/scripts/"*.sh
cp "$HOOK" "$FX/.claude/hooks/inject-policy-on-trigger.sh"

wp() { # <dir> <id> <repos-line-or-empty> <rule-text>
  local repos_line=""
  [ -n "$3" ] && repos_line="$3"$'\n'
  printf -- '---\nid: %s\ntitle: "%s"\nscope: test\nwhen: always\non: [PostToolUse]\nenforcement: soft\n%s---\n\n## Rule\n\n%s\n' \
    "$2" "$2" "$repos_line" "$4" > "$1/$2.md"
}
clear_policies() { rm -f "$FX/core/policies/"*.md "$CO_POL/"*.md; }

run() { # <session-id> <cwd> <command> [env...]
  local sid="$1" cwd="$2" cmd="$3" input
  shift 3
  input="$(jq -cn --arg sid "$sid" --arg cwd "$cwd" --arg cmd "$cmd" \
    '{session_id:$sid,hook_event_name:"PostToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd},tool_response:{exit_code:0}}')"
  env -u HQ_POLICY_WORKER_DIR HQ_SESSION_PRINCIPAL=human \
    HQ_ROOT="$FX" CLAUDE_PROJECT_DIR="$FX" "$@" \
    bash "$FX/.claude/hooks/inject-policy-on-trigger.sh" <<<"$input" 2>>"$FX/err.log"
}
sid() { printf 'repos-%s-%s-%s' "$1" "$$" "$RANDOM"; }
has() { grep -q "$1" <<<"$2"; }

echo "[1] repos: [vyg] fires only for the vyg repo; an unscoped policy fires everywhere"
clear_policies
wp "$FX/core/policies" vyg-only 'repos: [vyg]' "VYG ONLY rule"
wp "$FX/core/policies" everyone '' "EVERYONE rule"
out="$(run "$(sid vyg)" "$FX" "git -C repos/private/vyg commit -m x")"
has 'VYG ONLY rule' "$out" || fail "vyg-only missing for git -C repos/private/vyg: $out"
has 'EVERYONE rule' "$out" || fail "unscoped policy missing in vyg: $out"
out="$(run "$(sid other)" "$FX" "git -C repos/private/other commit -m x")"
! has 'vyg-only' "$out" || fail "vyg-only fired for a commit in another repo: $out"
has 'EVERYONE rule' "$out" || fail "unscoped policy missing in other repo: $out"
out="$(run "$(sid root)" "$FX" "ls")"
! has 'vyg-only' "$out" || fail "vyg-only fired with no repo in the event: $out"
# A repo whose name only starts with the listed name does not count.
out="$(run "$(sid prefix)" "$FX" "git -C repos/private/vyg-tools status")"
! has 'vyg-only' "$out" || fail "vyg-only fired for repo vyg-tools: $out"

echo "[2] cwd, HQ worktree, gh -R, and entry spellings"
out="$(run "$(sid cwd)" "$FX/repos/private/vyg" "git status")"
has 'VYG ONLY rule' "$out" || fail "vyg-only missing with cwd in the repo: $out"
out="$(run "$(sid wt)" "$FX/workspace/worktrees/vyg/feature-x" "git status")"
has 'VYG ONLY rule' "$out" || fail "vyg-only missing in an HQ worktree of the repo: $out"
out="$(run "$(sid gh)" "$FX" "gh pr view 3 -R acme-org/vyg")"
has 'VYG ONLY rule' "$out" || fail "vyg-only missing for gh -R owner/vyg: $out"
out="$(run "$(sid ghrepo)" "$FX" "gh pr list --repo=acme-org/vyg")"
has 'VYG ONLY rule' "$out" || fail "vyg-only missing for gh --repo=owner/vyg: $out"
clear_policies
wp "$FX/core/policies" owner-form 'repos: ["acme-org/VYG"]' "OWNER FORM rule"
wp "$FX/core/policies" path-form 'repos: [repos/private/vyg/]' "PATH FORM rule"
out="$(run "$(sid forms)" "$FX" "git -C repos/private/vyg log")"
has 'OWNER FORM rule' "$out" || fail "owner/name entry did not match: $out"
has 'PATH FORM rule' "$out" || fail "repos/x/name entry did not match: $out"

echo "[3] block lists, multi-value lists, empty list"
# One policy at a time, so the soft-match output budget never hides a result.
check_one() { # <id> <repos-line> <want-in-vyg 1|0> <want-with-no-repo 1|0>
  clear_policies
  wp "$FX/core/policies" "$1" "$2" "RULE $1"
  out="$(run "$(sid "$1-vyg")" "$FX" "git -C repos/private/vyg log")"
  if [ "$3" = 1 ]; then has "RULE $1" "$out" || fail "$1 missing in vyg: $out"
  else ! has "$1" "$out" || fail "$1 fired in vyg: $out"; fi
  out="$(run "$(sid "$1-none")" "$FX" "ls")"
  if [ "$4" = 1 ]; then has "RULE $1" "$out" || fail "$1 missing with no repo: $out"
  else ! has "$1" "$out" || fail "$1 fired with no repo: $out"; fi
}
check_one multi-inline 'repos: [other, vyg]' 1 0
check_one multi-block $'repos:\n  - other  # comment\n  - vyg' 1 0
check_one block-other $'repos:\n  - other' 0 0
check_one empty-list 'repos: []' 1 1

echo "[4] caches do not leak across repos"
clear_policies
rm -rf "$FX/workspace/orchestrator/hook-state/policy-trigger-cache"
wp "$FX/core/policies" cache-vyg 'repos: [vyg]' "CACHE VYG rule"
leak_sid="$(sid cache)"
out="$(run "$leak_sid" "$FX" "git -C repos/private/other log")"   # writes the parse cache
! has 'cache-vyg' "$out" || fail "cache-vyg fired in other (cold): $out"
out="$(run "$leak_sid" "$FX" "git -C repos/private/other log")"   # parse hit, writes eval cache
! has 'cache-vyg' "$out" || fail "cache-vyg fired in other (warm): $out"
cache_dir="$FX/workspace/orchestrator/hook-state/policy-trigger-cache"
cf="$(find "$cache_dir" -maxdepth 1 -name '*.cache' -print -quit)"
[ -n "$cf" ] || fail "parse cache was not written"
head -n 1 "$cf" | grep -Fq 'hq-policy-cache-v7' || fail "parse cache header was not bumped to v7"
out="$(run "$leak_sid" "$FX" "git -C repos/private/vyg log")"     # same session, cached parse
has 'CACHE VYG rule' "$out" || fail "cached other-repo verdict leaked into vyg: $out"

echo "[5] company policy with repos: is filtered"
clear_policies
rm -rf "$FX/workspace/orchestrator/hook-state/policy-trigger-cache"
wp "$CO_POL" co-vyg 'repos: [vyg]' "CO VYG rule"
wp "$CO_POL" co-all '' "CO ALL rule"
printf 'companies:\n  %s: {}\n' "$CO" > "$FX/companies/manifest.yaml"
out="$(run "$(sid co-vyg)" "$FX/companies/$CO" "git -C $FX/repos/private/vyg commit -m x" HQ_COMPANY="$CO")"
if has 'CO ALL rule' "$out"; then
  has 'CO VYG rule' "$out" || fail "company vyg policy missing for vyg commit: $out"
  out="$(run "$(sid co-other)" "$FX/companies/$CO" "git -C $FX/repos/private/other commit -m x" HQ_COMPANY="$CO")"
  has 'CO ALL rule' "$out" || fail "unscoped company policy missing in other repo: $out"
  ! has 'co-vyg' "$out" || fail "company vyg policy fired in other repo: $out"
else
  fail "company scope did not resolve in this fixture: $out"
fi

echo "PASS: inject-policy repos scoping"
