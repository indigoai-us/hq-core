"""/deploy record-existing: write deploy records for the caller's own existing apps.

Run through deploy-record-backfill.sh, which documents the interface. Standard
library only, Python 3.8+, run with -I. Reads hq-deploy and public pages only;
writes only under the caller's company folder and the cursor file.
"""

import base64
import html
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.realpath(os.path.join(HERE, "..", "..", "..", ".."))
DEPLOY_SCRIPTS = HERE
SESSION_VARS = ("HQ_SESSION_ID", "CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID",
                "CODEX_SESSION_ID", "CODEX_THREAD_ID", "GROK_SESSION_ID")
REQUEST_GAP_SECS = 0.5          # at most 2 network requests per second
DESC_CHARS = 300
THIN_WORDS = 50
MAX_LIST_PAGES = 100
FETCH_MAX_BYTES = 5 * 1024 * 1024
FETCH_TIMEOUT_SECS = 15
STEP_TIMEOUT_SECS = 120
SCAN_DEPTH = 6
SCAN_MAX_DIRS = 50000
INDEX_PEEK_BYTES = 64 * 1024
SKIP_SCAN = {"node_modules", ".git", "deploys", "worktrees", "threads", "sessions", "__pycache__",
             ".next", ".turbo", ".cache", "lanes-links", "orchestrator"}
CURSOR_RE = re.compile(r"^[A-Za-z0-9_-]+={0,2}$")
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,99}$")
SUBDOMAIN_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
TYPE_WORDS = (
    ("pdf-deck", ("pdf",)),
    ("deck", ("deck", "slides", "pitch")),
    ("newsletter", ("newsletter", "issue")),
    ("report", ("report", "summary", "digest", "standup", "weekly", "metrics", "brief", "review")),
    ("memo", ("memo", "proposal")),
    ("video", ("video", "film", "reel")),
    ("demo-site", ("demo", "prototype", "mock", "mockup")),
    ("landing", ("landing", "site", "home", "launch", "waitlist")),
    ("tool", ("tool", "calculator", "dashboard", "tracker")),
    ("explainer", ("explainer", "guide", "docs", "playbook", "how")),
)
EXPECT_PAGE = '(.apps | type == "array") and ((.nextCursor == null) or (.nextCursor | type == "string" and length > 0))'


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(DEPLOY_SCRIPTS, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


REC = load_module("hq_deploy_record", "deploy-record.py")


class Fail(Exception):
    def __init__(self, reason, detail=None, code=1):
        super().__init__(reason)
        self.reason = reason
        self.detail = detail
        self.code = code


def emit(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def say(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def parse_args(argv):
    flags = {"--apply", "--copy-sources", "--captions"}
    known = {"--company", "--app", "--source", "--cursor", "--api", "--hq-root", "--search",
             "--set-caption", "--caption"}
    opts = {"--search": []}
    i = 0
    while i < len(argv):
        key = argv[i]
        if key in flags:
            opts[key] = True
            i += 1
            continue
        if key == "--dry-run":
            i += 1
            continue
        if key not in known:
            raise Fail("bad_args", "unknown argument: %s" % key[:60], 64)
        if i + 1 >= len(argv):
            raise Fail("bad_args", "missing value for %s" % key, 64)
        if key == "--search":
            opts["--search"].append(argv[i + 1])
        elif key in opts:
            raise Fail("bad_args", "repeated argument: %s" % key, 64)
        else:
            opts[key] = argv[i + 1]
        i += 2
    if not SLUG_RE.match(opts.get("--company", "")):
        raise Fail("bad_args", "--company must be a company slug", 64)
    if opts.get("--app") and not SUBDOMAIN_RE.match(opts["--app"]):
        raise Fail("bad_args", "--app must be a subdomain", 64)
    if opts.get("--source") and not opts.get("--app"):
        raise Fail("bad_args", "--source needs --app <subdomain>", 64)
    if bool(opts.get("--set-caption")) != bool(opts.get("--caption")):
        raise Fail("bad_args", "--set-caption and --caption go together", 64)
    return opts


def is_hq_root(path):
    return os.path.isfile(os.path.join(path, "companies", "manifest.yaml"))


def find_root(opts):
    for start in (opts.get("--hq-root"), os.environ.get("HQ_ROOT"), os.getcwd(), REPO):
        if not start:
            continue
        probe, found = os.path.realpath(start), None
        while True:
            if is_hq_root(probe):
                found = probe
            parent = os.path.dirname(probe)
            if parent == probe:
                break
            probe = parent
        if found:
            return found
    raise Fail("hq_root_not_found")


def clean_env():
    """No session variables: a backfill must not file every app under the
    project this session happens to be bound to."""
    env = {k: v for k, v in os.environ.items() if k not in SESSION_VARS}
    for key in SESSION_VARS:
        os.environ.pop(key, None)
    return env


def gap_secs():
    try:
        return max(0.0, min(REQUEST_GAP_SECS, float(os.environ.get("HQ_DEPLOY_BACKFILL_GAP", REQUEST_GAP_SECS))))
    except ValueError:
        return REQUEST_GAP_SECS


class Pacer:
    """Keeps network requests at or under 2 per second."""

    def __init__(self):
        self.last = 0.0
        self.gap = gap_secs()
        self.count = 0

    def wait(self):
        delay = self.last + self.gap - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        self.last = time.monotonic()
        self.count += 1


def run_json(cmd, env, timeout=STEP_TIMEOUT_SECS):
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env,
                              timeout=timeout, check=False)
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


def jwt_sub(token):
    try:
        part = token.split(".")[1]
        part += "=" * (-len(part) % 4)
        return str(json.loads(base64.urlsafe_b64decode(part.encode("ascii"))).get("sub") or "")
    except (IndexError, ValueError, AttributeError):
        return ""


def list_apps(opts, company, env, pacer):
    """(apps, owner id). Every page of GET /api/apps; fails closed."""
    stub = os.environ.get("HQ_DEPLOY_BACKFILL_APPS_FILE")
    if stub:
        with open(stub, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return list(data.get("apps") or []), os.environ.get("HQ_DEPLOY_BACKFILL_OWNER", "")
    ident = run_json(["bash", os.path.join(DEPLOY_SCRIPTS, "identity-resolve.sh")], env)
    if ident.get("status") != "ok" or not ident.get("jwt"):
        raise Fail("login_required", "sign in with /hq-login, then run this again")
    owner = jwt_sub(ident["jwt"])
    req_env = dict(env, HQ_DEPLOY_JWT=ident["jwt"])
    api = opts.get("--api") or ""
    if not api:
        # The deploy skill's own chain: HQ_DEPLOY_API, the manifest, then the public default.
        proc = subprocess.run(["bash", os.path.join(DEPLOY_SCRIPTS, "resolve-deploy-api.sh")],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, timeout=30, check=False)
        api = proc.stdout.decode("utf-8", "replace").strip()
    api = api.rstrip("/")
    if not re.match(r"^https://[A-Za-z0-9.-]+(:[0-9]+)?$", api):
        raise Fail("list_failed", "could not resolve the deploy API")
    apps, cursor, seen = [], "", set()
    for _ in range(MAX_LIST_PAGES):
        url = api + "/api/apps?limit=100" + ("&cursor=" + cursor if cursor else "")
        pacer.wait()
        proc = subprocess.run(["bash", os.path.join(DEPLOY_SCRIPTS, "deploy-api-request.sh"),
                               "--stage", "record-existing-list", "--method", "GET", "--url", url,
                               "--header", "X-Org-Slug: " + company, "--expect", EXPECT_PAGE],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=req_env,
                              timeout=60, check=False)
        if proc.returncode != 0:
            raise Fail("list_failed", "the app list request failed")
        try:
            page = json.loads(proc.stdout.decode("utf-8", "replace"))
        except ValueError:
            raise Fail("list_failed", "the app list was not JSON")
        apps.extend(a for a in page.get("apps") or [] if isinstance(a, dict))
        cursor = page.get("nextCursor") or ""
        if not cursor:
            return apps, owner
        if not CURSOR_RE.match(cursor) or cursor in seen:
            raise Fail("list_failed", "unexpected or repeated list cursor")
        seen.add(cursor)
    raise Fail("list_failed", "more than %d pages of apps" % MAX_LIST_PAGES)


def record_header(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            head = fh.read(4096).split("\n")
    except OSError:
        return None
    if len(head) < 2 or head[0] != "---" or head[1] != 'record: "hq-deploy"':
        return None
    tags = []
    for line in head:
        if line.startswith("tags: "):
            try:
                tags = json.loads(line[6:])
            except ValueError:
                tags = []
    return {"tags": tags if isinstance(tags, list) else []}


def existing_records(root, company):
    """{subdomain: record path} for every record under companies/<company>/."""
    found = {}
    base = os.path.join(root, "companies", company)
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d not in ("node_modules", ".git", "source")]
        if os.path.basename(dirpath) != "deploys":
            continue
        for name in filenames:
            if name.endswith(".md") and SUBDOMAIN_RE.match(name[:-3]):
                path = os.path.join(dirpath, name)
                if record_header(path) is not None:
                    found.setdefault(name[:-3], path)
    return found


class SourceIndex:
    """Folders on this machine that hold an index.html, found once."""

    def __init__(self, roots):
        self.by_name = {}
        self.pages = []
        dirs = 0
        for root in roots:
            if not root or not os.path.isdir(root):
                continue
            root = os.path.realpath(root)
            base_depth = root.count(os.sep)
            for dirpath, dirnames, filenames in os.walk(root):
                dirs += 1
                if dirs > SCAN_MAX_DIRS:
                    return
                if dirpath.count(os.sep) - base_depth >= SCAN_DEPTH:
                    dirnames[:] = []
                dirnames[:] = sorted(d for d in dirnames if d not in SKIP_SCAN and not d.startswith("."))
                index = os.path.join(dirpath, "index.html")
                if "index.html" in filenames and os.path.isfile(index) and not os.path.islink(index):
                    self.by_name.setdefault(os.path.basename(dirpath).lower(), dirpath)
                    self.pages.append(dirpath)

    def find(self, app):
        sub = app["subdomain"].lower()
        if sub in self.by_name:
            return self.by_name[sub]
        name = re.sub(r"[^a-z0-9]+", "-", str(app.get("name") or "").lower()).strip("-")
        if name and name in self.by_name:
            return self.by_name[name]
        needle = ("//%s." % sub).encode("utf-8")
        for folder in self.pages:
            try:
                with open(os.path.join(folder, "index.html"), "rb") as fh:
                    if needle in fh.read(INDEX_PEEK_BYTES).lower():
                        return folder
            except OSError:
                continue
        return None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def fetch_public(app, pacer, workdir):
    """A folder holding the live page, or None. Public apps only, no redirects
    (a redirect is a sign-in page), HTML only, 5 MB cap."""
    url = app.get("url")
    if not isinstance(url, str) or not re.match(r"^https?://", url):
        return None
    opener = urllib.request.build_opener(NoRedirect)
    pacer.wait()
    try:
        with opener.open(urllib.request.Request(url, headers={"User-Agent": "hq-record-existing/1"}),
                         timeout=FETCH_TIMEOUT_SECS) as resp:
            if resp.status != 200 or "html" not in (resp.headers.get("Content-Type") or "").lower():
                return None
            body = resp.read(FETCH_MAX_BYTES + 1)
    except (urllib.error.URLError, OSError, ValueError):
        return None
    if len(body) > FETCH_MAX_BYTES:
        return None
    folder = os.path.join(workdir, "fetch-" + app["subdomain"])
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "index.html"), "wb") as fh:
        fh.write(body)
    return folder


def stub_source(app, workdir):
    folder = os.path.join(workdir, "stub-" + app["subdomain"])
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "index.html"), "w", encoding="utf-8") as fh:
        fh.write("<!doctype html><title>%s</title>\n" % html.escape(str(app.get("name") or app["subdomain"])))
    return folder


def guess_type(app):
    if app.get("type") == "app":
        return "tool"
    words = set(re.split(r"[^a-z0-9]+", " ".join(str(app.get(k) or "") for k in ("subdomain", "name", "title")).lower()))
    for content_type, keys in TYPE_WORDS:
        if words.intersection(keys):
            return content_type
    return "explainer"


def page_description(folder, app):
    """The first 300 characters of the page's own text, redacted."""
    index = os.path.join(os.path.realpath(folder), "index.html")
    host = (re.sub(r"^https?://", "", str(app.get("url") or "")).split("/")[0]).lower()
    try:
        found = REC.extract(os.path.realpath(folder), os.path.realpath(index), host)
    except Exception:  # noqa: BLE001 - a bad page falls back to the generic text
        return ""
    text = " ".join(t for _, t in found["sections"]) or found.get("meta") or ""
    return REC.clip(REC.redact(text), DESC_CHARS)


def generic_description(app, access, how):
    name = str(app.get("name") or app["subdomain"])
    text = "%s, a %s deploy at %s." % (name, access, app.get("url") or app["subdomain"])
    if how == "none":
        text += " Recorded by /deploy record-existing; the source was not found on this machine."
    return REC.clip(REC.redact(text), DESC_CHARS)


def dry_home(H, root, company, source, known):
    """Where --apply would put the record, without creating anything."""
    try:
        co, project, _ = H.resolve(root, {"--company": company, "--cwd": root}, os.path.realpath(source), [], known)
    except H.Fail as exc:
        return None, exc.reason
    if project:
        return os.path.join(root, "companies", co, "projects", project, "deploys"), None
    return os.path.join(root, "companies", co, "deploys"), None


def load_cursor(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) and isinstance(data.get("done"), dict) else {"done": {}}
    except (OSError, ValueError):
        return {"done": {}}


def save_cursor(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1, sort_keys=True)
    os.replace(tmp, path)


def rel(root, path):
    return os.path.relpath(path, root) if path and path.startswith(root + os.sep) else path


def process(app, ctx):
    """Record one app. Returns (outcome, line) where outcome is a summary key."""
    root, company, apply = ctx["root"], ctx["company"], ctx["apply"]
    sub = app["subdomain"]
    access = REC.resolve_access(app, "")
    source, how = None, "none"
    if ctx["forced_source"]:
        source, how = os.path.realpath(ctx["forced_source"]), "local"
        if not os.path.isfile(os.path.join(source, "index.html")):
            return "failed", "%s  failed: --source has no index.html" % sub
    else:
        source = ctx["index"].find(app)
        if source:
            how = "local"
        elif access == "public":
            source = fetch_public(app, ctx["pacer"], ctx["workdir"])
            how = "fetch" if source else "none"
    content_type = guess_type(app)
    outcome = {"local": "written_from_local", "fetch": "written_from_fetch", "none": "needs_source"}[how]
    if not apply:
        home, why = dry_home(ctx["H"], root, company, source or root, ctx["known"])
        if how == "local" and why:
            # A source the home step refuses (another company's folder) is not used.
            how, outcome = "none", "needs_source"
            home, why = dry_home(ctx["H"], root, company, root, ctx["known"])
        return outcome, "%s  access=%s  source=%s  type=%s  home=%s  -> would write%s" % (
            sub, access, how if how != "local" else "local:" + rel(root, source), content_type,
            rel(root, home) if home else "?(" + str(why) + ")", " (needs-source)" if how == "none" else "")

    app_file = os.path.join(ctx["workdir"], sub + ".json")
    with open(app_file, "w", encoding="utf-8") as fh:
        json.dump(app, fh)
    home_src = source if how == "local" else (source if how == "fetch" else stub_source(app, ctx["workdir"]))

    def resolve_home(src, copy):
        return run_json(["bash", os.path.join(DEPLOY_SCRIPTS, "deploy-record-home.sh"), "--subdomain", sub,
                         "--source", src, "--app-json", app_file, "--company", company,
                         "--cwd", root, "--hq-root", root, "--copy", copy], ctx["env"])

    home = resolve_home(home_src, "yes" if (how == "local" and ctx["copy_sources"]) else "no")
    if not home["ok"] and how == "local" and home.get("reason") in ("source_in_other_company", "source_too_broad",
                                                                   "source_contains_home"):
        # A folder the home step refuses (another company's, or too broad) is not used.
        how, outcome = "none", "needs_source"
        home = resolve_home(stub_source(app, ctx["workdir"]), "no")
    if not home["ok"]:
        return "failed", "%s  failed at home: %s" % (sub, home.get("reason"))

    if how != "none" and access in REC.TEXT_OK_GATES:
        description = page_description(home["source"], app) or generic_description(app, access, how)
    else:
        description = generic_description(app, access, how)
    tags = ["backfill"] + (["needs-source"] if how == "none" else []) + (["source-fetched"] if how == "fetch" else [])
    record_cmd = ["bash", os.path.join(DEPLOY_SCRIPTS, "deploy-record.sh"), "--app-json", app_file,
                  "--source", home["source"], "--home", home["home"], "--description", description,
                  "--type", content_type, "--company", home.get("company") or company]
    if home.get("project"):
        record_cmd += ["--project", home["project"]]
    if how == "fetch":
        record_cmd += ["--source-path", str(app.get("url") or "")]
    elif how == "none":
        record_cmd += ["--source-path", "needs-source"]
    for tag in tags:
        record_cmd += ["--tag", tag]
    record = run_json(record_cmd, ctx["env"])
    if not record["ok"]:
        return "failed", "%s  failed at record: %s" % (sub, record.get("reason"))
    old = ctx["existing"].get(sub)
    if old and os.path.realpath(old) != os.path.realpath(record["record"]):
        # Only a needs-source record from this command reaches here; the new one replaces it.
        os.remove(old)
    if record.get("words", 0) < THIN_WORDS and (how == "local" or (how == "fetch")):
        ctx["thin"].append({"record": rel(root, record["record"]), "subdomain": sub,
                            "url": app.get("url") or "", "source": rel(root, home["source"]) if how == "local" else ""})
    return outcome, "%s  access=%s  source=%s  type=%s  -> wrote %s%s" % (
        sub, access, how, content_type, rel(root, record["record"]), " (needs-source)" if how == "none" else "")


def set_caption(root, company, record_path, caption):
    """Replace a backfill record's description with a generated caption."""
    path = os.path.realpath(os.path.join(root, record_path))
    company_dir = os.path.realpath(os.path.join(root, "companies", company)) + os.sep
    head = record_header(path) if path.startswith(company_dir) else None
    if head is None or "backfill" not in head["tags"]:
        raise Fail("not_a_backfill_record", "--set-caption takes a record this command wrote", 64)
    caption = REC.clip(REC.redact(" ".join(caption.split())), DESC_CHARS)
    if not caption:
        raise Fail("bad_args", "--caption is empty", 64)
    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    end = lines.index("---", 1)
    for i in range(1, end):
        if lines[i].startswith("tags: "):
            tags = json.loads(lines[i][6:])
            if "caption-generated" not in tags:
                tags.append("caption-generated")
            lines[i] = "tags: " + json.dumps(tags)
    for i in range(end + 1, len(lines)):
        if lines[i].startswith("# "):
            j = i + 1
            while j < len(lines) and not lines[j].strip():
                j += 1
            if j < len(lines):
                lines[j] = caption
            break
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    os.replace(tmp, path)
    return {"ok": True, "record": rel(root, path), "caption": caption}


def run(opts):
    env = clean_env()
    root = find_root(opts)
    company = opts["--company"]
    H = load_module("hq_deploy_record_home", "deploy-record-home.py")
    known, _ = H.read_manifest(root)
    if company not in known:
        raise Fail("company_not_found", company, 64)
    if opts.get("--set-caption"):
        return set_caption(root, company, opts["--set-caption"], opts["--caption"])

    apply = bool(opts.get("--apply"))
    pacer = Pacer()
    apps, owner = list_apps(opts, company, env, pacer)
    if not owner:
        raise Fail("owner_unknown", "could not tell which apps are yours")
    mine = [a for a in apps if a.get("ownerId") == owner and isinstance(a.get("subdomain"), str)
            and SUBDOMAIN_RE.match(a["subdomain"])]
    if opts.get("--app"):
        mine = [a for a in mine if a["subdomain"] == opts["--app"]]
        if not mine:
            raise Fail("app_not_yours", "%s is not one of your apps in %s" % (opts["--app"], company), 64)
    mine.sort(key=lambda a: a["subdomain"])

    cursor_path = opts.get("--cursor") or os.path.join(root, "workspace", "deploy-record-backfill", company + ".json")
    cursor = load_cursor(cursor_path)
    existing = existing_records(root, company)
    counts = {"written_from_local": 0, "written_from_fetch": 0, "needs_source": 0, "skipped": 0, "failed": 0}
    needs, failed = [], []
    workdir = tempfile.mkdtemp(prefix="hq-record-existing-")
    ctx = {"root": root, "company": company, "apply": apply, "pacer": pacer, "workdir": workdir, "env": env,
           "H": H, "known": known, "existing": existing, "thin": [], "copy_sources": bool(opts.get("--copy-sources")),
           "forced_source": opts.get("--source"), "index": None}
    try:
        todo = []
        for app in mine:
            sub = app["subdomain"]
            old = existing.get(sub)
            redo = bool(opts.get("--source")) and old and "needs-source" in (record_header(old) or {}).get("tags", [])
            if (old and not redo) or (sub in cursor["done"] and not redo):
                counts["skipped"] += 1
                continue
            todo.append(app)
        if todo and not ctx["forced_source"]:
            roots = [os.path.join(root, "companies", company, "projects"), os.path.join(root, "workspace"),
                     os.path.join(os.path.expanduser("~"), ".hq", "deploy-hosts")] + list(opts["--search"])
            ctx["index"] = SourceIndex(roots)
        for app in todo:
            outcome, line = process(app, ctx)
            counts[outcome] += 1
            say(line)
            if outcome == "needs_source":
                needs.append(app["subdomain"])
            if outcome == "failed":
                failed.append(app["subdomain"])
            if apply and outcome != "failed":
                cursor["done"][app["subdomain"]] = outcome
                save_cursor(cursor_path, cursor)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    out = {"ok": True, "mode": "apply" if apply else "dry-run", "company": company, "apps_listed": len(apps),
           "yours": len(mine)}
    out.update(counts)
    out["needs_source_apps"] = needs
    out["failed_apps"] = failed
    out["requests"] = pacer.count
    if apply:
        out["cursor"] = rel(root, cursor_path)
    if opts.get("--captions") and apply:
        queue = os.path.join(root, "workspace", "deploy-record-backfill", company + "-captions.json")
        os.makedirs(os.path.dirname(queue), exist_ok=True)
        with open(queue, "w", encoding="utf-8") as fh:
            json.dump(ctx["thin"], fh, indent=1)
        out["captions_queue"] = rel(root, queue)
        out["captions_needed"] = len(ctx["thin"])
    say("record-existing %s (%s): written-from-local=%d written-from-fetch=%d needs-source=%d skipped=%d failed=%d"
        % (company, out["mode"], counts["written_from_local"], counts["written_from_fetch"],
           counts["needs_source"], counts["skipped"], counts["failed"]))
    return out


def main(argv):
    try:
        emit(run(parse_args(argv)))
        return 0
    except Fail as exc:
        out = {"ok": False, "reason": exc.reason}
        if exc.detail:
            out["detail"] = exc.detail
        emit(out)
        return exc.code
    except Exception as exc:  # noqa: BLE001
        emit({"ok": False, "reason": "internal_error", "detail": "%s: %s" % (type(exc).__name__, str(exc)[:160])})
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
