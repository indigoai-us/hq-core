#!/usr/bin/env bash
# hq-core: public
# lanes-workers.sh — the mechanical parts of `/conduct --workers`: role lanes
# pinned to one engine, model and effort for the session, per-role brief
# templates, the CI check after a lane opens a PR, and the QA trigger.
# Role lanes on runners belong to /conduct-runners, the advanced mode of
# /conduct. This script never calls `hq runners` (or its old `hq lanes` alias).
#
# Usage:
#   bash core/scripts/lanes-workers.sh setup --workers <r1,r2,...> \
#        [--engine claude|codex|grok] [--model <m>] [--effort <f>] \
#        [--runner subagent|runner] [--session-id <id>]
#     Validates the role list and persists conduct_lane_roles, conduct_engine,
#     conduct_child_model and conduct_child_effort in session meta. Omitted
#     engine/model/effort keep their current session value. The runner comes
#     from conduct-runner-resolve.sh (legacy mixed and lane read as runner).
#     Under subagent (the default) each role is recorded as a pending standing
#     subagent lane in workspace/orchestrator/conduct-subagents/<sid>/runs.json
#     (backing "subagent"); the conductor starts it with the Agent tool. Under
#     runner no runs.json row is written: the lanes are listed with backing
#     "runner" for /conduct-runners to open with conduct-standing.sh send.
#     Prints the result as JSON; "engine": null means the conductor still has
#     to resolve one.
#
#   bash core/scripts/lanes-workers.sh roles [--session-id <id>]
#     Prints the session's role lanes and pins as JSON.
#
#   bash core/scripts/lanes-workers.sh template --role <role>
#     Prints the brief template path for the role (generic.md when the role
#     has no template of its own).
#
#   bash core/scripts/lanes-workers.sh needs-qa [--role <role>] [--file <path>]... [--pr <url> [--repo <owner/repo>]]
#     Exit 0 and prints "yes" when the change needs a QA lane: the role is
#     frontend or designer, or a changed file is UI (svelte, tsx, jsx, vue, css,
#     scss, sass, less, html). Exit 1 and prints "no" otherwise. With --pr the
#     changed files come from `gh pr view`; a gh failure exits 2.
#
#   bash core/scripts/lanes-workers.sh ci --pr <url|number> [--repo <owner/repo>] \
#        [--timeout <secs>] [--interval <secs>] [--settle <secs>]
#     Waits (bounded, default 1200s) for the PR's checks and prints JSON
#     {state, failing, pending, passed}. Fails closed: if gh cannot report the
#     checks the state is "error", never "pass". A pass is only reported after
#     --settle seconds (default 120) and two polls with the same set of checks,
#     because a fresh push registers its check suites over a minute or two.
#     Exit 0 pass, 1 fail, 2 still pending at the timeout, 3 error,
#     4 no checks reported.
#
#   bash core/scripts/lanes-workers.sh ci-round --pr <url> [--session-id <id>] [--max <n>]
#     Counts one CI fix round for the PR and prints the new count. Exit 4 once
#     the count passes --max (default 3): stop resuming the lane and take it to
#     the owner through /decision-queue.

set -euo pipefail

ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
ROLES_DIR="$ROOT/.claude/skills/conduct/roles"

usage() { sed -n '3,51p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "lanes-workers: $*" >&2; exit 1; }
need_val() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }

SID=""
resolve_sid() {
  [ -n "$SID" ] || SID="$(bash "$ROOT/core/scripts/hq-session.sh" current 2>/dev/null || true)"
  [ -n "$SID" ] || die "no session id: pass --session-id or start an HQ session"
  case "$SID" in *[!A-Za-z0-9._-]*|.*) die "invalid session id: $SID" ;; esac
}
sget() { bash "$ROOT/core/scripts/hq-session.sh" --session-id "$SID" get "$1" 2>/dev/null || true; }
sset() { bash "$ROOT/core/scripts/hq-session.sh" --session-id "$SID" set "$1" "$2" >/dev/null; }

valid_role() {
  case "$1" in ''|[!a-z]*|*[!a-z0-9-]*|*-) return 1 ;; esac
  [ "${#1}" -le 32 ]
}

print_roles() {
  jq -cn --arg roles "$(sget conduct_lane_roles)" --arg engine "$(sget conduct_engine)" \
    --arg model "$(sget conduct_child_model)" --arg effort "$(sget conduct_child_effort)" \
    '{roles:($roles|split(",")|map(select(.!=""))),
      engine:(if $engine=="" then null else $engine end),
      model:(if $model=="" then null else $model end),
      effort:(if $effort=="" then null else $effort end)}'
}

# Prints subagent or runner for this session, through conduct-runner-resolve.sh.
resolve_runner() {
  local resolver="$ROOT/core/scripts/conduct-runner-resolve.sh"
  [ -f "$resolver" ] || { [ -z "$1" ] || [ "$1" = subagent ] || die "setup: no runner resolver for --runner $1"; printf subagent; return; }
  local out
  if [ -n "$1" ]; then
    out="$(sh "$resolver" --root "$ROOT" --session-id "$SID" --runner "$1")" || die "setup: cannot resolve the conduct runner"
  else
    out="$(sh "$resolver" --root "$ROOT" --session-id "$SID")" || die "setup: cannot resolve the conduct runner"
  fi
  case "$out" in subagent|runner) printf '%s' "$out" ;; *) die "setup: unexpected conduct runner: $out" ;; esac
}

# Prints a JSON object mapping each role in the comma list to its brief
# template, falling back to generic.md like `template` (null when neither
# exists).
role_templates() {
  local role out='{}' rel=".claude/skills/conduct/roles" t old_ifs="$IFS"
  IFS=','
  # shellcheck disable=SC2086
  set -- $1
  IFS="$old_ifs"
  for role in "$@"; do
    if [ -f "$ROLES_DIR/$role.md" ]; then t="$rel/$role.md"
    elif [ -f "$ROLES_DIR/generic.md" ]; then t="$rel/generic.md"
    else t=""; fi
    out="$(jq -c --arg r "$role" --arg t "$t" '. + {($r): (if $t=="" then null else $t end)}' <<<"$out")"
  done
  printf '%s' "$out"
}

# Writes one pending standing-subagent row per role into runs.json, replacing
# an earlier row for the same role. Temp file and mv, so readers never see a
# partial file.
record_subagent_lanes() {
  local dir="$ROOT/workspace/orchestrator/conduct-subagents/$SID" file tmp now
  file="$dir/runs.json"
  mkdir -p "$dir"
  now="$(date -u +%s)"
  tmp="$(mktemp "$dir/.runs.json.XXXXXX")"
  if [ -s "$file" ]; then cat "$file"; else echo '{"runs":[]}'; fi \
    | jq --arg roles "$1" --argjson now "$now" --argjson tmpl "$2" '
        ($roles|split(",")) as $r
        | (if type=="object" and (.runs|type)=="array" then . else {runs:[]} end)
        | .runs |= (map(select(((.lane.role? // null) as $x | $r | index($x)) | not))
            + ($r | map({agent_id:null, worker:., task:("standing " + . + " lane"),
                state:"pending", runner:"subagent", since:$now,
                lane:{lane_id:("role-" + .), role:., worker:., standing:true,
                  backing:"subagent", subagent_type:"general-purpose",
                  template:$tmpl[.],
                  last_task:null, state:"pending"}})))' > "$tmp" \
    || { rm -f "$tmp"; die "setup: cannot update $file"; }
  mv "$tmp" "$file"
}

cmd_setup() {
  local workers="" engine="" model="" effort="" runner="" role seen="," clean=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workers) need_val "$@"; workers="$2"; shift 2 ;;
      --engine) need_val "$@"; engine="$2"; shift 2 ;;
      --model) need_val "$@"; model="$2"; shift 2 ;;
      --effort) need_val "$@"; effort="$2"; shift 2 ;;
      --runner) need_val "$@"; runner="$2"; shift 2 ;;
      --session-id) need_val "$@"; SID="$2"; shift 2 ;;
      *) die "setup: unknown option: $1" ;;
    esac
  done
  [ -n "$workers" ] || die "setup: --workers is required (comma list, e.g. frontend,qa,orchestrator)"
  local old_ifs="$IFS"
  IFS=','
  # shellcheck disable=SC2086
  set -- $workers
  IFS="$old_ifs"
  for role in "$@"; do
    role="$(printf '%s' "$role" | tr -d ' ')"
    [ -n "$role" ] || continue
    valid_role "$role" || die "setup: invalid role name: '$role' (lowercase letters, digits, hyphens)"
    case "$seen" in *",$role,"*) continue ;; esac
    seen="$seen$role,"
    clean="${clean:+$clean,}$role"
  done
  [ -n "$clean" ] || die "setup: --workers named no roles"
  case "$engine" in ''|claude|codex|grok) ;; *) die "setup: unknown engine: $engine (claude, codex or grok)" ;; esac
  case "$model" in *[[:space:]]*) die "setup: invalid model name: $model" ;; esac
  case "$effort" in *[!a-z]*) die "setup: invalid effort: $effort" ;; esac
  resolve_sid
  runner="$(resolve_runner "$runner")"
  sset conduct_lane_roles "$clean"
  # Codex SessionStart may have supplied automatic engine/model/effort pins.
  # Explicit role-lane flags take precedence. When the user switches away from
  # Codex without replacement pins, clear only the automatic model/effort.
  local default_source
  default_source="$(sget conduct_default_source)"
  if [ -n "$engine$model$effort" ]; then
    case "$default_source" in
      codex-*)
        if [ -n "$engine" ] && [ "$engine" != codex ]; then
          [ -n "$model" ] || sset conduct_child_model ""
          [ -n "$effort" ] || sset conduct_child_effort ""
        fi
        ;;
    esac
    sset conduct_default_source explicit
  fi
  [ -z "$engine" ] || sset conduct_engine "$engine"
  [ -z "$model" ] || sset conduct_child_model "$model"
  [ -z "$effort" ] || sset conduct_child_effort "$effort"
  local backing=subagent tmpl
  tmpl="$(role_templates "$clean")"
  if [ "$runner" = subagent ]; then
    record_subagent_lanes "$clean" "$tmpl"
  else
    backing=runner
  fi
  print_roles | jq -c --arg runner "$runner" --arg backing "$backing" --arg roles "$clean" --argjson tmpl "$tmpl" '
    . + {runner:$runner,
         lanes:($roles|split(",")|map({lane_id:(if $backing=="subagent" then "role-" + . else null end),
           role:., standing:true, backing:$backing,
           template:$tmpl[.]}))}
    + (if $backing=="runner" then {note:"runner lanes: /conduct-runners opens each with conduct-standing.sh send"} else {} end)'
}

cmd_roles() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-id) need_val "$@"; SID="$2"; shift 2 ;;
      *) die "roles: unknown option: $1" ;;
    esac
  done
  resolve_sid
  print_roles
}

cmd_template() {
  local role=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --role) need_val "$@"; role="$2"; shift 2 ;;
      *) die "template: unknown option: $1" ;;
    esac
  done
  valid_role "$role" || die "template: invalid --role: '$role'"
  local rel=".claude/skills/conduct/roles"
  if [ -f "$ROLES_DIR/$role.md" ]; then
    printf '%s/%s.md\n' "$rel" "$role"
  elif [ -f "$ROLES_DIR/generic.md" ]; then
    printf '%s/generic.md\n' "$rel"
  else
    die "template: no template for '$role' and no generic.md in $rel"
  fi
}

is_ui_file() {
  case "$1" in
    *.svelte|*.tsx|*.jsx|*.vue|*.css|*.scss|*.sass|*.less|*.html|*.htm) return 0 ;;
  esac
  return 1
}

cmd_needs_qa() {
  local role="" pr="" repo="" files="" f
  while [ $# -gt 0 ]; do
    case "$1" in
      --role) need_val "$@"; role="$2"; shift 2 ;;
      --file) need_val "$@"; files="$files$2
"; shift 2 ;;
      --pr) need_val "$@"; pr="$2"; shift 2 ;;
      --repo) need_val "$@"; repo="$2"; shift 2 ;;
      *) die "needs-qa: unknown option: $1" ;;
    esac
  done
  case "$role" in
    frontend|designer) echo yes; return 0 ;;
  esac
  if [ -n "$pr" ]; then
    local out
    if [ -n "$repo" ]; then
      out="$(gh pr view "$pr" -R "$repo" --json files --jq '.files[].path' 2>/dev/null)" || { echo "lanes-workers: needs-qa: gh could not list the PR's files" >&2; exit 2; }
    else
      out="$(gh pr view "$pr" --json files --jq '.files[].path' 2>/dev/null)" || { echo "lanes-workers: needs-qa: gh could not list the PR's files" >&2; exit 2; }
    fi
    files="$files$out
"
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_ui_file "$f"; then echo yes; return 0; fi
  done <<EOF
$files
EOF
  echo no
  return 1
}

cmd_ci() {
  local pr="" repo="" timeout=1200 interval=30 settle=120
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr) need_val "$@"; pr="$2"; shift 2 ;;
      --repo) need_val "$@"; repo="$2"; shift 2 ;;
      --timeout) need_val "$@"; timeout="$2"; shift 2 ;;
      --interval) need_val "$@"; interval="$2"; shift 2 ;;
      --settle) need_val "$@"; settle="$2"; shift 2 ;;
      *) die "ci: unknown option: $1" ;;
    esac
  done
  [ -n "$pr" ] || die "ci: --pr is required"
  case "$timeout" in *[!0-9]*) die "ci: --timeout must be an integer" ;; esac
  case "$settle" in *[!0-9]*) die "ci: --settle must be an integer" ;; esac
  case "$interval" in ''|*[!0-9]*|0) die "ci: --interval must be a positive integer" ;; esac
  local started end out summary state names prev_names="__none__" final
  started=$(date +%s)
  end=$(( started + timeout ))
  while :; do
    out=""
    if [ -n "$repo" ]; then
      out="$(gh pr checks "$pr" -R "$repo" --json name,bucket,link 2>/dev/null)" || true
    else
      out="$(gh pr checks "$pr" --json name,bucket,link 2>/dev/null)" || true
    fi
    # gh exits non-zero while checks are pending, so judge the output, not the
    # exit code — and treat anything that is not a JSON array as an error.
    if ! summary="$(printf '%s' "$out" | jq -c '
        if type != "array" then error("not an array") else . end
        | {failing:[.[]|select(.bucket=="fail" or .bucket=="cancel")|.name],
           pending:[.[]|select(.bucket=="pending")|.name],
           passed:[.[]|select(.bucket=="pass")|.name],
           skipped:[.[]|select(.bucket=="skipping")|.name]}
        | .state = (if (.failing|length) > 0 then "fail"
                    elif (.pending|length) > 0 then "pending"
                    elif (.passed|length) > 0 then "pass"
                    else "none" end)' 2>/dev/null)" || [ -z "$summary" ]; then
      jq -cn --arg pr "$pr" '{pr:$pr, state:"error", failing:[], pending:[], passed:[], skipped:[]}'
      return 3
    fi
    state="$(printf '%s' "$summary" | jq -r .state)"
    names="$(printf '%s' "$summary" | jq -r '[.passed[],.pending[],.failing[],.skipped[]]|sort|join(",")')"
    # A fresh push registers its check suites over a minute or two, so an early
    # "pass" may cover only the first few. Pass and none are final only after
    # the settle window, and only when the set of checks did not change since
    # the previous poll. A failure is final at once.
    final=no
    case "$state" in
      fail) final=yes ;;
      pass|none)
        if [ $(( $(date +%s) - started )) -ge "$settle" ] && [ "$names" = "$prev_names" ]; then
          final=yes
        fi ;;
    esac
    prev_names="$names"
    if [ "$final" = yes ] || [ "$(date +%s)" -ge "$end" ]; then
      [ "$final" = yes ] || [ "$state" = fail ] || state=pending
      summary="$(printf '%s' "$summary" | jq -c --arg s "$state" '.state = $s')"
      printf '%s' "$summary" | jq -c --arg pr "$pr" '. + {pr:$pr}'
      case "$state" in
        pass) return 0 ;;
        fail) return 1 ;;
        pending) return 2 ;;
        *) return 4 ;;
      esac
    fi
    sleep "$interval"
  done
}

cmd_ci_round() {
  local pr="" max=3
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr) need_val "$@"; pr="$2"; shift 2 ;;
      --max) need_val "$@"; max="$2"; shift 2 ;;
      --session-id) need_val "$@"; SID="$2"; shift 2 ;;
      *) die "ci-round: unknown option: $1" ;;
    esac
  done
  [ -n "$pr" ] || die "ci-round: --pr is required"
  case "$pr" in *[[:space:]]*) die "ci-round: invalid --pr" ;; esac
  case "$max" in ''|*[!0-9]*) die "ci-round: --max must be an integer" ;; esac
  resolve_sid
  local dir="$ROOT/workspace/sessions/$SID" file n
  mkdir -p "$dir"
  file="$dir/conduct-ci-rounds.tsv"
  touch "$file"
  n="$(awk -F '\t' -v pr="$pr" '$1==pr {c=$2} END {print c+0}' "$file")"
  n=$((n + 1))
  awk -F '\t' -v pr="$pr" '$1!=pr' "$file" > "$file.tmp"
  printf '%s\t%s\n' "$pr" "$n" >> "$file.tmp"
  mv "$file.tmp" "$file"
  echo "$n"
  if [ "$n" -gt "$max" ]; then
    echo "lanes-workers: $pr has used $max CI fix rounds; take it to the owner" >&2
    return 4
  fi
}

sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  setup) cmd_setup "$@" ;;
  roles) cmd_roles "$@" ;;
  template) cmd_template "$@" ;;
  needs-qa) cmd_needs_qa "$@" ;;
  ci) cmd_ci "$@" ;;
  ci-round) cmd_ci_round "$@" ;;
  ""|-h|--help|help) usage ;;
  *) echo "lanes-workers: unknown subcommand: $sub" >&2; usage >&2; exit 1 ;;
esac
