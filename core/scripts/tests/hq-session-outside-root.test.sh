#!/usr/bin/env bash
# hq-core: public
# Regression test: hq-session.sh and `startwork-context.sh orient` must work
# when run from a subdirectory of the HQ root and from outside it, with no
# HQ_ROOT in the caller's environment. The installed hq CLI (which
# hq-session.sh forwards to) finds the root by walking up from the cwd, so the
# script has to hand it the root it lives in. A stub `hq` below reproduces
# that walk-up and its "Could not find your HQ installation" failure.
# Also checks that an orient bind failure (exit 4) reports the cause.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
unset HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_SESSION_ID \
      CODEX_THREAD_ID GROK_SESSION_ID HQ_ROOT CLAUDE_PROJECT_DIR HQ_HQ_SESSION_NO_CLI || true

FIX="$TMP/hq"
CO=acme
mkdir -p "$FIX/companies/$CO" "$FIX/core/scripts/lib" "$FIX/core/workers" "$FIX/workspace/sessions" "$FIX/sub/dir" "$TMP/outside" "$TMP/bin"
cp "$SRC/hq-session.sh" "$SRC/work-mesh-live-bind-trusted.sh" "$SRC/startwork-context.sh" "$FIX/core/scripts/"
cp "$SRC/lib/"*.sh "$FIX/core/scripts/lib/"
printf 'companies:\n  %s:\n    name: Acme\n    path: companies/%s\n' "$CO" "$CO" > "$FIX/companies/manifest.yaml"

# Stub CLI: same root resolution as hq-cli (HQ_ROOT, CLAUDE_PROJECT_DIR, then
# walk up from cwd looking for a companies dir), then run the in-tree script.
cat > "$TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = core ] && [ "${2:-}" = --help ]; then echo "hq-session exact-company-directory-match-v1"; exit 0; fi
[ "${1:-}" = core ] && [ "${2:-}" = hq-session ] || exit 98
root="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-}}"
if [ -z "$root" ]; then
  d="$PWD"
  while [ "$d" != / ] && [ ! -d "$d/companies" ]; do d="$(dirname "$d")"; done
  [ -d "$d/companies" ] || { echo "Could not find your HQ installation." >&2; exit 1; }
  root="$d"
fi
shift 2
HQ_ROOT="$root" HQ_HQ_SESSION_NO_CLI=1 exec bash "$root/core/scripts/hq-session.sh" "$@"
STUB
chmod +x "$TMP/bin/hq"
export PATH="$TMP/bin:$PATH" HQ_CLI_CAPS_CACHE="$TMP/caps" HOME="$TMP/home" TMPDIR="$TMP"
mkdir -p "$HOME"
S="$FIX/core/scripts/hq-session.sh"

for where in "$FIX" "$FIX/sub/dir" "$TMP/outside"; do
  sid="s-$(basename "$where")"
  mkdir -p "$FIX/workspace/sessions/$sid"; printf 'session_id: %s\n' "$sid" > "$FIX/workspace/sessions/$sid/meta.yaml"
  (cd "$where" && bash "$S" --session-id "$sid" set note hello) || fail "set failed from $where"
  got="$(cd "$where" && bash "$S" --session-id "$sid" get note)" || fail "get failed from $where"
  [ "$got" = hello ] || fail "get from $where returned '$got'"
  echo "  ok: hq-session set/get from $where"
done

orient() { (cd "$1" && HQ_WORK_MESH_RECONCILE_STUB=1 bash "$FIX/core/scripts/startwork-context.sh" orient --company "$CO" --session-id "$2"); }
for where in "$FIX" "$FIX/sub/dir" "$TMP/outside"; do
  sid="o-$(basename "$where")"
  out="$(orient "$where" "$sid" 2>&1)" || fail "orient failed from $where: $out"
  grep -q "^Bound: session $sid company_slug=$CO" <<<"$out" || fail "orient from $where did not bind: $(head -3 <<<"$out")"
  echo "  ok: orient bind from $where"
done

# Exit 4 must say what went wrong: break the binder and expect its stderr.
printf '#!/usr/bin/env bash\necho "boom: binder exploded" >&2\nexit 7\n' > "$FIX/core/scripts/work-mesh-live-bind-trusted.sh"
rc=0; err="$(orient "$TMP/outside" o-fail 2>&1 >/dev/null)" || rc=$?
[ "$rc" = 4 ] || fail "expected exit 4, got $rc"
grep -q "bind failed for '$CO' (root: $FIX)" <<<"$err" || fail "exit 4 message lacks root: $err"
grep -q 'boom: binder exploded' <<<"$err" || fail "exit 4 message lacks the binder's error: $err"
echo "  ok: orient exit 4 reports the cause"
echo "PASS: hq-session-outside-root"
