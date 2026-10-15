#!/usr/bin/env bash
# hq-core: public
#
# Regression test: the git hook dispatcher works from an HQ root whose path has
# an apostrophe, a space and a double quote (US-003).
#
# 1. Copies core/scripts, core/settings and core/hooks into such a root and
#    runs hq-fingerprint-hook.test.sh and commit-secret-scan.test.sh from it,
#    with the same bash that runs this file.
# 2. Wires the hooks with HQ_ROOT set to that root (plus $ and a backslash),
#    then checks that every generated stub parses, embeds the root as one
#    single-quoted word, and runs the gate: a clean commit passes and a fake
#    secret is blocked.
#
# Runs in a sandbox: temporary HOME, GIT_CONFIG_GLOBAL and GIT_CONFIG_NOSYSTEM=1.
# Fake secrets are random and never printed.
set -u
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX
REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
BASH_BIN="${BASH:-bash}"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1 (want $2, got $3)"; fi; }

# --- 1. both suites from a quoted root
Q="$T/hq it's \"quoted\" root"
mkdir -p "$Q/core"
cp -R "$REAL/core/scripts" "$REAL/core/settings" "$REAL/core/hooks" "$Q/core/"
for t in hq-fingerprint-hook commit-secret-scan; do
  out="$("$BASH_BIN" "$Q/core/scripts/tests/$t.test.sh" 2>&1)"; rc=$?
  ok "$t.test.sh passes from a quoted root" 0 "$rc"
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" | grep -E '^FAIL|passed' | sed 's/^/    /'; fi
done

# --- 2. generated stubs for a root with ', space, ", $ and \
R="$T/odd 'q' \"dq\" \$HOME \\b root"
mkdir -p "$R/core/scripts/lib" "$R/core/settings"
cp "$REAL/core/scripts/commit-secret-scan.sh" "$REAL/core/scripts/hq-fingerprint-hooks.sh" "$R/core/scripts/"
cp "$REAL/core/scripts/lib/git-hooks-dispatcher.sh" "$REAL/core/scripts/lib/hq-cli-floor.sh" \
  "$REAL/core/scripts/lib/hq-cli-capability.sh" "$R/core/scripts/lib/"
cp "$REAL/core/settings/commit-secret-scan.yaml" "$R/core/settings/"
cat >"$T/stub-hq" <<'STUB'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "scan secrets" ] || exit 2
shift 2
[ "${1:-}" = "--help" ] && { echo "usage: hq scan secrets [--staged] [files...]"; exit 0; }
pat='gh''p_[A-Za-z0-9]{36}'
if [ "${1:-}" = "--staged" ]; then
  git diff --cached -U0 | grep -qE "^\+.*$pat" && { echo "stub: possible secret" >&2; exit 1; }
  exit 0
fi
grep -qE "$pat" "$@" 2>/dev/null && { echo "stub: possible secret" >&2; exit 1; }
exit 0
STUB
chmod +x "$T/stub-hq"
export HQ_SECRET_SCAN_BIN="$T/stub-hq" HQ_ROOT="$R"
export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/.gitconfig" XDG_CONFIG_HOME="$T/home/.config" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
git -C "$T" config --global user.email t@example.invalid
git -C "$T" config --global user.name test
git -C "$T" config --global init.defaultBranch main

"$BASH_BIN" "$R/core/scripts/commit-secret-scan.sh" enable >/dev/null 2>&1
ok "enable succeeds from the odd root" 0 $?
for n in pre-commit commit-msg; do
  f="$HOME/.hq/git-hooks/$n"
  "$BASH_BIN" -n "$f" 2>/dev/null && st=yes || st=no
  ok "$n stub parses" yes "$st"
  # Run the stub's own assignments (hq_p first, the exec line reads it) and
  # compare the HQ_ROOT value they yield.
  line="$(grep ' dispatch ' "$f")"
  got="$(eval "$(grep '^hq_p=' "$f")"; eval "${line%% exec *}"; printf '%s' "$HQ_ROOT")"
  ok "$n stub embeds the exact HQ root" "$R" "$got"
done
hl="$(grep -F " husky \"" "$XDG_CONFIG_HOME/husky/init.sh" 2>/dev/null)"
hl="${hl#*bash }"; hl="${hl%% husky *}"
got="$(eval "printf '%s' $hl")"
ok "husky block embeds the exact dispatcher path" "$R/core/scripts/lib/git-hooks-dispatcher.sh" "$got"

r="$T/repo"; mkdir -p "$r"; git -C "$r" init -q
echo hi >"$r/a.txt"; git -C "$r" add a.txt
git -C "$r" commit -q -m clean >/dev/null 2>&1
ok "clean commit passes through the stub" 1 "$(git -C "$r" rev-list --count HEAD 2>/dev/null || echo 0)"
printf 'token = "%s"\n' "gh""p_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)" >"$r/s.py"
git -C "$r" add s.py; git -C "$r" commit -q -m leak >/dev/null 2>&1
ok "secret commit is blocked through the stub" 1 "$(git -C "$r" rev-list --count HEAD 2>/dev/null || echo 0)"

"$BASH_BIN" "$R/core/scripts/commit-secret-scan.sh" disable >/dev/null 2>&1
ok "disable succeeds from the odd root" 0 $?

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
