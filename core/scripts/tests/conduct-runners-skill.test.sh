#!/usr/bin/env bash
# /conduct-runners is the advanced mode of /conduct: lanes run on runners
# (detached hq runners processes). It owns the lanes CLI, the standing-lane and
# role-lane helpers, the subagent registration, its own always-on block, and
# the status row template. Default /conduct only hands over to it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DIR="$ROOT/.claude/skills/conduct-runners"
SKILL="$DIR/SKILL.md"
CORE="$DIR/conductor-core.md"
OPENAI="$DIR/agents/openai.yaml"
DEFAULT_DIR="$ROOT/.claude/skills/conduct"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$SKILL" ] || fail 'conduct-runners SKILL.md is missing'
[ -f "$DIR/dispatch.md" ] || fail 'conduct-runners dispatch.md is missing'

# Frontmatter.
fm="$(awk 'NR==1 && $0=="---" {fm=1; next} fm && $0=="---" {exit} fm' "$SKILL")"
printf '%s\n' "$fm" | grep -x >/dev/null 'name: conduct-runners' || fail 'skill name is not conduct-runners'
printf '%s\n' "$fm" | grep >/dev/null '^description: .*[Aa]dvanced mode of /conduct' || fail 'description does not name the advanced mode'
printf '%s\n' "$fm" | grep >/dev/null '^description: .*runners' || fail 'description does not mention runners'
tools="$(printf '%s\n' "$fm" | sed -n 's/^allowed-tools: //p')"
for t in 'Agent' 'SendMessage' 'Bash(hq runners:*)' 'Bash(bash core/scripts/lanes-workers.sh:*)' \
  'Bash(bash core/scripts/conduct-standing.sh:*)' 'Bash(bash core/scripts/hq-session.sh:*)' \
  'AskUserQuestion' 'mcp__visualize__show_widget'; do
  printf '%s\n' "$tools" | grep -F >/dev/null "$t" || fail "allowed-tools lost $t"
done
[ "$(wc -l < "$SKILL" | tr -d ' ')" -le 160 ] || fail 'conduct-runners SKILL.md exceeds 160 lines'

# Body: CLI material, references instead of copies, reachability.
for h in '## Step 1: Parse the argument' '## When a task needs a worker' '## Rules'; do
  grep -qF "$h" "$SKILL" || fail "skill lost $h"
done
grep -qF '.claude/skills/conduct-runners/dispatch.md' "$SKILL" || fail 'skill does not load the runners dispatch'
grep -qF 'hq runners keep-alive <lane> --on --standing' "$SKILL" || fail 'standing lanes do not use keep-alive'
grep -qF 'conduct-standing.sh send' "$SKILL" || fail 'standing lanes do not open through conduct-standing.sh'
grep -qF 'conduct-standing.sh close' "$SKILL" || fail 'off and handoff do not close standing lanes'
grep -qF 'lanes-workers.sh setup' "$SKILL" || fail '--workers does not use lanes-workers.sh setup'
grep -qF 'hq runners create --runner subagent' "$SKILL" || fail 'subagents are not registered as process-less lanes'
grep -qF 'hq runners progress' "$SKILL" || fail 'subagent lanes do not report through hq runners progress'
grep -qF 'hq runners list' "$SKILL" || fail 'hq runners list is not the one view'
grep -qF '.claude/skills/conduct/roles/' "$SKILL" || fail 'skill does not reference the shared role templates'
grep -qF '.claude/skills/conduct/adopt.md' "$SKILL" || fail 'skill does not reference adopt.md'
grep -qF '/conduct --runner runner' "$SKILL" || fail 'skill does not name the /conduct --runner runner route'
grep -qF 'conduct-runner-resolve.sh' "$SKILL" || fail 'skill does not name the runner resolver'
grep -qi 'same report' "$SKILL" || fail 'conduct link reports are not tied to the default shape'
[ -d "$DIR/roles" ] && fail 'role templates were copied instead of referenced'

# Default /conduct hands over and never registers subagents on the lanes CLI.
grep -qF '.claude/skills/conduct-runners/SKILL.md' "$DEFAULT_DIR/SKILL.md" || fail 'default /conduct does not hand over to /conduct-runners'
if grep -En 'hq (runners|lanes) create --runner subagent' "$DEFAULT_DIR/SKILL.md" "$DEFAULT_DIR/dispatch.md" "$DEFAULT_DIR/conductor-core.md"; then
  fail 'subagent registration must live only in /conduct-runners'
fi

# Second always-on block.
grep -q '<!-- inject:start -->' "$CORE" && grep -q '<!-- inject:end -->' "$CORE" || fail 'runners conductor-core has no inject markers'
injected="$(awk '/<!-- inject:start -->/{f=1;next}/<!-- inject:end -->/{f=0}f' "$CORE")"
bytes="$(printf '%s\n' "$injected" | wc -c | tr -d ' ')"
[ "$bytes" -le 750 ] || fail "runners inject block is $bytes bytes (max 750)"
printf '%s\n' "$injected" | grep >/dev/null 'Lane on a runner' || fail 'runners inject does not name a lane on a runner'
printf '%s\n' "$injected" | grep >/dev/null 'Subagent' || fail 'runners inject does not name subagents'
printf '%s\n' "$injected" | grep >/dev/null 'Child session' || fail 'runners inject does not name child sessions'
printf '%s\n' "$injected" | grep >/dev/null '/conduct-runners' || fail 'runners inject does not name /conduct-runners'

# Status row template moved, every reference follows it.
[ -f "$DIR/lane-rows.html" ] || fail 'lane-rows.html is not in conduct-runners'
[ -f "$DEFAULT_DIR/lane-rows.html" ] && fail 'lane-rows.html was copied, not moved'
if grep -rn --include='*.md' '\.claude/skills/conduct/lane-rows\.html' "$ROOT/.claude/skills"; then
  fail 'a skill still points at the old lane-rows.html path'
fi

# Codex metadata.
[ -f "$OPENAI" ] || fail 'conduct-runners agents/openai.yaml is missing'
short="$(awk '/short_description:/{f=1;next} f{sub(/^ +/,""); print; exit}' "$OPENAI")"
len=${#short}
[ "$len" -ge 25 ] && [ "$len" -le 64 ] || fail "openai short_description is $len chars (25-64)"

# Helper help text names the advanced mode.
bash "$ROOT/core/scripts/conduct-standing.sh" --help 2>&1 | grep >/dev/null '/conduct-runners' || fail 'conduct-standing.sh help does not name /conduct-runners'
bash "$ROOT/core/scripts/lanes-workers.sh" --help 2>&1 | grep >/dev/null '/conduct-runners' || fail 'lanes-workers.sh help does not name /conduct-runners'

# Inventory.
grep -q '"name": "conduct-runners"' "$ROOT/core/docs/hq/commands.json" || fail 'commands.json does not list conduct-runners'

echo "PASS: conduct-runners skill"
