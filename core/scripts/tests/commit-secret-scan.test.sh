#!/usr/bin/env bash
# hq-core: public
#
# Regression test for core/scripts/commit-secret-scan.sh.
#
# Runs in a sandbox: a temporary HOME, GIT_CONFIG_GLOBAL and fake HQ root, so
# the real machine's git config is never touched. Makes real `git commit`s.
# Fake secrets are random and never printed.
#
# Scanner: a real hq CLI with `hq scan secrets` (5.345.86+) when one is on PATH
# or in HQ_SECRET_SCAN_BIN; otherwise a stub that flags GitHub-token shapes, so
# the wiring is still tested on CI machines without the hq CLI.
#
# The fake HQ root has a space and a quote in its path, to prove the generated
# hook scripts quote it.
set -u
REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
if [ -z "${HQ_SECRET_SCAN_BIN:-}" ] && ! command -v hq >/dev/null 2>&1; then
  cat >"$T/stub-hq" <<'STUB'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "scan secrets" ] || exit 2
shift 2
[ "${1:-}" = "--help" ] && exit 0
pat='gh''p_[A-Za-z0-9]{36}'
if [ "${1:-}" = "--staged" ]; then
  git diff --cached -U0 | grep -qE "^\+.*$pat" && { echo "stub: possible secret" >&2; exit 1; }
  exit 0
fi
grep -qE "$pat" "$@" 2>/dev/null && { echo "stub: possible secret" >&2; exit 1; }
exit 0
STUB
  chmod +x "$T/stub-hq"
  export HQ_SECRET_SCAN_BIN="$T/stub-hq"
  echo "note: no hq CLI found; using a stub scanner"
fi
ROOT="$T/my hq's root"
export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/.gitconfig" XDG_CONFIG_HOME="$T/home/.config"
mkdir -p "$HOME" "$ROOT/core/scripts" "$ROOT/core/settings" "$ROOT/repos"
cp "$REAL/core/scripts/commit-secret-scan.sh" "$ROOT/core/scripts/"
cp "$REAL/core/settings/commit-secret-scan.yaml" "$ROOT/core/settings/"
export HQ_ROOT="$ROOT"
S="$ROOT/core/scripts/commit-secret-scan.sh"
git config --global user.email t@example.invalid
git config --global user.name test
git config --global init.defaultBranch main

pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1 (want $2, got $3)"; fi; }
rnd() { LC_ALL=C tr -dc "$1" </dev/urandom | head -c "$2"; }
repo() { local d="$1"; mkdir -p "$d"; git -C "$d" init -q; echo "$d"; }
fake() { printf 'token = "%s"\n' "gh""p_$(rnd 'A-Za-z0-9' 36)"; }
commits() { git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }

# --- off by default
ok "default setting is off" "commit secret scan: off" "$(bash "$S" status | head -1)"
r=$(repo "$T/plain0"); fake >"$r/a.py"; git -C "$r" add a.py; git -C "$r" commit -q -m x >/dev/null 2>&1
ok "off: nothing blocks" 1 "$(commits "$r")"

# --- existing global hook folder and own-path repos before enable
mkdir -p "$T/prevhooks"; printf '#!/bin/sh\necho prev-global-ran\n' >"$T/prevhooks/pre-commit"; chmod +x "$T/prevhooks/pre-commit"
git config --global core.hooksPath "$T/prevhooks"
own=$(repo "$ROOT/repos/private/ownhooks"); mkdir -p "$own/.githooks"
printf '#!/bin/sh\necho own-hook-ran\n' >"$own/.githooks/pre-commit"; chmod +x "$own/.githooks/pre-commit"
git -C "$own" config core.hooksPath .githooks
dead=$(repo "$ROOT/repos/private/deadpath"); git -C "$dead" config core.hooksPath /nonexistent/old/hooks
# A repo with no hook folder of its own, sorted last: enable once failed with
# "could not write the backup" when the last repo listed had no hooksPath.
plain=$(repo "$ROOT/repos/private/zz-plain")

bash "$S" enable >/dev/null 2>&1
ok "enable wires the global hook" "$HOME/.hq/git-hooks" "$(git config --global --get core.hooksPath)"
ok "enable records the setting" "enabled: true" "$(grep '^enabled:' "$ROOT/personal/settings/commit-secret-scan.yaml")"
grep -qF ">>> HQ commit secret scan" "$XDG_CONFIG_HOME/husky/init.sh" && h=yes || h=no
ok "enable adds the husky block" yes "$h"

# --- global-hook repo
r=$(repo "$T/plain1"); v=$(fake); printf '%s\n' "$v" >"$r/a.py"; git -C "$r" add a.py
out=$(git -C "$r" commit -q -m x 2>&1); ok "secret commit blocked" 0 "$(commits "$r")"
case "$out" in *"${v:9:30}"*) ok "value hidden" hidden printed ;; *) ok "value hidden" hidden hidden ;; esac
case "$out" in *"hq secrets"*) ok "block message points to hq secrets" yes yes ;; *) ok "block message points to hq secrets" yes no ;; esac
echo hi >"$r/b.txt"; git -C "$r" reset -q; git -C "$r" add b.txt
out=$(git -C "$r" commit -q -m clean 2>&1); ok "clean commit passes" 1 "$(commits "$r")"
case "$out" in *prev-global-ran*) ok "previous global hook still runs" yes yes ;; *) ok "previous global hook still runs" yes no ;; esac

# --- own-path repo is chained, its hook still runs
ok "own-path repo moved to chain" ".githooks" "$(git -C "$own" config --get hq.chainHooksPath)"
echo hi >"$own/a.txt"; git -C "$own" add a.txt
out=$(git -C "$own" commit -q -m x 2>&1); ok "own-path clean commit passes" 1 "$(commits "$own")"
case "$out" in *own-hook-ran*) ok "own hook runs after scan" yes yes ;; *) ok "own hook runs after scan" yes no ;; esac
fake >"$own/s.py"; git -C "$own" add s.py; git -C "$own" commit -q -m x >/dev/null 2>&1
ok "own-path secret blocked" 1 "$(commits "$own")"
ok "dead hook path cleared" "" "$(git -C "$dead" config --local --get core.hooksPath)"

# --- husky-style repo: the init.sh block runs the gate
hk=$(repo "$T/husky"); mkdir -p "$hk/.husky/_"
printf 'echo husky-own\n' >"$hk/.husky/pre-commit"
cat >"$hk/.husky/_/pre-commit" <<'EOF'
#!/usr/bin/env sh
n=$(basename "$0"); s=$(dirname "$(dirname "$0")")/$n
[ ! -f "$s" ] && exit 0
i="${XDG_CONFIG_HOME:-$HOME/.config}/husky/init.sh"
[ -f "$i" ] && . "$i"
sh -e "$s" "$@"
EOF
chmod +x "$hk/.husky/_/pre-commit"; git -C "$hk" config core.hooksPath .husky/_
fake >"$hk/s.py"; git -C "$hk" add s.py; git -C "$hk" commit -q -m x >/dev/null 2>&1
ok "husky repo secret blocked" 0 "$(commits "$hk")"

# --- pr-check
pr=$(repo "$T/pr"); echo base >"$pr/a.txt"; git -C "$pr" add a.txt; git -C "$pr" commit -q -m base >/dev/null 2>&1
git -C "$pr" branch -q base; git -C "$pr" checkout -q -b feature
fake >"$pr/s.py"; git -C "$pr" add s.py; git -C "$pr" commit -q --no-verify -m leak >/dev/null 2>&1
(cd "$pr" && bash "$S" pr-check base >/dev/null 2>&1); ok "pr-check finds a secret committed with --no-verify" 1 $?
git -C "$pr" checkout -q base; git -C "$pr" checkout -q -b clean; echo ok >"$pr/b.txt"; git -C "$pr" add b.txt; git -C "$pr" commit -q -m ok >/dev/null 2>&1
(cd "$pr" && bash "$S" pr-check base >/dev/null 2>&1); ok "pr-check passes a clean branch" 0 $?
# A secret committed and deleted later on the branch is still in history.
git -C "$pr" checkout -q base; git -C "$pr" checkout -q -b added-then-deleted
fake >"$pr/t.py"; git -C "$pr" add t.py; git -C "$pr" commit -q --no-verify -m leak >/dev/null 2>&1
git -C "$pr" rm -q t.py; git -C "$pr" commit -q -m "remove it" >/dev/null 2>&1
(cd "$pr" && bash "$S" pr-check base >/dev/null 2>&1); ok "pr-check finds a secret deleted later on the branch" 1 $?

# --- generated hook scripts quote the HQ path (it contains a space and a quote)
head -2 "$HOME/.hq/git-hooks/pre-commit" | tail -1 | grep -qF "my\ hq\'s\ root" && q=yes || q=no
ok "hook stub quotes the HQ path" yes "$q"

# --- disable restores everything
bash "$S" disable --dry-run >/dev/null 2>&1
ok "dry-run changes nothing" "$HOME/.hq/git-hooks" "$(git config --global --get core.hooksPath)"
bash "$S" disable >/dev/null 2>&1
ok "disable restores the previous global hook" "$T/prevhooks" "$(git config --global --get core.hooksPath)"
ok "disable restores own-path repo" ".githooks" "$(git -C "$own" config --get core.hooksPath)"
ok "disable removes the chain" "" "$(git -C "$own" config --get hq.chainHooksPath)"
ok "disable restores the dead path" "/nonexistent/old/hooks" "$(git -C "$dead" config --get core.hooksPath)"
grep -qF ">>> HQ commit secret scan" "$XDG_CONFIG_HOME/husky/init.sh" && h=present || h=removed
ok "disable removes the husky block" removed "$h"
ok "disable records the setting" "enabled: false" "$(grep '^enabled:' "$ROOT/personal/settings/commit-secret-scan.yaml")"

# --- enable fails closed without the scanner
HQ_SECRET_SCAN_BIN=false bash "$S" enable >/dev/null 2>&1; ok "enable refuses without the scanner" 2 $?

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
