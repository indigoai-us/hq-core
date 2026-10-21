#!/usr/bin/env bash
# hq-core: public
# US-001: closed surface and per-company eval library.
# Uses temp company roots only. Does not read a live companies/ directory.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SURFACE="$ROOT/core/scripts/eval-loop/surface.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$SURFACE" ] || fail "missing $SURFACE"

python3 - "$SURFACE" "$TMP" <<'PY'
import os
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]).resolve().parent))
import surface

tmp = Path(sys.argv[2]).resolve()

# Library access needs the HQ session lock and the HQ root's own companies
# directory, the same checks as the ledger. Each scenario gets its own HQ root.
session_id = "eval-loop-surface-test"
os.environ["HQ_SESSION_ID"] = session_id
os.environ["HQ_HQ_SESSION_NO_CLI"] = "1"
os.environ.pop("CLAUDE_PROJECT_DIR", None)

def bind(*slugs):
    """Write the session bind for the current HQ root. No slugs removes it."""
    meta = Path(os.environ["HQ_ROOT"]) / "workspace" / "sessions" / session_id / "meta.yaml"
    meta.parent.mkdir(parents=True, exist_ok=True)
    if not slugs:
        if meta.exists():
            meta.unlink()
        return
    meta.write_text(f"company_slug: {slugs[0]}\ncompany_slugs: {','.join(slugs)}\n", encoding="utf-8")

def hq_companies(name, lock="indigo"):
    """Make tmp/name an HQ root bound to ``lock`` and return its companies dir."""
    hq = tmp / name
    hq.mkdir(parents=True, exist_ok=True)
    os.environ["HQ_ROOT"] = str(hq)
    bind(lock)
    return hq / "companies"

expected_slots = (
    "skills/",
    "policies/",
    "worker-prompts/",
    "tool-guidance/",
    "subagents/",
)
if surface.SURFACE_SLOTS != expected_slots:
    raise SystemExit(f"surface slots drifted: {surface.SURFACE_SLOTS!r}")

# Paths outside the five slots are rejected, including control-plane names.
for blocked in (
    "core/hooks/pre.sh",
    "conduct/SKILL.md",
    "super-conductor/SKILL.md",
    "hooks/session.sh",
    "plugins/x.md",
    "scripts/run.sh",
    "README.md",
    "skills",
    "skills/",
):
    try:
        surface.normalize_surface_path(blocked)
    except surface.SurfaceError:
        pass
    else:
        raise SystemExit(f"accepted path outside the surface: {blocked}")

for allowed in (
    "skills/a.md",
    "skills/nested/SKILL.md",
    "policies/a.md",
    "worker-prompts/backend-dev.md",
    "tool-guidance/bash.md",
    "subagents/reviewer.md",
):
    if surface.normalize_surface_path(allowed) != allowed:
        raise SystemExit(f"allowed path was rewritten: {allowed}")

# Absolute paths and '..' raise before anything is joined onto a directory.
inc_dir = tmp / "incumbent"
(inc_dir / "skills").mkdir(parents=True)
(inc_dir / "policies").mkdir()
(inc_dir / "skills" / "keep.md").write_bytes(b"KEEP")
(inc_dir / "policies" / "rule.md").write_bytes(b"RULE")
dest = tmp / "dest"
dest.mkdir()
outside = tmp / "outside"
outside.mkdir()
sentinel = outside / "passwd"
sentinel.write_bytes(b"original")

def assert_untouched(label):
    if (inc_dir / "skills" / "keep.md").read_bytes() != b"KEEP":
        raise SystemExit(f"{label}: incumbent was written")
    if (inc_dir / "policies" / "rule.md").read_bytes() != b"RULE":
        raise SystemExit(f"{label}: incumbent policy was written")
    if any(dest.iterdir()):
        raise SystemExit(f"{label}: dest was written: {list(dest.iterdir())}")
    if sentinel.read_bytes() != b"original":
        raise SystemExit(f"{label}: wrote outside dest")
    escaped = tmp / "outside-escape"
    if escaped.exists():
        raise SystemExit(f"{label}: escaped file exists")

for bad in ("skills/../../outside-escape", "/etc/passwd", "skills/../policies/rule.md", r"skills\..\x"):
    incumbent = {"skills/keep.md": b"KEEP", "policies/rule.md": b"RULE"}
    snapshot = dict(incumbent)
    try:
        surface.apply_tree(incumbent, {"skills/keep.md": b"NEW", bad: b"nope"})
    except surface.SurfaceError:
        pass
    else:
        raise SystemExit(f"apply_tree accepted {bad}")
    if incumbent != snapshot:
        raise SystemExit(f"apply_tree mutated incumbent for {bad}")
    try:
        surface.apply_to_directory(inc_dir, {bad: b"nope"}, dest)
    except surface.SurfaceError:
        pass
    else:
        raise SystemExit(f"apply_to_directory accepted {bad}")
    assert_untouched(bad)

# Omitted files inherit the incumbent bytes. The incumbent mapping is not mutated.
incumbent = {"skills/keep.md": b"KEEP", "policies/rule.md": b"RULE"}
merged = surface.apply_tree(incumbent, {"skills/keep.md": b"NEW"})
if merged["policies/rule.md"] != b"RULE":
    raise SystemExit("omitted file did not inherit incumbent bytes")
if merged["skills/keep.md"] != b"NEW":
    raise SystemExit("patched file did not take the new bytes")
if incumbent["skills/keep.md"] != b"KEEP":
    raise SystemExit("apply_tree mutated the incumbent mapping")

surface.apply_to_directory(inc_dir, {"skills/keep.md": b"NEW"}, dest)
if (dest / "skills" / "keep.md").read_bytes() != b"NEW":
    raise SystemExit("dest missing patched skill")
if (dest / "policies" / "rule.md").read_bytes() != b"RULE":
    raise SystemExit("dest omitted file is not the incumbent")
if (inc_dir / "skills" / "keep.md").read_bytes() != b"KEEP":
    raise SystemExit("source incumbent was overwritten")

# Round-trip of an unchanged tree is byte-identical, including a NUL.
tree = {
    "skills/a.md": b"alpha\0beta",
    "policies/b.md": b"policy",
    "worker-prompts/c.md": b"prompt",
    "tool-guidance/d.md": b"tool",
    "subagents/e.md": b"sub",
}
restored = surface.round_trip(tree)
if set(restored) != set(tree):
    raise SystemExit(f"round-trip keys changed: {sorted(restored)}")
for key, data in tree.items():
    if restored[key] != data:
        raise SystemExit(f"round-trip bytes differ for {key}")
if surface.serialize_tree(tree) != surface.serialize_tree(restored):
    raise SystemExit("serialize is not stable across a round-trip")
empty_patch = surface.apply_tree(tree, {})
for key, data in tree.items():
    if empty_patch[key] != data:
        raise SystemExit(f"empty patch changed {key}")

# Two temp company roots. The indigo fixture must not open the other company.
companies = hq_companies("hq-main")
indigo = companies / "indigo" / "eval-library" / "class-001"
other = companies / "otherco" / "eval-library" / "class-001"
other.mkdir(parents=True)
indigo.mkdir(parents=True)
(companies / "manifest.yaml").write_text("companies:\n  indigo:\n    name: Indigo\n")
marker = other / "secret.txt"
marker.write_bytes(b"other-secret")
other_before = marker.read_bytes()

opened = []
real_open = os.open
real_listdir = os.listdir
real_scandir = os.scandir
real_stat = os.stat
real_lstat = os.lstat
real_mkdir = os.mkdir

def _hit(path):
    if isinstance(path, int):
        return
    text = os.fspath(path)
    opened.append(text)
    parts = Path(text).parts
    if "otherco" in parts:
        raise SystemExit(f"opened another company's directory: {text}")

def spy_open(path, flags, *args, **kwargs):
    _hit(path)
    return real_open(path, flags, *args, **kwargs)

def spy_listdir(path):
    _hit(path)
    return real_listdir(path)

def spy_scandir(path="."):
    _hit(path)
    return real_scandir(path)

def spy_stat(path, *args, **kwargs):
    _hit(path)
    return real_stat(path, *args, **kwargs)

def spy_lstat(path, *args, **kwargs):
    _hit(path)
    return real_lstat(path, *args, **kwargs)

def spy_mkdir(path, *args, **kwargs):
    _hit(path)
    return real_mkdir(path, *args, **kwargs)

os.open = spy_open
os.listdir = spy_listdir
os.scandir = spy_scandir
os.stat = spy_stat
os.lstat = spy_lstat
os.mkdir = spy_mkdir
try:
    got = surface.run_indigo_fixture(companies)
    if got != b"cue":
        raise SystemExit(f"indigo fixture read {got!r}")
    # Foreign read and write fail closed and must not open otherco.
    # Do not touch the other company from this block: the spy treats that as a failure.
    try:
        surface.read_library_bytes(companies, "otherco", "class-001", "secret.txt", "indigo")
    except surface.SurfaceError as exc:
        if "session bind" not in str(exc):
            raise SystemExit(f"unexpected bind error: {exc}")
    else:
        raise SystemExit("foreign company read succeeded")
    try:
        surface.write_library_bytes(companies, "otherco", "class-001", "secret.txt", b"overwrite", "indigo")
    except surface.SurfaceError:
        pass
    else:
        raise SystemExit("foreign company write succeeded")
    stray = companies / "indigo" / "escaped"
    try:
        surface.write_library_bytes(companies, "indigo", "class-001", "../escaped", b"nope", "indigo")
    except surface.SurfaceError:
        pass
    else:
        raise SystemExit("library write accepted ..")
finally:
    os.open = real_open
    os.listdir = real_listdir
    os.scandir = real_scandir
    os.stat = real_stat
    os.lstat = real_lstat
    os.mkdir = real_mkdir

if marker.read_bytes() != other_before:
    raise SystemExit("other company file changed")
if (companies / "indigo" / "escaped").exists():
    raise SystemExit("library write escaped the class directory")

# Same assertion with the other company unreadable, in case a join-then-open
# slipped past the spy. PermissionError means we opened it.
os.chmod(other, 0)
try:
    try:
        surface.read_library_bytes(companies, "otherco", "class-001", "secret.txt", "indigo")
    except surface.SurfaceError:
        pass
    except PermissionError:
        raise SystemExit("foreign read opened the other company directory")
    else:
        raise SystemExit("foreign read succeeded against a locked directory")
finally:
    os.chmod(other, 0o755)

if marker.read_bytes() != b"other-secret":
    raise SystemExit("other company marker changed after the locked read")

# Own-company read still works and stays under the library root.
own = surface.read_library_bytes(companies, "indigo", "class-001", "skills/cue.md", "indigo")
if own != b"cue":
    raise SystemExit(f"indigo read returned {own!r}")
cue_path = companies / "indigo" / "eval-library" / "class-001" / "skills" / "cue.md"
if not cue_path.is_file():
    raise SystemExit("library root is not companies/{company}/eval-library/{classId}/")
resolved_root = surface.library_root(companies, "indigo", "class-001", "indigo")
if resolved_root != companies / "indigo" / "eval-library" / "class-001":
    raise SystemExit(f"library_root returned {resolved_root}")

# A symlink slot must not receive a write. The target bytes stay put.
link_root = tmp / "linkroot"
link_root.mkdir()
linked = tmp / "linked-target"
linked.mkdir()
(linked / "stolen.md").write_bytes(b"safe")
os.symlink(linked, link_root / "skills", target_is_directory=True)
try:
    surface.apply_to_directory(inc_dir, {"skills/stolen.md": b"pwned"}, link_root)
except surface.SurfaceError:
    pass
else:
    raise SystemExit("apply_to_directory followed a symlink slot")
if (linked / "stolen.md").read_bytes() != b"safe":
    raise SystemExit("symlink slot was written")
# A valid file sorted before the symlink must also stay unwritten.
if (link_root / "policies" / "rule.md").exists():
    raise SystemExit("apply_to_directory wrote a file before the symlink refusal")

def expect_surface(label, fn):
    try:
        fn()
    except surface.SurfaceError:
        return
    except Exception as exc:
        raise SystemExit(f"{label}: raised {type(exc).__name__}: {exc}") from exc
    else:
        raise SystemExit(f"{label}: accepted")

# NUL and non-UTF-8 stay inside SurfaceError. Callers do not see ValueError
# or UnicodeDecodeError.
expect_surface("NUL path", lambda: surface.normalize_surface_path("skills/a\x00.md"))
bad_utf8 = struct.pack(">I", 3) + b"\xff\xfe\xfd" + struct.pack(">I", 0)
expect_surface("bad utf-8 key", lambda: surface.deserialize_tree(bad_utf8))

# Two spellings of one path are a collision, not a silent overwrite.
expect_surface(
    "duplicate incumbent keys",
    lambda: surface.apply_tree({"skills/a.md": b"1", "skills/./a.md": b"2"}, {}),
)
dup_blob_parts = []
for key, data in (("skills/a.md", b"1"), ("skills/./a.md", b"2")):
    raw = key.encode("utf-8")
    dup_blob_parts.append(struct.pack(">I", len(raw)) + raw + struct.pack(">I", len(data)) + data)
expect_surface("duplicate serialized keys", lambda: surface.deserialize_tree(b"".join(dup_blob_parts)))

# A patch may still replace the incumbent key when both normalize together.
overlaid = surface.apply_tree({"skills/a.md": b"old"}, {"skills/./a.md": b"new"})
if overlaid.get("skills/a.md") != b"new" or len(overlaid) != 1:
    raise SystemExit(f"overlay did not replace the normalized key: {overlaid!r}")

# '..', empty, absolute, and non-ASCII slugs never join a company directory.
for bad_company in ("", "..", ".", "../otherco", "/etc", "Indigo", "ïndigo", "indigo/../otherco"):
    expect_surface(
        f"company {bad_company!r}",
        lambda bad_company=bad_company: surface.library_root(companies, bad_company, "class-001", "indigo"),
    )
for bad_class in ("", "..", ".", "../x", "/tmp", "Class_1"):
    expect_surface(
        f"class {bad_class!r}",
        lambda bad_class=bad_class: surface.library_root(companies, "indigo", bad_class, "indigo"),
    )
# Both sides non-ASCII, so the ASCII slug check is what refuses.
nonascii = companies / "ïndigo" / "eval-library" / "class-001"
nonascii.mkdir(parents=True)
for label, fn in (
    ("non-ascii library_root", lambda: surface.library_root(companies, "ïndigo", "class-001", "ïndigo")),
    ("non-ascii read", lambda: surface.read_library_bytes(companies, "ïndigo", "class-001", "skills/a.md", "ïndigo")),
    ("non-ascii write", lambda: surface.write_library_bytes(companies, "ïndigo", "class-001", "skills/a.md", b"x", "ïndigo")),
):
    try:
        fn()
    except surface.SurfaceError as exc:
        if "invalid" not in str(exc):
            raise SystemExit(f"{label}: refused for the wrong reason: {exc}")
    else:
        raise SystemExit(f"{label}: accepted")
if any(nonascii.iterdir()):
    raise SystemExit("non-ascii company write created files")
expect_surface(
    "empty session company",
    lambda: surface.library_root(companies, "indigo", "class-001", ""),
)

# Unknown companies are refused even when the session slug matches, and a
# write must not create the company directory.
ghost = companies / "ghost" / "eval-library" / "class-001" / "skills"
ghost.mkdir(parents=True)
(ghost / "a.md").write_bytes(b"ghost")
bind("ghost")
expect_surface(
    "unknown company read",
    lambda: surface.read_library_bytes(companies, "ghost", "class-001", "skills/a.md", "ghost"),
)
bind("newco")
expect_surface(
    "unknown company write",
    lambda: surface.write_library_bytes(companies, "newco", "class-001", "skills/a.md", b"x", "newco"),
)
bind("indigo")
if (companies / "newco").exists():
    raise SystemExit("write created an unknown company tree")
if (ghost / "a.md").read_bytes() != b"ghost":
    raise SystemExit("unknown company file changed")

# Library paths are the five surface slots, same as a harness tree.
expect_surface(
    "library path outside surface",
    lambda: surface.read_library_bytes(companies, "indigo", "class-001", "anything.sh", "indigo"),
)
expect_surface(
    "library write outside surface",
    lambda: surface.write_library_bytes(companies, "indigo", "class-001", "secret.txt", b"nope", "indigo"),
)
if (companies / "indigo" / "eval-library" / "class-001" / "secret.txt").exists():
    raise SystemExit("library write created a path outside the surface")

def write_manifest(root, slugs):
    lines = ["companies:"]
    for slug in slugs:
        lines.append(f"  {slug}:")
        lines.append("    name: test")
    target = root / "manifest.yaml"
    target.write_text("\n".join(lines) + "\n")

# A symlinked companies directory must not be followed.
linked_hq = tmp / "hq-linked"
hq_companies("hq-linked")
real_companies = tmp / "real-companies"
(real_companies / "indigo" / "eval-library" / "class-001" / "skills").mkdir(parents=True)
(real_companies / "indigo" / "eval-library" / "class-001" / "skills" / "secret.md").write_bytes(b"THROUGH-ROOT")
write_manifest(real_companies, ["indigo"])
linked_companies = linked_hq / "companies"
os.symlink(real_companies, linked_companies, target_is_directory=True)
expect_surface(
    "symlinked companies root",
    lambda: surface.read_library_bytes(linked_companies, "indigo", "class-001", "skills/secret.md", "indigo"),
)
if (real_companies / "indigo" / "eval-library" / "class-001" / "skills" / "secret.md").read_bytes() != b"THROUGH-ROOT":
    raise SystemExit("symlinked companies root changed the target")

# A symlinked company folder must not reach the other company.
sym_companies = hq_companies("hq-sym")
(sym_companies / "otherco" / "eval-library" / "class-001" / "skills").mkdir(parents=True)
sym_secret = sym_companies / "otherco" / "eval-library" / "class-001" / "skills" / "secret.md"
sym_secret.write_bytes(b"OTHER")
os.symlink(sym_companies / "otherco", sym_companies / "indigo", target_is_directory=True)
write_manifest(sym_companies, ["indigo"])
expect_surface(
    "symlinked company folder read",
    lambda: surface.read_library_bytes(sym_companies, "indigo", "class-001", "skills/secret.md", "indigo"),
)
expect_surface(
    "symlinked company folder write",
    lambda: surface.write_library_bytes(sym_companies, "indigo", "class-001", "skills/secret.md", b"pwn", "indigo"),
)
if sym_secret.read_bytes() != b"OTHER":
    raise SystemExit("company symlink write changed the other company")

# A symlinked eval-library folder, class folder, or file below the class is refused.
lib_companies = hq_companies("hq-lib")
(lib_companies / "indigo").mkdir(parents=True)
outside_lib = tmp / "outside-lib" / "class-001" / "skills"
outside_lib.mkdir(parents=True)
(outside_lib / "secret.md").write_bytes(b"LIB")
os.symlink(tmp / "outside-lib", lib_companies / "indigo" / "eval-library", target_is_directory=True)
write_manifest(lib_companies, ["indigo"])
expect_surface(
    "symlinked eval-library read",
    lambda: surface.read_library_bytes(lib_companies, "indigo", "class-001", "skills/secret.md", "indigo"),
)
expect_surface(
    "symlinked eval-library write",
    lambda: surface.write_library_bytes(lib_companies, "indigo", "class-001", "skills/secret.md", b"pwn", "indigo"),
)
if (outside_lib / "secret.md").read_bytes() != b"LIB":
    raise SystemExit("eval-library symlink write changed the target")

class_companies = hq_companies("hq-class")
(class_companies / "indigo" / "eval-library").mkdir(parents=True)
outside_class = tmp / "outside-class" / "skills"
outside_class.mkdir(parents=True)
(outside_class / "secret.md").write_bytes(b"CLASS")
os.symlink(tmp / "outside-class", class_companies / "indigo" / "eval-library" / "class-001", target_is_directory=True)
write_manifest(class_companies, ["indigo"])
expect_surface(
    "symlinked class folder read",
    lambda: surface.read_library_bytes(class_companies, "indigo", "class-001", "skills/secret.md", "indigo"),
)
expect_surface(
    "symlinked class folder write",
    lambda: surface.write_library_bytes(class_companies, "indigo", "class-001", "skills/secret.md", b"pwn", "indigo"),
)
if (outside_class / "secret.md").read_bytes() != b"CLASS":
    raise SystemExit("class symlink write changed the target")

file_companies = hq_companies("hq-file")
file_skills = file_companies / "indigo" / "eval-library" / "class-001" / "skills"
file_skills.mkdir(parents=True)
file_target = tmp / "file-target.md"
file_target.write_bytes(b"FILE")
os.symlink(file_target, file_skills / "secret.md")
write_manifest(file_companies, ["indigo"])
expect_surface(
    "symlinked library file read",
    lambda: surface.read_library_bytes(file_companies, "indigo", "class-001", "skills/secret.md", "indigo"),
)
expect_surface(
    "symlinked library file write",
    lambda: surface.write_library_bytes(file_companies, "indigo", "class-001", "skills/secret.md", b"pwn", "indigo"),
)
if file_target.read_bytes() != b"FILE":
    raise SystemExit("library file symlink write changed the target")

# A known company with no directory is not created on write.
listed = hq_companies("hq-listed")
listed.mkdir()
write_manifest(listed, ["indigo"])
expect_surface(
    "missing company directory",
    lambda: surface.write_library_bytes(listed, "indigo", "class-001", "skills/a.md", b"x", "indigo"),
)
if (listed / "indigo").exists():
    raise SystemExit("write created a company directory")

# Company scope matches the ledger: the companies root must be the HQ root's
# own companies directory, and the company must be in the session lock.
scope = hq_companies("hq-scope")
for slug in ("indigo", "otherco"):
    (scope / slug / "eval-library" / "class-001" / "skills").mkdir(parents=True)
    (scope / slug / "eval-library" / "class-001" / "skills" / "a.md").write_bytes(slug.encode())
write_manifest(scope, ["indigo", "otherco"])
if surface.read_library_bytes(scope, "indigo", "class-001", "skills/a.md", "indigo") != b"indigo":
    raise SystemExit("bound company read failed")

def expect_scope(label, fn, reason):
    try:
        fn()
    except surface.SurfaceError as exc:
        if reason not in str(exc):
            raise SystemExit(f"{label}: refused for the wrong reason: {exc}")
    except Exception as exc:
        raise SystemExit(f"{label}: raised {type(exc).__name__}: {exc}") from exc
    else:
        raise SystemExit(f"{label}: accepted")

# Matching company and session_company strings do not bind a company that
# the session lock does not hold.
expect_scope(
    "company outside the session lock read",
    lambda: surface.read_library_bytes(scope, "otherco", "class-001", "skills/a.md", "otherco"),
    "session bind",
)
expect_scope(
    "company outside the session lock write",
    lambda: surface.write_library_bytes(scope, "otherco", "class-001", "skills/a.md", b"pwn", "otherco"),
    "session bind",
)
expect_scope(
    "company outside the session lock root",
    lambda: surface.library_root(scope, "otherco", "class-001", "otherco"),
    "session bind",
)
if (scope / "otherco" / "eval-library" / "class-001" / "skills" / "a.md").read_bytes() != b"otherco":
    raise SystemExit("write outside the session lock changed the other company")
bind("otherco")
if surface.read_library_bytes(scope, "otherco", "class-001", "skills/a.md", "otherco") != b"otherco":
    raise SystemExit("read under the other company's own lock failed")
expect_scope(
    "indigo after the lock moves to otherco",
    lambda: surface.read_library_bytes(scope, "indigo", "class-001", "skills/a.md", "indigo"),
    "session bind",
)
bind()
expect_scope(
    "no session lock",
    lambda: surface.read_library_bytes(scope, "indigo", "class-001", "skills/a.md", "indigo"),
    "no company lock",
)
expect_scope(
    "no session lock write",
    lambda: surface.write_library_bytes(scope, "indigo", "class-001", "skills/new.md", b"x", "indigo"),
    "no company lock",
)
if (scope / "indigo" / "eval-library" / "class-001" / "skills" / "new.md").exists():
    raise SystemExit("write without a session lock created a file")
bind("indigo")

# A second companies tree with its own manifest is refused, inside or outside
# the HQ root.
for stray_label, stray in (
    ("companies root outside HQ_ROOT", tmp / "stray" / "companies"),
    ("nested companies root inside HQ_ROOT", tmp / "hq-scope" / "nested" / "companies"),
):
    (stray / "indigo" / "eval-library" / "class-001" / "skills").mkdir(parents=True)
    (stray / "indigo" / "eval-library" / "class-001" / "skills" / "a.md").write_bytes(b"STRAY")
    write_manifest(stray, ["indigo"])
    expect_scope(
        f"{stray_label} read",
        lambda stray=stray: surface.read_library_bytes(stray, "indigo", "class-001", "skills/a.md", "indigo"),
        "HQ root companies",
    )
    expect_scope(
        f"{stray_label} write",
        lambda stray=stray: surface.write_library_bytes(stray, "indigo", "class-001", "skills/b.md", b"x", "indigo"),
        "HQ root companies",
    )
    expect_scope(
        f"{stray_label} root",
        lambda stray=stray: surface.library_root(stray, "indigo", "class-001", "indigo"),
        "HQ root companies",
    )
    if (stray / "indigo" / "eval-library" / "class-001" / "skills" / "b.md").exists():
        raise SystemExit(f"{stray_label}: write created a file")

# A library file hardlinked to another company's file is refused on write
# and on read. The other company's bytes do not change.
other_file = scope / "otherco" / "eval-library" / "class-001" / "skills" / "a.md"
hard = scope / "indigo" / "eval-library" / "class-001" / "skills" / "h.md"
os.link(other_file, hard)
expect_scope(
    "hardlinked library write",
    lambda: surface.write_library_bytes(scope, "indigo", "class-001", "skills/h.md", b"PWNED", "indigo"),
    "hardlink",
)
expect_scope(
    "hardlinked library read",
    lambda: surface.read_library_bytes(scope, "indigo", "class-001", "skills/h.md", "indigo"),
    "hardlink",
)
if other_file.read_bytes() != b"otherco":
    raise SystemExit("hardlinked write changed the other company file")
os.unlink(hard)

# A normal overwrite replaces the file in place and leaves no temp file.
lib_skills = scope / "indigo" / "eval-library" / "class-001" / "skills"
surface.write_library_bytes(scope, "indigo", "class-001", "skills/a.md", b"v2", "indigo")
if (lib_skills / "a.md").read_bytes() != b"v2":
    raise SystemExit("overwrite did not take the new bytes")
if sorted(p.name for p in lib_skills.iterdir()) != ["a.md"]:
    raise SystemExit(f"overwrite left extra files: {sorted(p.name for p in lib_skills.iterdir())}")

# A hardlinked incumbent file or output file is refused, and dest is unchanged.
hl_target = tmp / "hl-target.md"
hl_target.write_bytes(b"HL")
hl_inc = tmp / "hl-inc"
(hl_inc / "skills").mkdir(parents=True)
os.link(hl_target, hl_inc / "skills" / "h.md")
hl_dest = tmp / "hl-dest"
expect_scope("hardlinked incumbent file", lambda: surface.apply_to_directory(hl_inc, {}, hl_dest), "hardlink")
if hl_dest.exists():
    raise SystemExit("dest created despite a hardlinked incumbent file")
out_dest = tmp / "hl-out-dest"
(out_dest / "skills").mkdir(parents=True)
os.link(hl_target, out_dest / "skills" / "h.md")
expect_scope(
    "hardlinked output file",
    lambda: surface.apply_to_directory(tmp / "no-incumbent", {"skills/h.md": b"PWNED", "policies/p.md": b"p"}, out_dest),
    "hardlink",
)
if hl_target.read_bytes() != b"HL":
    raise SystemExit("hardlinked output write changed the target")
if (out_dest / "policies").exists():
    raise SystemExit("apply_to_directory wrote before the hardlink refusal")

# A file key that is also a folder of another key is refused before any
# write, for an existing dest and a missing dest.
def tree_snapshot(root):
    return sorted(
        (str(p.relative_to(root)), p.read_bytes() if p.is_file() else None)
        for p in root.rglob("*")
    )

prefix_dest = tmp / "prefix-dest"
(prefix_dest / "skills").mkdir(parents=True)
(prefix_dest / "skills" / "old.md").write_bytes(b"OLD")
before = tree_snapshot(prefix_dest)
expect_scope(
    "file and folder collide, existing dest",
    lambda: surface.apply_to_directory(tmp / "no-incumbent", {"skills/a": b"1", "skills/a/b": b"2"}, prefix_dest),
    "collide",
)
if tree_snapshot(prefix_dest) != before:
    raise SystemExit(f"prefix collision changed dest: {tree_snapshot(prefix_dest)}")
prefix_missing = tmp / "prefix-missing"
expect_scope(
    "file and folder collide, missing dest",
    lambda: surface.apply_to_directory(tmp / "no-incumbent", {"skills/a/b": b"2", "skills/a": b"1"}, prefix_missing),
    "collide",
)
if prefix_missing.exists():
    raise SystemExit("prefix collision created dest")
prefix_inc = tmp / "prefix-inc"
(prefix_inc / "skills").mkdir(parents=True)
(prefix_inc / "skills" / "a").write_bytes(b"1")
expect_scope(
    "incumbent file and patch folder collide",
    lambda: surface.apply_to_directory(prefix_inc, {"skills/a/b": b"2"}, prefix_dest),
    "collide",
)
if tree_snapshot(prefix_dest) != before:
    raise SystemExit("incumbent prefix collision changed dest")
expect_scope("apply_tree prefix collision", lambda: surface.apply_tree({"skills/a": b"1"}, {"skills/a/b": b"2"}), "collide")

# Keys that differ only by case are refused, for files and for folders.
for case_label, case_patch in (
    ("file case collision", {"skills/A.md": b"1", "skills/a.md": b"2"}),
    ("folder case collision", {"skills/X/a.md": b"1", "skills/x/b.md": b"2"}),
):
    expect_scope(
        case_label,
        lambda case_patch=case_patch: surface.apply_to_directory(tmp / "no-incumbent", case_patch, prefix_dest),
        "case collision",
    )
    expect_scope(f"apply_tree {case_label}", lambda case_patch=case_patch: surface.apply_tree({}, case_patch), "case collision")
if tree_snapshot(prefix_dest) != before:
    raise SystemExit("case collision changed dest")

# Composed and decomposed spellings of one name are the same file on APFS.
nfc_nfd = {"skills/\u00e9.md": b"1", "skills/e\u0301.md": b"2"}
expect_scope("NFC/NFD collision", lambda: surface.apply_to_directory(tmp / "no-incumbent", nfc_nfd, prefix_dest), "case collision")
expect_scope("apply_tree NFC/NFD collision", lambda: surface.apply_tree({}, nfc_nfd), "case collision")
if tree_snapshot(prefix_dest) != before:
    raise SystemExit("NFC/NFD collision changed dest")

# Bad input types and a very deep incumbent stay SurfaceError, with dest unchanged.
expect_surface("patch is not a mapping", lambda: surface.apply_to_directory(tmp / "no-incumbent", [("skills/a.md", b"x")], prefix_dest))
expect_surface("dest is None", lambda: surface.apply_to_directory(tmp / "no-incumbent", {"skills/a.md": b"x"}, None))
deep_inc = tmp / "deep-inc"
deep = deep_inc / "skills"
for _ in range(40):
    deep = deep / "d"
deep.mkdir(parents=True)
(deep / "a.md").write_bytes(b"deep")
expect_scope("deep incumbent", lambda: surface.apply_to_directory(deep_inc, {}, prefix_dest), "too deep")
if tree_snapshot(prefix_dest) != before:
    raise SystemExit("bad input changed dest")

# A missing dest is not created through a symlinked parent or a missing parent.
real_parent = tmp / "real-parent"
real_parent.mkdir()
link_parent = tmp / "link-parent"
os.symlink(real_parent, link_parent, target_is_directory=True)
expect_scope(
    "dest under a symlinked parent",
    lambda: surface.apply_to_directory(tmp / "no-incumbent", {"skills/a.md": b"x"}, link_parent / "new-dest"),
    "symlink",
)
if any(real_parent.iterdir()):
    raise SystemExit("dest was created through a symlinked parent")
expect_scope(
    "dest with a missing parent",
    lambda: surface.apply_to_directory(tmp / "no-incumbent", {"skills/a.md": b"x"}, tmp / "no-parent" / "dest"),
    "missing",
)
if (tmp / "no-parent").exists():
    raise SystemExit("dest parent was created")

# Incumbent symlinks are not followed, and a failed apply does not create dest.
leak_target = tmp / "inc-leak.txt"
leak_target.write_bytes(b"FILELEAK")
file_inc = tmp / "file-inc"
(file_inc / "skills").mkdir(parents=True)
os.symlink(leak_target, file_inc / "skills" / "leak.md")
file_dest = tmp / "file-dest"
expect_surface(
    "symlinked incumbent file",
    lambda: surface.apply_to_directory(file_inc, {"policies/p.md": b"p"}, file_dest),
)
if file_dest.exists():
    raise SystemExit("dest created despite an incumbent file symlink")
if leak_target.read_bytes() != b"FILELEAK":
    raise SystemExit("incumbent file symlink target changed")

outside_slot = tmp / "outside-slot"
outside_slot.mkdir()
(outside_slot / "secret.md").write_bytes(b"SLOTLEAK")
slot_inc = tmp / "slot-inc"
(slot_inc / "skills").mkdir(parents=True)
(slot_inc / "skills" / "ok.md").write_bytes(b"ok")
os.symlink(outside_slot, slot_inc / "policies", target_is_directory=True)
slot_dest = tmp / "slot-dest"
expect_surface(
    "symlinked incumbent slot",
    lambda: surface.apply_to_directory(slot_inc, {}, slot_dest),
)
if slot_dest.exists():
    raise SystemExit("dest created despite an incumbent slot symlink")
if (outside_slot / "secret.md").read_bytes() != b"SLOTLEAK":
    raise SystemExit("incumbent slot symlink target changed")

nested_inc = tmp / "nested-inc"
(nested_inc / "skills").mkdir(parents=True)
os.symlink(outside_slot, nested_inc / "skills" / "sub", target_is_directory=True)
nested_dest = tmp / "nested-dest"
expect_surface(
    "symlinked incumbent subdirectory",
    lambda: surface.apply_to_directory(nested_inc, {}, nested_dest),
)
if nested_dest.exists():
    raise SystemExit("dest created despite an incumbent subdirectory symlink")

# An unreadable incumbent subdirectory is an error, not a silent skip.
locked_inc = tmp / "locked-inc"
(locked_inc / "skills" / "locked").mkdir(parents=True)
(locked_inc / "skills" / "locked" / "a.md").write_bytes(b"a")
os.chmod(locked_inc / "skills" / "locked", 0)
locked_dest = tmp / "locked-dest"
try:
    if os.geteuid() != 0:
        expect_surface(
            "unreadable incumbent subdirectory",
            lambda: surface.apply_to_directory(locked_inc, {}, locked_dest),
        )
        if locked_dest.exists():
            raise SystemExit("dest created despite an unreadable incumbent subdirectory")
finally:
    os.chmod(locked_inc / "skills" / "locked", 0o755)

# An invalid patch does not create dest either.
missing_dest = tmp / "missing-dest"
expect_surface(
    "invalid patch creates dest",
    lambda: surface.apply_to_directory(inc_dir, {"../x": b"nope"}, missing_dest),
)
if missing_dest.exists():
    raise SystemExit("dest created on an invalid patch")

print("eval-loop-surface: ok")
PY
