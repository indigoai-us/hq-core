#!/usr/bin/env python3
# hq-core: public
"""Grade-withheld propose and compose packets.

Grades are withheld by construction. The builders read an allowlist of
fields and files, and none of those can hold a grade:

- A proposer run record may carry ``label``, ``run_id``, ``ok``,
  ``delivered``, ``error``, and ``cost`` (or ``cost_usd``). A record with any
  other key is refused, so a score field is never read into a view. The view
  is ``VIEW_FIELDS``. Cost is accepted on the record and never read.
  ``error`` is one of ``ERROR_CODES``, the process failure codes. ``ok`` is
  process success and must equal ``error == ""``, so it carries no bit of
  its own. ``delivered`` means a deliverable artifact exists. The view's
  ``label`` and ``run_id`` are minted here (``arm-N`` by first appearance,
  ``run-N`` by position), so harness-chosen names never reach the packet.
- A compose deliverable reads ``label``, ``task_id``, ``k``, ``mode``, and
  ``text``. Any other key, including a check exit status, is refused.
- The harness diff must be a unified diff whose every file header names a
  closed-surface path outside a grade area.

The CLI opens only allowlisted input paths. Each argument kind has one root
under the class library (``INPUT_KINDS`` and ``INPUT_ROOTS``): briefs in
``briefs/``, run records in ``runs/``, deliverable artifacts in
``deliverables/``, the harness diff in ``diffs/``, trees in ``trees/``, and
patches in ``patches/``. A path must be relative, sit under the root for its
kind, use lowercase slug segments, and end in a suffix that root allows.
Anything else is refused with code ``input_path`` before the file is opened.
Outputs go only to ``packets/``, which is not an input root. The ledger
(``ledger.json`` entries ``check`` and ``value``) sits at the library root,
outside every input root, so the builders have no read path to it. Inside
the roots, a segment that contains a grade stem (``GRADE_AREA_STEMS``) is
still refused as defense in depth. Tree and diff paths must be surface paths,
and a segment token that names a grade area (``GRADE_AREA_WORDS``) is refused.

The keyword scan is defense in depth. Text is NFKC-normalized, zero-width
and other format characters are dropped, Cyrillic and Greek lookalikes are
folded to Latin, and camelCase is split before matching. It also decodes
base64 and hex runs and scans the result. Each field is scanned on its own
and joined with the others. A refusal message names the kind of hit, never
the matched text.

The composer packet carries the harness diff and anonymized deliverable
text. The deliverable count is bound to k through the ledger: a compose may
carry at most one deliverable per task rollout the ledger plans for that k.
Compose takes the run id that ``ledger.plan_run`` returned and records that
run's next compose session (``session:compose`` at k=1,
``session:compose-1`` then ``session:compose-2`` at k=2). It never plans a
run. Every input and output-path check runs before the ledger is written,
and the packet file is removed if the ledger refuses the stage.
Anonymization is structural. Each deliverable gets ``candidate-N`` in
the order of a SHA-256 hash of its text, not its input position, and the
packet lists candidates in that order. Every candidate's label and ``task_id|k|mode`` token is replaced
in every text, only where it stands as a whole token.

Each item and the finished packet have a byte cap. Past either cap the
module raises PacketError and writes nothing.

CLI paths are relative to one company eval-library root. Every read and
write goes through ``surface._open_library``, which runs
``surface.company_scope``: the slug must equal the session company, the
companies root must be the HQ root's ``companies`` directory, and the company
must be in the session lock from ``hq-session.sh``. The company must also be
in the manifest, and the walk refuses symlinks at every step. A refusal
happens before another company's directory is opened. Outputs are created
with O_EXCL, so an existing file is never replaced.

The planner applies a patch and retries an invalid patch once. A second
invalid patch keeps the incumbent bytes and records fixed reason codes from
``PLAN_REASON_CODES``. No text from the patch is copied into the plan. This
module does not call a model, start a lane, or edit conduct.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import re
import sys
import unicodedata
from pathlib import Path
from typing import Callable, Mapping

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import ledger
import surface

VIEW_FIELDS = ("label", "run_id", "ok", "delivered", "error")
# Keys a rollout record may carry. Anything else is refused, not dropped.
# Cost keys are accepted so harness records load, and are never read.
RECORD_KEYS = frozenset(VIEW_FIELDS + ("cost", "cost_usd"))
# Keys a compose deliverable may carry.
DELIVERABLE_KEYS = frozenset(("label", "task_id", "k", "mode", "text"))
# The error field is a code. Free text is refused.
ERROR_CODES = (
    "",
    "timeout",
    "crashed",
    "no_output",
    "cancelled",
    "budget_exceeded",
    "harness_error",
    "lane_failed",
)
SCORE_FIELDS = ("n_passed", "n_criteria", "frac", "all_pass")
BANNED_WORK_WORDS = ("benchmark", "evaluation", "grader", "rubric", "score")
# Same tripwire strings as harness2 context.GRADER_VERDICT_MARKERS at 1cfe254.
GRADER_VERDICT_MARKERS = (
    "deterministic_eval_summary",
    "deterministic_eval_result",
    "judge_scope_and_deterministic_status",
    "Judge findings on the rendered result",
    '"passed_count"',
    '"pass_rate"',
    '"test_pass_rate"',
)
# A path segment containing one of these words is a grade area.
GRADE_AREA_WORDS = frozenset(
    (
        "grade",
        "grades",
        "graded",
        "grader",
        "graders",
        "grading",
        "result",
        "results",
        "verdict",
        "verdicts",
        "score",
        "scores",
        "scoring",
        "rubric",
        "rubrics",
        "judge",
        "judges",
        "judgement",
        "judgment",
        "ledger",
        "benchmark",
        "benchmarks",
        "evaluation",
        "evaluations",
        "eval",
        "evals",
        "checks",
    )
)
# Inside an input root, a segment containing one of these stems is refused.
GRADE_AREA_STEMS = (
    "grade",
    "grading",
    "result",
    "verdict",
    "score",
    "scoring",
    "rubric",
    "judg",
    "ledger",
    "benchmark",
    "eval",
    "assess",
)
# The only roots the CLI reads, each with the suffixes it allows.
INPUT_ROOTS = {
    "briefs": (".md", ".txt"),
    "runs": (".json",),
    "deliverables": (".json",),
    "diffs": (".diff", ".patch", ".txt"),
    "trees": (".json",),
    "patches": (".json",),
}
# Each CLI read names its kind, and each kind has one root.
INPUT_KINDS = {
    "work": "briefs",
    "runs": "runs",
    "record": "runs",
    "deliverables": "deliverables",
    "diff": "diffs",
    "tree": "trees",
    "incumbent": "trees",
    "patches": "patches",
}
# The only root the CLI writes. It is not an input root.
OUTPUT_ROOT = "packets"
OUTPUT_SUFFIXES = (".json",)
MAX_PATH_SEGMENTS = 4
# Fixed reason codes for the plan file. Nothing else is written there.
PLAN_REASON_CODES = (
    "invalid_path",
    "grade_area",
    "grade_content",
    "grader_marker",
    "too_large",
    "invalid_patch",
)
MAX_PATCH_ATTEMPTS = 2
# Caps are on the bytes that enter a packet, not on a serialized key name.
MAX_ITEM_BYTES = 256 * 1024
MAX_PACKET_BYTES = 1024 * 1024
_SCORE_KEYS = frozenset(SCORE_FIELDS + ("exit_status", "exit_code", "check_status"))
_SLUG = re.compile(r"[a-z0-9][a-z0-9:_-]{0,79}")
_PATH_SEGMENT = re.compile(r"[a-z0-9][a-z0-9._-]{0,79}")
_ZERO_WIDTH = frozenset((0x00AD, 0x180E, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF))
# Cyrillic and Greek letters that render like Latin ones.
_CONFUSABLES = str.maketrans(
    {
        "а": "a", "в": "b", "е": "e", "к": "k", "м": "m", "н": "h", "о": "o", "р": "p",
        "с": "c", "т": "t", "у": "y", "х": "x", "і": "i", "ј": "j", "ѕ": "s", "ԁ": "d",
        "ӏ": "l", "ɡ": "g", "ԛ": "q", "ԝ": "w",
        "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P",
        "С": "C", "Т": "T", "У": "Y", "Х": "X", "І": "I", "Ј": "J", "Ѕ": "S",
        "α": "a", "β": "b", "ε": "e", "ι": "i", "κ": "k", "ν": "v", "ο": "o", "ρ": "p",
        "τ": "t", "υ": "u", "χ": "x", "ω": "w",
        "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K", "Μ": "M",
        "Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T", "Υ": "Y", "Χ": "X",
        # Fraction and division slashes. NFKC turns "¾" into "3⁄4".
        "⁄": "/", "∕": "/", "⧸": "/",
    }
)
_NUMBER_WORDS = (
    r"(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|"
    r"thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|"
    r"forty|fifty|sixty|seventy|eighty|ninety|hundred|half|all|none|every|most)"
)
_NUM = rf"(?:\d+(?:\.\d+)?|{_NUMBER_WORDS})"
# Patterns run on the word form: lowercase, camelCase split, _ and - as spaces.
_WORD_PATTERNS = (
    re.compile(
        r"\b(?:grades?|graded|grading|graders?|scores?|scored|scoring|benchmarks?|"
        r"evaluations?|rubrics?|verdicts?|accuracy|rating|rated|frac|fraction|"
        r"pass ?rate|passrate|passed count|pass count|n passed|n criteria|"
        r"test pass rate|criteria (?:met|passed)|judge(?:d|ment)?|judgment)\b"
    ),
    re.compile(r"\ball pass\s*[=:]"),
    re.compile(r"\b(?:pass|fail|passed|failed)\s*[=:]"),
    re.compile(r"\b(?:result|outcome)\s*[=:]\s*(?:pass|fail|passed|failed)\b"),
)
_COUNT = re.compile(rf"\b{_NUM}\s*(?:[a-z]+\s+){{0,2}}?(?:/|\bof\b|\bout of\b)\s*{_NUM}\b")
_PERCENT = re.compile(rf"\b{_NUM}\s*(?:%|percent\b|per cent\b|pct\b)|%")
_DECIMAL = re.compile(r"(?<![\d.])(?:0?\.\d+|1\.0+)(?![\d.])")
_COUNT_CONTEXT = re.compile(
    r"pass|fail|\bmet\b|check|criteri|point|test|correct|item|requirement|"
    r"rating|score|success|right|wrong|grade"
)
_DECIMAL_CONTEXT = re.compile(
    r"rate|ratio|result|success|accuracy|precision|recall|frac|pass|fail|score|grade|check"
)
_CASED_VERDICT = re.compile(r"\b(?:PASS|FAIL|PASSED|FAILED)\b")
_B64_RUN = re.compile(r"[A-Za-z0-9+/_-]{16,}={0,2}")
_HEX_RUN = re.compile(r"(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{2}){8,}(?![0-9A-Fa-f])")
_WINDOW = 48
_IDENT_CHARS = "A-Za-z0-9_-"


class PacketError(Exception):
    """A packet, tree, or patch was refused. Callers must not write after this.

    ``code`` is a fixed reason code. It never carries text from the input.
    """

    def __init__(self, message: str, code: str = "invalid_patch") -> None:
        super().__init__(message)
        self.code = code


def normalize_text(text: str) -> str:
    """NFKC, drop zero-width and format characters, fold lookalikes."""
    text = unicodedata.normalize("NFKC", text)
    text = "".join(
        char
        for char in text
        if ord(char) not in _ZERO_WIDTH and unicodedata.category(char) != "Cf"
    )
    return unicodedata.normalize("NFKC", text.translate(_CONFUSABLES))


def _word_form(text: str) -> str:
    split = re.sub(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", " ", text)
    split = re.sub(r"[_\-]+", " ", split)
    return split.lower()


def banned_work_word(text: str) -> str | None:
    """Return the banned word found in work text, if any. Match is case-insensitive."""
    if not isinstance(text, str):
        raise PacketError("work must be a string")
    lowered = normalize_text(text).lower()
    for word in BANNED_WORK_WORDS:
        if word in lowered:
            return word
    return None


def _near(text: str, match: re.Match[str], context: re.Pattern[str]) -> bool:
    start = max(0, match.start() - _WINDOW)
    return context.search(text[start : match.end() + _WINDOW]) is not None


def _decoded_runs(text: str) -> list[str]:
    """Decode base64 and hex runs that turn into readable text."""
    found: list[str] = []
    candidates: list[bytes] = []
    for match in _B64_RUN.finditer(text):
        run = match.group(0)
        padded = run + "=" * (-len(run.rstrip("=")) % 4)
        for decoder in (base64.b64decode, base64.urlsafe_b64decode):
            try:
                candidates.append(decoder(padded.encode("ascii")))
            except (binascii.Error, ValueError):
                continue
    for match in _HEX_RUN.finditer(text):
        try:
            candidates.append(bytes.fromhex(match.group(0)))
        except ValueError:
            continue
    for raw in candidates:
        try:
            decoded = raw.decode("utf-8")
        except UnicodeError:
            continue
        if len(decoded) < 4:
            continue
        printable = sum(1 for char in decoded if char.isprintable() or char.isspace())
        if printable >= 0.9 * len(decoded):
            found.append(decoded)
    return found


def find_grade_leak(text: str, _depth: int = 0) -> str | None:
    """Return the kind of grade content found in ``text``, if any.

    Defense in depth only. The allowlists above are the primary control.
    The returned value is a kind name, not the matched text.
    """
    if not isinstance(text, str):
        raise PacketError("scanned value must be a string")
    norm = normalize_text(text)
    words = _word_form(norm)
    for marker in GRADER_VERDICT_MARKERS:
        if marker in norm or _word_form(marker) in words:
            return "grader_marker"
    for pattern in _WORD_PATTERNS:
        if pattern.search(words):
            return "grade_word"
    if _CASED_VERDICT.search(norm):
        return "verdict"
    for match in _COUNT.finditer(words):
        if _near(words, match, _COUNT_CONTEXT):
            return "count"
    for match in _PERCENT.finditer(words):
        if _near(words, match, _COUNT_CONTEXT):
            return "percent"
    for match in _DECIMAL.finditer(words):
        if _near(words, match, _DECIMAL_CONTEXT):
            return "decimal"
    if _depth < 2:
        for decoded in _decoded_runs(norm):
            if find_grade_leak(decoded, _depth + 1) is not None:
                return "encoded"
    return None


def refuse_grade_text(*texts: str) -> None:
    """Raise PacketError when any text, or all of them joined, carries a grade.

    The message names the kind of hit. It does not quote the text.
    """
    for text in texts:
        if not isinstance(text, str):
            raise PacketError("scanned value must be a string")
    joined = list(texts)
    if len(texts) > 1:
        joined.append(" ".join(texts))
    for text in joined:
        found = find_grade_leak(text)
        if found == "grader_marker":
            raise PacketError("grader verdict marker", "grader_marker")
        if found is not None:
            raise PacketError("grade content", "grade_content")


def _refuse_grade_area(rel: str) -> None:
    """Refuse a path whose segments name a grade, result, verdict, or ledger area."""
    norm = normalize_text(rel)
    for segment in re.split(r"[/\\]", norm):
        tokens = re.split(r"[^a-z0-9]+", _word_form(segment))
        if any(token in GRADE_AREA_WORDS for token in tokens):
            raise PacketError("path is in a grade area", "grade_area")


def _require_rooted_path(rel: object, root: str, suffixes: tuple[str, ...]) -> str:
    """Return ``rel`` if it is ``root/<slug>/.../<slug><suffix>``. Refuse anything else.

    Runs before the library root is joined, so a refused path is never opened.
    """
    if not isinstance(rel, str):
        raise PacketError("path is not an allowed input", "input_path")
    segments = rel.split("/")
    if len(segments) < 2 or len(segments) > MAX_PATH_SEGMENTS or segments[0] != root:
        raise PacketError("path is not an allowed input", "input_path")
    if any(_PATH_SEGMENT.fullmatch(segment) is None for segment in segments[1:]):
        raise PacketError("path is not an allowed input", "input_path")
    if not segments[-1].endswith(suffixes) or segments[-1] in suffixes:
        raise PacketError("path is not an allowed input", "input_path")
    for segment in segments[1:]:
        if any(stem in segment for stem in GRADE_AREA_STEMS):
            raise PacketError("path is in a grade area", "grade_area")
    _refuse_grade_area(rel)
    return rel


def require_input_path(rel: object, kind: str) -> str:
    """Refuse a CLI read outside the root for ``kind``."""
    root = INPUT_KINDS.get(kind)
    if root is None:
        raise PacketError("unknown input kind", "input_path")
    return _require_rooted_path(rel, root, INPUT_ROOTS[root])


def require_output_path(rel: object) -> str:
    """Refuse a CLI write outside ``packets/``."""
    return _require_rooted_path(rel, OUTPUT_ROOT, OUTPUT_SUFFIXES)


def _require_item_size(label: str, value: str | bytes | bytearray) -> None:
    if isinstance(value, str):
        size = len(value.encode("utf-8"))
    elif isinstance(value, (bytes, bytearray)):
        size = len(value)
    else:
        raise PacketError(f"{label} must be text")
    if size > MAX_ITEM_BYTES:
        raise PacketError(f"{label} exceeds item cap", "too_large")


def _require_packet_size(packet: Mapping[str, object]) -> None:
    encoded = json.dumps(packet, sort_keys=True).encode("utf-8")
    if len(encoded) > MAX_PACKET_BYTES:
        raise PacketError("packet exceeds packet cap", "too_large")


def _require_no_score_keys(value: object) -> None:
    """Refuse score keys on the packet. Strings inside those values are separate."""
    if isinstance(value, Mapping):
        for key, item in value.items():
            if str(key) in _SCORE_KEYS:
                raise PacketError("packet would contain a score or a check status")
            _require_no_score_keys(item)
    elif isinstance(value, list):
        for item in value:
            _require_no_score_keys(item)


def _require_keys(record: Mapping[str, object], allowed: frozenset[str], label: str) -> None:
    for key in record:
        if not isinstance(key, str) or key not in allowed:
            raise PacketError(f"{label} has a field outside the allowlist")


def _require_slug(value: object, label: str) -> str:
    if not isinstance(value, str) or _SLUG.fullmatch(value) is None:
        raise PacketError(f"{label} must be a lowercase slug")
    return value


def _rollout_slots(k: object) -> int:
    """Task rollouts the ledger plans for ``k``. Nothing is written."""
    try:
        plan = ledger._build_plan(k)  # type: ignore[arg-type]
    except ledger.LedgerError as exc:
        raise PacketError(str(exc)) from exc
    rollouts = plan.get("rollouts")
    if not isinstance(rollouts, list) or not rollouts:
        raise PacketError("ledger planned no rollouts")
    return len(rollouts)


# Compose stages per k, in the order the ledger reserves them.
_COMPOSE_STAGES = {1: ("session:compose",), 2: ("session:compose-1", "session:compose-2")}


def _compose_slot(book: "ledger.Ledger", run_id: object, k: int) -> str:
    """Return the next unused compose label on ``run_id``. Nothing is written.

    The run must already be planned in this class, at this k, and the
    ledger must be neither started nor finished. Compose never plans a run.
    """
    if not isinstance(run_id, str) or not ledger._run_id_ok(run_id):
        raise PacketError("unknown run")
    if not book.path.exists():
        raise PacketError("unknown run")
    with book._lock():
        state = book._load_state()
    if state.get("finalized") is True:
        raise PacketError("run is finished")
    if state.get("started") is True:
        raise PacketError("ledger already started")
    runs = state.get("runs")
    run = None
    if isinstance(runs, list):
        for item in runs:
            if isinstance(item, dict) and item.get("run_id") == run_id:
                run = item
    if run is None:
        raise PacketError("unknown run")
    run_k = run.get("k")
    if type(run_k) is not int or run_k != k:
        raise PacketError("deliverables k does not match the run")
    entries = state.get("entries")
    used = {entry.get("label") for entry in entries if isinstance(entry, dict)} if isinstance(entries, list) else set()
    for stage in _COMPOSE_STAGES.get(k, ()):
        label = ledger.format_label(book.company, run_id, stage)
        if label not in used:
            return label
    raise PacketError("compose stages are used for this run")


def _decode_tree_text(data: bytes) -> str:
    try:
        return data.decode("utf-8")
    except UnicodeError:
        return data.decode("latin-1")


def _library_parts(rel: str) -> list[str]:
    parts = rel.split("/")
    if not parts or any(part in ("", ".", "..") for part in parts):
        raise PacketError("not an allowed input path", "input_path")
    return parts


def read_company_text(
    companies_root: str,
    company: str,
    class_id: str,
    rel: str,
    session_company: str,
    *,
    kind: str,
) -> str:
    """Read one allowlisted input file for ``kind``.

    A path outside that kind's root is refused before the library is
    opened. The library walk then applies ``surface.company_scope`` (session
    lock and HQ root companies directory), the manifest check, and the
    no-symlink walk. A foreign company raises before its directory is opened.
    """
    require_input_path(rel, kind)
    opened, parent, leaf, _lexical = surface._open_library(
        companies_root, company, class_id, session_company, _library_parts(rel), create=False
    )
    try:
        if leaf is None:
            raise PacketError("not an allowed input path", "input_path")
        data = surface._read_at(parent.fd, leaf)
    finally:
        surface._close_all(opened)
    try:
        return data.decode("utf-8")
    except UnicodeError as exc:
        raise PacketError("library file is not utf-8") from exc


class _Written:
    """A file this module created. ``discard`` removes it again."""

    def __init__(self, parent_fd: int, leaf: str) -> None:
        self._parent_fd = parent_fd
        self._leaf = leaf

    def discard(self) -> None:
        try:
            os.unlink(self._leaf, dir_fd=self._parent_fd)
        except FileNotFoundError:
            pass


def _create_company_file(
    companies_root: str,
    company: str,
    class_id: str,
    rel: str,
    text: str,
    session_company: str,
    then: Callable[[], None] | None = None,
) -> None:
    """Create ``rel`` under ``packets/`` with O_EXCL. ``then`` runs before close.

    If ``then`` raises, the new file is removed and the error propagates.
    """
    if not isinstance(text, str):
        raise PacketError("output must be a string")
    require_output_path(rel)
    payload = text.encode("utf-8")
    opened, parent, leaf, _lexical = surface._open_library(
        companies_root, company, class_id, session_company, _library_parts(rel), create=True
    )
    try:
        if leaf is None:
            raise PacketError("not an allowed input path", "input_path")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | surface._nofollow()
        try:
            fd = os.open(leaf, flags, 0o644, dir_fd=parent.fd)
        except FileExistsError as exc:
            raise PacketError("refusing to overwrite") from exc
        written = _Written(parent.fd, leaf)
        try:
            try:
                view = memoryview(payload)
                while view:
                    view = view[os.write(fd, view):]
                os.fsync(fd)
            finally:
                os.close(fd)
            if then is not None:
                then()
        except BaseException:
            written.discard()
            raise
    finally:
        surface._close_all(opened)


def write_company_text(
    companies_root: str,
    company: str,
    class_id: str,
    rel: str,
    text: str,
    session_company: str,
) -> None:
    """Write one new file under the packets root. Refuses to overwrite. Foreign companies raise first."""
    _create_company_file(companies_root, company, class_id, rel, text, session_company)


def proposer_view(record: Mapping[str, object], *, arm: int = 1, run: int = 1) -> dict[str, object]:
    """Copy the allowlisted RunView fields. Any other key is refused.

    The view's label is ``arm-{arm}`` and its run id is ``run-{run}``. The
    record's own label and run id are checked and scanned, never copied.
    Cost is never read. ``ok`` must equal ``error == ""``.
    """
    if not isinstance(record, Mapping):
        raise PacketError("rollout record must be an object")
    for index in (arm, run):
        if isinstance(index, bool) or not isinstance(index, int) or index < 1:
            raise PacketError("view index must be a positive integer")
    _require_keys(record, RECORD_KEYS, "rollout record")
    label = _require_slug(record.get("label"), "label")
    run_id = _require_slug(record.get("run_id"), "run_id")
    ok = record.get("ok")
    delivered = record.get("delivered")
    if not isinstance(ok, bool):
        raise PacketError("ok must be a boolean")
    if not isinstance(delivered, bool):
        raise PacketError("delivered must be a boolean")
    error = record.get("error", "")
    if error is None:
        error = ""
    if not isinstance(error, str) or error not in ERROR_CODES:
        raise PacketError("error must be an error code")
    if ok is not (error == ""):
        raise PacketError("ok must mean the process ended without an error code")
    refuse_grade_text(label, run_id, error)
    view: dict[str, object] = {
        "label": f"arm-{arm}",
        "run_id": f"run-{run}",
        "ok": ok,
        "delivered": delivered,
        "error": error,
    }
    if tuple(view) != VIEW_FIELDS:
        raise PacketError("proposer view fields drifted")
    _require_no_score_keys(view)
    return view


def _view_strings(view: Mapping[str, object]) -> list[str]:
    return [value for value in view.values() if isinstance(value, str)]


def build_packet(work: str, runs: list[Mapping[str, object]] | None = None) -> dict[str, object]:
    """Build a proposer packet. A banned work word raises before any file write."""
    bad = banned_work_word(work)
    if bad is not None:
        raise PacketError("work text contains a banned word", "grade_content")
    _require_item_size("work", work)
    if runs is not None and not isinstance(runs, list):
        raise PacketError("runs must be a list")
    arms: dict[str, int] = {}
    views: list[dict[str, object]] = []
    for position, record in enumerate(runs or [], start=1):
        label = record.get("label") if isinstance(record, Mapping) else None
        arm = arms.setdefault(label, len(arms) + 1) if isinstance(label, str) else 1
        views.append(proposer_view(record, arm=arm, run=position))
    strings = [work]
    for view in views:
        strings.extend(_view_strings(view))
    refuse_grade_text(*strings)
    packet: dict[str, object] = {"work": work, "runs": views}
    _require_packet_size(packet)
    _require_no_score_keys(packet)
    return packet


def _refuse_tree_text(tree: Mapping[str, bytes]) -> None:
    """Refuse grade-area paths, then scan file names and file text."""
    for rel, data in tree.items():
        if not isinstance(data, (bytes, bytearray)):
            raise PacketError("tree values must be bytes")
        blob = bytes(data)
        _require_item_size("tree file", blob)
        _require_item_size("tree path", str(rel))
        _refuse_grade_area(str(rel))
        refuse_grade_text(str(rel))
        refuse_grade_text(_decode_tree_text(blob))


def validated_tree(tree: Mapping[str, bytes]) -> dict[str, bytes]:
    """Return a normalized tree, or raise before the caller stores it."""
    _refuse_tree_text(tree)
    normalized = surface.apply_tree(tree, {})
    _refuse_tree_text(normalized)
    return normalized


def _diff_header_path(raw: str, prefix: str) -> str | None:
    path = raw.split("\t", 1)[0]
    if path == "/dev/null":
        return None
    if not path.startswith(prefix):
        raise PacketError("harness diff header is not a surface path", "invalid_path")
    return path[len(prefix) :]


def diff_paths(harness_diff: str) -> list[str]:
    """Return the paths a unified diff names. Each must be a non-grade surface path.

    A diff without a ``---``/``+++`` header pair is refused.
    """
    lines = harness_diff.splitlines()
    paths: list[str] = []
    headers = 0
    index = 0
    while index < len(lines):
        line = lines[index]
        if line.startswith("--- ") and index + 1 < len(lines) and lines[index + 1].startswith("+++ "):
            headers += 1
            for raw, prefix in ((line[4:], "a/"), (lines[index + 1][4:], "b/")):
                path = _diff_header_path(raw, prefix)
                if path is not None:
                    paths.append(path)
            index += 2
            continue
        if line.startswith("diff --git "):
            for part in line[len("diff --git ") :].split(" "):
                if part.startswith("a/") or part.startswith("b/"):
                    paths.append(part[2:])
                else:
                    raise PacketError("harness diff header is not a surface path", "invalid_path")
        for prefix in ("rename from ", "rename to ", "copy from ", "copy to "):
            if line.startswith(prefix):
                paths.append(line[len(prefix) :])
        index += 1
    if headers == 0:
        raise PacketError("harness diff names no file", "invalid_path")
    for path in paths:
        try:
            surface.normalize_surface_path(path)
        except surface.SurfaceError as exc:
            raise PacketError("harness diff path is outside the surface", "invalid_path") from exc
        _refuse_grade_area(path)
    return paths


def _identity_tokens(item: Mapping[str, object]) -> list[str]:
    tokens: list[str] = []
    label = item.get("label")
    if isinstance(label, str) and label:
        tokens.append(label)
    task = item.get("task_id")
    mode = item.get("mode")
    k = item.get("k")
    if isinstance(task, str) and task and isinstance(mode, str) and mode:
        tokens.append(f"{task}|{k}|{mode}")
    return tokens


def _candidate_ranks(texts: list[str]) -> list[int]:
    """1-based candidate number per input position, ordered by a hash of the text.

    The order a harness passes deliverables in (for example incumbent
    first) does not decide which candidate number a deliverable gets.
    Equal texts keep their input order.
    """
    keyed = sorted(range(len(texts)), key=lambda i: (hashlib.sha256(texts[i].encode("utf-8")).hexdigest(), i))
    ranks = [0] * len(texts)
    for rank, position in enumerate(keyed, start=1):
        ranks[position] = rank
    return ranks


def _identity_lookup(deliverables: list[Mapping[str, object]], ranks: list[int]) -> dict[str, str]:
    """Map each identity token, lowercased, to its anonymous id.

    Labels must be unique. A ``task_id|k|mode`` token shared by several
    deliverables names no single candidate, so it maps to ``candidate``.
    """
    lookup: dict[str, str] = {}
    labels: set[str] = set()
    for item, rank in zip(deliverables, ranks):
        label = item.get("label")
        if isinstance(label, str) and label:
            if label.lower() in labels:
                raise PacketError("two deliverables share a label")
            labels.add(label.lower())
        for token in _identity_tokens(item):
            key = token.lower()
            anon = f"candidate-{rank}"
            if key in lookup and lookup[key] != anon:
                if key in labels:
                    raise PacketError("a label collides with another identity")
                anon = "candidate"
            lookup[key] = anon
    return lookup


def _anonymize_all(texts: list[str], deliverables: list[Mapping[str, object]], ranks: list[int]) -> list[str]:
    """Replace every candidate's identity in every text, as a whole token only."""
    lookup = _identity_lookup(deliverables, ranks)
    if not lookup:
        return list(texts)
    alternation = "|".join(re.escape(token) for token in sorted(lookup, key=len, reverse=True))
    pattern = re.compile(
        rf"(?<![{_IDENT_CHARS}])(?:{alternation})(?![{_IDENT_CHARS}])",
        re.IGNORECASE,
    )
    return [pattern.sub(lambda match: lookup[match.group(0).lower()], text) for text in texts]


def compose_packet(
    harness_diff: str,
    deliverables: list[Mapping[str, object]],
    *,
    companies_root: str,
    company: str,
    class_id: str,
    session_company: str,
    run_id: str,
    out: str | None = None,
) -> dict[str, object]:
    """Harness diff plus anonymized deliverable text. No check exit status.

    ``run_id`` names a run already planned with ``ledger.plan_run`` for the
    deliverables' k. Compose never plans a run. It records one compose
    session on that run: ``session:compose`` at k=1, ``session:compose-1``
    then ``session:compose-2`` at k=2. Every input refusal, and every ledger
    precondition, is checked before anything is written. With ``out``, the
    packet file is created first and removed again if the ledger refuses the
    stage. Returns the packet.
    """
    if not isinstance(harness_diff, str):
        raise PacketError("harness diff must be a string")
    if not isinstance(deliverables, list) or not deliverables:
        raise PacketError("deliverables must be a non-empty list")
    _require_item_size("harness diff", harness_diff)
    chosen: object = None
    for item in deliverables:
        if not isinstance(item, Mapping):
            raise PacketError("deliverable must be an object")
        _require_keys(item, DELIVERABLE_KEYS, "deliverable")
        k = item.get("k")
        if chosen is None:
            chosen = k
        elif type(k) is not type(chosen) or k != chosen:
            raise PacketError("deliverables carry different k")
    # The ledger's own k check and rollout count, before anything is written.
    slots = _rollout_slots(chosen)
    if len(deliverables) > slots:
        raise PacketError("more deliverables than the ledger plans rollouts for this k")
    texts: list[str] = []
    for item in deliverables:
        text = item.get("text")
        if not isinstance(text, str):
            raise PacketError("deliverable text must be a string")
        _require_item_size("deliverable", text)
        for key in ("label", "task_id", "mode"):
            if key in item:
                _require_slug(item[key], key)
        texts.append(text)
    diff_paths(harness_diff)
    refuse_grade_text(harness_diff)
    # Scan before anonymization, each text alone and all of them joined.
    refuse_grade_text(*texts)
    ranks = _candidate_ranks(texts)
    anonymized = _anonymize_all(texts, deliverables, ranks)
    rendered = [
        {"id": f"candidate-{rank}", "text": text}
        for rank, text in sorted(zip(ranks, anonymized))
    ]
    packet: dict[str, object] = {"harness_diff": harness_diff, "deliverables": rendered}
    _require_packet_size(packet)
    _require_no_score_keys(packet)
    if out is not None:
        require_output_path(out)
    book = ledger.Ledger(companies_root, company, class_id, session_company)
    label = _compose_slot(book, run_id, chosen)  # type: ignore[arg-type]
    stage = {
        "label": label,
        "kind": ledger.KIND_SESSION,
        "lane_id": "packets",
        "provider": "none",
        "account": "none",
        "usd": ledger.UNPRICED,
    }

    def record() -> None:
        try:
            book.commit(stage)
        except ledger.LedgerError as exc:
            raise PacketError(f"ledger refused the compose stage: {exc}") from exc

    if out is None:
        record()
    else:
        _create_company_file(companies_root, company, class_id, out, _dump(packet), session_company, then=record)
    return packet


def _coerce_patch(patch: object) -> dict[str, bytes]:
    if not isinstance(patch, Mapping):
        raise PacketError("patch must be an object")
    out: dict[str, bytes] = {}
    for key, value in patch.items():
        if isinstance(value, str):
            out[str(key)] = value.encode("utf-8")
        elif isinstance(value, (bytes, bytearray)):
            out[str(key)] = bytes(value)
        else:
            raise PacketError("patch value must be a string")
    return out


def _copy_tree(tree: Mapping[str, bytes]) -> dict[str, bytes]:
    copied: dict[str, bytes] = {}
    for key, value in tree.items():
        if not isinstance(value, (bytes, bytearray)):
            raise PacketError("tree values must be bytes")
        copied[str(key)] = bytes(value)
    return copied


def _reason_code(exc: BaseException) -> str:
    if isinstance(exc, surface.SurfaceError):
        return "invalid_path"
    code = getattr(exc, "code", None)
    if isinstance(exc, PacketError) and code in PLAN_REASON_CODES:
        return str(code)
    return "invalid_patch"


def plan_patches(incumbent: Mapping[str, bytes], patches: list[object]) -> dict[str, object]:
    """Try up to two patches. The second invalid patch keeps the incumbent.

    Reasons are fixed codes. Does not call a model. Does not mutate ``incumbent``.
    """
    if not isinstance(patches, list):
        raise PacketError("patches must be a list")
    if len(patches) > MAX_PATCH_ATTEMPTS:
        raise PacketError("a patch is retried once; more than two attempts is refused")
    original = _copy_tree(incumbent)
    reasons: list[str] = []
    for index, patch in enumerate(patches, start=1):
        try:
            merged = validated_tree(surface.apply_tree(original, _coerce_patch(patch)))
        except (PacketError, surface.SurfaceError, TypeError, ValueError) as exc:
            reasons.append(f"attempt {index}: {_reason_code(exc)}")
            if _copy_tree(incumbent) != original:
                raise PacketError("incumbent was mutated") from exc
            continue
        if _copy_tree(incumbent) != original:
            raise PacketError("incumbent was mutated")
        return {
            "tree": merged,
            "fell_back": False,
            "reason": "",
            "attempts": reasons,
        }
    if _copy_tree(incumbent) != original:
        raise PacketError("incumbent was mutated")
    return {
        "tree": _copy_tree(original),
        "fell_back": True,
        "reason": "; ".join(reasons) if reasons else "no patch",
        "attempts": reasons,
    }


def _load_tree_text(text: str) -> dict[str, bytes]:
    raw = json.loads(text)
    if not isinstance(raw, dict):
        raise PacketError("tree file must be an object")
    files = raw["files"] if "files" in raw and isinstance(raw["files"], dict) else raw
    if not isinstance(files, dict):
        raise PacketError("tree file must be an object")
    out: dict[str, bytes] = {}
    for key, value in files.items():
        if not isinstance(key, str) or not isinstance(value, str):
            raise PacketError("tree file values must be strings")
        _require_item_size("tree file", value)
        _refuse_grade_area(key)
        refuse_grade_text(key)
        refuse_grade_text(value)
        out[key] = value.encode("utf-8")
    return out


def _dump(payload: object) -> str:
    return json.dumps(payload, indent=2, sort_keys=True) + "\n"


def _tree_payload(tree: Mapping[str, bytes]) -> dict[str, str]:
    encoded: dict[str, str] = {}
    for key in sorted(tree):
        encoded[key] = tree[key].decode("utf-8")
    return encoded


def _add_scope(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--companies-root", required=True)
    parser.add_argument("--company", required=True)
    parser.add_argument("--class-id", required=True)
    parser.add_argument("--session-company", required=True)


def _read_arg(args: argparse.Namespace, kind: str) -> str:
    rel = getattr(args, kind)
    return read_company_text(args.companies_root, args.company, args.class_id, rel, args.session_company, kind=kind)


# Input arguments per command. Every path is checked before any file is opened.
_COMMAND_INPUTS = {
    "build-packet": ("work", "runs"),
    "proposer-view": ("record",),
    "store-tree": ("tree",),
    "compose": ("diff", "deliverables"),
    "plan": ("incumbent", "patches"),
}


def _require_cli_paths(args: argparse.Namespace) -> None:
    for kind in _COMMAND_INPUTS.get(args.cmd, ()):
        rel = getattr(args, kind)
        if rel is not None:
            require_input_path(rel, kind)
    require_output_path(args.out)


def _write_arg(args: argparse.Namespace, rel: str, text: str) -> None:
    write_company_text(args.companies_root, args.company, args.class_id, rel, text, args.session_company)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="packets")
    sub = parser.add_subparsers(dest="cmd", required=True)

    build = sub.add_parser("build-packet")
    _add_scope(build)
    build.add_argument("--work", required=True)
    build.add_argument("--runs")
    build.add_argument("--out", required=True)

    view = sub.add_parser("proposer-view")
    _add_scope(view)
    view.add_argument("--record", required=True)
    view.add_argument("--out", required=True)

    store = sub.add_parser("store-tree")
    _add_scope(store)
    store.add_argument("--tree", required=True)
    store.add_argument("--out", required=True)

    compose = sub.add_parser("compose")
    _add_scope(compose)
    compose.add_argument("--diff", required=True)
    compose.add_argument("--deliverables", required=True)
    compose.add_argument("--out", required=True)
    compose.add_argument("--run", required=True)

    plan = sub.add_parser("plan")
    _add_scope(plan)
    plan.add_argument("--incumbent", required=True)
    plan.add_argument("--patches", required=True)
    plan.add_argument("--out", required=True)

    args = parser.parse_args(argv)
    try:
        _require_cli_paths(args)
        if args.cmd == "build-packet":
            work = _read_arg(args, "work")
            runs: list[Mapping[str, object]] = []
            if args.runs:
                loaded = json.loads(_read_arg(args, "runs"))
                if not isinstance(loaded, list):
                    raise PacketError("runs file must be a list")
                runs = loaded
            packet = build_packet(work, runs)
            _write_arg(args, args.out, _dump(packet))
        elif args.cmd == "proposer-view":
            record = json.loads(_read_arg(args, "record"))
            _write_arg(args, args.out, _dump(proposer_view(record)))
        elif args.cmd == "store-tree":
            normalized = validated_tree(_load_tree_text(_read_arg(args, "tree")))
            _write_arg(args, args.out, _dump(_tree_payload(normalized)))
        elif args.cmd == "compose":
            diff = _read_arg(args, "diff")
            loaded = json.loads(_read_arg(args, "deliverables"))
            if not isinstance(loaded, list):
                raise PacketError("deliverables file must be a list")
            compose_packet(
                diff,
                loaded,
                companies_root=args.companies_root,
                company=args.company,
                class_id=args.class_id,
                session_company=args.session_company,
                run_id=args.run,
                out=args.out,
            )
            print(args.run)
        elif args.cmd == "plan":
            incumbent = _load_tree_text(_read_arg(args, "incumbent"))
            loaded = json.loads(_read_arg(args, "patches"))
            patches = loaded["patches"] if isinstance(loaded, dict) and "patches" in loaded else loaded
            if not isinstance(patches, list):
                raise PacketError("patches file must be a list")
            result = plan_patches(incumbent, patches)
            tree = result["tree"]
            if not isinstance(tree, dict):
                raise PacketError("planner returned no tree")
            _write_arg(
                args,
                args.out,
                _dump(
                    {
                        "attempts": result["attempts"],
                        "fell_back": result["fell_back"],
                        "reason": result["reason"],
                        "tree": _tree_payload(tree),
                    }
                ),
            )
        else:
            raise PacketError(f"unknown command {args.cmd}")
    except (PacketError, surface.SurfaceError, ledger.LedgerError, json.JSONDecodeError, UnicodeError, OSError) as exc:
        print(f"packets: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
