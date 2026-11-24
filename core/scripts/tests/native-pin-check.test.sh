#!/usr/bin/env bash
# Tests for core/scripts/ci/native-pin-check.sh. Builds a throwaway git
# repository and a stand-in hq-cli pin tree, then checks which pull request
# diffs pass and which fail.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../ci/native-pin-check.sh"
[ -f "$CHECK" ] || { echo "FAIL: missing $CHECK" >&2; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/native-pin-check-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

if command -v sha256sum >/dev/null 2>&1; then
  sha() { sha256sum "$1" | awk '{print $1}'; }
else
  sha() { shasum -a 256 "$1" | awk '{print $1}'; }
fi

pass=0
failures=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
not_ok() { failures=$((failures + 1)); printf 'not ok - %s\n' "$1"; }

repo="$tmp/repo"
pins="$tmp/hq-cli"
mkdir -p "$repo/.claude/hooks" "$repo/core/scripts" "$repo/docs" "$pins/crates/hq-hook/src"
g() { git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
g init -q -b main

printf '#!/bin/bash\necho guard v1\n' > "$repo/.claude/hooks/pinned-guard.sh"
printf '#!/bin/bash\necho lib v1\n' > "$repo/core/scripts/pinned-lib.sh"
printf '#!/bin/bash\necho unpinned\n' > "$repo/.claude/hooks/other.sh"
printf 'notes\n' > "$repo/docs/readme.md"
: > "$repo/docs/empty.txt"
g add -A
g commit -q -m base
base="$(g rev-parse HEAD)"

guard_v1="$(sha "$repo/.claude/hooks/pinned-guard.sh")"
lib_v1="$(sha "$repo/core/scripts/pinned-lib.sh")"
empty="$(sha "$repo/docs/empty.txt")"

# The guard is pinned in core-pins.json, the library only in a Rust table,
# and the empty file's hash appears in the source (it must never count).
cat > "$pins/crates/hq-hook/core-pins.json" <<EOF
{"schema":1,"releases":{"1.0.0":{"files":{".claude/hooks/pinned-guard.sh":{"sha256":"$guard_v1"}}}}}
EOF
cat > "$pins/crates/hq-hook/src/ports.rs" <<EOF
const PINS: &[(&str, &[&str])] = &[("core/scripts/pinned-lib.sh", &["$lib_v1"]), ("x", &["$empty"])];
EOF

# branch NAME MESSAGE CHANGE...: a branch off base with one commit.
branch() {
  local name="$1" message="$2"
  shift 2
  g checkout -q -B "$name" "$base"
  "$@"
  g add -A
  g commit -q --allow-empty -m "$message"
  g rev-parse HEAD
}
edit_guard() { printf '#!/bin/bash\necho guard v2\n' > "$repo/.claude/hooks/pinned-guard.sh"; }
edit_lib() { printf '#!/bin/bash\necho lib v2\n' > "$repo/core/scripts/pinned-lib.sh"; }
edit_other() { printf '#!/bin/bash\necho unpinned v2\n' > "$repo/.claude/hooks/other.sh"; printf 'more\n' >> "$repo/docs/readme.md"; }
edit_empty() { printf 'now has text\n' > "$repo/docs/empty.txt"; }
delete_guard() { rm "$repo/.claude/hooks/pinned-guard.sh"; }
rename_guard() { g mv .claude/hooks/pinned-guard.sh .claude/hooks/renamed-guard.sh; }
chmod_guard() { chmod +x "$repo/.claude/hooks/pinned-guard.sh"; }
add_new() { printf 'new\n' > "$repo/.claude/hooks/new-hook.sh"; }

# expect EXIT DESCRIPTION HEAD [BODY] [PINS]
expect() {
  local want="$1" desc="$2" head="$3" body="${4:-}" pin_dir="${5:-$pins}"
  local args=(--repo "$repo" --base "$base" --head "$head" --pins "$pin_dir")
  if [ -n "$body" ]; then
    printf '%s' "$body" > "$tmp/body.txt"
    args+=(--pr-body-file "$tmp/body.txt")
  fi
  local got=0
  env -u GITHUB_ACTIONS bash "$CHECK" "${args[@]}" > "$tmp/out.txt" 2>&1 || got=$?
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    not_ok "$desc (exit $got, wanted $want)"
    sed 's/^/    /' "$tmp/out.txt"
  fi
}

h_guard="$(branch guard 'change the guard' edit_guard)"
expect 1 "changing a pinned hook script without an acknowledgement fails" "$h_guard"
if grep -qF ".claude/hooks/pinned-guard.sh" "$tmp/out.txt" && grep -qF "crates/hq-hook/core-pins.json" "$tmp/out.txt"; then
  ok "the failure names the file and where hq-cli pins it"
else
  not_ok "the failure names the file and where hq-cli pins it"; sed 's/^/    /' "$tmp/out.txt"
fi
new_guard="$(sha "$repo/.claude/hooks/pinned-guard.sh")"
if grep -qF "$new_guard" "$tmp/out.txt"; then ok "the failure prints the new SHA-256"; else not_ok "the failure prints the new SHA-256"; fi

expect 0 "a body line 'Native-pin: pending hq-cli#N' acknowledges it" "$h_guard" $'Summary\r\n\r\nNative-pin: pending hq-cli#3480\r\n'
expect 0 "an owner/repo reference acknowledges it" "$h_guard" "Native-pin: pending indigoai-us/hq-cli#12"
expect 0 "a pull request URL acknowledges it" "$h_guard" "Native-pin: pending https://github.com/indigoai-us/hq-cli/pull/12"
expect 0 "a bash-fallback line with a reason acknowledges it" "$h_guard" "Native-pin: bash-fallback the port is being rewritten"
expect 1 "a bash-fallback line with no reason does not" "$h_guard" "Native-pin: bash-fallback"
expect 1 "'pending' with no hq-cli PR does not" "$h_guard" "Native-pin: pending"
expect 1 "a PR in another repository does not" "$h_guard" "Native-pin: pending indigoai-us/hq-core#5"
expect 1 "the line must start the line" "$h_guard" "see Native-pin: pending hq-cli#5"

h_trailer="$(branch trailer $'change the guard\n\nNative-pin: pending hq-cli#77' edit_guard)"
expect 0 "a commit message trailer acknowledges it" "$h_trailer"

h_lib="$(branch lib 'change the library' edit_lib)"
expect 1 "a file pinned only in a Rust pin table fails too" "$h_lib"

h_other="$(branch other 'unrelated change' edit_other)"
expect 0 "an unrelated change passes" "$h_other"

h_empty="$(branch empty 'fill an empty file' edit_empty)"
expect 0 "the empty file's hash is not treated as a pin" "$h_empty"

h_new="$(branch new 'add a hook' add_new)"
expect 0 "a new file passes" "$h_new"

h_chmod="$(branch chmod 'mode only' chmod_guard)"
expect 0 "a mode-only change to a pinned file passes" "$h_chmod"

h_delete="$(branch delete 'delete the guard' delete_guard)"
expect 1 "deleting a pinned file fails" "$h_delete"
expect 0 "deleting a pinned file passes with an acknowledgement" "$h_delete" "Native-pin: bash-fallback the hook is retired"

h_rename="$(branch rename 'rename the guard' rename_guard)"
expect 1 "renaming a pinned file fails (the old path disappears)" "$h_rename"

# hq-cli already pins the new bytes: the pin landed first.
pins_ahead="$tmp/hq-cli-ahead"
cp -R "$pins" "$pins_ahead"
printf '// new pin\nconst NEXT: &str = "%s";\n' "$new_guard" >> "$pins_ahead/crates/hq-hook/src/ports.rs"
expect 0 "passes when hq-cli already pins the new bytes" "$h_guard" "" "$pins_ahead"

# run_check EXIT DESCRIPTION ARGS...: run the check with explicit arguments.
run_check() {
  local want="$1" desc="$2" got=0
  shift 2
  env -u GITHUB_ACTIONS bash "$CHECK" "$@" > "$tmp/out.txt" 2>&1 || got=$?
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    not_ok "$desc (exit $got, wanted $want)"
    sed 's/^/    /' "$tmp/out.txt"
  fi
}

# Acknowledgement lines that must not count.
expect 1 "the <reason> placeholder from the failure message does not acknowledge" "$h_guard" "Native-pin: bash-fallback <reason>"
expect 1 "a one-word bash-fallback reason does not acknowledge" "$h_guard" "Native-pin: bash-fallback ."
expect 1 "hq-cli#0 does not acknowledge" "$h_guard" "Native-pin: pending hq-cli#0"
expect 1 "a line inside an HTML comment does not acknowledge" "$h_guard" $'Summary\n<!--\nNative-pin: pending hq-cli#5\n-->\n'
expect 1 "a line inside a one-line HTML comment does not acknowledge" "$h_guard" "<!-- Native-pin: pending hq-cli#5 -->"
expect 1 "a line inside a fenced code block does not acknowledge" "$h_guard" $'```\nNative-pin: pending hq-cli#5\n```\n'
expect 0 "a line after a closed HTML comment and code fence still acknowledges" "$h_guard" $'<!-- template -->\n```\nexample\n```\nNative-pin: pending hq-cli#5\n'

# The base branch moved on after the PR branched. The check compares the
# merge result with the current base, as the pull_request merge commit does.
g checkout -q -B main "$base"
edit_lib
g add -A
g commit -q -m "main changes the library"
main_moved="$(g rev-parse HEAD)"
g merge -q --no-ff --no-edit -m "merge other" "$h_other" > /dev/null
merge_other="$(g rev-parse HEAD)"
run_check 0 "a change the base branch made after the branch point is not counted" \
  --repo "$repo" --base "$main_moved" --head "$merge_other" --pins "$pins"

# Stale branch: main rewrote a pinned file and hq-cli pins main's bytes; a
# branch cut before that edits another line of the same file. The merge
# changes main's pinned bytes, so it must fail.
printf 'line 1 v0\nline 2\nline 3\nline 4\nline 5 v0\n' > "$repo/core/scripts/multi.sh"
g checkout -q -B stale-base "$base"
g add -A
g commit -q -m "add multi.sh"
stale_base="$(g rev-parse HEAD)"
printf 'line 1 v1\nline 2\nline 3\nline 4\nline 5 v0\n' > "$repo/core/scripts/multi.sh"
g commit -q -am "main ports multi.sh v1"
stale_main="$(g rev-parse HEAD)"
multi_v1="$(sha "$repo/core/scripts/multi.sh")"
g checkout -q -B stale-pr "$stale_base"
printf 'line 1 v0\nline 2\nline 3\nline 4\nline 5 pr\n' > "$repo/core/scripts/multi.sh"
g commit -q -am "stale branch edits line 5"
stale_pr="$(g rev-parse HEAD)"
g checkout -q stale-base
g reset -q --hard "$stale_main"
g merge -q --no-ff --no-edit -m "merge stale-pr" "$stale_pr" > /dev/null
stale_merge="$(g rev-parse HEAD)"
pins_stale="$tmp/hq-cli-stale"
cp -R "$pins" "$pins_stale"
printf 'const MULTI: &str = "%s";\n' "$multi_v1" >> "$pins_stale/crates/hq-hook/src/ports.rs"
run_check 1 "a stale branch that changes the base's newly pinned bytes fails" \
  --repo "$repo" --base "$stale_main" --head "$stale_merge" --pins "$pins_stale"
g checkout -q -B stale-pr2 "$stale_base"
printf 'line 1 v0\nline 2\nline 3\nline 4\nline 5 pr2\n' > "$repo/core/scripts/multi.sh"
g commit -q -am $'stale branch edits line 5 again\n\nNative-pin: pending hq-cli#9'
g checkout -q -B stale-main2 "$stale_main"
g merge -q --no-ff --no-edit -m "merge stale-pr2" stale-pr2 > /dev/null
stale_merge2="$(g rev-parse HEAD)"
run_check 0 "a commit trailer on the merged branch acknowledges the stale-branch change" \
  --repo "$repo" --base "$stale_main" --head "$stale_merge2" --pins "$pins_stale"

# A path with commas (as core/hooks/PreToolUse/10-Edit,Write,MultiEdit--*.sh
# has) is escaped in the annotation.
g checkout -q -B comma-base "$base"
mkdir -p "$repo/core/hooks/PreToolUse"
printf 'echo comma v1\n' > "$repo/core/hooks/PreToolUse/10-Edit,Write--guard.sh"
g add -A
g commit -q -m "add comma path"
comma_base="$(g rev-parse HEAD)"
comma_v1="$(sha "$repo/core/hooks/PreToolUse/10-Edit,Write--guard.sh")"
printf 'echo comma v2\n' > "$repo/core/hooks/PreToolUse/10-Edit,Write--guard.sh"
g commit -q -am "edit comma path"
comma_head="$(g rev-parse HEAD)"
pins_comma="$tmp/hq-cli-comma"
cp -R "$pins" "$pins_comma"
printf 'const COMMA: &str = "%s";\n' "$comma_v1" >> "$pins_comma/crates/hq-hook/src/ports.rs"
got=0
GITHUB_ACTIONS=true bash "$CHECK" --repo "$repo" --base "$comma_base" --head "$comma_head" --pins "$pins_comma" > "$tmp/out.txt" 2>&1 || got=$?
if [ "$got" = 1 ] && grep -qF "::error file=core/hooks/PreToolUse/10-Edit%2CWrite--guard.sh,title=" "$tmp/out.txt"; then
  ok "a path with commas is escaped in the error annotation"
else
  not_ok "a path with commas is escaped in the error annotation (exit $got)"; sed 's/^/    /' "$tmp/out.txt"
fi

# A pinned file replaced by a directory of the same name is a removal.
g checkout -q -B to-dir "$base"
g rm -q .claude/hooks/pinned-guard.sh
mkdir -p "$repo/.claude/hooks/pinned-guard.sh"
printf 'x\n' > "$repo/.claude/hooks/pinned-guard.sh/inner"
g add -A
g commit -q -m "replace the guard with a directory"
run_check 1 "replacing a pinned file with a directory fails" \
  --repo "$repo" --base "$base" --head "$(g rev-parse HEAD)" --pins "$pins"

# A blob-less partial clone whose remote is gone cannot read the base copy of
# a changed file. That is an input error, never a pass.
g config uploadpack.allowFilter true
g config uploadpack.allowAnySHA1InWant true
partial="$tmp/partial"
git clone -q --filter=blob:none --no-checkout "file://$repo" "$partial" 2>/dev/null
mv "$repo" "$tmp/repo-moved"
if git -C "$partial" rev-parse --verify --quiet "$h_guard^{commit}" > /dev/null \
  && ! git -C "$partial" cat-file -e "$base:.claude/hooks/pinned-guard.sh" 2>/dev/null; then
  ok "the partial clone has the commits but not the blobs"
else
  not_ok "the partial clone has the commits but not the blobs"
fi
run_check 2 "a blob the partial clone cannot fetch is an input error" \
  --repo "$partial" --base "$base" --head "$h_guard" --pins "$pins"
if grep -qF "cannot read" "$tmp/out.txt"; then
  ok "the error says the files cannot be read"
else
  not_ok "the error says the files cannot be read"; sed 's/^/    /' "$tmp/out.txt"
fi
run_check 2 "an unrelated change in that clone is an input error too, not a pass" \
  --repo "$partial" --base "$base" --head "$h_other" --pins "$pins"
# In Actions, an input error raised inside a command substitution still
# reaches the log as an error annotation.
got=0
GITHUB_ACTIONS=true bash "$CHECK" --repo "$partial" --base "$base" --head "$h_guard" --pins "$pins" > /dev/null 2> "$tmp/err.txt" || got=$?
if [ "$got" = 2 ] && grep -qF "::error title=native-pin-check::cannot read" "$tmp/err.txt"; then
  ok "in Actions an input error is an error annotation on stderr"
else
  not_ok "in Actions an input error is an error annotation on stderr (exit $got)"; sed 's/^/    /' "$tmp/err.txt"
fi
mv "$tmp/repo-moved" "$repo"

empty_pins="$tmp/no-pins"
mkdir -p "$empty_pins"
expect 2 "a missing hq-cli pin tree is an input error, not a pass" "$h_other" "" "$empty_pins"
mkdir -p "$empty_pins/crates/hq-hook/src"
printf '{}\n' > "$empty_pins/crates/hq-hook/core-pins.json"
expect 2 "a pin tree that names no hash is an input error" "$h_other" "" "$empty_pins"

got=0
env -u GITHUB_ACTIONS bash "$CHECK" --repo "$repo" --base "$base" > /dev/null 2>&1 || got=$?
if [ "$got" = 2 ]; then ok "missing arguments exit 2"; else not_ok "missing arguments exit 2 (exit $got)"; fi

got=0
GITHUB_ACTIONS=true bash "$CHECK" --repo "$repo" --base "$base" --head "$h_guard" --pins "$pins" > "$tmp/out.txt" 2>&1 || got=$?
if [ "$got" = 1 ] && grep -qF "::error file=.claude/hooks/pinned-guard.sh" "$tmp/out.txt"; then
  ok "in Actions the failure is an error annotation on the file"
else
  not_ok "in Actions the failure is an error annotation on the file (exit $got)"; sed 's/^/    /' "$tmp/out.txt"
fi

printf '%d passed, %d failed\n' "$pass" "$failures"
[ "$failures" -eq 0 ]
