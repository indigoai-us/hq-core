#!/usr/bin/env bash
# hq-core-review-run.test.sh — regression tests for .claude/audit/hq-core-review-run.sh,
# the one-command /hq-core-review runner.
#
# Before the runner existed, every review was about a dozen hand-run steps
# (settings clone, worktree, config merge, term files, two scanners, marker,
# cleanup), and HQ's scope hook rejected loops over PR refs. These tests pin
# the single command: it runs every scanner, writes the merge-gate marker only
# when the PR is clean (or the user accepted the findings), fails closed when a
# scanner cannot run, never prints a term or a matched value, and cleans up.
#
# Fully offline: a local bare repo stands in for GitHub, and gh, hq, the
# settings repo scripts and the company term builder are stubs that keep the
# real interfaces (gh pr view -q output, hq secrets exec ... -- cmd, term-scan
# `rule|path|line` + `findings=<n>`, merge-settings GITHUB_OUTPUT keys).
#
# Needs git, python3 with PyYAML, and yq on PATH (the runner checks for yq
# because the real merge-settings.sh uses it).
#
# Usage: bash core/scripts/tests/hq-core-review-run.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUNNER="$ROOT/.claude/audit/hq-core-review-run.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   [$1]"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]: $2"; }

# CI sets HQ_CORE_REVIEW_TEST_REQUIRE_DEPS=1 so a missing tool fails the job
# instead of skipping the suite.
skip() {
  [ "${HQ_CORE_REVIEW_TEST_REQUIRE_DEPS:-0}" = 1 ] && { echo "FAIL: $1 required"; exit 1; }
  echo "SKIP: $1 required"; exit 0
}
for t in git python3 yq; do
  command -v "$t" >/dev/null 2>&1 || skip "$t"
done
python3 -c 'import yaml' 2>/dev/null || skip PyYAML
[ -f "$RUNNER" ] || { echo "FAIL: runner missing at $RUNNER"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$T/gitconfig" user.name "Review Test"
git config --file "$T/gitconfig" user.email "review-test@example.com"
git config --file "$T/gitconfig" init.defaultBranch main
git config --file "$T/gitconfig" advice.detachedHead false

# ---------------------------------------------------------------- fixtures --
HQ="$T/hq"; mkdir -p "$HQ/workspace" "$HQ/companies/acme/scripts" "$T/bin" "$T/gh" "$T/tmp"
: > "$HQ/companies/manifest.yaml"

# Company term builder stub, same contract as companies/indigo/scripts/hq-core-review-terms.sh.
cat > "$HQ/companies/acme/scripts/hq-core-review-terms.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-all}" in
  --modes) printf '%s\n' "${HQ_AUDIT_TERM_MODES:-}" | sed '/^$/d'; exit 0 ;;
esac
[ -n "${HQ_AUDIT_DENYLIST_TERMS:-}" ] || { echo "terms: secret not set" >&2; exit 2; }
if [ "${1:-}" = "--check" ]; then
  d=$(printf '%s\n' "$HQ_AUDIT_DENYLIST_TERMS" | grep -c '^[^ ]*\.[^ ]*$')
  echo "total=$(printf '%s\n' "$HQ_AUDIT_DENYLIST_TERMS" | grep -c .) domain=$d"
  [ "$d" -gt 0 ] || exit 3
  exit 0
fi
printf '%s\n' "$HQ_AUDIT_DENYLIST_TERMS" | sed '/^$/d'
SH

# hq stub: `hq secrets exec --company <c> --only A,B -- cmd...` injects the
# named secrets from FAKE_<NAME> and runs cmd. Logs the company it was asked for.
cat > "$T/bin/hq" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "secrets exec" ] || exit 9
shift 2; only=""
while [ $# -gt 0 ] && [ "$1" != "--" ]; do
  case "$1" in --company) echo "$2" >> "$FAKE_HQ_LOG"; shift 2 ;; --only) only="$2"; shift 2 ;; *) shift ;; esac
done
shift
for n in ${only//,/ }; do v="FAKE_$n"; [ -n "${!v+x}" ] && export "$n=${!v}"; done
exec "$@"
SH

# gh stub: `gh pr view <n> -R <repo> --json ... -q ...` prints "$T/gh/<n>".
cat > "$T/bin/gh" <<SH
#!/usr/bin/env bash
[ "\$1 \$2" = "pr view" ] && [ -f "$T/gh/\$3" ] && { cat "$T/gh/\$3"; exit 0; }
exit 1
SH
chmod +x "$T/bin/hq" "$T/bin/gh" "$HQ/companies/acme/scripts/hq-core-review-terms.sh"
export PATH="$T/bin:$PATH" FAKE_HQ_LOG="$T/hq.log"

# Settings repo stand-in.
S="$T/settings"; mkdir -p "$S/defaults/policies" "$S/workflow-template/scripts" "$S/prompts"
cat > "$S/defaults/config.yaml" <<'YAML'
scanners:
  pii: {enabled: true}
  denylist: {enabled: true}
  domains: {enabled: true}
  slugs: {enabled: true}
YAML
echo "# pii" > "$S/defaults/policies/pii.md"
cat > "$S/workflow-template/scripts/merge-settings.sh" <<'SH'
#!/usr/bin/env bash
# Stub with the real script's interface: org config, repo config, output.
set -euo pipefail
org="$1" repo="$2" out="$3"
if [ -f "$repo" ]; then yq eval-all 'select(fileIndex == 0) *d select(fileIndex == 1)' "$org" "$repo" > "$out"; else cp "$org" "$out"; fi
b="$RUNNER_TEMP/audit-policies"; rm -rf "$b"; mkdir -p "$b"
cp "$(dirname "$org")"/policies/*.md "$b/"
for f in "$(dirname "$repo")"/policies/*.md; do [ -f "$f" ] && cp "$f" "$b/repo-$(basename "$f")"; done
s=""; [ -f "$(dirname "$repo")/suppressions.yaml" ] && s="$(dirname "$repo")/suppressions.yaml"
printf 'policies_bundle_dir<<GHEOF\n%s\nGHEOF\nsuppressions_path<<GHEOF\n%s\nGHEOF\n' "$b" "$s" >> "$GITHUB_OUTPUT"
SH
cat > "$S/workflow-template/scripts/term-scan.py" <<'PY'
# Stub with term-scan.py's output contract (case-insensitive substring only).
import argparse, os, re, subprocess, sys
if os.environ.get("FAKE_TERM_SCAN_FAIL"):
    sys.exit(2)
ap = argparse.ArgumentParser(); ap.add_argument("--terms"); ap.add_argument("--modes")
ap.add_argument("--repo"); ap.add_argument("--base"); a = ap.parse_args()
terms = [t.strip() for t in open(a.terms) if t.strip()]
if not terms:
    sys.exit(2)
mb = subprocess.check_output(["git", "-C", a.repo, "merge-base", "HEAD", a.base], text=True).strip()
diff = subprocess.check_output(["git", "-C", a.repo, "diff", "-U0", "--no-color", mb + "..HEAD"], text=True)
out, path, ln = [], None, 0
def rid(t, i): return ("domain/%d" if "." in t and " " not in t else "denylist/%d" if " " in t else "slug/%d") % i
def safe(p):
    for t in terms: p = re.sub(re.escape(t), "[REDACTED]", p, flags=re.I)
    return p
for line in diff.splitlines():
    if line.startswith("+++ "):
        path = line[6:] if line.startswith("+++ b/") else None
        for i, t in enumerate(terms):
            if path and t.lower() in path.lower(): out.append("%s|%s|0" % (rid(t, i), safe(path)))
        continue
    m = re.match(r"^@@ -\S+ \+(\d+)", line)
    if m: ln = int(m.group(1)); continue
    if line.startswith("+") and path:
        for i, t in enumerate(terms):
            if t.lower() in line.lower(): out.append("%s|%s|%d" % (rid(t, i), safe(path), ln))
        ln += 1
for o in out: print(o)
print("findings=%d" % len(out))
PY
export HQ_CORE_REVIEW_SETTINGS_DIR="$S" HQ_CORE_REVIEW_TMPDIR="$T/tmp" HQ_CORE_REVIEW_REPO="acme/staging"

# The private terms. The test asserts none of these strings ever reaches output.
DOMAIN_TERM="zeta-internal.io"
DENY_TERM="project nightjar"
export FAKE_HQ_AUDIT_DENYLIST_TERMS="$DOMAIN_TERM
$DENY_TERM"
export FAKE_HQ_AUDIT_TERM_MODES="word project nightjar"

# Origin (stands in for GitHub) and the staging checkout.
ORIGIN="$T/origin.git"; SEED="$T/seed"; STAGING="$T/staging"
git init -q --bare "$ORIGIN"
git init -q "$SEED"
mkdir -p "$SEED/.claude/audit/policies" "$SEED/docs" "$SEED/core/policies"
cat > "$SEED/.claude/audit/config.yaml" <<'YAML'
scanners:
  slugs: {enabled: false}
YAML
cat > "$SEED/.claude/audit/suppressions.yaml" <<'YAML'
- path: "core/policies/**"
  scanners: [pii, denylist]
  reason: "policy docs"
YAML
cat > "$SEED/.claude/audit/policies/internal-codes.md" <<'MD'
| field | value |
|-------|-------|
| rule_id | repo/hq-internal-code |
| pattern | `(?:HQ-PRO\|HQ-INTERNAL-DRAFT)-\d{3,5}` |
| severity | high |
MD
# Fixture values the scanners must catch are assembled at run time, so this
# file's own lines do not trip the audit when it reviews the PR that adds it.
AT="@"
export CODE_NUM=1234 # read by the make_pr command strings below
printf 'owner: legacy.person%srealmail.co\n' "$AT" > "$SEED/docs/legacy.md"
echo "readme" > "$SEED/README.md"
git -C "$SEED" add -A && git -C "$SEED" commit -qm base
git -C "$SEED" remote add origin "$ORIGIN"
git -C "$SEED" push -q origin main

PRN=100
make_pr() { # make_pr <name> <setup-commands...>: commit on a branch, publish as refs/pull/<n>/head
  local name="$1"; shift
  PRN=$((PRN + 1))
  git -C "$SEED" checkout -q -B "pr-$name" main
  ( cd "$SEED" && eval "$*" )
  git -C "$SEED" add -A && git -C "$SEED" commit -qm "$name"
  git -C "$SEED" push -q origin "HEAD:refs/pull/$PRN/head"
  printf '%s\tmain\tOPEN\n' "$(git -C "$SEED" rev-parse HEAD)" > "$T/gh/$PRN"
  git -C "$SEED" checkout -q main
}

make_pr clean 'printf "contact jane${AT}example.com or ops${AT}ci.example.test.\nhost 127.0.0.1 and 203.0.113.9\ncall 555-555-0123\nthread T-20261020-202938\nnpm install -g pkg${AT}2.1.296\n" > docs/new.md; echo "edit" >> docs/legacy.md'
make_pr email 'printf "line one\nreach jane.doe${AT}acme-corp.io today\n" > docs/contact.md'
make_pr suppressed 'printf "example: real.person${AT}corp-mail.io\n" > core/policies/doc.md'
make_pr selfsuppress 'printf -- "- path: \"**\"\n  reason: x\n" >> .claude/audit/suppressions.yaml; printf "boss${AT}corp-mail.io\n" > docs/x.md'
make_pr term 'mkdir -p docs/zeta-internal.io; printf "the Project Nightjar launch\n" > docs/zeta-internal.io/notes.md'
make_pr code 'printf "tracked as HQ-PRO-${CODE_NUM}\n" > docs/plan.md'
make_pr policy 'printf "Per our %s, keep it.\n" "policy" > docs/memo.md'
# make_pr numbers PRs from 101 in the order above.
PR_clean=101 PR_email=102 PR_suppressed=103 PR_selfsuppress=104 PR_term=105 PR_code=106 PR_policy=107
[ "$PRN" = 107 ] || { echo "FAIL: fixture PR numbering changed"; exit 1; }

# Bad base branches: no .claude/audit at all (git archive fails), audit dir
# without config.yaml, and a config that turns every scanner off. Each gets a
# PR (201-203) whose head is the clean PR's commit.
CLEAN_SHA="$(git -C "$SEED" rev-parse "pr-clean")"
git -C "$SEED" checkout -q -B base-noaudit main && git -C "$SEED" rm -rq .claude/audit \
  && git -C "$SEED" commit -qm noaudit
git -C "$SEED" checkout -q -B base-noconfig main && git -C "$SEED" rm -q .claude/audit/config.yaml \
  && git -C "$SEED" commit -qm noconfig
git -C "$SEED" checkout -q -B base-noscan main
printf 'scanners:\n  pii: {enabled: false}\n  denylist: {enabled: false}\n' > "$SEED/.claude/audit/config.yaml"
git -C "$SEED" commit -qam noscan
git -C "$SEED" checkout -q main
n=200
for b in base-noaudit base-noconfig base-noscan; do
  n=$((n + 1))
  git -C "$SEED" push -q origin "$b" "pr-clean:refs/pull/$n/head"
  printf '%s\t%s\tOPEN\n' "$CLEAN_SHA" "$b" > "$T/gh/$n"
done

git clone -q "$ORIGIN" "$STAGING"

run() { # run <pr> [args...] → sets OUT, RC
  OUT="$(bash "$RUNNER" "$@" --company acme --hq-root "$HQ" --staging-repo "$STAGING" 2>&1)"; RC=$?
}
marker() { echo "$HQ/workspace/hq-core-review/hq-core-staging-$1-$(cut -f1 "$T/gh/$1").json"; }
no_leak() { # no_leak <label>: output never carries a term or a matched value
  case "$OUT" in
    *"$DOMAIN_TERM"*|*"$DENY_TERM"*|*[Nn]ightjar*|*jane.doe@*|*real.person@*|*boss@*|*legacy.person@*)
      fail "$1 no leak" "output contains a term or matched value" ;;
    *) ok "$1 no leak" ;;
  esac
}
leftovers() { # leftovers <label>: temp dir and worktree are gone
  if [ -z "$(ls -A "$T/tmp")" ] && ! git -C "$STAGING" worktree list | grep -q "$T/tmp"; then ok "$1 cleaned up"
  else fail "$1 cleaned up" "temp dir or worktree left behind"; fi
}

# ------------------------------------------------------------------ cases --
echo "== clean PR: reserved values, pre-existing PII, every scanner =="
run "$PR_clean"
[ "$RC" = 0 ] && ok "clean exit 0" || fail "clean exit 0" "rc=$RC out=$OUT"
M="$(marker "$PR_clean")"
if [ -f "$M" ] && python3 - "$M" "$(cut -f1 "$T/gh/$PR_clean")" "$PR_clean" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["result"] == "clean" and d["head_sha"] == sys.argv[2] and d["pr"] == int(sys.argv[3]), d
assert d["skipped_scanners"] == [] and set(d["scanners_run"]) == {"pii", "denylist", "domains"}, d
assert d["findings"] == 0 and d["reviewed_at"].endswith("Z"), d
PY
then ok "clean marker at gate path with head sha"; else fail "clean marker" "missing or wrong: $M"; fi
case "$OUT" in *"scanners enabled: pii denylist domains"*) ok "repo config disables slugs" ;; *) fail "repo config disables slugs" "$OUT" ;; esac
grep -qx acme "$T/hq.log" && ok "secrets read for the requested company" || fail "secrets company" "$(cat "$T/hq.log")"
leftovers clean

echo "== real-looking email =="
run "$PR_email"
[ "$RC" = 1 ] && ok "email exit 1" || fail "email exit 1" "rc=$RC"
case "$OUT" in *"pii/email|docs/contact.md|2|high"*) ok "email finding by rule/path/line" ;; *) fail "email finding" "$OUT" ;; esac
[ ! -f "$(marker "$PR_email")" ] && ok "email no marker" || fail "email no marker" "marker written"
no_leak email
leftovers email

echo "== base-branch suppression applies =="
run "$PR_suppressed"
[ "$RC" = 0 ] && ok "suppressed path is clean" || fail "suppressed path" "rc=$RC $OUT"

echo "== a PR cannot suppress its own findings =="
run "$PR_selfsuppress"
[ "$RC" = 1 ] && ok "self-suppression exit 1" || fail "self-suppression exit 1" "rc=$RC"
case "$OUT" in *"pii/email|docs/x.md|1|high"*) ok "own suppression ignored" ;; *) fail "own suppression ignored" "$OUT" ;; esac
case "$OUT" in *"audit/config-changed|.claude/audit/suppressions.yaml|0|high"*) ok "audit config change flagged" ;; *) fail "audit config change flagged" "$OUT" ;; esac
no_leak selfsuppress

echo "== denylist and domain terms =="
run "$PR_term"
[ "$RC" = 1 ] && ok "term exit 1" || fail "term exit 1" "rc=$RC"
case "$OUT" in *"denylist/1|docs/[REDACTED]/notes.md|1|critical"*) ok "denylist finding, path redacted" ;; *) fail "denylist finding" "$OUT" ;; esac
case "$OUT" in *"domain/0|docs/[REDACTED]/notes.md|0|high"*) ok "domain path finding" ;; *) fail "domain path finding" "$OUT" ;; esac
no_leak term

echo "== repo policy pattern =="
run "$PR_code"
case "$RC:$OUT" in 1:*"repo/hq-internal-code|docs/plan.md|1|high"*) ok "repo policy finding" ;; *) fail "repo policy finding" "rc=$RC $OUT" ;; esac
run "$PR_policy"
case "$RC:$OUT" in 1:*"policy/rationale|docs/memo.md|1|medium"*) ok "policy language finding (case-insensitive)" ;; *) fail "policy language finding" "rc=$RC $OUT" ;; esac

echo "== --accept writes an accepted marker =="
run "$PR_email" --accept "user accepted the contact address in chat"
[ "$RC" = 0 ] && ok "accept exit 0" || fail "accept exit 0" "rc=$RC $OUT"
M="$(marker "$PR_email")"
if [ -f "$M" ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["result"]=="accepted" and d["findings"]==1 and d["accepted_reason"]' "$M"; then
  ok "accepted marker records findings and reason"; else fail "accepted marker" "missing or wrong"; fi
rm -f "$M"
run "$PR_email" --accept "  "
[ "$RC" = 64 ] && ok "accept needs a reason" || fail "accept needs a reason" "rc=$RC"

echo "== fail closed =="
FAKE_HQ_AUDIT_DENYLIST_TERMS="" run "$PR_clean"
[ "$RC" = 2 ] && ok "empty term secret exit 2" || fail "empty term secret" "rc=$RC"
FAKE_HQ_AUDIT_DENYLIST_TERMS="$DENY_TERM" run "$PR_clean"
[ "$RC" = 2 ] && ok "no domain terms exit 2" || fail "no domain terms" "rc=$RC"
FAKE_TERM_SCAN_FAIL=1 run "$PR_clean"
[ "$RC" = 2 ] && ok "term-scan failure exit 2" || fail "term-scan failure" "rc=$RC"
case "$OUT" in *"result=not-run"*) ok "not-run reported" ;; *) fail "not-run reported" "$OUT" ;; esac
leftovers failclosed
GOOD="$(cat "$T/gh/$PR_clean")"
printf '%s\tmain\tOPEN\n' "0123456789abcdef0123456789abcdef01234567" > "$T/gh/$PR_clean"
run "$PR_clean"
[ "$RC" = 2 ] && ok "head moved exit 2" || fail "head moved" "rc=$RC"
[ ! -f "$HQ/workspace/hq-core-review/hq-core-staging-$PR_clean-0123456789abcdef0123456789abcdef01234567.json" ] \
  && ok "head moved no marker" || fail "head moved no marker" "marker written"
# GitHub reports a commit the checkout already has (main), but pull/<n>/head
# points elsewhere: a sha that merely exists locally is not the PR head.
MAIN_SHA="$(git -C "$SEED" rev-parse main)"
printf '%s\tmain\tOPEN\n' "$MAIN_SHA" > "$T/gh/$PR_clean"
run "$PR_clean"
case "$RC:$OUT" in 2:*"the PR moved"*) ok "pull head must equal the reported head" ;; *) fail "pull head must equal the reported head" "rc=$RC $OUT" ;; esac
[ ! -f "$HQ/workspace/hq-core-review/hq-core-staging-$PR_clean-$MAIN_SHA.json" ] \
  && ok "reported-head mismatch no marker" || fail "reported-head mismatch no marker" "marker written"
printf '%s\n' "$GOOD" > "$T/gh/$PR_clean"
if git -C "$STAGING" for-each-ref refs/hq-core-review | grep -q .; then fail "private PR ref removed" "ref left behind"
else ok "private PR ref removed"; fi

for case in 201:"base without .claude/audit" 202:"base without config.yaml" 203:"config enables no scanner"; do
  n="${case%%:*}"
  run "$n"
  [ "$RC" = 2 ] && ok "$n ${case#*:} exit 2" || fail "$n ${case#*:} exit 2" "rc=$RC $OUT"
  ls "$HQ/workspace/hq-core-review/hq-core-staging-$n-"* >/dev/null 2>&1 \
    && fail "$n ${case#*:} no marker" "marker written" || ok "$n ${case#*:} no marker"
done
leftovers badbase
rm -f "$HQ/workspace/hq-core-review/"*
FAKE_HQ_AUDIT_DENYLIST_TERMS="" run "$PR_clean"
[ -z "$(ls -A "$HQ/workspace/hq-core-review")" ] && ok "failed runs write no marker" || fail "failed runs write no marker" "marker present"

echo "== usage =="
run notanumber
[ "$RC" = 64 ] && ok "bad PR number exit 64" || fail "bad PR number" "rc=$RC"
run "#$PR_suppressed"
[ "$RC" = 0 ] && ok "accepts #<n>" || fail "accepts #<n>" "rc=$RC"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
