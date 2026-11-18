#!/usr/bin/env bash
# hq-core: public
# Tests for core/scripts/garden-policy-pass.sh — the /garden policies pass.
# Fixture corpus: six policies, two retire and four stay.
set -euo pipefail
ROOT="${HQ_TEST_ROOT:-$(git rev-parse --show-toplevel)}"
FX="$(mktemp -d)"; FX="$(cd "$FX" && pwd -P)"; trap 'rm -rf "$FX"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
unset HQ_SESSION_ID CLAUDE_PROJECT_DIR
P="$FX/personal/policies"; C="$FX/companies/acme/policies"
mkdir -p "$P" "$C" "$FX/core/policies" "$FX/workspace/orchestrator"
pol() {  # file id extra-frontmatter
  printf -- '---\nid: %s\ntitle: t\nenforcement: hard\nwhen: always\non: [SessionStart]\n%s---\n\n## Rule\n\n%s rule.\n' "$2" "$3" "$2" > "$1"
}
# Now = 2026-10-07. 90 days earlier = 2026-07-09.
NOW=1791331200
# 1 retire: old, never retrieved.
pol "$P/old-unused.md" old-unused $'created: 2026-01-01\n'
# 2 stay: old, retrieved recently.
pol "$P/old-used.md" old-used $'created: 2026-01-01\n'
# 3 stay: young, never retrieved.
pol "$P/young.md" young $'created: 2026-09-01\n'
# 4 retire: superseded, and its replacement is active.
pol "$C/replaced.md" replaced $'created: 2026-09-20\nstatus: superseded\n'
pol "$C/replacement.md" replacement $'created: 2026-09-20\nsupersedes: [replaced]\n'
# 5 stay: superseded, but the replacement is itself retired (not live).
pol "$C/orphan-superseded.md" orphan-superseded $'created: 2026-09-20\nstatus: superseded\n'
pol "$FX/core/policies/dead-replacement.md" dead-replacement $'created: 2026-09-20\nstatus: retired\nsupersedes: [orphan-superseded]\n'
# 6 stay: has retire_when; the script never judges it on its own.
pol "$C/workaround.md" workaround $'created: 2026-09-20\nretire_when: hq-cli 6.0 ships the native fix\n'
# The ledger reaches back past the 90-day window (2026-06-01), so absence of
# retrievals is actually observed for this corpus (feedback_34db91b5).
printf '{"policy":"unrelated-early","session":"s0","ts":"2026-06-01T09:00:00Z","via":"read"}\n{"policy":"old-used","session":"s1","ts":"2026-09-30T10:00:00Z","via":"read"}\n' > "$FX/workspace/orchestrator/policy-retrieval-ledger.jsonl"
run() { HQ_ROOT="$FX" GARDEN_NOW_EPOCH=$NOW bash "$ROOT/core/scripts/garden-policy-pass.sh" --dir "$P" --dir "$C" "$@"; }

echo "[1] dry run lists exactly the two candidates and writes nothing to policies"
before="$(cat "$P"/*.md "$C"/*.md | shasum)"
out="$(run --dry-run)"
[ "$(grep -c '^would-retire	' <<<"$out")" = 2 ] || fail "want 2 candidates: $out"
grep -q '^would-retire	old-unused	' <<<"$out" || fail "old-unused not selected: $out"
grep -q '^would-retire	replaced	' <<<"$out" || fail "replaced not selected: $out"
grep -q '^judge	workaround	' <<<"$out" || fail "workaround not listed for judgment: $out"
for keep in old-used young orphan-superseded replacement; do
  grep -q "^would-retire	$keep	" <<<"$out" && fail "$keep selected"
done
[ "$(cat "$P"/*.md "$C"/*.md | shasum)" = "$before" ] || fail "dry run modified policies"
grep -q 'Dry run: evaluated 7 policies; 2 would be retired' <<<"$out" || fail "dry summary: $out"
[ -f "$FX/workspace/reports/garden/policies-2026-10-07.md" ] || fail "no dry-run report"

echo "[2] live run retires the two through hq core policy retire, keeps files in place"
out="$(run)"
grep -q 'Evaluated 7 policies; retired 2; 0 failed' <<<"$out" || fail "live summary: $out"
f="$P/old-unused.md"
grep -q '^status: retired' "$f" && grep -q '^retired_at:' "$f" && grep -q '^retired_by: garden-policy-pass' "$f" \
  && grep -q '^retired_reason: "garden: no retrievals in 90 days' "$f" || fail "old-unused fields: $(head -14 "$f")"
grep -q '^status: retired' "$C/replaced.md" && grep -q 'retired_reason: "garden: superseded by a live policy' "$C/replaced.md" || fail "replaced fields"
for keep in "$P/old-used.md" "$P/young.md" "$C/orphan-superseded.md" "$C/workaround.md" "$C/replacement.md"; do
  grep -q '^status: retired' "$keep" && fail "$keep retired"
done
[ "$(find "$P" "$C" -name '*.md' | wc -l | tr -d ' ')" = 7 ] || fail "files moved or deleted"
grep -q 'retired | old-unused' "$FX/workspace/reports/garden/policies-2026-10-07.md" || fail "report table"

echo "[3] --retire-when-met retires a judged condition with the reasoning recorded"
run --retire-when-met "workaround=hq-cli 6.0 is installed" >/dev/null
grep -q 'retired_reason: "garden: retire_when met (hq-cli 6.0 ships the native fix): hq-cli 6.0 is installed"' "$C/workaround.md" || fail "judged reason: $(head -14 "$C/workaround.md")"

echo "[4] core/policies is never retired, even when it qualifies"
pol "$FX/core/policies/core-old.md" core-old $'created: 2026-01-01\n'
out="$(HQ_ROOT="$FX" GARDEN_NOW_EPOCH=$NOW bash "$ROOT/core/scripts/garden-policy-pass.sh" --dir "$FX/core/policies")"
grep -q '^skip	core-old	core/policies/core-old.md	core policy' <<<"$out" || fail "core skip: $out"
grep -q '^status: retired' "$FX/core/policies/core-old.md" && fail "core policy retired"

# feedback_34db91b5: on a 17-day-old install the pass marked 60 rules unused
# over a "90-day" window, and it ignored trigger-loader injections, which is how
# most rules are used. Absence needs evidence that reaches back the whole
# window, and a rule read or injected inside the window is never retired.
FX2="$(mktemp -d)"; FX2="$(cd "$FX2" && pwd -P)"; trap 'rm -rf "$FX" "$FX2"' EXIT
P2="$FX2/personal/policies"; ST="$FX2/workspace/orchestrator/policy-trigger-state"
mkdir -p "$P2" "$ST"
run2() { HQ_ROOT="$FX2" GARDEN_NOW_EPOCH=$NOW bash "$ROOT/core/scripts/garden-policy-pass.sh" --dir "$P2" "$@"; }
stamp() { TZ=UTC touch -t "$1" "$2"; }   # CCYYMMDDhhmm, UTC

echo "[5] a ledger younger than the window retires nothing as unused"
pol "$P2/old-quiet.md" old-quiet $'created: 2026-01-01\n'
# Ledger starts 2026-09-20: 17 days before NOW.
printf '{"policy":"other","session":"s1","ts":"2026-09-20T10:00:00Z","via":"read"}\n' > "$FX2/workspace/orchestrator/policy-retrieval-ledger.jsonl"
out="$(run2 --dry-run)"
grep -q '^would-retire	' <<<"$out" && fail "short evidence still proposed a retirement: $out"
grep -q '^stay	old-quiet	.*covers less than 90 days; absence not judged' <<<"$out" || fail "short-coverage reason: $out"
out="$(run2 --days 10 --dry-run)"
grep -q '^would-retire	old-quiet	personal/policies/old-quiet.md	no retrievals in 10 days' <<<"$out" \
  || fail "a window the ledger does cover must still judge absence: $out"

echo "[6] trigger-loader injections inside the window count as use"
pol "$P2/injected-ledger.md" injected-ledger $'created: 2026-01-01\n'
pol "$P2/injected-seen.md" injected-seen $'created: 2026-01-01\n'
pol "$P2/injected-long-ago.md" injected-long-ago $'created: 2026-01-01\n'
pol "$P2/judged-but-used.md" judged-but-used $'created: 2026-01-01\nretire_when: the feature ships\n'
printf 'injected-ledger\njudged-but-used\n' > "$ST/sess-recent.txt"; stamp 202610011200 "$ST/sess-recent.txt"
printf 'injected-seen\t%s\tev:git\tparked\n' "$((NOW - 3 * 86400))" > "$ST/sess-seen.seen.tsv"; stamp 202610030000 "$ST/sess-seen.seen.tsv"
# An injection older than the window is not use, and also proves the history
# reaches back past 90 days.
printf 'injected-long-ago\n' > "$ST/sess-old.txt"; stamp 202606010000 "$ST/sess-old.txt"
# A footer or deferred queue is not a delivery.
printf 'old-quiet\n' > "$ST/sess-recent.footer.txt"; stamp 202610011200 "$ST/sess-recent.footer.txt"
printf 'old-quiet\n' > "$ST/sess-recent.deferred-soft.txt"; stamp 202610011200 "$ST/sess-recent.deferred-soft.txt"
out="$(run2 --dry-run --retire-when-met "judged-but-used=the feature shipped")"
grep -q '^stay	injected-ledger	.*in use (injected by the trigger loader' <<<"$out" || fail "session-ledger injection ignored: $out"
grep -q '^stay	injected-seen	.*in use (injected by the trigger loader' <<<"$out" || fail "seen-row injection ignored: $out"
grep -q '^stay	judged-but-used	.*in use (injected by the trigger loader.*not retired although: retire_when met' <<<"$out" \
  || fail "a rule in use was proposed through retire_when: $out"
grep -q '^would-retire	injected-long-ago	' <<<"$out" || fail "an injection older than the window must not count: $out"
grep -q '^would-retire	old-quiet	' <<<"$out" || fail "footer/deferred files must not count as use: $out"
echo "garden-policy-pass: ok"
