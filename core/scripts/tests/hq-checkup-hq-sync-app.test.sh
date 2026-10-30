#!/usr/bin/env bash
# hq-core: public
# Regression: hq-checkup must treat HQ Sync.app (and ~/Applications) as the
# HQ app. Checking only /Applications/HQ.app reports a false "isn't installed".
set -euo pipefail
ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
CHECKUP="$ROOT/.claude/skills/hq-checkup/hq-checkup.sh"
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$FX/root" "$FX/home" "$FX/bin" "$FX/Applications" "$FX/UserApplications"
cat > "$FX/bin/hq" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && { echo "9.9.9"; exit 0; }
[ "${1:-}" = "whoami" ] && { echo "logged in as test@example.com"; exit 0; }
exit 1
EOF
chmod +x "$FX/bin/hq"

cat > "$FX/bin/open" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$OPEN_LOG"
exit 0
EOF
chmod +x "$FX/bin/open"

cat > "$FX/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FX/bin/pgrep"

items() {
  python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
for item in data["items"]:
    if item["status"] == sys.argv[2]:
        print(item["headline"] + " | " + item["action"])
' "$1" "$2"
}

run_checkup() {
  env -i PATH="$FX/bin:/usr/bin:/bin" HOME="$FX/home" TMPDIR="$FX" \
    CLAUDE_PROJECT_DIR="$FX/root" \
    HQ_CHECKUP_UNAME=Darwin \
    HQ_CHECKUP_APPLICATIONS="$FX/Applications" \
    HQ_CHECKUP_USER_APPLICATIONS="$FX/UserApplications" \
    HQ_CHECKUP_START_WAIT=0 \
    HQ_CHECKUP_PGREP="$FX/bin/pgrep" \
    OPEN_LOG="$FX/open.log" \
    bash "$CHECKUP" --quick --json "$@" 2>/dev/null || true
}

echo "[1] no bundle → isn't installed"
run_checkup --check > "$FX/out.json"
items "$FX/out.json" YOU | grep -q "The HQ app isn't installed on this computer" \
  || fail "missing not-installed: $(cat "$FX/out.json")"
items "$FX/out.json" YOU | grep -q "isn't running" \
  && fail "no-bundle reported as not running: $(cat "$FX/out.json")"

echo "[2] HQ Sync.app in /Applications → isn't running, not 'isn't installed'"
mkdir -p "$FX/Applications/HQ Sync.app"
run_checkup --check > "$FX/out.json"
items "$FX/out.json" YOU | grep -q "The HQ app isn't running, so your work isn't being saved" \
  || fail "Sync.app not treated as installed: $(cat "$FX/out.json")"
items "$FX/out.json" YOU | grep -q "isn't installed" \
  && fail "Sync.app still reported as not installed: $(cat "$FX/out.json")"
rmdir "$FX/Applications/HQ Sync.app"

echo "[3] HQ.app in /Applications still counts"
mkdir -p "$FX/Applications/HQ.app"
run_checkup --check > "$FX/out.json"
items "$FX/out.json" YOU | grep -q "The HQ app isn't running, so your work isn't being saved" \
  || fail "HQ.app not treated as installed: $(cat "$FX/out.json")"
rmdir "$FX/Applications/HQ.app"

echo "[4] HQ Sync.app only in ~/Applications"
mkdir -p "$FX/UserApplications/HQ Sync.app"
run_checkup --check > "$FX/out.json"
items "$FX/out.json" YOU | grep -q "The HQ app isn't running, so your work isn't being saved" \
  || fail "user Applications Sync.app missed: $(cat "$FX/out.json")"
items "$FX/out.json" YOU | grep -q "isn't installed" \
  && fail "user Applications Sync.app reported as not installed: $(cat "$FX/out.json")"

echo "[5] fix mode opens the Sync.app bundle"
rm -f "$FX/open.log"
run_checkup > "$FX/out.json"
grep -Fqx "$FX/UserApplications/HQ Sync.app" "$FX/open.log" \
  || fail "open was not called with Sync.app bundle: $(cat "$FX/open.log" 2>/dev/null)"
items "$FX/out.json" YOU | grep -q "The HQ app won't start" \
  || fail "expected won't-start after stub open: $(cat "$FX/out.json")"

echo "PASS"
