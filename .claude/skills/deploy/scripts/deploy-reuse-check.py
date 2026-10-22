"""Find existing deploy records that do the same job as a new deploy.

Run through deploy-reuse-check.sh, which documents the interface. Standard
library only, Python 3.8+, run with -I. Reads only the qmd index and the
matched record files; never the deployed pages, and never changes the index.
"""

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,99}$")
# A record is <...>/deploys/<subdomain>.md; copied sources under
# deploys/<subdomain>/source/ are not records.
RECORD_PATH_RE = re.compile(r"/deploys/([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)\.md$")
# Tuned on the US-007 benchmark (2026-10-21, 85 public records): a record
# searched with its own description scores about 0.70, so 0.75 never asked,
# and 0.55 noted on 53 of 85 records. At 0.68 the check asks on 10 of 85
# (mostly true variants) and notes on 21 more.
ASK_AT = 0.68     # ask at or above this score
NOTE_AT = 0.62    # one line naming the closest deploy between NOTE_AT and ASK_AT
MAX_CANDIDATES = 3
QUERY_RESULTS = 10
DESC_CHARS = 160
QUERY_CHARS = 400
QMD_TIMEOUT_SECS = 20


class Fail(Exception):
    def __init__(self, reason, detail=None):
        super().__init__(reason)
        self.reason = reason
        self.detail = detail


def emit(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def parse_args(argv):
    known = {"--company", "--description", "--type", "--hq-root"}
    opts = {}
    i = 0
    while i < len(argv):
        key = argv[i]
        if key not in known:
            raise Fail("bad_args", "unknown argument: %s" % key[:60])
        if i + 1 >= len(argv):
            raise Fail("bad_args", "missing value for %s" % key)
        if key in opts:
            raise Fail("bad_args", "repeated argument: %s" % key)
        opts[key] = argv[i + 1]
        i += 2
    if not SLUG_RE.match(opts.get("--company", "")):
        raise Fail("bad_args", "--company must be a company slug")
    if not opts.get("--description", "").strip():
        raise Fail("bad_args", "--description is required")
    if opts.get("--type", "static") not in ("static", "app"):
        raise Fail("bad_args", "--type is static or app")
    return opts


def none(reason, started):
    """No candidates: the deploy proceeds. reason says why, for logs only."""
    return {"ok": True, "decision": "none", "candidates": [], "reason": reason,
            "ms": int((time.monotonic() - started) * 1000)}


def query_text(description):
    """The description as one line for qmd vsearch.

    vsearch is used rather than the hybrid `qmd query`: without its LLM
    rerank, hybrid scores are rank-normalised (the best hit is always 1.0), so
    a fixed threshold would ask on every deploy, and the rerank costs an LLM
    pass per deploy. vsearch returns an absolute similarity the Decisions
    table thresholds can apply to.
    """
    text = re.sub(r"[\"\r\n\t]+", " ", description)
    # The query is a positional argument, so a leading dash would read as a
    # qmd flag.
    return " ".join(text.split()).lstrip("- ")[:QUERY_CHARS]


def is_hq_root(path):
    return os.path.isfile(os.path.join(path, "companies", "manifest.yaml"))


def outermost_hq(path):
    """The outermost HQ root at or above path, or None (deploy-record.py's rule)."""
    probe, found = os.path.realpath(path), None
    while True:
        if is_hq_root(probe):
            found = probe
        parent = os.path.dirname(probe)
        if parent == probe:
            return found
        probe = parent


def find_hq_root(opts):
    """--hq-root, $HQ_ROOT, the cwd, then the HQ this script ships in; the
    outermost HQ at or above the first that is an HQ is the root."""
    starts = [opts.get("--hq-root"), os.environ.get("HQ_ROOT"), os.getcwd(),
              os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "..", "..", "..")]
    for start in starts:
        if start and outermost_hq(start):
            return outermost_hq(start)
    return None


def run_qmd(cmd, limit):
    """(returncode, stdout, stderr), or None on timeout.

    qmd wraps node, so the run gets its own process group and a timeout kills
    the whole group; subprocess.run(timeout=) would kill only the direct child
    and leave the node process running.
    """
    proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=limit)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.communicate()
        return None
    return proc.returncode, out, err


def read_record(path):
    """Frontmatter fields and the description paragraph of a record file."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read(64 * 1024).split("\n")
    except OSError:
        return None
    if len(lines) < 2 or lines[0] != "---" or lines[1] != 'record: "hq-deploy"':
        return None
    try:
        end = lines.index("---", 1)
    except ValueError:
        return None
    front = {}
    for line in lines[1:end]:
        key, sep, raw = line.partition(": ")
        if sep:
            try:
                front[key] = json.loads(raw)
            except ValueError:
                continue
    description = ""
    body = lines[end + 1:]
    for i, line in enumerate(body):
        if line.startswith("# "):
            rest = [x for x in body[i + 1:] if x.strip()]
            description = rest[0] if rest else ""
            break
    front["_description"] = description
    return front


def run(opts):
    started = time.monotonic()
    qmd = os.environ.get("HQ_DEPLOY_REUSE_QMD") or shutil.which("qmd")
    if not qmd or qmd == "none" or not os.access(qmd, os.X_OK):
        return none("qmd_missing", started)
    root = find_hq_root(opts)
    if not root:
        return none("hq_root_not_found", started)
    query = query_text(opts["--description"])
    if not query:
        return none("empty_query", started)
    collection = "%s-projects" % opts["--company"]
    cmd = [qmd, "vsearch", query, "-c", collection,
           "-n", str(QUERY_RESULTS), "--format", "json", "--full-path"]
    try:
        limit = float(os.environ.get("HQ_DEPLOY_REUSE_TIMEOUT") or QMD_TIMEOUT_SECS)
    except ValueError:
        limit = QMD_TIMEOUT_SECS
    try:
        result = run_qmd(cmd, max(0.5, min(limit, QMD_TIMEOUT_SECS)))
    except OSError:
        return none("qmd_missing", started)
    if result is None:
        return none("qmd_timeout", started)
    returncode, stdout, stderr = result
    if returncode != 0:
        err = stderr.decode("utf-8", "replace").lower()
        return none("collection_missing" if "collection" in err else "qmd_failed", started)
    try:
        hits = json.loads(stdout.decode("utf-8", "replace") or "[]")
    except ValueError:
        return none("qmd_bad_output", started)
    if not isinstance(hits, list):
        return none("qmd_bad_output", started)

    # Anchored at the HQ root, so a companies/<co>/projects/ folder nested
    # inside another company's tree does not count.
    projects_dir = os.path.join(root, "companies", opts["--company"], "projects") + os.sep
    seen, candidates = set(), []
    for hit in hits:
        if not isinstance(hit, dict):
            continue
        path = str(hit.get("file") or "")
        m = RECORD_PATH_RE.search(path.replace(os.sep, "/"))
        if not m or path in seen:
            continue
        seen.add(path)
        real = os.path.realpath(path)
        if not real.startswith(projects_dir) or not real.endswith(".md"):
            continue
        record = read_record(real)
        if not record or record.get("subdomain") != m.group(1):
            continue
        if opts.get("--type") and record.get("app_type") and record.get("app_type") != opts["--type"]:
            continue
        try:
            score = round(float(hit.get("score") or 0), 3)
        except (TypeError, ValueError):
            score = 0.0
        desc = " ".join(str(record.get("_description") or "").split())
        candidates.append({
            "subdomain": record.get("subdomain"),
            "url": record.get("url") or "",
            "project": record.get("project") or "",
            "score": score,
            "description": desc[:DESC_CHARS],
        })
    candidates.sort(key=lambda c: c["score"], reverse=True)
    del candidates[MAX_CANDIDATES:]
    top = candidates[0]["score"] if candidates else 0.0
    decision = "ask" if top >= ASK_AT else "note" if top >= NOTE_AT else "none"
    out = {"ok": True, "decision": decision, "candidates": candidates,
           "ms": int((time.monotonic() - started) * 1000)}
    if not candidates:
        out["reason"] = "no_records"
    return out


def main(argv):
    try:
        emit(run(parse_args(argv)))
        return 0
    except Fail as exc:
        out = {"ok": False, "reason": exc.reason, "decision": "none", "candidates": []}
        if exc.detail:
            out["detail"] = exc.detail
        emit(out)
        return 64
    except Exception as exc:  # noqa: BLE001 - a check must never stop a deploy
        emit({"ok": False, "reason": "internal_error", "decision": "none", "candidates": [],
              "detail": "%s: %s" % (type(exc).__name__, str(exc)[:160])})
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
