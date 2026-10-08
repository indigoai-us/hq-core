#!/bin/sh
# hq-core: public
# pipeline-worker-table.sh — the per-worker engine/model table behind
# /run-project --pipeline.
#
# Each worker lane runs on its own engine and model. This script proposes that
# table from a prd.json and, once the owner has confirmed it, turns it into the
# launcher exports each lane starts with. It never reads an engine or model
# default from a settings file (orchestrator.yaml, settings.json, ...): the only
# seed is each worker's own worker.yaml, and anything that cannot be read off
# it is left empty and flagged for the owner to answer.
#
# Usage:
#   pipeline-worker-table.sh [--workers-root <dir>]... [--overlay <file>] <prd.json>
#   pipeline-worker-table.sh [--workers-root <dir>]... [--overlay <file>] --confirmed <table.tsv> <prd.json>
#
# PROPOSE MODE (no --confirmed) prints tab-separated lines:
#
#   row   <worker> <engine> <model> <effort> <status> <stories> <note>
#   hint  <worker> <story>  <model>
#   unclassified <story>
#
#   status is `ok` or `needs-answer`. The lane set is the union of every
#   story's worker sequence: one `row` per distinct worker that appears in any
#   sequence (architect and qa-tester included), in first-seen order. A `hint`
#   line is a story's model_hint, shown for the owner; a confirmed table pin wins
#   over it (see CONFIRMED MODE).
#
# WORKER SEQUENCE (story -> workers, the full phase sequence in order), first
# match wins; pipeline-conductor.sh classify reads the same three sources:
#   1. --overlay <file> (the run's <state>/overlay.json, or the preflight plan):
#      {id: {"worker_sequence": [...]}}, {id: [...]}, or
#      {"ordered_stories": [{"id": .., "worker_sequence": [...]}]}.
#   2. worker_preference — a string or an array of worker ids, used as given.
#   3. Fallback, only when both are empty: the keyword table from
#      .claude/skills/execute-task/SKILL.md step 3, matched case-insensitively
#      against title + description + labels:
#        schema_change   (database|migration|schema|prisma|sql)   -> database-dev
#        ui_component    (component|page|form|button|react|ui)    -> frontend-dev
#        api_development (endpoint|api|rest|graphql|route|service) -> backend-dev
#      giving architect, the matched implementers (backend-dev also for a
#      schema change), then qa-tester.
#      A story matching none is printed as `unclassified`; no worker is guessed.
#
# UNKNOWN WORKERS: a worker with no worker.yaml under the worker roots gets an
# empty, needs-answer row noted "no worker.yaml", and a line on stderr naming
# the id, the roots searched and every known id. pipeline-conductor.sh classify
# refuses such a worker before launch.
#
# ENGINE SEED (from worker.yaml `execution:`):
#   model only        -> engine claude, model = execution.model
#   codex_model only  -> engine codex,  model = execution.codex_model,
#                        effort = `--reasoning <x>` from execution.codex_flags
#   both set          -> ambiguous: engine and model empty, needs-answer, the
#                        candidates listed in the note column
#   neither / no file -> engine and model empty, needs-answer
#   worker.yaml has no grok field, so grok is never seeded; the owner chooses it
#   in the confirmed table.
#
# CONFIRMED MODE: --confirmed <file> holds one lane per line,
#   <worker> <engine> <model> <effort>   (tabs or spaces; # comments allowed;
#   effort may be omitted). engine must be claude, codex, or grok and model must
#   be non-empty, or the script exits 2. Output per lane, using the pins in
#   core/scripts/workflow-runner.mjs, plus HQ_CONDUCT_ENGINE=<engine> for
#   every lane (a loop lane runs pipeline phase envelopes on that engine):
#     claude      -> HQ_WORKFLOW_CLAUDE_PLAN_MODEL, HQ_WORKFLOW_CLAUDE_EXEC_MODEL,
#                    HQ_WORKFLOW_CLAUDE_EFFORT
#     codex|grok  -> HQ_WORKFLOW_MODEL, HQ_WORKFLOW_EFFORT
#   The effort export is omitted when effort is empty (runner default applies).
#   A story's model_hint never overrides the lane: the lane's table pin wins.
#   Each hinted story on a confirmed lane gets a `# lane <w> story <id>
#   (model_hint)` block whose exports are commented out and that says "hint
#   ignored, table pins <model>". A bare alias (opus, sonnet, haiku, fable) is
#   never printed as a model.
#
# Worker roots: --workers-root (repeatable) or PIPELINE_WORKERS_ROOTS
# (colon-separated). Default: <hq>/core/workers, <hq>/companies/*/workers,
# <hq>/personal/workers. A worker is the directory named <id> holding worker.yaml.
#
# POSIX sh (dash-clean); JSON work is done by jq.

set -eu

HQ_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NL='
'
TAB="$(printf '\t')"

die() { echo "pipeline-worker-table: $1" >&2; exit "${2:-1}"; }

ROOTS=""
CONFIRMED=""
OVERLAY=""
PRD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workers-root) [ $# -ge 2 ] || die "--workers-root needs a dir"; ROOTS="${ROOTS:+$ROOTS$NL}$2"; shift 2 ;;
    --confirmed) [ $# -ge 2 ] || die "--confirmed needs a file"; CONFIRMED="$2"; shift 2 ;;
    --overlay) [ $# -ge 2 ] || die "--overlay needs a file"; OVERLAY="$2"; shift 2 ;;
    -h|--help) sed -n '3,/^# POSIX sh/p' "$0"; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *) [ -z "$PRD" ] || die "only one prd.json"; PRD="$1"; shift ;;
  esac
done
[ -n "$PRD" ] || die "usage: pipeline-worker-table.sh [--workers-root <dir>] [--overlay <file>] [--confirmed <file>] <prd.json>"
[ -f "$PRD" ] || die "no such prd: $PRD"
command -v jq >/dev/null 2>&1 || die "jq is required"
jq -e '.userStories | type == "array"' "$PRD" >/dev/null 2>&1 || die "not a prd (no userStories array): $PRD"
if [ -n "$OVERLAY" ]; then
  [ -f "$OVERLAY" ] || die "no such overlay: $OVERLAY"
  jq -e 'type == "object"' "$OVERLAY" >/dev/null 2>&1 || die "overlay is not a JSON object: $OVERLAY"
fi

if [ -z "$ROOTS" ]; then
  if [ -n "${PIPELINE_WORKERS_ROOTS:-}" ]; then
    ROOTS="$(printf '%s\n' "$PIPELINE_WORKERS_ROOTS" | tr ':' '\n')"
  else
    ROOTS="$HQ_ROOT/core/workers"
    for d in "$HQ_ROOT"/companies/*/workers; do [ -d "$d" ] && ROOTS="$ROOTS$NL$d"; done
    ROOTS="$ROOTS$NL$HQ_ROOT/personal/workers"
  fi
fi

# SEQS: one line per story, "<id><TAB><w1> <w2> ..." (empty worker list when
# unclassified), in prd order. The one place the sequence is derived.
SEQS="$(jq -r --slurpfile ov "${OVERLAY:-/dev/null}" '
  def seq: if type == "array" then [.[] | select(type == "string" and length > 0)]
           elif type == "string" then [split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0)]
           elif type == "object" then (.worker_sequence // [] | seq) else [] end;
  ($ov[0] // {}) as $o
  | (if ($o.ordered_stories | type) == "array"
       then [$o.ordered_stories[] | select(type == "object" and (.id | type) == "string") | {key: .id, value: (.worker_sequence // [] | seq)}] | from_entries
       else ($o | with_entries(.value |= seq)) end) as $m
  | .userStories[]
  | . as $s
  | ([$s.title // "", $s.description // "", (($s.labels // []) | join(" "))] | join(" ") | ascii_downcase) as $t
  | ($m[$s.id // ""] // []) as $ovs
  | (($s.worker_preference // []) | seq) as $pref
  | (if ($ovs | length) > 0 then $ovs
     elif ($pref | length) > 0 then $pref
     else
       ($t | test("\\b(database|migration|schema|prisma|sql)\\b")) as $schema
       | ($t | test("\\b(component|page|form|button|react|ui)\\b")) as $ui
       | ($t | test("\\b(endpoint|api|rest|graphql|route|service)\\b")) as $api
       | if ($schema or $ui or $api) | not then []
         else ["architect"] + (if $schema then ["database-dev"] else [] end)
              + (if ($api or $schema) then ["backend-dev"] else [] end)
              + (if $ui then ["frontend-dev"] else [] end) + ["qa-tester"] end
     end) as $w
  | "\($s.id // "")\t\($w | join(" "))"' "$PRD")"

# story_has <story id> <worker> -> 0 when the worker is in that story's sequence
story_has() {
  printf '%s\n' "$SEQS" | while IFS="$TAB" read -r sid ws; do
    [ "$sid" = "$1" ] || continue
    case " $ws " in *" $2 "*) echo yes ;; esac
  done | grep -q yes
}

find_worker_yaml() {
  printf '%s\n' "$ROOTS" | while IFS= read -r r; do
    [ -n "$r" ] && [ -d "$r" ] || continue
    hit="$(find "$r" -type f -name worker.yaml -path "*/$1/worker.yaml" 2>/dev/null | head -n 1)"
    if [ -n "$hit" ]; then echo "$hit"; break; fi
  done
}

known_workers() {
  printf '%s\n' "$ROOTS" | while IFS= read -r r; do
    [ -n "$r" ] && [ -d "$r" ] || continue
    find "$r" -type f -name worker.yaml 2>/dev/null
  done | while IFS= read -r y; do basename "$(dirname "$y")"; done | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# exec_field <worker.yaml> <key> -> value of execution.<key>, quotes and
# trailing comments stripped; empty when absent.
exec_field() {
  awk -v key="$2" '
    /^[^[:space:]#]/ { inexec = ($0 ~ /^execution:[[:space:]]*$/); next }
    inexec && $0 ~ "^[[:space:]]+" key ":" {
      v = $0; sub("^[[:space:]]+" key ":[[:space:]]*", "", v)
      sub(/[[:space:]]+#.*$/, "", v); sub(/[[:space:]]+$/, "", v)
      gsub(/^["'\'']|["'\'']$/, "", v); print v; exit
    }' "$1"
}

N="$(jq '.userStories | length' "$PRD")"

# ---- confirmed mode -------------------------------------------------------
# sq <value> -> value as one single-quoted shell word (embedded ' escaped), so
# a hostile model/effort string in the table or prd cannot break out of the
# export line when it is eval'd or sourced.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

emit_exports() { # engine model effort [prefix]
  printf '%sexport HQ_CONDUCT_ENGINE=%s\n' "${4:-}" "$(sq "$1")"
  case "$1" in
    claude)
      printf '%sexport HQ_WORKFLOW_CLAUDE_PLAN_MODEL=%s\n' "${4:-}" "$(sq "$2")"
      printf '%sexport HQ_WORKFLOW_CLAUDE_EXEC_MODEL=%s\n' "${4:-}" "$(sq "$2")"
      [ -z "$3" ] || printf '%sexport HQ_WORKFLOW_CLAUDE_EFFORT=%s\n' "${4:-}" "$(sq "$3")" ;;
    codex|grok)
      printf '%sexport HQ_WORKFLOW_MODEL=%s\n' "${4:-}" "$(sq "$2")"
      [ -z "$3" ] || printf '%sexport HQ_WORKFLOW_EFFORT=%s\n' "${4:-}" "$(sq "$3")" ;;
  esac
}

is_bare_alias() { case "$1" in opus|sonnet|haiku|fable|Opus|Sonnet|Haiku|Fable) return 0 ;; esac; return 1; }

if [ -n "$CONFIRMED" ]; then
  [ -f "$CONFIRMED" ] || die "no such confirmed table: $CONFIRMED"
  while read -r w engine model effort _rest || [ -n "${w:-}" ]; do
    case "$w" in ''|'#'*|worker) continue ;; esac
    case "${engine:-}" in claude|codex|grok) ;; *) die "lane $w: engine must be claude, codex, or grok (got '${engine:-}')" 2 ;; esac
    [ -n "${model:-}" ] || die "lane $w: model is empty — answer it before launch" 2
    echo "# lane $w ($engine)"
    emit_exports "$engine" "$model" "${effort:-}"
    i=0
    while [ "$i" -lt "$N" ]; do
      hint="$(jq -r --argjson i "$i" '.userStories[$i].model_hint // ""' "$PRD")"
      sid="$(jq -r --argjson i "$i" '.userStories[$i].id' "$PRD")"
      if [ -n "$hint" ] && story_has "$sid" "$w"; then
        if is_bare_alias "$hint"; then
          echo "# lane $w story $sid (model_hint) bare alias ignored, table pins $model"
        else
          echo "# lane $w story $sid (model_hint) hint ignored, table pins $model"
          emit_exports "$engine" "$hint" "${effort:-}" "# "
        fi
      fi
      i=$((i + 1))
    done
    w=""; engine=""; model=""; effort=""
  done <"$CONFIRMED"
  exit 0
fi

# ---- propose mode ---------------------------------------------------------
# WORKERS: distinct workers, first-seen order, one per line.
# STORIES_OF <worker>: the story ids whose sequence holds it, space-joined.
WORKERS="$(printf '%s\n' "$SEQS" | while IFS="$TAB" read -r sid ws; do
  for w in $ws; do echo "$w"; done
done | awk '!seen[$0]++')"

printf '%s\n' "$SEQS" | while IFS="$TAB" read -r sid ws; do
  [ -n "$ws" ] || printf 'unclassified\t%s\n' "$sid"
done

stories_of() {
  printf '%s\n' "$SEQS" | while IFS="$TAB" read -r sid ws; do
    case " $ws " in *" $1 "*) printf '%s\n' "$sid" ;; esac
  done | tr '\n' ' ' | sed 's/ $//'
}

KNOWN=""
printf '%s\n' "$WORKERS" | while IFS= read -r w; do
  [ -n "$w" ] || continue
  engine=""; model=""; effort=""; status="needs-answer"; note=""
  y="$(find_worker_yaml "$w")"
  if [ -z "$y" ]; then
    note="no worker.yaml"
    [ -n "$KNOWN" ] || KNOWN="$(known_workers)"
    echo "pipeline-worker-table: unknown worker $w: no worker.yaml under $(printf '%s\n' "$ROOTS" | tr '\n' ' ' | sed 's/ $//'); known: ${KNOWN:-none}" >&2
  else
    cm="$(exec_field "$y" model)"; xm="$(exec_field "$y" codex_model)"
    if [ -n "$cm" ] && [ -n "$xm" ]; then
      note="ambiguous: claude:$cm codex:$xm"
    elif [ -n "$cm" ]; then
      engine=claude; model="$cm"; status=ok
    elif [ -n "$xm" ]; then
      engine=codex; model="$xm"; status=ok
      effort="$(exec_field "$y" codex_flags | sed -n 's/.*--reasoning[= ]\([A-Za-z]*\).*/\1/p')"
    else
      note="no execution.model or execution.codex_model"
    fi
  fi
  printf 'row\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$w" "$engine" "$model" "$effort" "$status" "$(stories_of "$w")" "$note"
done

# hint lines: each hinted story in prd order, one per worker in its sequence
jq -r '.userStories[] | select((.model_hint // "") != "") | "\(.id)\t\(.model_hint)"' "$PRD" |
  while IFS="$TAB" read -r sid hint; do
    ws="$(printf '%s\n' "$SEQS" | while IFS="$TAB" read -r s2 w2; do if [ "$s2" = "$sid" ]; then printf "%s\n" "$w2"; fi; done)"
    for w in $ws; do printf 'hint\t%s\t%s\t%s\n' "$w" "$sid" "$hint"; done
  done
exit 0
