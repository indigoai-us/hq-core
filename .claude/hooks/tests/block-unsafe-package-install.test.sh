#!/usr/bin/env bash
# block-unsafe-package-install.test.sh
#
# Regression suite for the supply-chain install guard, focused on the
# value-taking-flag parse bug fixed 2026-09-11: `npm i -g --prefix /path <pkg>`
# had its space-separated `/path` read as an untrusted positional package, which
# BLOCKED sanctioned first-party / allow-listed global installs (e.g. upgrading
# the hq CLI into ~/.local). The `--flag=value` form always worked; the
# space-separated form did not. The fix must close the parse gap WITHOUT opening
# a hole for genuinely untrusted installs.
#
# The hook resolves its allow file (core/scripts/install-deps.allow) from the HQ
# root two levels up from the hook dir, so this suite exercises the REAL
# allow-list (@indigoai-us/hq-cli@*, @tobilu/qmd@2.5.3).
set -u

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/block-unsafe-package-install.sh"
FAIL=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: needs jq"; exit 0; }

run() { # cmd -> exit code (env assignments may be prefixed by the caller)
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" \
    | bash "$HOOK" >/dev/null 2>&1
  echo $?
}
check() { # desc, cmd, want
  local got; got=$(run "$2")
  [ "$got" = "$3" ] && pass "$1" || fail "$1 (exit=$got want=$3)"
}

# --- THE BUG: a space-separated value-flag must not block a sanctioned install
check "first-party @indigoai-us with --prefix <path>" \
  "npm install -g --prefix /tmp/pfx @indigoai-us/hq-cli@5.109.8" 0
check "allow-listed pin (qmd) with --prefix <path>" \
  "npm install -g --prefix /tmp/pfx @tobilu/qmd@2.5.3" 0
check "-C alias carrying a path value" \
  "npm install -g -C /tmp/pfx @indigoai-us/hq-cli@5.109.8" 0
check "--registry <url> before a first-party pkg" \
  "npm install -g --registry https://r.example.com @indigoai-us/hq-cli@5.109.8" 0
check "pnpm add -g --dir <path> first-party" \
  "pnpm add -g --dir /tmp/pfx @indigoai-us/hq-cli@5.109.8" 0

# --- regression: the equals form kept working, still does
check "first-party with --prefix=<path> (equals form)" \
  "npm install -g --prefix=/tmp/pfx @indigoai-us/hq-cli@5.109.8" 0

# --- GUARD INTEGRITY: the flag-value strip must NOT open a hole
check "untrusted pkg with --prefix <path> still BLOCKS" \
  "npm install -g --prefix /tmp/pfx left-pad" 2
check "mixed first-party + untrusted with --prefix still BLOCKS" \
  "npm install -g --prefix /tmp/pfx @indigoai-us/hq-cli@5.109.8 left-pad" 2
check "bare untrusted global (no flag) still BLOCKS" \
  "npm install -g left-pad" 2

# --- baselines unaffected by the change
check "npm ci is lockfile-strict, allowed" "npm ci" 0
check "npm install hydration (no pkg) allowed" "npm install" 0
check "npm install --prefix <path> hydration (no pkg) allowed" \
  "npm install --prefix /tmp/pfx" 0

if [ "$FAIL" = "0" ]; then echo "ALL PASS"; exit 0; else echo "FAILURES"; exit 1; fi
