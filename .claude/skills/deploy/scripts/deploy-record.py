"""Write a searchable deploy record from a deploy's local source.

Run only through deploy-record.sh, which calls `python3 -I` so the interpreter
never imports code from the artifact directory, the current directory, or user
site-packages.

The record is one markdown file, <home>/<subdomain>.md: YAML frontmatter that
says what the deploy is and where it lives, the deploying agent's description,
and the text extracted from the deployed pages. qmd indexes it like any other
project file, which is what makes "where is the deck we made" answerable.

Records sync to every member of the company, so anything the deploy's own gate
hides from some members stays out of the record. The access mode is resolved
fail-closed: only `public` and `company` deploys get page text.

Stdlib only. Compatible with Python 3.8+.

Output: exactly one JSON line on stdout, whatever happens.
  {"ok":true,"record":...,"subdomain":...,"type":...,"access_mode":...,
   "words":N,"truncated":bool,"tags":[...]}
  {"ok":false,"reason":...,"detail":...}
Exit codes: 0 ok, 64 bad arguments or invalid input, 1 runtime failure.
"""

import argparse
import datetime
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
from html.parser import HTMLParser
from urllib.parse import unquote, urlsplit

RECORD_VERSION = 1
BODY_WORD_CAP = 1500
THIN_TEXT_WORDS = 50
MAX_PAGES = 50
MAX_PDFS = 5
MAX_PDF_PAGES = 50
MAX_MEDIA = 50
MAX_HTML_BYTES = 5 * 1024 * 1024
MAX_PDF_TEXT_BYTES = 2 * 1024 * 1024
PDF_TIMEOUT_SECONDS = 20
DESCRIPTION_MAX_CHARS = 2000
TITLE_MAX_CHARS = 200
META_MAX_CHARS = 500

# Primary content types. Search can be scoped by these.
CONTENT_TYPES = (
    "explainer", "report", "memo", "deck", "pdf-deck", "landing", "tool",
    "demo-site", "newsletter", "preview", "asset", "video", "stub",
)
ACCESS_MODES = ("public", "company", "password", "private", "selected")
# Gates whose audience is the whole company or wider. Every other mode,
# including an unknown one, withholds page text: records sync to the company.
TEXT_OK_GATES = ("public", "company")
# Loosest to strictest. "unknown" (an unrecognised app value) ranks strictest.
ACCESS_STRICTNESS = {"public": 0, "company": 1, "password": 2, "selected": 3, "private": 4, "unknown": 5}
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,99}$")
SKIP_DIRS = {"node_modules", ".git", "__pycache__", ".next", ".turbo", ".cache"}
SKIP_SUBTREE_TAGS = {"script", "style", "noscript", "svg", "template"}
BADGE_IDS = {"hq-built-badge"}
BLOCK_TAGS = {
    "address", "article", "aside", "blockquote", "br", "dd", "details", "dialog",
    "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form",
    "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav",
    "ol", "p", "pre", "section", "summary", "table", "td", "th", "tr", "ul",
}
VOID_TAGS = {
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
    "param", "source", "track", "wbr",
}
SUBDOMAIN_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
TAG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")

# Credential shapes scrubbed from every string written to the record. Covers
# the catalog in .claude/skills/import-context/redact.sh (patterns, PEM keys,
# connection-string credentials, env-style assignments) plus common token
# formats that appear on deployed pages.
REDACTIONS = (
    ("private_key", re.compile(
        r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----.*?"
        r"(?:-----END (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----|$)", re.S)),
    ("connection_credentials", re.compile(r"(?<=://)[^/@\s:]+:[^/@\s]+(?=@)")),
    ("env", re.compile(r"(?i)\b([A-Z][A-Z0-9_]*(?:_KEY|_TOKEN|_SECRET|_PASSWORD)=)[^\s\"'<]+")),
    ("jwt", re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")),
    ("anthropic_key", re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}")),
    ("openai_key", re.compile(r"sk-[A-Za-z0-9_-]{20,}")),
    ("github_pat", re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}")),
    ("github_fine", re.compile(r"github_pat_[A-Za-z0-9_]{20,}")),
    ("gitlab_pat", re.compile(r"glpat-[A-Za-z0-9_-]{20,}")),
    ("slack_token", re.compile(r"xox[abposr]-[A-Za-z0-9-]{10,}")),
    ("slack_app", re.compile(r"xapp-[A-Za-z0-9-]{10,}")),
    ("slack_webhook", re.compile(r"hooks\.slack\.com/services/[A-Za-z0-9/_-]+")),
    ("aws_key", re.compile(r"(?:AKIA|ASIA)[0-9A-Z]{16}")),
    ("bearer", re.compile(r"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}")),
    ("google_api", re.compile(r"AIza[0-9A-Za-z_-]{35}")),
    ("stripe_key", re.compile(r"(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{20,}")),
    # Credentials passed in a URL query string or fragment (?token=..., &sig=...).
    ("url_secret", re.compile(
        r"(?i)([?&#;](?:access_token|refresh_token|id_token|token|auth|authorization|api[_-]?key|apikey|key|"
        r"secret|client_secret|password|passwd|pwd|sig|signature|code|x-amz-signature|x-amz-credential|"
        r"x-amz-security-token)=)[^&#\s\"'<>]+")),
    # "password: hunter22", "token = abc123", "apiKey: '...'" in any case.
    ("secret_assignment", re.compile(
        r"(?i)\b((?:password|passwd|pwd|passcode|secret|client[_-]?secret|token|access[_-]?token|"
        r"auth[_-]?token|api[_-]?key|access[_-]?key)\s*[:=]\s*[\"']?)[^\s\"'<>,;&]{4,}")),
)


class Fail(Exception):
    def __init__(self, reason, detail="", code=1):
        super().__init__(reason)
        self.reason = reason
        self.detail = detail
        self.code = code


def emit(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")


def redact(text):
    for name, pattern in REDACTIONS:
        marker = "<REDACTED:%s>" % name
        if pattern.groups:
            # Keep the captured prefix (an env var name), replace the value.
            text = pattern.sub(lambda m, mk=marker: m.group(1) + mk, text)
        else:
            text = pattern.sub(marker, text)
    return text


def collapse(text):
    return re.sub(r"\s+", " ", text or "").strip()


def clip(text, limit):
    text = collapse(text)
    return text if len(text) <= limit else text[:limit].rstrip() + "..."


class PageExtractor(HTMLParser):
    """Collect visible text, title, meta description, media and PDF references."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.lines = [[]]
        self.title_parts = []
        self.meta_description = ""
        self.og_description = ""
        self.alts = []
        self.media = []
        self.pdf_refs = []
        self._skip_tag = None
        self._skip_depth = 0
        self._in_title = False
        self._title_done = False

    # Skipping is tracked against the tag that opened the skipped subtree, so a
    # nested element with the same name does not end the skip early.
    def _start_skip(self, tag):
        self._skip_tag = tag
        self._skip_depth = 1

    def error(self, message):  # Python < 3.10 ParserBase calls this on bad markup
        raise ValueError(message)

    def handle_starttag(self, tag, attrs):
        a = {k: (v or "") for k, v in attrs}
        if self._skip_tag is not None:
            if tag == self._skip_tag and tag not in VOID_TAGS:
                self._skip_depth += 1
            return
        if tag == "title" and not self._title_done:
            self._in_title = True
            return
        if self._in_title:
            # Markup inside an unclosed <title> means the page never closed it.
            self._in_title = False
            self._title_done = True
        if tag == "meta":
            name = a.get("name", "").lower()
            prop = a.get("property", "").lower()
            if name == "description" and not self.meta_description:
                self.meta_description = a.get("content", "")
            elif "og:description" in (name, prop) and not self.og_description:
                self.og_description = a.get("content", "")
            return
        if a.get("id") in BADGE_IDS:
            if tag not in VOID_TAGS:
                self._start_skip(tag)
            return
        if tag in SKIP_SUBTREE_TAGS:
            self._start_skip(tag)
            return
        if tag == "img":
            alt = collapse(a.get("alt", ""))
            if alt:
                self.alts.append(alt)
            self._media(a.get("src", ""))
        elif tag in ("video", "audio", "source"):
            self._media(a.get("src", ""))
        elif tag == "object":
            self._pdf(a.get("data", ""))
        elif tag in ("embed", "iframe"):
            self._pdf(a.get("src", ""))
        elif tag == "a":
            self._pdf(a.get("href", ""))
        if tag in BLOCK_TAGS:
            self.lines.append([])

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag == "title" and self._in_title:
            # <title/> has no text and no end tag.
            self._in_title = False
            return
        if self._skip_tag == tag and tag not in VOID_TAGS:
            # A self-closed <svg/> or <div id="hq-built-badge"/> has no end tag.
            self._skip_depth -= 1
            if self._skip_depth <= 0:
                self._skip_tag = None

    def handle_endtag(self, tag):
        if self._skip_tag is not None:
            if tag == self._skip_tag:
                self._skip_depth -= 1
                if self._skip_depth <= 0:
                    self._skip_tag = None
            return
        if tag == "title" and self._in_title:
            self._in_title = False
            self._title_done = True
            return
        if tag in BLOCK_TAGS:
            self.lines.append([])

    def handle_data(self, data):
        if self._skip_tag is not None:
            return
        if self._in_title:
            self.title_parts.append(data)
            return
        self.lines[-1].append(data)

    def _media(self, src):
        src = (src or "").strip()
        if not src or src.lower().startswith(("data:", "blob:", "javascript:")):
            return
        base = os.path.basename(unquote(urlsplit(src).path))
        if base and base not in self.media and len(self.media) < MAX_MEDIA:
            self.media.append(base)

    def _pdf(self, ref):
        ref = (ref or "").strip()
        if not ref or ref.lower().startswith(("data:", "blob:", "javascript:", "mailto:")):
            return
        if urlsplit(ref).path.lower().endswith(".pdf") and ref not in self.pdf_refs:
            self.pdf_refs.append(ref)

    @property
    def title(self):
        return collapse("".join(self.title_parts))

    @property
    def description(self):
        return collapse(self.meta_description or self.og_description)

    @property
    def text(self):
        out = []
        for parts in self.lines:
            line = collapse("".join(parts))
            if line:
                out.append(line)
        return "\n".join(out)


def contained_file(source_real, path):
    """Real path of `path` when it is a regular file inside the source, else None.

    Symlinks are followed only when their target stays inside the source, so a
    link to a file elsewhere on disk can never put that file in a record.
    FIFOs, devices and directories are refused, so a read can never hang.
    """
    try:
        real = os.path.realpath(path)
        if real != source_real and not real.startswith(source_real + os.sep):
            return None
        if not stat.S_ISREG(os.stat(real).st_mode):
            return None
        return real
    except (OSError, ValueError):
        return None


def read_html(path):
    with open(path, "rb") as fh:
        raw = fh.read(MAX_HTML_BYTES)
    return raw.decode("utf-8", "replace")


def list_pages(source_real, root_real):
    """The root page first, then every other .html page by path, deduplicated
    by real path (a case-insensitive filesystem lists index.html twice)."""
    found = []
    for dirpath, dirnames, filenames in os.walk(source_real):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS and not d.startswith("."))
        for name in sorted(filenames):
            if name.lower().endswith((".html", ".htm")):
                found.append(os.path.join(dirpath, name))
    found.sort(key=lambda p: os.path.relpath(p, source_real).replace(os.sep, "/"))
    pages, seen = [(os.path.join(source_real, "index.html"), root_real)], {root_real}
    for path in found:
        real = contained_file(source_real, path)
        if real is None or real in seen:
            continue
        seen.add(real)
        pages.append((path, real))
        if len(pages) >= MAX_PAGES:
            break
    return pages


def route_of(source_real, page):
    rel = os.path.relpath(page, source_real).replace(os.sep, "/")
    if rel == "index.html":
        return "/"
    if rel.endswith("/index.html"):
        return "/" + rel[: -len("index.html")]
    return "/" + rel


def resolve_pdf(source_real, page_dir, ref, app_host):
    """Map a PDF reference to a regular file inside the source tree, or None."""
    try:
        parts = urlsplit(ref)
        if parts.scheme in ("http", "https"):
            if not app_host or (parts.hostname or "").lower() != app_host:
                return None
            candidate = os.path.join(source_real, unquote(parts.path).lstrip("/"))
        elif parts.scheme or parts.netloc:
            return None
        else:
            path = unquote(parts.path)
            if path.startswith("/"):
                candidate = os.path.join(source_real, path.lstrip("/"))
            else:
                candidate = os.path.join(page_dir, path)
    except ValueError:
        return None
    return contained_file(source_real, candidate)


def pdf_tool():
    configured = os.environ.get("HQ_DEPLOY_RECORD_PDFTOTEXT")
    if configured is not None:
        if configured in ("", "none"):
            return None
        return configured if os.path.isfile(configured) and os.access(configured, os.X_OK) else None
    return shutil.which("pdftotext")


def pdf_text(tool, path):
    """Text of the first MAX_PDF_PAGES pages, read in bounded chunks.

    The trailing "-" sends pdftotext's output to stdout; without it the tool
    would write a .txt file next to the PDF inside the source tree.
    """
    cmd = [tool, "-q", "-enc", "UTF-8", "-l", str(MAX_PDF_PAGES), path, "-"]
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
    except OSError:
        return None
    # A PDF that makes pdftotext hang is killed after the timeout, which ends
    # the blocked read below.
    timer = threading.Timer(PDF_TIMEOUT_SECONDS, proc.kill)
    timer.daemon = True
    timer.start()
    chunks, size = [], 0
    try:
        while size < MAX_PDF_TEXT_BYTES:
            chunk = proc.stdout.read(min(65536, MAX_PDF_TEXT_BYTES - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        if size >= MAX_PDF_TEXT_BYTES:
            proc.kill()
        rc = proc.wait(timeout=PDF_TIMEOUT_SECONDS)
    except (OSError, subprocess.SubprocessError):
        proc.kill()
        proc.wait()
        return None
    finally:
        timer.cancel()
        proc.stdout.close()
    if rc != 0 and size < MAX_PDF_TEXT_BYTES:
        return None
    return b"".join(chunks).decode("utf-8", "replace")


def display_path(source_real):
    """Store the source path relative to the HQ root when it is inside one.

    Absolute paths name the local user and differ per machine, and records
    sync across the team, so they are written relative to HQ or with ~.
    """
    probe, root = source_real, None
    while True:
        # The outermost HQ wins, matching check_home.
        if os.path.isfile(os.path.join(probe, "companies", "manifest.yaml")):
            root = probe
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent
    if root:
        return os.path.relpath(source_real, root).replace(os.sep, "/")
    home = os.path.realpath(os.path.expanduser("~"))
    if source_real == home or source_real.startswith(home + os.sep):
        return "~" + source_real[len(home):].replace(os.sep, "/")
    return source_real.replace(os.sep, "/")


def yaml_str(value):
    # ASCII-escaped JSON strings are valid YAML double-quoted scalars for every
    # input, including control characters and U+2028/U+2029.
    return json.dumps("" if value is None else str(value), ensure_ascii=True)


def yaml_list(values):
    return "[" + ", ".join(yaml_str(v) for v in values) + "]"


def cap_words(text, cap):
    """Keep the first `cap` words while preserving line breaks."""
    total = len(text.split())
    if total <= cap:
        return text, total, False
    kept, count = [], 0
    for line in text.split("\n"):
        words = line.split()
        if count + len(words) <= cap:
            kept.append(line)
            count += len(words)
            continue
        room = cap - count
        if room > 0:
            kept.append(" ".join(words[:room]))
        break
    return "\n".join(kept), total, True


def resolve_access(app, override):
    """The deploy's gate, resolved fail-closed.

    Reads the same fields the deploy skill does (privateMode, accessPolicy.mode,
    accessMode, passwordProtected). When --access-mode is passed too, the
    stricter of the two wins.
    """
    from_app = app_access(app)
    if not override:
        return from_app
    # The flag can only tighten the gate. The skill passes it because gates are
    # set after upload, so the app JSON may still say public; a flag that is
    # looser than the app JSON must never expose a gated deploy's text.
    return max(override, from_app, key=lambda m: ACCESS_STRICTNESS.get(m, len(ACCESS_STRICTNESS)))


GATE_FIELDS = ("privateMode", "passwordProtected", "accessMode", "accessPolicy")


def app_access(app):
    """Every gate field the app carries counts, and the strictest wins, so an
    accessMode of public cannot hide passwordProtected or privateMode. An app
    object with none of the gate fields says nothing about its gate and counts
    as unknown. Legacy apps carry the fields with null/false values: public."""
    if not any(key in app for key in GATE_FIELDS):
        return "unknown"
    modes = []
    if app.get("privateMode") is True:
        modes.append("private")
    if app.get("passwordProtected") is True:
        modes.append("password")
    policy = app.get("accessPolicy")
    for mode in (policy.get("mode") if isinstance(policy, dict) else None, app.get("accessMode")):
        if mode is None:
            continue
        if not isinstance(mode, str):
            modes.append("unknown")
            continue
        mode = mode.strip().lower()
        if mode:
            modes.append(mode if mode in ACCESS_MODES else "unknown")
    if not modes:
        return "public"
    return max(modes, key=lambda m: ACCESS_STRICTNESS.get(m, len(ACCESS_STRICTNESS)))


class ArgFail(argparse.ArgumentParser):
    def error(self, message):
        raise Fail("bad_args", message, 64)


def parse_args(argv):
    parser = ArgFail(prog="deploy-record.sh", add_help=False)
    parser.add_argument("--app-json", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--home", required=True)
    parser.add_argument("--description", required=True)
    parser.add_argument("--type", dest="content_type", required=True)
    parser.add_argument("--access-mode", default="")
    parser.add_argument("--project", default="")
    parser.add_argument("--company", default="")
    parser.add_argument("--created-by", default="")
    parser.add_argument("--deploy-id", default="")
    parser.add_argument("--source-path", default="")
    parser.add_argument("--tag", action="append", default=[])
    return parser.parse_args(argv)


def load_app(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            app = json.load(fh)
    except (OSError, ValueError) as exc:
        raise Fail("invalid_app_json", str(exc)[:200], 64)
    if not isinstance(app, dict):
        raise Fail("invalid_app_json", "app JSON must be an object", 64)
    subdomain = app.get("subdomain")
    subdomain = subdomain.strip() if isinstance(subdomain, str) else ""
    if not SUBDOMAIN_RE.match(subdomain):
        raise Fail("invalid_app_json", "subdomain missing or not a safe DNS label", 64)
    app["subdomain"] = subdomain
    return app


def ensure_home(home):
    try:
        os.makedirs(home, exist_ok=True)
    except (OSError, ValueError) as exc:
        raise Fail("home_not_writable", "%s: %s" % (home, getattr(exc, "strerror", None) or exc))
    if not os.path.isdir(home) or not os.access(home, os.W_OK | os.X_OK):
        raise Fail("home_not_writable", home)


def manifest_companies(root):
    """Company slugs in companies/manifest.yaml, in either supported layout."""
    names = set()
    wrapped = in_companies = False
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
                    continue
                m = re.match(r"^  ([A-Za-z0-9][A-Za-z0-9._-]*):", line)
                if in_companies and m:
                    names.add(m.group(1))
            elif top:
                names.add(top.group(1))
    names.discard("_template")
    names.discard("unaffiliated_repos")
    return names


def check_home(home, company, project):
    """Keep the record inside the company it names.

    A home under an HQ's companies/ folder must sit inside companies/<company>/
    for a company listed in the manifest; an unset --company or --project is
    taken from that path. A home outside every companies/ folder is allowed
    only when no company is claimed. Returns (company, project).
    """
    for name, value in (("--company", company), ("--project", project)):
        if value and not SLUG_RE.match(value):
            raise Fail("bad_args", "%s must be a lowercase slug" % name, 64)
    home_real = os.path.realpath(home)
    root = None
    probe = home_real
    while True:
        # Keep walking: the outermost HQ wins, so a companies/manifest.yaml
        # planted inside one company's tree cannot pose as an HQ root and
        # relabel that folder as another company's.
        if os.path.isfile(os.path.join(probe, "companies", "manifest.yaml")):
            root = probe
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent
    parts = os.path.relpath(home_real, root).split(os.sep) if root else []
    if not parts or parts[0] != "companies":
        if company:
            raise Fail("home_outside_company", "--home must be inside companies/%s/ of an HQ" % company, 64)
        return company, project
    if len(parts) < 2:
        raise Fail("home_outside_company", "--home must be inside a company folder, not companies/ itself", 64)
    owner = parts[1]
    if company and company != owner:
        raise Fail("home_outside_company", "--home is not inside companies/%s/" % company, 64)
    if owner not in manifest_companies(root):
        raise Fail("company_not_found", "companies/manifest.yaml does not list the home's company", 64)
    if len(parts) >= 4 and parts[2] == "projects":
        if project and project != parts[3]:
            raise Fail("home_outside_company", "--home is not inside projects/%s/" % project, 64)
        project = project or parts[3]
    return owner, project


def check_target(target):
    """Refuse to replace a file that is not a deploy record."""
    if not os.path.lexists(target):
        return
    if os.path.islink(target) or not os.path.isfile(target):
        raise Fail("record_conflict", "%s exists and is not a deploy record" % target)
    try:
        with open(target, "r", encoding="utf-8", errors="replace") as fh:
            head = fh.read(64)
    except OSError as exc:
        raise Fail("record_conflict", "%s: %s" % (target, exc.strerror or exc))
    if not head.startswith('---\nrecord: "hq-deploy"\n'):
        raise Fail("record_conflict", "%s exists and is not a deploy record" % target)


def write_atomic(target, content):
    """Write via a temp file in the same directory and rename over the target.

    A reader sees either the old record or the new one, never a partial file,
    and a failed write leaves no temp file behind.
    """
    home = os.path.dirname(target)
    mask = os.umask(0)
    os.umask(mask)
    fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(target) + ".", suffix=".tmp", dir=home)
    done = False
    try:
        if hasattr(os, "fchmod"):
            os.fchmod(fd, 0o666 & ~mask)
        with os.fdopen(fd, "w", encoding="utf-8", errors="replace") as fh:
            fh.write(content)
        os.replace(tmp, target)
        done = True
    except OSError as exc:
        raise Fail("write_failed", "%s: %s" % (target, exc.strerror or exc))
    finally:
        if not done:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def extract(source_real, root_real, app_host):
    """Parse every page. Returns a dict of what the record needs.

    A page that fails to parse keeps the text read before the failure and the
    record is tagged extract-partial; one bad page never sinks the record.
    Once the body cap is reached, later pages still count as routes but are
    not parsed, so a large site cannot make the run slow.
    """
    out = {"routes": [], "sections": [], "alts": [], "media": [], "pdfs": [],
           "title": "", "meta": "", "partial": False, "stopped_early": False}
    words = 0
    for index, (page, real) in enumerate(list_pages(source_real, root_real)):
        route = route_of(source_real, page)
        out["routes"].append(route)
        if words > BODY_WORD_CAP:
            out["stopped_early"] = True
            continue
        parser = PageExtractor()
        try:
            parser.feed(read_html(real))
            parser.close()
        except Exception:  # noqa: BLE001 - malformed markup must not sink the record
            out["partial"] = True
        if index == 0:
            out["title"], out["meta"] = parser.title, parser.description
        text = parser.text
        if text:
            heading = route
            if index > 0 and parser.title:
                heading = "%s (%s)" % (route, clip(parser.title, TITLE_MAX_CHARS))
            out["sections"].append((heading, text))
            words += len(text.split())
        for alt in parser.alts:
            if alt not in out["alts"]:
                out["alts"].append(alt)
                words += len(alt.split())
        for item in parser.media:
            if item not in out["media"] and len(out["media"]) < MAX_MEDIA:
                out["media"].append(item)
        for ref in parser.pdf_refs:
            resolved = resolve_pdf(source_real, os.path.dirname(real), ref, app_host)
            if resolved and resolved not in out["pdfs"] and len(out["pdfs"]) < MAX_PDFS:
                out["pdfs"].append(resolved)
    return out


def build(args):
    description = clip(args.description, DESCRIPTION_MAX_CHARS)
    if not description:
        raise Fail("bad_args", "--description must not be empty", 64)
    content_type = args.content_type.strip().lower()
    if content_type not in CONTENT_TYPES:
        raise Fail("bad_args", "--type must be one of: " + ", ".join(CONTENT_TYPES), 64)
    override = args.access_mode.strip().lower()
    if override and override not in ACCESS_MODES:
        raise Fail("bad_args", "--access-mode must be one of: " + ", ".join(ACCESS_MODES), 64)
    extra_tags = []
    for tag in args.tag:
        tag = tag.strip().lower()
        if not TAG_RE.match(tag):
            raise Fail("bad_args", "--tag values are lowercase letters, digits and dashes", 64)
        extra_tags.append(tag)

    company, project = check_home(args.home, args.company.strip(), args.project.strip())
    app = load_app(args.app_json)

    try:
        source_real = os.path.realpath(args.source)
    except ValueError as exc:
        raise Fail("bad_args", str(exc), 64)
    if not os.path.isdir(source_real):
        raise Fail("no_index_html", "source is not a directory: " + args.source)
    root_real = contained_file(source_real, os.path.join(source_real, "index.html"))
    if root_real is None:
        raise Fail("no_index_html", "no regular index.html inside " + args.source)

    url = redact(app.get("url")) if isinstance(app.get("url"), str) else ""
    app_host = (urlsplit(url).hostname or "").lower()
    access_mode = resolve_access(app, override)
    withhold = access_mode not in TEXT_OK_GATES

    title = meta_description = body = ""
    media, routes = [], ["/"]
    words, truncated = 0, False
    tags = ["deploy", content_type]
    if withhold:
        # Nothing from the pages: not text, titles, file names, routes or
        # counts. Every one of them can carry the part the gate protects.
        tags.append("text-withheld")
    else:
        found = extract(source_real, root_real, app_host)
        routes, media = found["routes"], found["media"]
        title = clip(redact(found["title"]), TITLE_MAX_CHARS)
        meta_description = clip(redact(found["meta"]), META_MAX_CHARS)
        pdf_sections, pdf_unread = [], False
        if found["pdfs"]:
            tool = pdf_tool()
            for pdf in found["pdfs"]:
                text = pdf_text(tool, pdf) if tool else None
                if text is None:
                    pdf_unread = True
                    continue
                pdf_sections.append((os.path.basename(pdf), collapse(text)))
        chunks = []
        multi = len(routes) > 1
        for heading, text in found["sections"]:
            chunks.append(("### " + heading + "\n" + text) if multi else text)
        if found["alts"]:
            chunks.append("### Image text\n" + "\n".join(found["alts"]))
        for name, text in pdf_sections:
            if text:
                chunks.append("### PDF: " + name + "\n" + text)
        body, words, truncated = cap_words(redact("\n\n".join(chunks)), BODY_WORD_CAP)
        truncated = truncated or found["stopped_early"]
        # Tags are emitted in a fixed order so records diff cleanly across reruns.
        if words < THIN_TEXT_WORDS:
            tags.append("thin-text")
        if pdf_unread:
            tags.append("needs-description")
        if found["partial"]:
            tags.append("extract-partial")
    for tag in extra_tags:
        if tag not in tags:
            tags.append(tag)

    home_before = os.path.realpath(args.home)
    ensure_home(args.home)
    # Check again now the folder exists: a link swapped in while it was being
    # created must not carry the record somewhere the first check refused.
    if os.path.realpath(args.home) != home_before or check_home(args.home, company, project) != (company, project):
        raise Fail("home_outside_company", "--home changed while it was being created", 64)

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    name = redact(app["name"]) if isinstance(app.get("name"), str) and app.get("name") else app["subdomain"]
    heading = title or (clip(redact(app["title"]), TITLE_MAX_CHARS) if not withhold and isinstance(app.get("title"), str) and app.get("title") else name)
    created_at = app.get("createdAt") if isinstance(app.get("createdAt"), str) and app.get("createdAt") else now
    deploy_id = redact(args.deploy_id or (app.get("deployId") if isinstance(app.get("deployId"), str) else ""))
    created_by = redact(args.created_by)

    front = [
        ("record", yaml_str("hq-deploy")),
        ("record_version", str(RECORD_VERSION)),
        ("app_id", yaml_str(app.get("id"))),
        ("name", yaml_str(name)),
        ("subdomain", yaml_str(app["subdomain"])),
        ("url", yaml_str(url)),
        ("app_type", yaml_str(app.get("type") or "")),
        ("type", yaml_str(content_type)),
        ("access_mode", yaml_str(access_mode)),
        ("company", yaml_str(company)),
        ("project", yaml_str(project)),
        # --source-path names the real source when --source is a stand-in (an
        # app deploy recorded from a generated page).
        ("source_path", yaml_str(clip(redact(args.source_path), 300) if args.source_path.strip()
                                 else display_path(source_real))),
        ("created_by", yaml_str(created_by)),
        ("created_at", yaml_str(created_at)),
        ("recorded_at", yaml_str(now)),
        ("deploy_id", yaml_str(deploy_id)),
        ("title", yaml_str(title)),
        ("meta_description", yaml_str(meta_description)),
        ("routes", yaml_list(routes)),
        ("media", yaml_list(media)),
        ("words_extracted", str(words)),
        ("truncated", "true" if truncated else "false"),
        ("tags", yaml_list(tags)),
    ]
    lines = ["---"] + ["%s: %s" % (k, v) for k, v in front] + ["---", ""]
    lines += ["# " + collapse(heading), "", redact(description), ""]
    if withhold:
        lines += [
            "Page text is not stored for this deploy (access mode: %s), because records "
            "are readable by everyone in the company. Open the link to see it." % access_mode,
            "",
        ]
    elif body:
        lines += ["## Page text", "", body, ""]
    content = "\n".join(lines)

    target = os.path.join(os.path.realpath(args.home), app["subdomain"] + ".md")
    check_target(target)
    write_atomic(target, content)

    return {
        "ok": True,
        "record": target,
        "subdomain": app["subdomain"],
        "type": content_type,
        "access_mode": access_mode,
        "words": words,
        "truncated": truncated,
        "tags": tags,
    }


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
