#!/usr/bin/env bash
# Behavior test for core/scripts/hq-bug-submit.sh: the body file is deleted
# after success, after failure and on TERM; other files are never deleted.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WRAP="$ROOT/core/scripts/hq-bug-submit.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
if [ "${STUB_SLEEP:-}" = 1 ]; then sleep 30; fi
exit "${STUB_RC:-0}"
STUB
chmod +x "$TMP/bin/hq"
export PATH="$TMP/bin:$PATH"
fail() { echo "FAIL: $*" >&2; exit 1; }

f="$TMP/hq-feedback-body.ok"; : > "$f"
bash "$WRAP" hq feedback bug --title t --body-file "$f" || fail "success rc"
[ ! -e "$f" ] || fail "body kept after success"

f="$TMP/hq-feedback-body.err"; : > "$f"
set +e; STUB_RC=7 bash "$WRAP" hq feedback bug --title t --body-file "$f"; rc=$?; set -e
[ "$rc" = 7 ] || fail "rc not propagated ($rc)"
[ ! -e "$f" ] || fail "body kept after failure"

f="$TMP/hq-feedback-body.sig"; : > "$f"
STUB_SLEEP=1 bash "$WRAP" hq feedback bug --title t --body-file "$f" &
pid=$!
sleep 1
start=$SECONDS
kill -TERM "$pid"
set +e; wait "$pid"; rc=$?; set -e
[ "$rc" = 143 ] || fail "TERM rc ($rc)"
[ $((SECONDS - start)) -lt 10 ] || fail "TERM cleanup waited for the hung child"
[ ! -e "$f" ] || fail "body kept after TERM"

f="$TMP/hq-feedback-body.eq"; : > "$f"
bash "$WRAP" hq feedback bug --title t "--body-file=$f" || fail "eq form rc"
[ ! -e "$f" ] || fail "body kept for --body-file= form"

f="$TMP/notes.md"; : > "$f"
bash "$WRAP" hq feedback bug --title t --body-file "$f" || fail "other rc"
[ -e "$f" ] || fail "deleted a file not named hq-feedback-body.*"

: > "$TMP/target"
ln -s "$TMP/target" "$TMP/hq-feedback-body.link"
bash "$WRAP" hq feedback bug --title t --body-file "$TMP/hq-feedback-body.link" || fail "link rc"
[ -L "$TMP/hq-feedback-body.link" ] && [ -e "$TMP/target" ] || fail "removed a symlink or its target"

set +e; bash "$WRAP" touch "$TMP/should-not-exist"; rc=$?; set -e
[ "$rc" = 2 ] && [ ! -e "$TMP/should-not-exist" ] || fail "ran a non hq-feedback command"

# Step 2 of the skill resolves the wrapper by absolute path from any cwd, and
# fails before creating a body file when the wrapper is missing.
python3 - "$ROOT/.claude/skills/hq-bug/SKILL.md" "$TMP/step2.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
sec = text.split("### 2. Resolve the submit wrapper and allocate the body file", 1)[1].split("### 3.", 1)[0]
open(sys.argv[2], "w").write(re.search(r"```bash\n(.*?)\n```", sec, re.S).group(1) + "\n")
PY
mkdir -p "$TMP/hq/core/scripts" "$TMP/hq/repos/x/sub" "$TMP/home" "$TMP/elsewhere" "$TMP/tmpdir"
: > "$TMP/hq/core/core.yaml"; : > "$TMP/hq/core/scripts/hq-bug-submit.sh"
out="$(cd "$TMP/hq/repos/x/sub" && env -u HQ_ROOT HOME="$TMP/home" TMPDIR="$TMP/tmpdir" bash "$TMP/step2.sh")" || fail "step 2 failed from a nested cwd"
case "$out" in *"SUBMIT_PATH=$TMP/hq/core/scripts/hq-bug-submit.sh"*) ;; *) fail "step 2 printed no absolute wrapper path: $out" ;; esac
body="$(printf '%s\n' "$out" | sed -n 's/^BODY_PATH=//p')"
[ -f "$body" ] || fail "step 2 created no body file"
perm="$(ls -l "$body" | cut -c1-10)"
[ "$perm" = "-rw-------" ] || fail "body file mode is $perm"
out="$(cd "$TMP/elsewhere" && env HQ_ROOT="$TMP/hq" HOME="$TMP/home" TMPDIR="$TMP/tmpdir" bash "$TMP/step2.sh")" || fail "step 2 ignored HQ_ROOT"
case "$out" in *"SUBMIT_PATH=$TMP/hq/core/scripts/hq-bug-submit.sh"*) ;; *) fail "HQ_ROOT not used" ;; esac
out="$(cd "$TMP/hq/repos/x" && env HQ_ROOT="$TMP/elsewhere" HOME="$TMP/home" TMPDIR="$TMP/tmpdir" bash "$TMP/step2.sh")" || fail "bad HQ_ROOT blocked the walk-up"
case "$out" in *"SUBMIT_PATH=$TMP/hq/core/scripts/hq-bug-submit.sh"*) ;; *) fail "bad HQ_ROOT not skipped" ;; esac
mkdir -p "$TMP/home2/.hq" "$TMP/sp ace/core/scripts"
: > "$TMP/sp ace/core/core.yaml"; : > "$TMP/sp ace/core/scripts/hq-bug-submit.sh"
printf '%s \r\n' "$TMP/sp ace" > "$TMP/home2/.hq/root"
out="$(cd "$TMP/elsewhere" && env -u HQ_ROOT HOME="$TMP/home2" TMPDIR="$TMP/tmpdir" bash "$TMP/step2.sh")" || fail "CRLF ~/.hq/root with a space in the path was not used"
case "$out" in *"SUBMIT_PATH=$TMP/sp ace/core/scripts/hq-bug-submit.sh"*) ;; *) fail "~/.hq/root not used: $out" ;; esac
rm -f "$TMP"/tmpdir/hq-feedback-body.*
set +e; (cd "$TMP/elsewhere" && env -u HQ_ROOT HOME="$TMP/home" TMPDIR="$TMP/tmpdir" bash "$TMP/step2.sh" 2>"$TMP/err"); rc=$?; set -e
[ "$rc" = 1 ] || fail "step 2 outside HQ rc=$rc"
grep -q "cannot find core/scripts/hq-bug-submit.sh" "$TMP/err" || fail "step 2 error is unclear"
[ -z "$(ls "$TMP/tmpdir")" ] || fail "step 2 created a body file after failing"

echo "PASS: step 2 resolves the wrapper by absolute path and fails before mktemp outside HQ"
echo "PASS: hq-bug-submit deletes the body on success, failure and TERM; spares other files, symlinks and non-hq commands"
