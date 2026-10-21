"""The /deploy record step: resolve the record's home, then write the record.

Run through deploy-record-step.sh, which documents the interface. Standard
library only, Python 3.8+, run with -I.
"""

import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
HOME_SH = os.path.join(HERE, "deploy-record-home.sh")
RECORD_SH = os.path.join(HERE, "deploy-record.sh")
README_MAX_CHARS = 20000
ROUTE_TAG_RE = re.compile(r"^route-[a-z0-9][a-z0-9-]{0,33}$")
ROUTE_PART_RE = re.compile(r" Also at (/\S*): ")
DESCRIPTION_MAX_CHARS = 2000  # deploy-record.py clips the description here
STEP_TIMEOUT_SECS = 120


class Fail(Exception):
    def __init__(self, stage, reason, detail=None):
        super().__init__(reason)
        self.stage = stage
        self.reason = reason
        self.detail = detail


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def parse_args(argv):
    known = {"--app-json", "--source", "--description", "--type", "--access-mode", "--company",
             "--deploy-id", "--route", "--deploy-type", "--hq-root"}
    opts = {}
    i = 0
    while i < len(argv):
        key = argv[i]
        if key not in known:
            raise Fail("args", "bad_args", "unknown argument: %s" % key[:60])
        if i + 1 >= len(argv):
            raise Fail("args", "bad_args", "missing value for %s" % key)
        if key in opts:
            raise Fail("args", "bad_args", "repeated argument: %s" % key)
        opts[key] = argv[i + 1]
        i += 2
    for req in ("--app-json", "--source", "--type"):
        if not opts.get(req):
            raise Fail("args", "bad_args", "missing %s" % req)
    if not (opts.get("--description") or "").strip():
        # The agent that built the artifact writes this paragraph for every
        # deploy; thin pages (video, PDF, image-only) depend on it.
        raise Fail("args", "description_missing", "the deploying agent must pass --description")
    if opts.get("--deploy-type", "static") not in ("static", "app"):
        raise Fail("args", "bad_args", "--deploy-type is static or app")
    return opts


def run_json(cmd):
    """Run a record script; return its one JSON line, whatever the exit code."""
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              timeout=STEP_TIMEOUT_SECS, check=False)
    except subprocess.TimeoutExpired:
        return {"ok": False, "reason": "timeout"}
    lines = proc.stdout.decode("utf-8", "replace").strip().splitlines()
    try:
        out = json.loads(lines[-1]) if lines else {}
    except ValueError:
        out = {}
    if not isinstance(out, dict):
        out = {}
    out.setdefault("ok", False)
    if not out["ok"]:
        out.setdefault("reason", "no_output")
    return out


def load_app(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            app = json.load(fh)
    except (OSError, ValueError):
        raise Fail("prepare", "invalid_app_json")
    if not isinstance(app, dict) or not isinstance(app.get("subdomain"), str) or not app["subdomain"]:
        raise Fail("prepare", "invalid_app_json", "the app JSON has no subdomain")
    return app


def app_stub(source):
    """A page made from README.md and package.json, for app deploys with no index.html."""
    name, about = os.path.basename(os.path.realpath(source)), ""
    pkg = os.path.join(source, "package.json")
    if os.path.isfile(pkg) and not os.path.islink(pkg):
        try:
            with open(pkg, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            if isinstance(data, dict):
                name = str(data.get("name") or name)
                about = str(data.get("description") or "")
        except (OSError, ValueError):
            pass
    readme = ""
    for candidate in ("README.md", "readme.md", "README"):
        path = os.path.join(source, candidate)
        if os.path.isfile(path) and not os.path.islink(path):
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                readme = fh.read(README_MAX_CHARS)
            break
    if not about and not readme:
        raise Fail("prepare", "no_index_html", "app deploy with no index.html, README.md or package.json description")
    stub = tempfile.mkdtemp(prefix="hq-deploy-record-")
    paragraphs = "".join("<p>%s</p>\n" % html.escape(p) for p in re.split(r"\n\s*\n", readme) if p.strip())
    with open(os.path.join(stub, "index.html"), "w", encoding="utf-8") as fh:
        fh.write("<!doctype html><html><head><title>%s</title><meta name=\"description\" content=\"%s\"></head>"
                 "<body>%s</body></html>\n" % (html.escape(name), html.escape(about, quote=True), paragraphs))
    return stub


def route_tag(route):
    slug = re.sub(r"[^a-z0-9]+", "-", route.strip("/").lower()).strip("-")[:34].strip("-")
    tag = "route-" + slug if slug else ""
    return tag if ROUTE_TAG_RE.match(tag) else ""


def route_description(old, route, text):
    """The host description with one " Also at <route>: <text>" part per route.

    A redeploy of a route replaces that route's part, and the newest route's
    part goes last. Past DESCRIPTION_MAX_CHARS the oldest route parts are
    dropped first, then the host's own text is shortened, so the newest
    route's text always fits.
    """
    marks = list(ROUTE_PART_RE.finditer(old))
    base = old[:marks[0].start()] if marks else old
    parts = []
    for i, mark in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(old)
        if mark.group(1) != route:
            parts.append((mark.group(1), old[mark.end():end]))
    parts.append((route, text))

    def compose():
        return base + "".join(" Also at %s: %s" % part for part in parts)

    while len(compose()) > DESCRIPTION_MAX_CHARS and len(parts) > 1:
        parts.pop(0)
    over = len(compose()) - DESCRIPTION_MAX_CHARS
    if over > 0 and base:
        base = base[:max(0, len(base) - over - 3)].rstrip() + "..."
    return compose()


def existing_record(path):
    """(route tags, description) from a record this step wrote before."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError:
        return [], ""
    if not lines or lines[0] != "---" or len(lines) < 2 or lines[1] != 'record: "hq-deploy"':
        return [], ""
    try:
        end = lines.index("---", 1)
    except ValueError:
        return [], ""
    tags = []
    for line in lines[1:end]:
        if line.startswith("tags: "):
            try:
                tags = [t for t in json.loads(line[6:]) if isinstance(t, str) and ROUTE_TAG_RE.match(t)]
            except ValueError:
                tags = []
    body = lines[end + 1:]
    description = ""
    for i, line in enumerate(body):
        if line.startswith("# "):
            rest = [x for x in body[i + 1:] if x.strip()]
            description = rest[0] if rest else ""
            break
    return tags, description


def build(opts):
    app = load_app(opts["--app-json"])
    subdomain = app["subdomain"]
    source = os.path.realpath(opts["--source"])
    if not os.path.isdir(source):
        raise Fail("prepare", "source_not_found")
    description = " ".join(opts["--description"].split())
    stub = None
    record_source, source_path = source, ""
    try:
        if opts.get("--deploy-type") == "app" and not os.path.isfile(os.path.join(source, "index.html")):
            stub = app_stub(source)
            record_source = stub

        home_cmd = ["bash", HOME_SH, "--subdomain", subdomain, "--source", source,
                    "--app-json", opts["--app-json"]]
        for key in ("--access-mode", "--company", "--hq-root"):
            if opts.get(key):
                home_cmd += [key, opts[key]]
        if stub:
            home_cmd += ["--copy", "no"]
        home = run_json(home_cmd)
        if not home["ok"]:
            raise Fail("home", home.get("reason", "failed"), home.get("detail"))
        if stub:
            # The generated page stands in for the source; the record names
            # where the app really lives.
            source_path = home.get("source_path") or ""
        else:
            record_source = home["source"]

        tags = []
        if opts.get("--route"):
            tag = route_tag(opts["--route"])
            old_tags, old_description = existing_record(os.path.join(home["home"], subdomain + ".md"))
            tags = old_tags + ([tag] if tag and tag not in old_tags else [])
            if old_description:
                description = route_description(old_description, opts["--route"], description)

        record_cmd = ["bash", RECORD_SH, "--app-json", opts["--app-json"], "--source", record_source,
                      "--home", home["home"], "--description", description, "--type", opts["--type"],
                      "--company", home.get("company") or ""]
        if home.get("project"):
            record_cmd += ["--project", home["project"]]
        if opts.get("--access-mode"):
            record_cmd += ["--access-mode", opts["--access-mode"]]
        if opts.get("--deploy-id"):
            record_cmd += ["--deploy-id", opts["--deploy-id"]]
        if source_path:
            record_cmd += ["--source-path", source_path]
        for tag in tags:
            record_cmd += ["--tag", tag]
        record = run_json(record_cmd)
        if not record["ok"]:
            raise Fail("record", record.get("reason", "failed"), record.get("detail"))
    finally:
        if stub:
            shutil.rmtree(stub, ignore_errors=True)
    return {"ok": True, "record": record["record"], "home": home["home"],
            "resolution": home.get("resolution"), "copied": bool(home.get("copied")),
            "access_mode": record.get("access_mode"), "words": record.get("words", 0)}


def main(argv):
    try:
        emit(build(parse_args(argv)))
        return 0
    except Fail as exc:
        out = {"ok": False, "stage": exc.stage, "reason": exc.reason}
        if exc.detail:
            out["detail"] = str(exc.detail)[:200]
        emit(out)
        return 1
    except Exception as exc:  # noqa: BLE001 - keep the one-line JSON contract
        emit({"ok": False, "stage": "internal", "reason": "internal_error",
              "detail": "%s: %s" % (type(exc).__name__, str(exc)[:160])})
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
