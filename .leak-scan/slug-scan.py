#!/usr/bin/env python3
"""slug-scan.py — report private tenant slugs in changed files without knowing them.

The snapshot (.leak-scan/manifest-snapshot.yaml, version 2) holds a salt and
sha256("<salt>:<slug>") per private slug. This script hashes every candidate
token in each file with the same salt and reports a hit when the hash is in the
set. Candidates are, for every run of [A-Za-z0-9_-]:

  - the whole run                      (hq-core-staging)
  - each piece split on "_" and "-"    (cmp_<slug>, <slug>_prod)
  - every contiguous span of hyphen-joined pieces inside an "_" segment
    (<slug>-prod, my-<slug>, where the slug itself may contain hyphens)

so a slug inside a longer identifier is still caught. Matching is exact case
(owner decision 2026-10-23). Output names the file and line, never the slug.

Exit 0 clean, 1 hits, 2 the scan could not run (bad snapshot, no hashes,
unreadable list). An empty hash set is an error, not a clean pass.

Usage: slug-scan.py --snapshot FILE --allowlist FILE --files LIST
       (LIST is a text file, one path per line)
"""
import argparse
import hashlib
import os
import re
import sys

RUN_RE = re.compile(r"[A-Za-z0-9_-]+")
MIN_LEN = 3


def section(path, key):
    out, on = [], False
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if re.match(rf"^{re.escape(key)}:", line):
                on = True
                continue
            if on and re.match(r"^[A-Za-z]", line):
                on = False
            if on:
                m = re.match(r"^\s*-\s*([^#\s\"']+)", line)
                if m:
                    out.append(m.group(1))
    return out


def read_salt(snap):
    with open(snap, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"^salt:\s*([0-9a-f]{32,})\s*$", line)
            if m:
                return m.group(1)
    return None


def candidates(run):
    """Every token a private slug could be hiding in, for one [A-Za-z0-9_-] run."""
    seen = set()
    if len(run) >= MIN_LEN:
        seen.add(run)
    for segment in run.split("_"):
        if not segment:
            continue
        pieces = [p for p in segment.split("-")]
        n = len(pieces)
        for i in range(n):
            for j in range(i, n):
                span = "-".join(pieces[i:j + 1])
                if len(span) >= MIN_LEN and not span.startswith("-") and not span.endswith("-"):
                    seen.add(span)
    return seen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", required=True)
    ap.add_argument("--allowlist", required=True)
    ap.add_argument("--files", required=True)
    a = ap.parse_args()

    try:
        salt = read_salt(a.snapshot)
        hashes = set(section(a.snapshot, "slug_hashes"))
        never_flag = set(section(a.snapshot, "public_slugs")) | set(section(a.allowlist, "allowed"))
        with open(a.files, encoding="utf-8") as fl:
            paths = [p.strip() for p in fl if p.strip()]
    except OSError as e:
        print(f"::error::slug-scan could not read its inputs: {e}", file=sys.stderr)
        return 2
    if not salt:
        print("::error::snapshot has no salt; regenerate with .leak-scan/hash-slugs.sh", file=sys.stderr)
        return 2

    def h(token):
        return hashlib.sha256(f"{salt}:{token}".encode()).hexdigest()

    hashes -= {h(t) for t in never_flag}
    if not hashes:
        print("::error::snapshot has no private slug hashes; the scan cannot run (regenerate the snapshot)", file=sys.stderr)
        return 2

    cache = {}

    def is_private(token):
        hit = cache.get(token)
        if hit is None:
            hit = h(token) in hashes
            cache[token] = hit
        return hit

    leaks = 0
    for path in paths:
        try:
            with open(path, "rb") as fh:
                data = fh.read().decode("utf-8", errors="replace")
        except OSError as e:
            print(f"::warning file={path}::slug-scan could not read file: {e}", file=sys.stderr)
            continue
        for lineno, line in enumerate(data.split("\n"), 1):
            found = False
            for run in set(RUN_RE.findall(line)):
                if any(is_private(c) for c in candidates(run)):
                    found = True
                    break
            if found:
                leaks += 1
                print(f"::error file={path},line={lineno}::private tenant slug leaked (hash match) at {path}:{lineno}")

    if leaks:
        print(f"slug-scan: {leaks} private slug hit(s) found", file=sys.stderr)
        return 1
    print("slug-scan: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
