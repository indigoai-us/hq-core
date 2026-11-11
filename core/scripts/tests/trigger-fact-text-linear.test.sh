#!/usr/bin/env bash
# hq-core: public
# trigger-fact-text.awk regression: (a) a 1 MB single-line input finishes in
# every mode within a generous bound (the old per-match substr() loops were
# quadratic and took tens of seconds), and (b) a fixed set of inputs keeps
# producing the same facts, order and exit status in every mode, including
# with the segment limit forced small so every re-split path runs.
# Runs with `awk` and, when installed, gawk, mawk and busybox awk.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$ROOT/core/scripts/lib/trigger-fact-text.awk"
BOUND="${HQ_TRIGGER_FACT_LINEAR_BOUND:-10}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
PASS=0

printf 'built=1\ntoken=.md\ntoken=/hq-share\ntoken=completed\ntoken=apikey\n' > "$TMP/vocab-hit"
printf 'built=1\ntoken=zzqqxx\n' > "$TMP/vocab-miss"

# Every awk to test: `awk` always; others only when present.
IMPLS="awk"
if [ -n "${HQ_TEST_AWKS:-}" ]; then
  IMPLS="$HQ_TEST_AWKS"
else
  for candidate in gawk mawk; do
    command -v "$candidate" >/dev/null 2>&1 && IMPLS="$IMPLS $candidate"
  done
  command -v busybox >/dev/null 2>&1 && busybox awk 'BEGIN{}' >/dev/null 2>&1 && IMPLS="$IMPLS busybox"
fi

run_awk() { # run_awk <impl> <awk args>...
  local impl="$1"; shift
  if [ "$impl" = busybox ]; then busybox awk "$@"; else "$impl" "$@"; fi
}

golden_input() {
  case "$1" in
    words) printf 'Deploy the HQ-core build_42 to prod, then run git push --force-with-lease -x 9ab a\n' ;;
    files) printf 'edit .claude/hooks/master-hook.sh and core/scripts/lib/trigger-fact-text.awk; open README.md, shot.PNG, .env v1.2.3 ../up.py\n' ;;
    slash) printf '/deploy now\nrun /hq-share x and /brainstorm, not repos/public or a//b /9x\tx /tabbed /Q-1\n' ;;
    multiline) printf 'pull request #12 was\nreviewed and merged\ngit checkout main\nexport AWS_PROFILE=dev\nline two\n\n' ;;
    secret) printf 'tok op://vault/item AWS_PROFILE=x .env\n' ;;
    empty) printf '' ;;
    spaces) printf 'a\tb\r\nc\vd\fe\n\n\n' ;;
    json) printf '%s' '{"stdout":"Successfully merged /tmp/x.json into main\nok","stderr":"","cmd":"/hq-sync"}' ;;
    facts) printf 'always\nPush push  /deploy\t.md\nshared_branch\n.MD\n' ;;
  esac
}

run_variant() { # run_variant <impl> <segment-limit> <variant> <input-file>
  local impl="$1" lim="$2" variant="$3" input="$4"
  case "$variant" in
    all) run_awk "$impl" -v hq_segment_limit="$lim" -v mode=all -v branch=main -f "$LIB" < "$input" ;;
    open) run_awk "$impl" -v hq_segment_limit="$lim" -v branch= -f "$LIB" < "$input" ;;
    derived) run_awk "$impl" -v hq_segment_limit="$lim" -v mode=derived -v branch=main -f "$LIB" < "$input" ;;
    normalize) run_awk "$impl" -v hq_segment_limit="$lim" -v mode=normalize -v branch=release/1 -f "$LIB" < "$input" ;;
    prefilter-hit) run_awk "$impl" -v hq_segment_limit="$lim" -v branch= -v policy_vocab_cache="$TMP/vocab-hit" -f "$LIB" < "$input" ;;
    prefilter-miss) run_awk "$impl" -v hq_segment_limit="$lim" -v branch= -v policy_vocab_cache="$TMP/vocab-miss" -f "$LIB" < "$input" ;;
  esac
}

# (b) Expected facts: name|variant|facts joined by spaces|exit status.
cat > "$TMP/expected" <<'EXPECTED'
words|all|deploy the hq-core build_42 to prod then run git push force-with-lease ab shared_branch|0
words|open|deploy the hq-core build_42 to prod then run git push force-with-lease ab|0
words|derived|shared_branch|0
words|normalize|deploy the hq-core build_42 to prod, then run git push --force-with-lease -x 9ab a shared_branch|0
words|prefilter-hit||1
words|prefilter-miss||1
files|all|edit claude hooks master-hook sh and core scripts lib trigger-fact-text awk open readme md shot png env v1 up py secret shared_branch .sh master-hook.sh .awk trigger-fact-text.awk .md readme.md .png shot.png .py up.py shared_branch|0
files|open|edit claude hooks master-hook sh and core scripts lib trigger-fact-text awk open readme md shot png env v1 up py secret shared_branch .sh master-hook.sh .awk trigger-fact-text.awk .md readme.md .png shot.png .py up.py|0
files|derived|secret shared_branch shared_branch|0
files|normalize|edit .claude/hooks/master-hook.sh and core/scripts/lib/trigger-fact-text.awk; open readme.md, shot.png, .env v1.2.3 ../up.py shared_branch|0
files|prefilter-hit||0
files|prefilter-miss||1
slash|all|deploy now run hq-share and brainstorm not repos public or tabbed q-1 /deploy /hq-share /brainstorm /tabbed /q-1 shared_branch|0
slash|open|deploy now run hq-share and brainstorm not repos public or tabbed q-1 /deploy /hq-share /brainstorm /tabbed /q-1|0
slash|derived|shared_branch|0
slash|normalize|/deploy now run /hq-share x and /brainstorm, not repos/public or a//b /9x /tabbed /q-1 shared_branch|0
slash|prefilter-hit||0
slash|prefilter-miss||1
multiline|all|pull request was reviewed and merged git checkout main export aws_profile dev line two secret shared_branch completed shared_branch|0
multiline|open|pull request was reviewed and merged git checkout main export aws_profile dev line two secret shared_branch completed|0
multiline|derived|secret shared_branch completed shared_branch|0
multiline|normalize|pull request #12 was reviewed and merged git checkout main export aws_profile=dev line two shared_branch|0
multiline|prefilter-hit||0
multiline|prefilter-miss||1
secret|all|tok op vault item aws_profile env secret shared_branch|0
secret|open|tok op vault item aws_profile env secret|0
secret|derived|secret shared_branch|0
secret|normalize|tok op://vault/item aws_profile=x .env shared_branch|0
secret|prefilter-hit||1
secret|prefilter-miss||1
empty|all|shared_branch|0
empty|open||0
empty|derived|shared_branch|0
empty|normalize|shared_branch|0
empty|prefilter-hit||1
empty|prefilter-miss||1
spaces|all|shared_branch|0
spaces|open||0
spaces|derived|shared_branch|0
spaces|normalize|a b c d e shared_branch|0
spaces|prefilter-hit||1
spaces|prefilter-miss||1
json|all|stdout successfully merged tmp json into main nok stderr cmd hq-sync shared_branch completed .json x.json /tmp shared_branch|0
json|open|stdout successfully merged tmp json into main nok stderr cmd hq-sync shared_branch completed .json x.json /tmp|0
json|derived|shared_branch completed shared_branch|0
json|normalize|{"stdout":"successfully merged /tmp/x.json into main\nok","stderr":"","cmd":"/hq-sync"} shared_branch|0
json|prefilter-hit||0
json|prefilter-miss||1
facts|all|always push push deploy md shared_branch md /deploy shared_branch|0
facts|open|always push push deploy md shared_branch md /deploy|0
facts|derived|shared_branch|0
facts|normalize|always push /deploy .md shared_branch|0
facts|prefilter-hit||1
facts|prefilter-miss||1
EXPECTED

for impl in $IMPLS; do
  for lim in 0 8; do
    while IFS='|' read -r name variant want want_rc; do
      golden_input "$name" > "$TMP/in"
      rc=0
      got="$(run_variant "$impl" "$lim" "$variant" "$TMP/in" | tr '\n' ' ')" || rc=$?
      got="${got% }"
      if [ "$got" = "$want" ] && [ "$rc" = "$want_rc" ]; then
        PASS=$((PASS + 1))
      else
        FAIL=$((FAIL + 1))
        printf 'FAIL[%s lim=%s %s %s]: got "%s" rc=%s, want "%s" rc=%s\n' \
          "$impl" "$lim" "$name" "$variant" "$got" "$rc" "$want" "$want_rc" >&2
      fi
    done < "$TMP/expected"
  done
done

# A missing vocabulary cache is an error (2), not a match or a skip.
for impl in $IMPLS; do
  rc=0
  printf 'deploy\n' | run_awk "$impl" -v branch= -v policy_vocab_cache="$TMP/absent" -f "$LIB" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 2 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL[$impl missing cache]: rc=$rc, want 2" >&2; fi
done

# (a) Large single-line text, as master-hook passes a tool output.
# make_input <bytes> <kind> writes it: "dense" is JSON-like output with short
# tokens, file names and slash commands; "resplit" is prose with one long
# segment that every separator level has to split again.
make_input() {
  awk -v n="$1" -v kind="$2" 'BEGIN {
    if (kind == "dense") u = "{\"id\":7,\"ok\":true,\"msg\":\"ab cd ef-gh i_j /run x.md\",\"p\":\"a/b.ts\"} "
    else u = "plain words in a long build log line "
    s = u
    while (length(s) < n) s = s s
    s = substr(s, 1, n)
    if (kind == "resplit") {
      t = "ab\fcd\f"
      while (length(t) < 8192) t = t t
      s = s " " t
    }
    printf "%s", s
  }'
}
make_input 1048576 dense > "$TMP/big-dense"
make_input 1048576 resplit > "$TMP/big-resplit"
for impl in $IMPLS; do
  for input in big-dense big-resplit; do
    for variant in all open derived normalize prefilter-miss; do
      start=$SECONDS
      run_variant "$impl" 0 "$variant" "$TMP/$input" > /dev/null || true
      elapsed=$((SECONDS - start))
      if [ "$elapsed" -le "$BOUND" ]; then
        PASS=$((PASS + 1))
      else
        FAIL=$((FAIL + 1))
        printf 'FAIL[%s %s %s]: 1 MB single-line input took %ss (bound %ss)\n' "$impl" "$input" "$variant" "$elapsed" "$BOUND" >&2
      fi
    done
  done
done

# Scaling: 4x the input must cost well under 16x the time (quadratic), so a
# fast awk such as mawk, where the old code fit inside the bound at 1 MB,
# still catches a regression. Needs bash 5 for sub-second timing.
if [ -n "${EPOCHREALTIME:-}" ]; then
  make_input 524288 dense > "$TMP/scale-small"
  make_input 2097152 dense > "$TMP/scale-large"
  usec() { local t="${EPOCHREALTIME/[^0-9]/}"; printf '%s' "$((10#$t))"; }
  for impl in $IMPLS; do
    for variant in all prefilter-miss; do
      start=$(usec); run_variant "$impl" 0 "$variant" "$TMP/scale-small" > /dev/null || true; small=$(( $(usec) - start ))
      start=$(usec); run_variant "$impl" 0 "$variant" "$TMP/scale-large" > /dev/null || true; large=$(( $(usec) - start ))
      if [ "$large" -le $((small * 8 + 1000000)) ]; then
        PASS=$((PASS + 1))
      else
        FAIL=$((FAIL + 1))
        printf 'FAIL[%s %s]: 2 MB took %sus against %sus for 512 KB (more than 8x + 1s)\n' "$impl" "$variant" "$large" "$small" >&2
      fi
    done
  done
fi

echo "trigger-fact-text-linear: awks=[$IMPLS] pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
