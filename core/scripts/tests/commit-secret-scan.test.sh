#!/usr/bin/env bash
# hq-core: public
#
# Regression test for core/scripts/commit-secret-scan.sh.
#
# Runs in a sandbox: a temporary HOME, GIT_CONFIG_GLOBAL, GIT_CONFIG_NOSYSTEM=1
# and a fake HQ root, so the real machine's git config is never touched. Makes real `git commit`s.
# Fake secrets are random and never printed.
#
# Scanner: HQ_SECRET_SCAN_BIN when set, else a real hq CLI on PATH whose
# `hq scan secrets --help` names --staged (5.345.86+); otherwise a stub that
# flags GitHub-token shapes, so the wiring is still tested on CI machines with
# no hq CLI or an older one. An older CLI exits 0 on that --help (it prints the
# root help), so exit status alone does not prove the scanner exists.
#
# The fake HQ root has a space and a quote in its path, to prove the generated
# hook scripts quote it.
set -u
# Git hooks export these; a test run from inside a hook must not inherit them.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX
REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
has_scanner() { case "$("$@" scan secrets --help 2>&1)" in *--staged*) return 0 ;; esac; return 1; }
if [ -z "${HQ_SECRET_SCAN_BIN:-}" ] && ! { command -v hq >/dev/null 2>&1 && has_scanner hq; }; then
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
  export HQ_SECRET_SCAN_BIN="$T/stub-hq"
  echo "note: no hq CLI with \`hq scan secrets\` found; using a stub scanner"
fi
ROOT="$T/my hq's root"
export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/.gitconfig" XDG_CONFIG_HOME="$T/home/.config" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$ROOT/core/scripts" "$ROOT/core/settings" "$ROOT/repos"
mkdir -p "$ROOT/core/scripts/lib"
cp "$REAL/core/scripts/commit-secret-scan.sh" "$REAL/core/scripts/hq-fingerprint-hooks.sh" "$ROOT/core/scripts/"
cp "$REAL/core/scripts/lib/git-hooks-dispatcher.sh" "$REAL/core/scripts/lib/hq-cli-floor.sh" \
  "$REAL/core/scripts/lib/hq-cli-capability.sh" "$ROOT/core/scripts/lib/"
cp "$REAL/core/settings/commit-secret-scan.yaml" "$ROOT/core/settings/"
export HQ_ROOT="$ROOT"
S="$ROOT/core/scripts/commit-secret-scan.sh"
git -C "$T" config --global user.email t@example.invalid
git -C "$T" config --global user.name test
git -C "$T" config --global init.defaultBranch main

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
git -C "$T" config --global core.hooksPath "$T/prevhooks"
own=$(repo "$ROOT/repos/private/ownhooks"); mkdir -p "$own/.githooks"
printf '#!/bin/sh\necho own-hook-ran\n' >"$own/.githooks/pre-commit"; chmod +x "$own/.githooks/pre-commit"
git -C "$own" config core.hooksPath .githooks
dead=$(repo "$ROOT/repos/private/deadpath"); git -C "$dead" config core.hooksPath /nonexistent/old/hooks
# A repo with no hook folder of its own, sorted last: enable once failed with
# "could not write the backup" when the last repo listed had no hooksPath.
plain=$(repo "$ROOT/repos/private/zz-plain")

bash "$S" enable >/dev/null 2>&1
ok "enable wires the global hook" "$HOME/.hq/git-hooks" "$(git -C "$T" config --global --get core.hooksPath)"
ok "enable records the setting" "enabled: true" "$(grep '^enabled:' "$ROOT/personal/settings/commit-secret-scan.yaml")"
grep -qF ">>> HQ git hooks" "$XDG_CONFIG_HOME/husky/init.sh" && h=yes || h=no
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
# pr-check passes the repo, the base commit's allowlist and the history-copy
# root to a CLI that takes --allowlist-rev, so only allowlists already on the
# base apply. A CLI without it (even one with --snapshot-root, which would
# trust HEAD's allowlist) gets the plain file list.
for v in new mid old; do
  case "$v" in
    new) help="usage: hq scan secrets [--staged] [--repo <dir> [--allowlist-rev <rev>] [--snapshot-root <dir>]] [files...]" ;;
    mid) help="usage: hq scan secrets [--staged] [--repo <dir> [--snapshot-root <dir>]] [files...]" ;;
    old) help="usage: hq scan secrets [--staged] [files...]" ;;
  esac
  cat >"$T/argv-hq-$v" <<ARGV
#!/usr/bin/env bash
[ "\$1 \$2" = "scan secrets" ] || exit 2
shift 2
if [ "\${1:-}" = "--help" ]; then
  echo "$help"
  exit 0
fi
printf '%s\n' "\$@" >"$T/argv-$v"
ARGV
  chmod +x "$T/argv-hq-$v"
  (cd "$pr" && HQ_SECRET_SCAN_BIN="$T/argv-hq-$v" bash "$S" pr-check base >/dev/null 2>&1)
done
top=$(git -C "$pr" rev-parse --show-toplevel)
a1=$(sed -n 1p "$T/argv-new"); a2=$(sed -n 2p "$T/argv-new"); a3=$(sed -n 3p "$T/argv-new"); a4=$(sed -n 4p "$T/argv-new")
a5=$(sed -n 5p "$T/argv-new"); a6=$(sed -n 6p "$T/argv-new")
ok "pr-check passes --repo <top> to a new CLI" "--repo $top" "$a1 $a2"
ok "pr-check reads the allowlist from the base commit, not HEAD" "--allowlist-rev $(git -C "$pr" rev-parse base)" "$a3 $a4"
ok "pr-check passes --snapshot-root to a new CLI" "--snapshot-root" "$a5"
grep -qxF "$a6/$(git -C "$pr" rev-parse --short=12 HEAD~1)/t.py" "$T/argv-new" && s=yes || s=no
ok "history copies sit under the snapshot root as <commit>/<path>" yes "$s"
grep -qx -- '--repo' "$T/argv-mid" && o=yes || o=no
ok "pr-check sends no --repo to a CLI without --allowlist-rev" no "$o"
grep -qx -- '--repo' "$T/argv-old" && o=yes || o=no
ok "pr-check sends no --repo to an older CLI" no "$o"
# A CLI that advertises --range gets one call: --repo <top> --range
# <base_sha>..HEAD, with no snapshot file list. Its exit code passes through
# (0, 1, 2); any other non-zero code fails closed as 2.
cat >"$T/range-hq" <<RANGE
#!/usr/bin/env bash
[ "\$1 \$2" = "scan secrets" ] || exit 2
shift 2
if [ "\${1:-}" = "--help" ]; then
  echo "usage: hq scan secrets [--staged] [--repo <dir> [--range <base>[..<head>]] [--allowlist-rev <rev>] [--snapshot-root <dir>]] [files...]"
  exit 0
fi
printf '%s\n' "\$@" >"$T/argv-range"
exit "\$(cat "$T/range-rc")"
RANGE
chmod +x "$T/range-hq"
git -C "$pr" checkout -q added-then-deleted
for want in 0 1 2; do
  echo "$want" >"$T/range-rc"; rm -f "$T/argv-range"
  (cd "$pr" && HQ_SECRET_SCAN_BIN="$T/range-hq" bash "$S" pr-check base >/dev/null 2>&1)
  ok "pr-check passes the --range scan's exit $want through" "$want" $?
done
echo 127 >"$T/range-rc"
(cd "$pr" && HQ_SECRET_SCAN_BIN="$T/range-hq" bash "$S" pr-check base >/dev/null 2>&1)
ok "pr-check fails closed (2) when the --range scan exits 127" 2 $?
ok "pr-check calls --range <base_sha>..HEAD with --repo <top>" \
  "--repo|$top|--range|$(git -C "$pr" rev-parse base)..HEAD|" "$(tr '\n' '|' <"$T/argv-range")"
# An older CLI without --range still gets the snapshot scan.
rm -f "$T/argv-new"
(cd "$pr" && HQ_SECRET_SCAN_BIN="$T/argv-hq-new" bash "$S" pr-check base >/dev/null 2>&1)
grep -qx -- '--snapshot-root' "$T/argv-new" 2>/dev/null && s=yes || s=no
ok "pr-check keeps the snapshot scan for a CLI without --range" yes "$s"
grep -qx -- '--range' "$T/argv-new" 2>/dev/null && s=yes || s=no
ok "pr-check sends no --range to a CLI without it" no "$s"
# A help text that only mentions --range in prose (no "--range <...>" option)
# does not switch to the range scan.
cat >"$T/prose-hq" <<PROSE
#!/usr/bin/env bash
[ "\$1 \$2" = "scan secrets" ] || exit 2
shift 2
if [ "\${1:-}" = "--help" ]; then
  echo "usage: hq scan secrets [--staged] [--repo <dir> [--allowlist-rev <rev>] [--snapshot-root <dir>]] [files...]"
  echo "  --repo <dir>  With --range: the repo to scan"
  exit 0
fi
printf '%s\n' "\$@" >"$T/argv-prose"
PROSE
chmod +x "$T/prose-hq"
(cd "$pr" && HQ_SECRET_SCAN_BIN="$T/prose-hq" bash "$S" pr-check base >/dev/null 2>&1)
grep -qx -- '--range' "$T/argv-prose" 2>/dev/null && s=yes || s=no
ok "pr-check needs a --range <...> option, not a prose mention" no "$s"

# --- generated hook scripts quote the HQ path (it contains a space and a quote)
grep "dispatch pre-commit" "$HOME/.hq/git-hooks/pre-commit" | grep -qF "'$T/my hq'\\''s root'" && q=yes || q=no
ok "hook stub quotes the HQ path" yes "$q"

# --- disable restores everything
bash "$S" disable --dry-run >/dev/null 2>&1
ok "dry-run changes nothing" "$HOME/.hq/git-hooks" "$(git -C "$T" config --global --get core.hooksPath)"
bash "$S" disable >/dev/null 2>&1
ok "disable restores the previous global hook" "$T/prevhooks" "$(git -C "$T" config --global --get core.hooksPath)"
ok "disable restores own-path repo" ".githooks" "$(git -C "$own" config --get core.hooksPath)"
ok "disable removes the chain" "" "$(git -C "$own" config --get hq.chainHooksPath)"
ok "disable restores the dead path" "/nonexistent/old/hooks" "$(git -C "$dead" config --get core.hooksPath)"
grep -qF ">>> HQ git hooks" "$XDG_CONFIG_HOME/husky/init.sh" 2>/dev/null && h=present || h=removed
ok "disable removes the husky block" removed "$h"
ok "disable records the setting" "enabled: false" "$(grep '^enabled:' "$ROOT/personal/settings/commit-secret-scan.yaml")"

# --- shared dispatcher with the fingerprint trailer (hq-fingerprint-hooks.sh)
F="$ROOT/core/scripts/hq-fingerprint-hooks.sh"
backups() { ls "$HOME/.hq/git-hooks-backups"/backup-*.tsv 2>/dev/null | wc -l | tr -d ' '; }
bash "$S" enable >/dev/null 2>&1
out=$(bash "$S" enable 2>&1)
case "$out" in "Already on."*) ok "second enable is a no-op" yes yes ;; *) ok "second enable is a no-op" yes no ;; esac
ok "second enable takes no second backup" 1 "$(backups)"
bash "$F" enable >/dev/null 2>&1
ok "fingerprint enable reuses the wiring" 1 "$(backups)"
ok "fingerprint enable sets its switch" true "$(git -C "$T" config --global --get hq.hooks.fingerprint)"
bash "$S" disable >/dev/null 2>&1
ok "scan off keeps the dispatcher for the trailer" "$HOME/.hq/git-hooks" "$(git -C "$T" config --global --get core.hooksPath)"
ok "scan off records its switch as false" false "$(git -C "$T" config --global --get hq.hooks.secretScan)"
ok "scan status reads off" "commit secret scan: off" "$(bash "$S" status | head -1)"
grep -qF ">>> HQ git hooks" "$XDG_CONFIG_HOME/husky/init.sh" 2>/dev/null && h=present || h=removed
ok "husky block stays while the trailer is on" present "$h"
r=$(repo "$T/plain2"); fake >"$r/a.py"; git -C "$r" add a.py; git -C "$r" commit -q -m x >/dev/null 2>&1
ok "scan off: secret no longer blocked" 1 "$(commits "$r")"
bash "$F" disable >/dev/null 2>&1
ok "last feature off restores the global hook" "$T/prevhooks" "$(git -C "$T" config --global --get core.hooksPath)"
ok "last feature off restores own-path repo" ".githooks" "$(git -C "$own" config --get core.hooksPath)"
[ -e "$HOME/.hq/git-hooks/pre-commit" ] && st=present || st=removed
ok "last feature off removes the stubs" removed "$st"

# --- a machine wired by the older secret-scan-only script (no hq.hooks.* keys)
git -C "$T" config --global core.hooksPath "$HOME/.hq/git-hooks"
ok "legacy wiring counts as scan on" "commit secret scan: on" "$(bash "$S" status | head -1)"
bash "$F" enable >/dev/null 2>&1
ok "fingerprint enable records the legacy scan switch" true "$(git -C "$T" config --global --get hq.hooks.secretScan)"
ok "legacy scan still on after fingerprint enable" "commit secret scan: on" "$(bash "$S" status | head -1)"
git -C "$T" config --global --unset core.hooksPath; git -C "$T" config --global --remove-section hq.hooks

# --- enable fails closed without the scanner
HQ_SECRET_SCAN_BIN=false bash "$S" enable >/dev/null 2>&1; ok "enable refuses without the scanner" 2 $?

# --- an hq CLI older than 5.345.86: no `scan` command, but `scan secrets --help`
# exits 0 with the root help. It must count as missing, so a commit is reported
# as needing a CLI update, never as a possible secret.
cat >"$T/old-hq" <<'OLD'
#!/usr/bin/env bash
case " $* " in
  *" --help "*) echo "Usage: hq [options] [command]"; echo "Commands: run, secrets, sync"; exit 0 ;;
esac
echo "error: unknown command '${1:-}'" >&2
exit 1
OLD
chmod +x "$T/old-hq"
HQ_SECRET_SCAN_BIN="$T/old-hq" bash "$S" enable >/dev/null 2>&1; ok "enable refuses an hq CLI without scan" 2 $?
og=$(repo "$T/oldcli"); echo hi >"$og/a.txt"; git -C "$og" add a.txt
out=$(cd "$og" && HQ_SECRET_SCAN_BIN="$T/old-hq" bash "$S" gate 2>&1); rc=$?
ok "old CLI: gate blocks" 1 "$rc"
case "$out" in *"Update the hq CLI"*) ok "old CLI: gate asks for a CLI update" yes yes ;; *) ok "old CLI: gate asks for a CLI update" yes no ;; esac
case "$out" in *"possible secret"*) ok "old CLI: gate does not claim a secret" no yes ;; *) ok "old CLI: gate does not claim a secret" no no ;; esac

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
