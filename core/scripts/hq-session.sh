#!/usr/bin/env bash
# hq-core: public
# hq-session.sh — read/write the current session's metadata.
#
# Usage:
#   core/scripts/hq-session.sh current               # print current session_id (or empty)
#   core/scripts/hq-session.sh path                  # print path to current meta.yaml
#   core/scripts/hq-session.sh get <key>             # read a key from meta.yaml
#   core/scripts/hq-session.sh set <key> <value>     # set/replace a top-level key
#
# Reserved value:
#   set company_slug personal   # bind the session to no-company (personal) work
#
# Global option (before the subcommand):
#   --session-id <id>   operate on this session instead of the resolved one
#
# Session bootstrapping is owned by .claude/hooks/master-hook.sh, which
# writes workspace/sessions/.current and ensures
# workspace/sessions/<session_id>/meta.yaml exists on every hook event.
#
# "Current session" is resolved by core/scripts/lib/session-id.sh: the session id
# exported into this process wins, and workspace/sessions/.current is only a
# fallback. .current is a single global pointer rewritten by every hook event, so
# with concurrent sessions it can name someone else's session — trusting it made
# `set company_slug` write to the wrong session's meta.yaml while the calling
# session stayed unbound and blocked by the scope guard.

set -euo pipefail

# Prefer the CLI-hosted implementation. The canonical script ships in the CLI
# (`hq core hq-session`); when the installed CLI provides it, delegate with
# arguments passed through untouched. Otherwise fall through to the in-tree copy
# below, which stays behavior-identical as a transitional fallback for a CLI
# that predates the command. HQ_HQ_SESSION_NO_CLI=1 forces the in-tree path.
if [ "${HQ_HQ_SESSION_NO_CLI:-}" != "1" ]; then
  __hs_hq="$(command -v hq 2>/dev/null || true)"
  if [ -n "$__hs_hq" ]; then
    # `hq core --help` costs seconds of node startup, so probe it at most once
    # per CLI build and cache the answer. Key by resolved path + mtime + size so
    # a PATH switch or same-second rebuild cannot reuse a stale result; keep the
    # cache in a private 0700 dir and trust it only when we own it; never persist
    # a failed probe. HQ_CLI_CAPS_CACHE overrides the path (tests isolate it).
    __hs_mt="$(stat -c %Y "$__hs_hq" 2>/dev/null || stat -f %m "$__hs_hq" 2>/dev/null || echo 0)"
    __hs_sz="$(stat -c %s "$__hs_hq" 2>/dev/null || stat -f %z "$__hs_hq" 2>/dev/null || echo 0)"
    __hs_key="$(printf '%s' "$__hs_hq:$__hs_mt:$__hs_sz" | cksum 2>/dev/null | cut -d' ' -f1)"
    if [ -n "${HQ_CLI_CAPS_CACHE:-}" ]; then
      __hs_cache="$HQ_CLI_CAPS_CACHE"
    else
      __hs_dir="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/hq-cli"
      mkdir -p "$__hs_dir" 2>/dev/null && chmod 700 "$__hs_dir" 2>/dev/null || true
      __hs_cache="$__hs_dir/core-caps.${__hs_key:-0}"
    fi
    __hs_caps=""
    if [ -r "$__hs_cache" ] && [ -O "$__hs_cache" ]; then
      __hs_caps="$(cat "$__hs_cache" 2>/dev/null || true)"
    elif __hs_caps="$(hq core --help 2>/dev/null)"; then
      [ -n "$__hs_caps" ] && (umask 077; printf '%s' "$__hs_caps" >"$__hs_cache" 2>/dev/null) || true
    else
      __hs_caps=""
    fi
    case "$__hs_caps" in
      *hq-session*) exec hq core hq-session "$@" ;;
    esac
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The DATA tree (sessions, companies, hooks) is the live HQ root. When this
# script is dispatched as `hq core hq-session` from inside the hq-cli package,
# its own location is NOT that tree — the CLI injects the live root via
# HQ_ROOT / CLAUDE_PROJECT_DIR. Prefer those; fall back to the self-relative
# root so a loose-file (in-tree) invocation keeps resolving exactly as before.
REPO_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
SESSIONS_DIR="$REPO_ROOT/workspace/sessions"
# Libs are sourced from THIS script's own directory, so a bundled dispatch loads
# the bundled copies and a loose-file invocation loads the tree's copies.
LIB_DIR="$SCRIPT_DIR/lib"
# shellcheck source=lib/session-scope-capability.sh
. "$LIB_DIR/session-scope-capability.sh"
# shellcheck source=lib/session-id.sh
. "$LIB_DIR/session-id.sh"

# Set by the --session-id global option; empty means "resolve it".
SESSION_ID_OVERRIDE=""

usage() {
  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

current_id() {
  if [ -n "$SESSION_ID_OVERRIDE" ]; then
    printf '%s' "$SESSION_ID_OVERRIDE"
    return 0
  fi
  session_id_resolve "$REPO_ROOT"
}

current_meta() {
  local id
  id="$(current_id)"
  [ -n "$id" ] || return 0
  printf '%s/%s/meta.yaml' "$SESSIONS_DIR" "$id"
}

cmd_current() {
  current_id
}

cmd_path() {
  current_meta
}

cmd_get() {
  local key="${1:-}"
  [ -n "$key" ] || { echo "usage: hq-session.sh get <key>" >&2; exit 1; }
  local meta
  meta="$(current_meta)"
  [ -n "$meta" ] && [ -f "$meta" ] || return 0
  awk -v k="$key" '
    $1 == k":" {
      sub(/^[^:]+:[[:space:]]*/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$meta"
}

cmd_set() {
  local key="${1:-}" value="${2:-}"
  [ -n "$key" ] && [ $# -ge 2 ] || { echo "usage: hq-session.sh set <key> <value>" >&2; exit 1; }

  # Reject an invalid company_slug BEFORE writing anything. Otherwise a bad value
  # lands in meta.yaml and only fails later at session_scope_mint, leaving
  # corrupt state that the scope gate would read as a (bogus) binding. Mirrors
  # session_scope_mint's own character-set rule; `personal` is a valid slug.
  if [ "$key" = "company_slug" ] && [ -n "$value" ]; then
    case "$value" in
      *[!a-z0-9_-]*)
        echo "hq-session: invalid company_slug: '$value' (allowed characters: a-z 0-9 - _)" >&2
        exit 1
        ;;
    esac
  fi

  local id meta
  id="$(current_id)"
  if [ -z "$id" ]; then
    echo "hq-session: no current session — no session id in the environment (HQ_SESSION_ID, CLAUDE_CODE_SESSION_ID, CLAUDE_SESSION_ID, CODEX_SESSION_ID, CODEX_THREAD_ID) and workspace/sessions/.current is missing or invalid. Is master-hook installed? Pass --session-id <id> to target a session explicitly." >&2
    exit 1
  fi
  meta="$SESSIONS_DIR/$id/meta.yaml"
  mkdir -p "$(dirname "$meta")"
  # Seed the same header master-hook.sh writes, so binding a session the hook
  # has not bootstrapped yet still produces a well-formed record.
  if [ ! -f "$meta" ]; then
    printf 'session_id: %s\nstarted_at: "%s"\n' \
      "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$meta"
  fi

  # Capture the prior value so we only surface policies when it actually changes.
  local prev=""
  prev="$(cmd_get "$key" 2>/dev/null || true)"

  local tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { found = 0 }
    $1 == k":" { print k": " v; found = 1; next }
    { print }
    END { if (!found) print k": " v }
  ' "$meta" > "$tmp"
  mv "$tmp" "$meta"

  # When a company is bound (or rebound) mid-session, surface that company's
  # hard-enforcement policies into this Bash tool result. SessionStart only
  # injects company policies for the company known *at start*; binding a
  # company afterward (this path) otherwise surfaces nothing, so an agent can
  # do company infra/deploy/credential work blind to hard rules. This closes
  # that gap. Emits policy text only — never secrets.
  if [ "$key" = "company_slug" ] && [ -n "$value" ] && [ "$value" != "$prev" ]; then
    session_scope_mint "$REPO_ROOT" "$id" "$value" || {
      echo "hq-session: failed to mint scope-capability for session $id" >&2
      exit 1
    }
    # `personal` is the reserved scope for work that belongs to no company. It
    # binds the session — satisfying the checkpoint company gate and scoping the
    # authorizer to personal/ — but it has no tenant directory, so there are no
    # company hard-policies to surface and nothing to register with the
    # company-scoped Work Mesh. Everything else is a real company bind.
    if [ "$value" != "personal" ]; then
      emit_company_hard_policies "$value"
      # Fire-and-forget: register this company bind with the Work Mesh (US-003).
      # Fully silent (all output → the hook's own bounded log) and guarded so it
      # can neither fail cmd_set under `set -euo pipefail` nor delay its return.
      spawn_work_mesh_register "$id" || true
    fi
  fi
}

# Spawn the client-side Work Mesh registration hook, detached, for a mid-session
# company bind. No-ops silently when the hook or jq is absent (e.g. sandboxed
# tests copy only hq-session.sh). Never blocks: the hook itself is fire-and-forget
# and this backgrounds even its fast foreground path off cmd_set's return path.
spawn_work_mesh_register() {
  local sid="$1"
  local hook="$REPO_ROOT/core/hooks/work-mesh-register.sh"
  local logf="$REPO_ROOT/workspace/logs/work-mesh-hook.log"
  [ -x "$hook" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local ev
  ev="$(jq -nc --arg sid "$sid" --arg cwd "${PWD:-}" '{session_id:$sid,cwd:$cwd}' 2>/dev/null)" || return 0
  [ -n "$ev" ] || return 0
  mkdir -p "$(dirname "$logf")" 2>/dev/null || true
  HQ_ROOT="$REPO_ROOT" nohup bash -c 'printf "%s" "$1" | "$2" company_slug' _ "$ev" "$hook" \
    >>"$logf" 2>&1 </dev/null &
  disown 2>/dev/null || true
  return 0
}

# Print a company's hard-enforcement policies, read directly from the policy
# files (the pre-built digest was retired — the when/on trigger hook is now the
# sole policy-surfacing path). Emits one `- [hard] **id**: rule` line per policy,
# including its exact source path so IDs do not have to match filenames. Lines
# are deduped (digest/README/example/sync-conflict copies are skipped) and
# budgeted (HQ_COMPANY_BIND_POLICY_CAP lines / HQ_COMPANY_BIND_POLICY_BYTES
# bytes, with a non-silent pointer for the overflow). An unbounded dump —
# observed at ~298 lines for a large tenant — buries the rules it exists to
# surface; the reactive trigger hook re-injects any withheld policy when its
# trigger fires.
emit_company_hard_policies() {
  local co="$1"
  local dir="$REPO_ROOT/companies/$co/policies"
  [ -d "$dir" ] || return 0
  # Collect real policy files only. Skip the generated digest, docs, examples,
  # and sync-conflict duplicates: policy slugs never contain spaces, so a space
  # in the basename ("foo 2.md") marks a stray copy whose lines would duplicate
  # the original's. (Also guards the glob: with no matching files "$dir"/*.md
  # expands literally and awk would exit nonzero under `set -e`.)
  local files=() f b
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    b="${f##*/}"
    case "$b" in
      _digest*.md|README.md|readme.md|example-policy.md|*.conflict-*|*" "*) continue ;;
    esac
    files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  local lines
  lines="$(awk -v co="$co" '
    function bn(p,  n,a,b){ n=split(p,a,"/"); b=a[n]; sub(/\.md$/,"",b); return b }
    function policy_file(p,  n,a){ n=split(p,a,"/"); return a[n] }
    function flush(){ if(enf=="hard" && rule!=""){ if(id=="")id=bn(fn); printf "- [hard] **%s**: %s Full text: `companies/%s/policies/%s`.\n", id, rule, co, policy_file(fn) } }
    FNR==1 { if(seen) flush(); d=0;id="";enf="";rule="";rsec=0;rcap=0;fn=FILENAME;seen=1 }
    /^---[ \t]*$/ { d++; next }
    d==1 && /^id:/          { s=$0; sub(/^id:[ \t]*/,"",s); gsub(/^["'"'"']|["'"'"']$/,"",s); id=s; next }
    d==1 && /^enforcement:/ { s=$0; sub(/^enforcement:[ \t]*/,"",s); gsub(/[ \t]/,"",s); enf=s; next }
    d>=2 && /^## Rule[ \t]*$/ { rsec=1; next }
    d>=2 && rsec && /^## / { rsec=0 }
    d>=2 && rsec && !rcap && NF { line=$0; gsub(/\*\*/,"",line); if(length(line)>160)line=substr(line,1,157)"..."; rule=line; rcap=1 }
    END { if(seen) flush() }
  ' "${files[@]}" 2>/dev/null)"
  [ -z "$lines" ] && return 0
  # Budget the emission: count cap and cumulative byte cap, prefix-stable
  # (glob order), never silent — overflow is summarized with a pointer so the
  # withheld policies stay one command away.
  local cap="${HQ_COMPANY_BIND_POLICY_CAP:-32}"
  local max_bytes="${HQ_COMPANY_BIND_POLICY_BYTES:-40960}"
  printf '\n<company-policy-digest co="%s">\n' "$co"
  printf '# %s hard-enforcement policies (auto-surfaced on company bind)\n' "$co"
  printf '> Company context just bound mid-session. These HARD rules now apply.\n'
  printf '> Full text: open the file path shown on each policy line. Browse `companies/%s/policies/` for the full set.\n\n' "$co"
  printf '%s\n' "$lines" | awk -v cap="$cap" -v maxb="$max_bytes" -v co="$co" '
    NF {
      n++
      if (!stop) {
        bytes += length($0) + 1
        if (n <= cap && bytes <= maxb) { print; kept = n } else stop = 1
      }
    }
    END {
      dropped = n - kept
      if (dropped > 0)
        printf "\n> %d more hard %s not shown (bind budget: %d policies / %d bytes). Browse `companies/%s/policies/` for the full set; matching rules re-surface via the policy trigger hook when they apply.\n", \
          dropped, (dropped == 1 ? "policy" : "policies"), cap, maxb, co
    }'
  printf '</company-policy-digest>\n'
}

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --session-id)
      SESSION_ID_OVERRIDE="${2:-}"
      if ! session_id_is_valid "$SESSION_ID_OVERRIDE"; then
        echo "hq-session: invalid --session-id: '${SESSION_ID_OVERRIDE}'" >&2
        exit 1
      fi
      shift 2
      ;;
    --session-id=*)
      SESSION_ID_OVERRIDE="${1#--session-id=}"
      if ! session_id_is_valid "$SESSION_ID_OVERRIDE"; then
        echo "hq-session: invalid --session-id: '${SESSION_ID_OVERRIDE}'" >&2
        exit 1
      fi
      shift
      ;;
    *) break ;;
  esac
done

sub="${1:-}"
shift || true
case "$sub" in
  current) cmd_current "$@" ;;
  path)    cmd_path "$@" ;;
  get)     cmd_get "$@" ;;
  set)     cmd_set "$@" ;;
  ""|-h|--help|help) usage ;;
  *) echo "hq-session: unknown subcommand '$sub'" >&2; usage >&2; exit 1 ;;
esac
