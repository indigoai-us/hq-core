#!/usr/bin/env bash
# hq-core: public
# Tests for core/scripts/hq-pr-create.sh with stub gh and hq on PATH.
# shellcheck disable=SC2015 # `ok` always returns 0, so `A && ok || no` is safe.
set -uo pipefail

for v in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
WRAP="$ROOT/core/scripts/hq-pr-create.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hq-pr-create-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/tmpd" "$TMP/root/core/settings" "$TMP/root/personal/settings"
# The wrapper's temp files land here, so the cleanup check sees only them.
export TMPDIR="$TMP/tmpd"

# Stub gh: records each argv entry on its own NUL-free line block and the
# resolved body (from --body or --body-file) into $TMP/body.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
: >"$STUB_DIR/args"
: >"$STUB_DIR/body"
while [ "$#" -gt 0 ]; do
  printf '[%s]\n' "$1" >>"$STUB_DIR/args"
  case "$1" in
    --body) printf '%s' "$2" >"$STUB_DIR/body"; printf '[%s]\n' "$2" >>"$STUB_DIR/args"; shift ;;
    --body-file) if [ "$2" = - ]; then cat >"$STUB_DIR/body"; else cat "$2" >"$STUB_DIR/body"; fi; printf '[%s]\n' "$2" >>"$STUB_DIR/args"; shift ;;
  esac
  shift
done
echo "https://github.com/o/r/pull/7"
STUB
cat >"$TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
printf x >>"$STUB_DIR/hq-calls"
if [ -n "${STUB_HQ_CHILD:-}" ]; then sleep 30 & echo "$!" >"$STUB_DIR/hq-child"; fi
if [ -n "${STUB_HQ_SLEEP:-}" ]; then sleep "$STUB_HQ_SLEEP"; fi
[ "${STUB_HQ_FAIL:-}" = 1 ] && exit 1
printf '{"fingerprint":"hqfp1:abc123","source":"test"}\n'
STUB
chmod 755 "$TMP/bin/gh" "$TMP/bin/hq"

export STUB_DIR="$TMP" PATH="$TMP/bin:$PATH" HQ_ROOT="$TMP/root"
# Each case starts with an empty fingerprint cache unless it tests the cache.
export HQ_FINGERPRINT_CACHE_DIR="$TMP/cache" HQ_SESSION_ID=test-session
fresh() { rm -rf "$TMP/cache"; }
unset HQ_FINGERPRINT_BIN STUB_HQ_SLEEP STUB_HQ_FAIL

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
FOOT=$'\n\n---\nHQ-Fingerprint: hqfp1:abc123'

out="$(bash "$WRAP" -R o/r --title "a title" --body "hello")"
[ "$(cat "$TMP/body")" = "hello$FOOT" ] && ok "--body gets footer" || no "--body gets footer"
[ "$out" = "https://github.com/o/r/pull/7" ] && ok "gh output unchanged" || no "gh output unchanged"
grep -qx '\[a title\]' "$TMP/args" && ok "arg with spaces verbatim" || no "arg with spaces verbatim"

bash "$WRAP" --body="x y" >/dev/null
[ "$(cat "$TMP/body")" = "x y$FOOT" ] && ok "--body= form" || no "--body= form"

bash "$WRAP" -b "short" >/dev/null
[ "$(cat "$TMP/body")" = "short$FOOT" ] && ok "-b form" || no "-b form"

printf 'from file\n\n' >"$TMP/b.md"
bash "$WRAP" --body-file "$TMP/b.md" >/dev/null
[ "$(cat "$TMP/body")" = "from file$FOOT" ] && ok "--body-file form" || no "--body-file form"
[ "$(cat "$TMP/b.md")" = "from file" ] && ok "source body file untouched" || no "source body file untouched"

bash "$WRAP" --body-file="$TMP/b.md" >/dev/null
[ "$(cat "$TMP/body")" = "from file$FOOT" ] && ok "--body-file= form" || no "--body-file= form"

printf 'piped' | bash "$WRAP" -F - >/dev/null
[ "$(cat "$TMP/body")" = "piped$FOOT" ] && ok "-F - stdin" || no "-F - stdin"

bash "$WRAP" --title t >/dev/null
[ "$(cat "$TMP/body")" = $'\n---\nHQ-Fingerprint: hqfp1:abc123' ] && ok "no body flag adds footer" || no "no body flag adds footer"

bash "$WRAP" --body $'keep\nHQ-Fingerprint: hqfp1:old' >/dev/null
[ "$(cat "$TMP/body")" = $'keep\nHQ-Fingerprint: hqfp1:old' ] && ok "existing footer not duplicated" || no "existing footer not duplicated"

bash "$WRAP" --title t -- --body literal >/dev/null
grep -qx '\[--\]' "$TMP/args" && [ "$(sed -n '$p' "$TMP/args")" = "[literal]" ] && ok "args after -- verbatim" || no "args after -- verbatim"

fresh
STUB_HQ_FAIL=1 bash "$WRAP" --body "plain" >/dev/null
[ "$(cat "$TMP/body")" = "plain" ] && ok "builder failure passes through" || no "builder failure passes through"

start=$(date +%s)
fresh
STUB_HQ_SLEEP=5 bash "$WRAP" --body "slow" >/dev/null
elapsed=$(( $(date +%s) - start ))
[ "$(cat "$TMP/body")" = "slow" ] && [ "$elapsed" -lt 5 ] && ok "builder capped at 2 s" || no "builder capped at 2 s ($elapsed s)"

printf 'enabled: false\n' >"$TMP/root/personal/settings/fingerprint.yaml"
bash "$WRAP" --body "off" >/dev/null
[ "$(cat "$TMP/body")" = "off" ] && ok "setting off passes through" || no "setting off passes through"
rm -f "$TMP/root/personal/settings/fingerprint.yaml"

fresh
HQ_FINGERPRINT_BIN="$TMP/missing-bin" bash "$WRAP" --body "nobin" >/dev/null
[ "$(cat "$TMP/body")" = "nobin" ] && ok "missing builder passes through" || no "missing builder passes through"

fresh
bash "$WRAP" --body a --body b >/dev/null
[ "$(cat "$TMP/body")" = "b$FOOT" ] && ok "repeated --body: last wins" || no "repeated --body: last wins"
[ "$(grep -cx '\[--body\]' "$TMP/args")" = 1 ] && ok "repeated --body: one --body sent" || no "repeated --body: one --body sent"

printf 'first\n' >"$TMP/a.md"
bash "$WRAP" -F "$TMP/a.md" --body-file "$TMP/b.md" >/dev/null
[ "$(cat "$TMP/body")" = "from file$FOOT" ] && ok "repeated --body-file: last wins" || no "repeated --body-file: last wins"

bash "$WRAP" -bfoo >/dev/null
[ "$(cat "$TMP/body")" = "foo$FOOT" ] && ok "-bTEXT attached form" || no "-bTEXT attached form"

bash "$WRAP" -F"$TMP/b.md" >/dev/null
[ "$(cat "$TMP/body")" = "from file$FOOT" ] && ok "-FPATH attached form" || no "-FPATH attached form"

mkdir -p "$TMP/adir"
bash "$WRAP" --title t --body-file "$TMP/adir" >/dev/null
[ "$(cat "$TMP/args")" = "[pr]"$'\n'"[create]"$'\n'"[--title]"$'\n'"[t]"$'\n'"[--body-file]"$'\n'"[$TMP/adir]" ] && ok "directory body file: argv unchanged" || no "directory body file: argv unchanged"

bash "$WRAP" --body x --title t --body-file "$TMP/b.md" >/dev/null
[ "$(cat "$TMP/args")" = "[pr]"$'\n'"[create]"$'\n'"[--body]"$'\n'"[x]"$'\n'"[--title]"$'\n'"[t]"$'\n'"[--body-file]"$'\n'"[$TMP/b.md]" ] && ok "mixed body kinds: argv unchanged" || no "mixed body kinds: argv unchanged"

fresh
STUB_HQ_FAIL=1 bash "$WRAP" --title t -bplain >/dev/null
[ "$(cat "$TMP/args")" = "[pr]"$'\n'"[create]"$'\n'"[--title]"$'\n'"[t]"$'\n'"[-bplain]" ] && ok "no fingerprint: argv order unchanged" || no "no fingerprint: argv order unchanged"

# Per-session cache: the builder runs once, later calls reuse the value.
fresh; rm -f "$TMP/hq-calls"
bash "$WRAP" --body c1 >/dev/null
bash "$WRAP" --body c2 >/dev/null
[ "$(cat "$TMP/body")" = "c2$FOOT" ] && [ "$(cat "$TMP/hq-calls")" = x ] && ok "cache: builder runs once per session" || no "cache: builder runs once per session"
HQ_SESSION_ID=other-session bash "$WRAP" --body c3 >/dev/null
[ "$(cat "$TMP/hq-calls")" = xx ] && ok "cache: new session id misses" || no "cache: new session id misses"
touch -t 202001010000 "$TMP/bin/hq"
bash "$WRAP" --body c4 >/dev/null
[ "$(cat "$TMP/hq-calls")" = xxx ] && ok "cache: hq mtime change misses" || no "cache: hq mtime change misses"
for f in "$TMP"/cache/fp-*; do touch -t 202001010000 "$f"; done
bash "$WRAP" --body c5 >/dev/null
[ "$(cat "$TMP/hq-calls")" = xxxx ] && ok "cache: entry older than 24 h misses" || no "cache: entry older than 24 h misses"
fresh; rm -f "$TMP/hq-calls"
STUB_HQ_FAIL=1 bash "$WRAP" --body n1 >/dev/null
bash "$WRAP" --body n2 >/dev/null
[ "$(cat "$TMP/body")" = "n2" ] && [ "$(cat "$TMP/hq-calls")" = x ] && ok "cache: empty result cached" || no "cache: empty result cached"
fresh; rm -f "$TMP/hq-calls"
printf 'enabled: false\n' >"$TMP/root/personal/settings/fingerprint.yaml"
bash "$WRAP" --body off2 >/dev/null
[ ! -f "$TMP/hq-calls" ] && ok "setting off: builder never runs" || no "setting off: builder never runs"
rm -f "$TMP/root/personal/settings/fingerprint.yaml"

# A hanging builder with a child: the 2 s cut leaves no process behind.
fresh; rm -f "$TMP/hq-child"
STUB_HQ_CHILD=1 STUB_HQ_SLEEP=30 bash "$WRAP" --body hang >/dev/null
sleep 0.3
child="$(cat "$TMP/hq-child" 2>/dev/null)"
left="$(pgrep -f "$TMP/bin/hq" 2>/dev/null | wc -l | tr -d ' ')"
if [ -n "$child" ] && ! kill -0 "$child" 2>/dev/null && [ "$left" = 0 ]; then
  ok "builder cut: no orphan processes"
else
  no "builder cut: no orphan processes (child ${child:-none}, $left hq left)"
  [ -z "$child" ] || kill -KILL "$child" 2>/dev/null
fi
[ "$(cat "$TMP/body")" = "hang" ] && ok "builder cut: passes through" || no "builder cut: passes through"

# Session id order matches core/scripts/lib/session-id.sh, so a Codex thread or
# a Grok session gets its own cache entry and later calls hit it.
nosid() {
  env -u HQ_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
    -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID "$@" bash "$WRAP" --body s >/dev/null
}
fresh; rm -f "$TMP/hq-calls"
nosid CODEX_THREAD_ID=thr-1
nosid CODEX_THREAD_ID=thr-1
[ "$(cat "$TMP/hq-calls")" = x ] && ok "session id: CODEX_THREAD_ID hits the cache" || no "session id: CODEX_THREAD_ID hits the cache"
nosid GROK_SESSION_ID=grok-1
nosid GROK_SESSION_ID=grok-1
[ "$(cat "$TMP/hq-calls")" = xx ] && ok "session id: GROK_SESSION_ID hits the cache" || no "session id: GROK_SESSION_ID hits the cache"
nosid CLAUDE_CODE_SESSION_ID=cc-1
nosid CLAUDE_CODE_SESSION_ID=cc-1 GROK_SESSION_ID=grok-1
[ "$(cat "$TMP/hq-calls")" = xxx ] && ok "session id: CLAUDE_CODE_SESSION_ID read and ranked first" || no "session id: CLAUDE_CODE_SESSION_ID read and ranked first"
nosid CODEX_THREAD_ID=thr-1 GROK_SESSION_ID=grok-2
[ "$(cat "$TMP/hq-calls")" = xxx ] && ok "session id: CODEX_THREAD_ID ranks above GROK_SESSION_ID" || no "session id: CODEX_THREAD_ID ranks above GROK_SESSION_ID"
nosid CODEX_THREAD_ID='bad/id' GROK_SESSION_ID=grok-1
[ "$(cat "$TMP/hq-calls")" = xxx ] && ok "session id: invalid value skipped" || no "session id: invalid value skipped"


left="$(find "$TMPDIR" -name 'hq-pr-body.*' -o -name 'hq-pr-fp.*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$left" = 0 ] && ok "temp files cleaned" || no "temp files cleaned ($left left)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
