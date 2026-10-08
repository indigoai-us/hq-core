#!/bin/bash
# Grilling engine helper: parse a question set, compute the open frontier,
# and produce the count object the engine returns.
# Format: .claude/skills/_shared/questions/FORMAT.md
#
# Usage:
#   frontier.sh frontier <question_set> [--known id,id] [--answered id,id]
#     Prints the ids of open decision questions whose depends_on are all
#     resolved, one per line, in file order. Facts are never printed; they
#     count as resolved once their own depends_on are resolved.
#
#   frontier.sh count <question_set> [--known id,id]
#     Walks the set round by round as if the user answered every frontier
#     decision, then prints the count object as JSON:
#     {"asked":N,"skipped_known":N,"skipped_fact":N,"by_tier":{...}}
#     by_tier counts asked questions only.
#
# Exit 0 on success, 2 on a malformed set or dependency cycle.

set -euo pipefail

usage() { sed -n '2,17p' "$0" >&2; exit 2; }

[ $# -ge 2 ] || usage
cmd="$1"; set_path="$2"; shift 2
known=""; answered=""
while [ $# -gt 0 ]; do
  case "$1" in
    --known) known="${2:-}"; shift 2 ;;
    --answered) answered="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
case "$cmd" in frontier|count) ;; *) usage ;; esac
[ -f "$set_path" ] || { echo "frontier.sh: no such question set: $set_path" >&2; exit 2; }

exec python3 - "$cmd" "$set_path" "$known" "$answered" <<'PY'
import json, re, sys

cmd, path, known_arg, answered_arg = sys.argv[1:5]
TIERS = ("strategic", "architecture", "quality")
KINDS = ("decision", "fact")

def die(msg):
    sys.stderr.write("frontier.sh: %s\n" % msg)
    sys.exit(2)

qs, order, cur = {}, [], None
with open(path) as fh:
    for line in fh:
        m = re.match(r"^##\s+([A-Za-z0-9_-]+)\s*$", line)
        if m:
            cur = m.group(1)
            if cur in qs:
                die("duplicate id %s" % cur)
            qs[cur] = {}
            order.append(cur)
            continue
        if line.startswith("#"):
            cur = None
            continue
        m = re.match(r"^-\s+([a-z_]+):\s*(.*?)\s*$", line)
        if cur and m:
            qs[cur][m.group(1)] = m.group(2)

if not order:
    die("no questions found in %s" % path)

for qid in order:
    q = qs[qid]
    if q.get("tier") not in TIERS:
        die("%s: tier must be one of %s" % (qid, "|".join(TIERS)))
    if q.get("kind") not in KINDS:
        die("%s: kind must be decision or fact" % qid)
    dep = q.get("depends_on")
    if dep is None or not (dep.startswith("[") and dep.endswith("]")):
        die("%s: depends_on must be a bracketed list" % qid)
    q["deps"] = [d.strip() for d in dep[1:-1].split(",") if d.strip()]
    for d in q["deps"]:
        if d not in qs:
            die("%s: depends_on unknown id %s" % (qid, d))
    if q["kind"] == "decision":
        opts = [o.strip() for o in q.get("options", "").split("|") if o.strip()]
        if not 2 <= len(opts) <= 4:
            die("%s: decision needs 2 to 4 options" % qid)
        if q.get("recommended") not in opts:
            die("%s: recommended must be one of the options" % qid)

def ids(arg):
    return set(x.strip() for x in arg.split(",") if x.strip())

known = ids(known_arg)
for k in known:
    if k not in qs:
        die("--known names unknown id %s" % k)
answered = ids(answered_arg)

def resolve_facts(resolved):
    # Facts are looked up, never asked: they resolve as soon as their deps do.
    changed = True
    while changed:
        changed = False
        for qid in order:
            q = qs[qid]
            if qid in resolved or q["kind"] != "fact":
                continue
            if all(d in resolved for d in q["deps"]):
                resolved.add(qid)
                changed = True

def frontier(resolved):
    return [qid for qid in order
            if qid not in resolved
            and qs[qid]["kind"] == "decision"
            and all(d in resolved for d in qs[qid]["deps"])]

if cmd == "frontier":
    resolved = set(known) | answered
    resolve_facts(resolved)
    for qid in frontier(resolved):
        print(qid)
    sys.exit(0)

resolved = set(known)
counts = {"asked": 0, "skipped_known": len(known), "skipped_fact": 0,
          "by_tier": {t: 0 for t in TIERS}}
while True:
    resolve_facts(resolved)
    batch = frontier(resolved)
    if not batch:
        break
    for qid in batch:
        counts["asked"] += 1
        counts["by_tier"][qs[qid]["tier"]] += 1
        resolved.add(qid)

unresolved = [q for q in order if q not in resolved]
if unresolved:
    die("dependency cycle or unreachable questions: %s" % ",".join(unresolved))
counts["skipped_fact"] = sum(1 for q in order if qs[q]["kind"] == "fact" and q not in known)
print(json.dumps(counts, sort_keys=True))
PY
