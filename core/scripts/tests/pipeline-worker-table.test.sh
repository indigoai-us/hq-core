#!/usr/bin/env bash
# pipeline-worker-table.test.sh — behavioural coverage for
# core/scripts/pipeline-worker-table.sh, the per-worker engine/model table.
#
# Hermetic: every worker.yaml comes from a fixture root passed with
# --workers-root, so real HQ workers never leak into the result. The cases that
# matter are the ones where a wrong answer would be silent: a worker with no
# usable model must stay empty and flagged, a model_hint must touch only its own
# story, and each engine must get the runner's own pin names.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/pipeline-worker-table.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "  ok — $1"; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }
assert_contains() { case "$1" in *"$2"*) : ;; *) fail "$3: missing '$2' in: $1" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3: unexpected '$2' in: $1" ;; *) : ;; esac; }

W="$TMP/workers"
mkw() { mkdir -p "$W/$1"; printf '%s\n' "$2" >"$W/$1/worker.yaml"; }
mkw backend-dev 'worker:
  id: backend-dev
execution:
  mode: on_demand
  model: opus'
mkw qa-tester 'worker:
  id: qa-tester
execution:
  codex_model: "gpt-5.4"   # pinned
  codex_flags: --reasoning high --fast'
mkw no-model 'worker:
  id: no-model
execution:
  mode: on_demand
model: should-not-be-read'
mkw both-set 'execution:
  model: sonnet
  codex_model: gpt-5.4'
mkw unused 'execution:
  model: haiku'

# A settings file with a model default, placed where a careless reader would
# look. The table must never pick it up.
mkdir -p "$TMP/settings"
printf 'default_model: gpt-settings-trap\nengine: grok\n' >"$TMP/settings/orchestrator.yaml"

cat >"$TMP/prd.json" <<'JSON'
{"userStories":[
 {"id":"US-1","title":"Build endpoint","worker_preference":["backend-dev"],"model_hint":""},
 {"id":"US-2","title":"Test it","worker_preference":"qa-tester"},
 {"id":"US-3","title":"More backend","worker_preference":["backend-dev"],"model_hint":"opus-hinted"},
 {"id":"US-4","title":"Backend and QA","worker_preference":["backend-dev","qa-tester"]}
]}
JSON

run() { bash "$SCRIPT" --workers-root "$W" "$@"; }

# 1. exactly the two classified workers, seeded from worker.yaml
OUT="$(run "$TMP/prd.json")"
ROWS="$(printf '%s\n' "$OUT" | grep '^row' | cut -f2 | tr '\n' ' ')"
assert_eq "$ROWS" "backend-dev qa-tester " "exactly two rows"
BE="$(printf '%s\n' "$OUT" | grep $'^row\tbackend-dev')"
assert_eq "$(echo "$BE" | cut -f3-6)" $'claude\topus\t\tok' "backend-dev seeded from execution.model"
assert_eq "$(echo "$BE" | cut -f7)" "US-1 US-3 US-4" "backend-dev stories"
QA="$(printf '%s\n' "$OUT" | grep $'^row\tqa-tester')"
assert_eq "$(echo "$QA" | cut -f3-6)" $'codex\tgpt-5.4\thigh\tok' "qa-tester seeded from codex_model + reasoning"
assert_not_contains "$OUT" "gpt-settings-trap" "no settings default"
assert_not_contains "$OUT" "haiku" "unused worker absent"
ok "seeded rows: one per classified worker, engine from the field that is set"

# 2. model_hint overrides only its story
HINTS="$(printf '%s\n' "$OUT" | grep '^hint' || true)"
assert_eq "$HINTS" $'hint\tbackend-dev\tUS-3\topus-hinted' "single hint line for US-3"
assert_eq "$(echo "$BE" | cut -f4)" "opus" "row default unchanged by hint"
ok "model_hint shown for its story only; worker default kept"

# 3. missing value -> empty engine and model, flagged
cat >"$TMP/prd-missing.json" <<'JSON'
{"userStories":[
 {"id":"US-9","title":"x","worker_preference":["no-model"]},
 {"id":"US-10","title":"y","worker_preference":["ghost-worker"]},
 {"id":"US-11","title":"z","worker_preference":["both-set"]}
]}
JSON
OUT="$(run "$TMP/prd-missing.json")"
NM="$(printf '%s\n' "$OUT" | grep $'^row\tno-model')"
assert_eq "$(echo "$NM" | cut -f3,4,6)" $'\t\tneeds-answer' "no-model flagged empty"
assert_contains "$NM" "no execution.model" "no-model note"
GH="$(printf '%s\n' "$OUT" | grep $'^row\tghost-worker')"
assert_eq "$(echo "$GH" | cut -f3,4,6)" $'\t\tneeds-answer' "missing worker.yaml flagged"
BS="$(printf '%s\n' "$OUT" | grep $'^row\tboth-set')"
assert_eq "$(echo "$BS" | cut -f3,4,6)" $'\t\tneeds-answer' "ambiguous flagged, not guessed"
assert_contains "$BS" "claude:sonnet codex:gpt-5.4" "ambiguous lists candidates"
ok "missing or ambiguous worker.yaml value -> empty engine/model, needs-answer"

# 4. keyword fallback and unclassified
cat >"$TMP/prd-fallback.json" <<'JSON'
{"userStories":[
 {"id":"US-20","title":"Add REST endpoint","worker_preference":[]},
 {"id":"US-21","title":"Write a poem","labels":["misc"]}
]}
JSON
OUT="$(run "$TMP/prd-fallback.json")"
assert_contains "$OUT" $'row\tbackend-dev' "fallback endpoint -> backend-dev"
assert_contains "$OUT" $'unclassified\tUS-21' "no match -> unclassified"
ok "fallback keyword classification; no guess when nothing matches"

# 5. confirmed table -> exports for claude, codex, grok
cat >"$TMP/confirmed.tsv" <<'TSV'
# worker engine model effort
backend-dev	claude	opus	medium
qa-tester	codex	gpt-5.4	high
grok-lane	grok	grok-4.6	low
TSV
OUT="$(run --confirmed "$TMP/confirmed.tsv" "$TMP/prd.json")"
assert_contains "$OUT" "export HQ_WORKFLOW_CLAUDE_PLAN_MODEL='opus'" "claude plan"
assert_contains "$OUT" "export HQ_WORKFLOW_CLAUDE_EXEC_MODEL='opus'" "claude exec"
assert_contains "$OUT" "export HQ_WORKFLOW_CLAUDE_EFFORT='medium'" "claude effort"
assert_contains "$OUT" "export HQ_WORKFLOW_MODEL='gpt-5.4'" "codex model"
assert_contains "$OUT" "export HQ_WORKFLOW_EFFORT='high'" "codex effort"
assert_contains "$OUT" "export HQ_WORKFLOW_MODEL='grok-4.6'" "grok model"
assert_contains "$OUT" "export HQ_WORKFLOW_EFFORT='low'" "grok effort"
assert_contains "$OUT" "export HQ_CONDUCT_ENGINE='claude'" "claude lane engine"
assert_contains "$OUT" "export HQ_CONDUCT_ENGINE='codex'" "codex lane engine"
assert_contains "$OUT" "export HQ_CONDUCT_ENGINE='grok'" "grok lane engine"
CODEX_BLOCK="$(printf '%s\n' "$OUT" | sed -n '/^# lane qa-tester/,/^# lane grok/p')"
assert_not_contains "$CODEX_BLOCK" "CLAUDE" "codex lane has no claude pins"
assert_contains "$OUT" "# lane backend-dev story US-3 (model_hint)" "hint block"
assert_contains "$OUT" "export HQ_WORKFLOW_CLAUDE_EXEC_MODEL='opus-hinted'" "hint export"
ok "confirmed table prints runner pins per engine, plus model_hint story blocks"

# 6. pin names exist in the runner
for pin in HQ_WORKFLOW_CLAUDE_PLAN_MODEL HQ_WORKFLOW_CLAUDE_EXEC_MODEL HQ_WORKFLOW_CLAUDE_EFFORT HQ_WORKFLOW_MODEL HQ_WORKFLOW_EFFORT; do
  grep -q "$pin" "$ROOT/core/scripts/workflow-runner.mjs" || fail "runner lacks $pin"
done
ok "export names match workflow-runner.mjs"

# 7. unconfirmed lane refuses
printf 'qa-tester\t\t\t\n' >"$TMP/bad.tsv"
set +e; run --confirmed "$TMP/bad.tsv" "$TMP/prd.json" >/dev/null 2>&1; rc=$?; set -e
assert_eq "$rc" "2" "empty engine exits 2"
ok "confirmed table with an unanswered lane exits 2"

# 8. review regressions: hostile model string stays one quoted word; a final
#    lane with no trailing newline is still emitted
# (table columns are whitespace-split, so the payload uses none)
printf "qa-tester\tcodex\tx';>$TMP/pwned;'\thigh\n" >"$TMP/evil.tsv"
OUT="$(run --confirmed "$TMP/evil.tsv" "$TMP/prd.json")"
( eval "$OUT" ) >/dev/null 2>&1 || true
[ ! -e "$TMP/pwned" ] || fail "model string escaped its quotes when eval'd"
VAL="$(eval "$OUT"; printf '%s' "${HQ_WORKFLOW_MODEL:-}")"
assert_eq "$VAL" "x';>$TMP/pwned;'" "hostile model round-trips verbatim"
printf 'qa-tester\tgrok\tgrok-4.6\thigh' >"$TMP/nonl.tsv"
OUT="$(run --confirmed "$TMP/nonl.tsv" "$TMP/prd.json")"
assert_contains "$OUT" "export HQ_WORKFLOW_MODEL='grok-4.6'" "last lane without newline emitted"
ok "export values are shell-quoted; final unterminated lane is read"

# 9. the lane set is the union of every story's full sequence: a keyword story
#    brings architect and qa-tester rows, the overlay adds its own workers
mkw architect 'execution:
  model: arch-model'
cat >"$TMP/prd-lanes.json" <<'JSON'
{"userStories":[
 {"id":"US-30","title":"Add REST endpoint"},
 {"id":"US-31","title":"Write a poem"},
 {"id":"US-32","title":"x","worker_preference":["backend-dev"]}
]}
JSON
OUT="$(run "$TMP/prd-lanes.json" 2>/dev/null)"
ROWS="$(printf '%s\n' "$OUT" | grep '^row' | cut -f2 | tr '\n' ' ')"
assert_eq "$ROWS" "architect backend-dev qa-tester " "keyword story yields the full sequence's lanes"
assert_contains "$OUT" $'unclassified\tUS-31' "no overlay -> unclassified"
printf '{"ordered_stories":[{"id":"US-31","worker_sequence":["no-model","qa-tester"]},{"id":"US-32","worker_sequence":["backend-dev","qa-tester"]}]}' >"$TMP/overlay.json"
OUT="$(run --overlay "$TMP/overlay.json" "$TMP/prd-lanes.json" 2>/dev/null)"
ROWS="$(printf '%s\n' "$OUT" | grep '^row' | cut -f2 | tr '\n' ' ')"
assert_eq "$ROWS" "architect backend-dev qa-tester no-model " "overlay sequences add their workers"
assert_not_contains "$OUT" "unclassified" "overlay classifies US-31"
assert_eq "$(printf '%s\n' "$OUT" | grep $'^row\tqa-tester' | cut -f7)" "US-30 US-31 US-32" "qa-tester serves every story whose sequence names it"
ok "lane set is derived from every story's sequence, overlay first"

# 10. an unknown worker is named on stderr with the roots and the known ids
ERR="$(run "$TMP/prd-missing.json" 2>&1 >/dev/null)"
assert_contains "$ERR" "unknown worker ghost-worker: no worker.yaml under $W" "unknown worker named with root"
assert_contains "$ERR" "known: architect backend-dev both-set no-model qa-tester unused" "known ids listed"
ok "unknown worker reported with the roots searched and the known ids"

# 11. a model_hint never overrides the lane pin; a bare alias is never printed as a model
cat >"$TMP/prd-alias.json" <<'JSON'
{"userStories":[{"id":"US-40","title":"x","worker_preference":["backend-dev"],"model_hint":"sonnet"}]}
JSON
OUT="$(run --confirmed "$TMP/confirmed.tsv" "$TMP/prd.json")"
assert_contains "$OUT" "# lane backend-dev story US-3 (model_hint) hint ignored, table pins opus" "pin wins"
assert_eq "$(printf '%s\n' "$OUT" | grep -c "^export HQ_WORKFLOW_CLAUDE_EXEC_MODEL='opus-hinted'")" "0" "hint export is not live"
VAL="$(eval "$OUT"; printf '%s' "${HQ_WORKFLOW_CLAUDE_EXEC_MODEL:-}")"
assert_eq "$VAL" "opus" "sourcing the exports keeps the pinned model"
OUT="$(run --confirmed "$TMP/confirmed.tsv" "$TMP/prd-alias.json")"
assert_contains "$OUT" "# lane backend-dev story US-40 (model_hint) bare alias ignored, table pins opus" "bare alias noted"
assert_not_contains "$OUT" "'sonnet'" "bare alias never exported"
ok "table pin wins over model_hint; bare alias never exported"

# 12. portable: no bash-only syntax
if command -v dash >/dev/null 2>&1; then dash -n "$SCRIPT" || fail "dash -n failed"; fi
sh -n "$SCRIPT" || fail "sh -n failed"
OUT="$(sh "$SCRIPT" --workers-root "$W" "$TMP/prd.json")"
assert_eq "$(printf '%s\n' "$OUT" | grep '^row' | cut -f2 | tr '\n' ' ')" "backend-dev qa-tester " "runs under sh"
ok "dash -n and sh -n clean; runs under sh"

echo "pipeline-worker-table: $PASS passed"
