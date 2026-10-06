#!/usr/bin/env bash
set -uo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
outpost="$repo_root/.claude/skills/outpost-host/SKILL.md"
accept="$repo_root/.claude/skills/accept/SKILL.md"
promote="$repo_root/.claude/skills/promote/SKILL.md"
failures=0
if grep -Fq 'bash "$CLAUDE_PLUGIN_ROOT/skills/outpost-host/host-app.sh" check' "$outpost"; then
  echo 'ok   outpost-host resolves its script from the installed plugin root'
else
  echo 'not ok   outpost-host resolves its script from the installed plugin root'
  failures=$((failures + 1))
fi
if grep -Fq '~/.hq/cognito-tokens.json' "$accept"; then
  echo 'ok   accept skill names the canonical Cognito token cache'
else
  echo 'not ok   accept skill names the canonical Cognito token cache'
  failures=$((failures + 1))
fi
if grep -Fq '~/.hq/cognito-tokens.json' "$promote" && ! grep -Fq '~/.hq/credentials.json' "$promote"; then
  echo 'ok   promote skill uses the canonical Cognito token cache too'
else
  echo 'not ok   promote skill uses the canonical Cognito token cache too'
  failures=$((failures + 1))
fi

if grep -Fq 'hq-deploy' "$repo_root/.claude/skills/deploy/agents/openai.yaml"; then
  echo 'ok   deploy skill metadata describes hq-deploy'
else
  echo 'not ok   deploy skill metadata describes hq-deploy'
  failures=$((failures + 1))
fi
if grep -Fq 'reliably reproducible' "$repo_root/.claude/skills/investigate/agents/openai.yaml" \
  && ! grep -Fq 'hard-to-reproduce' "$repo_root/.claude/skills/investigate/agents/openai.yaml"; then
  echo 'ok   investigate metadata reserves hard-to-reproduce failures for diagnose'
else
  echo 'not ok   investigate metadata reserves hard-to-reproduce failures for diagnose'
  failures=$((failures + 1))
fi
exit "$failures"
