#!/usr/bin/env bash
# conduct-standing.test.sh — /conduct-runners routing rules and standing worker
# lanes, plus the subagent default. Uses a fake hq binary that
# records every call, so no lane is created.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/core/scripts/lib" "$T/workspace/sessions/s1" "$T/bin" "$T/agents" "$T/.claude/agents" \
  "$T/core/workers/public/dev-team/backend-dev/skills" "$T/core/workers/public/content-brand/skills"
cp "$ROOT/core/scripts/conduct-standing.sh" "$ROOT/core/scripts/hq-session.sh" \
  "$ROOT/core/scripts/conduct-runner-resolve.sh" "$T/core/scripts/"
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
  "runners create")
    if [ -f "$FAKE_REFUSE" ]; then echo '{"ok":false,"code":"no_account_with_room","next_reset":"2026-10-23T00:00:00Z"}'; exit 1; fi
    n=$(( $(cat "$FAKE_N" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_N"
    echo "running" > "$FAKE_DIR/state-LANE$n"
    printf '{"ok":true,"lane_id":"LANE%s"}\n' "$n" ;;
  "runners show") printf '{"ok":true,"lane":{"state":"%s"}}\n' "$(cat "$FAKE_DIR/state-$3" 2>/dev/null || echo unknown)" ;;
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

echo "release default runner is subagent"
grep -Eq '^  runner: subagent$' "$ROOT/core/settings/orchestrator.yaml" || fail 'core/settings/orchestrator.yaml does not ship conduct.runner: subagent'
eq "$(j "$(C route --kind lookup)" .runner)" subagent 'the shipped setting resolves to subagent'

echo "the runner comes only from conduct-runner-resolve.sh"
# A stub resolver that always answers runner, while the settings still say
# subagent: the script must follow the resolver and keep no parser of its own.
mv "$T/core/scripts/conduct-runner-resolve.sh" "$T/resolve.real"
printf '#!/bin/sh\necho "$*" >> "%s/resolve.args"\necho runner\n' "$T" > "$T/core/scripts/conduct-runner-resolve.sh"
eq "$(j "$(C route --kind lookup)" .runner)" runner 'route takes the runner from conduct-runner-resolve.sh'
grep -q -- '--root' "$T/resolve.args" || fail 'conduct-standing.sh does not pass --root to the resolver'
C route --kind lookup --runner subagent >/dev/null
grep -q -- '--runner subagent' "$T/resolve.args" || fail 'conduct-standing.sh does not pass --runner to the resolver'
mv "$T/resolve.real" "$T/core/scripts/conduct-runner-resolve.sh"
rm -f "$T/resolve.args"
if grep -qE 'orchestrator\.yaml|conduct_runner' <(grep -v '^#' "$ROOT/core/scripts/conduct-standing.sh"); then
  fail 'conduct-standing.sh reads the runner setting itself instead of calling conduct-runner-resolve.sh'
fi
r="$(C route --kind small --worker backend-dev --company indigo)"
eq "$(j "$r" .route)" standing-subagent 'under the default a worker task goes to a standing subagent'
eq "$(j "$r" .standing)" true 'the standing subagent is a standing lane'
eq "$(j "$r" .lane)" null 'the default names no runner lane'
eq "$(j "$(C route --kind small --outlives)" .route)" child-session \
  'under the default, work that outlives the session goes to a child session, not a runner'
eq "$(j "$(C route --kind ongoing --worker backend-dev --company indigo --outlives)" .route)" child-session \
  'outlives wins over a worker match under the default'
r="$(C route --kind small --engine codex)"
eq "$(j "$r" .route)" needs-runners 'under the default a non-Claude engine says it needs /conduct-runners'
j "$r" .reason | grep >/dev/null '/conduct-runners' || fail 'needs-runners does not name /conduct-runners'
# A Codex host runs Codex subagents with spawn_agent in default mode.
eq "$(j "$(C route --kind small --engine codex --host codex)" .route)" subagent \
  'a Codex engine on a Codex host stays a default subagent'
eq "$(j "$(C route --kind ongoing --worker backend-dev --company indigo --engine codex --host codex)" .route)" standing-subagent \
  'a Codex worker task on a Codex host stays a standing subagent'
eq "$(j "$(C route --kind small --engine claude --host codex)" .route)" needs-runners \
  'a Claude engine from a Codex host needs /conduct-runners'
if C route --kind small --host cursor >/dev/null 2>&1; then fail 'route accepted an unknown --host'; fi
eq "$(j "$(C route --kind small)" .route)" subagent 'a small task with no worker is a one-off subagent'
eq "$(j "$(C route --kind answer)" .route)" inline 'an answer stays inline under the default'
rm "$T/core/settings/orchestrator.yaml"
eq "$(j "$(C route --kind lookup)" .runner)" subagent 'with no setting at all the runner is subagent'
cp "$ROOT/core/settings/orchestrator.yaml" "$T/core/settings/"

echo "routing rules under runner"
R() { C route --runner runner "$@"; }
eq "$(j "$(R --kind answer)" .route)" inline 'an answer from loaded context stays inline'
eq "$(j "$(R --kind status)" .route)" inline 'one status read stays inline'
eq "$(j "$(R --kind lookup)" .route)" subagent 'a lookup goes to a subagent'
eq "$(j "$(R --kind small)" .route)" subagent 'a small task with no worker goes to a subagent'
r="$(R --kind small --worker backend-dev --company indigo)"
eq "$(j "$r" .route)" lane-open 'a task that matches a worker opens its lane'
eq "$(j "$r" .standing)" true 'that lane is standing'
r="$(R --kind ongoing --worker backend-dev --company indigo)"
eq "$(j "$r" .route)" lane-open 'ongoing work in a worker area opens a lane'
eq "$(j "$r" .standing)" true 'the ongoing lane is standing'
eq "$(j "$(R --kind ongoing)" .route)" subagent 'ongoing work with no matching worker runs as a subagent'
eq "$(j "$(R --kind small --outlives)" .route)" lane-open 'work that outlives the session uses a lane'
eq "$(j "$(R --kind small --engine codex)" .route)" lane-open 'a non-Claude engine uses a lane'
r="$(C route --runner mixed --kind small --worker backend-dev --company indigo 2>"$T/legacy.err")"
eq "$(j "$r" .route)" lane-open 'the legacy mixed value routes like runner'
eq "$(j "$r" .runner)" runner 'the legacy mixed value reads as runner'
grep -q 'legacy value, read as "runner"' "$T/legacy.err" || fail 'legacy mixed did not warn'
r="$(C route --runner lane --kind small --worker backend-dev --company indigo 2>"$T/legacy.err")"
eq "$(j "$r" .runner)" runner 'the legacy lane value reads as runner'
eq "$(j "$r" .route)" lane-open 'the legacy lane value routes like runner'
grep -q 'legacy value, read as "runner"' "$T/legacy.err" || fail 'legacy lane did not warn'
C route --kind small --worker backend-dev >/dev/null 2>&1 && fail 'route with a worker accepted no company'
C route --kind edit >/dev/null 2>&1 && fail 'unknown kind accepted'
C route --kind small --runner pool >/dev/null 2>&1 && fail 'unknown runner accepted'

echo "runner resolution order"
printf 'conduct:\n  default_enabled: true\n  runner: runner\n' > "$T/personal/settings/orchestrator.yaml"
r="$(C route --kind small --worker backend-dev --company indigo)"
eq "$(j "$r" .runner)" runner 'personal setting overrides the release default'
eq "$(j "$r" .route)" lane-open 'personal runner opens a standing lane for a worker task'
bash "$T/core/scripts/hq-session.sh" --session-id s1 set conduct_runner subagent >/dev/null
eq "$(j "$(C route --kind small --worker backend-dev --company indigo)" .route)" standing-subagent 'session pin overrides the personal setting'
bash "$T/core/scripts/hq-session.sh" --session-id s1 set conduct_runner mixed >/dev/null
eq "$(j "$(C route --kind small --worker backend-dev --company indigo 2>/dev/null)" .runner)" runner 'a legacy mixed session pin reads as runner'
eq "$(j "$(C route --kind small --worker backend-dev --company indigo --runner subagent)" .route)" standing-subagent '--runner overrides the session pin'
r="$(C route --kind small --runner lane 2>/dev/null)"
eq "$(j "$r" .route)" subagent 'legacy lane is runner: a task with no worker is a one-off subagent, no one-shot lane'
eq "$(j "$r" .standing)" false 'that one-off subagent is not standing'
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

echo "default subagent runner: send is refused and close makes no hq call"
: > "$FAKE_LOG"
set +e; C send --worker backend-dev --company indigo --brief-file "$T/brief1.md" >/dev/null 2>"$T/send.err"; rc=$?; set -e
eq "$rc" 4 'send under the default subagent runner exits 4'
grep -q 'send refused' "$T/send.err" || fail 'send refusal did not explain itself'
grep -q '/conduct-runners' "$T/send.err" || fail 'send refusal does not point at /conduct-runners'
o="$(C close)"
grep -q 'no runner lanes closed' <<<"$o" || fail 'close under the default did not say it closed no runner lane'
C close --dry-run >/dev/null || fail 'close --dry-run under the default failed'
[ ! -s "$FAKE_LOG" ] || fail "send or close under the default called hq: $(cat "$FAKE_LOG")"

echo "standing lane under runner: first task opens it"
# /conduct-runners pins the runner for the session; send and close follow it.
bash "$T/core/scripts/hq-session.sh" --session-id s1 set conduct_runner runner >/dev/null
C send --worker backend-dev --brief-file "$T/brief1.md" >/dev/null 2>&1 && fail 'send without --company accepted'
o="$(C send --worker backend-dev --company indigo --brief-file "$T/brief1.md" --project api)"
eq "$(j "$o" .action)" opened 'first task opens the lane'
eq "$(j "$o" .lane)" LANE1 'lane id'
grep -q -- '^runners create .*--company indigo' "$FAKE_LOG" || fail 'create did not pass the company'
grep -q -- '^runners create .*--keep-alive' "$FAKE_LOG" || fail 'create did not pass --keep-alive'
grep -q -- '^runners create .*--senior session:s1' "$FAKE_LOG" || fail 'create did not name its senior'
grep -q -- '^runners create .*--no-story conduct standing backend-dev lane' "$FAKE_LOG" || fail 'create without a story did not record why'
grep -qx 'runners keep-alive LANE1 --on --standing --json' "$FAKE_LOG" || fail 'lane was not made standing'
eq "$(C find --worker backend-dev --company indigo)" LANE1 'lane recorded in conduct state'
eq "$(j "$(R --kind lookup --worker backend-dev --company indigo)" .route)" lane-reuse \
  'a later task in the same area routes to the standing lane'
eq "$(j "$(R --kind ongoing --worker backend-dev --company indigo)" .lane)" LANE1 'route names the standing lane'

echo "standing lane: second task in the same area reuses it"
: > "$FAKE_LOG"
o="$(C send --worker backend-dev --company indigo --brief-file "$T/brief2.md")"
eq "$(j "$o" .action)" reused 'second task reuses the lane'
eq "$(j "$o" .lane)" LANE1 'same lane'
grep -qx "runners message LANE1 --text-file $T/brief2.md --json" "$FAKE_LOG" || fail 'second task was not messaged to the lane'
grep -q '^runners create' "$FAKE_LOG" && fail 'second task opened a new lane'
eq "$(C list | jq 'length')" 1 'one standing lane recorded'

echo "standing lanes are per worker and per company"
o="$(C send --worker backend-dev --company example-co --brief-file "$T/brief1.md")"
eq "$(j "$o" .lane)" LANE2 'another company gets its own lane'
r="$(R --kind small --worker backend-dev --company personal)"
eq "$(j "$r" .route)" lane-open 'no cross-company reuse: another company opens its own lane'
eq "$(j "$r" .lane)" null 'no lane id from another company'

echo "a stopped standing lane is replaced"
echo stopped > "$T/state-LANE1"
: > "$FAKE_LOG"
o="$(C send --worker backend-dev --company indigo --brief-file "$T/brief2.md")"
eq "$(j "$o" .action)" opened 'stopped lane is reopened through create'
eq "$(j "$o" .lane)" LANE3 'new lane id recorded'
eq "$(C find --worker backend-dev --company indigo)" LANE3 'state points at the new lane'
grep -q '^runners message LANE1' "$FAKE_LOG" && fail 'messaged a stopped lane'

echo "a capacity refusal exits 3 so the conductor runs a subagent"
touch "$FAKE_REFUSE"
set +e; o="$(C send --worker frontend-dev --company indigo --brief-file "$T/brief1.md")"; rc=$?; set -e
eq "$rc" 3 'refusal exit code'
eq "$(j "$o" .code)" no_account_with_room 'refusal JSON is passed through'
C find --worker frontend-dev --company indigo >/dev/null && fail 'refused lane was recorded'
rm "$FAKE_REFUSE"

echo "send under subagent is refused and calls no hq"
: > "$FAKE_LOG"
set +e; C send --runner subagent --worker backend-dev --company indigo --brief-file "$T/brief2.md" >/dev/null 2>&1; rc=$?; set -e
eq "$rc" 4 'send --runner subagent is refused even with a runner pin'
[ ! -s "$FAKE_LOG" ] || fail 'refused send called hq'

echo "close under runner turns keep-alive off and interrupts each standing lane"
: > "$FAKE_LOG"
C close --dry-run | grep -q 'would close LANE3' || fail 'dry run did not list the lane'
[ ! -s "$FAKE_LOG" ] || fail 'dry run called hq'
C close >/dev/null
grep -qx 'runners keep-alive LANE3 --off --json' "$FAKE_LOG" || fail 'close did not turn keep-alive off'
grep -q '^runners interrupt LANE3 ' "$FAKE_LOG" || fail 'close did not interrupt the lane'
grep -q '^runners keep-alive LANE2 --off' "$FAKE_LOG" || fail 'close skipped the second company lane'
grep -q '^runners stop' "$FAKE_LOG" && fail 'close must keep lanes resumable, not stop them'
eq "$(C list)" '[]' 'close clears the record'
bash "$T/core/scripts/hq-session.sh" --session-id s1 set conduct_runner "" >/dev/null

echo "after an upgrade to the subagent default, close still ends this session's leftover runner lanes"
# A lane an older core or an earlier /conduct-runners turn opened for s1.
printf '{"schema":"conduct-standing-lanes.v1","lanes":[{"worker":"backend-dev","company":"indigo","lane":"LEFT1","opened_at":"2026-01-01T00:00:00Z"}]}\n' \
  > "$T/workspace/sessions/s1/conduct-standing-lanes.json"
echo running > "$T/state-LEFT1"
: > "$FAKE_LOG"
o="$(C close)"
grep -q 'closing 1 runner lane' <<<"$o" || fail 'default close did not say it is closing the leftover lane'
grep -qx 'runners keep-alive LEFT1 --off --json' "$FAKE_LOG" || fail 'default close did not turn keep-alive off on the leftover lane'
grep -q '^runners interrupt LEFT1 ' "$FAKE_LOG" || fail 'default close did not interrupt the leftover lane'
if grep -Eq '^lanes (create|message|keep-alive [^ ]+ --on)' "$FAKE_LOG"; then fail 'default close opened or messaged a lane'; fi
eq "$(C list)" '[]' 'default close clears the leftover record'
: > "$FAKE_LOG"
C close >/dev/null
[ ! -s "$FAKE_LOG" ] || fail 'default close with no record called hq'

echo "skill text matches the helper"
SKILL="$ROOT/.claude/skills/conduct/SKILL.md"
MODULE="$ROOT/.claude/skills/conduct/dispatch.md"
DCORE="$ROOT/.claude/skills/_shared/conduct-dispatch-core.md"
RUNNERS="$ROOT/.claude/skills/conduct-runners/dispatch.md"
CORE="$ROOT/.claude/skills/conduct/conductor-core.md"
grep -q 'conduct-standing.sh' "$SKILL" || fail 'SKILL.md does not use the routing helper'
grep -q 'Bash(bash core/scripts/conduct-standing.sh:\*)' "$SKILL" || fail 'SKILL.md cannot run the helper'
RSKILL="$ROOT/.claude/skills/conduct-runners/SKILL.md"
# Send belongs to /conduct-runners. Close ends lanes already open, so both
# /conduct off and the /conduct handoff path run it, and so does /conduct-runners off.
off_line="$(awk '/^- `off`/{on=1} on{print} on && /^- `status`/{exit}' "$SKILL")"
grep -q 'conduct-standing.sh close' <<<"$off_line" || fail '/conduct off does not close leftover runner lanes'
grep -A2 'Before `/handoff`' "$SKILL" | grep >/dev/null 'conduct-standing.sh close' || fail '/conduct handoff does not close leftover runner lanes'
grep -q 'conduct-standing.sh list' "$SKILL" || fail '/conduct does not check for leftover runner lanes on its first turn'
grep -q 'conduct-standing.sh close' "$RSKILL" || fail '/conduct-runners off does not close standing runner lanes'
if grep -q 'conduct-standing.sh send' "$SKILL" "$MODULE"; then fail 'default /conduct still sends to runner lanes'; fi
# The dispatch module describes the close call the skill makes.
mod_flat="$(tr '\n' ' ' < "$MODULE")"
if grep -q 'never calls `conduct-standing.sh` *subcommands that open, message, or close' <<<"$mod_flat"; then fail 'default dispatch says it never closes runner lanes'; fi
grep -q 'never opens or messages a *runner lane' <<<"$mod_flat" || fail 'default dispatch does not say it never opens or messages a runner lane'
grep -q 'conduct-standing.sh close`, which *ends leftover runner lanes' <<<"$mod_flat" || fail 'default dispatch does not describe the close of leftover runner lanes'
grep -q 'runs.json' "$SKILL" || fail '/conduct off does not close the runs.json lanes'
grep -q 'standing-subagent' "$MODULE" || fail 'default dispatch does not name the standing-subagent route'
grep -q -- '--runner mixed|lane' "$SKILL" || fail '/conduct does not accept --runner mixed'
grep -q -- '--runner mixed|lane' "$DCORE" || fail 'dispatch does not resolve the mixed runner'
# The subagent board record is a /conduct-runners operation only.
# The record is `hq runners create` (US-035); requiresHqCli is above
# 5.345.210, the first hq-cli with `hq runners`. Only the deprecated alias is
# banned from the conduct skills now.
if grep -q 'hq lanes' "$SKILL" "$MODULE" "$DCORE" "$RSKILL"; then fail 'conduct skills still name the deprecated hq lanes alias'; fi
grep -q 'hq runners create --runner subagent' "$RSKILL" || fail '/conduct-runners does not document the subagent board record'
grep -q 'no runtime dependency on the detached runners' "$MODULE" || fail 'normal conduct subagents still depend on detached runners'
# Shipped conduct files name no personal/ script and no owner-decision dates.
RDIR="$(dirname "$RSKILL")"
if grep -rq 'personal/skills' "$RDIR" "$(dirname "$SKILL")"; then fail 'conduct skills name a personal/ script'; fi
if grep -rqi 'owner decision,\{0,1\} 20[0-9][0-9]-' "$RDIR" "$(dirname "$SKILL")"; then fail 'conduct skills carry owner-decision provenance dates'; fi
if grep -rqi 'frogbear' "$RDIR"; then fail 'conduct-runners carries a personal organization name'; fi
# Codex stays in default mode on spawn_agent; it is not a reason for runners.
# shellcheck disable=SC2016  # literal backticks from the markdown
if grep -q 'no `Agent` tool (Codex' "$SKILL" "$MODULE" "$RSKILL"; then fail 'conduct skills still send a Codex host to /conduct-runners'; fi
grep -q 'spawn_agent' "$SKILL" || fail '/conduct does not keep a Codex host on spawn_agent'
grep -q 'spawn_agent' "$MODULE" || fail 'default dispatch does not name spawn_agent for Codex'
grep -q -- '--host codex' "$MODULE" || fail 'default dispatch does not pass --host codex in a Codex session'
if grep -Eq 'hq (runners|lanes) create --runner subagent' "$DCORE" "$MODULE" "$RUNNERS"; then fail 'normal conduct still registers subagents through hq runners'; fi
# shellcheck disable=SC2016  # literal backticks from the markdown
grep -q 'ships `subagent`' "$DCORE" || fail 'dispatch does not name subagent as the release default'
grep -q 'conduct-standing.sh send' "$RUNNERS" || fail 'dispatch does not route to standing lanes'
grep -q 'conduct-standing.sh agent-type' "$MODULE" || fail 'dispatch does not map workers to agent types'
grep -q 'keep-alive <lane> --on --standing' "$RUNNERS" || fail 'dispatch does not describe standing keep-alive'
if grep -q 'planned as' "$DCORE" "$MODULE" "$RUNNERS"; then fail 'dispatch still calls the subagent runner planned'; fi
injected="$(awk '/<!-- inject:start -->/{on=1;next} /<!-- inject:end -->/{on=0} on' "$CORE")"
grep -qi 'never does project work' <<<"$injected" || fail 'conductor core does not say the conductor never does project work'
if grep -q '^- Lane:' <<<"$injected"; then fail 'conductor core still sends everything to a lane'; fi
grep -qi 'subagent' <<<"$injected" || fail 'conductor core does not name subagents'
grep -qi 'standing' <<<"$injected" || fail 'conductor core does not name standing lanes'
[ "$(printf '%s\n' "$injected" | wc -c | tr -d ' ')" -le 750 ] || fail 'injected block is over 750 bytes'
echo 'conduct-standing.test.sh: routing and standing-lane reuse passed'
