#!/usr/bin/env bash
# conduct-standing.test.sh — /conduct routing rules and standing worker lanes
# (owner decision 2026-10-22, "Workers stay open"). Uses a fake hq binary that
# records every call, so no lane is created.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/core/scripts/lib" "$T/workspace/sessions/s1" "$T/bin" "$T/agents" "$T/.claude/agents" \
  "$T/core/workers/public/dev-team/backend-dev/skills" "$T/core/workers/public/content-brand/skills"
cp "$ROOT/core/scripts/conduct-standing.sh" "$ROOT/core/scripts/hq-session.sh" "$T/core/scripts/"
cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$ROOT/core/scripts/lib/session-id.sh" "$T/core/scripts/lib/"
mkdir -p "$T/core/settings" "$T/personal/settings"
cp "$ROOT/core/settings/orchestrator.yaml" "$T/core/settings/"
printf 'session_id: s1\n' > "$T/workspace/sessions/s1/meta.yaml"

cat > "$T/core/workers/registry.yaml" <<'YAML'
workers:
  - id: "backend-dev"
    path: "core/workers/public/dev-team/backend-dev/"
    status: "active"
  - id: "content-brand"
    path: "core/workers/public/content-brand/"
    status: "active"
YAML
cat > "$T/core/workers/public/dev-team/backend-dev/worker.yaml" <<'YAML'
id: backend-dev
skills:
  - id: implement-endpoint
    file: skills/implement-endpoint.md
  - id: e2e-testing
    file: skills/e2e-testing.md
verification:
  approval_required: false
YAML
touch "$T/core/workers/public/content-brand/skills/voice.md"
printf 'id: content-brand\nskills:\n  - voice-analysis\n' > "$T/core/workers/public/content-brand/worker.yaml"
printf -- '---\nname: content-brand\n---\n' > "$T/agents/content-brand.md"

# Fake hq: logs each call; lane state comes from $T/state-<lane>.
cat > "$T/bin/hq" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1 $2" in
  "lanes create")
    if [ -f "$FAKE_REFUSE" ]; then echo '{"ok":false,"code":"no_account_with_room","next_reset":"2026-10-23T00:00:00Z"}'; exit 1; fi
    n=$(( $(cat "$FAKE_N" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_N"
    echo "running" > "$FAKE_DIR/state-LANE$n"
    printf '{"ok":true,"lane_id":"LANE%s"}\n' "$n" ;;
  "lanes show") printf '{"ok":true,"lane":{"state":"%s"}}\n' "$(cat "$FAKE_DIR/state-$3" 2>/dev/null || echo unknown)" ;;
  *) echo '{"ok":true}' ;;
esac
FAKE
chmod +x "$T/bin/hq"
export HQ_ROOT="$T" HQ_SESSION_ID=s1 HQ_BIN="$T/bin/hq" HQ_CLAUDE_AGENTS_DIR="$T/agents"
export FAKE_LOG="$T/hq.log" FAKE_N="$T/n" FAKE_DIR="$T" FAKE_REFUSE="$T/refuse"
unset CLAUDE_PROJECT_DIR
: > "$FAKE_LOG"
C() { bash "$T/core/scripts/conduct-standing.sh" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }
j() { printf '%s' "$1" | jq -r "$2"; }
printf 'Add the /health endpoint.\n' > "$T/brief1.md"
printf 'Add the /ready endpoint.\n' > "$T/brief2.md"

echo "release default runner is mixed"
grep -Eq '^  runner: mixed$' "$ROOT/core/settings/orchestrator.yaml" || fail 'core/settings/orchestrator.yaml does not ship conduct.runner: mixed'
eq "$(j "$(C route --kind lookup)" .runner)" mixed 'the shipped setting resolves to mixed'

echo "routing rules under mixed"
eq "$(j "$(C route --kind answer)" .route)" inline 'an answer from loaded context stays inline'
eq "$(j "$(C route --kind status)" .route)" inline 'one status read stays inline'
eq "$(j "$(C route --kind lookup)" .route)" subagent 'a lookup goes to a subagent'
eq "$(j "$(C route --kind small)" .route)" subagent 'a small task with no worker goes to a subagent'
r="$(C route --kind small --worker backend-dev --company indigo)"
eq "$(j "$r" .route)" lane-open 'a task that matches a worker opens its lane'
eq "$(j "$r" .standing)" true 'that lane is standing'
r="$(C route --kind ongoing --worker backend-dev --company indigo)"
eq "$(j "$r" .route)" lane-open 'ongoing work in a worker area opens a lane'
eq "$(j "$r" .standing)" true 'the ongoing lane is standing'
eq "$(j "$(C route --kind ongoing)" .route)" subagent 'ongoing work with no matching worker runs as a subagent'
eq "$(j "$(C route --kind small --outlives)" .route)" lane-open 'work that outlives the session uses a lane'
eq "$(j "$(C route --kind small --engine codex)" .route)" lane-open 'a non-Claude engine uses a lane'
C route --kind small --worker backend-dev >/dev/null 2>&1 && fail 'route with a worker accepted no company'
C route --kind edit >/dev/null 2>&1 && fail 'unknown kind accepted'
C route --kind small --runner pool >/dev/null 2>&1 && fail 'unknown runner accepted'

echo "runner resolution order"
printf 'conduct:\n  default_enabled: true\n  runner: subagent\n' > "$T/personal/settings/orchestrator.yaml"
r="$(C route --kind small --worker backend-dev --company indigo)"
eq "$(j "$r" .runner)" subagent 'personal setting overrides the release default'
eq "$(j "$r" .route)" subagent 'runner subagent opens no standing lane'
bash "$T/core/scripts/hq-session.sh" --session-id s1 set conduct_runner mixed >/dev/null
eq "$(j "$(C route --kind small --worker backend-dev --company indigo)" .route)" lane-open 'session pin overrides the personal setting'
eq "$(j "$(C route --kind small --worker backend-dev --company indigo --runner subagent)" .route)" subagent '--runner overrides the session pin'
eq "$(j "$(C route --kind small --runner lane)" .route)" lane-open 'runner lane gives a task with no worker a one-shot lane'
eq "$(j "$(C route --kind small --runner lane)" .standing)" false 'that one-shot lane is not standing'
bash "$T/core/scripts/hq-session.sh" --session-id s1 set conduct_runner "" >/dev/null
rm "$T/personal/settings/orchestrator.yaml"
[ ! -s "$FAKE_LOG" ] || fail 'route called hq'

echo "agent type mapping"
a="$(C agent-type --worker content-brand)"
eq "$(j "$a" .subagent_type)" content-brand 'a worker with a Claude agent definition maps to that agent type'
eq "$(j "$a" '.skill_files[0]')" core/workers/public/content-brand/skills/voice.md 'skills dir fallback'
a="$(C agent-type --worker backend-dev)"
eq "$(j "$a" .subagent_type)" general-purpose 'a worker with no agent definition runs as general-purpose'
eq "$(j "$a" .worker_yaml)" core/workers/public/dev-team/backend-dev/worker.yaml 'worker.yaml path'
eq "$(j "$a" '.skill_files|join(",")')" \
  core/workers/public/dev-team/backend-dev/skills/implement-endpoint.md,core/workers/public/dev-team/backend-dev/skills/e2e-testing.md \
  'skills[].file paths are resolved against the worker path'
printf -- '---\nname: backend-dev\n---\n' > "$T/.claude/agents/backend-dev.md"
eq "$(j "$(C agent-type --worker backend-dev)" .subagent_type)" backend-dev 'a project agent definition is used'
rm "$T/.claude/agents/backend-dev.md"
eq "$(j "$(C agent-type --worker nobody)" .subagent_type)" general-purpose 'unknown worker is general-purpose'

echo "standing lane: first task opens it"
C send --worker backend-dev --brief-file "$T/brief1.md" >/dev/null 2>&1 && fail 'send without --company accepted'
o="$(C send --worker backend-dev --company indigo --brief-file "$T/brief1.md" --project api)"
eq "$(j "$o" .action)" opened 'first task opens the lane'
eq "$(j "$o" .lane)" LANE1 'lane id'
grep -q -- '^lanes create .*--company indigo' "$FAKE_LOG" || fail 'create did not pass the company'
grep -q -- '^lanes create .*--keep-alive' "$FAKE_LOG" || fail 'create did not pass --keep-alive'
grep -q -- '^lanes create .*--senior session:s1' "$FAKE_LOG" || fail 'create did not name its senior'
grep -q -- '^lanes create .*--no-story conduct standing backend-dev lane' "$FAKE_LOG" || fail 'create without a story did not record why'
grep -qx 'lanes keep-alive LANE1 --on --standing --json' "$FAKE_LOG" || fail 'lane was not made standing'
eq "$(C find --worker backend-dev --company indigo)" LANE1 'lane recorded in conduct state'
eq "$(j "$(C route --kind lookup --worker backend-dev --company indigo)" .route)" lane-reuse \
  'a later task in the same area routes to the standing lane'
eq "$(j "$(C route --kind ongoing --worker backend-dev --company indigo)" .lane)" LANE1 'route names the standing lane'

echo "standing lane: second task in the same area reuses it"
: > "$FAKE_LOG"
o="$(C send --worker backend-dev --company indigo --brief-file "$T/brief2.md")"
eq "$(j "$o" .action)" reused 'second task reuses the lane'
eq "$(j "$o" .lane)" LANE1 'same lane'
grep -qx "lanes message LANE1 --text-file $T/brief2.md --json" "$FAKE_LOG" || fail 'second task was not messaged to the lane'
grep -q '^lanes create' "$FAKE_LOG" && fail 'second task opened a new lane'
eq "$(C list | jq 'length')" 1 'one standing lane recorded'

echo "standing lanes are per worker and per company"
o="$(C send --worker backend-dev --company example-co --brief-file "$T/brief1.md")"
eq "$(j "$o" .lane)" LANE2 'another company gets its own lane'
r="$(C route --kind small --worker backend-dev --company personal)"
eq "$(j "$r" .route)" lane-open 'no cross-company reuse: another company opens its own lane'
eq "$(j "$r" .lane)" null 'no lane id from another company'

echo "a stopped standing lane is replaced"
echo stopped > "$T/state-LANE1"
: > "$FAKE_LOG"
o="$(C send --worker backend-dev --company indigo --brief-file "$T/brief2.md")"
eq "$(j "$o" .action)" opened 'stopped lane is reopened through create'
eq "$(j "$o" .lane)" LANE3 'new lane id recorded'
eq "$(C find --worker backend-dev --company indigo)" LANE3 'state points at the new lane'
grep -q '^lanes message LANE1' "$FAKE_LOG" && fail 'messaged a stopped lane'

echo "a capacity refusal exits 3 so the conductor runs a subagent"
touch "$FAKE_REFUSE"
set +e; o="$(C send --worker frontend-dev --company indigo --brief-file "$T/brief1.md")"; rc=$?; set -e
eq "$rc" 3 'refusal exit code'
eq "$(j "$o" .code)" no_account_with_room 'refusal JSON is passed through'
C find --worker frontend-dev --company indigo >/dev/null && fail 'refused lane was recorded'
rm "$FAKE_REFUSE"

echo "close turns keep-alive off and interrupts each standing lane"
: > "$FAKE_LOG"
C close --dry-run | grep -q 'would close LANE3' || fail 'dry run did not list the lane'
[ ! -s "$FAKE_LOG" ] || fail 'dry run called hq'
C close >/dev/null
grep -qx 'lanes keep-alive LANE3 --off --json' "$FAKE_LOG" || fail 'close did not turn keep-alive off'
grep -q '^lanes interrupt LANE3 ' "$FAKE_LOG" || fail 'close did not interrupt the lane'
grep -q '^lanes keep-alive LANE2 --off' "$FAKE_LOG" || fail 'close skipped the second company lane'
grep -q '^lanes stop' "$FAKE_LOG" && fail 'close must keep lanes resumable, not stop them'
eq "$(C list)" '[]' 'close clears the record'

echo "skill text matches the helper"
SKILL="$ROOT/.claude/skills/conduct/SKILL.md"
MODULE="$ROOT/.claude/skills/conduct/dispatch.md"
CORE="$ROOT/.claude/skills/conduct/conductor-core.md"
grep -q 'conduct-standing.sh' "$SKILL" || fail 'SKILL.md does not use the routing helper'
grep -q 'Bash(bash core/scripts/conduct-standing.sh:\*)' "$SKILL" || fail 'SKILL.md cannot run the helper'
grep -q 'conduct-standing.sh close' "$SKILL" || fail '/conduct off does not close standing lanes'
grep -q -- '--runner mixed|subagent|lane' "$SKILL" || fail '/conduct does not accept --runner mixed'
grep -q -- '--runner mixed|subagent|lane' "$MODULE" || fail 'dispatch does not resolve the mixed runner'
# shellcheck disable=SC2016  # literal backticks from the markdown
grep -q 'ships `mixed`' "$MODULE" || fail 'dispatch does not name mixed as the release default'
grep -q 'conduct-standing.sh send' "$MODULE" || fail 'dispatch does not route to standing lanes'
grep -q 'conduct-standing.sh agent-type' "$MODULE" || fail 'dispatch does not map workers to agent types'
grep -q 'keep-alive <lane> --on --standing' "$MODULE" || fail 'dispatch does not describe standing keep-alive'
if grep -q 'planned as' "$MODULE"; then fail 'dispatch still calls the subagent runner planned'; fi
injected="$(awk '/<!-- inject:start -->/{on=1;next} /<!-- inject:end -->/{on=0} on' "$CORE")"
grep -qi 'never does project work' <<<"$injected" || fail 'conductor core does not say the conductor never does project work'
if grep -q '^- Lane:' <<<"$injected"; then fail 'conductor core still sends everything to a lane'; fi
grep -qi 'subagent' <<<"$injected" || fail 'conductor core does not name subagents'
grep -qi 'standing' <<<"$injected" || fail 'conductor core does not name standing lanes'
[ "$(printf '%s\n' "$injected" | wc -c | tr -d ' ')" -le 750 ] || fail 'injected block is over 750 bytes'
echo 'conduct-standing.test.sh: routing and standing-lane reuse passed'
