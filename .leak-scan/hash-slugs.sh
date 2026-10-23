#!/usr/bin/env bash
# hash-slugs.sh — write .leak-scan/manifest-snapshot.yaml from plaintext tenant
# slugs WITHOUT storing the names. Each private slug is stored as
# sha256("<salt>:<slug>") so the snapshot can live in this repo and in public
# hq-core history without naming a tenant. public_slugs stay in plaintext
# because they are public brands.
#
# Usage:
#   printf '%s\n' slug-a slug-b | bash .leak-scan/hash-slugs.sh \
#       [--public indigo,personal] [--salt <hex>] [--out .leak-scan/manifest-snapshot.yaml]
#
# Without --salt, the salt in the existing --out file is reused when present,
# otherwise 32 random bytes are generated. HQ's /promote-hq-core Phase 4 is the
# intended caller (it reads companies/manifest.yaml and pipes the slugs here).
set -euo pipefail

public="indigo,personal"
salt=""
out=".leak-scan/manifest-snapshot.yaml"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --public) public="${2:-}"; shift 2 ;;
    --salt) salt="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "hash-slugs: unknown argument $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$salt" && -f "$out" ]]; then
  salt="$(awk '/^salt:/{print $2; exit}' "$out" | tr -d '"')"
fi
if [[ -z "$salt" ]]; then
  salt="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
fi
if ! [[ "$salt" =~ ^[0-9a-f]{32,}$ ]]; then
  echo "hash-slugs: salt must be lowercase hex, 32+ chars" >&2; exit 2
fi

# Read the slug list before the heredoc below takes over stdin.
input_slugs="$(cat)"

OUT="$out" SALT="$salt" PUBLIC="$public" SLUGS="$input_slugs" python3 - <<'PY'
import hashlib, os, sys, datetime
salt = os.environ["SALT"]
public = sorted({p.strip() for p in os.environ["PUBLIC"].split(",") if p.strip()})
slugs = sorted({l.strip() for l in os.environ["SLUGS"].splitlines() if l.strip() and not l.startswith("#")})
private = [s for s in slugs if s not in public]
hashes = sorted(hashlib.sha256(f"{salt}:{s}".encode()).hexdigest() for s in private)
lines = [
    "# manifest-snapshot.yaml — hashed view of HQ companies/manifest.yaml tenant slugs.",
    "#",
    "# Private tenant slugs are stored as sha256(\"<salt>:<slug>\") so this file can",
    "# sit in the repo and in public hq-core history without naming a tenant.",
    "# .leak-scan/scan.sh slugs hashes every slug-shaped token in a PR-changed",
    "# file with the same salt and fails on a match. Regenerate with",
    "# .leak-scan/hash-slugs.sh (HQ /promote-hq-core Phase 4 does this).",
    "#",
    "# public_slugs: brands hq-core may name; stored in plaintext and never flagged.",
    "",
    "version: 2",
    f"generated: {datetime.date.today().isoformat()}",
    "generator: .leak-scan/hash-slugs.sh",
    f"salt: {salt}",
    "",
    "public_slugs:",
] + [f"- {p}" for p in public] + ["", f"slug_hashes:  # {len(hashes)} private slugs"] + [f"- {h}" for h in hashes] + [""]
with open(os.environ["OUT"], "w") as f:
    f.write("\n".join(lines))
print(f"hash-slugs: wrote {os.environ['OUT']} with {len(hashes)} hashed private slugs and {len(public)} public slugs")
PY
