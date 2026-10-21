"""Resolve where a deploy record lives and keep a copy of the deploy source there.

Run through deploy-record-home.sh, which documents the interface. Standard
library only, Python 3.8+, run with -I so the working directory and PYTHONPATH
cannot shadow a module.
"""

import importlib.util
import json
import os
import re
import shutil
import stat
import sys
import tempfile

SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,99}$")
SUBDOMAIN_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
SESSION_ENV = ("HQ_SESSION_ID", "CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID",
               "CODEX_SESSION_ID", "CODEX_THREAD_ID", "GROK_SESSION_ID")
MAX_FILE_BYTES = 5 * 1024 * 1024
MAX_TOTAL_BYTES = 50 * 1024 * 1024
MAX_FILES = 2000
SKIP_DIRS = {"node_modules": "node_modules", ".git": "git"}
# Records and their sources sync to everyone in the company, so files that
# usually hold credentials never make the copy, even when the deploy had them.
SECRET_NAME_RE = re.compile(
    r"^(\.env(\..+)?|\.envrc|\.npmrc|\.netrc|\.pypirc|\.pgpass|\.htpasswd|\.git-credentials|\.dockercfg"
    r"|credentials(\..+)?|secrets?(\..+)?|service[-_]?account.*\.json|.+\.tfstate(\.backup)?|.+\.tfvars"
    r"|id_(rsa|dsa|ecdsa|ed25519)(_sk)?(\.pub)?|deploy[-_]?key(\.pub)?|.*_rsa|.+\.(pem|key|p12|pfx|jks|keystore|kdbx|ppk))$",
    re.I)
SECRET_NAME_ALLOW = {".env.example", ".env.sample", ".env.template"}
JUNK_NAMES = {".DS_Store", "Thumbs.db"}
COPY_MARKER = ".hq-deploy-source"
# Top-level HQ folders that hold many apps or several companies' work. A
# deploy source is one app folder inside them, never the folder itself.
BROAD_SOURCES = ("repos", "repos/public", "repos/private", "workspace", "workspace/worktrees",
                 "personal", "companies", "core", ".claude")
# Gates whose audience is the whole company or wider. Every other mode,
# including an unknown one, keeps the source out of the company folder.
COPY_OK_GATES = ("public", "company")


def load_record_module():
    """Share access-mode and redaction rules with deploy-record.py."""
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "deploy-record.py")
    spec = importlib.util.spec_from_file_location("hq_deploy_record", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


REC = load_record_module()


class Fail(Exception):
    def __init__(self, reason, code=64, detail=None):
        super().__init__(reason)
        self.reason = reason
        self.code = code
        self.detail = detail


def emit(obj):
    sys.stdout.write(json.dumps(obj, sort_keys=False) + "\n")
    sys.stdout.flush()


def parse_args(argv):
    known = {"--subdomain", "--source", "--company", "--project", "--session-id",
             "--cwd", "--hq-root", "--app-json", "--access-mode", "--copy"}
    opts = {}
    i = 0
    while i < len(argv):
        key = argv[i]
        if key not in known:
            raise Fail("bad_args", detail="unknown argument: %s" % key[:60])
        if i + 1 >= len(argv):
            raise Fail("bad_args", detail="missing value for %s" % key)
        if key in opts:
            raise Fail("bad_args", detail="repeated argument: %s" % key)
        opts[key] = argv[i + 1]
        i += 2
    for req in ("--subdomain", "--source"):
        if not opts.get(req):
            raise Fail("bad_args", detail="missing %s" % req)
    if not SUBDOMAIN_RE.match(opts["--subdomain"]):
        raise Fail("bad_args", detail="--subdomain must be a DNS label")
    for key in ("--company", "--project"):
        if key in opts and not SLUG_RE.match(opts[key]):
            raise Fail("bad_args", detail="%s is not a valid slug" % key)
    if "--session-id" in opts:
        sid = opts["--session-id"]
        if sid in (".", "..") or not SESSION_ID_RE.match(sid):
            raise Fail("bad_args", detail="--session-id is not a valid session id")
    if opts.setdefault("--copy", "yes") not in ("yes", "no"):
        raise Fail("bad_args", detail="--copy is yes or no")
    if "--access-mode" in opts:
        opts["--access-mode"] = opts["--access-mode"].strip().lower()
        if opts["--access-mode"] not in REC.ACCESS_MODES:
            raise Fail("bad_args", detail="--access-mode must be one of: " + ", ".join(REC.ACCESS_MODES))
    return opts


def resolve_access(opts):
    """The deploy's gate, fail-closed: the stricter of --access-mode and the
    app JSON, and "unknown" (no copy) when neither is given."""
    override = opts.get("--access-mode", "")
    if "--app-json" not in opts:
        return override or "unknown"
    try:
        with open(opts["--app-json"], "r", encoding="utf-8") as fh:
            app = json.load(fh)
    except (OSError, ValueError):
        raise Fail("invalid_app_json", detail="--app-json is not readable JSON")
    if not isinstance(app, dict):
        raise Fail("invalid_app_json", detail="--app-json must be an object")
    return REC.resolve_access(app, override)


def is_hq_root(path):
    return os.path.isfile(os.path.join(path, "companies", "manifest.yaml"))


def outermost_hq(path):
    """The outermost HQ root at or above path, or None.

    deploy-record.py uses the same rule, so the two scripts always agree on
    the root, and a companies/manifest.yaml planted inside one company's tree
    cannot pose as an HQ.
    """
    probe, found = os.path.realpath(path), None
    while True:
        if is_hq_root(probe):
            found = probe
        parent = os.path.dirname(probe)
        if parent == probe:
            return found
        probe = parent


def find_hq_root(opts):
    """Start from --hq-root, $HQ_ROOT, the HQ this script ships in, or the
    cwd, in that order; the outermost HQ at or above it is the root."""
    if opts.get("--hq-root"):
        start = os.path.realpath(opts["--hq-root"])
        if not is_hq_root(start):
            raise Fail("bad_args", detail="--hq-root has no companies/manifest.yaml")
        return outermost_hq(start)
    env_root = os.environ.get("HQ_ROOT", "")
    if env_root and is_hq_root(os.path.realpath(env_root)):
        return outermost_hq(env_root)
    here = os.path.dirname(os.path.realpath(__file__))
    candidate = os.path.realpath(os.path.join(here, "..", "..", "..", ".."))
    if is_hq_root(candidate):
        return outermost_hq(candidate)
    found = outermost_hq(opts.get("--cwd") or os.getcwd())
    if found:
        return found
    raise Fail("hq_root_not_found", code=1)


def read_manifest(root):
    """Company slugs and the repo paths each company lists in companies/manifest.yaml.

    Accepts both layouts session-auto-bind.sh accepts: a `companies:` mapping
    with two-space-indented slugs, and the older flat mapping. The template and
    metadata sections are not companies.
    """
    names, repos = set(), {}
    wrapped = in_companies = False
    current = None
    with open(os.path.join(root, "companies", "manifest.yaml"), encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if re.match(r"^companies:\s*(#.*)?$", line):
                wrapped = in_companies = True
                continue
            top = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*):", line)
            if wrapped:
                if top:
                    in_companies = False
                    current = None
                    continue
                m = re.match(r"^  ([A-Za-z0-9][A-Za-z0-9._-]*):", line)
                if in_companies and m:
                    current = m.group(1)
                    names.add(current)
                    continue
            elif top:
                current = top.group(1)
                names.add(current)
                continue
            repo = re.match(r"^\s+-\s+['\"]?(repos/[^'\"#\s]+)", line)
            if repo and current:
                repos[repo.group(1).rstrip("/")] = current
    for meta in ("_template", "unaffiliated_repos"):
        names.discard(meta)
    repos = {path: co for path, co in repos.items() if co in names}
    return names, repos


def company_ok(root, co, known):
    return bool(co) and SLUG_RE.match(co) is not None and co in known \
        and os.path.isdir(os.path.join(root, "companies", co))


def project_dir(root, co, slug):
    return os.path.join(root, "companies", co, "projects", slug)


def project_ok(root, co, slug):
    return bool(co) and SLUG_RE.match(co) is not None and bool(slug) \
        and SLUG_RE.match(slug) is not None and os.path.isdir(project_dir(root, co, slug))


def inside(child, parent):
    return child == parent or child.startswith(parent.rstrip(os.sep) + os.sep)


def read_meta(root, sid):
    """Read top-level scalar keys from workspace/sessions/<sid>/meta.yaml.

    The file belongs to the session hooks; this only reads it.
    """
    path = os.path.join(root, "workspace", "sessions", sid, "meta.yaml")
    meta = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):[ \t]*(.*?)[ \t]*$", line.rstrip("\n"))
                if not m:
                    continue
                value = m.group(2)
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                meta[m.group(1)] = value
    except OSError:
        return None
    return meta


def session_id(opts):
    if opts.get("--session-id"):
        return opts["--session-id"]
    for var in SESSION_ENV:
        val = re.sub(r"\s", "", os.environ.get(var, ""))
        if val and val not in (".", "..") and SESSION_ID_RE.match(val):
            return val
    return ""


def segment_project(root, path):
    """Return (company, slug) from the leaf companies/<co>/projects/<slug> in path."""
    real = os.path.realpath(path)
    if not inside(real, root):
        return None
    parts = os.path.relpath(real, root).split(os.sep)
    found = None
    for i in range(len(parts) - 3):
        if parts[i] == "companies" and parts[i + 2] == "projects":
            found = (parts[i + 1], parts[i + 3])
    return found


def source_owner(root, source_real, known, repos):
    """The company a source inside HQ belongs to, or None when no company claims it.

    A company owns its companies/<co>/ tree, the repos the manifest lists for
    it (and their worktrees under workspace/worktrees/<repo>/), and any
    workspace folder with its slug as a path segment.
    """
    if not inside(source_real, root):
        return None
    parts = os.path.relpath(source_real, root).split(os.sep)
    if parts[0] == "companies" and len(parts) >= 2:
        return parts[1]
    rel = "/".join(parts)
    for path, co in repos.items():
        if rel == path or rel.startswith(path + "/"):
            return co
    if parts[0] == "workspace":
        if len(parts) >= 3 and parts[1] == "worktrees":
            for path, co in repos.items():
                if path.rsplit("/", 1)[-1] == parts[2]:
                    return co
        for part in parts[1:]:
            if part in known:
                return part
    return None


def display_path(root, real):
    """Record paths relative to HQ (or ~) because records sync across machines."""
    if inside(real, root):
        return os.path.relpath(real, root).replace(os.sep, "/")
    home = os.path.realpath(os.path.expanduser("~"))
    if inside(real, home):
        return "~" + real[len(home):].replace(os.sep, "/")
    return real.replace(os.sep, "/")


def resolve(root, opts, source_real, notes, known):
    company = opts.get("--company", "")
    if company and not company_ok(root, company, known):
        raise Fail("company_not_found", detail=company)

    # Rung 1: --project.
    if opts.get("--project"):
        if not company:
            sid = session_id(opts)
            meta = read_meta(root, sid) if sid else None
            company = (meta or {}).get("company_slug", "")
            if not company_ok(root, company, known):
                raise Fail("company_unresolved", detail="--project needs --company or a session bound to a company")
        if not project_ok(root, company, opts["--project"]):
            raise Fail("project_not_found", detail="companies/%s/projects/%s" % (company, opts["--project"]))
        return company, opts["--project"], "flag"

    # Rung 2: the session's bound project.
    sid = session_id(opts)
    if sid:
        meta = read_meta(root, sid)
        if meta is None:
            notes.append("session_meta_missing")
        else:
            meta_co = meta.get("company_slug", "")
            meta_project = meta.get("project", "")
            if not company and company_ok(root, meta_co, known):
                company = meta_co
            if meta_project and "/" in meta_project:
                seg = segment_project(root, os.path.join(root, meta_project))
                meta_project = seg[1] if seg and seg[0] == meta_co else ""
            if meta_project:
                if not company_ok(root, meta_co, known):
                    notes.append("session_company_missing")
                elif meta_co != company:
                    notes.append("session_project_other_company")
                elif project_ok(root, company, meta_project):
                    return company, meta_project, "session"
                else:
                    notes.append("session_project_missing")

    # Rung 3: a companies/<co>/projects/<slug>/ segment in the source, then cwd.
    cwd = opts.get("--cwd") or os.getcwd()
    for label, path in (("source_path", source_real), ("cwd", cwd)):
        seg = segment_project(root, path)
        if not seg:
            continue
        seg_co, seg_slug = seg
        if company and seg_co != company:
            notes.append("%s_project_other_company" % label)
            continue
        if company_ok(root, seg_co, known) and project_ok(root, seg_co, seg_slug):
            return seg_co, seg_slug, label

    # Rung 4: the company-level fallback (Decisions table, 2026-10-15).
    if not company:
        raise Fail("company_unresolved", detail="pass --company or bind the session to a company")
    return company, None, "fallback"


def check_dest(dest_parent, final):
    """Only ever replace a copy this script made. Anything else at these paths
    (a link, a file, a folder someone filled by hand) is left alone."""
    if os.path.lexists(dest_parent) and (os.path.islink(dest_parent) or not os.path.isdir(dest_parent)):
        raise Fail("source_conflict", code=1, detail="<home>/<subdomain> exists and is not a folder")
    if os.path.lexists(final) and (os.path.islink(final) or not os.path.isdir(final)
                                   or not os.path.isfile(os.path.join(final, COPY_MARKER))):
        raise Fail("source_conflict", code=1, detail="<home>/<subdomain>/source exists and was not made by this script")


def read_regular(full):
    """Read a regular file without following a link swapped in after the walk.

    Returns (bytes, None), or (None, reason) when the file is skipped.
    """
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        fd = os.open(full, flags)
    except OSError:
        return None, "symlink" if os.path.islink(full) else "special"
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None, "special"
        if st.st_size > MAX_FILE_BYTES:
            return None, "oversize"
        chunks, size = [], 0
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            size += len(chunk)
            if size > MAX_FILE_BYTES:
                return None, "oversize"
            chunks.append(chunk)
        return b"".join(chunks), None
    finally:
        os.close(fd)


def copy_tree(src, dest_parent, name, owner_of=None, company=None):
    """Copy src into dest_parent/name, swapping it in only once complete.

    owner_of(path) names the company that owns a path (or None). Every folder
    and file in the copy is checked, so a source that holds another company's
    folder (workspace/reports/<other>/, a repo the manifest lists for another
    company) is refused instead of copied.
    """
    counts = {"files": 0, "bytes": 0, "redacted": 0}
    excluded = {"node_modules": 0, "git": 0, "oversize": 0, "symlink": 0,
                "special": 0, "secret_like": 0, "junk": 0}
    final = os.path.join(dest_parent, name)
    check_dest(dest_parent, final)
    os.makedirs(dest_parent, exist_ok=True)
    # Check again now the folder exists, in case a link was swapped in.
    if os.path.realpath(dest_parent) != dest_parent:
        raise Fail("source_conflict", code=1, detail="<home>/<subdomain> became a link")
    check_dest(dest_parent, final)
    tmp = tempfile.mkdtemp(prefix=".%s.tmp-" % name, dir=dest_parent)
    old = None
    try:
        for dirpath, dirnames, filenames in os.walk(src, followlinks=False):
            if owner_of:
                for path in [dirpath] + [os.path.join(dirpath, f) for f in filenames]:
                    owner = owner_of(os.path.realpath(path))
                    if owner is not None and owner != company:
                        raise Fail("source_in_other_company",
                                   detail="a folder inside the source belongs to another company")
            rel_dir = os.path.relpath(dirpath, src)
            target_dir = tmp if rel_dir == "." else os.path.join(tmp, rel_dir)
            keep = []
            for d in sorted(dirnames):
                full = os.path.join(dirpath, d)
                if d in SKIP_DIRS:
                    excluded[SKIP_DIRS[d]] += 1
                elif os.path.islink(full):
                    excluded["symlink"] += 1
                else:
                    keep.append(d)
                    os.makedirs(os.path.join(target_dir, d), exist_ok=True)
            dirnames[:] = keep
            for f in sorted(filenames):
                full = os.path.join(dirpath, f)
                if f in JUNK_NAMES:
                    excluded["junk"] += 1
                    continue
                if SECRET_NAME_RE.match(f) and f not in SECRET_NAME_ALLOW:
                    excluded["secret_like"] += 1
                    continue
                if os.path.islink(full):
                    excluded["symlink"] += 1
                    continue
                data, skipped = read_regular(full)
                if skipped:
                    excluded[skipped] += 1
                    continue
                if counts["files"] + 1 > MAX_FILES or counts["bytes"] + len(data) > MAX_TOTAL_BYTES:
                    raise Fail("source_too_large", code=1,
                               detail="more than %d files or %d MB; check --source" % (MAX_FILES, MAX_TOTAL_BYTES // (1024 * 1024)))
                # Any file that reads as UTF-8 text (html, js, tsx, vue, svelte,
                # json, md, ...) goes through the record writer's redaction.
                text = None
                if b"\x00" not in data:
                    try:
                        text = data.decode("utf-8")
                    except UnicodeDecodeError:
                        text = None
                    if text is not None:
                        clean = REC.redact(text)
                        if clean != text:
                            counts["redacted"] += 1
                            data = clean.encode("utf-8")
                with open(os.path.join(target_dir, f), "wb") as fh:
                    fh.write(data)
                counts["files"] += 1
                counts["bytes"] += len(data)
        with open(os.path.join(tmp, COPY_MARKER), "w", encoding="utf-8") as fh:
            fh.write("Copied by deploy-record-home.sh. A rerun replaces this folder.\n")
        check_dest(dest_parent, final)
        if os.path.lexists(final):
            old = tempfile.mkdtemp(prefix=".%s.old-" % name, dir=dest_parent)
            os.rmdir(old)
            os.replace(final, old)
        os.replace(tmp, final)
        tmp = None
    finally:
        if tmp and os.path.isdir(tmp):
            shutil.rmtree(tmp, ignore_errors=True)
        if old:
            if os.path.isdir(old) and not os.path.islink(old):
                shutil.rmtree(old, ignore_errors=True)
            elif os.path.lexists(old):
                os.unlink(old)
    return counts, excluded


def build(opts):
    access = resolve_access(opts)
    root = find_hq_root(opts)
    source_real = os.path.realpath(opts["--source"])
    if not os.path.isdir(source_real):
        raise Fail("source_not_found")
    notes = []
    known, repos = read_manifest(root)
    company, project, how = resolve(root, opts, source_real, notes, known)
    companies_root = os.path.realpath(os.path.join(root, "companies"))
    if source_real == root or inside(companies_root, source_real):
        raise Fail("source_contains_home", detail="the source holds every company folder")
    if inside(source_real, root) and os.path.relpath(source_real, root).replace(os.sep, "/") in BROAD_SOURCES:
        raise Fail("source_too_broad", detail="--source must be one app folder, not a top-level HQ folder")
    owner = source_owner(root, source_real, known, repos)
    if owner is not None and owner != company:
        # Never carry one company's files into another company's folder.
        raise Fail("source_in_other_company", detail="the source belongs to another company")
    company_dir = os.path.join(root, "companies", company)
    company_real = os.path.join(companies_root, company)
    if project:
        container = os.path.realpath(project_dir(root, company, project))
    else:
        container = os.path.realpath(company_dir)
    # A company or project folder that is a link into another company would
    # carry the copy there; the home must resolve inside the named company.
    if not inside(container, company_real):
        raise Fail("home_outside_company", detail="the company or project folder links outside companies/%s/" % company)
    home = os.path.join(container, "deploys")
    subdomain = opts["--subdomain"]

    out = {"ok": True, "home": home, "home_rel": display_path(root, home),
           "company": company, "project": project, "resolution": how,
           "subdomain": subdomain, "access_mode": access}

    try:
        os.makedirs(home, exist_ok=True)
    except OSError as exc:
        raise Fail("home_not_writable", code=1, detail=type(exc).__name__)
    if os.path.realpath(home) != home:
        raise Fail("home_outside_company", detail="the deploys folder is a link")
    if not os.access(home, os.W_OK | os.X_OK):
        raise Fail("home_not_writable", code=1)

    if inside(source_real, container):
        out.update({"copied": False, "source": source_real,
                    "source_path": display_path(root, source_real)})
    elif access not in COPY_OK_GATES:
        # The company folder syncs to every member, so a gated deploy's files
        # stay where they are; the record notes why there is no copy.
        out.update({"copied": False, "source": source_real,
                    "source_path": display_path(root, source_real),
                    "copy_withheld": access})
        notes.append("source_not_copied_gated")
    elif opts["--copy"] == "no":
        out.update({"copied": False, "source": source_real,
                    "source_path": display_path(root, source_real),
                    "copy_withheld": "not_requested"})
    else:
        if inside(os.path.realpath(home), source_real):
            raise Fail("source_contains_home", detail="the record home lies inside the source")
        index = os.path.join(source_real, "index.html")
        if os.path.islink(index) or not os.path.isfile(index):
            raise Fail("no_index_html", code=1, detail="no regular index.html at the top of --source")
        dest_parent = os.path.join(home, subdomain)
        try:
            counts, excluded = copy_tree(source_real, dest_parent, "source",
                                         owner_of=lambda path: source_owner(root, path, known, repos),
                                         company=company)
        except OSError as exc:
            raise Fail("copy_failed", code=1, detail=type(exc).__name__)
        dest = os.path.join(dest_parent, "source")
        out.update({"copied": True, "source": dest,
                    "source_path": display_path(root, dest),
                    "copied_from": display_path(root, source_real),
                    "files_copied": counts["files"], "bytes_copied": counts["bytes"],
                    "files_redacted": counts["redacted"], "excluded": excluded})
    if notes:
        out["notes"] = notes
    return out


def main(argv):
    try:
        emit(build(parse_args(argv)))
        return 0
    except Fail as exc:
        out = {"ok": False, "reason": exc.reason}
        if exc.detail:
            out["detail"] = exc.detail
        emit(out)
        return exc.code
    except Exception as exc:  # noqa: BLE001 - keep the one-line JSON contract
        emit({"ok": False, "reason": "internal_error", "detail": "%s: %s" % (type(exc).__name__, str(exc)[:160])})
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
