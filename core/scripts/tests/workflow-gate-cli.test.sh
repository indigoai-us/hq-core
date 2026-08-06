#!/bin/bash
# Regression test for core/scripts/workflow-gate.sh — the answering CLI for the
# workflow human-gate protocol (see
# core/knowledge/public/hq-core/workflow-gates-spec.md).
#
# Covers the CLI + file protocol only; it needs no workflow runner. Pending
# gates are synthesized directly as files, exactly as a paused orchestrator
# would write them. Covered behaviors:
#   1. list: empty state, and one line per pending gate (id, question, options)
#   2. show: prints the pending gate; falls back to the answered file; fails on
#      an unknown id
#   3. answer by label: writes answered/<id>.json (choice, answered_at, and
#      --notes/--by fields), removes the pending file
#   4. answer by 1-based index: `answer <id> 2` maps to the 2nd option label
#   5. validation: unknown gate id fails without --force; --force pre-answers a
#      gate that has not opened yet; an off-menu choice fails without
#      --freeform and is recorded with it; answering twice fails without
#      --force and overwrites with it
#   6. wait-pending: exits 0 when a pending gate exists, non-zero after
#      --timeout with none (a wake condition for watching sessions)
#   7. clear: removes both the pending and answered files for an id
#
# Hermetic: CODEX_WORKFLOW_GATES_DIR points every call at a temp dir.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
GATE_SH="$REPO_ROOT/core/scripts/workflow-gate.sh"

pass=0
fail=0
check() { # check <name> <condition-exit-code>
  if [ "$2" -eq 0 ]; then
    printf 'ok   - %s\n' "$1"; pass=$((pass + 1))
  else
    printf 'FAIL - %s\n' "$1"; fail=$((fail + 1))
  fi
}

TMP="$(mktemp -d /tmp/workflow-gate-cli-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# synth_pending <gates-dir> <id> — write a pending gate the way a paused
# orchestrator would (self-contained: question, options, context, recommended)
synth_pending() {
  mkdir -p "$1/pending"
  node -e '
    const fs = require("fs");
    const [, dir, id] = process.argv;
    fs.writeFileSync(`${dir}/pending/${id}.json`, JSON.stringify({
      id,
      question: "Which color should the widget be?",
      options: [
        { label: "red", description: "bold" },
        { label: "blue", description: "calm" },
      ],
      context: "The widget ships tomorrow.",
      recommended: "blue",
      status: "pending",
      created_at: new Date().toISOString(),
      run_id: "wf-test",
      answer_path: `${dir}/answered/${id}.json`,
    }, null, 2) + "\n");
  ' "$1" "$2"
}

gate() { CODEX_WORKFLOW_GATES_DIR="$1" bash "$GATE_SH" "${@:2}"; }

# ---- 1: list ----------------------------------------------------------------
G1="$TMP/g1"; mkdir -p "$G1"
OUT="$(gate "$G1" list)"
[ "$OUT" = "no pending gates" ]
check "list reports the empty state" "$?"

synth_pending "$G1" pick-color
OUT="$(gate "$G1" list)"
printf '%s' "$OUT" | grep -q 'pick-color' \
  && printf '%s' "$OUT" | grep -q 'Which color' \
  && printf '%s' "$OUT" | grep -q '1=red 2=blue'
check "list shows id, question, and numbered options" "$?"

# ---- 2: show ----------------------------------------------------------------
gate "$G1" show pick-color | node -e '
  const g = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(g.id === "pick-color" && g.recommended === "blue" ? 0 : 1);
'
check "show prints the pending gate JSON" "$?"
gate "$G1" show no-such-gate >/dev/null 2>&1
[ "$?" -ne 0 ]
check "show fails on an unknown id" "$?"

# ---- 3: answer by label ------------------------------------------------------
gate "$G1" answer pick-color blue --notes "match the brand" --by tester >/dev/null
check "answer by label exits 0" "$?"
[ ! -f "$G1/pending/pick-color.json" ]
check "pending file removed after answer" "$?"
node -e '
  const a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.exit(a.id === "pick-color" && a.choice === "blue"
    && a.notes === "match the brand" && a.answered_by === "tester"
    && typeof a.answered_at === "string" && !Number.isNaN(Date.parse(a.answered_at)) ? 0 : 1);
' "$G1/answered/pick-color.json"
check "answered file carries choice, notes, answered_by, answered_at" "$?"

# show falls back to the answered file once pending is gone
gate "$G1" show pick-color | node -e '
  const a = JSON.parse(require("fs").readFileSync(0, "utf8"));
  process.exit(a.choice === "blue" ? 0 : 1);
'
check "show falls back to the answered file" "$?"

# ---- 4: answer by index ------------------------------------------------------
G2="$TMP/g2"; mkdir -p "$G2"
synth_pending "$G2" pick-color
gate "$G2" answer pick-color 2 >/dev/null
check "numeric answer exits 0" "$?"
node -e '
  const a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.exit(a.choice === "blue" ? 0 : 1);
' "$G2/answered/pick-color.json"
check "answer 2 mapped to the 2nd option label (blue)" "$?"

G3="$TMP/g3"; mkdir -p "$G3"
synth_pending "$G3" pick-color
gate "$G3" answer pick-color 7 >/dev/null 2>&1
[ "$?" -ne 0 ]
check "out-of-range index fails" "$?"

# ---- 5: validation -----------------------------------------------------------
G4="$TMP/g4"; mkdir -p "$G4"
gate "$G4" answer never-opened yes >/dev/null 2>&1
[ "$?" -ne 0 ]
check "unknown gate id fails without --force" "$?"
gate "$G4" answer never-opened yes --force >/dev/null 2>&1
check "--force pre-answers a gate that has not opened yet" "$?"
[ -f "$G4/answered/never-opened.json" ]
check "pre-answer written to answered/" "$?"

G5="$TMP/g5"; mkdir -p "$G5"
synth_pending "$G5" pick-color
gate "$G5" answer pick-color purple >/dev/null 2>&1
[ "$?" -ne 0 ]
check "off-menu choice fails without --freeform" "$?"
gate "$G5" answer pick-color purple --freeform >/dev/null
check "--freeform records an off-menu choice" "$?"
node -e '
  const a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.exit(a.choice === "purple" ? 0 : 1);
' "$G5/answered/pick-color.json"
check "freeform choice stored verbatim" "$?"

gate "$G5" answer pick-color red --force --freeform >/dev/null 2>&1
RC1=$?
node -e '
  const a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.exit(a.choice === "red" ? 0 : 1);
' "$G5/answered/pick-color.json"
RC2=$?
synth_pending "$G5" pick-color
gate "$G5" answer pick-color red >/dev/null 2>&1
RC3=$?
[ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$RC3" -ne 0 ]
check "answering twice fails without --force and overwrites with it" "$?"

# ---- 6: wait-pending ---------------------------------------------------------
G6="$TMP/g6"; mkdir -p "$G6"
synth_pending "$G6" waiting
gate "$G6" wait-pending --timeout 3 >/dev/null 2>&1
check "wait-pending exits 0 when a pending gate exists" "$?"
G7="$TMP/g7"; mkdir -p "$G7"
gate "$G7" wait-pending --timeout 1 >/dev/null 2>&1
[ "$?" -ne 0 ]
check "wait-pending times out non-zero when nothing is pending" "$?"

# ---- 7: malformed input is rejected, never hangs -----------------------------
G9="$TMP/g9"; mkdir -p "$G9"
synth_pending "$G9" pick-color
gate "$G9" answer '../escape' yes --force >/dev/null 2>&1
[ "$?" -ne 0 ] && [ ! -f "$TMP/answered/../escape.json" ] && [ ! -e "$G9/escape.json" ]
check "path-traversal gate id is rejected" "$?"
gate "$G9" answer 'UPPER/slash' yes --force >/dev/null 2>&1
[ "$?" -ne 0 ]
check "non-slug gate id is rejected" "$?"

# a trailing flag with no value must fail fast, not loop forever
( gate "$G9" answer pick-color blue --notes >/dev/null 2>&1 ) &
HANGPID=$!
hang_budget=25
while kill -0 "$HANGPID" 2>/dev/null && [ "$hang_budget" -gt 0 ]; do
  sleep 0.2; hang_budget=$((hang_budget - 1))
done
if kill -0 "$HANGPID" 2>/dev/null; then
  kill "$HANGPID" 2>/dev/null; wait "$HANGPID" 2>/dev/null
  false
else
  wait "$HANGPID"; [ "$?" -ne 0 ]
fi
check "--notes without a value fails fast (no hang)" "$?"

gate "$G9" wait-pending --timeout abc >/dev/null 2>&1
[ "$?" -ne 0 ]
check "wait-pending rejects a non-numeric --timeout" "$?"

# ---- 8: clear ----------------------------------------------------------------
G8="$TMP/g8"; mkdir -p "$G8"
synth_pending "$G8" gone
gate "$G8" answer gone 1 >/dev/null
synth_pending "$G8" gone
gate "$G8" clear gone >/dev/null
[ ! -f "$G8/pending/gone.json" ] && [ ! -f "$G8/answered/gone.json" ]
check "clear removes both pending and answered files" "$?"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
