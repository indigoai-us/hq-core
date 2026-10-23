#!/usr/bin/env bash
# hq-core: public
# US-003: grade-withheld propose and compose packets.
# Uses a temp directory only. Does not read a live companies/ directory.
# Does not call a model.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PACKETS="$ROOT/core/scripts/eval-loop/packets.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# The ledger accepts only the HQ root's own companies directory. The suite
# temp dir is that root, so a caller HQ_ROOT or CLAUDE_PROJECT_DIR cannot
# point compose at a live checkout.
export HQ_ROOT="$TMP"
unset CLAUDE_PROJECT_DIR

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$PACKETS" ] || fail "missing $PACKETS"

# Review round 2, finding 3: the surface test is executable and runs in CI.
[ -x "$ROOT/core/scripts/tests/eval-loop-surface.test.sh" ] || fail "eval-loop-surface.test.sh is not executable"
grep -q 'bash core/scripts/tests/eval-loop-surface.test.sh' "$ROOT/.github/workflows/pr-checks.yml" ||
  fail "eval-loop-surface.test.sh is not wired into pr-checks"
# Review of #1417, critical 4: this test runs in CI.
[ -x "$ROOT/core/scripts/tests/eval-loop-packets.test.sh" ] || fail "eval-loop-packets.test.sh is not executable"
grep -q 'bash core/scripts/tests/eval-loop-packets.test.sh' "$ROOT/.github/workflows/pr-checks.yml" ||
  fail "eval-loop-packets.test.sh is not wired into pr-checks"

# This story does not call a model or start a lane.
if grep -E -n 'urllib|requests|httpx|openai|anthropic|subprocess|socket' "$PACKETS" >/dev/null; then
  fail "packets.py reaches outside the process"
fi

python3 - "$PACKETS" "$TMP" <<'PY'
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]).resolve().parent))
import hashlib
import packets
import ledger
import surface

tmp = Path(sys.argv[2])
companies = tmp / "companies"
companies.mkdir(parents=True, exist_ok=True)
# Depth is company-wide. Each independent compose gets its own company unless
# the caller reuses one and passes the parent run id. The session lock is a
# temp meta.yaml. It is not the live HQ session.
session_id = "eval-packets-test"
meta_path = tmp / "workspace" / "sessions" / session_id / "meta.yaml"
meta_path.parent.mkdir(parents=True, exist_ok=True)
os.environ["HQ_SESSION_ID"] = session_id
os.environ["HQ_HQ_SESSION_NO_CLI"] = "1"
manifest_companies = set()
_compose_n = 0

def write_manifest():
    lines = ["companies:"]
    for slug in sorted(manifest_companies):
        lines.append(f"  {slug}:")
        lines.append(f"    name: {slug}")
    (companies / "manifest.yaml").write_text("\n".join(lines) + "\n", encoding="utf-8")

def bind_company(company):
    if company not in manifest_companies:
        manifest_companies.add(company)
        write_manifest()
    (companies / company).mkdir(exist_ok=True)
    meta_path.write_text(f"company_slug: {company}\ncompany_slugs: {company}\n", encoding="utf-8")

def ledger_state(company, class_id):
    path = companies / company / "eval-library" / class_id / "ledger.json"
    return json.loads(path.read_text(encoding="utf-8"))

def plan(company, class_id, k, parent_run_id=None):
    """Plan one run through the ledger. Compose never plans."""
    bind_company(company)
    planned = ledger.plan_run(
        k,
        companies_root=str(companies),
        company=company,
        class_id=class_id,
        session_company=company,
        parent_run_id=parent_run_id,
    )
    return planned["run_id"]

def ledger_bytes(company, class_id):
    path = companies / company / "eval-library" / class_id / "ledger.json"
    return path.read_bytes() if path.exists() else None

def entry_labels(company, class_id):
    return [entry["label"] for entry in ledger_state(company, class_id)["entries"]]

_class_runs = {}
_last = {}

def compose(diff, docs, class_id=None, company=None, run_id=None, out=None):
    """Compose on a fresh company unless the caller reuses one.

    Without ``run_id`` the helper plans one root run per class, at the
    deliverables' k when that k is legal and at k=1 otherwise, and reuses it
    for later calls on that class. ``assert_untouched`` then checks that a
    refused compose left the ledger file byte for byte as it was.
    """
    global _compose_n
    _compose_n += 1
    cid = f"pkt{_compose_n:03d}" if class_id is None else class_id
    co = cid if company is None else company
    bind_company(co)
    if run_id is None:
        if (co, cid) not in _class_runs:
            first = docs[0].get("k") if isinstance(docs, list) and docs and isinstance(docs[0], dict) else None
            k = first if type(first) is int and first in (1, 2) else 1
            _class_runs[(co, cid)] = plan(co, cid, k)
        run_id = _class_runs[(co, cid)]
    _last["key"] = (co, cid)
    _last["bytes"] = ledger_bytes(co, cid)
    return packets.compose_packet(
        diff,
        docs,
        companies_root=str(companies),
        company=co,
        class_id=cid,
        session_company=co,
        run_id=run_id,
        out=out,
    )

def assert_untouched(message):
    co, cid = _last["key"]
    if ledger_bytes(co, cid) != _last["bytes"]:
        raise SystemExit(message)
    if ledger_bytes(co, cid) is not None and entry_labels(co, cid):
        raise SystemExit(message)


incumbent = {"skills/keep.md": b"KEEP", "policies/rule.md": b"RULE"}
snapshot = dict(incumbent)

# Two invalid patches: retry once, then keep the incumbent and record both reasons.
result = packets.plan_patches(
    incumbent,
    [
        {"skills/../../outside": "nope"},
        {"/etc/passwd": "nope"},
    ],
)
if result["fell_back"] is not True:
    raise SystemExit("two invalid patches were accepted")
if result["tree"] != snapshot:
    raise SystemExit(f"incumbent bytes changed: {result['tree']!r}")
if incumbent != snapshot:
    raise SystemExit("plan_patches mutated the incumbent mapping")
reason = result["reason"]
if reason != "attempt 1: invalid_path; attempt 2: invalid_path":
    raise SystemExit(f"retry did not record both reason codes: {reason}")
if len(result["attempts"]) != 2:
    raise SystemExit(f"expected one retry, got {result['attempts']!r}")

# The first valid patch is kept. The second attempt is not applied.
result = packets.plan_patches(
    incumbent,
    [
        {"skills/keep.md": "NEW"},
        {"skills/keep.md": "LATER"},
    ],
)
if result["fell_back"] is not False:
    raise SystemExit("a valid patch fell back")
if result["tree"]["skills/keep.md"] != b"NEW":
    raise SystemExit("first valid patch was not kept")
if result["tree"]["policies/rule.md"] != b"RULE":
    raise SystemExit("omitted file did not inherit the incumbent")
if incumbent["skills/keep.md"] != b"KEEP":
    raise SystemExit("valid patch mutated the incumbent mapping")

# An invalid patch is retried. The second, valid patch applies.
result = packets.plan_patches(
    incumbent,
    [
        {"skills/../../outside": "nope"},
        {"skills/keep.md": "NEW"},
    ],
)
if result["tree"]["skills/keep.md"] != b"NEW" or result["tree"]["policies/rule.md"] != b"RULE":
    raise SystemExit("retry did not apply the valid patch")
if result["attempts"] != ["attempt 1: invalid_path"]:
    raise SystemExit("first failure was not recorded")

# Two grader-verdict patches are invalid. The incumbent is kept.
result = packets.plan_patches(
    incumbent,
    [
        {"skills/a.md": "deterministic_eval_summary"},
        {"skills/b.md": '"passed_count"'},
    ],
)
if result["fell_back"] is not True or result["tree"] != snapshot:
    raise SystemExit("grader-verdict patch was stored")
if result["reason"] != "attempt 1: grader_marker; attempt 2: grader_marker":
    raise SystemExit(f"grader rejection was not recorded: {result['reason']}")

try:
    packets.plan_patches(incumbent, [{}, {}, {}])
except packets.PacketError:
    pass
else:
    raise SystemExit("a third patch attempt was allowed")
if incumbent != snapshot:
    raise SystemExit("refused third attempt mutated the incumbent")

# Work text is refused before a packet exists. The check is case-insensitive.
for text in ("the score is hidden", "Evaluation notes", "a Grader wrote this", "see the RUBRIC", "benchmark set"):
    try:
        packets.build_packet(text, [])
    except packets.PacketError:
        pass
    else:
        raise SystemExit(f"accepted banned work text: {text}")

packet = packets.build_packet("Write the weekly recap.", [])
if packet["work"] != "Write the weekly recap.":
    raise SystemExit("clean work text was rewritten")
if packet["runs"] != []:
    raise SystemExit("clean packet invented a run")

record = {
    "label": "incumbent",
    "run_id": "run-1",
    "ok": True,
    "delivered": False,
    "cost": 1.25,
    "error": "",
}
# A record with any key outside the allowlist is refused. A score key is
# never read into a view, and the refusal does not echo the key name.
for extra in ("n_passed", "n_criteria", "frac", "all_pass", "exit_status", "run_dir", "wall_s", "fraction", "nPassed", "gradeResult"):
    try:
        packets.proposer_view({**record, extra: 3})
    except packets.PacketError as exc:
        if extra in str(exc):
            raise SystemExit(f"refusal echoed the key name: {exc}")
    else:
        raise SystemExit(f"record with {extra} was accepted")
view = packets.proposer_view(record)
if set(view) != {"label", "run_id", "ok", "delivered", "error"}:
    raise SystemExit(f"proposer view fields drifted: {sorted(view)}")
encoded = json.dumps(view)
for banned in ("n_passed", "n_criteria", "all_pass", '"frac"', "exit_status", "run_dir", "cost", "1.25"):
    if banned in encoded:
        raise SystemExit(f"proposer view contains {banned}")

# Review round 3, finding 2: cost is never read, so it cannot carry a grade.
priced = {key: value for key, value in record.items() if key != "cost"}
for costed in ({**record, "cost": 0.75}, {**priced, "cost_usd": 0.75}, priced):
    costed_view = packets.proposer_view(costed)
    if "cost" in costed_view or "0.75" in json.dumps(costed_view):
        raise SystemExit(f"cost reached the proposer view: {costed_view}")
    if costed_view != view:
        raise SystemExit(f"cost changed the proposer view: {costed_view}")

# ok is process success. It must equal error == "", so it carries no bit of its own.
for mismatch in ({**record, "ok": False}, {**record, "ok": True, "error": "timeout"}):
    try:
        packets.proposer_view(mismatch)
    except packets.PacketError:
        pass
    else:
        raise SystemExit(f"ok that disagrees with error was accepted: {mismatch}")
failed = packets.proposer_view({**record, "ok": False, "error": "timeout"})
if failed["ok"] is not False or failed["error"] != "timeout":
    raise SystemExit(f"failed run view is wrong: {failed}")

# label and run_id are minted. Harness-chosen slugs never reach a view or packet.
leaky_ids = [
    {**record, "label": "frac0p75", "run_id": "r-3of4"},
    {**record, "label": "7061737320333f34", "run_id": "p3-f1"},
    {**record, "label": "frac0p75", "run_id": "run-9"},
]
minted = packets.build_packet("Write the weekly recap.", leaky_ids)
minted_text = json.dumps(minted)
for slug in ("frac0p75", "r-3of4", "7061737320333f34", "p3-f1", "run-9", "incumbent"):
    if slug in minted_text:
        raise SystemExit(f"harness slug {slug!r} reached the packet")
if [(run["label"], run["run_id"]) for run in minted["runs"]] != [("arm-1", "run-1"), ("arm-2", "run-2"), ("arm-1", "run-3")]:
    raise SystemExit(f"minted ids are wrong: {minted['runs']}")
if view["label"] != "arm-1" or view["run_id"] != "run-1":
    raise SystemExit(f"single view ids are not minted: {view}")

# Composer: harness diff and anonymized text. No check exit status, no label.
diff = "--- a/skills/recap.md\n+++ b/skills/recap.md\n@@\n-old\n+new\n"
docs = [
    {
        "label": "probe-a",
        "task_id": "class-001",
        "k": 1,
        "mode": "probe",
        "text": "class-001|1|probe wrote probe-a into the recap.",
    }
]
# A deliverable with a check exit status or a score key is refused before
# the ledger is written. The refusal does not echo the key name.
for extra in ("exit_status", "n_passed", "frac", "verdict"):
    try:
        compose(diff, [{**docs[0], extra: 0}], class_id="extrakey", company="extrakey")
    except packets.PacketError as exc:
        if extra in str(exc):
            raise SystemExit(f"refusal echoed the key name: {exc}")
    else:
        raise SystemExit(f"deliverable with {extra} was composed")
    assert_untouched("refused deliverable key wrote to the ledger")
composed = compose(diff, docs)
if composed["harness_diff"] != diff:
    raise SystemExit("harness diff was dropped")
body = composed["deliverables"][0]["text"]
if body != "candidate-1 wrote candidate-1 into the recap.":
    raise SystemExit(f"deliverable was not anonymized: {body}")
if composed["deliverables"][0]["id"] != "candidate-1":
    raise SystemExit("anonymous id drifted")
encoded = json.dumps(composed)
for banned in ("exit_status", "probe-a", "class-001|1|probe", "n_passed"):
    if banned in encoded:
        raise SystemExit(f"composer packet contains {banned}")

# A marker is rejected before a destination file exists.
dest = tmp / "stored.json"
tree = {"skills/a.md": b"see deterministic_eval_summary"}
try:
    packets.validated_tree(tree)
except packets.PacketError:
    pass
else:
    raise SystemExit("grader-verdict tree was accepted")
if dest.exists():
    raise SystemExit("rejected tree was stored")

clean = packets.validated_tree({"skills/a.md": b"hello", "policies/b.md": b"rule"})
if clean["policies/b.md"] != b"rule":
    raise SystemExit("validated tree dropped an incumbent file")

DIFF = "--- a/skills/recap.md\n+++ b/skills/recap.md\n@@\n-old\n+new\n"
base_doc = {
    "label": "probe-a",
    "task_id": "class-001",
    "k": 1,
    "mode": "probe",
}

# Deliverable text is scanned, not only the packet's keys.
graded = '{"pass_rate": 0.5, "passed_count": 3} deterministic_eval_summary all 4 rubric items PASS'
try:
    compose(DIFF, [{**base_doc, "text": graded}])
except packets.PacketError:
    pass
else:
    raise SystemExit("grader text in a deliverable was composed")

# A quoted grade key inside the deliverable string is visible before JSON encoding.
try:
    compose(DIFF, [{**base_doc, "text": '{"frac": 0.5}'}])
except packets.PacketError:
    pass
else:
    raise SystemExit("nested frac was composed")

# Free-text error is not a side channel for the grade.
graded_error = dict(record)
graded_error["error"] = "3/4 criteria passed; frac=0.75"
try:
    packets.proposer_view(graded_error)
except packets.PacketError:
    pass
else:
    raise SystemExit("grade in error was copied into the proposer view")

try:
    packets.build_packet("3/4 criteria passed; frac=0.75", [])
except packets.PacketError:
    pass
else:
    raise SystemExit("grade in work text was packed")

# A harness diff may name exit_code, exit_status, or all_pass. Those are not grades.
diff_ok = "--- a/skills/recap.md\n+++ b/skills/recap.md\n@@\n-  return exit_code\n-  return exit_status\n-  return all_pass\n+  return 0\n"
kept = compose(diff_ok, [{**base_doc, "text": "wrote the recap."}])
if "exit_code" not in kept["harness_diff"] or "exit_status" not in kept["harness_diff"] or "all_pass" not in kept["harness_diff"]:
    raise SystemExit("legitimate exit status names were refused")

# The same diff is still refused when the deliverable text carries a grade.
try:
    compose(diff_ok, [{**base_doc, "text": graded}])
except packets.PacketError:
    pass
else:
    raise SystemExit("a clean diff excused grade text")

# File names and file bytes are scanned, not only serialized keys.
try:
    packets.validated_tree({"skills/pass_rate.md": b"hello"})
except packets.PacketError:
    pass
else:
    raise SystemExit("grade file name was accepted")
try:
    packets.validated_tree({"skills/a.md": b'{"frac": 0.5}'})
except packets.PacketError:
    pass
else:
    raise SystemExit("nested frac in file bytes was accepted")
exit_tree = packets.validated_tree({"skills/keep.md": b"return exit_code"})
if exit_tree["skills/keep.md"] != b"return exit_code":
    raise SystemExit("exit_code in a skill file was refused")

# k above the ledger cap is refused with the ledger's own error.
try:
    ledger.plan_run(3)
except ledger.LedgerError as exc:
    ledger_msg = str(exc)
else:
    raise SystemExit("ledger accepted k=3")
try:
    compose(DIFF, [{**base_doc, "k": 3, "text": "wrote the recap."}], class_id="kthree", company="kthree")
except packets.PacketError as exc:
    if ledger_msg not in str(exc):
        raise SystemExit(f"compose did not use the ledger cap: {exc}")
else:
    raise SystemExit("compose accepted k=3")
assert_untouched("k=3 compose wrote to the ledger")
k2 = compose(DIFF, [{**base_doc, "k": 2, "text": "wrote the recap."}], class_id="ktwo", company="ktwo")
if k2["deliverables"][0]["text"] != "wrote the recap.":
    raise SystemExit("k=2 deliverable was rewritten")
k2_state = ledger_state("ktwo", "ktwo")
k2_run = k2_state["runs"][0]
if k2_state.get("depth") != 2 or len(k2_state["runs"]) != 1 or k2_run.get("parent_run_id") is not None:
    raise SystemExit(f"k=2 compose added a plan: depth={k2_state.get('depth')}")
if entry_labels("ktwo", "ktwo") != [ledger.format_label("ktwo", k2_run["run_id"], "session:compose-1")]:
    raise SystemExit(f"k=2 compose did not record compose-1: {entry_labels('ktwo', 'ktwo')}")

# Review of #1417, critical 2: compose records its session on the run the
# harness already planned. It never plans a second run, so a normal
# plan-then-compose on a fresh company works and the depth stays at k.
c2_run = plan("planco", "planco", 1)
c2_before = ledger_state("planco", "planco")
c2 = compose(DIFF, [{**base_doc, "k": 1, "text": "wrote the recap."}], class_id="planco", company="planco", run_id=c2_run)
if c2["deliverables"][0]["text"] != "wrote the recap.":
    raise SystemExit("plan-then-compose deliverable was rewritten")
c2_after = ledger_state("planco", "planco")
if c2_after["runs"] != c2_before["runs"] or c2_after.get("depth") != 1:
    raise SystemExit(f"compose changed the planned runs: {c2_after['runs']}")
if entry_labels("planco", "planco") != [ledger.format_label("planco", c2_run, "session:compose")]:
    raise SystemExit(f"compose did not record session:compose: {entry_labels('planco', 'planco')}")
try:
    compose(DIFF, [{**base_doc, "k": 1, "text": "wrote the recap."}], class_id="planco", company="planco", run_id=c2_run)
except packets.PacketError as exc:
    if "compose stages are used" not in str(exc):
        raise SystemExit(f"second k=1 compose used the wrong error: {exc}")
else:
    raise SystemExit("second k=1 compose on one run was accepted")
if len(ledger_state("planco", "planco")["entries"]) != 1:
    raise SystemExit("refused second compose wrote an entry")

# k=2 reserves two compose sessions on the one run. A third is refused.
two_run = plan("twoco", "twoco", 2)
for stage in ("session:compose-1", "session:compose-2"):
    compose(DIFF, [{**base_doc, "k": 2, "text": "wrote the recap."}], class_id="twoco", company="twoco", run_id=two_run)
    if entry_labels("twoco", "twoco")[-1] != ledger.format_label("twoco", two_run, stage):
        raise SystemExit(f"k=2 compose did not record {stage}")
try:
    compose(DIFF, [{**base_doc, "k": 2, "text": "wrote the recap."}], class_id="twoco", company="twoco", run_id=two_run)
except packets.PacketError as exc:
    if "compose stages are used" not in str(exc):
        raise SystemExit(f"third k=2 compose used the wrong error: {exc}")
else:
    raise SystemExit("third k=2 compose was accepted")
two_state = ledger_state("twoco", "twoco")
if len(two_state["runs"]) != 1 or two_state.get("depth") != 2 or len(two_state["entries"]) != 2:
    raise SystemExit(f"k=2 composes changed the plan: {two_state}")

# Deliverables at a different k than the run are refused and write nothing.
mismatch_run = plan("kmismatch", "kmismatch", 2)
try:
    compose(DIFF, [{**base_doc, "k": 1, "text": "wrote the recap."}], class_id="kmismatch", company="kmismatch", run_id=mismatch_run)
except packets.PacketError as exc:
    if "k does not match" not in str(exc):
        raise SystemExit(f"k mismatch used the wrong error: {exc}")
else:
    raise SystemExit("k=1 deliverables on a k=2 run were composed")
assert_untouched("k mismatch wrote to the ledger")

# An unknown run is refused: no ledger, a run from another class, and a bad id.
for cid, run in (("norun", c2_run), ("planco", "not a run id"), ("planco", 7)):
    before = ledger_bytes("planco", "planco")
    try:
        compose(DIFF, [{**base_doc, "k": 1, "text": "wrote the recap."}], class_id=cid, company="planco", run_id=run)
    except packets.PacketError as exc:
        if "unknown run" not in str(exc):
            raise SystemExit(f"unknown run {run!r} used the wrong error: {exc}")
    else:
        raise SystemExit(f"unknown run {run!r} was composed")
    if ledger_bytes("planco", "planco") != before or (companies / "planco" / "eval-library" / "norun").exists():
        raise SystemExit(f"unknown run {run!r} wrote to a ledger")

# A finished or started ledger takes no compose session.
fin_run = plan("compfin", "compfin", 1)
ledger.Ledger(str(companies), "compfin", "compfin", "compfin").finalize(1)
try:
    compose(DIFF, [{**base_doc, "k": 1, "text": "wrote the recap."}], class_id="compfin", company="compfin", run_id=fin_run)
except packets.PacketError as exc:
    if "run is finished" not in str(exc):
        raise SystemExit(f"finished run used the wrong error: {exc}")
else:
    raise SystemExit("compose on a finished run was accepted")
assert_untouched("compose on a finished run wrote to the ledger")
start_run = plan("compstart", "compstart", 1)
start_book = ledger.Ledger(str(companies), "compstart", "compstart", "compstart")
start_book.start([
    {
        "label": ledger.format_label("compstart", start_run, "session:propose"),
        "kind": ledger.KIND_SESSION,
        "lane_id": "lane-1",
        "provider": "none",
        "account": "none",
        "usd": ledger.UNPRICED,
    }
])
start_before = ledger_bytes("compstart", "compstart")
try:
    compose(DIFF, [{**base_doc, "k": 1, "text": "wrote the recap."}], class_id="compstart", company="compstart", run_id=start_run)
except packets.PacketError as exc:
    if "already started" not in str(exc):
        raise SystemExit(f"started ledger used the wrong error: {exc}")
else:
    raise SystemExit("compose on a started ledger was accepted")
if ledger_bytes("compstart", "compstart") != start_before:
    raise SystemExit("compose on a started ledger wrote to it")

# With an output file: an existing file is refused before the ledger is
# written, and a ledger refusal removes the new file again.
out_run = plan("outco", "outco", 2)
packets.write_company_text(str(companies), "outco", "outco", "packets/taken.json", "{}", "outco")
try:
    compose(DIFF, [{**base_doc, "k": 2, "text": "wrote the recap."}], class_id="outco", company="outco", run_id=out_run, out="packets/taken.json")
except packets.PacketError as exc:
    if "refusing to overwrite" not in str(exc):
        raise SystemExit(f"existing output used the wrong error: {exc}")
else:
    raise SystemExit("compose overwrote an existing output")
assert_untouched("refused output wrote to the ledger")
out_lib = companies / "outco" / "eval-library" / "outco"
if (out_lib / "packets" / "taken.json").read_text(encoding="utf-8") != "{}":
    raise SystemExit("refused output changed the existing file")
real_commit = ledger.Ledger.commit

def refusing_commit(self, raw):
    raise ledger.LedgerError("duplicate label")

ledger.Ledger.commit = refusing_commit
try:
    try:
        compose(DIFF, [{**base_doc, "k": 2, "text": "wrote the recap."}], class_id="outco", company="outco", run_id=out_run, out="packets/refused.json")
    except packets.PacketError as exc:
        if "ledger refused the compose stage" not in str(exc):
            raise SystemExit(f"ledger refusal used the wrong error: {exc}")
    else:
        raise SystemExit("compose ignored a ledger refusal")
finally:
    ledger.Ledger.commit = real_commit
if (out_lib / "packets" / "refused.json").exists():
    raise SystemExit("ledger refusal left the output file")
# A run finished after the compose slot is chosen. The ledger's own commit
# refuses the stage, so nothing is recorded on a closed class and the new
# output file is removed.
race_run = plan("raceco", "raceco", 1)
real_slot = packets._compose_slot

def slot_then_finalize(book, run_id, k):
    label = real_slot(book, run_id, k)
    ledger.Ledger(str(companies), "raceco", "raceco", "raceco").finalize(1)
    return label

packets._compose_slot = slot_then_finalize
try:
    try:
        compose(DIFF, [{**base_doc, "k": 1, "text": "wrote the recap."}], class_id="raceco", company="raceco", run_id=race_run, out="packets/race.json")
    except packets.PacketError as exc:
        if "ledger refused the compose stage" not in str(exc) or "run is finished" not in str(exc):
            raise SystemExit(f"finish after the slot check used the wrong error: {exc}")
    else:
        raise SystemExit("compose recorded a stage on a run finished after the slot check")
finally:
    packets._compose_slot = real_slot
if entry_labels("raceco", "raceco"):
    raise SystemExit(f"finished run took a compose stage: {entry_labels('raceco', 'raceco')}")
if (companies / "raceco" / "eval-library" / "raceco" / "packets" / "race.json").exists():
    raise SystemExit("refused stage left the output file")
written = compose(DIFF, [{**base_doc, "k": 2, "text": "wrote the recap."}], class_id="outco", company="outco", run_id=out_run, out="packets/compose.json")
if json.loads((out_lib / "packets" / "compose.json").read_text(encoding="utf-8")) != written:
    raise SystemExit("output file does not hold the returned packet")
if entry_labels("outco", "outco") != [ledger.format_label("outco", out_run, "session:compose-1")]:
    raise SystemExit(f"compose with an output recorded the wrong stage: {entry_labels('outco', 'outco')}")

# The cap is the company parent chain, checked when a run is planned. A second
# plan without a parent is refused, including a plan for a new class. Passing
# the parent run id spends the remaining depth. Compose runs on each plan.
root_id = plan("chainco", "depthcap", 1)
root = compose(DIFF, [{**base_doc, "k": 1, "text": "wrote the recap."}], class_id="depthcap", company="chainco", run_id=root_id)
if root["deliverables"][0]["text"] != "wrote the recap.":
    raise SystemExit("chain root deliverable was rewritten")

def refused_plan(company, class_id, k, parent_run_id, expected, what):
    try:
        plan(company, class_id, k, parent_run_id)
    except ledger.LedgerError as exc:
        if expected not in str(exc):
            raise SystemExit(f"{what} used the wrong error: {exc}")
    else:
        raise SystemExit(f"{what} was accepted")

refused_plan("chainco", "depthcap", 1, None, "parent run is required", "second plan without a parent")
refused_plan("chainco", "othercap", 1, None, "parent run is required", "new class without a parent")
if (companies / "chainco" / "eval-library" / "othercap" / "ledger.json").exists():
    raise SystemExit("refused new class wrote a ledger")
child_id = plan("chainco", "childcap", 1, root_id)
child = compose(DIFF, [{**base_doc, "k": 1, "text": "wrote the recap."}], class_id="childcap", company="chainco", run_id=child_id)
if child["deliverables"][0]["text"] != "wrote the recap.":
    raise SystemExit("child deliverable was rewritten")
child_state = ledger_state("chainco", "childcap")
if child_state.get("depth") != 2 or child_state["runs"][0].get("parent_run_id") != root_id:
    raise SystemExit(f"child did not take the parent chain: {child_state.get('depth')}")
if len(child_state["runs"]) != 1:
    raise SystemExit("compose added a plan to the child class")
if ledger_state("chainco", "depthcap").get("depth") != 1:
    raise SystemExit("child plan rewrote the parent class depth")
refused_plan("chainco", "childcap", 1, child_id, "k exceeds hard cap", "third k=1")
if ledger_state("chainco", "childcap").get("depth") != 2:
    raise SystemExit("refused third plan changed the child depth")

# A k=2 child of a depth-1 plan is the same cap, and the file stays at 1.
one_id = plan("depthone", "depthone", 1)
compose(DIFF, [{**base_doc, "k": 1, "text": "wrote the recap."}], class_id="depthone", company="depthone", run_id=one_id)
refused_plan("depthone", "depthone", 2, one_id, "k exceeds hard cap", "k=2 on a depth-1 ledger")
if ledger_state("depthone", "depthone").get("depth") != 1:
    raise SystemExit("refused k=2 changed depth")

# Siblings share the tree budget. Root k=1 plus one k=1 child spends k=2, so
# a second k=1 child of the same root is refused even though its depth is 2.
sib_root = plan("sibco", "sibroot", 1)
plan("sibco", "sibone", 1, sib_root)
refused_plan("sibco", "sibtwo", 1, sib_root, "k exceeds hard cap", "second sibling over the tree budget")
if (companies / "sibco" / "eval-library" / "sibtwo" / "ledger.json").exists():
    raise SystemExit("refused sibling wrote a ledger")

# A child of a finished run is refused.
fin_root = plan("finco", "finroot", 1)
compose(DIFF, [{**base_doc, "k": 1, "text": "wrote the recap."}], class_id="finroot", company="finco", run_id=fin_root)
ledger.Ledger(str(companies), "finco", "finroot", "finco").finalize(1)
refused_plan("finco", "finchild", 1, fin_root, "parent run is finished", "child of a finished run")
if (companies / "finco" / "eval-library" / "finchild" / "ledger.json").exists():
    raise SystemExit("refused child of a finished run wrote a ledger")

# One byte over the item cap is refused. A packet over the packet cap is refused.
try:
    compose(DIFF, [{**base_doc, "text": "y" * (packets.MAX_ITEM_BYTES + 1)}])
except packets.PacketError as exc:
    if "item cap" not in str(exc):
        raise SystemExit(f"oversized item used the wrong error: {exc}")
else:
    raise SystemExit("oversized deliverable was accepted")
# k=2 allows three deliverables. Two items under the item cap still go over
# the packet cap, because JSON escapes each non-ASCII character to six bytes.
chunk = "é" * 110000
if len(chunk.encode("utf-8")) >= packets.MAX_ITEM_BYTES or 2 * len(json.dumps(chunk)) <= packets.MAX_PACKET_BYTES:
    raise SystemExit("packet cap fixture no longer sits between the two caps")
wide = []
for index in range(2):
    wide.append({**base_doc, "k": 2, "label": f"probe-{index}", "text": chunk})
try:
    compose(DIFF, wide)
except packets.PacketError as exc:
    if "packet cap" not in str(exc):
        raise SystemExit(f"oversized packet used the wrong error: {exc}")
else:
    raise SystemExit("oversized packet was accepted")
under = compose(DIFF, [{**base_doc, "text": "y" * 100}])
if under["deliverables"][0]["text"] != "y" * 100:
    raise SystemExit("a small deliverable was refused")

# Review round 2, finding 1: each evasion is refused by the defense-in-depth
# scan in every builder. Compose refuses before the ledger is written.
PROBES = [
    "ｓｃｏｒｅ: 0.75",
    "scоre: 0.75",
    "pass​_rate 0.75",
    "eyJwYXNzX3JhdGUiOjAuNzV9",
    "7b22706173735f72617465223a302e37357d",
    "seventy-five percent of checks passed",
    "3 of 4 checks passed",
    "3/4 passed",
    "75% passed",
    "rating: 9/10",
    "accuracy=0.75",
    "criteria met: 3 of 4",
    "earned 3 points out of 4",
    "VERDICT: PASS",
    '"fraction": 0.75',
    "gradeResult=0.75",
    "nPassed=3",
    # Self-review: vulgar fractions, fraction slashes, and "pct".
    "¾ passed",
    "3⁄4 passed",
    "3∕4 passed",
    "75 pct passed",
]
for index, probe in enumerate(PROBES):
    try:
        packets.refuse_grade_text(probe)
    except packets.PacketError as exc:
        if probe in str(exc):
            raise SystemExit(f"refusal echoed the probe: {exc}")
    else:
        raise SystemExit(f"scan accepted probe {probe!r}")
    co = f"probe{index:02d}"
    try:
        compose(DIFF, [{**base_doc, "text": f"The recap is done. {probe}"}], class_id=co, company=co)
    except packets.PacketError:
        pass
    else:
        raise SystemExit(f"compose accepted probe {probe!r}")
    assert_untouched(f"refused probe {probe!r} wrote to the ledger")
    try:
        packets.build_packet(f"Write the weekly recap. {probe}", [])
    except packets.PacketError:
        pass
    else:
        raise SystemExit(f"build_packet accepted probe {probe!r}")
    try:
        packets.validated_tree({"skills/a.md": f"note: {probe}".encode("utf-8")})
    except packets.PacketError:
        pass
    else:
        raise SystemExit(f"validated_tree accepted probe {probe!r}")
    try:
        packets.proposer_view({**record, "error": probe})
    except packets.PacketError:
        pass
    else:
        raise SystemExit(f"proposer_view accepted probe {probe!r} in error")

# The error field is a fixed code. Free text is refused even when it is clean.
for code in packets.ERROR_CODES:
    if packets.proposer_view({**record, "ok": code == "", "error": code})["error"] != code:
        raise SystemExit(f"error code {code!r} was rewritten")
for text in ("the lane stopped early", "0.75", "Timeout"):
    try:
        packets.proposer_view({**record, "error": text})
    except packets.PacketError:
        pass
    else:
        raise SystemExit(f"free-text error {text!r} was accepted")

# A grade split across fields is refused: frac in one field, 0.75 in another.
for split in (
    {**record, "run_id": "frac", "error": "0.75"},
    {**record, "run_id": "frac"},
    {**record, "label": "pass-rate"},
    {**record, "label": "Incumbent"},
):
    try:
        packets.proposer_view(split)
    except packets.PacketError:
        pass
    else:
        raise SystemExit(f"split-field record was accepted: {split}")
for half in ("We got 3 of", "4 checks passed"):
    packets.refuse_grade_text(half)
try:
    compose(DIFF, [{**base_doc, "label": "probe-a", "text": "We got 3 of"}, {**base_doc, "label": "probe-b", "text": "4 checks passed"}], class_id="splitco", company="splitco")
except packets.PacketError:
    pass
else:
    raise SystemExit("grade split across two deliverables was composed")
assert_untouched("refused split deliverables wrote to the ledger")

# File names are scanned after normalization.
for name in ("skills/3-of-4-passed.md", "policies/verdict-PASS.md", "skills/scоre.md", "skills/passRate.md"):
    try:
        packets.validated_tree({name: b"hello"})
    except packets.PacketError:
        pass
    else:
        raise SystemExit(f"grade file name {name!r} was accepted")

# Clean text with numbers and the word "of" is kept. The scan is not a ban on numbers.
for clean_text in ("Step 1 of 3: write the intro.", "Version 1.2 of the tool shipped.", "Two of the four sections moved."):
    packets.refuse_grade_text(clean_text)
kept_tree = packets.validated_tree({"skills/step-1-of-3.md": b"Step 1 of 3: write the intro."})
if kept_tree["skills/step-1-of-3.md"] != b"Step 1 of 3: write the intro.":
    raise SystemExit("clean numbered skill was rewritten")

# Grades are stored where the builders have no read path. A grade area in a
# tree path, a diff path, or a CLI read path is refused.
for name in ("skills/grades/x.md", "skills/results.md", "policies/verdicts/a.md", "skills/ledger.md", "subagents/judge.md", "skills/check-results/a.md"):
    try:
        packets.validated_tree({name: b"hello"})
    except packets.PacketError as exc:
        if exc.code != "grade_area":
            raise SystemExit(f"grade area {name!r} used the wrong code: {exc.code}")
    else:
        raise SystemExit(f"grade area {name!r} was accepted")
for bad_diff in (
    "--- a/skills/grades/x.md\n+++ b/skills/grades/x.md\n@@\n-old\n+new\n",
    "--- a/results/run.json\n+++ b/results/run.json\n@@\n-old\n+new\n",
    "--- a/ledger.json\n+++ b/ledger.json\n@@\n-old\n+new\n",
    "--- a/../grades/x.md\n+++ b/../grades/x.md\n@@\n-old\n+new\n",
    "the harness changed a few lines",
    "",
):
    try:
        compose(bad_diff, [{**base_doc, "text": "wrote the recap."}], class_id="baddiff", company="baddiff")
    except packets.PacketError:
        pass
    else:
        raise SystemExit(f"harness diff {bad_diff!r} was composed")
    assert_untouched(f"refused harness diff {bad_diff!r} wrote to the ledger")
# Review round 3, finding 1: CLI reads are an allowlist of input roots. Any
# path outside the root for its kind is refused before it is opened,
# whatever its name. The ledger sits at the library root, outside every root.
outside = (
    "grades/x.json", "results/run-1.json", "ledger.json", "ledger.created", "verdict.json",
    "rollout-grader.json", "grades2/x.json", "scorecard.json", "gradebook/a.json", "judging/a",
    "evaluator/a", "assessment/a", "marks/a", "outcome/a", "qa/report.json", "ledgerbak.json",
    "out/rollout-1.json", "rollout.json", "/tmp/runs/a.json", "runs/../ledger.json", "runs/./a.json",
    "runs//a.json", "runs\\a.json", "Runs/a.json", "runs/A.json", "runs/a.txt", "runs/.json",
    "runs/", "runs", "", "briefs/a.md", "packets/a.json", "runs/a/b/c/d.json",
)
for rel in outside:
    try:
        packets.read_company_text(companies, "gradeco", "class-001", rel, "gradeco", kind="record")
    except packets.PacketError as exc:
        if exc.code != "input_path":
            raise SystemExit(f"input read {rel!r} used the wrong code: {exc.code}")
    else:
        raise SystemExit(f"input read {rel!r} was allowed")
# Inside a root, a segment with a grade stem is still refused.
for kind, rel in (
    ("record", "runs/scorecard.json"), ("work", "briefs/gradebook.md"), ("diff", "diffs/evaluator/a.diff"),
    ("deliverables", "deliverables/assessment.json"), ("runs", "runs/ledgerbak.json"),
    ("tree", "trees/results-1.json"), ("patches", "patches/judging.json"),
):
    try:
        packets.read_company_text(companies, "gradeco", "class-001", rel, "gradeco", kind=kind)
    except packets.PacketError as exc:
        if exc.code != "grade_area":
            raise SystemExit(f"stem read {rel!r} used the wrong code: {exc.code}")
    else:
        raise SystemExit(f"stem read {rel!r} was allowed")
if (companies / "gradeco").exists():
    raise SystemExit("refused input read touched the company directory")
# Each kind maps to one root and its suffixes.
for kind, rel in (
    ("work", "briefs/recap.md"), ("work", "briefs/2026/recap.txt"), ("runs", "runs/rollout-1.json"),
    ("record", "runs/r1/rollout.json"), ("deliverables", "deliverables/docs.json"),
    ("diff", "diffs/harness.diff"), ("diff", "diffs/harness.patch"), ("tree", "trees/incumbent.json"),
    ("incumbent", "trees/incumbent.json"), ("patches", "patches/p1.json"),
):
    if packets.require_input_path(rel, kind) != rel:
        raise SystemExit(f"allowed input {rel!r} was rewritten")
for kind, rel in (("work", "runs/a.json"), ("diff", "briefs/a.txt"), ("tree", "patches/a.json"), ("nope", "runs/a.json")):
    try:
        packets.require_input_path(rel, kind)
    except packets.PacketError as exc:
        if exc.code != "input_path":
            raise SystemExit(f"cross-kind read {rel!r} used the wrong code: {exc.code}")
    else:
        raise SystemExit(f"{kind} read {rel!r} was allowed")
# Writes go only to packets/, which is not an input root.
packets.require_output_path("packets/view.json")
for rel in ("view.json", "runs/view.json", "briefs/view.md", "ledger.json", "packets/view.md", "packets/../ledger.json"):
    try:
        packets.write_company_text(companies, "gradeco", "class-001", rel, "{}", "gradeco")
    except packets.PacketError as exc:
        if exc.code != "input_path":
            raise SystemExit(f"output {rel!r} used the wrong code: {exc.code}")
    else:
        raise SystemExit(f"output {rel!r} was written")
if (companies / "gradeco").exists():
    raise SystemExit("refused output touched the company directory")

# Review round 2, finding 2: the deliverable count is bound to k through the
# ledger. k=1 plans two rollouts, so ten deliverables are refused before any
# ledger write. Three at k=1 are refused. Two at k=1 and three at k=2 pass,
# and each records one compose session on its one planned run.
def many(count, k):
    return [{**base_doc, "k": k, "label": f"probe-{index}", "text": "wrote the recap."} for index in range(count)]

for count, k, co in ((10, 1, "tenatk1"), (3, 1, "threeatk1"), (4, 2, "fouratk2")):
    try:
        compose(DIFF, many(count, k), class_id=co, company=co)
    except packets.PacketError as exc:
        if "deliverables" not in str(exc):
            raise SystemExit(f"{count} deliverables at k={k} used the wrong error: {exc}")
    else:
        raise SystemExit(f"{count} deliverables at k={k} were composed")
    assert_untouched(f"{count} deliverables at k={k} wrote to the ledger")
for count, k, co in ((2, 1, "twoatk1"), (3, 2, "threeatk2")):
    packed = compose(DIFF, many(count, k), class_id=co, company=co)
    if len(packed["deliverables"]) != count:
        raise SystemExit(f"{count} deliverables at k={k} were not all composed")
    state = ledger_state(co, co)
    if len(state["runs"]) != 1 or state.get("depth") != k or len(state["entries"]) != 1:
        raise SystemExit(f"{count} deliverables at k={k} did not keep one k={k} plan and one compose entry")
for mixed in ([{**base_doc, "k": 1, "text": "a"}, {**base_doc, "label": "probe-b", "k": 2, "text": "b"}], [{**base_doc, "k": True, "text": "a"}], []):
    try:
        compose(DIFF, mixed, class_id="mixedk", company="mixedk")
    except packets.PacketError:
        pass
    else:
        raise SystemExit(f"deliverables {mixed!r} were composed")
    assert_untouched(f"refused deliverables {mixed!r} wrote to the ledger")

# Review round 2, finding 4: anonymization is structural. A label is replaced
# only as a whole token, and every candidate's label is replaced in every text.
banana = compose(DIFF, [{**base_doc, "label": "a", "text": "a banana and A cake"}], class_id="banana", company="banana")
if banana["deliverables"][0]["text"] != "candidate-1 banana and candidate-1 cake":
    raise SystemExit(f"short label mangled the text: {banana['deliverables'][0]['text']}")
duel_docs = [
    {"label": "bob", "task_id": "class-001", "k": 1, "mode": "incumbent", "text": "I beat alice."},
    {"label": "alice", "task_id": "class-001", "k": 1, "mode": "probe", "text": "bob and alice-two and malice."},
]

def expected_ids(docs):
    order = sorted(range(len(docs)), key=lambda i: (hashlib.sha256(docs[i]["text"].encode("utf-8")).hexdigest(), i))
    return {docs[position]["label"]: f"candidate-{rank}" for rank, position in enumerate(order, start=1)}

ids = expected_ids(duel_docs)
duel = compose(DIFF, duel_docs, class_id="duel", company="duel")
by_id = {item["id"]: item["text"] for item in duel["deliverables"]}
if by_id.get(ids["bob"]) != f"I beat {ids['alice']}.":
    raise SystemExit(f"other candidate's label stayed: {duel['deliverables']}")
if by_id.get(ids["alice"]) != f"{ids['bob']} and alice-two and malice.":
    raise SystemExit(f"label replaced inside another word: {duel['deliverables']}")
if [item["id"] for item in duel["deliverables"]] != sorted(by_id):
    raise SystemExit("deliverables are not listed in candidate order")
# Review of #1417, informational: input order does not decide candidate
# numbers. The incumbent passed first or last gives the same packet.
swapped = compose(DIFF, list(reversed(duel_docs)), class_id="duelswap", company="duelswap")
if swapped != duel:
    raise SystemExit(f"input order changed the packet: {swapped['deliverables']}")
try:
    compose(DIFF, [{**base_doc, "label": "same", "text": "a"}, {**base_doc, "label": "same", "text": "b"}], class_id="duplabel", company="duplabel")
except packets.PacketError:
    pass
else:
    raise SystemExit("duplicate labels were composed")

# Review round 2, finding 5: plan reasons are fixed codes. No patch text is copied.
leaky = packets.plan_patches(
    incumbent,
    [
        {"skills/a.md": "pass_rate is high"},
        {"skills/b.md": "3/4 criteria passed"},
    ],
)
if leaky["fell_back"] is not True:
    raise SystemExit("grade patches were accepted")
for field in (leaky["reason"], *leaky["attempts"]):
    for fragment in ("pass_rate", "3/4", "criteria", "passed", "skills/"):
        if fragment in field:
            raise SystemExit(f"plan reason copied patch text {fragment!r}: {field}")
for attempt in leaky["attempts"]:
    code = attempt.split(": ", 1)[1]
    if code not in packets.PLAN_REASON_CODES:
        raise SystemExit(f"plan reason is not a fixed code: {attempt}")
area = packets.plan_patches(incumbent, [{"skills/grades/a.md": "x"}, {"skills/b.md": "VERDICT: PASS"}])
if area["attempts"] != ["attempt 1: grade_area", "attempt 2: grade_content"]:
    raise SystemExit(f"plan codes drifted: {area['attempts']}")

# Review of #1417, criticals 1 and 3: library reads and writes go through
# surface._open_library. Matching --company and --session-company flags are
# not enough: the company must be the session lock, the companies root must
# be the HQ root companies directory, and the company must be in the manifest.
bind_company("lockco")
for co in ("intruder", "lockco"):
    lib = companies / co / "eval-library" / "scope"
    (lib / "briefs").mkdir(parents=True, exist_ok=True)
    (lib / "briefs" / "work.txt").write_bytes(b"Write the weekly recap.")
manifest_companies.add("intruder")
write_manifest()
bind_company("lockco")
if packets.read_company_text(str(companies), "lockco", "scope", "briefs/work.txt", "lockco", kind="work") != "Write the weekly recap.":
    raise SystemExit("locked company read returned the wrong bytes")
try:
    packets.read_company_text(str(companies), "intruder", "scope", "briefs/work.txt", "intruder", kind="work")
except surface.SurfaceError as exc:
    if "session bind" not in str(exc):
        raise SystemExit(f"company outside the session lock used the wrong error: {exc}")
else:
    raise SystemExit("company outside the session lock was read with matching flags")
try:
    packets.write_company_text(str(companies), "intruder", "scope", "packets/view.json", "{}", "intruder")
except surface.SurfaceError as exc:
    if "session bind" not in str(exc):
        raise SystemExit(f"write outside the session lock used the wrong error: {exc}")
else:
    raise SystemExit("company outside the session lock was written with matching flags")
if (companies / "intruder" / "eval-library" / "scope" / "packets").exists():
    raise SystemExit("refused write created the packets directory")
# A companies root outside the HQ root.
elsewhere = tmp / "elsewhere" / "companies"
(elsewhere / "lockco" / "eval-library" / "scope" / "briefs").mkdir(parents=True)
(elsewhere / "lockco" / "eval-library" / "scope" / "briefs" / "work.txt").write_bytes(b"Write the weekly recap.")
(elsewhere / "manifest.yaml").write_text("companies:\n  lockco:\n    name: lockco\n", encoding="utf-8")
try:
    packets.read_company_text(str(elsewhere), "lockco", "scope", "briefs/work.txt", "lockco", kind="work")
except surface.SurfaceError as exc:
    if "HQ root companies directory" not in str(exc):
        raise SystemExit(f"companies root outside the HQ root used the wrong error: {exc}")
else:
    raise SystemExit("companies root outside the HQ root was read")
# A locked company that is not in the manifest.
(companies / "unlisted" / "eval-library" / "scope" / "briefs").mkdir(parents=True)
(companies / "unlisted" / "eval-library" / "scope" / "briefs" / "work.txt").write_bytes(b"Write the weekly recap.")
meta_path.write_text("company_slug: unlisted\ncompany_slugs: unlisted\n", encoding="utf-8")
try:
    packets.read_company_text(str(companies), "unlisted", "scope", "briefs/work.txt", "unlisted", kind="work")
except surface.SurfaceError as exc:
    if "unknown company" not in str(exc):
        raise SystemExit(f"company missing from the manifest used the wrong error: {exc}")
else:
    raise SystemExit("company missing from the manifest was read")
# A hardlinked library file. The surface on main refuses nlink > 1.
bind_company("lockco")
scope_lib = companies / "lockco" / "eval-library" / "scope" / "briefs"
os.link(scope_lib / "work.txt", tmp / "hardlink-elsewhere.txt")
try:
    packets.read_company_text(str(companies), "lockco", "scope", "briefs/work.txt", "lockco", kind="work")
except surface.SurfaceError as exc:
    if "hardlink" not in str(exc):
        raise SystemExit(f"hardlinked library file used the wrong error: {exc}")
else:
    raise SystemExit("hardlinked library file was read")
os.unlink(tmp / "hardlink-elsewhere.txt")

# Company scoping uses the surface helper and fails closed.
companies = tmp / "companies"
bind_company("indigo")
indigo_root = companies / "indigo" / "eval-library" / "class-001"
other_root = companies / "otherco" / "eval-library" / "class-001"
indigo_root.mkdir(parents=True)
other_root.mkdir(parents=True)
(other_root / "briefs").mkdir()
(indigo_root / "briefs").mkdir()
(other_root / "briefs" / "secret.txt").write_bytes(b"other-secret")
(indigo_root / "briefs" / "work.txt").write_bytes(b"Write the weekly recap.")
opened = []
real_open = os.open

def spy_open(path, flags, *args, **kwargs):
    text = os.fspath(path)
    opened.append(text)
    if "otherco" in Path(text).parts:
        raise SystemExit(f"opened another company's directory: {text}")
    return real_open(path, flags, *args, **kwargs)

os.open = spy_open
try:
    try:
        packets.read_company_text(companies, "otherco", "class-001", "briefs/secret.txt", "indigo", kind="work")
    except surface.SurfaceError:
        pass
    else:
        raise SystemExit("foreign company was accepted")
    for escape in ("../otherco/briefs/secret.txt", "briefs/../../../otherco/eval-library/class-001/briefs/secret.txt", str(other_root / "briefs" / "secret.txt")):
        try:
            packets.read_company_text(companies, "indigo", "class-001", escape, "indigo", kind="work")
        except packets.PacketError as exc:
            if exc.code != "input_path":
                raise SystemExit(f"escape {escape!r} used the wrong code: {exc.code}")
        else:
            raise SystemExit(f"escape {escape!r} was accepted")
    if packets.read_company_text(companies, "indigo", "class-001", "briefs/work.txt", "indigo", kind="work") != "Write the weekly recap.":
        raise SystemExit("company library read returned the wrong bytes")
finally:
    os.open = real_open
if any("otherco" in Path(item).parts for item in opened):
    raise SystemExit(f"foreign company path was opened: {opened}")
PY

# CLI paths stay inside one temp company library. Nothing reads the live companies/ tree.
COMPANIES="$TMP/companies"
LIB="$COMPANIES/indigo/eval-library/class-001"
OTHER="$COMPANIES/otherco/eval-library/class-001"
mkdir -p "$LIB/briefs" "$LIB/runs" "$LIB/deliverables" "$LIB/diffs" "$LIB/trees" "$LIB/patches" "$OTHER/briefs"
printf 'other-secret\n' >"$OTHER/briefs/secret.txt"
SCOPE=(
  --companies-root "$COMPANIES"
  --company indigo
  --class-id class-001
  --session-company indigo
)

# Every CLI call runs under the temp session lock and the company manifest, so
# each refusal below is the check it names, not a missing lock.
export HQ_SESSION_ID=eval-packets-test
export HQ_HQ_SESSION_NO_CLI=1
mkdir -p "$TMP/workspace/sessions/$HQ_SESSION_ID" "$COMPANIES/indigo"
printf 'company_slug: indigo\ncompany_slugs: indigo\n' >"$TMP/workspace/sessions/$HQ_SESSION_ID/meta.yaml"
python3 - "$COMPANIES/manifest.yaml" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8") if path.is_file() else "companies:\n"
if "\n  indigo:\n" not in f"\n{text}":
    if "companies:" not in text:
        text = "companies:\n" + text
    if not text.endswith("\n"):
        text += "\n"
    text += "  indigo:\n    name: indigo\n"
    path.write_text(text, encoding="utf-8")
PY

# A missing session bind and a foreign company write nothing.
if python3 "$PACKETS" build-packet --companies-root "$COMPANIES" --company indigo --class-id class-001 --work briefs/work.txt --out packets/packet.json; then
  fail "missing session company exited 0"
fi
if python3 "$PACKETS" build-packet --companies-root "$COMPANIES" --company otherco --class-id class-001 --session-company indigo --work briefs/secret.txt --out packets/packet.json; then
  fail "foreign company exited 0"
fi
if [ -e "$OTHER/packets" ] || [ -e "$LIB/packets" ]; then
  fail "refused company scope wrote a packet"
fi
if ! grep -q 'other-secret' "$OTHER/briefs/secret.txt"; then
  fail "foreign company file was modified"
fi
ln -s "$OTHER/briefs/secret.txt" "$LIB/briefs/linked.txt"
if python3 "$PACKETS" build-packet "${SCOPE[@]}" --work briefs/linked.txt --out packets/packet.json; then
  fail "symlink path exited 0"
fi
if python3 "$PACKETS" build-packet "${SCOPE[@]}" --work ../otherco/briefs/secret.txt --out packets/packet.json; then
  fail "parent path exited 0"
fi
if python3 "$PACKETS" build-packet "${SCOPE[@]}" --work "$OTHER/briefs/secret.txt" --out packets/packet.json; then
  fail "absolute path exited 0"
fi
if [ -e "$LIB/packets" ]; then
  fail "refused path wrote a packet"
fi

# E2E: work text containing "score" exits non-zero and writes no file.
printf 'the score is hidden\n' >"$LIB/briefs/work.txt"
if python3 "$PACKETS" build-packet "${SCOPE[@]}" --work briefs/work.txt --out packets/packet.json; then
  fail "banned work text exited 0"
fi
if [ -e "$LIB/packets/packet.json" ]; then
  fail "banned work text wrote a packet"
fi

# E2E: an output outside packets/ is refused before any input is read.
printf 'Write the weekly recap.\n' >"$LIB/briefs/clean.txt"
for out in packet.json runs/packet.json briefs/packet.md ledger.json packets/packet.md; do
  if python3 "$PACKETS" build-packet "${SCOPE[@]}" --work briefs/clean.txt --out "$out" 2>"$TMP/out.err"; then
    fail "output $out exited 0"
  fi
  if ! grep -q 'not an allowed input' "$TMP/out.err"; then
    fail "output $out was not refused by the path allowlist"
  fi
  if [ -e "$LIB/$out" ]; then
    fail "output $out was written"
  fi
done

# E2E: a rollout record that includes n_passed is refused and writes no view.
cat >"$LIB/runs/extra-keys.json" <<'JSON'
{
  "label": "incumbent",
  "run_id": "run-1",
  "ok": true,
  "delivered": true,
  "cost": 1.25,
  "error": "",
  "n_passed": 3,
  "n_criteria": 4,
  "frac": 0.75,
  "all_pass": false,
  "exit_status": 0
}
JSON
if python3 "$PACKETS" proposer-view "${SCOPE[@]}" --record runs/extra-keys.json --out packets/extra-view.json 2>"$TMP/scored.err"; then
  fail "scored rollout exited 0"
fi
if [ -e "$LIB/packets/extra-view.json" ]; then
  fail "scored rollout wrote a view"
fi
if ! grep -q 'allowlist' "$TMP/scored.err"; then
  fail "scored rollout was not refused by the field allowlist"
fi
if grep -E -q 'n_passed|frac|0\.75' "$TMP/scored.err"; then
  fail "refusal echoed the score field"
fi

# E2E: a clean rollout record produces a view.
cat >"$LIB/runs/rollout.json" <<'JSON'
{
  "label": "incumbent",
  "run_id": "run-1",
  "ok": true,
  "delivered": true,
  "cost": 1.25,
  "error": ""
}
JSON
python3 "$PACKETS" proposer-view "${SCOPE[@]}" --record runs/rollout.json --out packets/view.json
python3 - "$LIB/packets/view.json" <<'PY'
import json, sys
view = json.load(open(sys.argv[1]))
if "frac" in view or "n_passed" in view or "cost" in view:
    raise SystemExit(f"score or cost field present: {view}")
if view != {"label": "arm-1", "run_id": "run-1", "ok": True, "delivered": True, "error": ""}:
    raise SystemExit(f"view fields wrong: {view}")
PY

# E2E: grade text in the error field writes no view.
cat >"$LIB/runs/error-text.json" <<'JSON'
{
  "label": "incumbent",
  "run_id": "run-1",
  "ok": true,
  "delivered": true,
  "cost": 1.25,
  "error": "3/4 criteria passed; frac=0.75"
}
JSON
if python3 "$PACKETS" proposer-view "${SCOPE[@]}" --record runs/error-text.json --out packets/error-view.json; then
  fail "error text exited 0"
fi
if [ -e "$LIB/packets/error-view.json" ]; then
  fail "error text wrote a view"
fi

# E2E, review round 3 finding 1: only the input roots are read. A clean record
# under any other name, including names that dodge the grade words, is refused
# before it is opened.
CLEAN_RECORD='{"label": "incumbent", "run_id": "run-1", "ok": true, "delivered": true, "error": ""}'
for rel in grades/run-1.json results/run-1.json ledger.json grades2/x.json scorecard.json gradebook/a.json \
  judging/a evaluator/a assessment/a marks/a outcome/a qa/report.json ledgerbak.json out/rollout-1.json rollout.json; do
  # The compose checks below need ledger.json absent, so that name is not created.
  if [ "$rel" != ledger.json ]; then
    mkdir -p "$(dirname "$LIB/$rel")"
    printf '%s\n' "$CLEAN_RECORD" >"$LIB/$rel"
  fi
  if python3 "$PACKETS" proposer-view "${SCOPE[@]}" --record "$rel" --out packets/area-view.json 2>"$TMP/area.err"; then
    fail "input read $rel exited 0"
  fi
  if ! grep -q 'not an allowed input' "$TMP/area.err"; then
    fail "input read $rel was not refused by the path allowlist"
  fi
done
printf '[%s]\n' "$CLEAN_RECORD" >"$LIB/runs/scorecard.json"
if python3 "$PACKETS" build-packet "${SCOPE[@]}" --work briefs/clean.txt --runs runs/scorecard.json --out packets/area-packet.json 2>"$TMP/area.err"; then
  fail "grade stem runs file exited 0"
fi
if ! grep -q 'grade area' "$TMP/area.err"; then
  fail "grade stem runs file was not refused as a grade area"
fi
if python3 "$PACKETS" build-packet "${SCOPE[@]}" --work briefs/clean.txt --runs grades/run-1.json --out packets/area-packet.json; then
  fail "grade area runs file exited 0"
fi
if [ -e "$LIB/packets/area-view.json" ] || [ -e "$LIB/packets/area-packet.json" ]; then
  fail "refused input read wrote a file"
fi
printf '[%s]\n' "$CLEAN_RECORD" >"$LIB/runs/runs.json"
python3 "$PACKETS" build-packet "${SCOPE[@]}" --work briefs/clean.txt --runs runs/runs.json --out packets/packet.json
if grep -q 'incumbent' "$LIB/packets/packet.json"; then
  fail "harness label reached the packet"
fi

# E2E: two invalid patches leave the incumbent file bytes unchanged.
cat >"$LIB/trees/incumbent.json" <<'JSON'
{
  "skills/keep.md": "KEEP",
  "policies/rule.md": "RULE"
}
JSON
cp "$LIB/trees/incumbent.json" "$TMP/incumbent.before"
cat >"$LIB/patches/patches.json" <<'JSON'
{
  "patches": [
    {"skills/../../outside": "nope"},
    {"/etc/passwd": "nope"}
  ]
}
JSON
python3 "$PACKETS" plan "${SCOPE[@]}" --incumbent trees/incumbent.json --patches patches/patches.json --out packets/plan.json
if ! cmp -s "$LIB/trees/incumbent.json" "$TMP/incumbent.before"; then
  fail "planner wrote the incumbent file"
fi
python3 - "$LIB/packets/plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
if plan["fell_back"] is not True:
    raise SystemExit("plan accepted invalid patches")
if plan["tree"] != {"skills/keep.md": "KEEP", "policies/rule.md": "RULE"}:
    raise SystemExit(f"plan tree changed: {plan['tree']}")
if plan["reason"] != "attempt 1: invalid_path; attempt 2: invalid_path":
    raise SystemExit(f"plan recorded the wrong reason: {plan['reason']}")
PY

# E2E: grade patch text is not copied into the plan file.
cat >"$LIB/patches/leaky-patches.json" <<'JSON'
{
  "patches": [
    {"skills/a.md": "pass_rate is high"},
    {"skills/b.md": "3/4 criteria passed"}
  ]
}
JSON
python3 "$PACKETS" plan "${SCOPE[@]}" --incumbent trees/incumbent.json --patches patches/leaky-patches.json --out packets/leaky-plan.json
if grep -E -q 'pass_rate|3/4|criteria' "$LIB/packets/leaky-plan.json"; then
  fail "plan file copied patch text"
fi
python3 - "$LIB/packets/leaky-plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
if plan["attempts"] != ["attempt 1: grade_content", "attempt 2: grade_content"]:
    raise SystemExit(f"plan file codes drifted: {plan['attempts']}")
PY

# A grader-verdict marker is rejected before the store file is created.
cat >"$LIB/trees/marked.json" <<'JSON'
{"skills/a.md": "prefix deterministic_eval_summary suffix"}
JSON
if python3 "$PACKETS" store-tree "${SCOPE[@]}" --tree trees/marked.json --out packets/marked-out.json; then
  fail "grader-verdict tree exited 0"
fi
if [ -e "$LIB/packets/marked-out.json" ]; then
  fail "grader-verdict tree was stored"
fi

# Composer CLI: a diff that mentions exit_code is kept. A grade in the text is not.
printf '%s\n' '--- a/skills/recap.md' '+++ b/skills/recap.md' '-  return exit_code' '+new' >"$LIB/diffs/diff.txt"
cat >"$LIB/deliverables/docs.json" <<'JSON'
[
  {
    "label": "probe-a",
    "task_id": "class-001",
    "k": 1,
    "mode": "probe",
    "text": "class-001|1|probe wrote probe-a."
  }
]
JSON
cat >"$LIB/deliverables/status-docs.json" <<'JSON'
[
  {
    "label": "probe-a",
    "task_id": "class-001",
    "k": 1,
    "mode": "probe",
    "text": "wrote the recap.",
    "exit_status": 0
  }
]
JSON
# Compose needs a run the harness planned. It does not plan one itself.
if python3 "$PACKETS" compose "${SCOPE[@]}" --diff diffs/diff.txt --deliverables deliverables/docs.json --out packets/compose.json 2>/dev/null; then
  fail "compose without --run exited 0"
fi
if [ -e "$LIB/packets/compose.json" ] || [ -e "$LIB/ledger.json" ]; then
  fail "compose without --run wrote a packet or a ledger"
fi
RUN_ID="$(python3 - "$ROOT/core/scripts/eval-loop" "$COMPANIES" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import ledger
print(ledger.plan_run(1, companies_root=sys.argv[2], company="indigo", class_id="class-001", session_company="indigo")["run_id"])
PY
)"
cp "$LIB/ledger.json" "$TMP/ledger.planned"
if python3 "$PACKETS" compose "${SCOPE[@]}" --run "$RUN_ID" --diff diffs/diff.txt --deliverables deliverables/status-docs.json --out packets/status-compose.json; then
  fail "deliverable with exit_status exited 0"
fi
if [ -e "$LIB/packets/status-compose.json" ] || ! cmp -s "$LIB/ledger.json" "$TMP/ledger.planned"; then
  fail "deliverable with exit_status wrote a packet or a ledger entry"
fi
COMPOSE_OUT="$(python3 "$PACKETS" compose "${SCOPE[@]}" --run "$RUN_ID" --diff diffs/diff.txt --deliverables deliverables/docs.json --out packets/compose.json)"
[ "$COMPOSE_OUT" = "$RUN_ID" ] || fail "compose did not print its run id"
python3 - "$LIB/ledger.json" "$RUN_ID" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
if len(state["runs"]) != 1 or state["runs"][0]["run_id"] != sys.argv[2] or state["depth"] != 1:
    raise SystemExit(f"CLI compose changed the plan: {state['runs']}")
labels = [entry["label"] for entry in state["entries"]]
if len(labels) != 1 or not labels[0].endswith(f"{sys.argv[2]}:session:compose"):
    raise SystemExit(f"CLI compose recorded the wrong stage: {labels}")
PY
cp "$LIB/ledger.json" "$TMP/ledger.composed"
if grep -q 'probe-a' "$LIB/packets/compose.json"; then
  fail "composer packet kept the deliverable label"
fi
python3 - "$LIB/packets/compose.json" <<'PY'
import json, sys
packet = json.load(open(sys.argv[1]))
if "return exit_code" not in packet["harness_diff"] or "+new" not in packet["harness_diff"]:
    raise SystemExit("harness diff missing")
if packet["deliverables"][0]["text"] != "candidate-1 wrote candidate-1.":
    raise SystemExit(packet["deliverables"][0]["text"])
if "exit_status" in packet or "n_passed" in packet:
    raise SystemExit("score key was copied")
PY
cat >"$LIB/deliverables/leak-docs.json" <<'JSON'
[
  {
    "label": "probe-a",
    "task_id": "class-001",
    "k": 1,
    "mode": "probe",
    "text": "{\"frac\": 0.5}"
  }
]
JSON
if python3 "$PACKETS" compose "${SCOPE[@]}" --run "$RUN_ID" --diff diffs/diff.txt --deliverables deliverables/leak-docs.json --out packets/leak-compose.json; then
  fail "nested frac exited 0"
fi
if [ -e "$LIB/packets/leak-compose.json" ]; then
  fail "nested frac wrote a packet"
fi
cat >"$LIB/deliverables/k3-docs.json" <<'JSON'
[
  {
    "label": "probe-a",
    "task_id": "class-001",
    "k": 3,
    "mode": "probe",
    "text": "wrote the recap."
  }
]
JSON
if python3 "$PACKETS" compose "${SCOPE[@]}" --run "$RUN_ID" --diff diffs/diff.txt --deliverables deliverables/k3-docs.json --out packets/k3-compose.json; then
  fail "k=3 exited 0"
fi
if [ -e "$LIB/packets/k3-compose.json" ]; then
  fail "k=3 wrote a packet"
fi
if ! cmp -s "$LIB/ledger.json" "$TMP/ledger.composed"; then
  fail "refused CLI composes wrote to the ledger"
fi

echo "ok"
