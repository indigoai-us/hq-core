#!/usr/bin/env bash
# hq-core: public
# pipeline-conductor.sh - deterministic helpers for the pipeline-conductor
# worker (/run-project --pipeline). The conductor owns a story queue and routes
# each phase of each story to an hq-cli loop lane. It never spawns a child
# agent: every phase runs in a lane the loop controller owns.
#
# Usage (every subcommand takes --state <dir>; most take --prd <prd.json>):
#   next     --prd P --state S [--limit N]       eligible story ids, one per line
#   classify --prd P --state S --story ID [--worktree DIR | --worktree REPO=DIR ...]
#            [--overlay F] [--table T]           write stories/<id>.json (phases, repo,
#                                                 worktree, classified_by); print phases
#   classify --prd P --state S [--overlay F] [--table T]
#                                                 (no --story) check every story that is not
#                                                 passing or skipped, write nothing; prints
#                                                 OK/WARN/ERROR lines, exit 1 on any ERROR
#   overlay  set --state S --story ID --sequence a,b,c | overlay show --state S
#                                                 the run's classification overlay
#                                                 (<state>/overlay.json); the prd is not edited
#   skip     --state S --story ID [--note TEXT] [--force] [--prd P]
#   unskip   --state S --story ID               leave a story out of the run (skips.json)
#   worktree --state S --repo R --shared [--prd P] [--story ID] [--story-branches]
#            [--worktree DIR | --worktree R=DIR] [--allow-repos-worktree]
#                                                 cut the run's worktree for repo R: one per
#                                                 repo on the run's feature branch (default),
#                                                 or one per story with --story-branches.
#                                                 Default target, every mode:
#                                                 <HQ>/workspace/worktrees/<project>/<repo-name>/
#                                                 (<repo-name>-<story> with --story-branches)
#   worktree --state S --repo R [--prd P]        without --shared: with --prd, the same cut
#                                                 at the default target; without it, the repo
#                                                 itself (refused under repos/, see below)
#   route    --prd P --state S --story ID         queue the story's current phase
#   accept   --state S --story ID --handoff F     record a phase handoff and advance
#   recheck  --prd P --state S --story ID         re-read literal ACs against ac_evidence
#   gate     tick|status --state S
#   gate     result --state S pass|fail [--note TEXT]
#   release  --state S (--story ID [--worker W] | --worker W)
#                                                 resolve an approval decision item
#   report   story --state S --story ID | report final --state S
#   tick     --prd P --state S [--worktree DIR | --worktree REPO=DIR ...] [--story-branches]
#            [--table T]                         (the confirmed worker table; recorded in run.json)
#                                                 one routing pass over the queue
#   go       --state S --story ID [--note TEXT]   release a story held awaiting_go
#   interrupt --state S [--story ID] [--note TEXT] mark every (or one) in_flight story interrupted (phase,
#                                                 time) and withdraw its envelope from the lane
#                                                 queue when no lane picked it up; prints
#                                                 INTERRUPTED <id> <phase> withdrawn|picked_up
#   stop     --state S [--note TEXT]              ask the run's driver to stop (driver/stop.json);
#                                                 with no live driver, runs interrupt itself
#
# Run worktrees under repos/: the core Write/Edit guard blocks editor-tool writes
#   under <HQ>/repos/, so a lane that edits with Write or Edit stalls there. An
#   explicit --worktree (any command) that resolves under repos/ is refused
#   (exit 2) unless --allow-repos-worktree is passed; with it, every phase
#   envelope routed into that tree carries one constraint line telling the worker
#   to edit through the shell or apply_patch. A worktree must still sit inside
#   the HQ root for lanes to cd into it.
#
# Owner resolutions (the parent runs these after the owner answers; the
# conductor and the driver never apply one on their own):
#   resolve  --state S --story ID --as accepted-partial --note TEXT [--prd P]
#                                                 accept a blocked story as a partial
#                                                 draft; dependents may route; passes
#                                                 is never set for it
#   resolve  --state S --story ID --as retry [--note TEXT] [--prd P]
#                                                 route the blocked phase again as a
#                                                 fresh call; the note reaches the worker;
#                                                 re-reads the story's phases from the prd
#                                                 (P, else the prd run.json records), resumes
#                                                 at the first phase without a passed handoff,
#                                                 and starts the failed-attempt count over
#   failcap  --state S --story ID                 the current phase returned failed too often:
#                                                 hold the story as blocked_needs_owner and write
#                                                 decisions/<id>-blocked-<phase>.md with each
#                                                 failed handoff's text (exit 10)
#   park     --state S --story ID [--note TEXT] [--prd P] [--force]
#                                                 set the story aside; every story that
#                                                 depends on it is held as parked_dependency.
#                                                 Prints PARK_CLOSURE <id> <n>: <ids> first; more
#                                                 than PC_PARK_CONFIRM (default 5) dependents
#                                                 needs --force
#   unpark   --state S --story ID [--prd P]       reverse park; prints UNPARK_RELEASES <id> <n>: <ids>
# park, unpark, skip and unskip each append a line to <state>/decisions.log.
#   reopen   --state S --story ID --note TEXT [--from-phase PHASE] [--prd P]
#                                                 send a verified or accepted_partial story
#                                                 back: queued at PHASE (default: the first
#                                                 phase whose worker is not a reviewer or
#                                                 tester), handoffs from PHASE on archived as
#                                                 handoffs/<id>-<phase>.reopened.<n>.json, the
#                                                 attempt count starts over, the note reaches
#                                                 the worker in the envelope. Clears passes:true
#                                                 in the prd. Verified dependents are not
#                                                 reopened; the final summary lists them.
#   gate     result --state S fail --story ID --note TEXT [--from-phase PHASE] [--prd P]
#                                                 record a failed gate that names the story that
#                                                 caused it: reopen that story (as above) and set
#                                                 the gate to `reopened`, so routing goes on and
#                                                 the reopened story routes first; the gate is due
#                                                 again once every reopened story verifies
# Each refuses a story in a state it does not apply to (exit 1) and is
# idempotent: repeating it prints ALREADY and exits 0.
#
# State dir layout:
#   stories/<id>.json        phases, current index, state, reroutes, worktree
#   envelopes/<id>-<phase>.json   envelopes queued to hq lanes
#   handoffs/<id>-<phase>.json    accepted phase handoffs
#   decisions/<id>-<worker>.md    approval items for the parent session
#   decisions/<id>-blocked-<phase>.md  a worker returned status blocked
#   run.json                 the prd path the last tick used (for park and report)
#   approvals.json           workers released for the whole run / per story
#   gate.json                regression gate cadence and state
#   report.md                one line per finished story + one final summary
#
# Classification (classify, and tick when a story first starts): the story's worker
#   sequence is its full phase sequence, in order: the overlay entry, else
#   worker_preference, else the keyword fallback (classified_by records which).
#   classify refuses (exit 1, every problem listed) when:
#   - a worker id has no worker.yaml under PC_WORKERS_ROOT (the message names the
#     roots and the nearest known ids);
#   - a story that declares code files (anything but docs/, markdown, text, yaml)
#     starts with a verifier or reader (is_implementer below reads worker.role,
#     else worker.type, from worker.yaml); prepend an implementer or set
#     "docs_only": true;
#   - a run with a worker table (--table, recorded by tick in run.json) has a
#     sequence worker with no row in it.
#   It warns (stderr, once per story) on a one-worker sequence, on a model_hint
#   (a table pin wins: "hint ignored, table pins <model>"; a bare alias opus,
#   sonnet, haiku or fable is never used), and on the dependency lint (dep_lint).
#   route prints NO_LANE <id> <phase> <worker> and exits 12 when the current
#   phase's worker has no table row; the story stays queued.
#
# Skip list: a skipped story (<state>/skips.json, stories/<id>.json state skipped)
#   is not selected, routed, gated or counted; FINAL lists it with its note.
#   Skipping a story others depend on prints SKIP_STRANDS and needs --force.
#
# Repo per story: classify resolves each story's repo, in this order:
#   1. the story's `repoPath`;
#   2. when the prd lists more than one repo, the repo that owns the story's first
#      declared file (`files[0]`): an absolute path under the repo, a path from
#      the HQ root, a path that starts with the repo's directory name, or a path
#      that exists inside exactly one repo. The repo list is `metadata.repos[]`
#      (canonical; each entry a path string or an object with `path` or
#      `repoPath`); `metadata.repoPaths[]` (path strings) is read as an alias;
#   3. `metadata.repoPath`.
#   Relative repo paths are read from the HQ root. stories/<id>.json records
#   the resolved `repo`. `tick --worktree <repo>=<worktree>` (repeatable) maps
#   each repo to its worktree and every phase of a story goes to the worktree of
#   its repo; the bare `--worktree <dir>` form serves a prd with at most one
#   repo. A story whose repo has no worktree is held blocked_needs_owner with a
#   decision item naming the repo; it is never routed to another repo's tree.
#   The envelope carries `repo`, `worktree` and, for a git worktree, `branch`.
#
# Branches: `metadata.baseBranch` (default main) is the base. Every cut starts
#   from origin/<baseBranch> when that ref exists after `git fetch origin
#   <baseBranch>`, else from local <baseBranch>, never from the repo's HEAD; the
#   exact ref is printed (CUT <branch> from <ref> <sha>). Neither ref: exit 1.
#   Default mode: one feature branch per repo for the run (`metadata.branchName`,
#   else feature/<project>) in one worktree per repo; every story of that repo
#   commits on it in dependency order, one story in flight per repo branch.
#   `--story-branches` (tick and worktree): one branch and worktree per story
#   (pipeline/<id>), cut when the story first routes from the branch of the last
#   verified story it depends on in the same repo (stacked), else from the base.
#   A story whose dependency branch is missing is held blocked_needs_owner.
#
# Concurrency: in the default mode PC_MAX_STORIES is lowered to the number of
#   worktrees in play (one story per repo branch at a time) and tick prints
#   MAX_STORIES <n> with the reason when it lowers it.
#
# Story-level go: a story with `approval: "explicit"` (canonical; the alias
#   `needsApproval: true` is read too), or one the release detector flags (its
#   declared files or acceptance criteria mention deploy, release, production,
#   or merging to the base branch; patterns in RELEASE_PATTERNS below), is held
#   awaiting_go before its first implementing phase, whatever the worker's
#   approval_required says, with decisions/<id>-go.md. Only `go` releases it;
#   `release --worker` (whole-run approval) does not. resolve and park apply.
#
# Story states: queued, in_flight, held, awaiting_go, awaiting_recheck, verified, failed_report,
#   blocked_needs_owner (a phase handoff said blocked; never retried on its own),
#   accepted_partial (owner accepted a blocked story as a partial draft; counts as
#   done for dependsOn, passes is never set), parked (owner set it aside),
#   parked_dependency (depends, directly or not, on a parked story).
# A reopened story is queued again with a `reopen` record (note, phase, the
#   verified dependents at the time); report.md drops its earlier line.
#
# Back-pressure hint: when a story's `files` include a data store or schema path
#   (contains store, schema, migration or db/), every envelope of that story
#   carries a constraint asking the worker to run the repo's schema-contract
#   tests, if present.
#
# A handoff with status `failed` re-queues the phase (the driver allows one
# route-back). A handoff with status `blocked` holds the story as
# blocked_needs_owner and writes one decision item: a rerun cannot help.
# A state dir from the previous version (a queued story whose newest archived
# handoff, handoffs/<id>-<phase>.failed.<n>.json, says blocked) is read as
# blocked_needs_owner, so resolve works on it without hand edits.
#
# Exit codes: 0 ok; 1 refused or failed; 2 usage; 3 lane capacity/admission (retry next tick);
#   10 held for a parent decision (approval hold, or a blocked handoff on accept);
#   11 lane down: `hq lanes enqueue` returned `loop_not_running` or a terminal
#      lane state. The worker mapping is dropped, the story stays queued, and
#      route prints LANE_DOWN <id> <phase> <worker> ...; tick stops there.
#   12 no lane: the phase's worker has no row in the run's worker table (NO_LANE);
#      tick stops there.
#
# Env: PC_HQ (default hq), PC_ENVELOPE (default
#   core/scripts/pipeline-envelope.sh), PC_WORKERS_ROOT (colon-separated worker
#   roots, default below), PC_GATE_EVERY (default 3,
#   the /run-project regression cadence), PC_NOW (epoch seconds, for tests),
#   PC_DEADLINE_MIN (default 120), PC_MAX_STORIES (default 3), PC_HQ_ROOT,
#   PC_PARK_CONFIRM (default 5). PC_WORKERS_ROOT defaults to core/workers, every
#   companies/*/workers and personal/workers.
#
# The conductor never writes `passes` into prd.json. A verified story is
# reported; the parent session decides what to record.
#
# bash 3.2 portable; JSON and YAML work is done by node.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PC_HQ_ROOT="${PC_HQ_ROOT:-$(cd "$HERE/../.." && pwd)}"
export PC_HQ_ROOT
export PC_HQ="${PC_HQ:-hq}"
export PC_ENVELOPE="${PC_ENVELOPE:-$HERE/pipeline-envelope.sh}"
if [ -z "${PC_WORKERS_ROOT:-}" ]; then
  PC_WORKERS_ROOT="$PC_HQ_ROOT/core/workers"
  for d in "$PC_HQ_ROOT"/companies/*/workers; do [ -d "$d" ] && PC_WORKERS_ROOT="$PC_WORKERS_ROOT:$d"; done
  PC_WORKERS_ROOT="$PC_WORKERS_ROOT:$PC_HQ_ROOT/personal/workers"
fi
export PC_WORKERS_ROOT
export PC_GATE_EVERY="${PC_GATE_EVERY:-3}"
export PC_DEADLINE_MIN="${PC_DEADLINE_MIN:-120}"
export PC_MAX_STORIES="${PC_MAX_STORIES:-3}"

usage() { sed -n '3,/^# bash 3.2 portable/p' "${BASH_SOURCE[0]}" >&2; exit 2; }
die() { echo "pipeline-conductor: $*" >&2; exit "${2:-1}"; }

command -v node >/dev/null 2>&1 || die "node required" 2
[ $# -ge 1 ] || usage
CMD="$1"; shift
SUB=""
case "$CMD" in
  gate|report|overlay) [ $# -ge 1 ] || usage; SUB="$1"; shift ;;
  -h|--help) usage ;;
esac

PRD=""; STATE=""; STORY=""; HANDOFF=""; REPO=""; SHARED=0; WORKER=""; WT=""; LIMIT=""; NOTE=""; RESULT=""; AS=""; NOTE_SET=0; FROM_PHASE=""
STORY_BRANCHES=0; OVERLAY=""; TABLE=""; SEQUENCE=""; FORCE=0; ALLOW_REPOS=0
NL='
'
while [ $# -gt 0 ]; do
  case "$1" in
    --prd|--state|--story|--handoff|--repo|--worker|--worktree|--limit|--note|--as|--from-phase|--overlay|--table|--sequence)
      [ $# -ge 2 ] || die "$1 needs a value" 2 ;;
  esac
  case "$1" in
    --prd) PRD="${2:-}"; shift 2 ;;
    --state) STATE="${2:-}"; shift 2 ;;
    --story) STORY="${2:-}"; shift 2 ;;
    --handoff) HANDOFF="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --shared) SHARED=1; shift ;;
    --worker) WORKER="${2:-}"; shift 2 ;;
    --worktree) WT="${WT:+$WT$NL}${2:-}"; shift 2 ;;
    --story-branches) STORY_BRANCHES=1; shift ;;
    --limit) LIMIT="${2:-}"; shift 2 ;;
    --note) NOTE="${2:-}"; NOTE_SET=1; shift 2 ;;
    --as) AS="${2:-}"; shift 2 ;;
    --from-phase) FROM_PHASE="${2:-}"; shift 2 ;;
    --overlay) OVERLAY="${2:-}"; shift 2 ;;
    --table) TABLE="${2:-}"; shift 2 ;;
    --sequence) SEQUENCE="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --allow-repos-worktree) ALLOW_REPOS=1; shift ;;
    pass|fail) RESULT="$1"; shift ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done
[ -n "$STATE" ] || die "--state <dir> is required" 2
case "$STORY" in */*|.*) die "unsafe story id: $STORY" 2 ;; esac
case "$LIMIT" in ""|*[!0-9]*) [ -z "$LIMIT" ] || die "--limit must be a non-negative integer" 2 ;; esac
mkdir -p "$STATE/stories" "$STATE/envelopes" "$STATE/handoffs" "$STATE/decisions" || die "cannot create state dir $STATE"

export PC_SELF_DIR="$HERE" PC_CMD="$CMD" PC_SUB="$SUB" PC_PRD="$PRD" PC_STATE="$STATE" PC_STORY="$STORY" \
  PC_HANDOFF="$HANDOFF" PC_WORKER="$WORKER" PC_WT="$WT" PC_LIMIT="$LIMIT" PC_NOTE="$NOTE" PC_RESULT="$RESULT" \
  PC_AS="$AS" PC_NOTE_SET="$NOTE_SET" PC_FROM_PHASE="$FROM_PHASE" PC_REPO="$REPO" PC_SHARED="$SHARED" \
  PC_STORY_BRANCHES="$STORY_BRANCHES" PC_OVERLAY="$OVERLAY" PC_TABLE="$TABLE" PC_SEQUENCE="$SEQUENCE" PC_FORCE="$FORCE" \
  PC_ALLOW_REPOS="$ALLOW_REPOS"

node - <<'JS'
"use strict";
const fs = require("fs"), cp = require("child_process"), osm = require("os");

const E = process.env;
const CMD = E.PC_CMD, SUB = E.PC_SUB, STATE = E.PC_STATE;
const PRD = E.PC_PRD, STORY = E.PC_STORY;

// ---------- runtime helpers (stdout is buffered until exit, stderr is written at once) ----------
const OUTBUF = [];
function writeAll(fd, s) {
  const b = Buffer.from(s, "utf8"); let off = 0;
  while (off < b.length) {
    try { off += fs.writeSync(fd, b, off, b.length - off); }
    catch (e) { if (e.code !== "EAGAIN") throw e; }
  }
}
function flushOut() { if (OUTBUF.length) { const s = OUTBUF.join(""); OUTBUF.length = 0; writeAll(1, s); } }
function print(s) { OUTBUF.push(s + "\n"); }
function owrite(s) { OUTBUF.push(s); }
function eprint(s) { writeAll(2, s + "\n"); }
function exit(rc) { flushOut(); process.exit(rc); }
function die(msg, rc) { eprint("pipeline-conductor: " + msg); exit(rc === undefined ? 1 : rc); }

function T(x) {
  if (x === null || x === undefined || x === false || x === 0 || x === "") return false;
  if (Array.isArray(x)) return x.length > 0;
  if (typeof x === "object") return Object.keys(x).length > 0;
  return true;
}
function or(x, y) { return T(x) ? x : y; }
function isDict(x) { return x !== null && typeof x === "object" && !Array.isArray(x); }
function isInt(x) { return typeof x === "boolean" || (typeof x === "number" && Number.isInteger(x)); }
function isNum(x) { return typeof x === "boolean" || typeof x === "number"; }
function num(x) { return typeof x === "boolean" ? (x ? 1 : 0) : x; }
function get(d, k, dflt) { return isDict(d) && Object.prototype.hasOwnProperty.call(d, k) ? d[k] : dflt; }
function has(d, k) { return isDict(d) && Object.prototype.hasOwnProperty.call(d, k); }
function pop(d, k, dflt) { if (has(d, k)) { const v = d[k]; delete d[k]; return v; } return dflt; }
function setdefault(d, k, v) { if (!has(d, k)) d[k] = v; return d[k]; }
function eq(a, b) { return JSON.stringify(a) === JSON.stringify(b); }
function pyInt(x) {
  if (typeof x === "boolean") return x ? 1 : 0;
  if (typeof x === "number") { if (!isFinite(x)) throw new Error("cannot convert float to integer"); return Math.trunc(x); }
  if (typeof x === "string" && /^\s*[+-]?\d+(_\d+)*\s*$/.test(x)) return parseInt(x.replace(/_/g, "").trim(), 10);
  throw new Error("invalid literal for int(): " + pyRepr(x));
}
function pyNum(x) {
  if (Number.isInteger(x)) return String(x);
  let s = String(x);
  s = s.replace(/e([+-])(\d)$/, "e$10$2");
  return s;
}
function pyStrRepr(s) {
  const q = (s.indexOf("'") >= 0 && s.indexOf('"') < 0) ? '"' : "'";
  let out = q;
  for (const ch of s) {
    const c = ch.codePointAt(0);
    if (ch === "\\") out += "\\\\";
    else if (ch === q) out += "\\" + q;
    else if (ch === "\n") out += "\\n";
    else if (ch === "\r") out += "\\r";
    else if (ch === "\t") out += "\\t";
    else if (c < 0x20 || c === 0x7f) out += "\\x" + c.toString(16).padStart(2, "0");
    else out += ch;
  }
  return out + q;
}
function pyRepr(x) {
  if (typeof x === "string") return pyStrRepr(x);
  if (Array.isArray(x)) return "[" + x.map(pyRepr).join(", ") + "]";
  if (isDict(x)) return "{" + Object.keys(x).map(k => pyStrRepr(k) + ": " + pyRepr(x[k])).join(", ") + "}";
  return S(x);
}
function S(x) {
  if (x === null || x === undefined) return "None";
  if (x === true) return "True";
  if (x === false) return "False";
  if (typeof x === "number") return pyNum(x);
  if (typeof x === "string") return x;
  return pyRepr(x);
}
function words(s) { return String(s).split(/\s+/).filter(Boolean); }
function wsjoin(x) { return words(S(x)).join(" "); }
function splitlines(s) {
  const parts = s.split(/\r\n|[\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029]/);
  if (parts.length && parts[parts.length - 1] === "") parts.pop();
  return parts;
}
function strip(s) { return s.replace(/^\s+|\s+$/g, ""); }
function lstripChars(s, chars) { let i = 0; while (i < s.length && chars.indexOf(s[i]) >= 0) i++; return s.slice(i); }
function stripChars(s, chars) {
  let i = 0, j = s.length;
  while (i < j && chars.indexOf(s[i]) >= 0) i++;
  while (j > i && chars.indexOf(s[j - 1]) >= 0) j--;
  return s.slice(i, j);
}
function reEscape(s) { return String(s).replace(/[()[\]{}?*+\-|^$\\.&~# \t\n\r\v\f]/g, "\\$&"); }
function cmpStr(a, b) { return a < b ? -1 : a > b ? 1 : 0; }
function sortedStr(a) { return Array.from(a).sort(cmpStr); }
function uniq(a) { return Array.from(new Set(a)); }
function pyDumps(v, ascii) {
  // json.dumps default separators (", ", ": "), optional ensure_ascii escaping
  const str = (s) => {
    let o = '"';
    for (let i = 0; i < s.length; i++) {
      const ch = s[i], c = s.charCodeAt(i);
      if (ch === '"') o += '\\"';
      else if (ch === "\\") o += "\\\\";
      else if (ch === "\n") o += "\\n";
      else if (ch === "\r") o += "\\r";
      else if (ch === "\t") o += "\\t";
      else if (ch === "\b") o += "\\b";
      else if (ch === "\f") o += "\\f";
      else if (c < 0x20 || (ascii && c > 0x7e)) o += "\\u" + c.toString(16).padStart(4, "0");
      else o += ch;
    }
    return o + '"';
  };
  const go = (x) => {
    if (x === null || x === undefined) return "null";
    if (x === true) return "true";
    if (x === false) return "false";
    if (typeof x === "number") return Number.isInteger(x) ? String(x) : pyNum(x);
    if (typeof x === "string") return str(x);
    if (Array.isArray(x)) return "[" + x.map(go).join(", ") + "]";
    return "{" + Object.keys(x).map(k => str(k) + ": " + go(x[k])).join(", ") + "}";
  };
  return go(v);
}

// ---------- path helpers (posixpath semantics) ----------
function isabs(p) { return p.startsWith("/"); }
function pjoin(a, ...rest) {
  let path = a;
  for (const b of rest) {
    if (b.startsWith("/")) path = b;
    else if (!path || path.endsWith("/")) path += b;
    else path += "/" + b;
  }
  return path;
}
function basename(p) { return p.slice(p.lastIndexOf("/") + 1); }
function dirname(p) {
  let head = p.slice(0, p.lastIndexOf("/") + 1);
  if (head && head !== "/".repeat(head.length)) head = head.replace(/\/+$/, "");
  return head;
}
function psplit(p) {
  const i = p.lastIndexOf("/") + 1;
  let head = p.slice(0, i); const tail = p.slice(i);
  if (head && head !== "/".repeat(head.length)) head = head.replace(/\/+$/, "");
  return [head, tail];
}
function normpath(p) {
  if (p === "") return ".";
  let initial = p.startsWith("/") ? 1 : 0;
  if (initial && p.startsWith("//") && !p.startsWith("///")) initial = 2;
  const comps = p.split("/"), out = [];
  for (const c of comps) {
    if (c === "" || c === ".") continue;
    if (c !== ".." || (!initial && !out.length) || (out.length && out[out.length - 1] === "..")) out.push(c);
    else if (out.length) out.pop();
  }
  const s = "/".repeat(initial) + out.join("/");
  return s || ".";
}
function abspath(p) { p = String(p); if (!isabs(p)) p = pjoin(process.cwd(), p); return normpath(p); }
function expanduser(p) {
  if (!p.startsWith("~")) return p;
  let i = p.indexOf("/", 1); if (i < 0) i = p.length;
  if (i !== 1) return p;
  const home = E.HOME || osm.homedir();
  let r = home.replace(/\/+$/, "") + p.slice(i);
  return r || "/";
}
function lstatOk(p) { try { return fs.lstatSync(p); } catch (e) { return null; } }
function realpath(filename) {
  const seen = new Map();
  function jr(path, rest) {
    if (isabs(rest)) { rest = rest.slice(1); path = "/"; }
    while (rest) {
      let name; const i = rest.indexOf("/");
      if (i < 0) { name = rest; rest = ""; } else { name = rest.slice(0, i); rest = rest.slice(i + 1); }
      if (!name || name === ".") continue;
      if (name === "..") {
        if (path) {
          let nm; [path, nm] = psplit(path);
          if (nm === "..") path = pjoin(path, "..", "..");
        } else path = "..";
        continue;
      }
      const newpath = pjoin(path, name);
      const st = lstatOk(newpath);
      if (!st || !st.isSymbolicLink()) { path = newpath; continue; }
      if (seen.has(newpath)) {
        path = seen.get(newpath);
        if (path !== null) continue;
        return [pjoin(newpath, rest), false];
      }
      seen.set(newpath, null);
      let ok; [path, ok] = jr(path, fs.readlinkSync(newpath));
      if (!ok) return [pjoin(path, rest), false];
      seen.set(newpath, path);
    }
    return [path, true];
  }
  return abspath(jr("", String(filename))[0]);
}
function exists(p) { try { fs.statSync(p); return true; } catch (e) { return false; } }
function isdir(p) { try { return fs.statSync(p).isDirectory(); } catch (e) { return false; } }
function islink(p) { const s = lstatOk(p); return !!s && s.isSymbolicLink(); }
function readText(p) { return fs.readFileSync(p, "utf8"); }
function writeText(p, s) { fs.writeFileSync(p, s, "utf8"); }
function listdir(p) { return fs.readdirSync(p); }
function* walk(top) {
  let ents;
  try { ents = fs.readdirSync(top, { withFileTypes: true }); } catch (e) { return; }
  const dirs = [], files = [];
  for (const e of ents) {
    let d = false;
    try { d = e.isDirectory() || (e.isSymbolicLink() && fs.statSync(pjoin(top, e.name)).isDirectory()); } catch (x) { d = false; }
    (d ? dirs : files).push(e.name);
  }
  const ent = [top, dirs, files];
  yield ent;
  for (const d of ent[1]) {
    const np = pjoin(top, d);
    if (!islink(np)) yield* walk(np);
  }
}

// ---------- subprocess ----------
function run(cmd, args, opts) {
  opts = opts || {};
  const r = cp.spawnSync(cmd, args, { encoding: "utf8", maxBuffer: 1 << 30, stdio: ["inherit", "pipe", "pipe"],
                                      timeout: opts.timeout });
  if (r.error) throw r.error;
  let rc = r.status;
  if (rc === null) rc = -((osm.constants.signals || {})[r.signal] || 1);
  return { returncode: rc, stdout: r.stdout || "", stderr: r.stderr || "" };
}

function jload(p, dflt) {
  if (dflt === undefined) dflt = null;
  try { return JSON.parse(readText(p)); } catch (e) { return dflt; }
}

function jsave(p, d) {
  const tmp = p + ".tmp";
  writeText(tmp, JSON.stringify(d, null, 1));
  fs.renameSync(tmp, p);
}

function sp(...parts) { return pjoin(STATE, ...parts); }

function now() {
  const v = E.PC_NOW;
  if (v) return pyInt(v);
  return Math.floor(Date.now() / 1000);
}

function iso(t) { return new Date(t * 1000).toISOString().replace(/\.\d+Z$/, "Z"); }

function prd() {
  if (!PRD) die("--prd is required", 2);
  const d = jload(PRD);
  if (!isDict(d) || !Array.isArray(d.userStories)) die("not a prd: " + PRD);
  return d;
}

function prd_opt() {
  // The prd from --prd, else the one the last tick recorded in run.json, else null.
  const path = PRD || get(or(jload(sp("run.json"), {}), {}), "prd");
  const d = T(path) ? jload(path) : null;
  return isDict(d) && Array.isArray(d.userStories) ? d : null;
}

function story_of(p, sid) {
  for (const s of p.userStories) if (get(s, "id") === sid) return s;
  die("story not in prd: " + S(sid));
}

function sfile(sid) { return sp("stories", sid + ".json"); }

function sload(sid) {
  const d = jload(sfile(sid));
  if (d === null) die("story " + sid + " not classified (no " + sfile(sid) + ")");
  return migrate_legacy(d);
}

// ---------- blocked handoffs ----------
const DONE_STATES = ["verified", "accepted_partial"];

function archives(sid, phase) {
  // Archived handoffs of one phase, oldest first: [[n, path]].
  const pre = sid + "-" + phase + ".failed.";
  const out = [];
  for (const n of listdir(sp("handoffs"))) {
    if (n.startsWith(pre) && n.endsWith(".json") && n.length >= pre.length + 5 && /^[0-9]+$/.test(n.slice(pre.length, -5)))
      out.push([parseInt(n.slice(pre.length, -5), 10), sp("handoffs", n)]);
  }
  return out.sort((a, b) => a[0] - b[0] || cmpStr(a[1], b[1]));
}

function archive_handoff(sid, phase) {
  const h = sp("handoffs", sid + "-" + phase + ".json");
  if (!exists(h)) return null;
  let n = 1;
  while (exists(sp("handoffs", sid + "-" + phase + ".failed." + n + ".json"))) n += 1;
  const dst = sp("handoffs", sid + "-" + phase + ".failed." + n + ".json");
  fs.renameSync(h, dst);
  return dst;
}

function blocker_text(h) {
  const parts = ["summary", "notes"].filter(k => typeof get(h, k) === "string" && strip(h[k])).map(k => strip(h[k]));
  return parts.join("\n\n") || "(the worker gave no reason)";
}

function decision_path(sid, phase) { return sp("decisions", S(sid) + "-blocked-" + S(phase) + ".md"); }

function hold_blocked(st, h, hpath) {
  const sid = st.id; const ph = st.phases[st.current];
  const attempts = archives(sid, ph.phase).length + (exists(sp("handoffs", sid + "-" + ph.phase + ".json")) ? 1 : 0);
  const text = blocker_text(h);
  st.state = "blocked_needs_owner";
  st.blocked = { phase: ph.phase, worker: ph.worker, handoff: abspath(hpath), text: text, at: iso(now()), attempts: attempts };
  pop(st, "owner_retry");
  const dp = decision_path(sid, ph.phase);
  writeText(dp,
    "# Decision: " + S(sid) + " is blocked at its " + S(ph.phase) + " phase\n\n" +
    "- story: " + S(sid) + " (" + S(get(st, "title", "")) + ")\n- phase: " + S(ph.phase) + "\n- lane: " + S(ph.worker) +
    "\n- attempts so far: " + attempts + "\n- handoff: " + abspath(hpath) + "\n- status: pending\n\n" +
    "## What the worker said\n\n" + text + "\n\n" +
    "## Resolutions (run one after the owner answers, then restart the driver)\n\n" +
    "- Accept as a partial draft (dependents may start; passes is not set):\n" +
    "  pipeline-conductor.sh resolve --state " + STATE + " --story " + S(sid) + " --as accepted-partial --note \"<owner's reason>\"\n" +
    "- Run the phase again with the owner's answer:\n" +
    "  pipeline-conductor.sh resolve --state " + STATE + " --story " + S(sid) + " --as retry --note \"<owner's answer>\"\n" +
    "- Set the story and its dependents aside:\n" +
    "  pipeline-conductor.sh park --state " + STATE + " --story " + S(sid) + " --note \"<why>\"\n");
  jsave(sfile(sid), st);
  return dp;
}

function migrate_legacy(st) {
  // A previous-version state dir re-queued a blocked phase and archived its handoffs.
  // Read such a story as blocked_needs_owner. blocked_ack counts archives the owner already answered.
  if (get(st, "state") !== "queued" || !T(get(st, "started"))) return st;
  const phases = or(get(st, "phases"), []); const cur = get(st, "current", 0);
  if (!(isInt(cur) && 0 <= num(cur) && num(cur) < phases.length)) return st;
  const phase = phases[num(cur)].phase;
  if (exists(sp("handoffs", st.id + "-" + phase + ".json"))) return st;
  const arch = archives(st.id, phase);
  if (arch.length <= pyInt(get(st, "blocked_ack", 0))) return st;
  const h = or(jload(arch[arch.length - 1][1]), {});
  if (get(h, "status") !== "blocked" || get(h, "phase") !== phase) return st;
  hold_blocked(st, h, arch[arch.length - 1][1]);
  return st;
}

function mark_decision(dp, status) {
  if (exists(dp)) {
    let t = readText(dp);
    t = t.replace(/^- status: .*$/m, () => "- status: " + status);
    writeText(dp, t);
  }
}

function need_story() {
  if (!STORY) die("--story is required", 2);
  return STORY;
}

const PHASE = { "architect": "architect", "backend-dev": "backend", "frontend-dev": "frontend",
                "database-dev": "database", "qa-tester": "qa", "motion-designer": "motion" };
function phaseOf(w) { return has(PHASE, w) ? PHASE[w] : w; }


// ---------- repos, worktrees, branches ----------
class CutError extends Error {}

function real(path) {
  // Absolute, symlink-free path; a relative path is read from the HQ root.
  path = expanduser(strip(S(path)));
  if (!isabs(path)) path = pjoin(E.PC_HQ_ROOT, path);
  return realpath(path);
}

function listed_repos(p) {
  // metadata.repos[] (canonical: path strings or objects with path/repoPath) plus the alias metadata.repoPaths[].
  const md = or(get(p, "metadata"), {});
  const out = [];
  for (const key of ["repos", "repoPaths"]) {
    for (let r of or(get(md, key), [])) {
      if (isDict(r)) r = or(get(r, "path"), get(r, "repoPath"));
      if (typeof r === "string" && strip(r) && !out.includes(real(r))) out.push(real(r));
    }
  }
  return out;
}

function all_repos(p) {
  const out = listed_repos(p).slice();
  const md = or(get(p, "metadata"), {});
  for (const r of [get(md, "repoPath")].concat(p.userStories.map(s => get(s, "repoPath")))) {
    if (typeof r === "string" && strip(r) && !out.includes(real(r))) out.push(real(r));
  }
  return out;
}

function multi_repo(p) { return all_repos(p).length > 1; }

function under(path, root) { return path === root || path.startsWith(root.replace(/\/+$/, "") + "/"); }

function file_owner(f, repos) {
  // The repo that owns a declared file path, or null.
  f = expanduser(strip(f));
  const tiers = [];
  if (isabs(f)) {
    tiers.push(repos.filter(r => under(realpath(f), r)));
  } else {
    tiers.push(repos.filter(r => under(realpath(pjoin(E.PC_HQ_ROOT, f)), r)));
    const head = lstripChars(f.replace(/\\/g, "/"), "./").split("/")[0];
    tiers.push(repos.filter(r => basename(r) === head));
    tiers.push(repos.filter(r => exists(pjoin(r, f))));
  }
  for (const t of tiers) {
    if (t.length === 1) return t[0];
    if (t.length > 1) { let best = t[0]; for (const x of t) if (x.length > best.length) best = x; return best; }
  }
  return null;
}

function resolve_repo(p, s) {
  if (typeof get(s, "repoPath") === "string" && strip(s.repoPath)) return [real(s.repoPath), "story repoPath"];
  const repos = listed_repos(p);
  const files = or(get(s, "files"), []).filter(f => typeof f === "string" && strip(f));
  if (repos.length > 1 && files.length) {
    const o = file_owner(files[0], repos);
    if (o) return [o, "owner of " + files[0]];
  }
  const md = or(get(p, "metadata"), {});
  if (typeof get(md, "repoPath") === "string" && strip(md.repoPath)) return [real(md.repoPath), "metadata.repoPath"];
  if (repos.length === 1) return [repos[0], "metadata.repos"];
  return [null, "none"];
}

const REPOS_WT_LINE = "This worktree is under repos/, where the core Write/Edit guard blocks the editor tools: " +
                      "make every file edit through the shell or apply_patch, never with the Write or Edit tool.";

// The one check for a run worktree under <HQ>/repos/.
function repos_worktree(path, refuse) {
  if (refuse === undefined) refuse = true;
  const hq = realpath(E.PC_HQ_ROOT);
  const r = realpath(abspath(expanduser(S(path))));
  if (!under(r, pjoin(hq, "repos"))) return false;
  if (refuse && E.PC_ALLOW_REPOS !== "1") {
    die("refusing worktree " + S(path) + ": it resolves under " + pjoin(hq, "repos") + "/" + ", where the core Write/Edit guard blocks editor-tool " +
        "writes, so a lane that edits with the Write or Edit tool stalls there. Leave --worktree off to use " +
        "the default " + pjoin(hq, "workspace", "worktrees") + "/<project>/<repo-name>/, or pass --allow-repos-worktree to keep this tree; every phase " +
        "envelope then tells the worker to edit through the shell or apply_patch.", 2);
  }
  return true;
}

function wt_mapping(raw) {
  // --worktree values -> {repo: worktree}; a bare --worktree DIR is stored under "*".
  const m = {};
  for (const e of (raw || "").split("\n")) {
    if (!strip(e)) continue;
    const i = e.indexOf("=");
    if (i >= 0) {
      const r = e.slice(0, i), w = e.slice(i + 1);
      m[real(r)] = abspath(strip(w));
    } else {
      m["*"] = abspath(strip(e));
    }
  }
  for (const w of Object.values(m)) repos_worktree(w);
  return m;
}

function pick_worktree(p, repo, m) {
  if (T(repo) && has(m, repo)) return m[repo];
  if (has(m, "*") && !multi_repo(p)) return m["*"];
  return null;
}

function git(repo, ...args) { return run("git", ["-C", repo].concat(args)); }

function base_branch(p) {
  const b = get(or(get(p, "metadata"), {}), "baseBranch");
  return typeof b === "string" && strip(b) ? strip(b) : "main";
}

function slug(x) { return stripChars(S(x).replace(/[^A-Za-z0-9._-]/gu, "-"), "-") || "x"; }

function feature_branch(p) {
  const b = get(or(get(p, "metadata"), {}), "branchName");
  if (typeof b === "string" && strip(b)) return strip(b);
  return "feature/" + slug(or(or(get(p, "name"), get(p, "project")), "run"));
}

function has_ref(repo, ref) { return git(repo, "rev-parse", "--verify", "--quiet", ref + "^{commit}").returncode === 0; }

function base_ref(repo, base) {
  if (git(repo, "remote", "get-url", "origin").returncode === 0) {
    git(repo, "fetch", "--quiet", "origin", "+refs/heads/" + base + ":refs/remotes/origin/" + base);
    if (has_ref(repo, "refs/remotes/origin/" + base))
      return ["origin/" + base, strip(git(repo, "rev-parse", "refs/remotes/origin/" + base).stdout)];
  }
  if (has_ref(repo, "refs/heads/" + base))
    return [base, strip(git(repo, "rev-parse", "refs/heads/" + base).stdout)];
  throw new CutError("cannot cut a branch in " + repo + ": neither origin/" + base + " nor " + base + " exists (base branch from metadata.baseBranch, " +
                     "default main)");
}

function check_repo(repo) {
  const hq = realpath(E.PC_HQ_ROOT);
  if (under(repo, hq) && !under(repo, pjoin(hq, "repos")))
    throw new CutError("refusing a worktree of a repo inside the HQ root: " + repo);
  if (realpath(strip(git(repo, "rev-parse", "--show-toplevel").stdout) || "/nonexistent") !== repo)
    throw new CutError("not the top of a repository (git rev-parse --show-toplevel): " + repo);
}

function wt_root(p) {
  if (E.PC_WORKTREE_ROOT) return E.PC_WORKTREE_ROOT;
  const pp = or(p, {});
  const proj = or(or(get(pp, "name"), get(pp, "project")), basename(realpath(STATE)));
  return pjoin(realpath(E.PC_HQ_ROOT), "workspace", "worktrees", slug(proj));
}

function explicit_target(repo) {
  const m = wt_mapping(E.PC_WT);
  return or(has(m, repo) ? m[repo] : null, has(m, "*") ? m["*"] : null);
}

function add_worktree(repo, wt, branch, start) {
  fs.mkdirSync(dirname(wt) || ".", { recursive: true });
  let r, line;
  if (has_ref(repo, "refs/heads/" + branch)) {
    r = git(repo, "worktree", "add", wt, branch);
    line = "REUSED " + branch + " (branch exists, not cut again) in " + wt;
  } else {
    const [ref, sha] = start;
    r = git(repo, "worktree", "add", "-b", branch, wt, ref);
    line = "CUT " + branch + " from " + ref + " " + sha.slice(0, 12) + " in " + wt;
  }
  if (r.returncode !== 0) throw new CutError("git worktree add failed for " + wt + " (" + branch + "): " + strip(r.stderr));
  return line;
}

function cut_repo_worktree(p, repo) {
  check_repo(repo);
  const wt = explicit_target(repo) || pjoin(wt_root(p), slug(basename(repo)));
  const branch = feature_branch(p);
  if (isdir(wt))
    return [wt, "EXISTS " + wt + " on " + (strip(git(wt, "rev-parse", "--abbrev-ref", "HEAD").stdout) || "?")];
  const start = has_ref(repo, "refs/heads/" + branch) ? null : base_ref(repo, base_branch(p));
  return [wt, add_worktree(repo, wt, branch, start)];
}

function stacked_on(p, sid, repo, stories) {
  const s = story_of(p, sid); let last = null;
  for (const d of or(get(s, "dependsOn"), [])) {
    const v = or(stories.get(d), {});
    if (DONE_STATES.includes(get(v, "state")) && T(get(v, "branch")) && get(v, "repo") === repo) last = [d, v.branch];
  }
  return last;
}

function cut_story_worktree(p, sid, st, repo) {
  check_repo(repo);
  const wt = explicit_target(repo) || pjoin(wt_root(p), slug(basename(repo)) + "-" + slug(sid));
  const branch = "pipeline/" + slug(sid);
  if (isdir(wt)) return [wt, "EXISTS " + wt + " on " + branch];
  const dep = stacked_on(p, sid, repo, all_stories());
  let start;
  if (dep) {
    if (!has_ref(repo, "refs/heads/" + dep[1]))
      throw new CutError("dependency branch missing: " + S(dep[1]) + " (story " + S(dep[0]) + ") is not in " + repo + "; story " + sid + " stacks on it");
    start = [dep[1], strip(git(repo, "rev-parse", "refs/heads/" + dep[1]).stdout)];
  } else {
    start = base_ref(repo, base_branch(p));
  }
  const line = add_worktree(repo, wt, branch, has_ref(repo, "refs/heads/" + branch) ? null : start);
  st.branch = branch; st.stacked_on = dep ? dep[0] : null;
  return [wt, line];
}

function hold_owner(st, kind, text) {
  const sid = st.id; const ph = st.phases[st.current];
  st.state = "blocked_needs_owner";
  st.blocked = { phase: ph.phase, worker: ph.worker, handoff: null, kind: kind, text: text, at: iso(now()), attempts: 0 };
  pop(st, "owner_retry");
  const dp = decision_path(sid, ph.phase);
  writeText(dp,
    "# Decision: " + S(sid) + " cannot route its " + S(ph.phase) + " phase\n\n" +
    "- story: " + S(sid) + " (" + S(get(st, "title", "")) + ")\n- phase: " + S(ph.phase) + "\n- lane: " + S(ph.worker) +
    "\n- reason: " + kind + "\n- status: pending\n\n" +
    "## What is wrong\n\n" + text + "\n\n" +
    "## Resolutions (run one after the owner answers, then restart the driver)\n\n" +
    "- Fix it (pass the missing --worktree <repo>=<dir> to the driver, or restore the branch), then route again:\n" +
    "  pipeline-conductor.sh resolve --state " + STATE + " --story " + S(sid) + " --as retry --note \"<what changed>\"\n" +
    "- Set the story and its dependents aside:\n" +
    "  pipeline-conductor.sh park --state " + STATE + " --story " + S(sid) + " --note \"<why>\"\n");
  jsave(sfile(sid), st);
  print("BLOCKED_OWNER " + S(sid) + " " + S(ph.phase) + " " + kind + " " + dp);
  exit(10);
}

function route_worktree(p, st) {
  const runj = or(jload(sp("run.json"), {}), {});
  const m = or(get(runj, "worktrees"), {});
  const repo = get(st, "repo");
  const wt = T(m) ? pick_worktree(p, repo, m) : get(st, "worktree");
  if (!T(wt)) {
    hold_owner(st, "no_worktree",
      "Story " + S(st.id) + " belongs to repo " + S(or(repo, "(none resolved: set the story's repoPath)")) + ", and no worktree was given for it. Pass --worktree " +
      S(or(repo, "<repo>")) + "=<worktree> to the driver (tick); it is not routed to another repo's worktree.");
  }
  if (T(get(runj, "story_branches"))) {
    if (T(get(st, "story_worktree")) && isdir(st.story_worktree)) return st.story_worktree;
    const src = T(repo) ? repo : realpath(strip(git(wt, "rev-parse", "--show-toplevel").stdout) || wt);
    let swt, line;
    try {
      [swt, line] = cut_story_worktree(p, st.id, st, src);
    } catch (e) {
      if (!(e instanceof CutError)) throw e;
      hold_owner(st, e.message.includes("dependency branch missing") ? "dependency_branch_missing" : "cut_failed", e.message);
    }
    st.story_worktree = swt;
    print(line);
    return swt;
  }
  return wt;
}

// ---------- story-level go ----------
// The release detector: one place. A story whose declared files or acceptance criteria match
// any of these needs an explicit go. %(base)s is the prd's base branch.
const RELEASE_PATTERNS = [
  "\\bdeploy(s|ed|ing|ment|ments)?\\b",
  "\\breleas(e|es|ed|ing)\\b",
  "\\bproduction\\b",
  "\\bprod\\b",
  "\\bmerg(e|es|ed|ing)\\b[^.;\\n]{0,40}?\\b(to|into)\\b[^.;\\n]{0,15}?\\b(base branch|main|master|%(base)s)\\b",
];

function needs_go(p, s) {
  if (get(s, "approval") === "explicit") return "approval: explicit";
  if (get(s, "needsApproval") === true) return "needsApproval: true";
  const base = reEscape(base_branch(p));
  for (const [src, items] of [["files", get(s, "files")], ["acceptance criteria", get(s, "acceptanceCriteria")]]) {
    for (const t of or(items, [])) {
      if (typeof t !== "string") continue;
      for (const pat of RELEASE_PATTERNS) {
        const m = new RegExp(pat.split("%(base)s").join(base), "i").exec(t);
        if (m) return "release detector: " + pyRepr(m[0]) + " in " + src + " (" + t + ")";
      }
    }
  }
  return null;
}

function go_index(st) {
  const i = st.phases.findIndex(ph => !is_checker(ph.worker));
  return i < 0 ? 0 : i;
}

function go_path(sid) { return sp("decisions", sid + "-go.md"); }

function hold_for_go(st, why) {
  const sid = st.id; const ph = st.phases[st.current];
  st.state = "awaiting_go"; st.go_hold = { phase: ph.phase, worker: ph.worker, reason: why, at: iso(now()) };
  const dp = go_path(sid);
  writeText(dp,
    "# Decision: give the go for " + S(sid) + " before its " + S(ph.phase) + " phase\n\n" +
    "- story: " + S(sid) + " (" + S(get(st, "title", "")) + ")\n- phase: " + S(ph.phase) + "\n- worker: " + S(ph.worker) + "\n- reason: " + why + "\n- status: pending\n\n" +
    "This story needs an explicit go. Approving the " + S(ph.worker) + " worker for the whole run does not release it.\n\n" +
    "- Go: pipeline-conductor.sh go --state " + STATE + " --story " + S(sid) + "\n" +
    "- Accept without running it (passes is not set):\n" +
    "  pipeline-conductor.sh resolve --state " + STATE + " --story " + S(sid) + " --as accepted-partial --note \"<owner's reason>\"\n" +
    "- Set it and its dependents aside: pipeline-conductor.sh park --state " + STATE + " --story " + S(sid) + " --note \"<why>\"\n");
  jsave(sfile(sid), st);
  print("AWAITING_GO " + S(sid) + " " + S(ph.phase) + " " + dp);
  exit(10);
}

function do_go() {
  const sid = need_story();
  const st = jload(sfile(sid));
  if (st === null) die("story " + sid + " has no state in " + STATE + "; nothing to release");
  if (st.state !== "awaiting_go") {
    if (T(get(st, "go"))) { print("ALREADY go " + sid); return; }
    die("story " + sid + " is " + S(st.state) + "; go applies only to a story awaiting_go");
  }
  st.go = { at: iso(now()), note: note() };
  st.state = "queued";
  jsave(sfile(sid), st);
  mark_decision(go_path(sid), "go");
  print("GO " + sid);
}

function do_worktree() {
  if (!E.PC_REPO) die("worktree needs --repo", 2);
  if (!isdir(E.PC_REPO)) die("repo not found: " + E.PC_REPO);
  const repo = realpath(E.PC_REPO);
  const st = STORY ? sload(STORY) : null;
  let wt, line;
  try {
    if (E.PC_SHARED !== "1" && !PRD) {
      // no prd to name a branch: the repo itself is the target, and it is checked like an explicit one
      check_repo(repo); repos_worktree(explicit_target(repo) || repo); wt = explicit_target(repo) || repo; line = "";
    } else {
      const p = prd_opt();
      if (p === null) die("worktree --shared needs the prd for baseBranch and branchName: pass --prd", 2);
      if (E.PC_STORY_BRANCHES === "1") {
        if (st === null) die("worktree --story-branches needs --story", 2);
        [wt, line] = cut_story_worktree(p, STORY, st, repo);
        st.story_worktree = wt;
      } else {
        [wt, line] = cut_repo_worktree(p, repo);
      }
    }
  } catch (e) {
    if (!(e instanceof CutError)) throw e;
    die(e.message);
  }
  if (st !== null) { st.worktree = wt; st.repo = repo; jsave(sfile(STORY), st); }
  if (line) eprint(line);
  print(wt);
}

// ---------- gate ----------
function gate() {
  return jload(sp("gate.json"), { completed: 0, state: "ok", every: pyInt(E.PC_GATE_EVERY), note: "" });
}

function gate_tick() {
  const g = gate(); g.completed += 1;
  const every = pyInt(E.PC_GATE_EVERY) || 3;
  const due = ((g.completed % every) + every) % every === 0;
  if (due && !["failed", "reopened"].includes(g.state)) g.state = "due";
  jsave(sp("gate.json"), g);
  return due;
}

// ---------- report ----------
function report_line(sid, text) {
  const rp = sp("report.md");
  let lines = exists(rp) ? splitlines(readText(rp)) : [];
  if (lines.some(l => l.startsWith("- " + sid + " "))) return false;
  lines = lines.filter(l => !l.startsWith("FINAL:")).concat(["- " + sid + " " + text]);
  writeText(rp, lines.join("\n") + "\n");
  return true;
}

function story_report(sid, st) {
  const title = S(get(st, "title", ""));
  if (st.state === "verified") {
    if (T(get(st, "reopen")))
      return report_line(sid, "verified after it was reopened (" + wsjoin(get(st.reopen, "note", "")) + "): " + title);
    return report_line(sid, "verified: " + title);
  }
  if (st.state === "failed_report")
    return report_line(sid, "failed after one reroute: " + title + " (unmet AC: " + get(st, "unmet", []).map(S).join(",") + ")");
  if (st.state === "accepted_partial") {
    const r = or(get(st, "resolution"), {});
    const unmet = get(r, "unmet", []).map(S).join(",") || "none recorded";
    return report_line(sid, "accepted by the owner as a partial draft, not verified; passes is not set: " + title + " " +
                       "(unmet AC: " + unmet + "; owner note: " + wsjoin(get(r, "note", "")) + ")");
  }
  return false;
}

function all_stories() {
  const out = new Map();
  const d = sp("stories");
  for (const n of sortedStr(listdir(d))) {
    if (n.endsWith(".json")) {
      const v = jload(pjoin(d, n));
      if (T(v)) out.set(v.id, migrate_legacy(v));
    }
  }
  return out;
}

// ---------- selection ----------
function eligible(p) {
  const g = gate();
  if (g.state === "failed") return [];
  const known = all_stories();
  const done = new Set(p.userStories.filter(s => get(s, "passes") === true).map(s => s.id));
  for (const [k, v] of known) if (DONE_STATES.includes(v.state)) done.add(k);
  const out = [];
  p.userStories.forEach((s, i) => {
    const sid = get(s, "id");
    if (typeof sid !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._:-]*\n?$/.test(sid)) return;
    if (get(s, "passes") === true || known.has(sid)) return;
    if (or(get(s, "dependsOn"), []).every(d => done.has(d))) {
      const pr = get(s, "priority");
      out.push([isNum(pr) ? num(pr) : 1e9, i, sid]);
    }
  });
  out.sort((a, b) => (a[0] - b[0]) || (a[1] - b[1]));
  return out.map(x => x[2]);
}

// ---------- classification ----------
// A story's worker sequence is the full phase sequence for the story, in order. Sources, first match wins:
//   1. the run's overlay (<state>/overlay.json, written by `overlay set` or `classify --overlay`; the prd is
//      not edited), recorded as classified_by: overlay;
//   2. the story's worker_preference (a string or an array), classified_by: worker_preference;
//   3. the keyword fallback (architect, the matched implementers, qa-tester), classified_by: keywords.
function overlay_load() {
  const d = or(jload(sp("overlay.json"), {}), {});
  return isDict(d) ? d : {};
}

function seq_list(v) {
  if (isDict(v)) v = get(v, "worker_sequence");
  if (typeof v === "string") v = v.split(",").map(strip);
  return Array.isArray(v) ? v.filter(w => typeof w === "string" && strip(w)) : [];
}

function overlay_entries(d) {
  const out = {};
  if (isDict(d) && Array.isArray(get(d, "ordered_stories"))) {
    for (const e of d.ordered_stories)
      if (isDict(e) && typeof get(e, "id") === "string" && seq_list(e).length) out[e.id] = seq_list(e);
    return out;
  }
  if (isDict(d)) {
    for (const [k, v] of Object.entries(d)) if (seq_list(v).length) out[k] = seq_list(v);
  }
  return out;
}

function story_sequence(s) {
  const ov = seq_list(get(overlay_load(), get(s, "id")));
  if (ov.length) return [ov, "overlay"];
  let pref = or(get(s, "worker_preference"), []);
  if (typeof pref === "string") pref = [pref];
  const workers = pref.filter(w => typeof w === "string" && w);
  if (workers.length) return [workers, "worker_preference"];
  const text = [get(s, "title", ""), get(s, "description", "")].concat(Array.from(or(get(s, "labels"), []))).join(" ").toLowerCase();
  const hasw = ws => new RegExp("\\b(" + ws.join("|") + ")\\b").test(text);
  const schema = hasw(["database", "migration", "schema", "prisma", "sql"]);
  const ui = hasw(["component", "page", "form", "button", "react", "ui"]);
  const api = hasw(["endpoint", "api", "rest", "graphql", "route", "service"]);
  if (!(schema || ui || api)) return [null, null];
  return [["architect"].concat(schema ? ["database-dev"] : [], (api || schema) ? ["backend-dev"] : [],
                               ui ? ["frontend-dev"] : [], ["qa-tester"]), "keywords"];
}

function classify_story(s) {
  const [workers] = story_sequence(s);
  return T(workers) ? workers.map(w => ({ phase: phaseOf(w), worker: w })) : null;
}

// Code files: anything that is not docs, markdown, plain text or yaml. A story that declares none is not held
// to the implementer-first rule; `"docs_only": true` on the story exempts it explicitly.
const DOC_EXT = [".md", ".mdx", ".markdown", ".txt", ".rst", ".yaml", ".yml"];

function code_files(s) {
  if (get(s, "docs_only") === true) return [];
  const out = [];
  for (const f of or(get(s, "files"), [])) {
    if (typeof f !== "string" || !strip(f)) continue;
    const low = strip(f).toLowerCase();
    if (DOC_EXT.some(x => low.endsWith(x)) || /(^|\/)docs?\//.test(low)) continue;
    out.push(strip(f));
  }
  return out;
}

function sequence_problems(s, workers) {
  const sid = get(s, "id"); const errs = [], warns = [];
  for (const w of uniq(workers)) {
    if (!find_worker_yaml(w)) errs.push("story " + S(sid) + ": " + unknown_worker_msg(w));
  }
  const code = code_files(s);
  if (code.length && workers.length && find_worker_yaml(workers[0]) && !is_implementer(workers[0])) {
    errs.push("story " + S(sid) + ": its sequence " + workers.join(",") + " starts with " + workers[0] + " (" + (worker_role(workers[0]) || "no role") +
              "), a verifier or reader, but the story declares code " +
              "files (" + code.slice(0, 3).join(", ") + "). Prepend an implementer (pipeline-conductor.sh overlay set --state " + STATE + " --story " + S(sid) + " " +
              "--sequence <implementer>," + workers.join(",") + ") or mark the story docs-only (\"docs_only\": true)");
  }
  if (workers.length === 1)
    warns.push("story " + S(sid) + ": the sequence is one worker (" + workers[0] + "); architect and qa phases will not run");
  return [errs, warns];
}

// Dependency lint: a story whose acceptance criteria or declared files name a LATER story's id (word match),
// or contain a file path that only later stories declare (substring match), and whose dependsOn lacks that
// story. A warning only; it prints the dependsOn line that would fix it.
function dep_lint(p, s) {
  const stories = p.userStories.filter(x => typeof get(x, "id") === "string");
  const ids = stories.map(x => x.id);
  if (!ids.includes(get(s, "id"))) return [];
  const i = ids.indexOf(s.id);
  const deps = Array.from(or(get(s, "dependsOn"), []));
  const text = Array.from(or(get(s, "acceptanceCriteria"), [])).concat(Array.from(or(get(s, "files"), []))).map(S).join("\n");
  const own = new Set();
  for (const x of stories.slice(0, i + 1)) for (const f of or(get(x, "files"), [])) if (typeof f === "string") own.add(f);
  const missing = [];
  for (const later of stories.slice(i + 1)) {
    const lid = later.id;
    if (deps.includes(lid)) continue;
    let why = null;
    if (new RegExp("(?<![A-Za-z0-9_-])" + reEscape(lid) + "(?![A-Za-z0-9_-])").test(text)) why = "names " + lid;
    else {
      for (const f of or(get(later, "files"), [])) {
        if (typeof f === "string" && strip(f) && !own.has(f) && text.includes(f)) {
          why = "references " + f + ", which only " + lid + " declares"; break;
        }
      }
    }
    if (why) missing.push([lid, why]);
  }
  if (!missing.length) return [];
  const want = deps.concat(missing.map(x => x[0]).filter(lid => !deps.includes(lid)));
  return ["story " + s.id + " needs " + missing.map(([lid, w]) => lid + " (" + w + ")").join(" and ") + ", but its dependsOn lacks " +
          (missing.length > 1 ? "them" : "it") + "; suggested: \"dependsOn\": " + pyDumps(want, true)];
}

// ---------- worker table (lanes) ----------
function table_path() {
  return E.PC_TABLE || or(get(or(jload(sp("run.json"), {}), {}), "table"), "");
}

function table_rows() {
  // Map{worker: model} from the confirmed table, or null when the run has no table.
  const t = table_path();
  if (!T(t)) return null;
  if (!exists(t)) die("worker table not found: " + S(t));
  const rows = new Map();
  for (const ln of splitlines(readText(t))) {
    const f = words(ln);
    if (!f.length || f[0].startsWith("#") || f[0] === "worker") continue;
    rows.set(f[0], f.length > 2 ? f[2] : "");
  }
  return rows;
}

function lane_problems(workers) {
  const rows = table_rows();
  if (rows === null) return [];
  const miss = uniq(workers).filter(w => !rows.has(w));
  return miss.length ? ["no lane in the worker table " + S(table_path()) + " for: " + miss.join(", ") + ". Add a row for each and confirm the table again"] : [];
}

const BARE_ALIASES = ["opus", "sonnet", "haiku", "fable"];

function hint_notes(s, workers) {
  let h = get(s, "model_hint");
  if (typeof h !== "string" || !strip(h)) return [[], null];
  h = strip(h); const rows = table_rows() || new Map();
  const pins = sortedStr(new Set(workers.filter(w => T(rows.get(w))).map(w => rows.get(w))));
  if (pins.length) return [["story " + s.id + ": model_hint " + h + ": hint ignored, table pins " + pins.join(", ")], null];
  if (BARE_ALIASES.includes(h.toLowerCase()))
    return [["story " + s.id + ": model_hint " + h + " is a bare alias and is ignored; give a full model id or pin the lane " +
             "in the worker table"], null];
  return [[], h];
}

function skipped(sid) { return has(or(jload(sp("skips.json"), {}), {}), sid); }

function do_classify(p, sid, raw) {
  if (skipped(sid)) {
    print("SKIPPED " + sid + " (in skips.json; unskip --story " + sid + " to run it)"); return null;
  }
  const s = story_of(p, sid);
  const [workers, src0] = story_sequence(s);
  if (!T(workers)) {
    die("story " + sid + " is unclassified: set worker_preference, add it to the overlay (overlay set --state " + STATE + " " +
        "--story " + sid + " --sequence <a>,<b>,...), or leave it out (skip --state " + STATE + " --story " + sid + ")");
  }
  let [errs, warns] = sequence_problems(s, workers);
  errs = errs.concat(lane_problems(workers));
  if (errs.length) die("classify refused:\n  " + errs.join("\n  "));
  const [hw, hint] = hint_notes(s, workers);
  const phases = workers.map(w => ({ phase: phaseOf(w), worker: w }));
  const st = or(jload(sfile(sid)), {});
  for (const w of warns.concat(hw, dep_lint(p, s))) {
    if (!or(get(st, "warned"), []).includes(w)) {
      eprint("WARN " + w); setdefault(st, "warned", []).push(w);
    }
  }
  if (hint) st.model_hint = hint;
  else pop(st, "model_hint");
  Object.assign(st, { id: sid, title: get(s, "title", ""), phases: phases, classified_by: src0, worker_sequence: workers });
  setdefault(st, "current", 0); setdefault(st, "state", "queued"); setdefault(st, "reroutes", 0);
  const [repo, src] = resolve_repo(p, s);
  st.repo = repo; st.repo_source = src;
  const m = wt_mapping(raw);
  if (T(m)) {
    st.worktree = pick_worktree(p, repo, m);
  } else if (!T(get(st, "worktree")) && !multi_repo(p)) {
    st.worktree = abspath(repo || process.cwd());
  }
  jsave(sfile(sid), st);
  return st;
}

// ---------- worker.yaml ----------
const SKIP_DIRS = ["node_modules", ".git", "dist"];

function find_worker_yaml(w) {
  for (const root of E.PC_WORKERS_ROOT.split(":")) {
    if (!root || !isdir(root)) continue;
    for (const ent of walk(root)) {
      ent[1] = ent[1].filter(d => !SKIP_DIRS.includes(d));
      if (basename(ent[0]) === w && ent[2].includes("worker.yaml")) return pjoin(ent[0], "worker.yaml");
    }
  }
  return null;
}

let _KNOWN = null;
function known_workers() {
  if (_KNOWN === null) {
    const out = new Set();
    for (const root of E.PC_WORKERS_ROOT.split(":")) {
      if (!root || !isdir(root)) continue;
      for (const ent of walk(root)) {
        ent[1] = ent[1].filter(d => !SKIP_DIRS.includes(d));
        if (ent[2].includes("worker.yaml")) out.add(basename(ent[0]));
      }
    }
    _KNOWN = sortedStr(out);
  }
  return _KNOWN;
}

function edit_distance(a, b) {
  a = Array.from(a); b = Array.from(b);
  let prev = []; for (let j = 0; j <= b.length; j++) prev.push(j);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++)
      cur.push(Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] !== b[j - 1] ? 1 : 0)));
    prev = cur;
  }
  return prev[prev.length - 1];
}

function unknown_worker_msg(w) {
  const known = known_workers();
  const near = known.map(k => [edit_distance(w, k), k]).sort((x, y) => (x[0] - y[0]) || cmpStr(x[1], y[1]))
    .filter(x => x[0] <= 3).map(x => x[1]).slice(0, 3);
  const hint = near.length ? "; nearest known: " + near.join(", ") : "; known: " + (known.join(", ") || "none");
  return "unknown worker " + w + ": no worker.yaml under " + E.PC_WORKERS_ROOT.split(":").filter(Boolean).join(", ") + hint;
}

function yaml_field(y, key) {
  // worker.<key> (or a top-level <key>) from a worker.yaml, as a string; empty when absent.
  const text = readText(y);
  const m = /^worker:\s*\n((?:[ \t]+.*\n?|\s*\n)*)/m.exec(text);
  for (const block of (m ? [m[1]] : []).concat([text])) {
    const n = new RegExp("^[ \\t]*" + reEscape(key) + ":[ \\t]*['\"]?([^'\"#\\n]*?)['\"]?[ \\t]*(#.*)?$", "m").exec(block);
    if (n && strip(n[1])) return strip(n[1]);
  }
  return "";
}

// Implementer test, in one place. It reads the worker's worker.yaml: `worker.role` when set, else
// `worker.type`. A value naming a reviewer, tester, architect or reader (review, test, qa, architect or read,
// case-insensitive) makes the worker a verifier or reader. When worker.yaml sets no role, a worker id that
// names one of those (qa-tester, code-reviewer, architect) counts too. Anything else is an implementer.
const VERIFIER_RE = /(review|test|qa|architect|read)/i;

function worker_role(w) {
  const y = find_worker_yaml(w);
  return y ? (yaml_field(y, "role") || yaml_field(y, "type")) : "";
}

function is_implementer(w) {
  const y = find_worker_yaml(w);
  const role = y ? yaml_field(y, "role") : "";
  if (role) return !VERIFIER_RE.test(role);
  const typ = y ? yaml_field(y, "type") : "";
  if (typ && VERIFIER_RE.test(typ)) return false;
  return !/(^|[-_])(qa|test|tester|testing|review|reviewer|verifier|architect|reader)([-_]|$)/.test(w || "");
}

// Minimal YAML reading for approval_needs: the top-level mapping, and the verification mapping's
// approval_required and human_checkpoints. Returns null when the text has no top-level mapping.
const YAML_TRUE = ["y", "Y", "yes", "Yes", "YES", "true", "True", "TRUE", "on", "On", "ON"];
const YAML_FALSE = ["n", "N", "no", "No", "NO", "false", "False", "FALSE", "off", "Off", "OFF"];
function yamlUncomment(v) {
  if (/^["']/.test(v)) return v;
  const m = /(^|[ \t])#/.exec(v);
  return m ? v.slice(0, m.index) : v;
}
function yamlScalar(raw) {
  let v = strip(yamlUncomment(raw));
  if (v === "" || v === "~" || v === "null" || v === "Null" || v === "NULL") return null;
  if (v.startsWith('"') && v.endsWith('"') && v.length >= 2) {
    try { return JSON.parse(v); } catch (e) { return v.slice(1, -1); }
  }
  if (v.startsWith("'") && v.endsWith("'") && v.length >= 2) return v.slice(1, -1).replace(/''/g, "'");
  if (YAML_TRUE.indexOf(v) >= 0 && !/^[yYnN]$/.test(v)) return true;
  if (YAML_FALSE.indexOf(v) >= 0 && !/^[yYnN]$/.test(v)) return false;
  if (/^[-+]?(0|[1-9][0-9_]*)$/.test(v)) return parseInt(v.replace(/_/g, ""), 10);
  if (/^[-+]?([0-9][0-9_]*)?\.[0-9_]*([eE][-+][0-9]+)?$/.test(v) && /[0-9]/.test(v)) return parseFloat(v.replace(/_/g, ""));
  if (v.startsWith("[") && v.endsWith("]")) {
    const inner = strip(v.slice(1, -1));
    return inner ? inner.split(",").map(x => yamlScalar(x)) : [];
  }
  if (v.startsWith("{") && v.endsWith("}")) {
    const out = {}; const inner = strip(v.slice(1, -1));
    if (inner) for (const part of inner.split(",")) {
      const i = part.indexOf(":"); if (i < 0) continue;
      out[strip(part.slice(0, i))] = yamlScalar(part.slice(i + 1));
    }
    return out;
  }
  return v;
}
function yamlBlock(lines, start, parentIndent) {
  // The value of a key whose inline value was empty: a block sequence, a block mapping, or null.
  let i = start;
  while (i < lines.length && (/^\s*$/.test(lines[i]) || /^\s*#/.test(lines[i]))) i++;
  if (i >= lines.length) return [null, i];
  const ind = lines[i].match(/^ */)[0].length;
  const isSeq = /^ *- |^ *-$/.test(lines[i]);
  if (ind < parentIndent || (ind === parentIndent && !isSeq)) return [null, start];
  if (isSeq) {
    const out = [];
    while (i < lines.length) {
      const l = lines[i];
      if (/^\s*$/.test(l) || /^\s*#/.test(l)) { i++; continue; }
      const li = l.match(/^ */)[0].length;
      if (li < ind) break;
      if (li === ind) {
        const m = /^ *-(?: (.*))?$/.exec(l);
        if (!m) break;
        out.push(yamlScalar(m[1] || ""));
      }
      i++;
    }
    return [out, i];
  }
  const out = {};
  while (i < lines.length) {
    const l = lines[i];
    if (/^\s*$/.test(l) || /^\s*#/.test(l)) { i++; continue; }
    const li = l.match(/^ */)[0].length;
    if (li < ind) break;
    if (li === ind) {
      const m = /^ *("[^"]*"|'[^']*'|[^:#][^:]*?):(?:[ \t]+(.*)|)$/.exec(l);
      if (!m) { i++; continue; }
      const k = m[1].replace(/^["']|["']$/g, "");
      if (strip(yamlUncomment(m[2] || "")) === "") {
        const [v, ni] = yamlBlock(lines, i + 1, ind);
        out[k] = v; i = Math.max(ni, i + 1); continue;
      }
      out[k] = yamlScalar(m[2]);
    }
    i++;
  }
  return [out, i];
}
function yamlTop(text) {
  const lines = text.split(/\r?\n/);
  const [doc] = yamlBlock(lines.filter(l => !/^(---|\.\.\.)\s*$/.test(l)), 0, -1);
  return isDict(doc) ? doc : null;
}

function approval_needs(w) {
  const y = find_worker_yaml(w);
  if (!y) return [];
  const text = readText(y);
  let doc = null;
  try { doc = yamlTop(text); } catch (e) { doc = null; }
  const reasons = [];
  if (isDict(doc)) {
    const ver = isDict(get(doc, "verification")) ? doc.verification : {};
    if (get(doc, "approval_required") === true || get(ver, "approval_required") === true)
      reasons.push("approval_required: true");
    const hc = get(ver, "human_checkpoints");
    if (T(hc))
      reasons.push("human_checkpoints: " + (Array.isArray(hc) ? hc : [hc]).map(S).join(", "));
  } else {
    if (/^\s*approval_required:\s*true\b/m.test(text)) reasons.push("approval_required: true");
    const m = /^(\s*)human_checkpoints:\s*(.*)$/m.exec(text);
    if (m) {
      const inline = strip(m[2]);
      let items;
      if (!inline) {
        const seg = text.slice(m.index + m[0].length).split("\n\n")[0];
        items = []; const re = /^\s*-\s*(\S.*)$/gm; let x;
        while ((x = re.exec(seg)) !== null) { items.push(x[1]); if (x[0] === "") re.lastIndex++; }
      } else {
        items = stripChars(inline, "[]").split(",").filter(x => strip(x)).map(strip);
      }
      if (items.length) reasons.push("human_checkpoints: " + items.join(", "));
    }
  }
  return reasons;
}

function approved(sid, w) {
  const a = jload(sp("approvals.json"), { run: [], story: {} });
  return get(a, "run", []).includes(w) || get(get(a, "story", {}), sid, []).includes(w);
}

// ---------- envelopes ----------
function validate(path, kind) {
  const r = run(E.PC_ENVELOPE, ["validate", "--kind", kind, path]);
  return [r.returncode === 0, strip(r.stderr || r.stdout)];
}

function do_route(p, sid) {
  const st = sload(sid);
  if (gate().state === "failed" && st.state === "queued" && st.current === 0 && !T(get(st, "started")))
    die("regression gate failed; not starting new stories");
  if (!["queued", "held"].includes(st.state))
    die("story " + sid + " is " + S(st.state) + ", nothing to route");
  const i = st.current; const ph = st.phases[i];
  const rows = table_rows();
  if (rows !== null && !rows.has(ph.worker)) {
    print("NO_LANE " + sid + " " + S(ph.phase) + " " + S(ph.worker) + " not in the worker table " + S(table_path()));
    exit(12);
  }
  let incoming = null;
  if (i > 0) {
    const prev = st.phases[i - 1];
    incoming = sp("handoffs", sid + "-" + prev.phase + ".json");
    if (!exists(incoming)) die("refusing " + sid + "/" + S(ph.phase) + ": no handoff from " + S(prev.phase));
    const [ok, why] = validate(incoming, "handoff");
    if (!ok) die("refusing " + sid + "/" + S(ph.phase) + ": previous handoff invalid: " + why);
    if (get(or(jload(incoming), {}), "status") !== "passed")
      die("refusing " + sid + "/" + S(ph.phase) + ": previous phase " + S(prev.phase) + " did not pass");
  }
  const s = story_of(p, sid);
  if (i === go_index(st) && !T(get(st, "go"))) {
    const why = needs_go(p, s);
    if (why) hold_for_go(st, why);
  }
  const wt = route_worktree(p, st);
  const reasons = approved(sid, ph.worker) ? [] : approval_needs(ph.worker);
  if (reasons.length) {
    const dp = sp("decisions", sid + "-" + ph.worker + ".md");
    if (!exists(dp)) {
      writeText(dp,
        "# Decision: approve " + S(ph.worker) + " for " + S(ph.phase) + " phase of " + sid + "\n\n" +
        "- story: " + sid + " (" + S(get(st, "title", "")) + ")\n- phase: " + S(ph.phase) + "\n- worker: " + S(ph.worker) + "\n- reason: " + reasons.join("; ") + "\n- status: pending\n\n" +
        "Approve with: pipeline-conductor.sh release --state " + STATE + " --story " + sid + " --worker " + S(ph.worker) + "\n" +
        "Approve for the whole run with: pipeline-conductor.sh release --state " + STATE + " --worker " + S(ph.worker) + "\n");
    }
    st.state = "held"; st.held_for = ph.worker; jsave(sfile(sid), st);
    print("HELD " + sid + " " + S(ph.phase) + " " + dp);
    exit(10);
  }
  st.worktree = wt;
  const env = { schema: "hq-phase-envelope/v1", story_id: sid, phase: ph.phase, worker_id: ph.worker,
                worktree: wt, incoming_handoff: incoming,
                acceptance_criteria: Array.from(or(get(s, "acceptanceCriteria"), [])),
                deadline: iso(now() + pyInt(E.PC_DEADLINE_MIN) * 60),
                fresh_call: (st.reroutes > 0 && i === get(st, "rerouted_at", -1)) || get(or(get(st, "owner_retry"), {}), "index") === i
                            || get(reopen_pending(st), "index") === i,
                result_path: abspath(sp("handoffs", sid + "-" + ph.phase + ".json")) };
  if (T(get(p, "name")) || T(get(p, "project"))) env.project = S(or(get(p, "name"), get(p, "project")));
  if (T(get(st, "repo"))) env.repo = st.repo;
  if (isdir(wt)) {
    const br = git(wt, "rev-parse", "--abbrev-ref", "HEAD");
    if (br.returncode === 0 && !["", "HEAD"].includes(strip(br.stdout))) {
      env.branch = strip(br.stdout);
      setdefault(env, "constraints", []).push(
        "Commit this phase's work on branch " + env.branch + " in " + wt + "; stories of this repo build on each other there.");
    }
  }
  if (typeof get(s, "title") === "string" && s.title) env.story_title = s.title;
  if (typeof get(s, "description") === "string" && s.description) env.story_description = s.description;
  const cpth = sp("constraints.txt");
  if (exists(cpth)) {
    const cons = splitlines(readText(cpth)).map(strip).filter(Boolean);
    if (cons.length) env.constraints = cons;
  }
  if (store_paths(s).length) {
    setdefault(env, "constraints", []).push(
      "This story adds or changes a data store or schema. Run the repo's schema-contract tests " +
      "(tests that check queries and columns against the schema) as back-pressure, if present.");
  }
  const ro = reopen_pending(st);
  if (get(ro, "index") === i) {
    env.reopen_note = wsjoin(get(ro, "note", ""));
    setdefault(env, "constraints", []).push(
      "This story was " + S(get(ro, "from", "verified")) + " and has been reopened at this phase. Why: " + env.reopen_note);
  }
  const orr = or(get(st, "owner_retry"), {});
  if (get(orr, "index") === i && T(get(orr, "note"))) {
    setdefault(env, "constraints", []).push(
      "The owner answered your last blocker on this phase: " + wsjoin(orr.note));
  }
  const ip = interrupt_pending(st);
  if (get(ip, "index") === i) {
    env.resumed_after_interrupt = true;
    env.fresh_call = true;
    if (T(get(ip, "partial_handoff"))) env.prior_handoff = ip.partial_handoff;
    setdefault(env, "constraints", []).push(
      "This phase was interrupted at " + S(get(ip, "at", "?")) + " when the run stopped; check the worktree for partial work" +
      (T(get(ip, "partial_handoff")) ? " and read the partial handoff " + S(ip.partial_handoff) : "") + " before " +
      "starting over.");
  }
  if (repos_worktree(wt, false)) setdefault(env, "constraints", []).push(REPOS_WT_LINE);
  const ep = sp("envelopes", sid + "-" + ph.phase + ".json");
  jsave(ep, env);
  const [ok, why] = validate(ep, "envelope");
  if (!ok) {
    fs.unlinkSync(ep); die("built an invalid envelope for " + sid + "/" + S(ph.phase) + ": " + why);
  }
  const sessionEnv = process.env.HQ_SESSION_ID ? ["HQ_SESSION_ID=" + process.env.HQ_SESSION_ID] : [];
  const session = strip(run("env", ["HQ_ROOT=" + E.PC_HQ_ROOT].concat(sessionEnv, ["bash", pjoin(E.PC_HQ_ROOT, "core/scripts/hq-session.sh"), "current"])).stdout);
  const company = strip(run("env", ["HQ_ROOT=" + E.PC_HQ_ROOT, "bash", pjoin(E.PC_HQ_ROOT, "core/scripts/hq-session.sh"), "--session-id", session, "get", "company_slug"]).stdout);
  if (!company || company === "personal") die("cannot route pipeline phase: no company is bound in session state");
  const project = S(or(get(p, "name"), or(get(p, "project"), "")));
  if (!project) die("cannot route pipeline phase: project name is missing");
  const runState = or(jload(sp("run.json"), {}), {});
  if ((T(get(runState, "company_slug")) && runState.company_slug !== company) ||
      (T(get(runState, "project")) && runState.project !== project)) {
    die("cannot resume pipeline lane mapping: bound company or project differs from the run owner");
  }
  runState.company_slug = company; runState.project = project; jsave(sp("run.json"), runState);
  const lanesFile = sp("lanes.json");
  const laneMap = or(jload(lanesFile, {}), {});
  let lane = laneMap[ph.worker];
  if (lane) {
    let rows;
    try {
      const listed = JSON.parse(run(E.PC_HQ, ["lanes", "list", "--json"], { timeout: 30000 }).stdout || "{}");
      rows = Array.isArray(listed) ? listed : get(listed, "lanes", null);
    } catch (e) { die("cannot verify mapped pipeline lane ownership: hq lanes list returned invalid JSON"); }
    if (!Array.isArray(rows)) die("cannot verify mapped pipeline lane ownership: hq lanes list omitted lanes");
    const row = rows.find(x => isDict(x) && get(x, "lane_id") === lane);
    if (!row) { delete laneMap[ph.worker]; jsave(lanesFile, laneMap); lane = null; }
    else if (get(get(row, "company", {}), "slug") !== company || get(row, "project_id") !== project || get(row, "worker") !== ph.worker) {
      die("refusing to reuse mapped pipeline lane owned by a different company, project, or worker");
    }
  }
  if (!lane) {
    const meta = or(get(p, "metadata"), {});
    const createArgs = ["lanes", "create", "--loop", "--company", company, "--project", project,
      "--story", sid, "--worker", ph.worker, "--senior", "session:" + session, "--json"];
    const table = get(or(jload(sp("run.json"), {}), {}), "table", "");
    if (T(table) && exists(table)) {
      const row = splitlines(readText(table)).map(x => x.split("\t")).find(x => x[0] === ph.worker);
      if (row) { if (row[1]) createArgs.push("--provider", row[1]); if (row[2]) createArgs.push("--model", row[2]); if (row[3]) createArgs.push("--effort", row[3]); }
    }
    const created = run(E.PC_HQ, createArgs, { timeout: 120000 });
    let answer; try { answer = JSON.parse(created.stdout); } catch (e) { answer = {}; }
    if (!isDict(answer) || get(answer, "ok") !== true) {
      const createError = get(answer, "error", null);
      const code = S(isDict(createError) ? get(createError, "code", get(answer, "code", "create_failed")) : (createError || get(answer, "code", "create_failed")));
      if (/admission|capacity|full|limit/i.test(code)) { st.state = "queued"; jsave(sfile(sid), st); print("RETRY " + sid + " " + S(ph.phase) + " lanes-" + code); exit(3); }
      die("hq lanes create refused pipeline phase: " + code + " " + strip(created.stderr));
    }
    lane = get(answer, "lane_id", get(answer, "lane"));
    if (!T(lane)) die("hq lanes create returned no lane_id");
    laneMap[ph.worker] = lane;
    jsave(lanesFile, laneMap);
  }
  const envData = jload(ep, {}); const baseEnvelopeId = sid + "-" + ph.phase;
  const suffixes = or(get(st, "envelope_suffixes"), {});
  envData.id = baseEnvelopeId + (suffixes[ph.phase] ? ".r" + suffixes[ph.phase] : "");
  envData.result_path = abspath(sp("handoffs", sid + "-" + ph.phase + ".json")); jsave(ep, envData);
  let r = run(E.PC_HQ, ["lanes", "enqueue", lane, "--envelope", abspath(ep)], { timeout: 30000 });
  let ans; try { ans = JSON.parse(r.stdout); } catch (e) { ans = {}; }
  let enqueueError = get(ans, "error", null);
  let code = S(isDict(enqueueError) ? get(enqueueError, "code", get(ans, "code", "enqueue_failed")) : (enqueueError || get(ans, "code", "enqueue_failed")));
  if ((!isDict(ans) || get(ans, "ok") !== true) && /already.*used|envelope_id_reused/i.test(code)) {
    const n = Number(suffixes[ph.phase] || 0) + 1;
    suffixes[ph.phase] = n; st.envelope_suffixes = suffixes; envData.id = baseEnvelopeId + ".r" + n;
    jsave(sfile(sid), st); jsave(ep, envData);
    r = run(E.PC_HQ, ["lanes", "enqueue", lane, "--envelope", abspath(ep)], { timeout: 30000 });
    try { ans = JSON.parse(r.stdout); } catch (e) { ans = {}; }
    enqueueError = get(ans, "error", null);
    code = S(isDict(enqueueError) ? get(enqueueError, "code", get(ans, "code", "enqueue_failed")) : (enqueueError || get(ans, "code", "enqueue_failed")));
  }
  if (!isDict(ans) || get(ans, "ok") !== true) {
    if (code === "loop_not_running" || ["stopped", "failed", "parked"].includes(get(ans, "loop_state"))) {
      delete laneMap[ph.worker]; jsave(lanesFile, laneMap); st.state = "queued"; jsave(sfile(sid), st);
      print("LANE_DOWN " + sid + " " + S(ph.phase) + " " + S(ph.worker) + " lanes-" + code); exit(11);
    }
    die("hq lanes enqueue failed for " + sid + "/" + S(ph.phase) + ": " + code + " " + strip(r.stderr));
  }
  st.state = "in_flight"; st.started = true; st.routed_at = now(); pop(st, "held_for");
  pop(st, "owner_retry");
  if (get(reopen_pending(st), "index") === i) st.reopen.routed = true;
  if (get(interrupt_pending(st), "index") === i) { st.interrupted.routed = true; st.interrupted.routed_at = iso(now()); }
  jsave(sfile(sid), st);
  print("ROUTED " + sid + " " + S(ph.phase) + " " + S(ph.worker) + " " + strip(r.stdout));
}

// ---------- accept ----------
function do_accept(sid) {
  const st = sload(sid);
  const src = E.PC_HANDOFF;
  if (!src || !exists(src)) die("--handoff file required");
  const [ok, why] = validate(src, "handoff");
  if (!ok) die("invalid handoff: " + why);
  const h = jload(src);
  if (st.state !== "in_flight")
    die("story " + sid + " is " + S(st.state) + ", not in_flight; refusing handoff");
  const ph = st.phases[st.current];
  if (get(h, "story_id") !== sid && !S(get(h, "story_id", "")).endsWith("/" + sid))
    die("handoff story_id " + S(get(h, "story_id")) + " does not match " + sid);
  if (get(h, "phase") !== ph.phase) die("handoff phase " + S(get(h, "phase")) + " is not the current phase " + S(ph.phase));
  const dst = sp("handoffs", sid + "-" + ph.phase + ".json");
  if (abspath(src) !== abspath(dst)) jsave(dst, h);
  if (h.status === "blocked") {
    const dp = hold_blocked(st, h, dst);
    print("PHASE_BLOCKED " + sid + " " + S(ph.phase) + " " + dp); exit(10);
  }
  if (h.status !== "passed") {
    st.state = "queued"; jsave(sfile(sid), st);
    print("PHASE_" + String(h.status).toUpperCase() + " " + sid + " " + S(ph.phase)); exit(1);
  }
  if (st.current + 1 < st.phases.length) {
    st.current += 1; st.state = "queued"; jsave(sfile(sid), st);
    print("NEXT " + sid + " " + S(st.phases[st.current].phase));
  } else {
    st.state = "awaiting_recheck"; jsave(sfile(sid), st);
    print("RECHECK " + sid);
  }
}

// ---------- recheck ----------
function unmet_acs(sid, st, acs, extra) {
  const met = new Map();
  const paths = st.phases.map(ph => sp("handoffs", sid + "-" + ph.phase + ".json")).concat(Array.from(extra || []));
  for (const path of paths) {
    const h = or(jload(path), {});
    for (const ev of or(get(h, "ac_evidence"), [])) {
      if (!isDict(ev) || !(typeof get(ev, "index") === "number" && Number.isInteger(ev.index))) continue;
      const k = ev.index;
      if (has(ev, "criterion") && k < acs.length) {
        const ak = k < 0 ? acs[acs.length + k] : acs[k];
        if (k < 0 && acs.length + k < 0) throw new Error("IndexError: list index out of range");
        if (!eq(ev.criterion, ak)) continue;
      }
      if (get(ev, "met") === true && typeof get(ev, "evidence") === "string" && strip(ev.evidence)) met.set(k, true);
    }
  }
  const out = [];
  for (let i = 0; i < acs.length; i++) if (!met.get(i)) out.push(i);
  return out;
}

function do_recheck(p, sid) {
  const st = sload(sid);
  if (st.state !== "awaiting_recheck") die("story " + sid + " is " + S(st.state) + ", not awaiting_recheck");
  const acs = Array.from(or(get(story_of(p, sid), "acceptanceCriteria"), []));
  const unmet = unmet_acs(sid, st, acs);
  if (!unmet.length) {
    st.state = "verified";
    if (T(get(st, "reopen"))) st.reopen.done = true;
    jsave(sfile(sid), st);
    story_report(sid, st);
    print("VERIFIED " + sid);
    let due = gate_tick();
    const g = gate();
    if (or(get(g, "reopened"), []).includes(sid)) {
      g.reopened.splice(g.reopened.indexOf(sid), 1);
      if (!g.reopened.length && g.state === "reopened") { g.state = "due"; due = true; }
      jsave(sp("gate.json"), g);
    }
    if (due) print("RUN_GATE");
    return;
  }
  if (st.reroutes < 1) {
    st.reroutes = 1; st.current = st.phases.length - 1; st.rerouted_at = st.current;
    st.state = "queued"; st.unmet = unmet; jsave(sfile(sid), st);
    try { fs.unlinkSync(sp("handoffs", sid + "-" + st.phases[st.phases.length - 1].phase + ".json")); } catch (e) { /* none */ }
    print("ROUTED_BACK " + sid + " " + S(st.phases[st.phases.length - 1].phase) + " unmet:" + unmet.join(","));
    exit(1);
  }
  st.state = "failed_report"; st.unmet = unmet; jsave(sfile(sid), st);
  story_report(sid, st);
  print("FAILED " + sid + " unmet:" + unmet.join(","));
  exit(1);
}

// ---------- release ----------
function do_release() {
  let w = E.PC_WORKER;
  const a = jload(sp("approvals.json"), { run: [], story: {} });
  let targets;
  if (STORY) {
    const st = sload(STORY);
    if (st.state === "awaiting_go")
      die("story " + STORY + " is awaiting_go; a worker approval does not release it: run go --story " + STORY);
    w = w || get(st, "held_for");
    if (!T(w)) die("story " + STORY + " is not held");
    setdefault(setdefault(a, "story", {}), STORY, []);
    if (!a.story[STORY].includes(w)) a.story[STORY].push(w);
    targets = [STORY];
  } else {
    if (!w) die("release needs --story or --worker", 2);
    if (!setdefault(a, "run", []).includes(w)) a.run.push(w);
    targets = [];
    for (const [k, v] of all_stories()) if (v.state === "held" && get(v, "held_for") === w) targets.push(k);
  }
  jsave(sp("approvals.json"), a);
  for (const sid of targets) {
    const st = sload(sid);
    const dp = sp("decisions", sid + "-" + w + ".md");
    if (exists(dp)) {
      const t = readText(dp).split("- status: pending").join("- status: approved");
      writeText(dp, t);
    }
    if (st.state === "held") { st.state = "queued"; pop(st, "held_for"); jsave(sfile(sid), st); }
    print("RELEASED " + sid + " " + S(w));
  }
}

// ---------- owner resolutions ----------
function note() {
  return E.PC_NOTE_SET === "1" ? E.PC_NOTE : "";
}

function story_acs(sid, phase) {
  const p = prd_opt();
  if (p) {
    for (const s of p.userStories) if (get(s, "id") === sid) return Array.from(or(get(s, "acceptanceCriteria"), []));
  }
  const env = or(jload(sp("envelopes", sid + "-" + phase + ".json")), {});
  const acs = get(env, "acceptance_criteria");
  if (Array.isArray(acs)) return acs;
  die("cannot find the acceptance criteria of " + sid + ": pass --prd");
}

function maxFailed(sid, phase) {
  const ns = archives(sid, phase).map(x => x[0]);
  return ns.length ? Math.max.apply(null, ns) : 0;
}

function do_resolve() {
  const sid = need_story(); const how = E.PC_AS;
  if (!["accepted-partial", "retry"].includes(how)) die("resolve needs --as accepted-partial|retry", 2);
  let st = jload(sfile(sid));
  if (st === null) die("story " + sid + " has no state in " + STATE + "; nothing to resolve");
  st = migrate_legacy(st);
  const last = or(get(st, "resolution"), {});
  if (how === "accepted-partial") {
    if (st.state === "accepted_partial") { print("ALREADY accepted-partial " + sid); return; }
    if (!["blocked_needs_owner", "awaiting_go"].includes(st.state))
      die("story " + sid + " is " + S(st.state) + "; resolve --as accepted-partial applies only to a story blocked for the owner " +
          "(blocked_needs_owner) or awaiting_go");
    if (!strip(note())) die("resolve --as accepted-partial needs --note <the owner's reason>", 2);
    const b = or(get(st, "blocked"), { phase: st.phases[st.current].phase, handoff: null });
    const acs = story_acs(sid, b.phase);
    const unmet = unmet_acs(sid, st, acs, T(get(b, "handoff")) ? [b.handoff] : []);
    st.state = "accepted_partial"; st.unmet = unmet;
    st.resolution = { as: "accepted-partial", note: note(), at: iso(now()), phase: b.phase,
                      unmet: unmet, unmet_text: unmet.map(i => acs[i]), ac_total: acs.length };
    jsave(sfile(sid), st);
    mark_decision(decision_path(sid, b.phase), "resolved: accepted-partial");
    mark_decision(go_path(sid), "resolved: accepted-partial");
    story_report(sid, st);
    print("RESOLVED " + sid + " accepted-partial unmet:" + unmet.join(",") + " passes-not-set");
    return;
  }
  if (!["blocked_needs_owner", "awaiting_go"].includes(st.state)) {
    if (get(last, "as") === "retry" && ["queued", "in_flight"].includes(st.state)) {
      print("ALREADY retry " + sid); return;
    }
    die("story " + sid + " is " + S(st.state) + "; resolve --as retry applies only to a story blocked for the owner " +
        "(blocked_needs_owner)");
  }
  const p = prd_opt();
  if (p === null) die("resolve --as retry needs the prd to re-read the story's phases: pass --prd", 2);
  const phases = classify_story(story_of(p, sid));
  if (!T(phases)) die("story " + sid + " is unclassified in the prd: set worker_preference");
  const b = or(pop(st, "blocked", null), { phase: st.phases[st.current].phase });
  archive_handoff(sid, b.phase);
  st.blocked_ack = archives(sid, b.phase).length;
  // The owner may have corrected worker_preference: replace the cached phases
  // and resume at the first phase that has no passed handoff on disk.
  st.phases = phases;
  const ci = phases.findIndex(ph => get(or(jload(sp("handoffs", sid + "-" + ph.phase + ".json")), {}), "status") !== "passed");
  st.current = ci < 0 ? phases.length - 1 : ci;
  // A retry starts the attempt count over: earlier failed handoffs stay archived for the record.
  const fa = {}; for (const ph of phases) fa[ph.phase] = maxFailed(sid, ph.phase);
  st.fail_ack = fa;
  st.owner_retry = { index: st.current, note: note() };
  st.resolution = { as: "retry", note: note(), at: iso(now()), phase: b.phase };
  st.state = "queued";
  jsave(sfile(sid), st);
  mark_decision(decision_path(sid, b.phase), "resolved: retry");
  print("RESOLVED " + sid + " retry " + S(b.phase) + " phases:" + phases.map(ph => ph.phase).join(",") + " next:" +
        S(phases[st.current].phase));
}

function do_failcap() {
  // A phase returned status failed too many times: hold the story for the owner with a decision item.
  const sid = need_story();
  const st = sload(sid);
  if (st.state === "blocked_needs_owner") {
    print("ALREADY blocked " + sid + " " + decision_path(sid, st.blocked.phase)); exit(10);
  }
  if (!["queued", "held", "in_flight"].includes(st.state))
    die("story " + sid + " is " + S(st.state) + "; failcap applies to a story whose current phase keeps failing");
  const ph = st.phases[st.current];
  const ack = pyInt(get(or(get(st, "fail_ack"), {}), ph.phase, 0));
  const tried = archives(sid, ph.phase).filter(x => x[0] > ack).map(x => x[1]);
  const cur = sp("handoffs", sid + "-" + ph.phase + ".json");
  if (exists(cur)) tried.push(cur);
  const failed = tried.map(path => [path, or(jload(path), {})]).filter(x => get(x[1], "status") === "failed");
  if (!failed.length) die("story " + sid + " phase " + S(ph.phase) + " has no failed handoff to hold");
  const last = failed[failed.length - 1][0];
  const texts = failed.map(([path, h], i) => "### Attempt " + (i + 1) + " (" + path + ")\n\n" + blocker_text(h)).join("\n\n");
  st.state = "blocked_needs_owner";
  st.blocked = { phase: ph.phase, worker: ph.worker, handoff: abspath(last), kind: "failed",
                 text: failed.map(x => blocker_text(x[1])).join("\n\n"), at: iso(now()), attempts: failed.length };
  pop(st, "owner_retry");
  const dp = decision_path(sid, ph.phase);
  writeText(dp,
    "# Decision: " + sid + " failed its " + S(ph.phase) + " phase " + failed.length + " times\n\n" +
    "- story: " + sid + " (" + S(get(st, "title", "")) + ")\n- phase: " + S(ph.phase) + "\n- lane: " + S(ph.worker) + "\n- failed attempts: " + failed.length +
    "\n- last handoff: " + abspath(last) + "\n- status: pending\n\n" +
    "## What the worker said each time\n\n" + texts + "\n\n" +
    "## Resolutions (run one after the owner answers, then restart the driver)\n\n" +
    "- Run the story again (re-reads its phases from the prd, so fix worker_preference first if the lane was wrong;\n" +
    "  the attempt count starts over):\n" +
    "  pipeline-conductor.sh resolve --state " + STATE + " --story " + sid + " --as retry --prd <prd.json> --note \"<owner's answer>\"\n" +
    "- Accept as a partial draft (dependents may start; passes is not set):\n" +
    "  pipeline-conductor.sh resolve --state " + STATE + " --story " + sid + " --as accepted-partial --note \"<owner's reason>\"\n" +
    "- Set the story and its dependents aside:\n" +
    "  pipeline-conductor.sh park --state " + STATE + " --story " + sid + " --note \"<why>\"\n");
  jsave(sfile(sid), st);
  print("PHASE_FAILCAP " + sid + " " + S(ph.phase) + " " + dp);
  exit(10);
}

function depsMap(p) {
  const deps = new Map();
  for (const s of p.userStories) if (typeof get(s, "id") === "string") deps.set(s.id, Array.from(or(get(s, "dependsOn"), [])));
  return deps;
}

function parked_closure(p, stories) {
  // Map{story id: [parked stories it depends on, directly or through others]} for unparked stories.
  const parked = new Set(); for (const [k, v] of stories) if (v.state === "parked") parked.add(k);
  const deps = depsMap(p);
  const out = new Map();
  for (const sid of deps.keys()) {
    if (parked.has(sid)) continue;
    const roots = new Set(), seen = new Set([sid]), todo = deps.get(sid).slice();
    while (todo.length) {
      const d = todo.pop();
      if (seen.has(d)) continue;
      seen.add(d);
      if (parked.has(d)) roots.add(d);
      for (const x of (deps.has(d) ? deps.get(d) : [])) todo.push(x);
    }
    if (roots.size) out.set(sid, sortedStr(roots));
  }
  return out;
}

function sync_parked(p) {
  // Hold every not-started dependent of a parked story as parked_dependency; release the rest.
  const stories = all_stories();
  const held = parked_closure(p, stories);
  for (const sid of sortedStr(held.keys())) {
    const roots = held.get(sid);
    const st = stories.has(sid) ? stories.get(sid) : null;
    if (st === null) {
      const s = story_of(p, sid);
      jsave(sfile(sid), { id: sid, title: get(s, "title", ""), phases: [], current: 0,
                          state: "parked_dependency", reroutes: 0, parked_by: roots });
      print("PARKED_DEPENDENCY " + sid + " by " + roots.join(","));
    } else if (st.state === "parked_dependency" && !eq(get(st, "parked_by"), roots)) {
      st.parked_by = roots; jsave(sfile(sid), st);
    }
  }
  for (const [sid, st] of stories) {
    if (st.state === "parked_dependency" && !held.has(sid)) {
      fs.unlinkSync(sfile(sid));
      print("RELEASED_DEPENDENCY " + sid);
    }
  }
}

function log_decision(kind, sid, kw) {
  // One JSON line per owner action in <state>/decisions.log.
  const rec = Object.assign({ at: iso(now()), action: kind, story: sid }, kw || {});
  fs.appendFileSync(sp("decisions.log"), pyDumps(rec, false) + "\n", "utf8");
}

function dependents_closure(p, sid, stories) {
  // Stories that depend on sid directly or through others and are not done (passes or a done state).
  const deps = depsMap(p);
  const done = new Set(p.userStories.filter(s => get(s, "passes") === true).map(s => s.id));
  for (const [k, v] of stories) if (DONE_STATES.includes(get(v, "state"))) done.add(k);
  const out = [];
  for (const k of deps.keys()) {
    if (k === sid || done.has(k)) continue;
    const seen = new Set(), todo = deps.get(k).slice();
    while (todo.length) {
      const d = todo.pop();
      if (seen.has(d)) continue;
      seen.add(d);
      if (d === sid) { out.push(k); break; }
      for (const x of (deps.has(d) ? deps.get(d) : [])) todo.push(x);
    }
  }
  return sortedStr(out);
}

// ---------- skip list ----------
const SKIPPABLE = ["queued", "held", "awaiting_go", "blocked_needs_owner", "parked_dependency"];

function do_skip() {
  const sid = need_story(); const p = prd_opt();
  const sk = or(jload(sp("skips.json"), {}), {});
  if (has(sk, sid)) { print("ALREADY skipped " + sid); return; }
  if (p === null) die("skip needs the prd to find the stories that depend on " + sid + ": pass --prd", 2);
  const s = story_of(p, sid);
  let st = jload(sfile(sid));
  if (st !== null && !SKIPPABLE.includes(get(st, "state")))
    die("story " + sid + " is " + S(get(st, "state")) + "; skip applies to a story that has not started or is " + SKIPPABLE.join(", "));
  const strands = dependents_closure(p, sid, all_stories());
  if (strands.length) {
    print("SKIP_STRANDS " + sid + " " + strands.length + ": " + strands.join(","));
    if (E.PC_FORCE !== "1")
      die("skipping " + sid + " strands " + strands.length + " stories that depend on it (" + strands.join(",") + "); they will not run. Repeat with --force");
  }
  sk[sid] = { note: note(), at: iso(now()), from: T(st) ? get(st, "state") : null, strands: strands };
  jsave(sp("skips.json"), sk);
  if (st === null) st = { id: sid, title: get(s, "title", ""), phases: [], current: 0, reroutes: 0 };
  st.skipped_from = sk[sid].from; st.state = "skipped";
  jsave(sfile(sid), st);
  log_decision("skip", sid, { note: note(), strands: strands });
  print("SKIPPED " + sid);
}

function do_unskip() {
  const sid = need_story();
  const sk = or(jload(sp("skips.json"), {}), {});
  if (!has(sk, sid)) { print("ALREADY unskipped " + sid); return; }
  const frm = get(pop(sk, sid), "from");
  const st = jload(sfile(sid));
  if (st !== null && get(st, "state") === "skipped") {
    if (frm === null || frm === undefined) fs.unlinkSync(sfile(sid));
    else { st.state = frm; pop(st, "skipped_from"); jsave(sfile(sid), st); }
  }
  jsave(sp("skips.json"), sk);
  log_decision("unskip", sid);
  print("UNSKIPPED " + sid + " " + S(or(frm, "not-started")));
}

// ---------- overlay ----------
function do_overlay() {
  const ov = overlay_load();
  if (SUB === "show") { print(JSON.stringify(ov, null, 1)); return; }
  if (SUB !== "set") die("overlay set|show", 2);
  const sid = need_story();
  const seq = seq_list(E.PC_SEQUENCE || "");
  if (!seq.length) die("overlay set needs --sequence <worker>,<worker>,...", 2);
  ov[sid] = { worker_sequence: seq, at: iso(now()) };
  jsave(sp("overlay.json"), ov);
  const st = or(jload(sfile(sid)), {});
  if (T(get(st, "started"))) print("NOTE " + sid + " already started; the new sequence applies on resolve --as retry");
  print("OVERLAY " + sid + " " + seq.join(","));
}

function import_overlay(path) {
  const d = jload(path);
  if (d === null) die("overlay file is not JSON: " + path);
  const ent = overlay_entries(d);
  if (!T(ent)) die("overlay file has no story worker_sequence entries: " + path);
  const ov = overlay_load();
  for (const [k, v] of Object.entries(ent)) ov[k] = { worker_sequence: v, at: iso(now()), from: abspath(path) };
  jsave(sp("overlay.json"), ov);
  eprint("OVERLAY_IMPORTED " + Object.keys(ent).length + " from " + path);
}

function classify_all(p) {
  // Check every story that is not passing or skipped, without writing story state. Exit 1 on any error.
  let errs = [], warns = []; const need = new Map();
  for (const s of p.userStories) {
    const sid = get(s, "id");
    if (typeof sid !== "string" || get(s, "passes") === true) continue;
    if (skipped(sid)) { print("SKIPPED " + sid); continue; }
    const [workers, src] = story_sequence(s);
    if (!T(workers)) {
      errs.push("story " + sid + " is unclassified: overlay set --state " + STATE + " --story " + sid + " --sequence <a>,<b>,..., " +
                "set worker_preference, or skip --state " + STATE + " --story " + sid);
      continue;
    }
    const [e, w] = sequence_problems(s, workers); errs = errs.concat(e); warns = warns.concat(w);
    warns = warns.concat(hint_notes(s, workers)[0], dep_lint(p, s));
    const rows = table_rows();
    if (rows !== null) {
      for (const wk of workers) if (!rows.has(wk)) { if (!need.has(wk)) need.set(wk, []); need.get(wk).push(sid); }
    }
    print("OK " + sid + " " + workers.join(",") + " (" + src + ")");
  }
  if (need.size) {
    errs.push("no lane in the worker table " + S(table_path()) + " for: " +
              Array.from(need).map(([w, ids]) => w + " (" + ids.join(",") + ")").join("; ") + ". Add a row for each and confirm the table again");
  }
  for (const w of warns) print("WARN " + w);
  for (const e of errs) print("ERROR " + e);
  if (errs.length) die("classify refused: " + errs.length + " error(s)");
}

const PARKABLE = ["queued", "held", "awaiting_go", "blocked_needs_owner", "failed_report"];

function do_park() {
  const sid = need_story(); const p = prd_opt();
  let st = jload(sfile(sid));
  st = T(st) ? migrate_legacy(st) : null;
  if (T(st) && st.state === "parked") { print("ALREADY parked " + sid); return; }
  let frm;
  if (st === null) {
    if (p === null) die("story " + sid + " has no state yet; pass --prd so park can find it", 2);
    const s = story_of(p, sid);
    if (get(s, "passes") === true) die("story " + sid + " already passes in the prd; nothing to park");
    st = { id: sid, title: get(s, "title", ""), phases: [], current: 0, reroutes: 0 };
    frm = null;
  } else if (!PARKABLE.includes(st.state)) {
    die("story " + sid + " is " + S(st.state) + "; park applies to a story that has not started or is " + PARKABLE.join(", "));
  } else {
    frm = st.state;
  }
  let closure;
  if (p === null) {
    print("PARK_CLOSURE " + sid + " unknown: no prd to read dependsOn from (pass --prd)");
    closure = [];
  } else {
    closure = dependents_closure(p, sid, all_stories());
    print("PARK_CLOSURE " + sid + " " + closure.length + ": " + (closure.join(",") || "none"));
    const limit = pyInt(E.PC_PARK_CONFIRM || 5);
    if (closure.length > limit && E.PC_FORCE !== "1")
      die("park " + sid + " would also park " + closure.length + " dependent stories (" + closure.join(",") + "), more than PC_PARK_CONFIRM=" + limit + "; " +
          "repeat with --force to park them");
  }
  log_decision("park", sid, { note: note(), closure: closure });
  st.parked = { from: frm, note: note(), at: iso(now()) };
  st.state = "parked";
  jsave(sfile(sid), st);
  const pk = jload(sp("parking.json"), { unparked: [] });
  if (pk.unparked.includes(sid)) { pk.unparked.splice(pk.unparked.indexOf(sid), 1); jsave(sp("parking.json"), pk); }
  if (frm === "blocked_needs_owner") mark_decision(decision_path(sid, st.blocked.phase), "parked");
  if (frm === "awaiting_go") mark_decision(go_path(sid), "parked");
  print("PARKED " + sid);
  if (T(p)) sync_parked(p);
}

function do_unpark() {
  const sid = need_story(); const p = prd_opt();
  const st = jload(sfile(sid));
  const pk = jload(sp("parking.json"), { unparked: [] });
  if (st === null || get(st, "state") !== "parked") {
    if (pk.unparked.includes(sid)) { print("ALREADY unparked " + sid); return; }
    die("story " + sid + " is " + (st !== null ? S(st.state) : "not started") + "; unpark applies only to a parked story");
  }
  const frm = get(or(get(st, "parked"), {}), "from");
  const releases = [];
  for (const [k, v] of all_stories()) if (v.state === "parked_dependency" && eq(or(get(v, "parked_by"), []), [sid])) releases.push(k);
  releases.sort(cmpStr);
  print("UNPARK_RELEASES " + sid + " " + releases.length + ": " + (releases.join(",") || "none"));
  log_decision("unpark", sid, { releases: releases });
  if (frm === null || frm === undefined) {
    fs.unlinkSync(sfile(sid));
  } else {
    st.state = frm; pop(st, "parked"); jsave(sfile(sid), st);
    if (frm === "blocked_needs_owner") mark_decision(decision_path(sid, st.blocked.phase), "pending");
    if (frm === "awaiting_go") mark_decision(go_path(sid), "pending");
  }
  pk.unparked.push(sid); jsave(sp("parking.json"), pk);
  print("UNPARKED " + sid + " " + S(or(frm, "not-started")));
  if (T(p)) sync_parked(p);
}

// ---------- reopen ----------
const STORE_RE = /(store|schema|migration|db\/)/i;

function store_paths(s) {
  return or(get(s, "files"), []).filter(f => typeof f === "string" && STORE_RE.test(f));
}

function reopen_pending(st) {
  const ro = or(get(st, "reopen"), {});
  return T(ro) && !T(get(ro, "routed")) && !T(get(ro, "done")) ? ro : {};
}

function is_checker(w) {
  // A reviewer or tester lane: reopen skips it when choosing the default phase.
  return /(^|[-_])(qa|test|tester|testing|review|reviewer|verifier)([-_]|$)/.test(w || "");
}

function archive_reopened(sid, phase) {
  const h = sp("handoffs", sid + "-" + phase + ".json");
  if (!exists(h)) return null;
  let n = 1;
  while (exists(sp("handoffs", sid + "-" + phase + ".reopened." + n + ".json"))) n += 1;
  const dst = sp("handoffs", sid + "-" + phase + ".reopened." + n + ".json");
  fs.renameSync(h, dst);
  return dst;
}

function verified_dependents(p, sid, stories) {
  // Stories that depend on sid, directly or through others, and are verified now.
  if (p === null) {
    const out = [];
    for (const [k, v] of stories) if (v.state === "verified" && or(get(v, "depends_on"), []).includes(sid)) out.push(k);
    return sortedStr(out);
  }
  const deps = depsMap(p);
  const out = [];
  for (const k of deps.keys()) {
    if (k === sid || get(or(stories.get(k), {}), "state") !== "verified") continue;
    const seen = new Set(), todo = deps.get(k).slice();
    while (todo.length) {
      const d = todo.pop();
      if (seen.has(d)) continue;
      seen.add(d);
      if (d === sid) { out.push(k); break; }
      for (const x of (deps.has(d) ? deps.get(d) : [])) todo.push(x);
    }
  }
  return sortedStr(out);
}

const REOPENABLE = ["verified", "accepted_partial"];

function do_reopen(by_gate) {
  by_gate = !!by_gate;
  const sid = need_story();
  if (!strip(note())) die("reopen needs --note <why the story goes back>", 2);
  let st = jload(sfile(sid));
  if (st === null) die("story " + sid + " has no state in " + STATE + "; nothing to reopen");
  st = migrate_legacy(st);
  const ro = or(get(st, "reopen"), {});
  if (!REOPENABLE.includes(st.state)) {
    if (T(ro) && !T(get(ro, "done")) && ["queued", "held", "in_flight", "awaiting_recheck"].includes(st.state)) {
      print("ALREADY reopened " + sid + " at " + S(get(ro, "phase")) + " (" + st.state + ")"); return;
    }
    die("story " + sid + " is " + S(st.state) + "; reopen applies only to a verified or accepted_partial story");
  }
  const phases = or(get(st, "phases"), []);
  if (!phases.length) die("story " + sid + " has no phases recorded; nothing to reopen");
  const fp = E.PC_FROM_PHASE || "";
  let idx;
  if (fp) {
    idx = phases.findIndex(ph => ph.phase === fp);
    if (idx < 0) die("story " + sid + " has no phase " + fp + " (phases: " + phases.map(ph => S(ph.phase)).join(",") + ")", 2);
  } else {
    idx = phases.findIndex(ph => !is_checker(ph.worker));
    if (idx < 0) idx = 0;
  }
  for (const ph of phases.slice(0, idx)) {
    if (get(or(jload(sp("handoffs", sid + "-" + ph.phase + ".json")), {}), "status") !== "passed")
      die("story " + sid + ": phase " + S(ph.phase) + " before " + S(phases[idx].phase) + " has no passed handoff; reopen from " + S(ph.phase) + " instead");
  }
  const p = prd_opt();
  const deps = verified_dependents(p, sid, all_stories());
  const archived = phases.slice(idx).map(ph => archive_reopened(sid, ph.phase)).filter(T);
  const frm = st.state;
  st.current = idx; st.state = "queued"; st.reroutes = 0;
  const prev = pop(st, "resolution", null);
  for (const k of ["rerouted_at", "unmet", "owner_retry", "blocked", "routed_at"]) pop(st, k);
  // The attempt count starts over: earlier failed handoffs stay archived for the record.
  const fa = {}; for (const ph of phases) fa[ph.phase] = maxFailed(sid, ph.phase);
  st.fail_ack = fa;
  st.blocked_ack = archives(sid, phases[idx].phase).length;
  st.reopen = { index: idx, phase: phases[idx].phase, note: note(), at: iso(now()), from: frm,
                by_gate: by_gate, verified_dependents: deps,
                archived: archived.map(abspath), count: pyInt(get(ro, "count", 0)) + 1 };
  if (T(prev)) st.reopen.previous_resolution = prev;
  jsave(sfile(sid), st);
  const rp = sp("report.md");
  if (exists(rp)) {
    const lines = splitlines(readText(rp)).filter(l => !l.startsWith("- " + sid + " "));
    writeText(rp, lines.join("\n") + (lines.length ? "\n" : ""));
  }
  print("REOPENED " + sid + " from:" + frm + " phase:" + S(phases[idx].phase) + " archived:" + archived.length + " verified-dependents:" + (deps.join(",") || "none"));
  const path = PRD || get(or(jload(sp("run.json"), {}), {}), "prd");
  if (p !== null && T(path)) {
    for (const s of p.userStories) {
      if (get(s, "id") === sid && get(s, "passes") === true) {
        s.passes = false;
        jsave(path, p);
        print("PASSES_CLEARED " + sid + " in " + abspath(path));
      }
    }
  }
}

function final_line() {
  const ss = all_stories(); const c = new Map();
  for (const v of ss.values()) c.set(v.state, (c.get(v.state) || 0) + 1);
  const n = k => c.get(k) || 0;
  const line = "FINAL: verified " + n("verified") + ", failed " + n("failed_report") + ", partial " + n("accepted_partial") +
    ", blocked " + n("blocked_needs_owner") + ", parked " + n("parked") + ", held " + n("held") + ", awaiting go " + n("awaiting_go") +
    ", interrupted " + n("interrupted") + ", unfinished " + (n("queued") + n("in_flight") + n("awaiting_recheck")) + ", gate " + S(gate().state);
  const extra = [];
  const il = interrupted_list(ss);
  if (il) extra.push("interrupted, routed first on the next driver start: " + il);
  const part = []; for (const [k, v] of ss) if (v.state === "accepted_partial") part.push(k);
  if (part.length) extra.push("partial drafts, passes not set: " + part.map(k =>
    k + " (unmet AC " + (get(or(get(ss.get(k), "resolution"), {}), "unmet", []).map(S).join(",") || "none") + ")").join(", "));
  for (const [k, v] of ss) {
    if (v.state === "parked") {
      const why = wsjoin(or(get(or(get(v, "parked"), {}), "note"), "no note"));
      const deps = [];
      for (const [d, w] of ss) if (w.state === "parked_dependency" && or(get(w, "parked_by"), []).includes(k)) deps.push(d);
      deps.sort(cmpStr);
      extra.push("parked " + k + " (" + why + "; holds " + (deps.join(", ") || "no dependents") + ")");
    }
  }
  for (const k of sortedStr(ss.keys())) {
    const v = ss.get(k);
    const ro = or(get(v, "reopen"), {});
    if (!T(ro)) continue;
    extra.push("reopened " + k + " at " + S(get(ro, "phase")) + " (" + wsjoin(get(ro, "note", "")) + ")");
    if (T(get(ro, "verified_dependents")))
      extra.push("verified before " + k + " was reopened: " + ro.verified_dependents.join(", "));
  }
  const sk = or(jload(sp("skips.json"), {}), {});
  for (const k of sortedStr(Object.keys(sk))) {
    const why = wsjoin(or(get(sk[k], "note"), "no note"));
    const st_ = or(get(sk[k], "strands"), []);
    extra.push("skipped " + k + " (" + why + (T(st_) ? "; strands " + st_.join(", ") : "") + ")");
  }
  const blk = []; for (const [k, v] of ss) if (v.state === "blocked_needs_owner") blk.push(k);
  if (blk.length) extra.push("blocked for the owner: " + blk.join(", "));
  const ag = []; for (const [k, v] of ss) if (v.state === "awaiting_go") ag.push(k);
  ag.sort(cmpStr);
  if (ag.length) extra.push("awaiting go: " + ag.map(k =>
    k + " (" + S(get(or(get(ss.get(k), "go_hold"), {}), "reason", "")) + "; run go --story " + k + ")").join(", "));
  return line + (extra.length ? "; " + extra.join("; ") : "");
}

// ---------- interrupt / stop ----------
function interrupt_pending(st) {
  // The interrupted record of a story whose interrupted phase has not been routed again, else {}.
  const it = or(get(st, "interrupted"), {});
  return isDict(it) && T(get(it, "phase")) && !T(get(it, "routed")) ? it : {};
}

function interrupted_list(ss) {
  ss = ss === undefined ? all_stories() : ss;
  return sortedStr(ss.keys()).filter(k => T(interrupt_pending(ss.get(k))))
    .map(k => k + " at " + S(interrupt_pending(ss.get(k)).phase) + " (" + S(get(interrupt_pending(ss.get(k)), "at", "?")) + ")").join(", ");
}

function lane_runs() {
  return new Map(Object.entries(or(jload(sp("lanes.json"), {}), {})));
}

function withdraw(lane, sid, ph) {
  if (!T(lane)) return false;
  const r = run(E.PC_HQ, ["lanes", "interrupt", lane, "--story", sid, "--phase", ph, "--json"], { timeout: 30000 });
  let ans; try { ans = JSON.parse(r.stdout); } catch (e) { return false; }
  const id = sid + "-" + ph;
  if ((get(ans, "withdrawn", []) || []).includes(id)) return true;
  return (get(ans, "already_picked_up", []) || []).includes(id) ? false : false;
}

function interrupted_aside(sid, phase) {
  const h = sp("handoffs", sid + "-" + phase + ".json");
  if (!exists(h)) return null;
  let n = 1;
  while (exists(sp("handoffs", sid + "-" + phase + ".interrupted." + n + ".json"))) n += 1;
  const dst = abspath(sp("handoffs", sid + "-" + phase + ".interrupted." + n + ".json"));
  fs.renameSync(h, dst);
  return dst;
}

function do_interrupt(reason) {
  let lanes = null;
  const ss = all_stories();
  for (const sid of sortedStr(ss.keys())) {
    const st = ss.get(sid);
    if (st.state !== "in_flight" || (STORY && sid !== STORY)) continue;
    const i = st.current; const ph = st.phases[i];
    const h = sp("handoffs", sid + "-" + ph.phase + ".json");
    const hd = jload(h);
    if (isDict(hd) && get(hd, "phase") === ph.phase && ["passed", "failed", "blocked"].includes(get(hd, "status"))) {
      // the phase finished; the next driver accepts it
      print("KEPT " + sid + " " + S(ph.phase) + " handoff-present"); continue;
    }
    const partial = interrupted_aside(sid, ph.phase);
    if (lanes === null) lanes = lane_runs();
    const gone = withdraw(lanes.has(ph.worker) ? lanes.get(ph.worker) : null, sid, ph.phase);
    st.state = "interrupted";
    st.interrupted = { phase: ph.phase, index: i, worker: ph.worker, at: iso(now()), reason: reason, withdrawn: gone };
    if (partial) st.interrupted.partial_handoff = partial;
    jsave(sfile(sid), st);
    print("INTERRUPTED " + sid + " " + S(ph.phase) + " " + (gone ? "withdrawn" : "picked_up"));
  }
}

function driver_alive() {
  let pid;
  try {
    const t = strip(readText(sp("driver", "driver.pid")));
    pid = pyInt(t);
  } catch (e) { return false; }
  try { process.kill(pid, 0); return true; } catch (e) { return false; }
}

function do_stop() {
  fs.mkdirSync(sp("driver"), { recursive: true });
  const rec = { kind: "stop", at: iso(now()), note: note() };
  if (driver_alive()) {
    jsave(sp("driver", "stop.json"), rec);
    print("STOP_REQUESTED " + sp("driver", "stop.json")); return;
  }
  do_interrupt("stop: " + (note() || "parent stop command"));
  const lanes = Array.from(lane_runs().values());
  for (const lane of lanes) run(E.PC_HQ, ["lanes", "stop", lane], { timeout: 30000 });
  let listed = null;
  try {
    const parsed = JSON.parse(run(E.PC_HQ, ["lanes", "list", "--json"], { timeout: 30000 }).stdout || "{}");
    listed = Array.isArray(parsed) ? parsed : get(parsed, "lanes", null);
  } catch (e) { listed = null; }
  const stopped = Array.isArray(listed) && lanes.every(id => {
    const row = listed.find(item => isDict(item) && get(item, "lane_id") === id);
    return !row || get(get(row, "loop", {}), "state") === "stopped";
  });
  if (stopped) jsave(sp("lanes.json"), {});
  print(stopped ? "STOPPED no live driver" : "STOP_REQUESTED no live driver; waiting for every loop lane to stop");
}

// ---------- tick ----------
const ACTIVE_STATES = ["queued", "in_flight", "held", "awaiting_recheck"];

function do_tick(p) {
  const m = wt_mapping(E.PC_WT); const sb = E.PC_STORY_BRANCHES === "1";
  const prev = or(jload(sp("run.json"), {}), {});
    const runj = { ...prev, prd: abspath(PRD), worktrees: m, story_branches: sb,
                 allow_repos_worktree: E.PC_ALLOW_REPOS === "1",
                 table: E.PC_TABLE ? abspath(E.PC_TABLE) : get(prev, "table", "") };
  let cap = pyInt(E.PC_MAX_STORIES); let capnote = "";
  if (!sb) {
    const n = new Set(Object.values(m)).size || 1;
    if (cap > n) {
      capnote = "MAX_STORIES " + n + " PC_MAX_STORIES=" + cap + " lowered: " + n + " worktree(s) in play and stories of a repo share one " +
                "feature branch, so one story is in flight per repo branch at a time";
      cap = n;
    }
  }
  runj.max_stories_note = capnote;
  jsave(sp("run.json"), runj);
  if (capnote && get(prev, "max_stories_note") !== capnote) print(capnote);
  sync_parked(p);
  for (const [sid, v] of all_stories()) {
    if (v.state === "interrupted") {
      // a lane that was mid-call when the run stopped may have written its handoff since: keep it as the
      // prior partial handoff, so the resumed phase is not accepted on the stale one
      const late = interrupted_aside(sid, v.interrupted.phase);
      if (late) v.interrupted.partial_handoff = late;
      v.state = "queued"; v.interrupted.resuming = true; jsave(sfile(sid), v);
    }
  }
  const stories = all_stories();
  const rank = k => T(interrupt_pending(stories.get(k))) ? 0 : T(reopen_pending(stories.get(k))) ? 1 : 2;
  const order = Array.from(stories.keys()).sort((a, b) => (rank(a) - rank(b)) || cmpStr(a, b));
  for (const sid of order) {
    const st = stories.get(sid);
    if (st.state === "queued") {
      if ([11, 12].includes(run_sub(["route", "--prd", PRD, "--state", STATE, "--story", sid]))) return;
    }
  }
  const active = Array.from(all_stories().values()).filter(v => ACTIVE_STATES.includes(v.state));
  const busy = new Set(active.map(v => get(v, "worktree")));
  let room = Math.max(0, cap - active.length);
  for (const sid of eligible(p)) {
    if (room <= 0) break;
    if (!sb) {
      const known = or(jload(sfile(sid)), {});
      const want = T(m) ? pick_worktree(p, resolve_repo(p, story_of(p, sid))[0], m) : get(known, "worktree");
      if (T(want) && busy.has(want)) continue;
    }
    const [ws] = story_sequence(story_of(p, sid));
    const rows = table_rows();
    const miss = (ws || []).filter(w => rows !== null && !rows.has(w));
    if (miss.length) {
      print("NO_LANE " + sid + " " + phaseOf(miss[0]) + " " + miss[0] + " not in the worker table " + S(table_path()));
      return;
    }
    if (do_classify(p, sid, E.PC_WT) === null) continue;
    if ([11, 12].includes(run_sub(["route", "--prd", PRD, "--state", STATE, "--story", sid]))) return;
    const st = or(jload(sfile(sid)), {});
    if (ACTIVE_STATES.includes(get(st, "state"))) {
      room -= 1; busy.add(get(st, "worktree"));
    }
  }
  if (gate().state === "due") print("RUN_GATE");
  if (gate().state === "failed") print("GATE_FAILED");
}

function run_sub(args) {
  const r = run(pjoin(E.PC_SELF_DIR, "pipeline-conductor.sh"), args);
  owrite(r.stdout);
  if (![0, 3, 10, 11, 12].includes(r.returncode) && r.stderr) owrite("ERROR " + r.stderr);
  return r.returncode;
}

// ---------- dispatch ----------
function main() {
  if (CMD === "next") {
    const ids = eligible(prd());
    const lim = E.PC_LIMIT;
    for (const sid of (lim ? ids.slice(0, pyInt(lim)) : ids)) print(sid);
  } else if (CMD === "classify") {
    if (E.PC_OVERLAY) import_overlay(E.PC_OVERLAY);
    if (!STORY) {
      classify_all(prd());
    } else {
      const st = do_classify(prd(), STORY, E.PC_WT);
      for (const ph of or(get(or(st, {}), "phases"), [])) print(S(ph.phase) + "\t" + S(ph.worker));
    }
  } else if (CMD === "overlay") {
    do_overlay();
  } else if (CMD === "skip") {
    do_skip();
  } else if (CMD === "unskip") {
    do_unskip();
  } else if (CMD === "route") {
    do_route(prd(), need_story());
  } else if (CMD === "accept") {
    do_accept(need_story());
  } else if (CMD === "recheck") {
    do_recheck(prd(), need_story());
  } else if (CMD === "gate") {
    if (SUB === "tick") {
      if (gate_tick()) print("RUN_GATE");
    } else if (SUB === "status") {
      const g = gate(); print(S(g.state) + " completed=" + pyInt(g.completed) + " every=" + E.PC_GATE_EVERY);
    } else if (SUB === "result") {
      const res = E.PC_RESULT;
      if (!["pass", "fail"].includes(res)) die("gate result needs pass|fail", 2);
      if (res === "fail" && STORY) {
        do_reopen(true);
        const g = gate(); g.state = "reopened"; g.note = E.PC_NOTE;
        const ro = or(get(g, "reopened"), []);
        g.reopened = ro.concat(!ro.includes(STORY) ? [STORY] : []);
        jsave(sp("gate.json"), g);
        print("GATE reopened " + STORY);
      } else {
        const g = gate(); g.state = res === "pass" ? "ok" : "failed"; g.note = E.PC_NOTE;
        if (res === "pass") pop(g, "reopened");
        jsave(sp("gate.json"), g);
        print("GATE " + g.state);
      }
    } else die("gate tick|status|result", 2);
  } else if (CMD === "release") {
    do_release();
  } else if (CMD === "report") {
    if (SUB === "story") {
      const st = sload(need_story());
      if (!story_report(STORY, st) && !["verified", "failed_report", "accepted_partial"].includes(st.state))
        die("story " + STORY + " is not finished (" + S(st.state) + ")");
    } else if (SUB === "final") {
      const rp = sp("report.md");
      let lines = exists(rp) ? splitlines(readText(rp)) : [];
      lines = lines.filter(l => !l.startsWith("FINAL:"));
      lines.push(final_line());
      writeText(rp, lines.join("\n") + "\n");
      print(lines[lines.length - 1]);
    } else die("report story|final", 2);
  } else if (CMD === "tick") {
    do_tick(prd());
  } else if (CMD === "resolve") {
    do_resolve();
  } else if (CMD === "failcap") {
    do_failcap();
  } else if (CMD === "park") {
    do_park();
  } else if (CMD === "unpark") {
    do_unpark();
  } else if (CMD === "reopen") {
    do_reopen();
  } else if (CMD === "go") {
    do_go();
  } else if (CMD === "worktree") {
    do_worktree();
  } else if (CMD === "interrupt") {
    do_interrupt(note() || "interrupt");
  } else if (CMD === "stop") {
    do_stop();
  } else {
    die("unknown subcommand: " + CMD, 2);
  }
}

try {
  main();
} catch (e) {
  eprint("Traceback (most recent call last):\n" + (e && e.stack ? e.stack : String(e)));
  exit(1);
}
exit(0);
JS
