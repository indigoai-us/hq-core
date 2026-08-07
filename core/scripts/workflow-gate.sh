#!/bin/bash
# workflow-gate.sh — inspect and answer human gates opened by codex-workflow.mjs gate().
#
# A gate is a self-contained pending question file written by a paused workflow
# run; writing a matching answered/<id>.json resumes that run in place. Answers
# are durable: a re-launched run returns them instantly instead of re-asking
# the human, so never delete answered/ files while their project is live.
#
# Usage:
#   workflow-gate.sh list
#   workflow-gate.sh show <id>
#   workflow-gate.sh answer <id> <choice|N> [--notes "..."] [--by name] [--force] [--freeform]
#       <choice|N>   an option label, or a 1-based option index
#       --notes      free-text note stored alongside the choice
#       --by         who answered (recorded as answered_by)
#       --force      pre-answer a gate that has not opened yet, or overwrite an
#                    existing answer
#       --freeform   accept a choice that is not one of the gate's options
#   workflow-gate.sh wait-pending [--timeout secs]
#       Blocks until any pending gate exists (exit 0) or the timeout elapses
#       (exit 1). Monitor-friendly wake condition for watching sessions.
#   workflow-gate.sh watch-run <run-dir> [--timeout secs]
#       Run-scoped wake condition for the session that launched a workflow.
#       Blocks until a gate belonging to THAT run opens (prints its id, exit 0),
#       the run finishes (exit 3), or --timeout elapses (exit 1). Match is on
#       the run_dir every gate carries, which is the --run-dir the launching
#       session chose — no id parsing, no env coupling, no startup race.
#   workflow-gate.sh clear <id>
#       Remove both the pending and answered files for a gate id.
#
# Env: HQ_WORKFLOW_GATES_DIR overrides the gates root (default
# <hq-root>/workspace/gates); legacy CODEX_WORKFLOW_GATES_DIR is honored.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HQ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATES_DIR="${HQ_WORKFLOW_GATES_DIR:-${CODEX_WORKFLOW_GATES_DIR:-$HQ_ROOT/workspace/gates}}"
PENDING_DIR="$GATES_DIR/pending"
ANSWERED_DIR="$GATES_DIR/answered"

die() { printf 'workflow-gate: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# Gate ids are slugged filenames (see the spec) — reject anything else so an id
# can never traverse outside the gates dir or smuggle path separators.
require_gate_id() {
  case "$1" in
    (*[!a-z0-9._-]*|'') die "invalid gate id \"$1\" — ids are lowercase [a-z0-9._-]" ;;
  esac
}

cmd="${1:-}"
[ -n "$cmd" ] || usage 1
shift

case "$cmd" in

  list)
    if ! ls "$PENDING_DIR"/*.json >/dev/null 2>&1; then
      echo "no pending gates"
      exit 0
    fi
    node -e '
      const fs = require("fs");
      for (const f of process.argv.slice(1)) {
        try {
          const g = JSON.parse(fs.readFileSync(f, "utf8"));
          const ageMin = Math.max(0, Math.round((Date.now() - Date.parse(g.created_at || 0)) / 60000));
          const opts = (g.options || []).map((o, i) => `${i + 1}=${o.label}`).join(" ");
          console.log(`${g.id}  (${ageMin}m)  ${g.question}${opts ? `  [${opts}]` : ""}`);
        } catch { console.log(`<unreadable> ${f}`); }
      }
    ' "$PENDING_DIR"/*.json
    ;;

  show)
    id="${1:-}"
    [ -n "$id" ] || die "usage: show <id>"
    require_gate_id "$id"
    if [ -f "$PENDING_DIR/$id.json" ]; then
      cat "$PENDING_DIR/$id.json"
    elif [ -f "$ANSWERED_DIR/$id.json" ]; then
      cat "$ANSWERED_DIR/$id.json"
    else
      die "no gate \"$id\" in pending or answered"
    fi
    ;;

  answer)
    id="${1:-}"; choice="${2:-}"
    { [ -n "$id" ] && [ -n "$choice" ]; } || die "usage: answer <id> <choice|N> [--notes ...] [--by name] [--force] [--freeform]"
    require_gate_id "$id"
    shift 2
    notes=""; by=""; force=0; freeform=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --notes) [ $# -ge 2 ] || die "--notes needs a value"; notes="$2"; shift 2 ;;
        --by) [ $# -ge 2 ] || die "--by needs a value"; by="$2"; shift 2 ;;
        --force) force=1; shift ;;
        --freeform) freeform=1; shift ;;
        *) die "unknown flag: $1" ;;
      esac
    done
    JS="$(cat <<'NODE'
const fs = require("fs");
const path = require("path");
const [, pendingDir, answeredDir, id, rawChoice, notes, by, force, freeform] = process.argv;
const F = force === "1";
const FF = freeform === "1";
const pendingFile = path.join(pendingDir, id + ".json");
const answeredFile = path.join(answeredDir, id + ".json");
const fail = (m) => { console.error("workflow-gate: " + m); process.exit(1); };

let gate = null;
try { gate = JSON.parse(fs.readFileSync(pendingFile, "utf8")); } catch { /* not pending */ }
if (!gate && !F) {
  let ids = [];
  try { ids = fs.readdirSync(pendingDir).filter((f) => f.endsWith(".json")).map((f) => f.slice(0, -5)); } catch { /* no dir */ }
  fail(`no pending gate "${id}"${ids.length ? ` — pending: ${ids.join(", ")}` : " — nothing is pending"} (use --force to pre-answer)`);
}

let choice = rawChoice;
const opts = gate && Array.isArray(gate.options) ? gate.options : [];
if (opts.length) {
  if (/^[0-9]+$/.test(rawChoice)) {
    const n = Number(rawChoice);
    if (n >= 1 && n <= opts.length) choice = opts[n - 1].label;
    else fail(`index ${n} is out of range 1..${opts.length} for "${id}"`);
  } else {
    const hit = opts.find((o) => String(o.label).toLowerCase() === rawChoice.toLowerCase());
    if (hit) choice = hit.label;
    else if (!FF) fail(`"${rawChoice}" is not an option for "${id}" — options: ${opts.map((o) => o.label).join(", ")} (use --freeform to record it anyway)`);
  }
}

if (fs.existsSync(answeredFile) && !F) {
  fail(`gate "${id}" is already answered (${answeredFile}) — use --force to overwrite`);
}
fs.mkdirSync(answeredDir, { recursive: true });
const answer = {
  id,
  choice,
  ...(notes ? { notes } : {}),
  ...(by ? { answered_by: by } : {}),
  answered_at: new Date().toISOString(),
};
const tmp = `${answeredFile}.tmp-${process.pid}`;
fs.writeFileSync(tmp, JSON.stringify(answer, null, 2) + "\n");
fs.renameSync(tmp, answeredFile);
try { fs.rmSync(pendingFile, { force: true }); } catch { /* best-effort */ }
console.log(`answered ${id} -> ${choice}`);
NODE
)"
    node -e "$JS" "$PENDING_DIR" "$ANSWERED_DIR" "$id" "$choice" "$notes" "$by" "$force" "$freeform"
    ;;

  wait-pending)
    timeout=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; timeout="$2"; shift 2 ;;
        *) die "unknown flag: $1" ;;
      esac
    done
    if [ -n "$timeout" ]; then
      case "$timeout" in
        (*[!0-9]*|'') die "--timeout must be a whole number of seconds" ;;
      esac
    fi
    elapsed=0
    while :; do
      if ls "$PENDING_DIR"/*.json >/dev/null 2>&1; then exit 0; fi
      if [ -n "$timeout" ] && [ "$elapsed" -ge "$timeout" ]; then exit 1; fi
      sleep 1
      elapsed=$((elapsed + 1))
    done
    ;;

  watch-run)
    # Run-scoped wake condition: block until a gate belonging to THIS run opens,
    # or until the run finishes. Gates carry the run_dir the runner was launched
    # with, and the launching session chooses that --run-dir, so matching on it
    # needs no id parsing, no env coupling, and no race at startup.
    #   exit 0 + gate id  a pending gate for this run
    #   exit 3            the run finished (journal.jsonl has run-done)
    #   exit 1            --timeout elapsed
    run_dir="${1:-}"
    [ -n "$run_dir" ] || die "usage: watch-run <run-dir> [--timeout secs]"
    case "$run_dir" in -*) die "usage: watch-run <run-dir> [--timeout secs]" ;; esac
    shift
    timeout=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --timeout) [ $# -ge 2 ] || die "--timeout needs a value"; timeout="$2"; shift 2 ;;
        *) die "unknown flag: $1" ;;
      esac
    done
    if [ -n "$timeout" ]; then
      case "$timeout" in
        (*[!0-9]*|'') die "--timeout must be a whole number of seconds" ;;
      esac
    fi
    elapsed=0
    while :; do
      # Gate check first: a gate that opened just before the run ended must
      # still be surfaced rather than swallowed by the run-done exit.
      hit="$(PENDING_DIR="$PENDING_DIR" RUN_DIR="$run_dir" node -e '
        const fs = require("fs"), path = require("path");
        const pendingDir = process.env.PENDING_DIR;
        const want = path.resolve(process.env.RUN_DIR);
        let files = [];
        try { files = fs.readdirSync(pendingDir).filter((f) => f.endsWith(".json")); } catch { process.exit(0); }
        files.sort();
        for (const f of files) {
          try {
            const g = JSON.parse(fs.readFileSync(path.join(pendingDir, f), "utf8"));
            if (g.run_dir && path.resolve(g.run_dir) === want) { console.log(g.id || f.slice(0, -5)); break; }
          } catch { /* half-written or malformed — try the next one */ }
        }
      ' 2>/dev/null)"
      if [ -n "$hit" ]; then printf '%s\n' "$hit"; exit 0; fi
      if [ -f "$run_dir/journal.jsonl" ] && grep -q '"event":"run-done"' "$run_dir/journal.jsonl" 2>/dev/null; then
        exit 3
      fi
      if [ -n "$timeout" ] && [ "$elapsed" -ge "$timeout" ]; then exit 1; fi
      sleep 1
      elapsed=$((elapsed + 1))
    done
    ;;

  clear)
    id="${1:-}"
    [ -n "$id" ] || die "usage: clear <id>"
    require_gate_id "$id"
    rm -f "$PENDING_DIR/$id.json" "$ANSWERED_DIR/$id.json"
    echo "cleared $id"
    ;;

  -h|--help|help)
    usage 0
    ;;

  *)
    die "unknown command: $cmd (list | show | answer | wait-pending | watch-run | clear)"
    ;;
esac
