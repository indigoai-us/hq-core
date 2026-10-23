#!/usr/bin/env bash
# hq-core-review-run.sh — run the whole /hq-core-review audit for one
# indigoai-us/hq-core-staging pull request with a single command.
#
# Usage:
#   bash .claude/audit/hq-core-review-run.sh <pr> [--accept "<reason>"]
#        [--company <slug>] [--hq-root <dir>] [--staging-repo <dir>]
#        [--terms-script <path>]
#
# What it does, in order (the steps the /hq-core-review skill used to list for
# the agent to run by hand):
#   1. Reads the PR's head commit and base branch from GitHub (gh).
#   2. Fetches the audit settings repo (indigoai-us/hq-pr-review-settings) into
#      a private temp dir.
#   3. Fetches the PR head into the hq-core-staging checkout and adds a
#      detached worktree for it inside the temp dir. The fetched commit must be
#      the head GitHub reported, or the run stops.
#   4. Merges the audit config with the settings repo's merge-settings.sh. The
#      repo's .claude/audit files (config, suppressions, extra policies) are
#      read from the BASE branch, so a PR cannot suppress its own findings. A
#      PR that changes .claude/audit/** gets an audit/config-changed finding.
#   5. Builds the private term and match-mode files from the company's vault
#      secrets (hq secrets exec ... hq-core-review-terms.sh) and checks them.
#   6. Runs the denylist and domain scanners (settings repo term-scan.py) and
#      the PII scanner plus repo policy patterns (built in below) on the lines
#      the PR adds, then applies the reserved-value exclusions and the base
#      branch's suppressions.yaml.
#   7. Prints findings as `rule|path|line|severity` only. It never prints a
#      term, a modes line or matched content; a term inside a path is
#      replaced with [REDACTED].
#   8. Writes the merge-gate pass marker
#      <hq-root>/workspace/hq-core-review/hq-core-staging-<pr>-<head-sha>.json
#      when every enabled scanner ran and nothing was found. With --accept it
#      writes an "accepted" marker despite findings. Use --accept only after
#      the user has accepted those findings for this PR in chat.
#   9. Removes the worktree and the temp dir, on success or failure.
#
# This is maintainer tooling for auditing this repo, not session runtime, so it
# lives here beside the audit config instead of under core/scripts (which must
# not call python3). It needs gh, git, yq, python3 and PyYAML.
#
# Exit codes:
#   0   marker written (clean, or accepted)
#   1   findings; no marker written
#   2   a scanner or a setup step did not run; no marker written, never clean
#   64  usage error
#
# Test and portability overrides (environment):
#   HQ_CORE_REVIEW_SETTINGS_DIR  copy this local settings dir instead of cloning
#   HQ_CORE_REVIEW_SETTINGS_URL  settings repo to clone
#   HQ_CORE_REVIEW_REPO          GitHub repo (default indigoai-us/hq-core-staging)
#   HQ_CORE_REVIEW_HQ_BIN        hq CLI to run `hq secrets exec` with (default hq)
#   HQ_CORE_REVIEW_TMPDIR        parent dir for the temp dir (default /tmp)
set -uo pipefail

REPO="${HQ_CORE_REVIEW_REPO:-indigoai-us/hq-core-staging}"
SETTINGS_URL="${HQ_CORE_REVIEW_SETTINGS_URL:-https://github.com/indigoai-us/hq-pr-review-settings}"
HQ_BIN="${HQ_CORE_REVIEW_HQ_BIN:-hq}"
TMP_PARENT="${HQ_CORE_REVIEW_TMPDIR:-/tmp}"

usage() {
  sed -n '5,8p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

PR="" ACCEPT_REASON="" ACCEPT=0 COMPANY="indigo"
HQ_ROOT_ARG="" STAGING_ARG="" TERMS_SCRIPT_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --accept) [ $# -ge 2 ] || usage; ACCEPT=1; ACCEPT_REASON="$2"; shift 2 ;;
    --company) [ $# -ge 2 ] || usage; COMPANY="$2"; shift 2 ;;
    --hq-root) [ $# -ge 2 ] || usage; HQ_ROOT_ARG="$2"; shift 2 ;;
    --staging-repo) [ $# -ge 2 ] || usage; STAGING_ARG="$2"; shift 2 ;;
    --terms-script) [ $# -ge 2 ] || usage; TERMS_SCRIPT_ARG="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "hq-core-review: unknown flag $1" >&2; usage ;;
    *) [ -z "$PR" ] || usage; PR="${1#\#}"; shift ;;
  esac
done
printf '%s' "$PR" | grep -Eq '^[0-9]+$' || { echo "hq-core-review: pass the PR number" >&2; usage; }
printf '%s' "$COMPANY" | grep -Eq '^[a-z0-9][a-z0-9-]*$' || { echo "hq-core-review: bad --company" >&2; exit 64; }
if [ "$ACCEPT" = 1 ] && [ -z "$(printf '%s' "$ACCEPT_REASON" | tr -d '[:space:]')" ]; then
  echo "hq-core-review: --accept needs a reason (what the user accepted)" >&2; exit 64
fi

fail() { echo "hq-core-review: $1" >&2; echo "result=not-run pr=$PR (no marker written)"; exit 2; }

# --- HQ root ---------------------------------------------------------------
find_root() {
  local d="$1"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -f "$d/companies/manifest.yaml" ] && [ -d "$d/workspace" ] && { printf '%s' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}
HQ_ROOT="${HQ_ROOT_ARG:-${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-}}}"
[ -n "$HQ_ROOT" ] || HQ_ROOT="$(find_root "$(pwd)")" || HQ_ROOT=""
[ -n "$HQ_ROOT" ] || HQ_ROOT="$(find_root "$(cd "$(dirname "$0")" && pwd)")" || HQ_ROOT=""
[ -n "$HQ_ROOT" ] && [ -d "$HQ_ROOT/workspace" ] || fail "cannot find the HQ root; pass --hq-root"
HQ_ROOT="$(cd "$HQ_ROOT" && pwd)"

STAGING="${STAGING_ARG:-$HQ_ROOT/repos/private/hq-core-staging}"
git -C "$STAGING" rev-parse --git-dir >/dev/null 2>&1 || fail "no hq-core-staging checkout at $STAGING; pass --staging-repo"
TERMS_SCRIPT="${TERMS_SCRIPT_ARG:-$HQ_ROOT/companies/$COMPANY/scripts/hq-core-review-terms.sh}"
[ -f "$TERMS_SCRIPT" ] || fail "term builder not found at $TERMS_SCRIPT"

for tool in gh git python3 yq; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed"
done
python3 -c 'import yaml' 2>/dev/null || fail "python3 is missing PyYAML"

# --- PR head from GitHub ----------------------------------------------------
PR_INFO="$(gh pr view "$PR" -R "$REPO" --json headRefOid,baseRefName,state \
  -q '[.headRefOid,.baseRefName,.state]|@tsv' 2>/dev/null)" || fail "gh could not read PR #$PR in $REPO"
HEAD_SHA="$(printf '%s' "$PR_INFO" | cut -f1)"
BASE="$(printf '%s' "$PR_INFO" | cut -f2)"
STATE="$(printf '%s' "$PR_INFO" | cut -f3)"
printf '%s' "$HEAD_SHA" | grep -Eq '^[0-9a-f]{40}$' || fail "gh returned no head commit for PR #$PR"
printf '%s' "$BASE" | grep -Eq '^[A-Za-z0-9._/-]+$' || fail "gh returned a bad base branch for PR #$PR"
echo "hq-core-review: PR #$PR ($STATE) head ${HEAD_SHA:0:12} base $BASE"

# --- private work dir, always cleaned up -----------------------------------
umask 077
WORK="$(mktemp -d "$TMP_PARENT/hq-core-review-$PR.XXXXXX")" || fail "cannot create a temp dir"
PR_REF="refs/hq-core-review/pr-$PR-$$"
cleanup() {
  git -C "$STAGING" worktree remove --force "$WORK/pr" >/dev/null 2>&1 || true
  git -C "$STAGING" update-ref -d "$PR_REF" >/dev/null 2>&1 || true
  git -C "$STAGING" worktree prune >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 2' INT TERM HUP

# --- 1. audit settings ------------------------------------------------------
if [ -n "${HQ_CORE_REVIEW_SETTINGS_DIR:-}" ]; then
  cp -R "$HQ_CORE_REVIEW_SETTINGS_DIR" "$WORK/.audit-settings" || fail "cannot copy $HQ_CORE_REVIEW_SETTINGS_DIR"
else
  git clone -q --depth 1 --filter=blob:none --sparse "$SETTINGS_URL" "$WORK/.audit-settings" >/dev/null 2>&1 \
    && git -C "$WORK/.audit-settings" sparse-checkout set defaults prompts workflow-template/scripts >/dev/null 2>&1 \
    || fail "cannot fetch the audit settings repo ($SETTINGS_URL)"
fi
SCRIPTS="$WORK/.audit-settings/workflow-template/scripts"
[ -f "$SCRIPTS/merge-settings.sh" ] && [ -f "$SCRIPTS/term-scan.py" ] \
  && [ -f "$WORK/.audit-settings/defaults/config.yaml" ] || fail "audit settings are missing merge-settings.sh, term-scan.py or defaults/config.yaml"

# --- 2. PR head checkout ----------------------------------------------------
git -C "$STAGING" fetch -q origin "+refs/heads/$BASE:refs/remotes/origin/$BASE" >/dev/null 2>&1 \
  || fail "cannot fetch base branch $BASE"
# Fetch into a ref private to this run (FETCH_HEAD is shared with any other
# fetch in the checkout) and require it to be the head GitHub reported.
git -C "$STAGING" fetch -q origin "+refs/pull/$PR/head:$PR_REF" >/dev/null 2>&1 || fail "cannot fetch pull/$PR/head"
FETCHED="$(git -C "$STAGING" rev-parse --verify -q "$PR_REF^{commit}")" || fail "cannot read the fetched PR head"
[ "$FETCHED" = "$HEAD_SHA" ] \
  || fail "pull/$PR/head is ${FETCHED:0:12} but GitHub reported ${HEAD_SHA:0:12}; the PR moved during the run, run it again"
git -C "$STAGING" worktree add -q --detach "$WORK/pr" "$HEAD_SHA" >/dev/null 2>&1 || fail "cannot add a worktree for the PR head"
[ "$(git -C "$WORK/pr" rev-parse HEAD)" = "$HEAD_SHA" ] || fail "worktree is not at the PR head"

# --- 3. merged config, from the base branch's .claude/audit -----------------
# Without the base config, suppressions and repo policies the scan would run
# on org defaults alone, so a failed extraction stops the run.
mkdir -p "$WORK/base"
git -C "$STAGING" archive -o "$WORK/base-audit.tar" "refs/remotes/origin/$BASE" .claude/audit >/dev/null 2>&1 \
  || fail "cannot read .claude/audit from base branch $BASE"
tar -x -f "$WORK/base-audit.tar" -C "$WORK/base" >/dev/null 2>&1 || fail "cannot extract the base branch's .claude/audit"
[ -f "$WORK/base/.claude/audit/config.yaml" ] || fail "base branch $BASE has no .claude/audit/config.yaml"
: > "$WORK/gh-output"
( cd "$WORK/pr" && GITHUB_OUTPUT="$WORK/gh-output" GITHUB_REPOSITORY="$REPO" RUNNER_TEMP="$WORK" \
    bash "$SCRIPTS/merge-settings.sh" "$WORK/.audit-settings/defaults/config.yaml" \
    "$WORK/base/.claude/audit/config.yaml" "$WORK/audit-config.yaml" ) > "$WORK/merge.log" 2>&1 \
  || { tail -5 "$WORK/merge.log" >&2; fail "merge-settings.sh failed"; }

ghout() { # ghout <key>: value of a key<<GHEOF block in $GITHUB_OUTPUT
  awk -v k="$1" '$0 == k"<<GHEOF" {on=1; next} on && $0 == "GHEOF" {exit} on {print}' "$WORK/gh-output"
}
POLICIES_DIR="$(ghout policies_bundle_dir)"
SUPPRESSIONS="$(ghout suppressions_path)"
[ -n "$POLICIES_DIR" ] && [ -d "$POLICIES_DIR" ] || fail "merge-settings.sh exported no policies bundle"

ENABLED="$(python3 - "$WORK/audit-config.yaml" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
sc = cfg.get("scanners") or {}
def on(name):
    v = (sc.get(name) or {}).get("enabled", False)
    return v is True or str(v).lower() == "true"
den = on("denylist")
print(" ".join(n for n, v in [("pii", on("pii")), ("denylist", den),
                              ("domains", den and on("domains")),
                              ("slugs", den and on("slugs"))] if v))
PY
)" || fail "cannot read the merged audit config"
echo "hq-core-review: scanners enabled: ${ENABLED:-none}"
[ -n "$ENABLED" ] || fail "the merged config enables no scanner, so nothing would be scanned"
case " $ENABLED " in *" pii "*) ;; *) echo "hq-core-review: note: the PII scanner is disabled by config" ;; esac

# --- 4. terms and denylist/domain scan --------------------------------------
: > "$WORK/term-findings.txt"
TERM_SCAN_RAN=0
case " $ENABLED " in
  *" denylist "*)
    "$HQ_BIN" secrets exec --company "$COMPANY" --only HQ_AUDIT_DENYLIST_TERMS -- \
      bash "$TERMS_SCRIPT" > "$WORK/terms.txt" 2> "$WORK/terms.err" \
      || { cat "$WORK/terms.err" >&2; fail "could not build the term list (is HQ_AUDIT_DENYLIST_TERMS readable for $COMPANY?)"; }
    "$HQ_BIN" secrets exec --company "$COMPANY" --only HQ_AUDIT_TERM_MODES -- \
      bash "$TERMS_SCRIPT" --modes > "$WORK/modes.txt" 2> "$WORK/modes.err" \
      || { cat "$WORK/modes.err" >&2; fail "could not build the match-modes file"; }
    CHECK="$("$HQ_BIN" secrets exec --company "$COMPANY" --only HQ_AUDIT_DENYLIST_TERMS,HQ_AUDIT_TERM_MODES -- \
      bash "$TERMS_SCRIPT" --check 2> "$WORK/check.err")"
    rc=$?
    # The --check line holds counts only; it is the one term-builder output safe to show.
    [ -n "$CHECK" ] && echo "hq-core-review: terms $CHECK"
    [ "$rc" = 0 ] || { cat "$WORK/check.err" >&2; fail "term check failed (exit $rc); the denylist/domain scan cannot run"; }
    [ -s "$WORK/terms.txt" ] || fail "the term file is empty; the denylist/domain scan cannot run"
    ( cd "$WORK/pr" && HQ_AUDIT_TERM_MODES_FILE="$WORK/modes.txt" python3 "$SCRIPTS/term-scan.py" \
        --terms "$WORK/terms.txt" --modes "$WORK/modes.txt" --repo . --base "origin/$BASE" ) \
      > "$WORK/term-findings.txt" 2> "$WORK/term-scan.err"
    rc=$?
    [ "$rc" = 0 ] || { cat "$WORK/term-scan.err" >&2; fail "term-scan.py did not run (exit $rc)"; }
    grep -Eq '^findings=[0-9]+$' "$WORK/term-findings.txt" || fail "term-scan.py printed no findings count"
    TERM_SCAN_RAN=1
    ;;
esac

# --- 5. PII + repo policies, exclusions, suppressions, report ---------------
python3 - "$WORK" "$BASE" "$ENABLED" "$TERM_SCAN_RAN" "$POLICIES_DIR" "$SUPPRESSIONS" <<'PY'
import json, os, re, subprocess, sys
import yaml

work, base, enabled, term_ran, policies_dir, supp_path = sys.argv[1:7]
enabled = set(enabled.split())
repo = os.path.join(work, "pr")

def die(msg):
    print("hq-core-review: " + msg, file=sys.stderr)
    sys.exit(2)

# --- the PR's added lines (same diff flags as term-scan.py) ---
try:
    mb = subprocess.check_output(["git", "-C", repo, "merge-base", "HEAD", "origin/" + base], text=True).strip()
    spec = [mb + "..HEAD", "--", ".", ":!.audit-settings"]
    diff = subprocess.check_output(
        ["git", "-C", repo, "-c", "core.quotePath=true", "diff", "--no-color", "--no-ext-diff",
         "--no-textconv", "--text", "--src-prefix=a/", "--dst-prefix=b/", "-U0"] + spec,
        text=True, errors="replace")
    changed = subprocess.check_output(
        ["git", "-C", repo, "diff", "--name-only", "-z", "--no-renames"] + spec,
        text=True, errors="replace").split("\0")
except subprocess.CalledProcessError:
    die("cannot diff the PR against origin/" + base)

def unquote(p):
    if len(p) >= 2 and p[0] == '"' and p[-1] == '"':
        raw = p[1:-1].encode("utf-8").decode("unicode_escape")
        return raw.encode("latin-1", "replace").decode("utf-8", "replace")
    return p

added, path, ln = [], None, 0
for line in diff.splitlines():
    if line.startswith("+++ "):
        p = line[4:]
        path = None if p == "/dev/null" else unquote(p)
        if path and path.startswith("b/"):
            path = path[2:]
        continue
    if line.startswith("--- ") or line.startswith("diff --git "):
        continue
    m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
    if m:
        ln = int(m.group(1))
        continue
    if line.startswith("+") and path is not None:
        added.append((path, ln, line[1:]))
        ln += 1

# --- PII rules (hq-pr-review-settings defaults/policies/pii.md) ---
PII = [
    ("pii/email", r"[\w.+-]+@[\w-]+\.[\w.-]+", 0, "high"),
    ("pii/phone", r"\b\d{3}[-.]?\d{3}[-.]?\d{4}\b", 0, "high"),
    ("pii/ssn", r"\b\d{3}-\d{2}-\d{4}\b", 0, "critical"),
    ("pii/credit-card", r"\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{1,7}\b", 0, "critical"),
    ("pii/ipv4", r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b", 0, "medium"),
    # `[ ]` is a plain space; it keeps this source line from matching its own rule.
    ("policy/rationale", r"\b(?:internal[ ]policy|per our[ ]policy|company policy[ ]requires|do not share[ ]externally)\b", re.I, "medium"),
]

def strip_tail(d):
    while d.endswith(".") or d.endswith("-"):
        d = d[:-1]
    return d

def reserved(rule, value):
    """Reserved placeholder values (pii.md "Exclusions"): never findings."""
    if rule == "pii/email":
        d = strip_tail(value.split("@", 1)[1].lower())
        if d in ("example.com", "example.net", "example.org", "localhost"):
            return True
        if d.endswith((".example.com", ".example.net", ".example.org")):
            return True
        if d.rsplit(".", 1)[-1] in ("test", "example", "invalid", "localhost"):
            return True
        return re.fullmatch(r"[0-9]+\.[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.-]+)?", d) is not None
    if rule == "pii/ipv4":
        o = [int(x) for x in value.split(".")]
        if o[0] == 127 or value in ("0.0.0.0", "255.255.255.255"):
            return True
        return o[:3] in ([192, 0, 2], [198, 51, 100], [203, 0, 113])
    if rule == "pii/credit-card":
        # HQ thread-id timestamps (T-YYYYMMDD-HHMMSS) are not card numbers.
        return re.fullmatch(r"20\d{2}[01]\d[0-3]\d-[0-2]\d[0-5]\d[0-5]\d", value) is not None
    if rule == "pii/phone":
        return re.sub(r"\D", "", value)[-7:].startswith("55501")
    return False

# --- repo policies (bundle files named repo-*.md) ---
repo_rules = []
for name in sorted(os.listdir(policies_dir)):
    if not (name.startswith("repo-") and name.endswith(".md")):
        continue
    fields = {}
    for row in open(os.path.join(policies_dir, name), encoding="utf-8", errors="replace"):
        m = re.match(r"^\|\s*(rule_id|id|pattern|severity)\s*\|\s*(.*?)\s*\|\s*$", row)
        if m:
            fields.setdefault(m.group(1), m.group(2).replace("\\|", "|"))
    rid = (fields.get("rule_id") or fields.get("id") or "").strip("` ")
    pat = (fields.get("pattern") or "").strip()
    if pat.startswith("`") and pat.count("`") >= 2:
        pat = pat[1:pat.index("`", 1)]
    if not rid or not pat:
        die("repo policy %s has no machine-readable rule_id and pattern; it cannot run" % name)
    try:
        repo_rules.append((rid, re.compile(pat), (fields.get("severity") or "high").strip("` ").lower()))
    except re.error:
        die("repo policy %s has a pattern Python cannot compile" % name)

findings = []  # (rule, path, line, severity, scanner)
if "pii" in enabled:
    for rule, pat, flags, sev in PII:
        rx = re.compile(pat, flags)
        for p, n, text in added:
            if any(not reserved(rule, m.group(0)) for m in rx.finditer(text)):
                findings.append((rule, p, n, sev, "pii"))
for rid, rx, sev in repo_rules:
    for p, n, text in added:
        if rx.search(text):
            findings.append((rid, p, n, sev, "repo"))

# A PR that edits the audit config is reviewed with the base branch's config,
# and a person has to look at the change itself.
for p in changed:
    if p.startswith(".claude/audit/"):
        findings.append(("audit/config-changed", p, 0, "high", "audit"))

# --- denylist / domain findings from term-scan.py ---
TERM_SEV = {"denylist": ("critical", "denylist"), "domain": ("high", "domains"), "slug": ("medium", "slugs")}
if term_ran == "1":
    for row in open(os.path.join(work, "term-findings.txt"), encoding="utf-8", errors="replace"):
        row = row.rstrip("\n")
        if not row or row.startswith("findings="):
            continue
        head, _, num = row.rpartition("|")
        rule, _, p = head.partition("|")
        if not rule or not p or not num.isdigit():
            die("unexpected term-scan.py output line")
        sev, scanner = TERM_SEV.get(rule.split("/", 1)[0], ("high", "denylist"))
        if scanner not in enabled:
            continue
        findings.append((rule, p, int(num), sev, scanner))

# --- suppressions (gitignore-style globs, base branch copy) ---
def glob_rx(g):
    g = g.strip()
    anchored = "/" in g.rstrip("/")
    g = g.lstrip("/")
    if g.endswith("/"):
        g += "**"
    out, i = "", 0
    while i < len(g):
        if g.startswith("**/", i):
            out += "(?:.*/)?"; i += 3
        elif g.startswith("**", i):
            out += ".*"; i += 2
        elif g[i] == "*":
            out += "[^/]*"; i += 1
        elif g[i] == "?":
            out += "[^/]"; i += 1
        else:
            out += re.escape(g[i]); i += 1
    if not anchored:
        out = "(?:.*/)?" + out
    return re.compile(out + "(?:/.*)?\\Z")

supp = []
if supp_path:
    if not os.path.isabs(supp_path):
        supp_path = os.path.join(repo, supp_path)
    if os.path.isfile(supp_path):
        try:
            entries = yaml.safe_load(open(supp_path)) or []
        except yaml.YAMLError:
            die("suppressions.yaml does not parse")
        for e in entries if isinstance(entries, list) else []:
            if isinstance(e, dict) and e.get("path"):
                supp.append((glob_rx(str(e["path"])), set(e.get("scanners") or []), set(e.get("rules") or [])))

def suppressed(f):
    rule, p, _, _, scanner = f
    if scanner == "audit":
        return False
    for rx, scanners, rules in supp:
        if rx.match(p) and ((not scanners and not rules) or scanner in scanners or rule in rules):
            return True
    return False

uniq = set(findings)
kept = sorted((f for f in uniq if not suppressed(f)), key=lambda f: (f[1], f[2], f[0]))

# Never print a term: redact any term that appears in a PII/repo finding path.
terms = []
tf = os.path.join(work, "terms.txt")
if os.path.isfile(tf):
    terms = sorted({t.strip() for t in open(tf, encoding="utf-8", errors="replace") if t.strip()}, key=len, reverse=True)
def safe(p):
    for t in terms:
        p = re.sub(re.escape(t), "[REDACTED]", p, flags=re.I)
    return p

for rule, p, n, sev, _ in kept:
    print("%s|%s|%d|%s" % (rule, safe(p), n, sev))
print("hq-core-review: findings=%d suppressed=%d added_lines=%d" % (len(kept), len(uniq) - len(kept), len(added)))
with open(os.path.join(work, "result.json"), "w") as fh:
    json.dump({"findings": len(kept), "suppressed": len(uniq) - len(kept),
               "rules": sorted({f[0] for f in kept})}, fh)
sys.exit(1 if kept else 0)
PY
rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || fail "the PII/policy scan did not run (exit $rc)"
FINDINGS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["findings"])' "$WORK/result.json")" \
  || fail "the scan wrote no result"

# --- 6. marker ------------------------------------------------------------------
if [ "$rc" = 1 ] && [ "$ACCEPT" != 1 ]; then
  echo "result=findings pr=$PR head=$HEAD_SHA findings=$FINDINGS (no marker written)"
  echo "Show these to the user. If they accept them for this PR, rerun with --accept \"<what they accepted>\"."
  exit 1
fi
RESULT=clean
[ "$rc" = 1 ] && RESULT=accepted
MARKER_DIR="$HQ_ROOT/workspace/hq-core-review"
mkdir -p "$MARKER_DIR" || fail "cannot create $MARKER_DIR"
MARKER="$MARKER_DIR/hq-core-staging-$PR-$HEAD_SHA.json"
python3 - "$MARKER" "$PR" "$HEAD_SHA" "$RESULT" "$ENABLED" "$WORK/result.json" "$ACCEPT_REASON" <<'PY' || fail "cannot write the marker"
import datetime, json, os, sys
marker, pr, sha, result, enabled, res, reason = sys.argv[1:8]
r = json.load(open(res))
doc = {"pr": int(pr), "head_sha": sha, "result": result, "skipped_scanners": [],
       "scanners_run": enabled.split(), "findings": r["findings"], "suppressed": r["suppressed"],
       "rules": r["rules"], "runner": ".claude/audit/hq-core-review-run.sh",
       "reviewed_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
if result == "accepted":
    doc["accepted_reason"] = reason
tmp = marker + ".tmp"
with open(tmp, "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
os.chmod(tmp, 0o644)
os.replace(tmp, marker)
PY
echo "result=$RESULT pr=$PR head=$HEAD_SHA findings=$FINDINGS"
echo "marker=$MARKER"
exit 0
