#!/usr/bin/env python3
# hq-core: public
"""Persisted run ledger for one eval class.

Default k is 1: two task rollouts (incumbent and one probe) and two improver
sessions (propose and compose). The hard cap is k=2. At k=2 the plan stays
within 6 task rollouts and 6 improver sessions and includes one retry session.
k greater than 2 is refused before any lane argv is built and before the
ledger file is created.

Depth is the parent chain, read from the company ledger files under an
exclusive lock, not from the object's attributes and not from a per-class
counter. The first plan for a company may omit a parent. Its depth is k.
Every later plan is a child: it must name a parent run id that already
exists in this company's ledgers, and its depth is that parent's depth plus
k. A new class id does not start a new budget. Leaving the parent off while
any run is active is refused. A chain whose depth would pass 2 is refused.

The budget is the whole tree, counted from the ledger under the company
lock. The root, every descendant, and every sibling share it. The sum of k
across that tree is at most 2, and the reserved rollouts and sessions stay
within 6 and 6. A class is not refused merely because some run has depth 2
while budget remains. Once that budget is spent, a later plan stays refused
for as long as the ledger files remain. A finished run stays refused too:
``finalize`` records that state, a child of a finished run is refused, and
a finished class takes no more stages. A ``--lanes`` file may not sit under
``core/`` or ``companies/`` or use a ledger file name.
This module has no reset command. An operator resets the company by
deleting every class ledger under ``companies/{company}/eval-library/``
(``ledger.json``, ``ledger.created``, and ``ledger.lock``) and
``eval-library/company.lock``. Deleting ``ledger.json`` alone leaves
``ledger.created`` in place; the next call fails with ``ledger missing``
and does not recreate the file. Deleting both the ledger and the marker is
what clears the budget, and only an operator outside this module should do
that.

The file lives at ``companies/{company}/eval-library/{classId}/ledger.json``.
Company scope matches ``surface.py`` from PR 1415. When ``surface.py``
sits beside this file, its ``company_scope`` check runs after the checks
here, and once the class directory exists its ``library_root`` walk runs
too. A class directory that does not exist yet is not an error: the first
plan for a class creates it. Without ``surface.py`` the same fail-closed
slug checks still run here. The company must be in the HQ session lock from
``core/scripts/hq-session.sh`` and in ``companies/manifest.yaml``. A CLI
session flag that merely matches ``--company`` is not the lock. The
companies root must be exactly the HQ root's ``companies`` directory. That root is ``HQ_ROOT`` when
set, otherwise ``CLAUDE_PROJECT_DIR``, otherwise the checkout that contains
this module. It is not the parent of ``--companies-root``. Any other
companies root, including one nested inside the HQ root, is refused. Unknown companies are refused and their
directory is not created. The company path is joined only after those
checks pass.

Local files are trusted. A writer who can replace ``ledger.json`` with a
schema-valid document and can rewrite or remove ``ledger.created`` can
reset the budget. A checksum stored next to the file would be rewritten by
that same writer, so a consistent rewrite is not detectable here. This
module refuses truncated JSON, a schema or cross-field mismatch, a symlink,
and a missing ledger that still has its created marker. It does not sign
the file. State that must survive a writer with access to these files has
to live outside that writer's reach.

Writes go to a temp file in the same directory and then replace the target.
A missing ledger that already has a created marker, an unreadable file, or a
file that does not match the schema is refused and left in place.

Labels are ``{company}:{run_id}:{stage}``. The run id is minted here. A
label for another company or another run is rejected.

This ledger does not require R=4k rollouts or P=3k sessions. A second stage
with the same label raises before any count check. Once ``start`` has been
recorded, later commits and starts are refused even if the object is cleared.
A check that ran and failed is ``excluded``, not 0. A check that did not run
is ``unscored`` and cannot be adopted. A passing check carries a score in
(0, 1]; it is 1 when the caller gives none. ``mean`` averages those scores
over passing checks only and reports the excluded and unscored counts beside
it, so one pass and three failures read as a mean over one stage with three
excluded. A start batch must hold at least one stage. ``usd`` is a finite
number at or above 0, or ``unpriced``. Lane argv never carries a provider
flag; new lanes keep the Grok default.

This module does not call ``hq lanes``, a model, or the control plane.
"""

from __future__ import annotations

import contextlib
import errno
import fcntl
import importlib.util
import json
import math
import os
import secrets
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable, Iterator, Mapping, Sequence

DEFAULT_K = 1
MAX_K = 2
MAX_ROLLOUTS = 6
MAX_SESSIONS = 6
SCHEMA = 1

KIND_ROLLOUT = "rollout"
KIND_SESSION = "session"
CHECK_PASS = "pass"
CHECK_EXCLUDED = "excluded"
CHECK_UNSCORED = "unscored"
UNPRICED = "unpriced"

# Flags that would override the Grok default on ``hq lanes create``.
PROVIDER_OVERRIDE_FLAGS = ("--provider", "--model-provider")

_STATE_KEYS = {
    "schema",
    "company",
    "class_id",
    "depth",
    "started",
    "rollout_count",
    "session_count",
    "entries",
    "runs",
    "finalized",
}
_RUN_KEYS = {"run_id", "k", "depth", "parent_run_id", "labels"}
_ENTRY_KEYS = {"label", "kind", "lane_id", "provider", "account", "usd", "check", "value"}
_MARKER_TEXT = "schema=1\n"


class LedgerError(Exception):
    """The plan or a stage was refused. Callers must not start a lane."""


def _require_k(k: object) -> int:
    """Accept only the integers 1 and 2.

    The cap is the literal pair ``(1, 2)``. Assigning ``MAX_K`` does not
    admit another value, and bools and int subclasses are not integers here.
    """
    if isinstance(k, bool) or type(k) is not int or k < 1:
        raise LedgerError("invalid k")
    if k not in (1, 2):
        raise LedgerError("k exceeds hard cap")
    return k


def _build_plan(k: int) -> dict[str, object]:
    """Return the stage list for ``k``. Counts are not 4k or 3k.

    Labels here are stage suffixes. ``plan`` stamps the company and run id
    before anything is returned to a caller.
    """
    k = _require_k(k)
    if k == 1:
        rollouts = (
            {"label": "rollout:incumbent", "kind": KIND_ROLLOUT},
            {"label": "rollout:probe", "kind": KIND_ROLLOUT},
        )
        sessions = (
            {"label": "session:propose", "kind": KIND_SESSION},
            {"label": "session:compose", "kind": KIND_SESSION},
        )
    elif k == 2:
        # Two probes, plus one retry session. Under the 6 and 6 ceiling.
        rollouts = (
            {"label": "rollout:incumbent", "kind": KIND_ROLLOUT},
            {"label": "rollout:probe-1", "kind": KIND_ROLLOUT},
            {"label": "rollout:probe-2", "kind": KIND_ROLLOUT},
        )
        sessions = (
            {"label": "session:propose-1", "kind": KIND_SESSION},
            {"label": "session:compose-1", "kind": KIND_SESSION},
            {"label": "session:propose-2", "kind": KIND_SESSION},
            {"label": "session:compose-2", "kind": KIND_SESSION},
            {"label": "session:retry", "kind": KIND_SESSION},
        )
    else:
        raise LedgerError("k exceeds hard cap")
    if len(rollouts) > 6 or len(sessions) > 6:
        raise LedgerError("plan exceeds cap")
    labels = [stage["label"] for stage in rollouts + sessions]
    if len(labels) != len(set(labels)):
        raise LedgerError("duplicate label")
    return {
        "k": k,
        "rollouts": [dict(stage) for stage in rollouts],
        "sessions": [dict(stage) for stage in sessions],
    }


def _ascii_alnum(char: str) -> bool:
    return ("a" <= char <= "z") or ("0" <= char <= "9")


def _slug(value: object, label: str) -> str:
    """ASCII slug. ``str.isalnum`` is not used: it accepts non-ASCII letters."""
    if not isinstance(value, str) or value == "" or not value.isascii():
        raise LedgerError(f"invalid {label}")
    if "/" in value or "\\" in value or value in (".", ".."):
        raise LedgerError(f"invalid {label}")
    if len(value) > 64:
        raise LedgerError(f"invalid {label}")
    if not _ascii_alnum(value[0]) or not _ascii_alnum(value[-1]):
        raise LedgerError(f"invalid {label}")
    for char in value:
        if not (_ascii_alnum(char) or char == "-"):
            raise LedgerError(f"invalid {label}")
    return value


def _manifest_companies(companies_root: Path) -> set[str]:
    """Top-level keys of ``companies/manifest.yaml``. Missing means unknown."""
    path = companies_root / "manifest.yaml"
    if path.is_symlink() or not path.is_file():
        raise LedgerError("unknown company")
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise LedgerError("unknown company") from exc
    companies: set[str] = set()
    in_companies = False
    for line in text.splitlines():
        if line == "companies:":
            in_companies = True
            continue
        if not in_companies:
            continue
        if line and not line.startswith(" "):
            break
        if len(line) > 2 and line.startswith("  ") and not line.startswith("   ") and line.endswith(":"):
            key = line[2:-1].strip()
            if key:
                companies.add(key)
    return companies


def _resolve_hq_root() -> Path:
    """HQ root the way ``hq-session.sh`` resolves it.

    ``HQ_ROOT``, else ``CLAUDE_PROJECT_DIR``, else this module's checkout.
    Not the parent of a caller-chosen ``--companies-root``.
    """
    chosen = os.environ.get("HQ_ROOT", "").strip()
    if not chosen:
        chosen = os.environ.get("CLAUDE_PROJECT_DIR", "").strip()
    if chosen:
        return Path(chosen).resolve()
    # core/scripts/eval-loop/ledger.py → checkout root is parents[3].
    return Path(__file__).resolve().parents[3]


def _hq_root_for(companies_root: Path) -> Path:
    """Return the HQ root, or refuse any companies root but ``hq_root/companies``.

    A second companies tree nested inside the HQ root (for example under
    ``workspace/``) would carry its own manifest and get a fresh budget, so
    only the HQ root's own ``companies`` directory is accepted.
    """
    hq_root = _resolve_hq_root()
    if companies_root.resolve() != (hq_root / "companies").resolve():
        raise LedgerError("companies root is not the HQ root companies directory")
    return hq_root


def _session_lock(companies_root: Path) -> set[str]:
    """Companies in the HQ session lock. The CLI flag is not this set.

    ``hq-session.sh get company_slugs`` reads the session lock for the HQ
    root from ``_resolve_hq_root``. A matching ``--session-company`` flag
    does not bind a company the lock does not name, and ``--companies-root``
    does not choose that root.
    """
    script = Path(__file__).resolve().parent.parent / "hq-session.sh"
    if not script.is_file():
        raise LedgerError("session has no company lock")
    hq_root = _hq_root_for(companies_root)
    env = os.environ.copy()
    env["HQ_ROOT"] = str(hq_root)
    env["HQ_HQ_SESSION_NO_CLI"] = "1"
    try:
        proc = subprocess.run(
            [str(script), "get", "company_slugs"],
            capture_output=True,
            text=True,
            env=env,
            cwd=str(hq_root),
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise LedgerError("session has no company lock") from exc
    if proc.returncode != 0:
        raise LedgerError("session has no company lock")
    slugs = {part.strip() for part in proc.stdout.strip().split(",") if part.strip()}
    if not slugs:
        raise LedgerError("session has no company lock")
    return slugs


def _surface_library_root(
    companies_root: os.PathLike[str] | str,
    company: str,
    class_id: str,
    session_company: str,
    class_dir: Path,
) -> Path | None:
    """Run PR 1415's checks when ``surface.py`` is beside this module.

    ``company_scope`` always runs. ``surface.library_root`` opens the class
    directory without creating it, so it runs only once ``class_dir`` exists
    (or is a symlink, which it refuses). A first plan for a new class would
    otherwise fail with ``missing path`` before the ledger could create it.
    """
    surface_path = Path(__file__).with_name("surface.py")
    if not surface_path.is_file():
        return None
    spec = importlib.util.spec_from_file_location("hq_eval_loop_surface", surface_path)
    if spec is None or spec.loader is None:
        raise LedgerError("surface module unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    scope = getattr(module, "company_scope", None)
    walk = getattr(module, "library_root", None)
    if scope is None or walk is None:
        raise LedgerError("surface module unavailable")
    try:
        scope(companies_root, company, session_company)
        if class_dir.exists() or class_dir.is_symlink():
            return Path(walk(companies_root, company, class_id, session_company))
        return class_dir
    except Exception as exc:
        if type(exc).__name__ == "SurfaceError":
            raise LedgerError(str(exc)) from exc
        raise


def library_root(
    companies_root: os.PathLike[str] | str,
    company: str,
    class_id: str,
    session_company: str,
) -> Path:
    """Return ``companies/{company}/eval-library/{classId}`` after the bind check.

    A slug that does not match ``session_company`` raises before the company
    segment is joined onto ``companies_root``. The session lock and the
    manifest are checked before a class directory is created.
    """
    session = _slug(session_company, "session company")
    bound = _slug(company, "company")
    if bound != session:
        raise LedgerError("company slug does not match session bind")
    class_slug = _slug(class_id, "class id")
    root = Path(companies_root)
    company_dir = root / bound
    # A symlink is refused before manifest and lock IO, and before any join
    # that would follow it. The directory is not created here.
    if company_dir.is_symlink():
        raise LedgerError("symlink")
    try:
        locked = _session_lock(root)
    except LedgerError:
        raise
    if bound not in locked:
        raise LedgerError("company slug does not match session bind")
    try:
        known = _manifest_companies(root)
    except LedgerError:
        raise
    if bound not in known or not company_dir.is_dir():
        raise LedgerError("unknown company")
    class_dir = company_dir / "eval-library" / class_slug
    library = company_dir / "eval-library"
    if library.is_symlink():
        raise LedgerError("symlink")
    delegated = _surface_library_root(companies_root, company, class_id, session_company, class_dir)
    if delegated is not None:
        return delegated
    return class_dir


def format_label(company: str, run_id: str, stage: str) -> str:
    """Bind a stage suffix to one company and one minted run id."""
    if not isinstance(company, str) or company == "":
        raise LedgerError("invalid label")
    if not isinstance(run_id, str) or _run_id_ok(run_id) is False:
        raise LedgerError("invalid label")
    if not isinstance(stage, str) or stage == "" or ":" not in stage:
        raise LedgerError("invalid label")
    if stage.startswith("/") or ".." in stage.split(":"):
        raise LedgerError("invalid label")
    return f"{company}:{run_id}:{stage}"


def _run_id_ok(run_id: object) -> bool:
    if not isinstance(run_id, str) or len(run_id) != 16:
        return False
    for char in run_id:
        if char not in "0123456789abcdef":
            return False
    return True


def _split_label(label: object, company: str, run_ids: set[str]) -> str:
    if not isinstance(label, str):
        raise LedgerError("label is not bound to this run")
    bound_company, sep, rest = label.partition(":")
    if sep != ":" or bound_company != company or rest == "":
        raise LedgerError("label is not bound to this run")
    run_id, sep2, stage = rest.partition(":")
    if sep2 != ":" or stage == "" or run_id not in run_ids or not _run_id_ok(run_id):
        raise LedgerError("label is not bound to this run")
    return run_id


def _stamp(company: str, run_id: str, stages: Sequence[Mapping[str, object]]) -> list[dict[str, object]]:
    stamped: list[dict[str, object]] = []
    for stage in stages:
        item = dict(stage)
        item["label"] = format_label(company, run_id, str(stage["label"]))
        stamped.append(item)
    return stamped


def lane_create_argv(label: str, *, provider: str | None = None) -> list[str]:
    """Argv for a later ``hq lanes create``. No provider flag is included.

    Passing ``provider`` raises. The lanes CLI keeps its Grok default.
    """
    if provider is not None:
        raise LedgerError("provider override")
    if not isinstance(label, str) or label == "":
        raise LedgerError("invalid label")
    argv = ["hq", "lanes", "create", "--label", label]
    for flag in PROVIDER_OVERRIDE_FLAGS:
        if flag in argv:
            raise LedgerError("provider override")
    return argv


def classify_check(ran: bool, passed: bool | None = None) -> str:
    """Map a check to pass, excluded, or unscored. Never returns 0."""
    if not isinstance(ran, bool):
        raise LedgerError("ran must be bool")
    if not ran:
        if passed is not None:
            raise LedgerError("unrun check has no pass bit")
        return CHECK_UNSCORED
    if passed is True:
        return CHECK_PASS
    if passed is False:
        return CHECK_EXCLUDED
    raise LedgerError("a check that ran needs a pass bit")


def can_adopt(check: str) -> bool:
    """Only a passing check can be adopted. Unscored and excluded cannot."""
    if check == CHECK_PASS:
        return True
    if check in (CHECK_EXCLUDED, CHECK_UNSCORED):
        return False
    raise LedgerError("invalid check")


def _usd_ok(usd: object) -> bool:
    """``unpriced``, or a finite real number at or above 0. Bools are not numbers."""
    if usd == UNPRICED:
        return True
    if isinstance(usd, bool) or not isinstance(usd, (int, float)):
        return False
    try:
        return math.isfinite(usd) and usd >= 0
    except OverflowError:
        return False


def _score_ok(value: object) -> bool:
    """A passing score is a finite real number in (0, 1]. Bools are not numbers."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    try:
        return math.isfinite(value) and 0 < value <= 1
    except OverflowError:
        return False


def usd_from_lane(meta: Mapping[str, object]) -> object:
    """Use the lane's usd. Missing, null, or blank metadata is ``unpriced``."""
    if "usd" not in meta:
        return UNPRICED
    usd = meta["usd"]
    if usd is None or usd == "":
        return UNPRICED
    return usd


def normalize_stage(raw: Mapping[str, object]) -> dict[str, object]:
    """Copy one stage. A failed check stores ``excluded`` and no numeric value."""
    required = ("label", "kind", "lane_id", "provider", "account", "usd")
    missing = [name for name in required if name not in raw]
    if missing:
        raise LedgerError("missing " + ",".join(missing))
    label = raw["label"]
    kind = raw["kind"]
    if not isinstance(label, str) or label == "":
        raise LedgerError("invalid label")
    if kind not in (KIND_ROLLOUT, KIND_SESSION):
        raise LedgerError("invalid kind")
    for name in ("lane_id", "provider", "account"):
        value = raw[name]
        if not isinstance(value, str) or value == "":
            raise LedgerError(f"invalid {name}")
    usd = raw["usd"]
    if usd is None or usd == "":
        usd = UNPRICED
    if not _usd_ok(usd):
        raise LedgerError("usd must be a finite number at or above 0, or unpriced")
    if "value" in raw and raw["value"] == 0:
        raise LedgerError("failed check is excluded, not 0")
    check = raw.get("check", CHECK_UNSCORED)
    if check not in (CHECK_PASS, CHECK_EXCLUDED, CHECK_UNSCORED):
        raise LedgerError("invalid check")
    if check == CHECK_EXCLUDED and "value" in raw:
        raise LedgerError("excluded check has no numeric value")
    if check == CHECK_UNSCORED and "value" in raw:
        raise LedgerError("unscored check has no numeric value")
    score: object = 1
    if check == CHECK_PASS and "value" in raw:
        score = raw["value"]
        if not _score_ok(score):
            raise LedgerError("passing score must be a finite number in (0, 1]")
    stage: dict[str, object] = {
        "label": label,
        "kind": kind,
        "lane_id": raw["lane_id"],
        "provider": raw["provider"],
        "account": raw["account"],
        "usd": usd,
        "check": check,
    }
    if check == CHECK_PASS:
        stage["value"] = score
    return stage


def _empty_state(company: str, class_id: str) -> dict[str, object]:
    return {
        "schema": SCHEMA,
        "company": company,
        "class_id": class_id,
        "depth": 0,
        "started": False,
        "rollout_count": 0,
        "session_count": 0,
        "entries": [],
        "runs": [],
        "finalized": False,
    }


def _recompute(state: dict[str, object]) -> tuple[int, int]:
    entries = state["entries"]
    if not isinstance(entries, list):
        raise LedgerError("invalid ledger")
    rollouts = sum(1 for entry in entries if isinstance(entry, dict) and entry.get("kind") == KIND_ROLLOUT)
    sessions = sum(1 for entry in entries if isinstance(entry, dict) and entry.get("kind") == KIND_SESSION)
    state["rollout_count"] = rollouts
    state["session_count"] = sessions
    return rollouts, sessions


def _validate_state(state: object, company: str, class_id: str) -> dict[str, object]:
    """Refuse a missing shape, a tampered counter, or a label for another run."""
    if not isinstance(state, dict) or set(state) != _STATE_KEYS:
        raise LedgerError("invalid ledger")
    if type(state["schema"]) is not int or state["schema"] != SCHEMA:
        raise LedgerError("invalid ledger")
    if state["company"] != company or state["class_id"] != class_id:
        raise LedgerError("invalid ledger")
    if type(state["depth"]) is not int or isinstance(state["started"], bool) is False:
        raise LedgerError("invalid ledger")
    if isinstance(state["finalized"], bool) is False:
        raise LedgerError("invalid ledger")
    if state["depth"] < 0 or state["depth"] > 2:
        raise LedgerError("invalid ledger")
    if type(state["rollout_count"]) is not int or type(state["session_count"]) is not int:
        raise LedgerError("invalid ledger")
    entries = state["entries"]
    runs = state["runs"]
    if not isinstance(entries, list) or not isinstance(runs, list):
        raise LedgerError("invalid ledger")

    run_ids: list[str] = []
    reserved: list[str] = []
    prior_depth: dict[str, int] = {}
    deepest = 0
    roots = 0
    for run in runs:
        if not isinstance(run, dict) or set(run) != _RUN_KEYS:
            raise LedgerError("invalid ledger")
        run_id = run["run_id"]
        if not _run_id_ok(run_id) or run_id in run_ids:
            raise LedgerError("invalid ledger")
        if type(run["k"]) is not int or run["k"] not in (1, 2):
            raise LedgerError("invalid ledger")
        if type(run["depth"]) is not int:
            raise LedgerError("invalid ledger")
        parent = run["parent_run_id"]
        if parent is None:
            roots += 1
            if run["depth"] != run["k"]:
                raise LedgerError("invalid ledger")
        elif not _run_id_ok(parent):
            raise LedgerError("invalid ledger")
        elif parent in prior_depth:
            if run["depth"] != prior_depth[parent] + run["k"]:
                raise LedgerError("invalid ledger")
        elif run["depth"] <= run["k"] or run["depth"] > 2:
            # Parent lives in another class ledger. The company chain check
            # confirms that id. A depth that is not past this run's own k
            # would be a fresh budget.
            raise LedgerError("invalid ledger")
        if roots > 1 or run["depth"] > 2:
            raise LedgerError("invalid ledger")
        prior_depth[run_id] = run["depth"]
        deepest = max(deepest, run["depth"])
        labels = run["labels"]
        if not isinstance(labels, list) or not labels:
            raise LedgerError("invalid ledger")
        for label in labels:
            if not isinstance(label, str) or _split_label(label, company, {run_id}) != run_id:
                raise LedgerError("invalid ledger")
            reserved.append(label)
        run_ids.append(run_id)
    if state["depth"] != deepest:
        raise LedgerError("invalid ledger")
    if len(reserved) != len(set(reserved)):
        raise LedgerError("invalid ledger")

    known = set(run_ids)
    entry_labels: list[str] = []
    rollouts = 0
    sessions = 0
    for entry in entries:
        if not isinstance(entry, dict):
            raise LedgerError("invalid ledger")
        if not set(entry) <= _ENTRY_KEYS or not {"label", "kind", "lane_id", "provider", "account", "usd", "check"} <= set(entry):
            raise LedgerError("invalid ledger")
        label = entry["label"]
        _split_label(label, company, known)
        entry_labels.append(label)
        kind = entry["kind"]
        if kind == KIND_ROLLOUT:
            rollouts += 1
        elif kind == KIND_SESSION:
            sessions += 1
        else:
            raise LedgerError("invalid ledger")
        for name in ("lane_id", "provider", "account"):
            if not isinstance(entry[name], str) or entry[name] == "":
                raise LedgerError("invalid ledger")
        if not _usd_ok(entry["usd"]):
            raise LedgerError("invalid ledger")
        check = entry["check"]
        if check not in (CHECK_PASS, CHECK_EXCLUDED, CHECK_UNSCORED):
            raise LedgerError("invalid ledger")
        if check == CHECK_PASS:
            if not _score_ok(entry.get("value")):
                raise LedgerError("invalid ledger")
        elif "value" in entry:
            raise LedgerError("invalid ledger")
    if len(entry_labels) != len(set(entry_labels)):
        raise LedgerError("invalid ledger")
    if rollouts > 6 or sessions > 6:
        raise LedgerError("invalid ledger")
    if state["rollout_count"] != rollouts or state["session_count"] != sessions:
        raise LedgerError("invalid ledger")
    return state


def _fsync_dir(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _atomic_write(path: Path, payload: bytes) -> None:
    """Write ``payload`` to a temp file in the same directory, then replace."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".ledger-", suffix=".tmp")
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        _fsync_dir(path.parent)
    except Exception:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise


def _dump_state(state: Mapping[str, object]) -> bytes:
    try:
        text = json.dumps(state, indent=2, sort_keys=True, allow_nan=False)
    except ValueError as exc:
        raise LedgerError("invalid ledger") from exc
    return (text + "\n").encode("utf-8")


def _write_new_file(path: Path, text: str) -> None:
    """Create ``path`` only when it is absent. The bytes land via link, not truncate."""
    if path.exists() or path.is_symlink():
        raise LedgerError("lanes path exists")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".lanes-", suffix=".tmp")
    except OSError as exc:
        raise LedgerError("lanes path is not writable") from exc
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(tmp, path)
        except FileExistsError as exc:
            raise LedgerError("lanes path exists") from exc
    finally:
        try:
            tmp.unlink()
        except OSError:
            pass
    try:
        _fsync_dir(path.parent)
    except OSError as exc:
        # The file is already linked in place and its bytes are fsynced.
        # Only the directory entry's durability is unconfirmed.
        sys.stderr.write(f"warning: lanes directory fsync failed: {exc.strerror or exc}\n")


_LEDGER_FILE_NAMES = frozenset({"ledger.json", "ledger.created", "ledger.lock", "company.lock"})


def _is_under(target: Path, guarded: Path) -> bool:
    """True when ``target`` or its nearest existing ancestor sits in ``guarded``.

    Compared by device and inode, not by path text, so a case-folding
    filesystem cannot reach ``guarded`` through ``CORE`` or ``Companies``.
    """
    # Text check first, case-folded, so a guarded directory that does not
    # exist yet is still refused. Over-refusing ``Core`` on a case-sensitive
    # filesystem is the safe side.
    target_text = os.path.realpath(target).casefold()
    guarded_text = os.path.realpath(guarded).casefold()
    if target_text == guarded_text or target_text.startswith(guarded_text.rstrip(os.sep) + os.sep):
        return True
    if not guarded.exists():
        return False
    probe = target
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    for candidate in (probe, *probe.parents):
        try:
            if os.path.samefile(candidate, guarded):
                return True
        except OSError:
            continue
    return False


def _refuse_core_path(path: Path, companies_root: os.PathLike[str] | str | None = None) -> None:
    """Refuse a lanes target the ledger or another tenant depends on.

    ``core/`` is release-owned. ``companies/`` holds every tenant's ledgers:
    a lanes file there can be read back as a sibling ledger and refuse every
    later plan for that company, or land in another company's tree. A
    ledger file name is refused anywhere.
    """
    target = Path(os.path.realpath(path))
    if target.name in _LEDGER_FILE_NAMES:
        raise LedgerError("lanes path uses a ledger file name")
    hq_root = _resolve_hq_root()
    if _is_under(target, hq_root / "core"):
        raise LedgerError("lanes path is under core")
    guarded = [hq_root / "companies"]
    if companies_root is not None:
        guarded.append(Path(companies_root))
    for root in guarded:
        if _is_under(target, root):
            raise LedgerError("lanes path is under companies")


def _open_lock(path: Path):
    """Open a lock file without following a symlink.

    ``O_NOFOLLOW`` refuses a planted symlink instead of creating its target
    outside the tenant directory. ``O_CREAT`` still creates a regular file
    when the path is absent.
    """
    if path.is_symlink():
        raise LedgerError("symlink")
    flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW
    try:
        fd = os.open(path, flags, 0o644)
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            raise LedgerError("symlink") from exc
        raise
    return os.fdopen(fd, "a+")


def _assert_chain(runs: Mapping[str, Mapping[str, object]]) -> None:
    """Depth is the parent chain across every class ledger for one company."""

    def depth_of(run_id: str, stack: set[str]) -> int:
        if run_id in stack:
            raise LedgerError("invalid ledger")
        run = runs[run_id]
        parent = run["parent_run_id"]
        own = run["k"]
        recorded = run["depth"]
        if not isinstance(own, int) or not isinstance(recorded, int):
            raise LedgerError("invalid ledger")
        if parent is None:
            if recorded != own:
                raise LedgerError("invalid ledger")
            return recorded
        if not isinstance(parent, str) or parent not in runs:
            raise LedgerError("invalid ledger")
        expected = depth_of(parent, stack | {run_id}) + own
        if recorded != expected or expected > 2:
            raise LedgerError("invalid ledger")
        return expected

    roots = [run_id for run_id, run in runs.items() if run.get("parent_run_id") is None]
    if len(roots) > 1:
        raise LedgerError("invalid ledger")
    for run_id in runs:
        depth_of(run_id, set())


def _root_of(runs: Mapping[str, Mapping[str, object]], run_id: str) -> str:
    """Walk parents to the root of ``run_id``. A cycle or a gap is invalid."""
    seen: set[str] = set()
    current = run_id
    while True:
        if current in seen or current not in runs:
            raise LedgerError("invalid ledger")
        seen.add(current)
        parent = runs[current].get("parent_run_id")
        if parent is None:
            return current
        if not isinstance(parent, str):
            raise LedgerError("invalid ledger")
        current = parent


def _stage_kind(label: object) -> str:
    """Kind of a stored ``company:run:stage`` label. Anything else is invalid."""
    if not isinstance(label, str):
        raise LedgerError("invalid ledger")
    _company, sep, rest = label.partition(":")
    _run, sep2, stage = rest.partition(":")
    if sep != ":" or sep2 != ":" or stage == "":
        raise LedgerError("invalid ledger")
    if stage.startswith("rollout:"):
        return KIND_ROLLOUT
    if stage.startswith("session:"):
        return KIND_SESSION
    raise LedgerError("invalid ledger")


def _assert_tree_budget(
    runs: Mapping[str, Mapping[str, object]],
    parent_run_id: str | None,
    extra_k: int,
    extra_rollouts: int,
    extra_sessions: int,
) -> None:
    """The root plus every descendant, including this plan, stays in budget.

    Siblings share that budget. The sum of k is at most 2. Reserved rollouts
    and sessions, from stored labels plus this plan, stay within 6 and 6.
    Those ceilings are literals, not ``MAX_K``, ``MAX_ROLLOUTS``, or
    ``MAX_SESSIONS``.
    """
    if parent_run_id is None:
        counted: list[str] = []
    else:
        root = _root_of(runs, parent_run_id)
        counted = [run_id for run_id in runs if _root_of(runs, run_id) == root]
    total_k = extra_k
    rollouts = extra_rollouts
    sessions = extra_sessions
    for run_id in counted:
        run = runs[run_id]
        own = run.get("k")
        if type(own) is not int:
            raise LedgerError("invalid ledger")
        total_k += own
        labels = run.get("labels")
        if not isinstance(labels, list):
            raise LedgerError("invalid ledger")
        for label in labels:
            if _stage_kind(label) == KIND_ROLLOUT:
                rollouts += 1
            else:
                sessions += 1
    if total_k > 2:
        raise LedgerError("k exceeds hard cap")
    if rollouts > 6:
        raise LedgerError("rollout cap")
    if sessions > 6:
        raise LedgerError("session cap")


def _reserved_kind(state: Mapping[str, object], label: str) -> str:
    """Kind implied by a label in this run's reserved list. Anything else is refused."""
    runs = state["runs"]
    if not isinstance(runs, list):
        raise LedgerError("invalid ledger")
    for run in runs:
        if not isinstance(run, dict):
            continue
        labels = run.get("labels")
        if not isinstance(labels, list) or label not in labels:
            continue
        _company, _sep, stage = label.partition(":")
        _run, _sep2, stage = stage.partition(":")
        if stage.startswith("rollout:"):
            return KIND_ROLLOUT
        if stage.startswith("session:"):
            return KIND_SESSION
        raise LedgerError("label is not reserved")
    raise LedgerError("label is not reserved")


class Ledger:
    """Company-scoped ledger. Attributes are a view; the file decides."""

    def __init__(
        self,
        companies_root: os.PathLike[str] | str,
        company: str,
        class_id: str,
        session_company: str,
    ) -> None:
        self.companies_root = companies_root
        self.company = company
        self.class_id = class_id
        self.session_company = session_company
        # library_root raises before joining a foreign company segment.
        self.root = library_root(companies_root, company, class_id, session_company)
        self.company = _slug(company, "company")
        self.class_id = _slug(class_id, "class id")
        self.path = self.root / "ledger.json"
        self.marker = self.root / "ledger.created"
        self.entries: list[dict[str, object]] = []
        self.count_checks = 0
        self.started = False
        self.lanes: list[list[str]] = []
        if self.root.exists() or self.path.exists() or self.marker.exists():
            with self._lock():
                self._sync(self._load_state())

    def _reject_symlinks(self) -> None:
        base = Path(self.companies_root)
        if base.is_symlink():
            raise LedgerError("symlink")
        current = base
        for part in (self.company, "eval-library", self.class_id):
            current = current / part
            if current.is_symlink():
                raise LedgerError("symlink")
        if self.path.is_symlink() or self.marker.is_symlink():
            raise LedgerError("symlink")

    @contextlib.contextmanager
    def _lock(self) -> Iterator[None]:
        self._reject_symlinks()
        company_dir = Path(self.companies_root) / self.company
        if company_dir.is_symlink() or not company_dir.is_dir():
            raise LedgerError("unknown company")
        library = company_dir / "eval-library"
        if library.is_symlink():
            raise LedgerError("symlink")
        library.mkdir(exist_ok=True)
        if self.root.is_symlink():
            raise LedgerError("symlink")
        self.root.mkdir(exist_ok=True)
        self._reject_symlinks()
        company_handle = _open_lock(library / "company.lock")
        try:
            fcntl.flock(company_handle.fileno(), fcntl.LOCK_EX)
            handle = _open_lock(self.root / "ledger.lock")
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
                try:
                    yield
                finally:
                    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            finally:
                handle.close()
        finally:
            fcntl.flock(company_handle.fileno(), fcntl.LOCK_UN)
            company_handle.close()

    def _company_view(
        self, overlay: Mapping[str, object]
    ) -> tuple[dict[str, Mapping[str, object]], dict[str, bool]]:
        """Runs for this company, and whether each run's class is finalized.

        ``overlay`` is the current class, possibly unsaved. ``finalized`` is
        read under the same company lock as the run records.
        """
        found: dict[str, Mapping[str, object]] = {}
        finished: dict[str, bool] = {}
        library = Path(self.companies_root) / self.company / "eval-library"
        if library.is_symlink():
            raise LedgerError("symlink")
        if not library.is_dir():
            return found, finished
        for child in library.iterdir():
            if child.name.startswith(".") or not child.is_dir():
                continue
            if child.is_symlink():
                raise LedgerError("symlink")
            if child.name == self.class_id:
                state: object = overlay
            else:
                path = child / "ledger.json"
                if not path.exists() and not path.is_symlink():
                    # A class that once held a ledger keeps its created
                    # marker. Skipping it would drop its runs from the tree
                    # and hand a new root a fresh budget.
                    marker = child / "ledger.created"
                    if marker.is_symlink():
                        raise LedgerError("symlink")
                    if marker.exists():
                        raise LedgerError("ledger missing")
                    continue
                if path.is_symlink():
                    raise LedgerError("symlink")
                try:
                    raw = path.read_bytes()
                    parsed = json.loads(raw.decode("utf-8"))
                except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
                    raise LedgerError("corrupt ledger") from exc
                state = _validate_state(parsed, self.company, child.name)
            if not isinstance(state, dict):
                raise LedgerError("invalid ledger")
            flag = state.get("finalized")
            if isinstance(flag, bool) is False:
                raise LedgerError("invalid ledger")
            runs = state.get("runs")
            if not isinstance(runs, list):
                raise LedgerError("invalid ledger")
            for run in runs:
                if not isinstance(run, dict) or not _run_id_ok(run.get("run_id")):
                    raise LedgerError("invalid ledger")
                run_id = str(run["run_id"])
                if run_id in found:
                    raise LedgerError("invalid ledger")
                found[run_id] = run
                finished[run_id] = flag
        return found, finished

    def _company_runs(self, overlay: Mapping[str, object]) -> dict[str, Mapping[str, object]]:
        """Every run for this company. ``overlay`` is the current class, possibly unsaved."""
        found, _finished = self._company_view(overlay)
        return found

    def _marker_present(self) -> bool:
        if not self.marker.exists():
            return False
        if self.marker.is_symlink():
            raise LedgerError("symlink")
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            fd = os.open(self.marker, flags)
        except OSError as exc:
            if exc.errno == errno.ELOOP:
                raise LedgerError("symlink") from exc
            raise LedgerError("ledger unreadable") from exc
        try:
            with os.fdopen(fd, "r", encoding="utf-8") as handle:
                text = handle.read()
        except OSError as exc:
            raise LedgerError("ledger unreadable") from exc
        if text != _MARKER_TEXT:
            raise LedgerError("invalid ledger")
        return True

    def _read_ledger_bytes(self) -> bytes:
        if self.path.is_symlink():
            raise LedgerError("symlink")
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            fd = os.open(self.path, flags)
        except OSError as exc:
            if exc.errno == errno.ELOOP:
                raise LedgerError("symlink") from exc
            raise LedgerError("ledger unreadable") from exc
        try:
            with os.fdopen(fd, "rb") as handle:
                return handle.read()
        except OSError as exc:
            raise LedgerError("ledger unreadable") from exc

    def _write_marker(self) -> None:
        _atomic_write(self.marker, _MARKER_TEXT.encode("utf-8"))

    def _load_state(self) -> dict[str, object]:
        """Read the file. Do not replace a missing, bad, or unreadable ledger."""
        self._reject_symlinks()
        marker = self._marker_present()
        if not self.path.exists():
            if marker:
                raise LedgerError("ledger missing")
            return _empty_state(self.company, self.class_id)
        raw = self._read_ledger_bytes()
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise LedgerError("corrupt ledger") from exc
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError as exc:
            raise LedgerError("corrupt ledger") from exc
        state = _validate_state(parsed, self.company, self.class_id)
        _assert_chain(self._company_runs(state))
        if not marker:
            self._write_marker()
        return state

    def _write_state(self, state: Mapping[str, object]) -> None:
        _atomic_write(self.path, _dump_state(state))
        if not self.marker.exists():
            self._write_marker()

    def _restore(self, previous: bytes | None, marker_existed: bool) -> None:
        if previous is None:
            if self.path.exists() and not self.path.is_symlink():
                self.path.unlink()
        else:
            _atomic_write(self.path, previous)
        if not marker_existed and self.marker.exists() and not self.marker.is_symlink():
            self.marker.unlink()

    def _sync(self, state: Mapping[str, object]) -> None:
        entries = state["entries"]
        self.entries = [dict(entry) for entry in entries] if isinstance(entries, list) else []
        self.started = bool(state["started"])

    def _reject_duplicate(self, label: str, batch: Sequence[str], state: Mapping[str, object]) -> None:
        entries = state["entries"]
        if label in batch or any(isinstance(entry, dict) and entry.get("label") == label for entry in entries):
            raise LedgerError("duplicate label")

    def _check_counts(self, state: Mapping[str, object], kinds: Sequence[str]) -> None:
        self.count_checks += 1
        rollouts = int(state["rollout_count"]) + sum(1 for kind in kinds if kind == KIND_ROLLOUT)
        sessions = int(state["session_count"]) + sum(1 for kind in kinds if kind == KIND_SESSION)
        # Literal ceilings. Patching MAX_ROLLOUTS / MAX_SESSIONS cannot raise them.
        if rollouts > 6:
            raise LedgerError("rollout cap")
        if sessions > 6:
            raise LedgerError("session cap")

    def plan(
        self,
        k: int = DEFAULT_K,
        parent_run_id: str | None = None,
        lanes_path: os.PathLike[str] | str | None = None,
    ) -> dict[str, object]:
        """Record one run. Depth is the parent chain plus this call's k.

        A chain whose depth would pass 2 is refused. The whole tree,
        including siblings, must stay within the k=2 budget: the sum of k
        is at most 2, and reserved rollouts and sessions stay within 6 and
        6. A class is not refused merely because some run has depth 2 while
        budget remains. A child of a finished run is refused. Passing a new
        class id, or leaving the parent off while any run is active, does
        not open a new budget.
        """
        k = _require_k(k)
        lanes = Path(lanes_path) if lanes_path is not None else None
        if lanes is not None and (lanes.exists() or lanes.is_symlink()):
            raise LedgerError("lanes path exists")
        if lanes is not None:
            # realpath walks components in order, so ``link/..`` resolves
            # where the OS will write. The guard and the write share it.
            lanes = Path(os.path.realpath(lanes))
            _refuse_core_path(lanes, self.companies_root)
        with self._lock():
            if lanes is not None and (lanes.exists() or lanes.is_symlink()):
                raise LedgerError("lanes path exists")
            state = self._load_state()
            if state.get("finalized") is True:
                raise LedgerError("parent run is finished")
            company_runs, finished = self._company_view(state)
            if parent_run_id is None:
                if company_runs:
                    raise LedgerError("parent run is required")
                new_depth = k
            else:
                parent = company_runs.get(parent_run_id)
                if not _run_id_ok(parent_run_id) or parent is None:
                    raise LedgerError("unknown parent run")
                if finished.get(parent_run_id) is True:
                    raise LedgerError("parent run is finished")
                parent_depth = parent.get("depth")
                if type(parent_depth) is not int:
                    raise LedgerError("invalid ledger")
                new_depth = parent_depth + k
            # Literal 2. A patched MAX_K must not let another k=2 through.
            # Depth comes from the chain, so a new class cannot start again at k.
            if new_depth > 2:
                raise LedgerError("k exceeds hard cap")
            run_id = secrets.token_hex(8)
            shaped = _build_plan(k)
            rollouts = _stamp(self.company, run_id, shaped["rollouts"])  # type: ignore[arg-type]
            sessions = _stamp(self.company, run_id, shaped["sessions"])  # type: ignore[arg-type]
            labels = [str(stage["label"]) for stage in rollouts + sessions]
            if len(labels) != len(set(labels)):
                raise LedgerError("duplicate label")
            # Counted under the company lock, before this run is written.
            # Siblings are already in company_runs and share the same tree.
            _assert_tree_budget(company_runs, parent_run_id, k, len(rollouts), len(sessions))
            runs = state["runs"]
            if not isinstance(runs, list):
                raise LedgerError("invalid ledger")
            runs.append(
                {
                    "run_id": run_id,
                    "k": k,
                    "depth": new_depth,
                    "parent_run_id": parent_run_id,
                    "labels": labels,
                }
            )
            state["depth"] = max(int(state["depth"]), new_depth)
            _validate_state(state, self.company, self.class_id)
            _assert_chain(self._company_runs(state))
            previous = self._read_ledger_bytes() if self.path.exists() else None
            marker_existed = self.marker.exists()
            try:
                self._write_state(state)
                if lanes is not None:
                    argv_list = [lane_create_argv(label) for label in labels]
                    _write_new_file(lanes, json.dumps(argv_list) + "\n")
            except Exception:
                self._restore(previous, marker_existed)
                raise
            self._sync(state)
        return {
            "k": k,
            "company": self.company,
            "class_id": self.class_id,
            "run_id": run_id,
            "depth": new_depth,
            "parent_run_id": parent_run_id,
            "rollouts": rollouts,
            "sessions": sessions,
        }

    def commit(self, raw: Mapping[str, object]) -> dict[str, object]:
        """Store one stage. Counts and duplicates come from the file."""
        label = raw.get("label")
        if not isinstance(label, str):
            raise LedgerError("invalid label")
        with self._lock():
            state = self._load_state()
            self._sync(state)
            if state["finalized"] is True:
                raise LedgerError("run is finished")
            if state["started"]:
                raise LedgerError("already started")
            self._reject_duplicate(label, (), state)
            _split_label(label, self.company, {str(run["run_id"]) for run in state["runs"] if isinstance(run, dict)})
            kind = raw.get("kind")
            if not isinstance(kind, str):
                raise LedgerError("invalid kind")
            expected = _reserved_kind(state, label)
            if kind != expected:
                raise LedgerError("kind does not match the reserved stage")
            self._check_counts(state, (kind,))
            stage = normalize_stage(raw)
            entries = state["entries"]
            if not isinstance(entries, list):
                raise LedgerError("invalid ledger")
            entries.append(stage)
            _recompute(state)
            _validate_state(state, self.company, self.class_id)
            self._write_state(state)
            self._sync(state)
            return dict(stage)

    def start(self, stages: Sequence[Mapping[str, object]]) -> list[dict[str, object]]:
        """Start a run from a batch. A started file stays started.

        The batch is read once into a list, so a generator is checked and
        stored in full. An empty batch is refused before the lock is taken:
        it would set ``started`` with no entries and refuse every later
        commit for this class.
        """
        stages = list(stages)
        if not stages:
            raise LedgerError("empty batch")
        with self._lock():
            state = self._load_state()
            self._sync(state)
            if state["finalized"] is True:
                raise LedgerError("run is finished")
            if state["started"]:
                raise LedgerError("already started")
            seen: list[str] = []
            for raw in stages:
                label = raw.get("label")
                if not isinstance(label, str):
                    raise LedgerError("invalid label")
                self._reject_duplicate(label, seen, state)
                seen.append(label)
            run_ids = {str(run["run_id"]) for run in state["runs"] if isinstance(run, dict)}
            kinds: list[str] = []
            for raw in stages:
                label = raw.get("label")
                if not isinstance(label, str):
                    raise LedgerError("invalid label")
                _split_label(label, self.company, run_ids)
                kind = raw.get("kind")
                if not isinstance(kind, str):
                    raise LedgerError("invalid kind")
                expected = _reserved_kind(state, label)
                if kind != expected:
                    raise LedgerError("kind does not match the reserved stage")
                kinds.append(kind)
            self._check_counts(state, tuple(kinds))
            stored = [normalize_stage(raw) for raw in stages]
            entries = state["entries"]
            if not isinstance(entries, list):
                raise LedgerError("invalid ledger")
            entries.extend(stored)
            state["started"] = True
            _recompute(state)
            _validate_state(state, self.company, self.class_id)
            self._write_state(state)
            self._sync(state)
            return [dict(item) for item in stored]

    def mean(self) -> dict[str, object]:
        """Mean score over passing checks.

        Excluded and unscored checks are not in the denominator. Their counts
        are returned as ``excluded`` and ``unscored`` so a caller can see how
        many stages the mean left out.
        """
        with self._lock():
            state = self._load_state()
            self._sync(state)
            entries = state["entries"]
        denominator = 0
        excluded = 0
        unscored = 0
        total = 0.0
        for entry in entries:
            check = entry["check"]
            if check == CHECK_EXCLUDED:
                if "value" in entry or entry.get("value") == 0:
                    raise LedgerError("excluded stored as 0")
                excluded += 1
                continue
            if check == CHECK_UNSCORED:
                unscored += 1
                continue
            if check != CHECK_PASS:
                raise LedgerError("invalid check")
            value = entry.get("value")
            if value == 0:
                raise LedgerError("failed check is excluded, not 0")
            if not _score_ok(value):
                raise LedgerError("invalid ledger")
            total += float(value)  # type: ignore[arg-type]
            denominator += 1
        if denominator == 0:
            return {"mean": None, "denominator": 0, "excluded": excluded, "unscored": unscored}
        return {
            "mean": total / denominator,
            "denominator": denominator,
            "excluded": excluded,
            "unscored": unscored,
        }

    def finalize(self, k: int) -> dict[str, object]:
        """Close the class and persist ``finalized``.

        ``k`` must equal the largest run k in this class: a lower k is
        refused, and so is a higher one, which would record a budget the
        class never planned. Committed
        counts must stay within the sum of this class's plans and within 6
        and 6. Chain depth is not compared to ``k``: a k=1 child of a k=1
        root is depth 2 and still finalizes as k=1. A later child of this
        run is refused.
        """
        k = _require_k(k)
        with self._lock():
            if not self.path.exists():
                raise LedgerError("ledger missing")
            state = self._load_state()
            self._sync(state)
            runs = state["runs"]
            if not isinstance(runs, list):
                raise LedgerError("invalid ledger")
            plan_rollouts = 0
            plan_sessions = 0
            widest = 0
            for run in runs:
                if not isinstance(run, dict) or type(run.get("k")) is not int:
                    raise LedgerError("invalid ledger")
                if run["k"] > k:
                    raise LedgerError("counts exceed k")
                widest = max(widest, run["k"])
                shaped = _build_plan(run["k"])
                plan_rollouts += len(shaped["rollouts"])  # type: ignore[arg-type]
                plan_sessions += len(shaped["sessions"])  # type: ignore[arg-type]
            if widest != k:
                raise LedgerError("k does not match the planned run")
            rollouts = int(state["rollout_count"])
            sessions = int(state["session_count"])
            # Literal 6 and 6. Patching MAX_ROLLOUTS / MAX_SESSIONS cannot raise them.
            if rollouts > plan_rollouts or sessions > plan_sessions or rollouts > 6 or sessions > 6:
                raise LedgerError("counts exceed k")
            state["finalized"] = True
            _validate_state(state, self.company, self.class_id)
            self._write_state(state)
            self._sync(state)
            return {
                "k": k,
                "rollouts": rollouts,
                "sessions": sessions,
                "required_identity": None,
            }


def plan_run(
    k: int = DEFAULT_K,
    *,
    companies_root: os.PathLike[str] | str | None = None,
    company: str | None = None,
    class_id: str | None = None,
    session_company: str | None = None,
    parent_run_id: str | None = None,
    lanes_path: os.PathLike[str] | str | None = None,
) -> dict[str, object]:
    """Plan a run and persist it. k>2 raises before a company directory is created."""
    checked = _require_k(k)
    if companies_root is None or company is None or class_id is None or session_company is None:
        raise LedgerError("company is required")
    book = Ledger(companies_root, company, class_id, session_company)
    return book.plan(checked, parent_run_id=parent_run_id, lanes_path=lanes_path)


def prepare(
    k: int = DEFAULT_K,
    create_lane: Callable[[Sequence[str]], None] | None = None,
    *,
    companies_root: os.PathLike[str] | str | None = None,
    company: str | None = None,
    class_id: str | None = None,
    session_company: str | None = None,
    parent_run_id: str | None = None,
) -> tuple[dict[str, object], list[list[str]]]:
    """Plan, then build lane argv. ``create_lane`` is not called when k>2."""
    planned = plan_run(
        k,
        companies_root=companies_root,
        company=company,
        class_id=class_id,
        session_company=session_company,
        parent_run_id=parent_run_id,
    )
    stages = list(planned["rollouts"]) + list(planned["sessions"])
    argv_list: list[list[str]] = []
    for stage in stages:
        argv = lane_create_argv(str(stage["label"]))
        argv_list.append(argv)
        if create_lane is not None:
            create_lane(argv)
    return planned, argv_list


def _parse_plan_args(argv: Sequence[str]) -> dict[str, object]:
    if len(argv) < 2 or argv[1] != "plan":
        raise LedgerError(
            "usage: ledger.py plan --k N --company SLUG --class ID "
            "--companies-root PATH --session-company SLUG [--lanes PATH] [--parent-run ID]"
        )
    k: object = DEFAULT_K
    lanes_path: str | None = None
    company: str | None = None
    class_id: str | None = None
    companies_root: str | None = None
    session_company: str | None = None
    parent_run_id: str | None = None
    index = 2
    while index < len(argv):
        flag = argv[index]
        needs_value = flag in ("--k", "--lanes", "--company", "--class", "--companies-root", "--session-company", "--parent-run")
        if not needs_value:
            raise LedgerError(
                "usage: ledger.py plan --k N --company SLUG --class ID "
                "--companies-root PATH --session-company SLUG [--lanes PATH] [--parent-run ID]"
            )
        index += 1
        if index >= len(argv):
            raise LedgerError(f"missing {flag}")
        value = argv[index]
        if flag == "--k":
            try:
                k = int(value)
            except ValueError as exc:
                raise LedgerError("invalid k") from exc
        elif flag == "--lanes":
            lanes_path = value
        elif flag == "--company":
            company = value
        elif flag == "--class":
            class_id = value
        elif flag == "--companies-root":
            companies_root = value
        elif flag == "--session-company":
            session_company = value
        else:
            parent_run_id = value
        index += 1
    return {
        "k": k,
        "lanes_path": lanes_path,
        "company": company,
        "class_id": class_id,
        "companies_root": companies_root,
        "session_company": session_company,
        "parent_run_id": parent_run_id,
    }


def main(argv: Sequence[str]) -> int:
    try:
        opts = _parse_plan_args(argv)
        k = opts["k"]
        if isinstance(k, bool) or type(k) is not int:
            raise LedgerError("invalid k")
        planned = plan_run(
            k,
            companies_root=opts["companies_root"],  # type: ignore[arg-type]
            company=opts["company"],  # type: ignore[arg-type]
            class_id=opts["class_id"],  # type: ignore[arg-type]
            session_company=opts["session_company"],  # type: ignore[arg-type]
            parent_run_id=opts["parent_run_id"],  # type: ignore[arg-type]
            lanes_path=opts["lanes_path"],  # type: ignore[arg-type]
        )
    except LedgerError as exc:
        sys.stderr.write(f"error: {exc}\n")
        return 1
    except OSError as exc:
        sys.stderr.write(f"error: {exc.strerror or exc}\n")
        return 1
    json.dump(planned, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
