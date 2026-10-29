#!/usr/bin/env bash
# hq-core: public
# Regression: a session rooted in a repo below HQ (repos/private/<repo> or
# workspace/worktrees/<name>) does not load HQ's .claude/skills, because
# Claude Code and Codex stop the skill walk at the repository root. The
# SessionStart hook 55-repo-rooted-hq-skills.sh must name the HQ skills
# (/review, /handoff, personal skills) and the /add-dir command for those
# sessions, and stay silent for an HQ-root session.
# Feedback: feedback_0e17ba66-170c-4bd2-867d-4f9cf6fe0631.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SRC="$ROOT/core/hooks/SessionStart/55-repo-rooted-hq-skills.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
HQ="$TMP/hq"
HOME_DIR="$TMP/home"

mkskill() { mkdir -p "$1" && printf -- '---\nname: %s\n---\nbody\n' "${1##*/}" > "$1/SKILL.md"; }

mkdir -p "$HQ/core/hooks/SessionStart" "$HQ/core/packages/hq-pack-eng" \
  "$HQ/companies/otherco" "$HQ/workspace/sessions" "$HOME_DIR"
git -C "$HQ" init -q
cp "$HOOK_SRC" "$HQ/core/hooks/SessionStart/"
mkskill "$HQ/.claude/skills/review"
mkskill "$HQ/.claude/skills/handoff"
mkskill "$HQ/.claude/skills/startwork"
mkdir -p "$HQ/.claude/skills/_shared"
mkdir -p "$HQ/.claude/skills/no-skill-file"
mkskill "$HQ/.claude/skills/hq-pack-eng:ship"
mkskill "$HQ/.claude/skills/otherco:secret-flow"
mkskill "$HQ/.claude/skills/personal:mirrored"
mkskill "$HQ/personal/skills/mirrored"
mkskill "$HQ/personal/skills/deep-review"

REPO="$HQ/repos/private/client-app"
mkdir -p "$REPO/src/lib"
git -C "$REPO" init -q
WT="$HQ/workspace/worktrees/client-app-fix"
mkdir -p "$WT"
printf 'gitdir: %s/.git/worktrees/x\n' "$REPO" > "$WT/.git"
OWN="$HQ/repos/public/own-skills"
mkdir -p "$OWN"
git -C "$OWN" init -q
mkskill "$OWN/.claude/skills/review"
OUTSIDE="$TMP/outside-repo"
mkdir -p "$OUTSIDE"
git -C "$OUTSIDE" init -q

run_hook() { # <cwd> [env...] -> stdout
  local cwd="$1"; shift
  jq -cn --arg cwd "$cwd" '{session_id:"s1",cwd:$cwd,hook_event_name:"SessionStart",source:"startup"}' \
    | (cd "$cwd" && env -u HQ_ROOT -u HQ_HOOK_CWD -u HQ_NO_REPO_SKILLS_NOTE -u HQ_DISABLED_HOOKS \
        HOME="$HOME_DIR" "$@" bash "$HQ/core/hooks/SessionStart/55-repo-rooted-hq-skills.sh")
}
ctx() { jq -r '.hookSpecificOutput.additionalContext // ""'; }

# 1. Repo-rooted session (repos/private/<repo>, started in a subfolder).
out="$(run_hook "$REPO/src/lib")"
[ -n "$out" ] || fail "repo-rooted session got no note"
[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" = "SessionStart" ] || fail "wrong event name: $out"
note="$(printf '%s' "$out" | ctx)"
printf '%s' "$note" | grep >/dev/null "repository root is $REPO," || fail "note does not name the repo root: $note"
printf '%s' "$note" | grep >/dev/null -F "/add-dir $HQ\`" || fail "note lacks /add-dir <HQ_ROOT>: $note"
printf '%s' "$note" | grep >/dev/null -F "$HQ/.claude/skills/<name>/SKILL.md" || fail "note lacks skill path pattern: $note"
for want in review handoff startwork hq-pack-eng:ship personal:mirrored; do
  printf '%s' "$note" | grep >/dev/null -E "(: |, )$want(,|$| )" || fail "note does not list $want: $note"
done
printf '%s' "$note" | grep >/dev/null -F "$HQ/personal/skills/<name>/SKILL.md): deep-review" \
  || fail "unmirrored personal skill not listed with its path: $note"
for reject in _shared no-skill-file otherco:secret-flow otherco; do
  if printf '%s' "$note" | grep >/dev/null "$reject"; then fail "note leaks or lists $reject: $note"; fi
done
if printf '%s' "$note" | grep >/dev/null -E '(: |, )mirrored(,|$)'; then fail "mirrored personal skill listed twice: $note"; fi
pass "repo-rooted session lists HQ, pack and personal skills with /add-dir"

# 2. HQ-root session: no note (HQ skills already load natively).
out="$(run_hook "$HQ")"
[ -z "$out" ] || fail "HQ-root session got a note: $out"
mkdir -p "$HQ/companies/otherco/knowledge"
out="$(run_hook "$HQ/companies/otherco/knowledge")"
[ -z "$out" ] || fail "HQ subfolder without its own .git got a note: $out"
pass "HQ-root session and HQ subfolders get no note"

# 3. Worktree under workspace/worktrees (.git file) is repo-rooted too.
note="$(run_hook "$WT" | ctx)"
printf '%s' "$note" | grep >/dev/null "repository root is $WT," || fail "worktree session got no note: $note"
pass "worktree session gets the note"

# 4. Skills the session already loads are not repeated.
note="$(run_hook "$OWN" | ctx)"
if printf '%s' "$note" | grep >/dev/null -E '(: |, )review(,|$)'; then fail "repo's own review skill repeated: $note"; fi
printf '%s' "$note" | grep >/dev/null -E '(: |, )handoff(,|$)' || fail "handoff missing from own-skills repo note: $note"
mkskill "$HOME_DIR/.claude/skills/handoff"
note="$(run_hook "$REPO" | ctx)"
if printf '%s' "$note" | grep >/dev/null -E '(: |, )handoff(,|$)'; then fail "user-level handoff skill repeated: $note"; fi
rm -rf "$HOME_DIR/.claude"
pass "repo and user-level skills are not repeated"

# 5. Outside HQ: no note (HQ Anywhere plugin path owns that case).
out="$(cd "$OUTSIDE" && jq -cn --arg cwd "$OUTSIDE" '{cwd:$cwd}' \
  | env HOME="$HOME_DIR" HQ_ROOT="$HQ" bash "$HQ/core/hooks/SessionStart/55-repo-rooted-hq-skills.sh")"
[ -z "$out" ] || fail "foreign cwd got a note: $out"
pass "cwd outside HQ gets no note"

# 6. Opt-outs.
[ -z "$(run_hook "$REPO" HQ_NO_REPO_SKILLS_NOTE=1)" ] || fail "HQ_NO_REPO_SKILLS_NOTE=1 not honored"
[ -z "$(run_hook "$REPO" HQ_DISABLED_HOOKS=repo-skills-note)" ] || fail "HQ_DISABLED_HOOKS not honored"
pass "opt-outs silence the note"

# 7. Output stays bounded with a large skill set; core skills come first.
for i in $(seq 1 400); do mkskill "$HQ/.claude/skills/hq-pack-eng:generated-skill-$i"; done
out="$(run_hook "$REPO")"
note="$(printf '%s' "$out" | ctx)"
[ "${#note}" -le 4500 ] || fail "note is ${#note} chars, over the bound"
printf '%s' "$note" | grep >/dev/null -E '\(\+[0-9]+ more; list them with ls\)' || fail "truncated note lacks the +N more marker"
printf '%s' "$note" | grep >/dev/null -E '(: |, )review(,|$)' || fail "budget cut dropped review"
printf '%s' "$note" | grep >/dev/null -E '(: |, )handoff(,|$)' || fail "budget cut dropped handoff"
printf '%s' "$note" | grep >/dev/null -F "personal/skills/<name>/SKILL.md): deep-review" || fail "budget cut dropped personal skills"
pass "note is bounded (${#note} chars) and keeps core and personal skills"

# 7b. Output is valid JSON when a skill folder name needs escaping.
rm -rf "$HQ/.claude/skills/hq-pack-eng:generated-skill-"*
mkskill "$HQ/.claude/skills/quote\"back\\slash"
out="$(run_hook "$REPO")"
printf '%s' "$out" | jq -e . >/dev/null 2>&1 || fail "output is not valid JSON: $out"
printf '%s' "$out" | ctx | grep -qF 'quote"back\slash' || fail "escaped name did not round-trip: $out"
rm -rf "$HQ/.claude/skills/quote\"back\\slash"
pass "output is valid JSON with quote and backslash in a name"

# 7c. CPU cost: the HQ-root early exit spawns nothing beyond bash itself.
# Compare against a bare bash that only drains stdin (same harness overhead).
cpu_ms() { # <cwd> <script>; prints median user+sys ms over 15 runs
  local i t samples=()
  for i in $(seq 1 15); do
    t="$( { TIMEFORMAT='%3U %3S'; time (printf '{"cwd":"%s"}' "$1" | HOME="$HOME_DIR" bash "$2" >/dev/null); } 2>&1 )"
    samples+=("$(awk '{printf "%d", ($1 + $2) * 1000}' <<<"$t")")
  done
  printf '%s\n' "${samples[@]}" | sort -n | sed -n 8p
}
printf 'cat >/dev/null\n' > "$TMP/baseline.sh"
base_ms="$(cpu_ms "$HQ" "$TMP/baseline.sh")"
root_ms="$(cpu_ms "$HQ" "$HQ/core/hooks/SessionStart/55-repo-rooted-hq-skills.sh")"
echo "  cpu median: baseline=${base_ms}ms hq-root=${root_ms}ms"
[ "$root_ms" -le $((base_ms + 5)) ] || fail "HQ-root early exit costs ${root_ms}ms vs baseline ${base_ms}ms"
pass "HQ-root early exit is within 5ms CPU of a bare bash"

# 8. Through master-hook dispatch: one note for a repo-rooted session, none
# for an HQ-root session.
rm -rf "$HQ/.claude/skills/hq-pack-eng:generated-skill-"*
mkdir -p "$HQ/.claude/hooks" "$HQ/core/scripts/lib" "$HQ/personal"
cp "$ROOT/.claude/hooks/master-hook.sh" "$ROOT/.claude/hooks/hook-timeout-probe.sh" \
  "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$ROOT/.claude/hooks/mandatory-scope-authorizer.sh" "$HQ/.claude/hooks/"
cp "$ROOT/core/scripts/resolve-hq-root.sh" "$ROOT/core/scripts/resolve-company.sh" \
  "$ROOT/core/scripts/hq-anywhere-runtime-flag.cjs" "$ROOT/core/scripts/hq-session.sh" \
  "$ROOT/core/scripts/hook-lib.sh" "$HQ/core/scripts/"
cp -R "$ROOT/core/scripts/lib/." "$HQ/core/scripts/lib/"
printf 'companies:\n  otherco:\n    name: Other\n' > "$HQ/companies/manifest.yaml"
dispatch() { # <cwd> <sid> -> master-hook stdout
  jq -cn --arg cwd "$1" --arg sid "$2" \
    '{session_id:$sid,cwd:$cwd,hook_event_name:"SessionStart",source:"startup"}' \
    | (cd "$1" && env -u HQ_ROOT -u HQ_NO_REPO_SKILLS_NOTE -u HQ_DISABLED_HOOKS \
        HOME="$HOME_DIR" HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HQ_SESSION_NO_CLI=1 \
        HQ_FLAG_HQ_ANYWHERE_RUNTIME=0 \
        bash "$HQ/.claude/hooks/master-hook.sh" SessionStart) 2>"$TMP/dispatch.err" \
    || fail "master-hook SessionStart failed in $1: $(cat "$TMP/dispatch.err")"
}
out="$(dispatch "$REPO" repo-sess-1)"
count="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""' \
  | grep -c "HQ's skills are not in this session's skill list" || true)"
[ "$count" = "1" ] || fail "repo-rooted dispatch emitted $count notes: $out"
pass "master-hook dispatch emits one note for a repo-rooted session"
out="$(dispatch "$HQ" root-sess-1)"
if printf '%s' "$out" | grep >/dev/null "skill list"; then fail "HQ-root dispatch emitted the note: $out"; fi
pass "master-hook dispatch emits no note for an HQ-root session"

echo "PASS sessionstart-repo-rooted-hq-skills"
