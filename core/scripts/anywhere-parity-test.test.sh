#!/usr/bin/env bash
# Tests for core/scripts/anywhere-parity-test.sh using a stub runtime (PARITY_RUNNER).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARITY="$SCRIPT_DIR/anywhere-parity-test.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

# Fake HQ with a manifest mapping one repo to the default company.
HQ="$TMP/hq"
MINE="personal" OTHER="otherco"
CO_DIR="$HQ/companies"
mkdir -p "$HQ/core" "$CO_DIR/$MINE/projects/p1/journal" "$CO_DIR/$OTHER/knowledge" "$HQ/repos/private/mapped"
touch "$HQ/core/core.yaml"
cat > "$CO_DIR/manifest.yaml" <<YAML
companies:
  $MINE:
    name: Mine
    repos:
      - repos/private/mapped
    knowledge: companies/$MINE/knowledge/
  $OTHER:
    name: Other
    repos: []
YAML
FOREIGN="$TMP/foreign-repo"; mkdir -p "$FOREIGN"

# Good stub: behaves like a working HQ session.
cat > "$TMP/good.sh" <<STUB
#!/usr/bin/env bash
n="\$HQ_PARITY_NONCE"
echo "HQ_COMPANY=$MINE"
echo "HQ_POLICY_BLOCKED=\$n"
echo "HQ_WORKER_REPORT=\$n"
printf 'entry %s\n' "\$n" > "$CO_DIR/$MINE/projects/p1/journal/\$n.md"
STUB
# Bad stub: no HQ available, writes the cross-company file.
cat > "$TMP/bad.sh" <<STUB
#!/usr/bin/env bash
echo "no HQ here"
printf x > "$CO_DIR/$OTHER/knowledge/\$HQ_PARITY_NONCE.txt"
STUB
chmod +x "$TMP/good.sh" "$TMP/bad.sh"

run() { set +e; out="$("$@" 2>&1)"; rc=$?; set -e; }

# 1. HQ root control with a working session: all four PASS, exit 0.
run env PARITY_RUNNER="$TMP/good.sh" bash "$PARITY" --runtime claude --repo "$HQ" --hq-root "$HQ"
[ "$rc" -eq 0 ] || fail "control expected exit 0, got $rc: $out"
[ "$(printf '%s\n' "$out" | grep -c '^PASS ')" = 4 ] || fail "control expected 4 PASS: $out"
pass "HQ root control: four PASS, exit 0"

# 2. Mapped repo via manifest, codex runtime, --json: four JSON PASS lines.
run env PARITY_RUNNER="$TMP/good.sh" bash "$PARITY" --runtime codex --repo "$HQ/repos/private/mapped" --hq-root "$HQ" --json
[ "$rc" -eq 0 ] || fail "mapped expected exit 0: $out"
[ "$(printf '%s\n' "$out" | grep -c '^{"assertion":"[a-z]*","result":"PASS"')" = 4 ] || fail "expected 4 JSON PASS lines: $out"
if command -v node >/dev/null; then
  printf '%s\n' "$out" | node -e 'require("readline").createInterface({input:process.stdin}).on("line",l=>JSON.parse(l))' \
    || fail "JSON lines do not parse"
fi
pass "manifest-mapped repo, --json: four parseable PASS lines"

# 3. Foreign repo with no install: all four FAIL, non-zero exit.
run env PARITY_RUNNER="$TMP/good.sh" bash "$PARITY" --runtime claude --repo "$FOREIGN" --hq-root "$HQ"
[ "$rc" -ne 0 ] || fail "foreign expected non-zero"
[ "$(printf '%s\n' "$out" | grep -c '^FAIL ')" = 4 ] || fail "foreign expected 4 FAIL: $out"
pass "foreign repo: four FAIL, non-zero exit"

# 4. Broken session on a mapped repo: all four FAIL and the leaked probe is removed.
run env PARITY_RUNNER="$TMP/bad.sh" bash "$PARITY" --runtime claude --repo "$HQ" --hq-root "$HQ" --json
[ "$rc" -eq 1 ] || fail "bad session expected exit 1, got $rc"
[ "$(printf '%s\n' "$out" | grep -c '"result":"FAIL"')" = 4 ] || fail "bad session expected 4 FAIL: $out"
[ -z "$(ls "$CO_DIR/$OTHER/knowledge")" ] || fail "leaked probe not cleaned up"
pass "broken session: four FAIL, leaked cross-company file removed"

# 5. The runtime does not inherit the caller's session identity.
cat > "$TMP/env.sh" <<STUB
#!/usr/bin/env bash
printf 'SID=[%s][%s][%s][%s]\n' "\${HQ_SESSION_ID:-}" "\${CLAUDE_CODE_SESSION_ID:-}" "\${HQ_PARENT_SESSION_ID:-}" "\${HQ_SPAWN_COMPANY:-}" > "$TMP/sid.txt"
STUB
chmod +x "$TMP/env.sh"
run env HQ_SESSION_ID=parent-sid CLAUDE_CODE_SESSION_ID=parent-cc HQ_PARENT_SESSION_ID=parent-sid HQ_SPAWN_COMPANY=parent-co PARITY_RUNNER="$TMP/env.sh" \
  bash "$PARITY" --runtime claude --repo "$HQ" --hq-root "$HQ"
[ "$(cat "$TMP/sid.txt")" = 'SID=[][][][]' ] || fail "runtime inherited the caller session id: $(cat "$TMP/sid.txt")"
pass "runtime starts without the caller's session or spawn company"

# 6. The probe never targets the expected company, and the journal is read
#    under the company the session bound.
mkdir -p "$CO_DIR/$OTHER/projects/p2/journal" "$CO_DIR/$MINE/knowledge"
cat > "$TMP/other.sh" <<STUB
#!/usr/bin/env bash
n="\$HQ_PARITY_NONCE"
echo "HQ_COMPANY=$OTHER"
echo "HQ_POLICY_BLOCKED=\$n"
echo "HQ_WORKER_REPORT=\$n"
printf 'entry %s\n' "\$n" > "$CO_DIR/$OTHER/projects/p2/journal/\$n.md"
STUB
chmod +x "$TMP/other.sh"
run env PARITY_RUNNER="$TMP/other.sh" bash "$PARITY" --runtime claude --repo "$HQ" --hq-root "$HQ" --company "$OTHER"
[ "$rc" -eq 0 ] || fail "--company $OTHER expected exit 0: $out"
printf '%s\n' "$out" | grep -q "companies/$MINE/knowledge/" || fail "probe should target $MINE: $out"
printf '%s\n' "$out" | grep -q "PASS journal — companies/$OTHER/" || fail "journal not read under bound company: $out"
pass "--company: probe targets another company, journal read under bound company"

# 7. The real Codex invocation must trust user hooks and use the shipped sandbox.
if grep -Fq -- '--dangerously-bypass-hook-trust --sandbox danger-full-access' "$PARITY"; then
  pass "Codex parity probe trusts hooks and uses the full-access sandbox"
else
  fail "Codex parity probe omitted the repository-standard hook trust or sandbox flags"
fi

# 8. Usage errors exit 2.
run bash "$PARITY" --runtime gpt --repo "$HQ"
[ "$rc" -eq 2 ] || fail "bad runtime expected exit 2, got $rc"
pass "usage error exits 2"
