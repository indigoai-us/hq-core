#!/usr/bin/env bash
# hq-core: public
# lanes-workers.sh — the mechanical parts of `/conduct --workers`: role lanes
# pinned to one engine, model and effort for the session, per-role brief
# templates, the CI check after a lane opens a PR, and the QA trigger.
#
# Usage:
#   bash core/scripts/lanes-workers.sh setup --workers <r1,r2,...> \
#        [--engine claude|codex|grok] [--model <m>] [--effort <f>] [--session-id <id>]
#     Validates the role list and persists conduct_lane_roles, conduct_engine,
#     conduct_child_model and conduct_child_effort in session meta. Omitted
#     engine/model/effort keep their current session value. Prints the result
#     as JSON; "engine": null means the conductor still has to resolve one.
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

usage() { sed -n '3,46p' "$0" | sed 's/^# \{0,1\}//'; }
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

cmd_setup() {
  local workers="" engine="" model="" effort="" role seen="," clean=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workers) need_val "$@"; workers="$2"; shift 2 ;;
      --engine) need_val "$@"; engine="$2"; shift 2 ;;
      --model) need_val "$@"; model="$2"; shift 2 ;;
      --effort) need_val "$@"; effort="$2"; shift 2 ;;
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
  print_roles
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
