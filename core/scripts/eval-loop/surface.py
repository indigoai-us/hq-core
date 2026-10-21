#!/usr/bin/env python3
# hq-core: public
"""Closed harness surface and the per-company eval library root.

A harness edit may name only these relative slots:

  skills/, policies/, worker-prompts/, tool-guidance/, subagents/

Absolute paths and any ``..`` segment are rejected before a path is joined
onto a directory. Omitted files keep the incumbent bytes. A round-trip of an
unchanged tree is byte-identical. Two paths that normalize to the same key
are refused. NUL bytes and non-UTF-8 keys raise SurfaceError.

The library root is ``companies/{company}/eval-library/{classId}/``. Every
read and write runs ``company_scope``: the company slug must be ASCII and
equal ``session_company``, the companies root must be exactly the HQ root's
``companies`` directory, and the company must be in the ``hq-session.sh``
session lock and in the manifest. A failed check raises before that company
directory is joined, opened, or created. A write never creates a company
directory.

Every component from the companies directory through the company folder,
``eval-library``, the class id, and each segment below is refused when it is
a symlink or when its real path sits outside that company. Opens use
``O_NOFOLLOW``. A file with more than one hard link is refused. Writes go to a
temp file in the target folder and are renamed into place.

This module does not start lanes, call a model, or edit conduct.
"""

from __future__ import annotations

import errno
import os
import re
import secrets
import stat
import struct
import subprocess
import sys
import unicodedata
from pathlib import Path
from typing import Mapping

# The only editable slots. A path outside this tuple is rejected.
SURFACE_SLOTS = (
    "skills/",
    "policies/",
    "worker-prompts/",
    "tool-guidance/",
    "subagents/",
)

# Deepest folder nesting the incumbent walk accepts below a slot.
_MAX_DEPTH = 32

# ASCII, 1..64 chars, hyphens only in the middle. ``..`` and Unicode fail.
_SLUG = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$")


class SurfaceError(Exception):
    """A path or company bind was refused. Callers must treat this as a no-write."""


class _Dir:
    """An owned directory fd opened with O_NOFOLLOW."""

    __slots__ = ("fd",)

    def __init__(self, fd: int) -> None:
        self.fd = fd

    def close(self) -> None:
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1


def _nofollow() -> int:
    flag = getattr(os, "O_NOFOLLOW", None)
    if flag is None:
        raise SurfaceError("symlink")
    return flag


def _os_error(exc: OSError) -> SurfaceError:
    # ELOOP is what O_NOFOLLOW returns for a final-component symlink.
    if exc.errno in (errno.ELOOP, errno.EPERM):
        return SurfaceError("symlink")
    if exc.errno == errno.ENOENT:
        return SurfaceError("missing path")
    return SurfaceError("unavailable path")


def _component(name: str) -> None:
    if (
        not isinstance(name, str)
        or name in ("", ".", "..")
        or "/" in name
        or "\\" in name
        or "\x00" in name
    ):
        raise SurfaceError("parent segment")


def _raw_segments(path: str) -> list[str]:
    """Split a path without collapsing ``..`` and without joining it to a root."""
    if not isinstance(path, str) or path == "":
        raise SurfaceError("empty path")
    if "\x00" in path:
        raise SurfaceError("NUL byte")
    if path.startswith("/") or path.startswith("\\"):
        raise SurfaceError("absolute path")
    if path.startswith("//") or path.startswith("\\\\"):
        raise SurfaceError("absolute path")
    if len(path) >= 2 and path[1] == ":":
        raise SurfaceError("absolute path")
    # isabs does not join the path onto a directory.
    try:
        absolute = os.path.isabs(path)
    except ValueError as exc:
        raise SurfaceError("NUL byte") from exc
    if absolute:
        raise SurfaceError("absolute path")
    parts = path.replace("\\", "/").split("/")
    if any(part == ".." for part in parts):
        raise SurfaceError("parent segment")
    return parts


def normalize_surface_path(path: str) -> str:
    """Return the canonical relative surface path, or raise SurfaceError.

    The check runs before any join onto a directory. ``..`` is never folded
    away: a segment equal to ``..`` is an error even when the lexical result
    would still sit inside a slot.
    """
    parts = [part for part in _raw_segments(path) if part not in ("", ".")]
    if not parts:
        raise SurfaceError("empty path")
    rel = "/".join(parts)
    if not any(rel.startswith(slot) and len(rel) > len(slot) for slot in SURFACE_SLOTS):
        raise SurfaceError("path outside surface")
    return rel


def _as_bytes(value: object, label: str) -> bytes:
    if isinstance(value, (bytes, bytearray)):
        return bytes(value)
    raise SurfaceError(f"{label} value must be bytes")


def _put_new(out: dict[str, bytes], key: str, data: bytes) -> None:
    if key in out:
        raise SurfaceError("duplicate path")
    out[key] = data


def _fold(name: str) -> str:
    return unicodedata.normalize("NFC", unicodedata.normalize("NFC", name).casefold())


def _check_layout(keys) -> None:
    """Refuse a tree that cannot be written as plain files.

    A key that is a folder of another key (``skills/a`` and ``skills/a/b``)
    is refused. Two keys, or two folders, that differ only by case are
    refused, because a case-insensitive filesystem would merge them. Keys
    are compared in Unicode NFC as well, because APFS treats composed and
    decomposed spellings of one name as the same file.
    """
    seen: dict[str, str] = {}
    folders: dict[str, str] = {}
    for key in keys:
        folded = _fold(key)
        if seen.setdefault(folded, key) != key:
            raise SurfaceError("case collision")
        parts = key.split("/")
        for index in range(1, len(parts)):
            prefix = "/".join(parts[:index])
            if folders.setdefault(_fold(prefix), prefix) != prefix:
                raise SurfaceError("case collision")
    for folded in seen:
        if folded in folders:
            raise SurfaceError("file and folder collide")


def apply_tree(incumbent: Mapping[str, bytes], patch: Mapping[str, bytes]) -> dict[str, bytes]:
    """Copy ``incumbent`` and overlay ``patch``.

    Every patch path is validated before any incumbent byte is copied into
    the result and before ``incumbent`` could be mutated. An invalid patch
    raises SurfaceError and leaves ``incumbent`` unchanged. Two keys in one
    mapping that normalize to the same path are an error. A patch key that
    normalizes onto an incumbent key replaces that value. Keys absent from
    ``patch`` keep the incumbent bytes.
    """
    validated: dict[str, bytes] = {}
    for raw, data in patch.items():
        _put_new(validated, normalize_surface_path(str(raw)), _as_bytes(data, "patch"))

    out: dict[str, bytes] = {}
    for raw, data in incumbent.items():
        _put_new(out, normalize_surface_path(str(raw)), _as_bytes(data, "incumbent"))
    out.update(validated)
    _check_layout(out)
    return out


def serialize_tree(tree: Mapping[str, bytes]) -> bytes:
    """Encode a surface tree. Paths are sorted so the bytes are stable."""
    normalized = apply_tree(tree, {})
    chunks: list[bytes] = []
    for key in sorted(normalized):
        key_b = key.encode("utf-8")
        data = normalized[key]
        chunks.append(struct.pack(">I", len(key_b)))
        chunks.append(key_b)
        chunks.append(struct.pack(">I", len(data)))
        chunks.append(data)
    return b"".join(chunks)


def deserialize_tree(blob: bytes) -> dict[str, bytes]:
    """Decode a tree produced by ``serialize_tree``. Stored keys are re-checked."""
    if not isinstance(blob, (bytes, bytearray)):
        raise SurfaceError("tree blob must be bytes")
    raw = bytes(blob)
    out: dict[str, bytes] = {}
    index = 0
    size = len(raw)
    while index < size:
        if index + 4 > size:
            raise SurfaceError("truncated tree")
        (key_len,) = struct.unpack(">I", raw[index : index + 4])
        index += 4
        if index + key_len > size:
            raise SurfaceError("truncated tree")
        try:
            key = raw[index : index + key_len].decode("utf-8")
        except UnicodeDecodeError as exc:
            raise SurfaceError("bad utf-8") from exc
        index += key_len
        if index + 4 > size:
            raise SurfaceError("truncated tree")
        (data_len,) = struct.unpack(">I", raw[index : index + 4])
        index += 4
        if index + data_len > size:
            raise SurfaceError("truncated tree")
        data = raw[index : index + data_len]
        index += data_len
        _put_new(out, normalize_surface_path(key), data)
    _check_layout(out)
    return out


def round_trip(tree: Mapping[str, bytes]) -> dict[str, bytes]:
    """Serialize and parse ``tree``. An unchanged tree comes back byte-identical."""
    return deserialize_tree(serialize_tree(tree))


def _check_leaf(st: os.stat_result) -> None:
    """A library or tree file must be one regular file with one name."""
    if stat.S_ISLNK(st.st_mode):
        raise SurfaceError("symlink")
    if not stat.S_ISREG(st.st_mode):
        raise SurfaceError("unavailable path")
    # A second name could be a hardlink into another company's tree.
    if st.st_nlink > 1:
        raise SurfaceError("hardlink")


def _stat_at(parent_fd: int, name: str) -> os.stat_result | None:
    _component(name)
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    except ValueError as exc:
        raise SurfaceError("NUL byte") from exc
    except OSError as exc:
        raise _os_error(exc) from exc


def _read_fd(fd: int) -> bytes:
    try:
        try:
            _check_leaf(os.fstat(fd))
        except OSError as exc:
            raise _os_error(exc) from exc
        chunks: list[bytes] = []
        while True:
            try:
                block = os.read(fd, 1024 * 1024)
            except OSError as exc:
                raise _os_error(exc) from exc
            if not block:
                break
            chunks.append(block)
        return b"".join(chunks)
    finally:
        os.close(fd)


def _read_at(parent_fd: int, name: str) -> bytes:
    _component(name)
    # O_NONBLOCK keeps a FIFO from hanging the open; fstat then refuses it.
    flags = os.O_RDONLY | os.O_NONBLOCK | _nofollow()
    try:
        fd = os.open(name, flags, dir_fd=parent_fd)
    except ValueError as exc:
        raise SurfaceError("NUL byte") from exc
    except OSError as exc:
        raise _os_error(exc) from exc
    return _read_fd(fd)


def _replace_at(parent_fd: int, name: str, data: bytes) -> None:
    """Write ``name`` under ``parent_fd`` through a temp file and a rename.

    An existing symlink, non-regular file, or file with more than one link is
    refused. The rename swaps the directory entry, so bytes are never written
    into an inode that another name shares, and a reader never sees a
    partial file.
    """
    existing = _stat_at(parent_fd, name)
    if existing is not None:
        _check_leaf(existing)
    temp = f".{name}.{secrets.token_hex(8)}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | _nofollow()
    try:
        fd = os.open(temp, flags, 0o644, dir_fd=parent_fd)
    except OSError as exc:
        raise _os_error(exc) from exc
    try:
        try:
            view = memoryview(data)
            while len(view):
                wrote = os.write(fd, view)
                if wrote <= 0:
                    raise SurfaceError("unavailable path")
                view = view[wrote:]
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(temp, name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
    except BaseException as exc:
        try:
            os.unlink(temp, dir_fd=parent_fd)
        except OSError:
            pass
        if isinstance(exc, OSError):
            raise _os_error(exc) from exc
        raise


def _open_dir(path: Path) -> _Dir:
    flags = os.O_RDONLY | os.O_DIRECTORY | _nofollow()
    try:
        fd = os.open(os.fspath(path), flags)
    except ValueError as exc:
        raise SurfaceError("NUL byte") from exc
    except OSError as exc:
        raise _os_error(exc) from exc
    return _Dir(fd)


def _open_dir_at(parent: _Dir, name: str) -> _Dir:
    _component(name)
    flags = os.O_RDONLY | os.O_DIRECTORY | _nofollow()
    try:
        fd = os.open(name, flags, dir_fd=parent.fd)
    except ValueError as exc:
        raise SurfaceError("NUL byte") from exc
    except OSError as exc:
        raise _os_error(exc) from exc
    return _Dir(fd)


def _close_all(opened: list[_Dir]) -> None:
    for item in reversed(opened):
        item.close()


def _assert_inside(lexical: Path, parent_real: Path, name: str) -> Path:
    """Refuse when the real path of an already-opened non-symlink leaves parent_real."""
    try:
        got = Path(os.path.realpath(lexical))
    except ValueError as exc:
        raise SurfaceError("NUL byte") from exc
    expect = parent_real / name
    if got != expect:
        raise SurfaceError("path escapes company root")
    return got


def _lstat_or_none(path: Path):
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None
    except ValueError as exc:
        raise SurfaceError("NUL byte") from exc
    except OSError as exc:
        raise _os_error(exc) from exc


def _walk_fd(folder: _Dir, prefix: str, found: dict[str, bytes], depth: int = 0) -> None:
    """Read every file below an opened folder. Every open is fd-relative."""
    if depth > _MAX_DEPTH:
        raise SurfaceError("tree too deep")
    try:
        names = sorted(os.listdir(folder.fd))
    except OSError as exc:
        raise _os_error(exc) from exc
    for name in names:
        st = _stat_at(folder.fd, name)
        if st is None:
            raise SurfaceError("missing path")
        rel = f"{prefix}/{name}"
        if stat.S_ISLNK(st.st_mode):
            raise SurfaceError("symlink")
        if stat.S_ISDIR(st.st_mode):
            child = _open_dir_at(folder, name)
            try:
                _walk_fd(child, rel, found, depth + 1)
            finally:
                child.close()
            continue
        _check_leaf(st)
        _put_new(found, normalize_surface_path(rel), _read_at(folder.fd, name))


def _read_surface_dir(incumbent_dir: Path) -> dict[str, bytes]:
    """Read slot files. A symlink, hardlink, or special file is refused.

    The walk opens each folder with O_NOFOLLOW relative to its parent fd, so
    a folder swapped for a symlink after the check is not followed.
    """
    found: dict[str, bytes] = {}
    incumbent_dir = Path(incumbent_dir)
    root_stat = _lstat_or_none(incumbent_dir)
    if root_stat is None:
        return found
    if stat.S_ISLNK(root_stat.st_mode):
        raise SurfaceError("symlink")
    if not stat.S_ISDIR(root_stat.st_mode):
        raise SurfaceError("unavailable path")
    base = _open_dir(incumbent_dir)
    try:
        for slot in SURFACE_SLOTS:
            slot_name = slot.rstrip("/")
            slot_stat = _stat_at(base.fd, slot_name)
            if slot_stat is None:
                continue
            if stat.S_ISLNK(slot_stat.st_mode):
                raise SurfaceError("symlink")
            if not stat.S_ISDIR(slot_stat.st_mode):
                raise SurfaceError("unavailable path")
            child = _open_dir_at(base, slot_name)
            try:
                _walk_fd(child, slot_name, found)
            finally:
                child.close()
    finally:
        base.close()
    return found


def _check_target_at(root: _Dir, rel: str) -> None:
    """Refuse a symlink, a non-folder, or a linked file on an existing output path."""
    parts = rel.split("/")
    opened: list[_Dir] = []
    current = root
    try:
        for part in parts[:-1]:
            st = _stat_at(current.fd, part)
            if st is None:
                return
            if stat.S_ISLNK(st.st_mode):
                raise SurfaceError("symlink")
            if not stat.S_ISDIR(st.st_mode):
                raise SurfaceError("unavailable path")
            current = _open_dir_at(current, part)
            opened.append(current)
        st = _stat_at(current.fd, parts[-1])
        if st is not None:
            _check_leaf(st)
    finally:
        _close_all(opened)


def _write_tree_at(root: _Dir, rel: str, data: bytes) -> None:
    parts = rel.split("/")
    opened: list[_Dir] = []
    current = root
    try:
        for part in parts[:-1]:
            _mkdir_at(current, part)
            current = _open_dir_at(current, part)
            opened.append(current)
        _replace_at(current.fd, parts[-1], data)
    finally:
        _close_all(opened)


def _open_dest(dest: Path) -> _Dir:
    """Open ``dest``, creating it only inside an existing, non-symlink parent.

    Missing parent folders are not created, so a missing dest is never
    created through a symlinked parent.
    """
    dest_stat = _lstat_or_none(dest)
    if dest_stat is not None:
        if stat.S_ISLNK(dest_stat.st_mode):
            raise SurfaceError("symlink")
        if not stat.S_ISDIR(dest_stat.st_mode):
            raise SurfaceError("unavailable path")
        return _open_dir(dest)
    absolute = Path(os.path.abspath(dest))
    parent_stat = _lstat_or_none(absolute.parent)
    if parent_stat is None:
        raise SurfaceError("missing path")
    if stat.S_ISLNK(parent_stat.st_mode):
        raise SurfaceError("symlink")
    if not stat.S_ISDIR(parent_stat.st_mode):
        raise SurfaceError("unavailable path")
    parent = _open_dir(absolute.parent)
    try:
        _component(absolute.name)
        try:
            os.mkdir(absolute.name, 0o755, dir_fd=parent.fd)
        except OSError as exc:
            raise _os_error(exc) from exc
        return _open_dir_at(parent, absolute.name)
    finally:
        parent.close()


def apply_to_directory(incumbent_dir: Path, patch: Mapping[str, bytes], dest: Path) -> None:
    """Write the merged tree under ``dest``.

    Patch paths, the merged layout, the incumbent tree, and every existing
    output path are checked before ``dest`` is created and before any file is
    written. On SurfaceError from those checks, ``dest`` and ``incumbent_dir``
    are unchanged. Every error this function raises is a SurfaceError. A
    failure during the writes themselves, such as a full disk, can leave the
    files written so far.
    """
    try:
        _apply_to_directory(incumbent_dir, patch, dest)
    except SurfaceError:
        raise
    except OSError as exc:
        raise _os_error(exc) from exc
    except (AttributeError, TypeError, ValueError, RecursionError) as exc:
        raise SurfaceError("invalid input") from exc


def _apply_to_directory(incumbent_dir: Path, patch: Mapping[str, bytes], dest: Path) -> None:
    validated: dict[str, bytes] = {}
    for raw, data in patch.items():
        _put_new(validated, normalize_surface_path(str(raw)), _as_bytes(data, "patch"))
    incumbent = _read_surface_dir(Path(incumbent_dir))
    merged = dict(incumbent)
    merged.update(validated)
    _check_layout(merged)

    dest = Path(dest)
    dest_stat = _lstat_or_none(dest)
    if dest_stat is not None:
        if stat.S_ISLNK(dest_stat.st_mode):
            raise SurfaceError("symlink")
        if not stat.S_ISDIR(dest_stat.st_mode):
            raise SurfaceError("unavailable path")
        # Every output path is checked before the first write, so a symlink
        # later in the tree cannot leave an earlier file behind.
        probe = _open_dir(dest)
        try:
            for rel in merged:
                _check_target_at(probe, rel)
        finally:
            probe.close()

    root = _open_dest(dest)
    try:
        for rel in sorted(merged):
            _write_tree_at(root, rel, merged[rel])
    finally:
        root.close()


def _slug(value: object, label: str) -> str:
    if not isinstance(value, str) or "\x00" in value or _SLUG.fullmatch(value) is None:
        raise SurfaceError(f"invalid {label}")
    return value


def _session_slugs(company: str, class_id: str, session_company: str) -> tuple[str, str]:
    session = _slug(session_company, "session company")
    bound = _slug(company, "company")
    if bound != session:
        raise SurfaceError("company slug does not match session bind")
    return bound, _slug(class_id, "class id")


def _resolve_hq_root() -> Path:
    """HQ root the way ``hq-session.sh`` resolves it.

    ``HQ_ROOT``, else ``CLAUDE_PROJECT_DIR``, else this module's checkout.
    Never the parent of a caller-chosen companies root.
    """
    chosen = os.environ.get("HQ_ROOT", "").strip()
    if not chosen:
        chosen = os.environ.get("CLAUDE_PROJECT_DIR", "").strip()
    if chosen:
        return Path(os.path.realpath(chosen))
    # core/scripts/eval-loop/surface.py -> checkout root is parents[3].
    return Path(os.path.realpath(__file__)).parents[3]


def _session_lock(hq_root: Path) -> set[str]:
    """Companies in the HQ session lock from ``hq-session.sh get company_slugs``."""
    script = Path(os.path.realpath(__file__)).parent.parent / "hq-session.sh"
    if not script.is_file():
        raise SurfaceError("session has no company lock")
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
        raise SurfaceError("session has no company lock") from exc
    if proc.returncode != 0:
        raise SurfaceError("session has no company lock")
    slugs = {part.strip() for part in proc.stdout.strip().split(",") if part.strip()}
    if not slugs:
        raise SurfaceError("session has no company lock")
    return slugs


def company_scope(companies_root: os.PathLike[str] | str, company: str, session_company: str) -> str:
    """The shared company checks for any eval-loop library access.

    ``company`` must be an ASCII slug equal to ``session_company``. The
    companies root must resolve to exactly the HQ root's ``companies``
    directory, so a second tree with its own manifest is refused. The company
    must be in the HQ session lock read by ``hq-session.sh``; a matching
    ``session_company`` string alone does not bind it. The manifest and the
    symlink walk are checked afterwards when the library is opened.
    Returns the bound slug.
    """
    session = _slug(session_company, "session company")
    bound = _slug(company, "company")
    if bound != session:
        raise SurfaceError("company slug does not match session bind")
    hq_root = _resolve_hq_root()
    try:
        got = os.path.realpath(os.fspath(companies_root))
    except (TypeError, ValueError) as exc:
        raise SurfaceError("invalid companies root") from exc
    if got != os.path.realpath(hq_root / "companies"):
        raise SurfaceError("companies root is not the HQ root companies directory")
    if bound not in _session_lock(hq_root):
        raise SurfaceError("company slug does not match session bind")
    return bound


def _manifest_slugs(text: str) -> set[str]:
    """Return the company keys under the top-level ``companies:`` mapping."""
    slugs: set[str] = set()
    in_companies = False
    companies_indent = 0
    child_indent: int | None = None
    for raw_line in text.splitlines():
        line = raw_line.rstrip("\r")
        if "\t" in line:
            raise SurfaceError("invalid manifest")
        stripped = line.strip()
        if stripped == "" or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if not in_companies:
            if indent == 0 and stripped == "companies:":
                in_companies = True
                companies_indent = indent
            continue
        if indent <= companies_indent:
            break
        if child_indent is None:
            child_indent = indent
        if indent != child_indent:
            continue
        if not stripped.endswith(":"):
            raise SurfaceError("invalid manifest")
        key = stripped[:-1].strip()
        if key == "" or key.startswith(("'", '"')):
            raise SurfaceError("invalid manifest")
        slugs.add(key)
    if not in_companies:
        raise SurfaceError("unknown company")
    return slugs


def _mkdir_at(parent: _Dir, name: str) -> None:
    _component(name)
    try:
        os.mkdir(name, 0o755, dir_fd=parent.fd)
    except FileExistsError:
        return
    except OSError as exc:
        raise _os_error(exc) from exc


def _descend(parent: _Dir, name: str, lexical_parent: Path, parent_real: Path, *, create: bool) -> tuple[_Dir, Path, Path]:
    """Open one real child directory. Never follows a symlink. Never creates a company."""
    lexical = lexical_parent / name
    if create:
        _mkdir_at(parent, name)
    child = _open_dir_at(parent, name)
    try:
        child_real = _assert_inside(lexical, parent_real, name)
    except SurfaceError:
        child.close()
        raise
    return child, lexical, child_real


def _open_library(
    companies_root: os.PathLike[str] | str,
    company: str,
    class_id: str,
    session_company: str,
    rel_parts: list[str],
    *,
    create: bool,
) -> tuple[list[_Dir], _Dir, str | None, Path]:
    """Open the companies root and walk to the class dir, or to the file parent.

    ``rel_parts`` empty means stop on the class directory (library_root).
    Otherwise the last element is the leaf file name and the return parent is
    the directory that contains it. The company directory itself is never
    created. Returns ``(opened, parent, leaf_or_none, lexical_file_or_class)``.
    """
    bound, class_slug = _session_slugs(company, class_id, session_company)
    company_scope(companies_root, bound, session_company)
    root = Path(companies_root)
    opened: list[_Dir] = []
    try:
        root_dir = _open_dir(root)
        opened.append(root_dir)
        try:
            manifest_text = _read_at(root_dir.fd, "manifest.yaml").decode("utf-8")
        except UnicodeDecodeError as exc:
            raise SurfaceError("bad utf-8") from exc
        if bound not in _manifest_slugs(manifest_text):
            raise SurfaceError("unknown company")
        # Refuse a missing or symlinked company before creating anything below it.
        company_dir, company_lexical, company_real = _descend(
            root_dir, bound, root, Path(os.path.realpath(root)), create=False
        )
        opened.append(company_dir)
        parent = company_dir
        lexical = company_lexical
        parent_real = company_real
        dir_parts = ["eval-library", class_slug]
        leaf: str | None = None
        if rel_parts:
            leaf = rel_parts[-1]
            dir_parts.extend(rel_parts[:-1])
        for name in dir_parts:
            child, lexical, parent_real = _descend(
                parent, name, lexical, parent_real, create=create
            )
            opened.append(child)
            parent = child
        if leaf is None:
            return opened, parent, None, lexical
        _component(leaf)
        return opened, parent, leaf, lexical / leaf
    except Exception:
        _close_all(opened)
        raise


def library_root(companies_root: os.PathLike[str] | str, company: str, class_id: str, session_company: str) -> Path:
    """Return ``companies/{company}/eval-library/{classId}`` after the bind check.

    A slug that fails ``company_scope``, is not in the manifest, or walks
    through a symlink raises SurfaceError before another company's directory
    is used. This does not create directories.
    """
    opened, _parent, leaf, lexical = _open_library(
        companies_root, company, class_id, session_company, [], create=False
    )
    _close_all(opened)
    if leaf is not None:
        raise SurfaceError("unavailable path")
    return lexical


def read_library_bytes(
    companies_root: os.PathLike[str] | str,
    company: str,
    class_id: str,
    rel: str,
    session_company: str,
) -> bytes:
    """Read one library file. A foreign company slug fails before any open."""
    # Bind first so a foreign slug is refused before the surface-slot check
    # rewrites the error callers assert on.
    _session_slugs(company, class_id, session_company)
    rel_norm = normalize_surface_path(rel)
    opened, parent, leaf, _lexical = _open_library(
        companies_root,
        company,
        class_id,
        session_company,
        rel_norm.split("/"),
        create=False,
    )
    try:
        if leaf is None:
            raise SurfaceError("empty path")
        return _read_at(parent.fd, leaf)
    finally:
        _close_all(opened)


def write_library_bytes(
    companies_root: os.PathLike[str] | str,
    company: str,
    class_id: str,
    rel: str,
    data: bytes,
    session_company: str,
) -> Path:
    """Write one library file. A foreign or unknown company fails before mkdir or open."""
    payload = _as_bytes(data, "library")
    _session_slugs(company, class_id, session_company)
    rel_norm = normalize_surface_path(rel)
    opened, parent, leaf, lexical = _open_library(
        companies_root,
        company,
        class_id,
        session_company,
        rel_norm.split("/"),
        create=True,
    )
    try:
        if leaf is None:
            raise SurfaceError("empty path")
        _replace_at(parent.fd, leaf, payload)
        return lexical
    finally:
        _close_all(opened)


def run_indigo_fixture(companies_root: os.PathLike[str] | str) -> bytes:
    """Exercise the indigo library only.

    The session bind is ``indigo``. The companies root must already contain
    ``manifest.yaml`` listing indigo and a real ``indigo`` directory. This
    function does not receive another company's slug and does not build
    another company's path. Callers that place a second company next to
    indigo can assert it is never opened.
    """
    write_library_bytes(companies_root, "indigo", "class-001", "skills/cue.md", b"cue", "indigo")
    merged = apply_tree(
        {"skills/cue.md": b"cue", "policies/keep.md": b"keep-me"},
        {"skills/cue.md": b"cue-2"},
    )
    if merged["policies/keep.md"] != b"keep-me":
        raise SurfaceError("omitted file was not inherited")
    restored = round_trip(merged)
    if restored["policies/keep.md"] != b"keep-me" or restored["skills/cue.md"] != b"cue-2":
        raise SurfaceError("round-trip changed bytes")
    return read_library_bytes(companies_root, "indigo", "class-001", "skills/cue.md", "indigo")


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "normalize":
        try:
            sys.stdout.write(normalize_surface_path(argv[2]) + "\n")
        except SurfaceError as exc:
            sys.stderr.write(f"error: {exc}\n")
            return 1
        return 0
    sys.stderr.write("usage: surface.py normalize RELATIVE_PATH\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
