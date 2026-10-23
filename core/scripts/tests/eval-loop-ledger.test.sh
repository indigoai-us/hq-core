#!/usr/bin/env bash
# hq-core: public
# US-002: persisted run ledger, unique labels, and the k=2 cap.
# Uses temp company roots only. Does not read a live companies/ directory
# and does not call hq lanes.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LEDGER="$ROOT/core/scripts/eval-loop/ledger.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$LEDGER" ] || fail "missing $LEDGER"
[ -x "${BASH_SOURCE[0]}" ] || fail "test is not executable"

python3 -I - "$LEDGER" "$TMP" "$ROOT" <<'PY'
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]).resolve().parent))
import ledger

ledger_path = str(Path(sys.argv[1]).resolve())
tmp = Path(sys.argv[2])
root = Path(sys.argv[3])
companies = tmp / "companies"
py = sys.executable


companies.mkdir(parents=True, exist_ok=True)
# Each independent scenario gets its own company. Depth is company-wide, so a
# second class under one company is a child, not a fresh budget. The session
# lock is a temp meta.yaml read by hq-session.sh. It is not the live HQ session.
session_id = "eval-ledger-test"
meta_path = tmp / "workspace" / "sessions" / session_id / "meta.yaml"
meta_path.parent.mkdir(parents=True, exist_ok=True)
manifest_companies = set()
ACTIVE = {"company": None}
os.environ["HQ_SESSION_ID"] = session_id
os.environ["HQ_HQ_SESSION_NO_CLI"] = "1"
# The companies root must sit under the HQ root. The suite temp dir is that
# root. A caller HQ_ROOT or CLAUDE_PROJECT_DIR must not point at a checkout
# outside this temp tree, or every companies root here would be refused.
os.environ["HQ_ROOT"] = str(tmp.resolve())
os.environ.pop("CLAUDE_PROJECT_DIR", None)


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
    ACTIVE["company"] = company
    return company


def stage(run_id, suffix, kind, lane, check="unscored", usd="unpriced", account="a"):
    company = ACTIVE["company"]
    return {
        "label": ledger.format_label(company, run_id, suffix),
        "kind": kind,
        "lane_id": lane,
        "provider": "grok",
        "account": account,
        "usd": usd,
        "check": check,
    }


def suffix_of(label):
    company, run_id, stage_name = label.split(":", 2)
    if company != ACTIVE["company"] or len(run_id) != 16:
        raise SystemExit(f"label is not company+run bound: {label}")
    return stage_name


def open_book(class_id, company=None):
    company = bind_company(company or class_id)
    return ledger.Ledger(companies, company, class_id, company)


def cli(class_id, k, lanes, extra=None, company=None):
    company = bind_company(company or class_id)
    cmd = [
        py,
        "-I",
        ledger_path,
        "plan",
        "--k",
        str(k),
        "--company",
        company,
        "--class",
        class_id,
        "--companies-root",
        str(companies),
        "--session-company",
        company,
        "--lanes",
        str(lanes),
    ]
    if extra:
        cmd.extend(extra)
    return subprocess.run(cmd, capture_output=True, text=True)


workflow = (root / ".github" / "workflows" / "pr-checks.yml").read_text()
if "core/scripts/tests/eval-loop-ledger.test.sh" not in workflow:
    raise SystemExit("ledger test is not wired into CI")

if ledger.DEFAULT_K != 1 or ledger.MAX_K != 2:
    raise SystemExit(f"cap constants drifted: {ledger.DEFAULT_K} {ledger.MAX_K}")

# Patching MAX_K must not turn k=3 into the k=2 plan.
saved_max = ledger.MAX_K
ledger.MAX_K = 9
try:
    try:
        ledger._build_plan(3)
    except ledger.LedgerError as exc:
        if "k exceeds hard cap" not in str(exc) and "invalid k" not in str(exc):
            raise SystemExit(f"patched MAX_K raised the wrong error: {exc}")
    else:
        raise SystemExit("patched MAX_K let _build_plan accept k=3")
    try:
        ledger.plan_run(
            3,
            companies_root=companies,
            company="indigo",
            class_id="patched-k",
            session_company="indigo",
        )
    except ledger.LedgerError as exc:
        if "cap" not in str(exc) and "invalid k" not in str(exc):
            raise SystemExit(f"patched plan_run raised the wrong error: {exc}")
    else:
        raise SystemExit("patched MAX_K admitted k=3")
finally:
    ledger.MAX_K = saved_max
if (companies / "indigo" / "eval-library" / "patched-k").exists():
    raise SystemExit("rejected k=3 created a class directory")

# k=3 through the CLI writes nothing and does not traceback.
k3_lanes = tmp / "lanes-k3.json"
k3 = cli("k3", 3, k3_lanes)
if k3.returncode == 0:
    raise SystemExit("k=3 exited 0")
if k3.stdout:
    raise SystemExit(f"k=3 wrote a plan: {k3.stdout}")
if k3_lanes.exists():
    raise SystemExit("k=3 created a lane file")
if "k exceeds hard cap" not in k3.stderr:
    raise SystemExit(f"k=3 error did not name the cap: {k3.stderr}")
if "Traceback" in k3.stderr:
    raise SystemExit(k3.stderr)
if (companies / "k3" / "eval-library" / "k3").exists():
    raise SystemExit("k=3 created a ledger directory")

# A missing company is refused before a lane file exists.
missing = subprocess.run(
    [py, "-I", ledger_path, "plan", "--k", "1", "--lanes", str(tmp / "lanes-nocompany.json")],
    capture_output=True,
    text=True,
)
if missing.returncode == 0 or (tmp / "lanes-nocompany.json").exists():
    raise SystemExit("missing company wrote a plan")
if "Traceback" in missing.stderr or "company is required" not in missing.stderr:
    raise SystemExit(f"missing company error drifted: {missing.stderr}")

# An existing lanes path is the module's error, and it does not consume depth.
existed = tmp / "lanes-exists.json"
existed.write_text("[]", encoding="utf-8")
existed_run = cli("lanes-exists", 1, existed)
if existed_run.returncode == 0:
    raise SystemExit("existing lanes path exited 0")
if "Traceback" in existed_run.stderr or "lanes path exists" not in existed_run.stderr:
    raise SystemExit(f"existing lanes path was not a ledger error: {existed_run.stderr}")
if existed.read_text(encoding="utf-8") != "[]":
    raise SystemExit("existing lanes file was overwritten")
if (companies / "lanes-exists" / "eval-library" / "lanes-exists").exists():
    raise SystemExit("existing lanes path created a class directory")

# Bad company fails closed before the other company's directory is joined.
bad_root = tmp / "bad-root"
try:
    ledger.Ledger(bad_root, "acme", "class-001", "indigo")
except ledger.LedgerError as exc:
    if "session bind" not in str(exc):
        raise SystemExit(f"bad company raised the wrong error: {exc}")
else:
    raise SystemExit("foreign company was accepted")
if (bad_root / "acme").exists() or (bad_root / "indigo").exists():
    raise SystemExit("foreign company directory was created")
for bad_company, bad_class in (("Indigo", "class-001"), ("indigo", "../x"), ("../indigo", "class-001"), ("", "class-001")):
    try:
        ledger.Ledger(bad_root, bad_company, bad_class, "indigo")
    except ledger.LedgerError:
        pass
    else:
        raise SystemExit(f"accepted bad slug company={bad_company!r} class={bad_class!r}")
if any(bad_root.iterdir()) if bad_root.exists() else False:
    raise SystemExit(f"bad slug created {list(bad_root.iterdir())}")

# A company directory that is a symlink is not written through.
link_root = tmp / "link-root"
real_company = tmp / "real-other"
real_company.mkdir()
link_root.mkdir()
(link_root / "indigo").symlink_to(real_company)
try:
    ledger.Ledger(link_root, "indigo", "class-001", "indigo").plan(1)
except ledger.LedgerError as exc:
    if "symlink" not in str(exc):
        raise SystemExit(f"symlink company raised the wrong error: {exc}")
else:
    raise SystemExit("symlinked company directory was accepted")
if (real_company / "eval-library").exists():
    raise SystemExit("write followed a company symlink")

# k=1 and k=2 keep their stage suffixes, but every label carries company and run id.
k1 = cli("shape-k1", 1, tmp / "lanes-k1.json")
if k1.returncode != 0:
    raise SystemExit(f"k=1 failed: {k1.stderr}")
planned = json.loads(k1.stdout)
argv_list = json.loads((tmp / "lanes-k1.json").read_text())
if planned["k"] != 1 or planned["company"] != "shape-k1" or planned["depth"] != 1:
    raise SystemExit(f"k=1 plan drifted: {planned}")
roll_suffixes = [suffix_of(stage["label"]) for stage in planned["rollouts"]]
session_suffixes = [suffix_of(stage["label"]) for stage in planned["sessions"]]
if roll_suffixes != ["rollout:incumbent", "rollout:probe"]:
    raise SystemExit(f"k=1 rollouts drifted: {roll_suffixes}")
if session_suffixes != ["session:propose", "session:compose"]:
    raise SystemExit(f"k=1 sessions drifted: {session_suffixes}")
if any(stage["label"] == "rollout:incumbent" for stage in planned["rollouts"]):
    raise SystemExit("k=1 label had no run id")
if any(stage["kind"] != "rollout" for stage in planned["rollouts"]):
    raise SystemExit("k=1 rollout kind drifted")
if any(stage["kind"] != "session" for stage in planned["sessions"]):
    raise SystemExit("k=1 session kind drifted")
labels = [stage["label"] for stage in planned["rollouts"] + planned["sessions"]]
if [item[4] for item in argv_list] != labels:
    raise SystemExit(f"lane argv labels drifted: {argv_list}")
if any(item[3] != "--label" for item in argv_list):
    raise SystemExit(f"lane argv missing --label: {argv_list}")
for argv in argv_list:
    if argv[:3] != ["hq", "lanes", "create"]:
        raise SystemExit(f"argv is not hq lanes create: {argv}")
    if "--provider" in argv or "--model-provider" in argv or "codex" in argv:
        raise SystemExit(f"provider override in argv: {argv}")
ledger_file = companies / "shape-k1" / "eval-library" / "shape-k1" / "ledger.json"
if not ledger_file.is_file():
    raise SystemExit("k=1 did not persist a ledger under the company eval library")
stored = json.loads(ledger_file.read_text())
if stored["depth"] != 1 or stored["company"] != "shape-k1" or len(stored["runs"]) != 1:
    raise SystemExit(f"persisted k=1 ledger drifted: {stored}")

try:
    ledger.lane_create_argv("indigo:abcdef0123456789:rollout:probe", provider="codex")
except ledger.LedgerError as exc:
    if "provider override" not in str(exc):
        raise SystemExit(f"unexpected provider error: {exc}")
else:
    raise SystemExit("provider=codex was accepted")

created = []
try:
    ledger.prepare(3, create_lane=created.append)
except ledger.LedgerError as exc:
    if "k exceeds hard cap" not in str(exc):
        raise SystemExit(f"unexpected k=3 error: {exc}")
else:
    raise SystemExit("prepare(3) returned a plan")
if created:
    raise SystemExit(f"k=3 created lanes: {created}")

bind_company("shape-k2")
k2, k2_argv = ledger.prepare(
    2,
    create_lane=created.append,
    companies_root=companies,
    company="shape-k2",
    class_id="shape-k2",
    session_company="shape-k2",
)
if len(k2["rollouts"]) > 6 or len(k2["sessions"]) > 6:
    raise SystemExit(f"k=2 exceeds the cap: {len(k2['rollouts'])} {len(k2['sessions'])}")
if [suffix_of(stage["label"]) for stage in k2["rollouts"]] != [
    "rollout:incumbent",
    "rollout:probe-1",
    "rollout:probe-2",
]:
    raise SystemExit(f"k=2 rollouts drifted: {k2['rollouts']}")
if [suffix_of(stage["label"]) for stage in k2["sessions"]] != [
    "session:propose-1",
    "session:compose-1",
    "session:propose-2",
    "session:compose-2",
    "session:retry",
]:
    raise SystemExit(f"k=2 sessions drifted: {k2['sessions']}")
if len(k2["rollouts"]) == 4 * 2 or len(k2["sessions"]) == 3 * 2:
    raise SystemExit("k=2 plan required R=4k or P=3k")
if sum(1 for stage in k2["sessions"] if suffix_of(stage["label"]) == "session:retry") != 1:
    raise SystemExit("k=2 plan did not include one retry")
if k2["depth"] != 2:
    raise SystemExit(f"k=2 did not consume the depth budget: {k2}")
run_ids = {stage["label"].split(":", 2)[1] for stage in k2["rollouts"] + k2["sessions"]}
if run_ids != {k2["run_id"]}:
    raise SystemExit("k=2 labels were not bound to the minted run")
for argv in k2_argv:
    if "--provider" in argv or "codex" in argv:
        raise SystemExit(f"k=2 provider override: {argv}")
try:
    open_book("shape-k2").plan(1)
except ledger.LedgerError as exc:
    if "parent run is required" not in str(exc):
        raise SystemExit(f"second plan after k=2 raised the wrong error: {exc}")
else:
    raise SystemExit("repeated plan after k=2 was accepted")
try:
    open_book("shape-k2").plan(1, parent_run_id=k2["run_id"])
except ledger.LedgerError as exc:
    if "k exceeds hard cap" not in str(exc):
        raise SystemExit(f"child after depth 2 raised the wrong error: {exc}")
else:
    raise SystemExit("child after depth 2 was accepted")

# Two k=1 plans share one file, then the third is refused. Labels do not collide.
label_book = open_book("labels")
first = label_book.plan(1)
second = label_book.plan(1, parent_run_id=first["run_id"])
if first["run_id"] == second["run_id"] or first["depth"] != 1 or second["depth"] != 2:
    raise SystemExit(f"depth was not carried: {first['depth']} {second['depth']}")
if first["rollouts"][0]["label"] == second["rollouts"][0]["label"]:
    raise SystemExit("two runs minted the same label")
try:
    label_book.plan(1)
except ledger.LedgerError as exc:
    if "parent run is required" not in str(exc):
        raise SystemExit(f"third k=1 without a parent raised the wrong error: {exc}")
else:
    raise SystemExit("third k=1 without a parent was accepted")
try:
    label_book.plan(1, parent_run_id=second["run_id"])
except ledger.LedgerError as exc:
    if "k exceeds hard cap" not in str(exc):
        raise SystemExit(f"third k=1 raised the wrong error: {exc}")
else:
    raise SystemExit("third k=1 was accepted")
# A new instance reads the file. It does not start from zero.
try:
    open_book("labels").plan(1)
except ledger.LedgerError as exc:
    if "parent run is required" not in str(exc):
        raise SystemExit(f"fresh instance ignored the ledger: {exc}")
else:
    raise SystemExit("fresh instance reset the depth")

# Recursion carries the parent recorded in the file, not a caller-supplied depth.
recur = open_book("recurse")
parent = recur.plan(1)
child = recur.plan(1, parent_run_id=parent["run_id"])
if child["depth"] != 2 or child["parent_run_id"] != parent["run_id"]:
    raise SystemExit(f"child depth was not carried: {child}")
try:
    recur.plan(1, parent_run_id=child["run_id"])
except ledger.LedgerError as exc:
    if "k exceeds hard cap" not in str(exc):
        raise SystemExit(f"grandchild raised the wrong error: {exc}")
else:
    raise SystemExit("recursion passed k=2")
try:
    open_book("recurse").plan(2, parent_run_id=child["run_id"])
except ledger.LedgerError as exc:
    if "k exceeds hard cap" not in str(exc):
        raise SystemExit(f"k=2 after two levels raised the wrong error: {exc}")
else:
    raise SystemExit("k=2 after two levels was accepted")
orphan = open_book("orphan")
try:
    orphan.plan(1, parent_run_id="0123456789abcdef")
except ledger.LedgerError as exc:
    if "unknown parent" not in str(exc):
        raise SystemExit(f"unknown parent raised the wrong error: {exc}")
else:
    raise SystemExit("unknown parent was accepted")
if (companies / "orphan" / "eval-library" / "orphan" / "ledger.json").exists():
    raise SystemExit("unknown parent wrote a ledger")

# Repeated k=2 does not start a second budget.
repeat = open_book("repeat-k2")
repeated = repeat.plan(2)
try:
    repeat.plan(2)
except ledger.LedgerError as exc:
    if "parent run is required" not in str(exc):
        raise SystemExit(f"repeated k=2 without a parent raised the wrong error: {exc}")
else:
    raise SystemExit("repeated k=2 without a parent was accepted")
try:
    repeat.plan(2, parent_run_id=repeated["run_id"])
except ledger.LedgerError as exc:
    if "k exceeds hard cap" not in str(exc):
        raise SystemExit(f"repeated k=2 raised the wrong error: {exc}")
else:
    raise SystemExit("repeated k=2 was accepted")

# Duplicate label raises before the count check. The first entry stays put.
book = open_book("dup")
opened = book.plan(1)
run_id = opened["run_id"]
first_raw = stage(run_id, "rollout:incumbent", "rollout", "lane-1", check="pass")
stored_stage = book.commit(first_raw)
snapshot = dict(stored_stage)
checks = book.count_checks
try:
    book.commit(stage(run_id, "rollout:incumbent", "rollout", "lane-2", check="pass", usd=99))
except ledger.LedgerError as exc:
    if str(exc) != "duplicate label":
        raise SystemExit(f"duplicate raised the wrong error: {exc}")
else:
    raise SystemExit("duplicate label was committed")
if book.entries[0] != snapshot:
    raise SystemExit(f"first entry changed: {book.entries[0]}")
if book.count_checks != checks:
    raise SystemExit("count check ran for a duplicate label")
if book.started:
    raise SystemExit("run started after a duplicate commit")
if book.lanes:
    raise SystemExit("duplicate commit recorded a lane")
if len(book.entries) != 1:
    raise SystemExit("duplicate commit appended a stage")

# A second instance sees the persisted entry and still rejects the duplicate.
other = open_book("dup")
if len(other.entries) != 1 or other.entries[0]["label"] != snapshot["label"]:
    raise SystemExit(f"second instance did not load the ledger: {other.entries}")
try:
    other.commit(stage(run_id, "rollout:incumbent", "rollout", "lane-3", check="pass"))
except ledger.LedgerError as exc:
    if str(exc) != "duplicate label":
        raise SystemExit(f"second instance duplicate raised the wrong error: {exc}")
else:
    raise SystemExit("second instance accepted a duplicate")

# Clearing the object does not drop the persisted entry.
book.entries.clear()
book.started = False
try:
    book.commit(stage(run_id, "rollout:incumbent", "rollout", "lane-4", check="pass"))
except ledger.LedgerError as exc:
    if str(exc) != "duplicate label":
        raise SystemExit(f"cleared ledger raised the wrong error: {exc}")
else:
    raise SystemExit("cleared entries accepted a duplicate")
if len(book.entries) != 1:
    raise SystemExit("clear discarded the persisted entry")

# A batch with a duplicate never starts, and the count check does not run.
batch = open_book("batch")
batch_plan = batch.plan(1)
batch_run = batch_plan["run_id"]
batch_stage = stage(batch_run, "rollout:probe", "rollout", "lane-b")
try:
    batch.start([batch_stage, dict(batch_stage, lane_id="lane-9")])
except ledger.LedgerError as exc:
    if str(exc) != "duplicate label":
        raise SystemExit(f"batch duplicate raised the wrong error: {exc}")
else:
    raise SystemExit("duplicate batch started")
if batch.entries or batch.started or batch.count_checks or batch.lanes:
    raise SystemExit(
        f"duplicate batch changed the ledger: {batch.entries} {batch.started} {batch.count_checks}"
    )

# A duplicate of a reserved label still raises before the count check.
full = open_book("cap")
full_plan = full.plan(1)
full_run = full_plan["run_id"]
full.commit(stage(full_run, "rollout:incumbent", "rollout", "lane-0", usd=0.5))
full.commit(stage(full_run, "rollout:probe", "rollout", "lane-1", usd=0.5))
before = full.count_checks
first_full = dict(full.entries[0])
try:
    full.commit(dict(full.entries[0]))
except ledger.LedgerError as exc:
    if str(exc) != "duplicate label":
        raise SystemExit(f"full ledger duplicate was not first: {exc}")
else:
    raise SystemExit("full ledger accepted a duplicate")
if full.count_checks != before or full.entries[0] != first_full:
    raise SystemExit("duplicate at the cap ran the count check or edited entry 0")
full.entries.clear()
full.started = False
try:
    full.commit(stage(full_run, "rollout:seventh", "rollout", "lane-7"))
except ledger.LedgerError as exc:
    if "not reserved" not in str(exc):
        raise SystemExit(f"unreserved rollout raised the wrong error: {exc}")
else:
    raise SystemExit("unreserved rollout was accepted")
if len(full.entries) != 2 or full.count_checks != before:
    raise SystemExit("unreserved label changed the persisted rollouts or ran the count check")
# The same refusal holds for a process that never held the first commits.
try:
    open_book("cap").commit(stage(full_run, "rollout:eighth", "rollout", "lane-8"))
except ledger.LedgerError as exc:
    if "not reserved" not in str(exc):
        raise SystemExit(f"second instance unreserved rollout raised the wrong error: {exc}")
else:
    raise SystemExit("second instance accepted an unreserved rollout")
# The literal 6 ceiling still refuses another rollout once the counter is there.
try:
    full._check_counts({"rollout_count": 6, "session_count": 0}, ("rollout",))
except ledger.LedgerError as exc:
    if "rollout cap" not in str(exc):
        raise SystemExit(f"rollout cap raised the wrong error: {exc}")
else:
    raise SystemExit("rollout cap accepted a seventh rollout")

# Spoofed labels are not accepted.
spoof = open_book("spoof")
spoof_run = spoof.plan(1)["run_id"]
for raw_label in (
    f"acme:{spoof_run}:rollout:x",
    "indigo:deadbeefdeadbeef:rollout:x",
    "rollout:incumbent",
):
    raw = stage(spoof_run, "rollout:x", "rollout", "lane-s")
    raw["label"] = raw_label
    try:
        spoof.commit(raw)
    except ledger.LedgerError as exc:
        if "not bound" not in str(exc):
            raise SystemExit(f"spoofed label raised the wrong error: {exc}")
    else:
        raise SystemExit(f"spoofed label was committed: {raw_label}")
if spoof.entries:
    raise SystemExit("spoofed label left an entry")

# start freezes the file. Clearing the object does not open it again.
frozen = open_book("frozen")
frozen_run = frozen.plan(1)["run_id"]
frozen.start([stage(frozen_run, "rollout:incumbent", "rollout", "lane-f")])
if frozen.started is not True or len(frozen.entries) != 1:
    raise SystemExit("start did not record the batch")
frozen.started = False
frozen.entries.clear()
try:
    frozen.commit(stage(frozen_run, "rollout:two", "rollout", "lane-f2"))
except ledger.LedgerError as exc:
    if "already started" not in str(exc):
        raise SystemExit(f"commit after start raised the wrong error: {exc}")
else:
    raise SystemExit("commit after start was accepted")
frozen.started = False
try:
    frozen.start([stage(frozen_run, "rollout:three", "rollout", "lane-f3")])
except ledger.LedgerError as exc:
    if "already started" not in str(exc):
        raise SystemExit(f"restart raised the wrong error: {exc}")
else:
    raise SystemExit("clearing started allowed a second start")
reloaded = open_book("frozen")
if reloaded.started is not True or len(reloaded.entries) != 1:
    raise SystemExit(f"restart view drifted: {reloaded.started} {reloaded.entries}")

# A failed check is excluded, not 0, and is left out of the mean.
if ledger.classify_check(True, False) != "excluded":
    raise SystemExit("failed check was not excluded")
if ledger.classify_check(True, False) == 0:
    raise SystemExit("failed check was stored as 0")
if ledger.classify_check(False) != "unscored":
    raise SystemExit("unrun check was not unscored")
if ledger.can_adopt("unscored") or ledger.can_adopt("excluded"):
    raise SystemExit("unscored or excluded check can be adopted")
if not ledger.can_adopt("pass"):
    raise SystemExit("passing check cannot be adopted")

scored = open_book("scored")
scored_run = scored.plan(1)["run_id"]
passed = scored.commit(
    stage(
        scored_run,
        "rollout:incumbent",
        "rollout",
        "lane-inc",
        check=ledger.classify_check(True, True),
        usd=ledger.usd_from_lane({}),
    )
)
failed = scored.commit(
    stage(
        scored_run,
        "rollout:probe",
        "rollout",
        "lane-probe",
        check=ledger.classify_check(True, False),
        usd=ledger.usd_from_lane({"usd": None}),
        account="b",
    )
)
missed = scored.commit(
    stage(
        scored_run,
        "session:propose",
        "session",
        "lane-propose",
        check=ledger.classify_check(False),
        usd=ledger.usd_from_lane({"usd": ""}),
    )
)
for entry in (passed, failed, missed):
    for field in ("label", "kind", "lane_id", "provider", "account", "usd"):
        if field not in entry or entry[field] in ("", None):
            raise SystemExit(f"stage missing {field}: {entry}")
if passed["usd"] != "unpriced" or failed["usd"] != "unpriced" or missed["usd"] != "unpriced":
    raise SystemExit("missing usd was not unpriced")
if failed["check"] != "excluded" or "value" in failed or failed.get("value") == 0:
    raise SystemExit(f"failed check stored a number: {failed}")
if missed["check"] != "unscored":
    raise SystemExit(f"missed check drifted: {missed}")
aggregate = scored.mean()
if aggregate["denominator"] != 1 or aggregate["mean"] != 1.0:
    raise SystemExit(f"mean included the failed check: {aggregate}")
priced = scored.commit(
    stage(
        scored_run,
        "session:compose",
        "session",
        "lane-compose",
        check="pass",
        usd=ledger.usd_from_lane({"usd": 1.25}),
    )
)
if priced["usd"] != 1.25:
    raise SystemExit(f"numeric usd was rewritten: {priced}")
closed = scored.finalize(1)
if closed["required_identity"] is not None:
    raise SystemExit("finalize required an identity")
if closed["rollouts"] == 4 or closed["sessions"] == 3:
    raise SystemExit("finalize counted the harness2 identity")
if closed["rollouts"] != 2 or closed["sessions"] != 2:
    raise SystemExit(f"finalize counts drifted: {closed}")

# finalize(1) refuses a class whose own run has k greater than 1.
wide = open_book("wide")
wide.plan(2)
try:
    wide.finalize(1)
except ledger.LedgerError as exc:
    if "counts exceed k" not in str(exc):
        raise SystemExit(f"finalize(1) on a depth-2 ledger raised the wrong error: {exc}")
else:
    raise SystemExit("finalize(1) accepted a depth-2 ledger")
try:
    wide._check_counts({"rollout_count": 0, "session_count": 6}, ("session",))
except ledger.LedgerError as exc:
    if "session cap" not in str(exc):
        raise SystemExit(f"session cap raised the wrong error: {exc}")
else:
    raise SystemExit("session cap accepted a seventh session")
fit = open_book("fit-k2")
fit_run = fit.plan(2)["run_id"]
for index, suffix in enumerate(("rollout:incumbent", "rollout:probe-1", "rollout:probe-2")):
    fit.commit(stage(fit_run, suffix, "rollout", f"lane-r{index}", check="pass"))
for index, suffix in enumerate(
    ("session:propose-1", "session:compose-1", "session:propose-2", "session:compose-2", "session:retry")
):
    fit.commit(stage(fit_run, suffix, "session", f"lane-s{index}", check="pass"))
fit_closed = fit.finalize(2)
if fit_closed["rollouts"] != 3 or fit_closed["sessions"] != 5 or fit_closed["required_identity"] is not None:
    raise SystemExit(f"k=2 finalize drifted: {fit_closed}")

# A k=1 root and a same-class k=1 child finalize as k=1. Depth 2 is the chain,
# not a reason to refuse. Three committed rollouts are inside the two plans
# (four reserved) and inside 6, and past a single k=1 plan's two rollouts.
bind_company("shared")
shared = ledger.Ledger(companies, "shared", "c1", "shared")
shared_root = shared.plan(1)["run_id"]
shared_child = shared.plan(1, parent_run_id=shared_root)["run_id"]
for run_id, suffixes in (
    (shared_root, ("rollout:incumbent", "rollout:probe")),
    (shared_child, ("rollout:incumbent",)),
):
    for suffix in suffixes:
        shared.commit(stage(run_id, suffix, "rollout", f"lane-{run_id[:4]}-{suffix}", check="pass"))
shared_closed = shared.finalize(1)
if shared_closed["rollouts"] != 3 or shared_closed["sessions"] != 0 or shared_closed["required_identity"] is not None:
    raise SystemExit(f"shared-class finalize(1) drifted: {shared_closed}")
shared_body = json.loads((companies / "shared" / "eval-library" / "c1" / "ledger.json").read_text())
if shared_body.get("finalized") is not True:
    raise SystemExit(f"finalize did not record the finished state: {shared_body.get('finalized')}")
try:
    shared.plan(1, parent_run_id=shared_root)
except ledger.LedgerError as exc:
    if "parent run is finished" not in str(exc):
        raise SystemExit(f"plan after finalize raised the wrong error: {exc}")
else:
    raise SystemExit("plan after finalize was accepted")

# Finishing the root before any child refuses the child while budget remains.
bind_company("done-root")
done = ledger.Ledger(companies, "done-root", "c1", "done-root")
done_id = done.plan(1)["run_id"]
done.finalize(1)
try:
    ledger.Ledger(companies, "done-root", "c2", "done-root").plan(1, parent_run_id=done_id)
except ledger.LedgerError as exc:
    if "parent run is finished" not in str(exc):
        raise SystemExit(f"child of a finished run raised the wrong error: {exc}")
else:
    raise SystemExit("child of a finished run was accepted")
if (companies / "done-root" / "eval-library" / "c2" / "ledger.json").exists():
    raise SystemExit("child of a finished run wrote a ledger")
# A finished class takes no new stage and cannot be started.
done_bytes = (companies / "done-root" / "eval-library" / "c1" / "ledger.json").read_bytes()
for attempt, call in (
    ("commit", lambda: done.commit({"label": ledger.format_label("done-root", done_id, "session:compose"), "kind": ledger.KIND_SESSION, "lane_id": "x", "provider": "none", "account": "none", "usd": ledger.UNPRICED})),
    ("start", lambda: done.start([stage(done_id, "rollout:late", "rollout", "lane-late")])),
):
    try:
        call()
    except ledger.LedgerError as exc:
        if "run is finished" not in str(exc):
            raise SystemExit(f"{attempt} after finalize raised the wrong error: {exc}")
    else:
        raise SystemExit(f"{attempt} after finalize was accepted")
if (companies / "done-root" / "eval-library" / "c1" / "ledger.json").read_bytes() != done_bytes:
    raise SystemExit("refused stage changed a finished ledger")

try:
    ledger.normalize_stage(
        {
            "label": "rollout:zero",
            "kind": "rollout",
            "lane_id": "lane-z",
            "provider": "grok",
            "account": "a",
            "usd": "unpriced",
            "check": "excluded",
            "value": 0,
        }
    )
except ledger.LedgerError as exc:
    if "not 0" not in str(exc) and "no numeric value" not in str(exc):
        raise SystemExit(f"zero value raised the wrong error: {exc}")
else:
    raise SystemExit("excluded check accepted value 0")

# Corrupt, edited, unreadable, and deleted ledgers fail closed and are not rewritten.
bad_state = open_book("bad-file")
bad_state.plan(1)
bad_path = companies / "bad-file" / "eval-library" / "bad-file" / "ledger.json"
marker = bad_path.parent / "ledger.created"
original = bad_path.read_bytes()
bad_path.write_text("{", encoding="utf-8")
try:
    open_book("bad-file")
except ledger.LedgerError as exc:
    if "corrupt" not in str(exc):
        raise SystemExit(f"corrupt ledger raised the wrong error: {exc}")
else:
    raise SystemExit("corrupt ledger opened")
if bad_path.read_text(encoding="utf-8") != "{":
    raise SystemExit("corrupt ledger was rewritten")
bad_path.write_bytes(original)
edited = json.loads(original.decode("utf-8"))
edited["depth"] = 5
edited["company"] = "acme"
payload = json.dumps(edited)
bad_path.write_text(payload, encoding="utf-8")
try:
    open_book("bad-file")
except ledger.LedgerError as exc:
    if "invalid" not in str(exc):
        raise SystemExit(f"edited ledger raised the wrong error: {exc}")
else:
    raise SystemExit("edited ledger opened")
if bad_path.read_text(encoding="utf-8") != payload:
    raise SystemExit("edited ledger was rewritten")
bad_path.write_bytes(original)
tweaked = json.loads(original.decode("utf-8"))
tweaked["rollout_count"] = 4
count_payload = json.dumps(tweaked)
bad_path.write_text(count_payload, encoding="utf-8")
try:
    open_book("bad-file")
except ledger.LedgerError as exc:
    if "invalid" not in str(exc):
        raise SystemExit(f"count mismatch raised the wrong error: {exc}")
else:
    raise SystemExit("count mismatch was accepted")
if bad_path.read_text(encoding="utf-8") != count_payload:
    raise SystemExit("count mismatch was rewritten")
bad_path.write_bytes(original)
duped = json.loads(original.decode("utf-8"))
duped["runs"][0]["labels"].append(duped["runs"][0]["labels"][0])
dup_payload = json.dumps(duped)
bad_path.write_text(dup_payload, encoding="utf-8")
try:
    open_book("bad-file")
except ledger.LedgerError as exc:
    if "invalid" not in str(exc):
        raise SystemExit(f"duplicate stored label raised the wrong error: {exc}")
else:
    raise SystemExit("duplicate stored label was accepted")
bad_path.write_bytes(original)
os.chmod(bad_path, 0)
try:
    try:
        open_book("bad-file")
    except ledger.LedgerError as exc:
        if "unreadable" not in str(exc):
            raise SystemExit(f"unreadable ledger raised the wrong error: {exc}")
    else:
        raise SystemExit("unreadable ledger opened")
finally:
    os.chmod(bad_path, 0o644)
if bad_path.read_bytes() != original:
    raise SystemExit("unreadable ledger was rewritten")
bad_path.unlink()
if not marker.is_file():
    raise SystemExit("created marker disappeared")
try:
    open_book("bad-file")
except ledger.LedgerError as exc:
    if "missing" not in str(exc):
        raise SystemExit(f"missing ledger raised the wrong error: {exc}")
else:
    raise SystemExit("missing ledger was treated as empty")
if bad_path.exists():
    raise SystemExit("missing ledger was recreated")

# A new class does not get a fresh k=2 budget. Depth follows the parent chain.
bind_company("chainco")
exhausted = ledger.Ledger(companies, "chainco", "c2", "chainco").plan(2)
if exhausted["depth"] != 2 or exhausted["parent_run_id"] is not None:
    raise SystemExit(f"chain root drifted: {exhausted}")
try:
    ledger.Ledger(companies, "chainco", "c3", "chainco").plan(2)
except ledger.LedgerError as exc:
    if "parent run is required" not in str(exc):
        raise SystemExit(f"new class without a parent raised the wrong error: {exc}")
else:
    raise SystemExit("new class accepted a fresh k=2 budget")
if (companies / "chainco" / "eval-library" / "c3" / "ledger.json").exists():
    raise SystemExit("refused child wrote a ledger")
try:
    ledger.Ledger(companies, "chainco", "c3", "chainco").plan(1, parent_run_id=exhausted["run_id"])
except ledger.LedgerError as exc:
    if "k exceeds hard cap" not in str(exc):
        raise SystemExit(f"child of a depth-2 run raised the wrong error: {exc}")
else:
    raise SystemExit("child of a depth-2 run was accepted")

bind_company("tree")
root_run = ledger.Ledger(companies, "tree", "c2", "tree").plan(1)
child_run = ledger.Ledger(companies, "tree", "c3", "tree").plan(1, parent_run_id=root_run["run_id"])
if child_run["depth"] != 2 or child_run["parent_run_id"] != root_run["run_id"]:
    raise SystemExit(f"cross-class child depth was not the chain: {child_run}")
try:
    ledger.Ledger(companies, "tree", "c4", "tree").plan(1)
except ledger.LedgerError as exc:
    if "parent run is required" not in str(exc):
        raise SystemExit(f"orphan class raised the wrong error: {exc}")
else:
    raise SystemExit("orphan class was accepted while a run was active")
child_file = json.loads((companies / "tree" / "eval-library" / "c3" / "ledger.json").read_text())
if child_file["depth"] != 2 or child_file["runs"][0]["parent_run_id"] != root_run["run_id"]:
    raise SystemExit(f"cross-class ledger did not store the chain: {child_file}")

# Siblings share the tree budget. One k=1 child of a k=1 root is the budget.
# A second child, in another class or in the same class, is refused.
bind_company("sib")
sib_root = ledger.Ledger(companies, "sib", "c1", "sib").plan(1)
sib_child = ledger.Ledger(companies, "sib", "c2", "sib").plan(1, parent_run_id=sib_root["run_id"])
if sib_child["depth"] != 2 or sib_child["parent_run_id"] != sib_root["run_id"]:
    raise SystemExit(f"first sibling was not accepted at depth 2: {sib_child}")
try:
    ledger.Ledger(companies, "sib", "c3", "sib").plan(1, parent_run_id=sib_root["run_id"])
except ledger.LedgerError as exc:
    if "k exceeds hard cap" not in str(exc):
        raise SystemExit(f"second sibling class raised the wrong error: {exc}")
else:
    raise SystemExit("second sibling class was accepted")
if (companies / "sib" / "eval-library" / "c3" / "ledger.json").exists():
    raise SystemExit("second sibling class wrote a ledger")
try:
    ledger.Ledger(companies, "sib", "c1", "sib").plan(1, parent_run_id=sib_root["run_id"])
except ledger.LedgerError as exc:
    if "k exceeds hard cap" not in str(exc):
        raise SystemExit(f"same-class sibling raised the wrong error: {exc}")
else:
    raise SystemExit("same-class sibling was accepted")
sib_root_body = json.loads((companies / "sib" / "eval-library" / "c1" / "ledger.json").read_text())
sib_child_body = json.loads((companies / "sib" / "eval-library" / "c2" / "ledger.json").read_text())
if len(sib_root_body["runs"]) != 1 or len(sib_child_body["runs"]) != 1:
    raise SystemExit(f"sibling refusal mutated the tree: {sib_root_body['runs']} {sib_child_body['runs']}")

# A chain past depth 2 stays refused. The tree budget and the HQ root are documented.
source = Path(ledger_path).read_text(encoding="utf-8")
if "stays refused" not in source or "Local files are trusted" not in source:
    raise SystemExit("depth-2 lifetime or trust model is not documented")
if "ledger.created" not in source or "no reset command" not in source:
    raise SystemExit("reset procedure is not documented")
if "A class at depth 2 stays refused" in source or "any later class" in source:
    raise SystemExit("docstring still refuses every depth-2 class")
if "sum of k" not in source:
    raise SystemExit("tree budget is not documented")
if "not the parent of" not in source:
    raise SystemExit("HQ root rule is not documented")
if "parent run is finished" not in source:
    raise SystemExit("finished run is not documented")

# Reserved stage labels, including a suffix that is not in the plan, and a mismatched kind.
reserved = open_book("reserved")
reserved_run = reserved.plan(1)["run_id"]
reserved_company = ACTIVE["company"]
for raw_label in (
    f"{reserved_company}:{reserved_run}:anything",
    f"{reserved_company}:{reserved_run}:rollout:x",
):
    raw = stage(reserved_run, "rollout:probe", "rollout", "lane-r")
    raw["label"] = raw_label
    try:
        reserved.commit(raw)
    except ledger.LedgerError as exc:
        if "not reserved" not in str(exc):
            raise SystemExit(f"unreserved stage raised the wrong error: {exc}")
    else:
        raise SystemExit(f"unreserved stage was committed: {raw_label}")
mismatched = stage(reserved_run, "rollout:incumbent", "session", "lane-kind")
try:
    reserved.commit(mismatched)
except ledger.LedgerError as exc:
    if "kind" not in str(exc):
        raise SystemExit(f"kind mismatch raised the wrong error: {exc}")
else:
    raise SystemExit("kind was not tied to the reserved stage")
if reserved.entries:
    raise SystemExit("unreserved commit left an entry")

# The lock is opened with O_NOFOLLOW. A planted symlink must not create the target.
bind_company("lockco")
lock_dir = companies / "lockco" / "eval-library" / "c1"
lock_dir.mkdir(parents=True)
outside_lock = tmp / "escaped-lock"
(lock_dir / "ledger.lock").symlink_to(outside_lock)
try:
    ledger.Ledger(companies, "lockco", "c1", "lockco").plan(1)
except ledger.LedgerError as exc:
    if "symlink" not in str(exc):
        raise SystemExit(f"lock symlink raised the wrong error: {exc}")
else:
    raise SystemExit("lock symlink was followed")
if outside_lock.exists() or (lock_dir / "ledger.json").exists():
    raise SystemExit("lock symlink created a file outside the class or wrote a ledger")

# Session lock, not the CLI flag. Unknown companies are not created. Slugs are ASCII.
bind_company("indigo")
manifest_companies.add("holler")
write_manifest()
(companies / "holler").mkdir(exist_ok=True)
bind_company("indigo")
try:
    ledger.Ledger(companies, "holler", "c", "holler")
except ledger.LedgerError as exc:
    if "session bind" not in str(exc):
        raise SystemExit(f"unlocked company raised the wrong error: {exc}")
else:
    raise SystemExit("CLI session flag bound a company the HQ session lock does not name")
if (companies / "holler" / "eval-library").exists():
    raise SystemExit("unlocked company created an eval library")

meta_path.write_text("company_slug: ghost\ncompany_slugs: ghost\n", encoding="utf-8")
try:
    ledger.Ledger(companies, "ghost", "c", "ghost")
except ledger.LedgerError as exc:
    if "unknown company" not in str(exc):
        raise SystemExit(f"unknown company raised the wrong error: {exc}")
else:
    raise SystemExit("unknown company was accepted")
if (companies / "ghost").exists():
    raise SystemExit("unknown company directory was created")
bind_company("indigo")

non_ascii = "indig\u00e9"
try:
    ledger.Ledger(companies, non_ascii, "c", non_ascii)
except ledger.LedgerError as exc:
    if "invalid" not in str(exc):
        raise SystemExit(f"non-ASCII slug raised the wrong error: {exc}")
else:
    raise SystemExit("non-ASCII slug was accepted")
if any(not path.name.isascii() for path in companies.iterdir()):
    raise SystemExit("non-ASCII slug created a company directory")

# --companies-root does not choose the HQ root. A tree outside HQ_ROOT is refused.
fake_hq = Path(tempfile.mkdtemp(prefix="eval-ledger-outside-"))
try:
    try:
        fake_hq.resolve().relative_to(tmp.resolve())
    except ValueError:
        pass
    else:
        raise SystemExit("outside fixture was created inside the HQ root")
    fake_companies = fake_hq / "companies"
    fake_companies.mkdir()
    (fake_companies / "manifest.yaml").write_text(
        "companies:\n  acme:\n    name: acme\n",
        encoding="utf-8",
    )
    (fake_companies / "acme").mkdir()
    fake_meta = fake_hq / "workspace" / "sessions" / session_id
    fake_meta.mkdir(parents=True)
    (fake_meta / "meta.yaml").write_text(
        "company_slug: acme\ncompany_slugs: acme\n",
        encoding="utf-8",
    )
    try:
        ledger.Ledger(fake_companies, "acme", "c1", "acme").plan(2)
    except ledger.LedgerError as exc:
        if "companies root is not the HQ root companies directory" not in str(exc):
            raise SystemExit(f"outside companies root raised the wrong error: {exc}")
    else:
        raise SystemExit("companies root outside the HQ root was accepted")
    if (fake_companies / "acme" / "eval-library").exists():
        raise SystemExit("outside companies root created an eval library")
finally:
    shutil.rmtree(fake_hq)

# A second companies tree nested inside the HQ root, with its own manifest and
# a company whose real budget is spent, must not get a fresh budget.
spent = bind_company("nestedspent")
ledger.Ledger(companies, spent, "c1", spent).plan(2)
try:
    ledger.Ledger(companies, spent, "c2", spent).plan(2)
except ledger.LedgerError:
    pass
else:
    raise SystemExit("real budget was not spent before the nested-root probe")
nested_companies = tmp / "workspace" / "evil" / "companies"
nested_companies.mkdir(parents=True)
(nested_companies / "manifest.yaml").write_text(
    f"companies:\n  {spent}:\n    name: {spent}\n",
    encoding="utf-8",
)
(nested_companies / spent).mkdir()
try:
    ledger.Ledger(nested_companies, spent, "c1", spent).plan(2)
except ledger.LedgerError as exc:
    if "companies root is not the HQ root companies directory" not in str(exc):
        raise SystemExit(f"nested companies root raised the wrong error: {exc}")
else:
    raise SystemExit("nested companies root inside the HQ root got a fresh budget")
if (nested_companies / spent / "eval-library").exists():
    raise SystemExit("nested companies root created an eval library")
shutil.rmtree(tmp / "workspace" / "evil")


def run_many(k, count, class_id):
    bind_company(class_id)
    procs = []
    for index in range(count):
        lanes = tmp / f"{class_id}-{index}.json"
        procs.append(
            subprocess.Popen(
                [
                    py,
                    "-I",
                    ledger_path,
                    "plan",
                    "--k",
                    str(k),
                    "--company",
                    class_id,
                    "--class",
                    class_id,
                    "--companies-root",
                    str(companies),
                    "--session-company",
                    class_id,
                    "--lanes",
                    str(lanes),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        )
    results = []
    for proc in procs:
        try:
            out, err = proc.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
            raise SystemExit(f"parallel k={k} hung")
        results.append((proc.returncode, out, err))
    return results


for k, class_id in ((2, "par-k2"), (1, "par-k1")):
    results = run_many(k, 8, class_id)
    ok = [(out, err) for code, out, err in results if code == 0]
    bad = [(code, out, err) for code, out, err in results if code != 0]
    if len(ok) != 1:
        raise SystemExit(f"parallel k={k} successes {len(ok)} errors {[err for _, _, err in bad]}")
    labels = []
    for out, _err in ok:
        body = json.loads(out)
        if body["company"] != class_id or not body["run_id"] or body["depth"] != k:
            raise SystemExit(f"parallel plan was not bound: {body}")
        for item in body["rollouts"] + body["sessions"]:
            if not item["label"].startswith(f"{class_id}:{body['run_id']}:"):
                raise SystemExit(f"parallel label was not unique to the run: {item['label']}")
            labels.append(item["label"])
    if len(labels) != len(set(labels)):
        raise SystemExit(f"parallel k={k} reused a label")
    for code, _out, err in bad:
        if "Traceback" in err or "parent run is required" not in err:
            raise SystemExit(f"parallel k={k} failure was not the parent rule: {code} {err}")
    path = companies / class_id / "eval-library" / class_id / "ledger.json"
    body = json.loads(path.read_text())
    if body["depth"] != k or len(body["runs"]) != 1:
        raise SystemExit(f"parallel k={k} ledger drifted: {body}")
    temps = list(path.parent.glob(".ledger-*")) + list(path.parent.glob(".lanes-*"))
    if temps:
        raise SystemExit(f"atomic write left temp files: {temps}")


def run_children(company, parent_run_id, count):
    bind_company(company)
    procs = []
    for index in range(count):
        class_id = f"c{index:02d}"
        lanes = tmp / f"{company}-{class_id}.json"
        procs.append(
            subprocess.Popen(
                [
                    py,
                    "-I",
                    ledger_path,
                    "plan",
                    "--k",
                    "1",
                    "--company",
                    company,
                    "--class",
                    class_id,
                    "--companies-root",
                    str(companies),
                    "--session-company",
                    company,
                    "--lanes",
                    str(lanes),
                    "--parent-run",
                    parent_run_id,
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        )
    results = []
    for proc in procs:
        try:
            out, err = proc.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
            raise SystemExit("parallel children hung")
        results.append((proc.returncode, out, err))
    return results


bind_company("par-kids")
kids_root = ledger.Ledger(companies, "par-kids", "root", "par-kids").plan(1)
kids = run_children("par-kids", kids_root["run_id"], 20)
kids_ok = [(out, err) for code, out, err in kids if code == 0]
kids_bad = [(code, out, err) for code, out, err in kids if code != 0]
if len(kids_ok) != 1 or len(kids_bad) != 19:
    raise SystemExit(
        f"parallel children successes {len(kids_ok)} errors {[err for _, _, err in kids_bad]}"
    )
kids_body = json.loads(kids_ok[0][0])
if kids_body["depth"] != 2 or kids_body["parent_run_id"] != kids_root["run_id"]:
    raise SystemExit(f"parallel child was not depth 2 under the root: {kids_body}")
for code, _out, err in kids_bad:
    if "Traceback" in err or "k exceeds hard cap" not in err or "parent run is required" in err:
        raise SystemExit(f"parallel child failure was not the tree budget: {code} {err}")
kids_ledgers = list((companies / "par-kids" / "eval-library").glob("c*/ledger.json"))
if len(kids_ledgers) != 1:
    raise SystemExit(f"parallel children wrote {len(kids_ledgers)} ledgers")
root_ledger = json.loads(
    (companies / "par-kids" / "eval-library" / "root" / "ledger.json").read_text()
)
if len(root_ledger["runs"]) != 1:
    raise SystemExit(f"parallel children mutated the root: {root_ledger}")


# PR 1416 review, critical 1: an empty batch must not mark the run started.
# start([]) and start(<empty generator>) used to save started=True with no
# entries, and every later commit failed with "already started".
empty_book = open_book("empty-start")
empty_run = empty_book.plan(1)["run_id"]
for empty_batch in ([], (item for item in ())):
    try:
        empty_book.start(empty_batch)
    except ledger.LedgerError as exc:
        if "empty batch" not in str(exc):
            raise SystemExit(f"empty batch raised the wrong error: {exc}")
    else:
        raise SystemExit("empty batch was accepted")
empty_body = json.loads((companies / "empty-start" / "eval-library" / "empty-start" / "ledger.json").read_text())
if empty_body["started"] is not False or empty_body["entries"]:
    raise SystemExit(f"empty batch changed the ledger: {empty_body}")
if open_book("empty-start").started is not False:
    raise SystemExit("empty batch left the run started")
empty_book.commit(stage(empty_run, "rollout:incumbent", "rollout", "lane-e1"))

# A generator batch is read once and stored in full, not consumed by the
# duplicate scan and then stored as nothing.
gen_book = open_book("gen-start")
gen_run = gen_book.plan(1)["run_id"]
gen_stored = gen_book.start(
    stage(gen_run, suffix, "rollout", f"lane-g{index}")
    for index, suffix in enumerate(("rollout:incumbent", "rollout:probe"))
)
gen_body = json.loads((companies / "gen-start" / "eval-library" / "gen-start" / "ledger.json").read_text())
if len(gen_stored) != 2 or len(gen_body["entries"]) != 2 or gen_body["rollout_count"] != 2:
    raise SystemExit(f"generator batch was not stored in full: {gen_body}")

# PR 1416 review, critical 2: mean() averages pass scores, not a constant
# 1.0, and reports the stages it left out.
avg = open_book("mean-score")
avg_run = avg.plan(1)["run_id"]
avg.commit(dict(stage(avg_run, "rollout:incumbent", "rollout", "lane-m1", check="pass"), value=0.5))
avg.commit(stage(avg_run, "rollout:probe", "rollout", "lane-m2", check="pass"))
avg.commit(stage(avg_run, "session:propose", "session", "lane-m3", check="excluded"))
avg.commit(stage(avg_run, "session:compose", "session", "lane-m4", check="unscored"))
avg_mean = avg.mean()
if avg_mean != {"mean": 0.75, "denominator": 2, "excluded": 1, "unscored": 1}:
    raise SystemExit(f"mean did not average the pass scores: {avg_mean}")
avg_body = json.loads((companies / "mean-score" / "eval-library" / "mean-score" / "ledger.json").read_text())
if [entry.get("value") for entry in avg_body["entries"]] != [0.5, 1, None, None]:
    raise SystemExit(f"pass scores were not stored as given: {avg_body['entries']}")
# One pass and three exclusions report three excluded beside the mean.
lone = open_book("mean-lone")
lone_run = lone.plan(2)["run_id"]
lone.commit(stage(lone_run, "rollout:incumbent", "rollout", "lane-l0", check="pass"))
for index, suffix in enumerate(("rollout:probe-1", "rollout:probe-2", "session:propose-1")):
    kind = "session" if suffix.startswith("session") else "rollout"
    lone.commit(stage(lone_run, suffix, kind, f"lane-l{index + 1}", check="excluded"))
if lone.mean() != {"mean": 1.0, "denominator": 1, "excluded": 3, "unscored": 0}:
    raise SystemExit(f"mean hid the excluded stages: {lone.mean()}")
if open_book("mean-empty").mean() != {"mean": None, "denominator": 0, "excluded": 0, "unscored": 0}:
    raise SystemExit("empty mean drifted")
# A pass score outside (0, 1] is refused, not rewritten to 1.
for bad_score in (-1, 1.5, float("nan"), float("inf"), True, "0.5"):
    try:
        ledger.normalize_stage(dict(stage(avg_run, "rollout:x", "rollout", "lane-x", check="pass"), value=bad_score))
    except ledger.LedgerError as exc:
        if "passing score" not in str(exc):
            raise SystemExit(f"pass score {bad_score!r} raised the wrong error: {exc}")
    else:
        raise SystemExit(f"pass score {bad_score!r} was accepted")
# A value on an unscored check is refused, not dropped.
for bad_value in ("0", 1):
    try:
        ledger.normalize_stage(dict(stage(avg_run, "rollout:x", "rollout", "lane-x"), value=bad_value))
    except ledger.LedgerError as exc:
        if "unscored check has no numeric value" not in str(exc):
            raise SystemExit(f"unscored value {bad_value!r} raised the wrong error: {exc}")
    else:
        raise SystemExit(f"unscored value {bad_value!r} was accepted")
# A tampered pass score in the file is refused on load.
tamper_path = companies / "mean-score" / "eval-library" / "mean-score" / "ledger.json"
tamper_saved = tamper_path.read_bytes()
tamper_body = json.loads(tamper_saved)
tamper_body["entries"][0]["value"] = 7
tamper_path.write_text(json.dumps(tamper_body), encoding="utf-8")
try:
    open_book("mean-score")
except ledger.LedgerError as exc:
    if "invalid ledger" not in str(exc):
        raise SystemExit(f"tampered score raised the wrong error: {exc}")
else:
    raise SystemExit("tampered pass score loaded")
tamper_path.write_bytes(tamper_saved)

# usd must be finite and not negative. NaN must not reach ledger.json.
bind_company("usd-check")
usd_run = "0123456789abcdef"
for bad_usd in (float("nan"), float("inf"), -0.5):
    try:
        ledger.normalize_stage(stage(usd_run, "rollout:x", "rollout", "lane-x", usd=bad_usd))
    except ledger.LedgerError as exc:
        if "usd must be" not in str(exc):
            raise SystemExit(f"usd {bad_usd!r} raised the wrong error: {exc}")
    else:
        raise SystemExit(f"usd {bad_usd!r} was accepted")
if ledger.normalize_stage(stage(usd_run, "rollout:x", "rollout", "lane-x", usd=0))["usd"] != 0:
    raise SystemExit("zero usd was refused")

# A class whose ledger.json is gone but whose created marker remains is not
# skipped by the company tree: a new root in another class is refused.
bind_company("gone-class")
gone = ledger.Ledger(companies, "gone-class", "c1", "gone-class")
gone.plan(1)
(companies / "gone-class" / "eval-library" / "c1" / "ledger.json").unlink()
try:
    ledger.Ledger(companies, "gone-class", "c2", "gone-class").plan(2)
except ledger.LedgerError as exc:
    if "ledger missing" not in str(exc):
        raise SystemExit(f"missing sibling ledger raised the wrong error: {exc}")
else:
    raise SystemExit("missing sibling ledger opened a fresh budget")
if (companies / "gone-class" / "eval-library" / "c2" / "ledger.json").exists():
    raise SystemExit("missing sibling ledger let a new class write")

# finalize(k) must equal the planned k. finalize(2) on a k=1 run is refused.
narrow = open_book("narrow")
narrow.plan(1)
try:
    narrow.finalize(2)
except ledger.LedgerError as exc:
    if "k does not match the planned run" not in str(exc):
        raise SystemExit(f"finalize(2) on k=1 raised the wrong error: {exc}")
else:
    raise SystemExit("finalize(2) accepted a k=1 run")
if json.loads((companies / "narrow" / "eval-library" / "narrow" / "ledger.json").read_text())["finalized"]:
    raise SystemExit("refused finalize recorded the finished state")
narrow.finalize(1)

# --lanes under the HQ root's core/ is refused and writes nothing.
core_lanes = tmp / "core" / "policies" / "lanes.json"
core_run = cli("lanes-core", 1, core_lanes)
if core_run.returncode == 0 or core_lanes.exists() or "Traceback" in core_run.stderr:
    raise SystemExit(f"lanes under core was accepted: {core_run.returncode} {core_run.stderr}")
if "lanes path is under core" not in core_run.stderr:
    raise SystemExit(f"lanes under core raised the wrong error: {core_run.stderr}")
if (companies / "lanes-core" / "eval-library" / "lanes-core" / "ledger.json").exists():
    raise SystemExit("lanes under core wrote a ledger")
# A lanes parent that cannot be created is a clean error, and the ledger is rolled back.
blocker = tmp / "lanes-blocker"
blocker.write_text("x", encoding="utf-8")
blocked_lanes = blocker / "sub" / "lanes.json"
blocked_run = cli("lanes-blocked", 1, blocked_lanes)
if blocked_run.returncode != 1 or "Traceback" in blocked_run.stderr:
    raise SystemExit(f"unwritable lanes parent escaped: {blocked_run.returncode} {blocked_run.stderr}")
if "lanes path is not writable" not in blocked_run.stderr:
    raise SystemExit(f"unwritable lanes parent raised the wrong error: {blocked_run.stderr}")
if (companies / "lanes-blocked" / "eval-library" / "lanes-blocked" / "ledger.json").exists():
    raise SystemExit("unwritable lanes parent left a ledger")

# With surface.py from PR 1415 beside the ledger, a first plan for a new
# class still works: the class directory does not exist yet.
if not (Path(ledger_path).parent / "surface.py").is_file():
    raise SystemExit("surface.py is not beside ledger.py; the delegated scope path is untested")
fresh_book = open_book("fresh-class")
if (companies / "fresh-class" / "eval-library" / "fresh-class").exists():
    raise SystemExit("opening a ledger created the class directory")
fresh_book.plan(1)


# --lanes inside the companies tree is refused. A lanes file written as a
# sibling ledger.json would refuse every later plan for that company, and one
# in another company's folder crosses the tenant boundary.
bind_company("lanes-tree")
tree_targets = [
    companies / "lanes-tree" / "eval-library" / "other" / "ledger.json",
    companies / "lanes-tree" / "eval-library" / "other" / "lanes.json",
    companies / "lanes-neighbour" / "lanes.json",
]
for tree_lanes in tree_targets:
    tree_run = cli("lanes-tree", 1, tree_lanes)
    if tree_run.returncode != 1 or "Traceback" in tree_run.stderr or tree_lanes.exists():
        raise SystemExit(f"lanes inside companies was accepted: {tree_lanes} {tree_run.returncode} {tree_run.stderr}")
    if "lanes path" not in tree_run.stderr:
        raise SystemExit(f"lanes inside companies raised the wrong error: {tree_run.stderr}")
if (companies / "lanes-tree" / "eval-library" / "lanes-tree" / "ledger.json").exists():
    raise SystemExit("refused lanes path left a ledger")
tree_ok = cli("lanes-tree", 1, tmp / "lanes-tree-ok.json")
if tree_ok.returncode != 0:
    raise SystemExit(f"plan after refused lanes paths failed: {tree_ok.stderr}")
# A ledger file name is refused outside the tree too.
named_lanes = tmp / "named" / "ledger.created"
named_run = cli("lanes-named", 1, named_lanes)
if named_run.returncode != 1 or named_lanes.exists() or "ledger file name" not in named_run.stderr:
    raise SystemExit(f"ledger file name was accepted for lanes: {named_run.returncode} {named_run.stderr}")
# A case variant of core/ is refused. macOS volumes fold case by default.
for core_variant in (tmp / "CORE" / "x.json", tmp / "Core" / "policies" / "x.json"):
    variant_run = cli("lanes-case", 1, core_variant)
    if variant_run.returncode != 1 or core_variant.exists() or "lanes path is under core" not in variant_run.stderr:
        raise SystemExit(f"core case variant was accepted: {core_variant} {variant_run.stderr}")

# A finished class takes no more stages.
shut = open_book("shut")
shut_run = shut.plan(1)["run_id"]
shut.commit(stage(shut_run, "rollout:incumbent", "rollout", "lane-s1", check="pass"))
shut.finalize(1)
shut_before = (companies / "shut" / "eval-library" / "shut" / "ledger.json").read_bytes()
for late in (
    lambda: shut.commit(stage(shut_run, "rollout:probe", "rollout", "lane-s2")),
    lambda: shut.start([stage(shut_run, "rollout:probe", "rollout", "lane-s2")]),
):
    try:
        late()
    except ledger.LedgerError as exc:
        if "run is finished" not in str(exc):
            raise SystemExit(f"stage after finalize raised the wrong error: {exc}")
    else:
        raise SystemExit("a finished class took another stage")
if (companies / "shut" / "eval-library" / "shut" / "ledger.json").read_bytes() != shut_before:
    raise SystemExit("refused stage changed a finished ledger")

# A huge int is refused as a LedgerError, not an escaped OverflowError.
bind_company("huge")
for huge in (
    stage("0123456789abcdef", "rollout:x", "rollout", "lane-h", usd=10**400),
    dict(stage("0123456789abcdef", "rollout:x", "rollout", "lane-h", check="pass"), value=10**400),
):
    try:
        ledger.normalize_stage(huge)
    except ledger.LedgerError:
        pass
    else:
        raise SystemExit("huge int was accepted")

# A failed directory fsync after the lanes file is linked keeps both the
# lanes file and the ledger run, so the lanes argv never names a lost run.
fsync_lanes_dir = tmp / "fsync-lanes"
fsync_lanes_dir.mkdir()
fsync_lanes = fsync_lanes_dir / "lanes.json"
saved_fsync = ledger._fsync_dir
def failing_fsync(path):
    if Path(path) == fsync_lanes_dir:
        raise OSError(5, "Input/output error")
    return saved_fsync(path)
ledger._fsync_dir = failing_fsync
try:
    fsync_plan = open_book("fsync-lanes").plan(1, lanes_path=fsync_lanes)
finally:
    ledger._fsync_dir = saved_fsync
fsync_body = json.loads((companies / "fsync-lanes" / "eval-library" / "fsync-lanes" / "ledger.json").read_text())
if not fsync_lanes.exists() or [run["run_id"] for run in fsync_body["runs"]] != [fsync_plan["run_id"]]:
    raise SystemExit(f"fsync failure split the lanes file from the ledger: {fsync_body}")


# A symlink followed by .. is checked where the OS resolves it. Text
# normalization would fold link/.. away and miss the companies tree.
bind_company("lanes-dotdot")
dotdot_dir = companies / "lanes-dotdot-target" / "sub"
dotdot_dir.mkdir(parents=True)
dotdot_link = tmp / "dotdot-link"
dotdot_link.symlink_to(dotdot_dir)
dotdot_lanes = Path(str(dotdot_link) + "/../lanes.json")
dotdot_run = cli("lanes-dotdot", 1, dotdot_lanes)
landed = companies / "lanes-dotdot-target" / "lanes.json"
if dotdot_run.returncode != 1 or landed.exists() or "lanes path is under companies" not in dotdot_run.stderr:
    raise SystemExit(f"symlink dotdot lanes path was accepted: {dotdot_run.returncode} {dotdot_run.stderr}")

print("ok")
PY
