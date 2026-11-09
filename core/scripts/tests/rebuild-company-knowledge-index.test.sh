#!/usr/bin/env bash
# Regression test for real-directory company knowledge indexing.
# Also covers feedback_96b21a44: --help / unknown flags / old CLI must not
# rewrite every company's INDEX.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/rebuild-company-knowledge-index.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

KNOWLEDGE="$TMP/hq/companies/acme/knowledge"
OTHER="$TMP/hq/companies/other/knowledge"
mkdir -p "$KNOWLEDGE/docs" "$OTHER"
printf '# Team Guide\n' > "$KNOWLEDGE/guide.md"
printf '# Runbook\n' > "$KNOWLEDGE/docs/runbook.md"
printf '# Other\n' > "$OTHER/x.md"

passed=0
fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# --help must print usage and write nothing (feedback_96b21a44).
if ! HQ_ROOT="$TMP/hq" bash "$SCRIPT" --help >"$TMP/help.out" 2>"$TMP/help.err"; then
  fail "--help exited nonzero"
fi
grep -Fq 'Help performs no writes' "$TMP/help.out" || fail "--help stdout missing usage"
if [ -e "$KNOWLEDGE/INDEX.md" ] || [ -e "$OTHER/INDEX.md" ]; then
  fail "--help wrote an INDEX.md"
fi
passed=$((passed + 1))

# Unrecognized flags must refuse before any write.
if HQ_ROOT="$TMP/hq" bash "$SCRIPT" --nope >"$TMP/nope.out" 2>"$TMP/nope.err"; then
  fail "unknown flag exited 0"
fi
if [ -e "$KNOWLEDGE/INDEX.md" ] || [ -e "$OTHER/INDEX.md" ]; then
  fail "unknown flag wrote an INDEX.md"
fi
passed=$((passed + 1))

# CLI older than 5.345.188 still fans out on --help. The forwarder floor must
# stop it before hq runs.
mkdir -p "$TMP/old-bin"
cat > "$TMP/old-bin/hq" <<'HQ'
#!/usr/bin/env bash
if [ "${1-}" = "--version" ]; then
  printf '%s\n' "${HQ_TEST_CLI_VERSION:?}"
  exit 0
fi
printf 'would rewrite every company\n'
exit 0
HQ
chmod +x "$TMP/old-bin/hq"
if HQ_TEST_CLI_VERSION=5.345.62 PATH="$TMP/old-bin:$PATH" HQ_ROOT="$TMP/hq" \
  bash "$SCRIPT" --help >"$TMP/old.out" 2>"$TMP/old.err"; then
  fail "forwarder accepted hq-cli 5.345.62 below its 5.345.188 floor"
fi
grep -Fq 'needs hq-cli >= 5.345.188 (found 5.345.62)' "$TMP/old.err" || \
  fail "old CLI rejection did not include the floor message"
if grep -Fq 'would rewrite every company' "$TMP/old.out"; then
  fail "old CLI ran before the floor rejection"
fi
if [ -e "$KNOWLEDGE/INDEX.md" ] || [ -e "$OTHER/INDEX.md" ]; then
  fail "old CLI floor path wrote an INDEX.md"
fi
passed=$((passed + 1))

HQ_ROOT="$TMP/hq" bash "$SCRIPT" >/dev/null 2>/dev/null
INDEX="$KNOWLEDGE/INDEX.md"

if ! grep -Fq '| `docs/` | 1 item(s) |' "$INDEX"; then
  echo "FAIL: knowledge directory row missing from INDEX.md" >&2
  exit 1
fi

if ! grep -Fq '| `guide.md` | Team Guide |' "$INDEX"; then
  echo "FAIL: knowledge file row missing from INDEX.md" >&2
  exit 1
fi
passed=$((passed + 2))

echo "rebuild-company-knowledge-index: ${passed} passed, 0 failed"
