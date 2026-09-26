#!/usr/bin/env bash
# Regression: the Grok minimum-version gate in codex-preflight.sh must reach
# the right verdict on a host whose `sort` has no version mode.
#
# Why this exists. HQ's Grok adapter needs Grok >= GROK_MIN_VERSION: on a 0.2.x
# build a PreToolUse deny does not block one tool call, it cancels the whole
# turn (cancellation_category "hook_denied"), and `hq lanes` runs
# `grok --single`, where the turn ending ends the process. A lane then dies on
# the first guard that objects. `doctor` is the documented place an operator
# learns this, so a wrong verdict there is worse than no check at all.
#
# The first cut of the gate compared versions with `sort -V`. Stock macOS ships
# BSD sort, which has no version mode (the same constraint
# hook-gate-path-augment.test.sh already enforces for hook-gate). Under
# `set -o pipefail` the substitution comes back empty, the comparison reads
# that as "older", and doctor tells an operator on a perfectly current Grok to
# go update it. This test pins the behaviour by putting a BSD-like sort on PATH
# for the whole run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
PREFLIGHT="$ROOT/core/scripts/codex-preflight.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$PREFLIGHT" ] || fail "missing $PREFLIGHT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/grok-min-version.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"

MIN="$(sed -n 's/^GROK_MIN_VERSION="\([^"]*\)"$/\1/p' "$PREFLIGHT" | head -1)"
[ -n "$MIN" ] || fail "could not read GROK_MIN_VERSION out of codex-preflight.sh"
pass "declared minimum is $MIN"

# A sort that behaves like BSD sort: every version flag is a usage error.
cat > "$BIN/sort" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    -V|--version-sort|-*V*) echo "sort: illegal option -- V" >&2; exit 2 ;;
  esac
done
exec /usr/bin/sort "$@"
STUB
chmod +x "$BIN/sort"

# Confirm the stub really does reject the flag, so a green run cannot mean the
# shim quietly fell through to a GNU sort.
if printf '1\n2\n' | PATH="$BIN:$PATH" sort -V >/dev/null 2>&1; then
  fail "BSD-sort shim accepted -V; the shim is not in effect"
fi
pass "BSD-sort shim rejects -V"

make_grok() { # <version>
  printf '#!/bin/sh\necho "grok %s (deadbeef)"\n' "$1" > "$BIN/grok"
  chmod +x "$BIN/grok"
}

# BASH_ENV is neutralised here for a reason beyond speed: on a host that points
# it at a profile, that profile re-exports PATH (nvm, brew shellenv) inside the
# script's own bash and silently wins over the prepend below, so the stubs would
# never be reached and every case would pass against the real installation.
run_doctor() {
  PATH="$BIN:$PATH" BASH_ENV=/dev/null bash "$PREFLIGHT" doctor 2>&1 \
    | grep -i '^  grok: grok' || true
}

# Prove the stub is the binary under test before asserting on any verdict.
make_grok "0.0.1-probe"
probe="$(PATH="$BIN:$PATH" BASH_ENV=/dev/null bash -c 'command -v grok')"
[ "$probe" = "$BIN/grok" ] || fail "stub grok not on PATH inside the test shell (resolved $probe)"
pass "stub grok resolves at $probe"

echo "[1] a current build is not reported as too old"
make_grok "1.0.41"
out="$(run_doctor)"
case "$out" in
  *"TOO OLD"*) fail "1.0.41 reported too old under BSD sort: $out" ;;
  "") fail "doctor printed no grok version line (got nothing to assert on)" ;;
esac
pass "1.0.41: $out"

echo "[2] the exact minimum is accepted"
make_grok "$MIN"
out="$(run_doctor)"
case "$out" in
  *"TOO OLD"*) fail "the minimum itself ($MIN) reported too old: $out" ;;
esac
pass "$MIN: $out"

echo "[3] the builds that cancel lanes are reported"
for old in 0.2.56 0.2.93 1.0.33; do
  make_grok "$old"
  out="$(run_doctor)"
  case "$out" in
    *"TOO OLD"*) pass "$old flagged: $out" ;;
    *) fail "$old was NOT flagged as too old: ${out:-<no grok line>}" ;;
  esac
done

echo "[4] a newer major is accepted"
make_grok "2.0.0"
out="$(run_doctor)"
case "$out" in
  *"TOO OLD"*) fail "2.0.0 reported too old: $out" ;;
esac
pass "2.0.0: $out"

echo "[5] doctor stays read-only — it advises \`hq reindex\`, it does not run it"
# The advisory strings were written with unescaped backticks inside a
# double-quoted echo, so every doctor run on an untrusted tree silently shelled
# out to `hq reindex` and rewrote ~/.grok trust, config.toml and the user
# bridge. A diagnostic that repairs what it is meant to report cannot be
# trusted to report it. Put an `hq` on PATH that records any call and fails
# loudly if one happens.
make_grok "1.0.41"
CALLED="$TMP/hq-was-called"
rm -f "$CALLED"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$CALLED" > "$BIN/hq"
chmod +x "$BIN/hq"
# HOME points at an empty directory so the trust and user-bridge probes both
# take their else branch. Without this the assertion is vacuous on a machine
# whose tree is already trusted — which is every machine where the bug has
# already run once and repaired its own trigger.
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"
out5="$(PATH="$BIN:$PATH" BASH_ENV=/dev/null HOME="$FAKE_HOME" bash "$PREFLIGHT" doctor 2>&1 || true)"
case "$out5" in
  *"NOT trusted"*) : ;;
  *) fail "case [5] did not reach the untrusted advisory branch; the assertion would be vacuous" ;;
esac
if [ -f "$CALLED" ]; then
  fail "doctor invoked hq: $(tr '\n' ';' < "$CALLED")"
fi
pass "doctor reached both advisory branches and made no hq call"
rm -f "$BIN/hq"

echo "grok-min-version: ok"
