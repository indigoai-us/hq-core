#!/usr/bin/env bash
# pr-checks-minimal-actions.test.sh - regression test for the GitHub Actions
# cost cut (2026-10-19): Linux checks on ready PRs, one nightly run of the
# required checks and the GitHub-hosted macOS/Windows smoke, the smoke again
# on staging release tags, nothing on a branch push.
#
# Pins the contract:
#   - pr-checks triggers are exactly pull_request, workflow_dispatch, one
#     nightly schedule and push for stable v* tags only, never v*-* pre-release
#     tags (no branches, no paths).
#   - Job reachability, evaluated from each job's `if:` for every event:
#       * the 16 required-on-schedule checks run on ready PRs, dispatch and the schedule;
#       * every other Linux job runs only on ready PRs and dispatch;
#       * shell-smoke-macos, shell-smoke-windows and codex-windows-hook-launcher
#         run only on dispatch, the schedule and staging release tags, never
#         on pull requests;
#       * on a staging release tag only those three jobs and denylist-scan
#         (which computes their path gates) run; an hq-core tag runs nothing;
#       * nothing runs on a branch push or a draft PR.
#   - A push condition appears only as the exact staging release-tag clause.
#   - On the schedule and on tags, the smoke path detectors get an empty base
#     and every should-run-*.sh detector returns run=true for an empty base;
#     the codex Windows filter forces run=true on dispatch, the schedule and
#     tag pushes.
#   - codex-windows-hooks (real Codex on Windows) never runs on pull requests:
#     its triggers are exactly workflow_dispatch, one nightly schedule and
#     push for stable v* tags only, never v*-* pre-release tags.
#   - HQ_*_RUNNER* variables appear only in the guarded staging runs-on form
#     (staging repo, never a fork PR, hosted Linux fallback, or windows-latest
#     for codex-windows-hooks). The macOS and Windows smoke jobs in pr-checks
#     stay on GitHub-hosted runners.
#     runner-cost-arm-labels.test.sh pins the per-job runner labels.
#   - The grouped linux-checks-N jobs count as Linux jobs: they run on ready
#     PRs and dispatch only, never on the schedule.
#   - resumework-benchmark runs on pull requests only with the `benchmark`
#     label, still supports workflow_dispatch, and an unrelated label event
#     does not cancel a benchmark run in progress.
#   - hq CLI floor parity runs only the Linux leg on pull requests; the macOS
#     and Windows legs run only on workflow_dispatch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PR_CHECKS="$ROOT/.github/workflows/pr-checks.yml"
BENCH="$ROOT/.github/workflows/resumework-benchmark.yml"
FLOOR="$ROOT/.github/workflows/hq-cli-floor-parity.yml"
CODEX_WIN="$ROOT/.github/workflows/codex-windows-hooks.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Top-level `on:` block (from `on:` to the next top-level key).
on_block() {
  awk '
    /^on:[[:space:]]*$/ { in_on=1; next }
    in_on && /^[^[:space:]#]/ { exit }
    in_on { print }
  ' "$1"
}

# One job body under `jobs:` (from `  <name>:` to the next job key).
job_block() {
  awk -v job="$2" '
    $0 == "  " job ":" { in_job=1; print; next }
    in_job && /^  [[:alnum:]_-]+:[[:space:]]*$/ { exit }
    in_job { print }
  ' "$1"
}

# The job-level `if:` expression (single line or folded `>-` block).
job_if() {
  awk '
    /^    if:/ { in_if=1; print; next }
    in_if && /^      / { print; next }
    in_if { exit }
  ' <<< "$1"
}


# --- pr-checks triggers and job reachability --------------------------------
PR_ON="$(on_block "$PR_CHECKS")"
[[ -n "$PR_ON" ]] || fail 'could not read the pr-checks on: block'
# A push condition may appear only as the staging release-tag clause, and only
# in the three smoke jobs and denylist-scan (which computes their path gates).
TAG_CLAUSE="(github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') && github.repository == 'indigoai-us/hq-core-staging')"
push_lines="$(grep -F "github.event_name == 'push'" "$PR_CHECKS" || true)"
[[ -n "$push_lines" ]] || fail 'expected the staging release-tag clause in pr-checks'
while IFS= read -r line; do
  grep -Fq "$TAG_CLAUSE" <<< "$line" \
    || fail "push condition outside the staging release-tag clause: $line"
  [[ "$(grep -Fo "github.event_name == 'push'" <<< "$line" | wc -l | tr -d ' ')" == "$(grep -Fo "$TAG_CLAUSE" <<< "$line" | wc -l | tr -d ' ')" ]] \
    || fail "push condition outside the staging release-tag clause: $line"
done <<< "$push_lines"
tag_jobs="$(awk -v clause="$TAG_CLAUSE" '
  /^jobs:/ { in_jobs=1; next }
  in_jobs && /^  [[:alnum:]_-]+:[[:space:]]*$/ { job=$1; sub(/:$/, "", job); next }
  in_jobs && index($0, clause) { print job }
' "$PR_CHECKS" | sort -u | tr '\n' ' ')"
[[ "$tag_jobs" == 'codex-windows-hook-launcher denylist-scan shell-smoke-macos shell-smoke-windows ' ]] \
  || fail "unexpected jobs keyed on release tags: $tag_jobs"

python3 - "$PR_CHECKS" <<'PY'
import itertools
import re
import sys

try:
    import yaml
except ImportError as exc:
    raise SystemExit("FAIL: pr-checks-minimal-actions requires PyYAML") from exc

workflow = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
failures = []

triggers = workflow.get(True, workflow.get("on"))
if not isinstance(triggers, dict):
    raise SystemExit("FAIL: pr-checks on: must be a mapping")
if sorted(triggers) != ["pull_request", "push", "schedule", "workflow_dispatch"]:
    failures.append(f"pr-checks triggers must be exactly pull_request, push, schedule, workflow_dispatch; got {sorted(triggers)}")
if triggers.get("push") != {"tags": ["v*", "!v*-*"]}:
    failures.append(f"pr-checks push must be stable v* tags only (tags: ['v*', '!v*-*']), with no branches or paths; got {triggers.get('push')}")


def tag_triggers(patterns, tag):
    # GitHub filter semantics: * matches any run of characters except '/',
    # patterns apply in order, a '!' pattern excludes, and the last match wins.
    matched = False
    for pattern in patterns:
        negate = pattern.startswith("!")
        body = pattern[1:] if negate else pattern
        rx = "".join("[^/]*" if ch == "*" else re.escape(ch) for ch in body)
        if re.fullmatch(rx, tag):
            matched = not negate
    return matched


push_tags = (triggers.get("push") or {}).get("tags") or []
for tag, want in (("v1.2.3", True), ("v16.0.31", True),
                  ("v1.2.3-beta.1", False), ("v16.0.31-beta.19", False), ("v1.2.3-rc.1", False),
                  ("release-1", False)):
    if tag_triggers(push_tags, tag) != want:
        failures.append(f"tag {tag} must {'start' if want else 'not start'} pr-checks; push tags are {push_tags}")
schedule = triggers.get("schedule") or []
if len(schedule) != 1 or not re.fullmatch(r"\d+ \d+ \* \* \*", str(schedule[0].get("cron", ""))):
    failures.append(f"pr-checks must have exactly one nightly cron schedule; got {schedule}")
pr = triggers.get("pull_request") or {}
if pr.get("branches") != ["main"]:
    failures.append("pull_request must stay limited to PRs against main")

REQUIRED = set("""auto-acl-share-hooks auto-checkpoint-cmds collect-policy-changes
core-write-protection denylist-scan dm-people-resolve git-mutation-guard
install-deps policy-rationale-scan provenance-stripped public-frontmatter-revalidate
settings-local-not-ignored skill-command-refs users-path-tripwire vendor-public-ok
prefer-native-capabilities""".split())
SMOKE = {"shell-smoke-macos", "shell-smoke-windows", "codex-windows-hook-launcher"}
jobs = workflow["jobs"]
for name in REQUIRED | SMOKE:
    if name not in jobs:
        failures.append(f"job {name} is missing (do not rename or remove it)")
    elif jobs[name].get("name", name) != name:
        failures.append(f"job {name} must keep its check name")

EVENTS = {
    "pr_ready": {"event_name": "pull_request", "draft": False, "ref": "refs/pull/1/merge"},
    "pr_draft": {"event_name": "pull_request", "draft": True, "ref": "refs/pull/1/merge"},
    "dispatch": {"event_name": "workflow_dispatch", "draft": None, "ref": "refs/heads/main"},
    "schedule": {"event_name": "schedule", "draft": None, "ref": "refs/heads/main"},
    # The push trigger is tags-only; evaluate a main push anyway so a
    # condition cannot depend on a branch push.
    "push_main": {"event_name": "push", "draft": None, "ref": "refs/heads/main"},
    "push_tag": {"event_name": "push", "draft": None, "ref": "refs/tags/v16.0.31"},
    "push_tag_hq_core": {"event_name": "push", "draft": None, "ref": "refs/tags/v16.0.31",
                         "repo": "indigoai-us/hq-core"},
}
KNOWN = {
    "github.event_name": lambda e: repr(e["event_name"]),
    "github.event.pull_request.draft": lambda e: repr(e["draft"]),
    "github.ref": lambda e: repr(e["ref"]),
    "github.repository": lambda e: repr(e.get("repo", "indigoai-us/hq-core-staging")),
}
# Anything that depends on another job's result, outputs, or PR labels is a
# free boolean: "reachable" means some combination lets the job run.
FREE = re.compile(
    r"(?:needs(?:\[['\"][\w-]+['\"]\]|\.[\w-]+)\.(?:result|outputs\.[\w-]+)\s*(?:==|!=)\s*'[^']*')"
    r"|contains\(github\.event\.pull_request\.labels\.\*\.name,\s*'[^']*'\)"
)


def compile_if(expr):
    if expr is None:
        return lambda env, free: True, 0
    text = str(expr).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    text = " ".join(text.split())
    frees = []

    def free_sub(match):
        frees.append(match.group(0))
        return f" F[{len(frees) - 1}] "

    text = FREE.sub(free_sub, text)
    text = text.replace("always()", "True").replace("!cancelled()", "True").replace("cancelled()", "False")
    text = re.sub(r"startsWith\(", "starts_with(", text)
    text = text.replace("&&", " and ").replace("||", " or ")
    text = re.sub(r"!(?!=)", " not ", text)
    text = text.replace("true", "True").replace("false", "False")
    for key in sorted(KNOWN, key=len, reverse=True):
        text = text.replace(key, "{" + key + "}")
    leftover = re.findall(r"(?<![{\w.])(?:github|needs|inputs|env|vars)\.[\w.\[\]'*-]+", text)
    if leftover:
        raise SystemExit(f"FAIL: unsupported expression term(s) {leftover} in: {expr}")
    code = text

    def run(env, free):
        src = code
        for key, fmt in KNOWN.items():
            src = src.replace("{" + key + "}", fmt(env))
        return bool(eval(src, {"F": free, "starts_with": lambda a, b: str(a).startswith(b)}))

    return run, len(frees)


def reachable(job, env):
    fn, nfree = compile_if(job.get("if"))
    return any(fn(env, combo) for combo in itertools.product([True, False], repeat=nfree))


# A staging Linux job may pick a self-hosted label from a repository variable,
# but its hosted fallback (the label used on hq-core, on fork PRs and when the
# variable is unset) must be a GitHub-hosted Ubuntu label.
HOSTED_FALLBACK = re.compile(r"^\$\{\{ .* \|\| '(ubuntu-[\w.-]+)' \}\}$")


def is_linux(job):
    runner = str(job.get("runs-on", ""))
    return runner.startswith("ubuntu") or bool(HOSTED_FALLBACK.match(runner))


linux = {n for n, j in jobs.items() if is_linux(j)}
grouped = {n for n in jobs if re.fullmatch(r"linux-checks-\d+", n)}
if not grouped:
    failures.append("expected the grouped linux-checks-N jobs")
for name, job in jobs.items():
    reach = {ev: reachable(job, env) for ev, env in EVENTS.items()}
    if reach["pr_draft"]:
        failures.append(f"{name} must not run on draft PRs")
    if reach["push_main"]:
        failures.append(f"{name} must not run on a branch push")
    if reach["push_tag_hq_core"]:
        failures.append(f"{name} must not run on an hq-core tag push")
    if reach["push_tag"] and name not in SMOKE | {"denylist-scan"}:
        failures.append(f"{name} must not run on release tags")
    if name in REQUIRED:
        for ev in ("pr_ready", "dispatch", "schedule"):
            if not reach[ev]:
                failures.append(f"required check {name} must run on {ev}")
        if name == "denylist-scan" and not reach["push_tag"]:
            failures.append("denylist-scan must run on release tags (it computes the smoke path gates)")
    elif name in SMOKE:
        for ev in ("dispatch", "schedule", "push_tag"):
            if not reach[ev]:
                failures.append(f"smoke job {name} must run on {ev}")
        if reach["pr_ready"]:
            failures.append(f"smoke job {name} must never run on pull requests")
    else:
        if name not in linux:
            failures.append(f"non-required job {name} must run on Linux")
        if reach["schedule"]:
            failures.append(f"non-required job {name} must not run on the schedule")

if failures:
    for message in failures:
        print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)
print(f"PASS: pr-checks reachability ({len(REQUIRED)} required, {len(SMOKE)} smoke, "
      f"{len(jobs) - len(REQUIRED) - len(SMOKE)} PR/dispatch-only jobs)")
PY

# --- smoke path gates are kept and fail open on the schedule and tags -------
for job in shell-smoke-macos shell-smoke-windows codex-windows-hook-launcher; do
  cond="$(job_if "$(job_block "$PR_CHECKS" "$job")")"
  grep -Fq "(github.event_name == 'workflow_dispatch' || github.event_name == 'schedule' || $TAG_CLAUSE)" <<< "$cond" \
    || fail "$job condition must name exactly dispatch, the schedule and staging release tags"
done
grep -Fq "needs['denylist-scan'].outputs.macos_shell_smoke == 'true'" <<< "$(job_block "$PR_CHECKS" shell-smoke-macos)" \
  || fail 'shell-smoke-macos must keep its path gate'
grep -Fq "needs['denylist-scan'].outputs.windows_shell_smoke == 'true'" <<< "$(job_block "$PR_CHECKS" shell-smoke-windows)" \
  || fail 'shell-smoke-windows must keep its path gate'

DENYLIST_JOB="$(job_block "$PR_CHECKS" denylist-scan)"
for step_id in shell_smoke_macos_paths shell_smoke_windows_paths resumework_timing_paths; do
  step="$(sed -n "/id: $step_id\$/,/GITHUB_OUTPUT/p" <<< "$DENYLIST_JOB")"
  [[ -n "$step" ]] || fail "denylist-scan is missing the $step_id detector"
  grep -Fq "elif [[ \"\$GITHUB_EVENT_NAME\" == 'schedule' || \"\$GITHUB_REF\" == refs/tags/* ]]; then" <<< "$step" \
    || fail "$step_id must special-case the schedule and release tags"
  sed -n "/== refs\/tags\/\* ]]; then/,/^          else/p" <<< "$step" | grep -Fqx "            base_sha=''" \
    || fail "$step_id must pass an empty base on the schedule and release tags"
done

# Every detector must fail open (run=true) for an empty base.
DETECT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pr-checks-minimal-actions.XXXXXX")"
trap 'rm -rf "$DETECT_TMP"' EXIT
git -C "$DETECT_TMP" init -q
git -C "$DETECT_TMP" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m base
mkdir -p "$DETECT_TMP/docs"
printf 'doc\n' > "$DETECT_TMP/docs/readme.md"
git -C "$DETECT_TMP" add docs/readme.md
git -C "$DETECT_TMP" -c user.name=t -c user.email=t@example.invalid commit -q -m 'docs only'
detect_head="$(git -C "$DETECT_TMP" rev-parse HEAD)"
detect_base="$(git -C "$DETECT_TMP" rev-parse HEAD~1)"
for detector in should-run-macos-shell-smoke.sh should-run-windows-shell-smoke.sh should-run-resumework-timing.sh; do
  result="$(bash "$ROOT/core/scripts/ci/$detector" '' "$detect_head" "$DETECT_TMP")"
  [[ "$result" == 'run=true' ]] || fail "$detector must return run=true for an empty base, got: $result"
done
# Control: with a real base, a docs-only change does not trigger the smoke jobs,
# so run=true above comes from the empty base.
for detector in should-run-macos-shell-smoke.sh should-run-windows-shell-smoke.sh; do
  result="$(bash "$ROOT/core/scripts/ci/$detector" "$detect_base" "$detect_head" "$DETECT_TMP")"
  [[ "$result" == 'run=false' ]] || fail "$detector control: docs-only change should give run=false, got: $result"
done

# The codex Windows filter forces run=true on dispatch, the schedule and tag
# pushes (the job is reachable on push only for staging release tags).
CODEX_FILTER="$(job_block "$PR_CHECKS" codex-windows-hook-launcher | sed -n '/id: filter/,/GITHUB_OUTPUT/p')"
grep -A1 -F 'if [ "${{ github.event_name }}" = "workflow_dispatch" ] \' <<< "$CODEX_FILTER" \
  | grep -Fq '|| [ "${{ github.event_name }}" = "schedule" ] \' \
  || fail 'codex-windows-hook-launcher filter must force run=true on workflow_dispatch and the schedule'
grep -A1 -F '|| [ "${{ github.event_name }}" = "schedule" ] \' <<< "$CODEX_FILTER" \
  | grep -Fq '|| [ "${{ github.event_name }}" = "push" ]; then' \
  || fail 'codex-windows-hook-launcher filter must force run=true on release tag pushes'
grep -A1 -F '|| [ "${{ github.event_name }}" = "push" ]; then' <<< "$CODEX_FILTER" | grep -Fq 'echo "run=true" >> "$GITHUB_OUTPUT"' \
  || fail 'codex-windows-hook-launcher filter must output run=true on workflow_dispatch, the schedule and release tags'

# HQ_*_RUNNER* variables only in the guarded staging runs-on form: staging
# repo only, never a fork PR, and a GitHub-hosted Linux fallback.
guard="\${{ github.repository == 'indigoai-us/hq-core-staging' && (github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository) && "
runner_lines="$(grep -RhE 'HQ_[A-Z0-9_]*RUNNER' "$ROOT/.github/workflows" | sed -E 's/^ +//')"
[[ -n "$runner_lines" ]] || fail 'expected staging runs-on lines that read the runner variables'
while IFS= read -r line; do
  case "$line" in
    "runs-on: ${guard}fromJSON(vars.HQ_STAGING_RUNNER_LINUX_ARM || '\"ubuntu-24.04-arm\"') || 'ubuntu-24.04-arm' }}") ;;
    "runs-on: ${guard}fromJSON(vars.HQ_STAGING_RUNNER_LINUX || '\"ubuntu-latest\"') || 'ubuntu-latest' }}") ;;
    "runs-on: ${guard}matrix.os == 'ubuntu-latest' && fromJSON(vars.HQ_STAGING_RUNNER_LINUX || '\"ubuntu-latest\"') || matrix.os }}") ;;
    "runs-on: ${guard}fromJSON(vars.HQ_STAGING_RUNNER_WINDOWS || '\"windows-latest\"') || 'windows-latest' }}") ;;
    *) fail "runner variable used outside the guarded staging runs-on form: $line" ;;
  esac
done <<< "$runner_lines"

# Evaluate every guarded runs-on line. A fork PR (head.repo.fork true, head
# repo outside the staging repo) and hq-core must always get the hosted label,
# even with the variable set. Same-repo staging events get the variable's
# value, whether it holds a JSON array or a JSON string.
python3 - "$ROOT/.github/workflows" <<'PY'
import json
import os
import re
import sys

wf_dir = sys.argv[1]
STAGING = "indigoai-us/hq-core-staging"
TOKEN = re.compile(r"\s*(?:('(?:[^']|'')*')|(&&|\|\||==|!=|!|\(|\))|([A-Za-z_][\w.-]*))")


def evaluate(expr, ctx):
    body = expr.strip()
    if not (body.startswith("${{") and body.endswith("}}")):
        raise SystemExit(f"FAIL: runs-on is not a single expression: {expr}")
    body = body[3:-2]
    out, pos = [], 0
    while pos < len(body):
        m = TOKEN.match(body, pos)
        if not m or m.end() == pos:
            if body[pos:].strip():
                raise SystemExit(f"FAIL: cannot parse runs-on at {body[pos:]!r}: {expr}")
            break
        pos = m.end()
        lit, op, ident = m.groups()
        if lit is not None:
            out.append(repr(lit[1:-1].replace("''", "'")))
        elif op:
            out.append({"&&": " and ", "||": " or ", "!": " not "}.get(op, f" {op} "))
        elif ident == "fromJSON":
            out.append("from_json")
        elif ident in ctx:
            out.append(repr(ctx[ident]))
        elif ident.startswith("vars."):
            out.append(repr(""))
        else:
            raise SystemExit(f"FAIL: unexpected term {ident} in runs-on: {expr}")
    return eval("".join(out), {"from_json": json.loads, "__builtins__": {}})


def context(repo, event, fork, var_value, var_name, matrix_os):
    ctx = {
        "github.repository": repo,
        "github.event_name": event,
        "matrix.os": matrix_os,
    }
    if event == "pull_request":
        ctx["github.event.pull_request.head.repo.full_name"] = (
            "someone/hq-core-staging" if fork else repo)
        ctx["github.event.pull_request.head.repo.fork"] = fork
    else:
        ctx["github.event.pull_request.head.repo.full_name"] = ""
        ctx["github.event.pull_request.head.repo.fork"] = ""
    if var_value is not None:
        ctx[f"vars.{var_name}"] = var_value
    return ctx


ARRAY = ["self-hosted", "linux", "x64"]
VALUES = {"unset": None, "array": json.dumps(ARRAY), "string": json.dumps("custom-label")}
failures, checked = [], 0
for name in sorted(os.listdir(wf_dir)):
    if not name.endswith(".yml"):
        continue
    for line in open(os.path.join(wf_dir, name), encoding="utf-8"):
        m = re.match(r"^\s*runs-on: (\$\{\{.*\}\})\s*$", line)
        if not m or "HQ_STAGING_RUNNER" not in m.group(1):
            continue
        expr = m.group(1)
        var = re.search(r"vars\.(HQ_STAGING_RUNNER_[A-Z_]+)", expr).group(1)
        matrix = "matrix.os" in expr
        hosted_label = None if matrix else re.search(r"\|\| '([\w.-]+)' \}\}$", expr).group(1)
        for os_label in (["ubuntu-latest", "macos-latest", "windows-latest"] if matrix else [None]):
            hosted = os_label if matrix else hosted_label
            linux = not matrix or os_label == "ubuntu-latest"
            for key, value in VALUES.items():
                want_self = {"unset": hosted, "array": ARRAY, "string": "custom-label"}[key]
                cases = [
                    (STAGING, "pull_request", False, want_self if linux else hosted),
                    (STAGING, "push", False, want_self if linux else hosted),
                    (STAGING, "workflow_dispatch", False, want_self if linux else hosted),
                    (STAGING, "pull_request", True, hosted),
                    ("indigoai-us/hq-core", "push", False, hosted),
                    ("indigoai-us/hq-core", "pull_request", False, hosted),
                ]
                for repo, event, fork, want in cases:
                    got = evaluate(expr, context(repo, event, fork, value, var, os_label))
                    checked += 1
                    if got != want:
                        failures.append(
                            f"{name}: {repo} {event} fork={fork} {var}={key} matrix.os={os_label}: "
                            f"expected {want!r}, got {got!r}")
if not checked:
    failures.append("no guarded runs-on lines were evaluated")
if failures:
    for message in failures:
        print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)
print(f"PASS: guarded runs-on evaluation ({checked} cases; fork PRs and hq-core stay hosted)")
PY

# No other pr-checks job may use a GitHub-hosted macOS or Windows runner.
hosted_platform_jobs="$(awk '
  /^jobs:/ { in_jobs=1; next }
  in_jobs && /^  [[:alnum:]_-]+:[[:space:]]*$/ { job=$1; sub(/:$/, "", job); next }
  in_jobs && /^    runs-on:/ && /(macos|windows)-/ { print job }
' "$PR_CHECKS" | sort | tr '\n' ' ')"
[[ "$hosted_platform_jobs" == 'codex-windows-hook-launcher shell-smoke-macos shell-smoke-windows ' ]] \
  || fail "unexpected hosted macOS/Windows jobs in pr-checks: $hosted_platform_jobs"

# --- codex-windows-hooks: never on pull requests, stable tags only ----------
python3 - "$CODEX_WIN" <<'PY'
import re
import sys

import yaml

workflow = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
failures = []
triggers = workflow.get(True, workflow.get("on"))
if not isinstance(triggers, dict):
    raise SystemExit("FAIL: codex-windows-hooks on: must be a mapping")
if sorted(triggers) != ["push", "schedule", "workflow_dispatch"]:
    failures.append("codex-windows-hooks triggers must be exactly push, schedule, workflow_dispatch "
                    f"(never pull_request or pull_request_target); got {sorted(triggers)}")
if triggers.get("push") != {"tags": ["v*", "!v*-*"]}:
    failures.append("codex-windows-hooks push must be stable v* tags only (tags: ['v*', '!v*-*']), "
                    f"with no branches or paths; got {triggers.get('push')}")


def tag_triggers(patterns, tag):
    # GitHub filter semantics: * matches any run of characters except '/',
    # patterns apply in order, a '!' pattern excludes, and the last match wins.
    matched = False
    for pattern in patterns:
        negate = pattern.startswith("!")
        body = pattern[1:] if negate else pattern
        rx = "".join("[^/]*" if ch == "*" else re.escape(ch) for ch in body)
        if re.fullmatch(rx, tag):
            matched = not negate
    return matched


push_tags = (triggers.get("push") or {}).get("tags") or []
for tag, want in (("v1.2.3", True), ("v16.0.31", True),
                  ("v1.2.3-beta.1", False), ("v16.0.31-beta.23", False), ("v1.2.3-rc.1", False),
                  ("release-1", False)):
    if tag_triggers(push_tags, tag) != want:
        failures.append(f"tag {tag} must {'start' if want else 'not start'} codex-windows-hooks; push tags are {push_tags}")
schedule = triggers.get("schedule") or []
if len(schedule) != 1 or not re.fullmatch(r"\d+ \d+ \* \* \*", str(schedule[0].get("cron", ""))):
    failures.append(f"codex-windows-hooks must have exactly one nightly cron schedule; got {schedule}")
if failures:
    for message in failures:
        print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)
print("PASS: codex-windows-hooks runs only on dispatch, nightly and stable v* tags")
PY

# --- resumework-benchmark is label-gated on pull requests -------------------
BENCH_ON="$(on_block "$BENCH")"
grep -Eq '^  workflow_dispatch:' <<< "$BENCH_ON" \
  || fail 'resumework-benchmark must keep workflow_dispatch'
grep -Eq '^    types: \[.*labeled.*\]' <<< "$BENCH_ON" \
  || fail 'resumework-benchmark pull_request types must include labeled'
BENCH_JOB="$(job_block "$BENCH" benchmark)"
BENCH_IF="$(job_if "$BENCH_JOB")"
grep -Fq "contains(github.event.pull_request.labels.*.name, 'benchmark')" <<< "$BENCH_IF" \
  || fail 'resumework-benchmark must run on pull requests only with the benchmark label'
grep -Fq "github.event_name == 'pull_request'" <<< "$BENCH_IF" \
  || fail 'the benchmark label gate must apply to pull_request events'
grep -Fq "github.event_name == 'workflow_dispatch' && inputs.scale_only != true" <<< "$BENCH_IF" \
  || fail 'resumework-benchmark must still run on workflow_dispatch'
BENCH_CONCURRENCY="$(sed -n '/^concurrency:$/,/^jobs:$/p' "$BENCH")"
grep -Fqx "  cancel-in-progress: \${{ github.event.action != 'labeled' || github.event.label.name == 'benchmark' }}" <<< "$BENCH_CONCURRENCY" \
  || fail 'an unrelated label event must not cancel a resumework benchmark run in progress'
if grep -Fqx '  cancel-in-progress: true' <<< "$BENCH_CONCURRENCY"; then
  fail 'resumework-benchmark must not cancel unconditionally (unrelated labels would cancel a running benchmark)'
fi
# --- promote-to-hq-core runs are never cancelled ----------------------------
PROMOTE_CONCURRENCY="$(sed -n '/^concurrency:$/,/^jobs:$/p' "$ROOT/.github/workflows/promote-to-hq-core.yml")"
grep -Fqx '  group: promote-to-hq-core-${{ github.ref }}' <<< "$PROMOTE_CONCURRENCY" \
  || fail 'promote-to-hq-core must serialize runs per ref'
grep -Fqx '  cancel-in-progress: false' <<< "$PROMOTE_CONCURRENCY" \
  || fail 'promote-to-hq-core must never cancel a run in progress'

LOCK_IF="$(job_if "$(job_block "$BENCH" lock-scale)")"
grep -Fq "github.event_name == 'workflow_dispatch'" <<< "$LOCK_IF" \
  || fail 'resumework lock-scale must stay dispatch-only'

# --- hq CLI floor parity: Linux on PRs, macOS/Windows by hand ---------------
FLOOR_ON="$(on_block "$FLOOR")"
grep -Eq '^  pull_request:' <<< "$FLOOR_ON" || fail 'floor parity must keep pull_request for the Linux leg'
grep -Eq '^  workflow_dispatch:' <<< "$FLOOR_ON" || fail 'floor parity must offer workflow_dispatch'
if grep -Eq '^  push:' <<< "$FLOOR_ON"; then
  fail 'floor parity must not run on push'
fi
os_line="$(grep -E '^        os:' "$FLOOR")"
[[ "$(grep -c . <<< "$os_line")" -eq 1 ]] || fail 'floor parity must define exactly one matrix os line'
grep -Fq "github.event_name == 'workflow_dispatch' && '[\"ubuntu-latest\",\"macos-latest\",\"windows-latest\"]'" <<< "$os_line" \
  || fail 'floor parity must run macOS and Windows legs only on workflow_dispatch'
grep -Fq "|| '[\"ubuntu-latest\"]'" <<< "$os_line" \
  || fail 'floor parity must run only the Linux leg on pull requests'

echo 'PASS: pr-checks minimal Actions contract (tag-only push trigger, codex-windows-hooks never on PRs and stable tags only, nightly required checks and macOS/Windows smoke, smoke on staging release tags and never on PRs, label-gated benchmark, Linux-only floor parity on PRs)'
