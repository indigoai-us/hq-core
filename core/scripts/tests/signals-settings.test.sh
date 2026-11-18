#!/usr/bin/env bash
# signals-settings.test.sh - core/settings/signals.yaml and
# core/settings/signals-adapters.yaml parse and agree with the hq-cli readers.
#
# Pinned checks (always run): every key, value and adapter entry matches the
# hq-cli code that reads these files, transcribed below from hq-cli main:
#   src/lib/signals/settings.ts           DEFAULT_SIGNALS_SETTINGS, VALID,
#                                         loadIncrementalSettings defaults
#   src/lib/bot/jobs/meeting-rider.ts     rider.interval_seconds default 20
#   src/lib/bot/jobs/meeting-detect.ts    rider.detect_interval_seconds default 60
#   src/lib/signals/adapters-catalog.ts   entry keys, ADAPTER_FLAGS
#   src/lib/hot-channels/adapters/index.ts registered adapter ids, in order
# The daily brief's reader (brief_gate.load_settings) must read the same values.
#
# /signals run skill text (.claude/skills/signals/SKILL.md): the failed-run
# reply says the brief still builds; the skill runs the engine check before it
# adds or moves a job and adds none when the engine is off; the prompt-driven
# job passes --catch-up only on a late-run notice and the job-created reply
# makes no catch-up promise; the engine-off reply does not claim the engine is
# off; the skill promises no retry. The
# engine check itself (brief_gate.py engine) answers off with no flag and no job
# record, and on with HQ_FLAG_CLI_BOT_SIGNALS_ENGINE_JOB=true.
#
# Live check (optional): with HQ_CLI_REPO set to an hq-cli git checkout, the
# pinned values are also compared with the source at HQ_CLI_REF (default
# origin/main), so a change on hq-cli main shows up here as a failure.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"

python3 - "$root" "${HQ_CLI_REPO:-}" "${HQ_CLI_REF:-origin/main}" <<'PY'
import importlib.util
import json
import math
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:
    raise SystemExit("FAIL: signals-settings test requires PyYAML (python3 -c 'import yaml')")

root = Path(sys.argv[1])
cli_repo = sys.argv[2]
cli_ref = sys.argv[3]
passed = 0
failed = 0


def check(name, got, want):
    global passed, failed
    if got == want:
        passed += 1
    else:
        failed += 1
        print(f"FAIL: {name}: want {want!r} got {got!r}")


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


# --- Pinned hq-cli expectations ------------------------------------------
SETTINGS_DEFAULTS = {"maxTurns": 40, "maxBudgetUsd": 2.0, "lateStartHour": 22, "briefWaitMinutes": 20}
VALID = {
    "maxTurns": lambda v: isinstance(v, int) and not isinstance(v, bool) and v >= 1,
    "maxBudgetUsd": lambda v: is_num(v) and v >= 0,
    "lateStartHour": lambda v: isinstance(v, int) and not isinstance(v, bool) and 1 <= v <= 24,
    "briefWaitMinutes": lambda v: is_num(v) and v >= 0,
}
INCREMENTAL_DEFAULTS = {"max_turns": 12, "max_budget_usd": 0.4}
RIDER_DEFAULTS = {"interval_seconds": 20, "detect_interval_seconds": 60}
ADAPTER_IDS = ["meetings", "slack", "linear", "attio", "gmail"]
ADAPTER_FLAGS = {"slack": "hq.hot-channel-slack", "linear": "hq.hot-channel-linear", "gmail": "hq.hot-channel-gmail"}
ENTRY_KEYS = {"id", "enabled", "schedule", "flag"}

# --- signals.yaml -------------------------------------------------------
sig_path = root / "core/settings/signals.yaml"
check("signals.yaml exists", sig_path.is_file(), True)
sig = yaml.safe_load(sig_path.read_text()) if sig_path.is_file() else None
check("signals.yaml is a mapping", isinstance(sig, dict), True)
sig = sig if isinstance(sig, dict) else {}
check("signals.yaml top-level keys", sorted(sig), sorted([*SETTINGS_DEFAULTS, "incremental", "rider"]))
for key, want in SETTINGS_DEFAULTS.items():
    v = sig.get(key)
    check(f"signals.yaml {key} is a number", is_num(v), True)
    check(f"signals.yaml {key} passes hq-cli VALID", bool(VALID[key](v)) if is_num(v) else False, True)
    check(f"signals.yaml {key} equals hq-cli default", v, want)
check("briefWaitMinutes inside brief_gate bounds 1-180", 1 <= sig.get("briefWaitMinutes", 0) <= 180, True)
inc = sig.get("incremental")
check("incremental is a mapping", isinstance(inc, dict), True)
inc = inc if isinstance(inc, dict) else {}
check("incremental keys", sorted(inc), sorted(INCREMENTAL_DEFAULTS))
check("incremental.max_turns passes VALID.maxTurns", VALID["maxTurns"](inc.get("max_turns")), True)
check("incremental.max_budget_usd passes VALID.maxBudgetUsd", is_num(inc.get("max_budget_usd")) and inc["max_budget_usd"] >= 0, True)
for key, want in INCREMENTAL_DEFAULTS.items():
    check(f"incremental.{key} equals hq-cli default", inc.get(key), want)
rider = sig.get("rider")
check("rider is a mapping", isinstance(rider, dict), True)
rider = rider if isinstance(rider, dict) else {}
check("rider keys", sorted(rider), sorted(RIDER_DEFAULTS))
for key, want in RIDER_DEFAULTS.items():
    check(f"rider.{key} is a number of at least 5", is_num(rider.get(key)) and rider[key] >= 5, True)
    check(f"rider.{key} equals hq-cli default", rider.get(key), want)

# The daily brief reads the same four numbers with its own line parser.
spec = importlib.util.spec_from_file_location("brief_gate", root / ".claude/skills/daily-brief/scripts/brief_gate.py")
bg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bg)
check("brief_gate DEFAULTS equal hq-cli defaults", bg.DEFAULTS, SETTINGS_DEFAULTS)
check("brief_gate.load_settings reads the shipped file", bg.load_settings(root), SETTINGS_DEFAULTS)

# --- signals-adapters.yaml ---------------------------------------------
ad_path = root / "core/settings/signals-adapters.yaml"
check("signals-adapters.yaml exists", ad_path.is_file(), True)
ad_text = ad_path.read_text() if ad_path.is_file() else ""
# hq-cli loads this file with js-yaml CORE_SCHEMA. PyYAML's safe_load agrees with it
# for the scalars this file uses (strings, integers, booleans).
ad = yaml.safe_load(ad_text)
check("signals-adapters.yaml is a mapping", isinstance(ad, dict), True)
ad = ad if isinstance(ad, dict) else {}
check("signals-adapters.yaml top-level keys", sorted(ad), ["adapters", "version"])
check("signals-adapters.yaml version", ad.get("version"), 1)
entries = ad.get("adapters")
check("adapters is a list", isinstance(entries, list), True)
entries = entries if isinstance(entries, list) else []
check("adapter ids match hq-cli registry order", [e.get("id") if isinstance(e, dict) else None for e in entries], ADAPTER_IDS)
for e in entries:
    if not isinstance(e, dict):
        check("adapter entry is a mapping", False, True)
        continue
    i = e.get("id")
    check(f"{i}: only keys hq-cli reads", sorted(set(e) - ENTRY_KEYS), [])
    check(f"{i}: enabled is boolean true", e.get("enabled") is True, True)
    if "schedule" in e:
        check(f"{i}: schedule is a string", isinstance(e["schedule"], str), True)
    check(f"{i}: flag matches hq-cli ADAPTER_FLAGS", e.get("flag"), ADAPTER_FLAGS.get(i))

# --- /signals run skill text --------------------------------------------
skill = (root / ".claude/skills/signals/SKILL.md").read_text()
run_start = skill.find("## `/signals run`")
check("skill has a /signals run section", run_start >= 0, True)
run = skill[run_start:skill.find("## See also", run_start)] if run_start >= 0 else ""
fail_at = run.find("Run failed (")
failed_part = run[fail_at:run.find("\"Try now\" (the", fail_at)] if fail_at >= 0 else ""
check("skill has a run-failed reply", fail_at >= 0 and "```hq-block" in failed_part, True)
check("run-failed reply never says the brief is not built", "not built" in failed_part, False)
check("run-failed reply says the brief still builds", "Your brief still builds, with a note that signals are out of date." in failed_part, True)
check("skill never says the brief is not built", "brief is not built" in skill, False)
check("run-failed reply promises no retry time", "I try again at" in failed_part.split("````", 1)[-1], False)
check("run-failed reply offers no wait option", '"id":"wait"' in failed_part, False)
check("run-failed reply says no retry on its own", "I do not retry this on my own." in failed_part, True)
job_at = run.find("### Creating the morning job")
job = run[job_at:run.find("### Run replies", job_at)] if job_at >= 0 else ""
engine_at = job.find("brief_gate.py engine")
first_step = job.find("1. Run the engine check.")
first_add = job.find("--add")
first_move = job.find("--reschedule")
check("job section runs the engine check", engine_at >= 0 and first_step >= 0, True)
check("engine check comes before any job add or move", 0 <= first_step < min(i for i in (first_add, first_move) if i >= 0), True)
step1 = job[first_step:job.find("\n2. ", first_step)] if first_step >= 0 else ""
check("engine off: create no job and change no job", "When it says `off`, create no job and change no job." in step1, True)
check("engine off: reply in plain words and stop", "did not set up a job" in step1 and "Stop here." in step1, True)
check("engine off branch never adds a job", "--add" in step1 or "--reschedule" in step1, False)
add_cmd = [line for line in job.splitlines() if line.strip().startswith("hq bot jobs <bot> --add")]
check("one prompt-driven job command", len(add_cmd), 1)
check("prompt-driven job passes --catch-up when late", bool(add_cmd) and "--catch-up" in add_cmd[0], True)
check("--catch-up is tied to the late-run notice", bool(add_cmd) and "scheduled-run message for this job says the run is late" in add_cmd[0], True)
check("catch-up marking limited to the classic CLI bot runtime", "On the classic CLI bot runtime" in job and "HQ Fleet Runtime jobs get no such notice" in job, True)
created = job[job.find("Job-created reply."):]
check("job-created reply makes no catch-up promise", "catch-up" in created.split("````")[1] if created.count("````") >= 2 else True, False)
check("engine off reply does not claim the engine is off", "not turned on" in step1, False)
check("engine off reply says it could not confirm the engine", "I could not confirm that the signals engine is on for this computer yet" in step1, True)
check("engine off reply says when to ask again", "Ask me again after the next morning signals run, or ask your HQ admin if it stays off." in step1, True)
check("prompt-driven job runs the job trigger", bool(add_cmd) and "hq signals run --trigger job --json" in add_cmd[0], True)

# The engine check the skill relies on: off by default, on with the env flag.
with tempfile.TemporaryDirectory() as tmp:
    (Path(tmp) / "workspace").mkdir()
    gate = root / ".claude/skills/daily-brief/scripts/brief_gate.py"

    def engine(extra_env):
        env = {k: v for k, v in os.environ.items() if k != "HQ_FLAG_CLI_BOT_SIGNALS_ENGINE_JOB"}
        env.update(extra_env)
        out = subprocess.run([sys.executable, "-I", str(gate), "engine", "--hq-root", tmp, "--today", "2026-01-05"],
                             capture_output=True, text=True, env=env)
        try:
            return json.loads(out.stdout).get("on")
        except ValueError:
            return f"exit {out.returncode}: {out.stdout!r}"

    check("engine check is off with no flag and no job record", engine({}), False)
    check("engine check is on with HQ_FLAG_CLI_BOT_SIGNALS_ENGINE_JOB=true", engine({"HQ_FLAG_CLI_BOT_SIGNALS_ENGINE_JOB": "true"}), True)
    check("engine check is off with HQ_FLAG_CLI_BOT_SIGNALS_ENGINE_JOB=false", engine({"HQ_FLAG_CLI_BOT_SIGNALS_ENGINE_JOB": "false"}), False)

# --- Live comparison with hq-cli source ---------------------------------
if cli_repo:
    def src(rel):
        out = subprocess.run(["git", "-C", cli_repo, "cat-file", "-p", f"{cli_ref}:{rel}"], capture_output=True, text=True)
        if out.returncode != 0:
            check(f"read {cli_ref}:{rel}", out.stderr.strip(), "")
            return ""
        return out.stdout

    def num(s):
        return float(s) if "." in s else int(s)

    settings_ts = src("src/lib/signals/settings.ts")
    m = re.search(r"DEFAULT_SIGNALS_SETTINGS: SignalsSettings = \{(.*?)\};", settings_ts, re.S)
    live = {k: num(v) for k, v in re.findall(r"(\w+):\s*([0-9.]+)", m.group(1))} if m else {}
    check("live: DEFAULT_SIGNALS_SETTINGS", live, SETTINGS_DEFAULTS)
    m = re.search(r"const out = \{ maxTurns: ([0-9.]+), maxBudgetUsd: ([0-9.]+) \}", settings_ts)
    check("live: incremental defaults", {"max_turns": num(m.group(1)), "max_budget_usd": num(m.group(2))} if m else None, INCREMENTAL_DEFAULTS)
    check("live: incremental keys read", sorted(set(re.findall(r"v\?\.(max_\w+)", settings_ts))), sorted(INCREMENTAL_DEFAULTS))
    rider_ts = src("src/lib/bot/jobs/meeting-rider.ts")
    m = re.search(r"let interval = ([0-9]+);", rider_ts)
    check("live: rider.interval_seconds default", num(m.group(1)) if m else None, RIDER_DEFAULTS["interval_seconds"])
    check("live: rider reads interval_seconds", "rider?.interval_seconds" in rider_ts, True)
    detect_ts = src("src/lib/bot/jobs/meeting-detect.ts")
    m = re.search(r"rider\?\.detect_interval_seconds;\s*return [^:]+: ([0-9]+);", detect_ts)
    check("live: rider.detect_interval_seconds default", num(m.group(1)) if m else None, RIDER_DEFAULTS["detect_interval_seconds"])
    catalog_ts = src("src/lib/signals/adapters-catalog.ts")
    m = re.search(r"ADAPTER_FLAGS: Readonly<Record<string, AdapterFlag>> = \{(.*?)\n\};", catalog_ts, re.S)
    live_flags = dict(re.findall(r'(\w+): \{ flag: "([^"]+)"', m.group(1))) if m else {}
    check("live: ADAPTER_FLAGS", live_flags, ADAPTER_FLAGS)
    m = re.search(r"export interface SignalsAdapterCatalogEntry \{(.*?)\}", catalog_ts, re.S)
    check("live: catalog entry keys", sorted(re.findall(r"(\w+)\??:", m.group(1))) if m else None, sorted(ENTRY_KEYS))
    check("live: catalog path", 'SIGNALS_ADAPTERS_CATALOG_PATH = "core/settings/signals-adapters.yaml"' in catalog_ts, True)
    index_ts = src("src/lib/hot-channels/adapters/index.ts")
    order = [n.lower() for n in re.findall(r"registry\.register\(\s*create(\w+)Adapter", index_ts)]
    check("live: registered adapter order", order, ADAPTER_IDS)
    for name in ADAPTER_IDS:
        ts = src(f"src/lib/hot-channels/adapters/{name}.ts")
        check(f"live: {name} adapter id", f'_ADAPTER_ID = "{name}"' in ts, True)
    print(f"live hq-cli source: {cli_ref}")

print(f"signals-settings: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
