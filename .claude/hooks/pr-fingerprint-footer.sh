#!/usr/bin/env bash
# hq-core: public
# PostToolUse(Bash): after a raw `gh pr create`, add the HQ-Fingerprint footer
# to the new PR body with `gh pr edit`. PRs opened through
# core/scripts/hq-pr-create.sh already carry it and are skipped. Silent; always
# exits 0; the whole hook is capped at 10 s.
#
# The trigger comes from the executed command only (tool_input.command, split
# into simple commands with heredoc bodies removed), so `gh pr create` inside
# quoted text, a heredoc, or another command's output never fires. The PR URL
# comes only from tool_response.stdout: its last line that is exactly a
# github.com pull URL, which is where `gh pr create` prints the new PR.

INPUT="$(cat 2>/dev/null || true)"

# Cheap prefilter on the whole payload; the field checks below decide.
case "$INPUT" in
  *gh*pr*create*) ;;
  *) exit 0 ;;
esac

HOOK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)"
[ -f "$HOOK_ROOT/core/scripts/hook-lib.sh" ] || exit 0
. "$HOOK_ROOT/core/scripts/hook-lib.sh"

if [ -z "${HQ_LIB_JQ:-}" ] && [ -z "${HQ_LIB_NODE:-}" ]; then
  # No JSON reader: skip, but leave one line so the skip is visible.
  if [ -n "${HOME:-}" ] && mkdir -p "$HOME/.hq" 2>/dev/null; then
    printf '%s pr-fingerprint-footer: skipped, neither jq nor node is available to read the hook payload\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" >>"$HOME/.hq/fingerprint-hook.log" 2>/dev/null
  fi
  exit 0
fi

CMD="$(printf '%s' "$INPUT" | hq_json_get tool_input.command)"
OUT="$(printf '%s' "$INPUT" | hq_json_get tool_response.stdout)"
[ -n "$CMD" ] && [ -n "$OUT" ] || exit 0

# Remove heredoc bodies (<<WORD, <<-WORD, <<'WORD', <<"WORD") so text fed to a
# command on stdin is not split into command records. Here-strings (<<<) stay.
pr_fp_strip_heredocs() {
  printf '%s\n' "$1" | awk '
    function scan(s,    p, rest, c, dash, w, q) {
      while ((p = index(s, "<<")) > 0) {
        rest = substr(s, p + 2)
        if (substr(rest, 1, 1) == "<") { s = substr(rest, 2); continue }
        dash = 0
        if (substr(rest, 1, 1) == "-") { dash = 1; rest = substr(rest, 2) }
        while (substr(rest, 1, 1) == " " || substr(rest, 1, 1) == "\t") rest = substr(rest, 2)
        c = substr(rest, 1, 1); w = ""
        if (c == "\047" || c == "\"") {
          rest = substr(rest, 2); q = index(rest, c)
          if (q == 0) return
          w = substr(rest, 1, q - 1); rest = substr(rest, q + 1)
        } else {
          if (c == "\\") rest = substr(rest, 2)
          while (length(rest) > 0 && substr(rest, 1, 1) ~ /[A-Za-z0-9_.-]/) {
            w = w substr(rest, 1, 1); rest = substr(rest, 2)
          }
        }
        if (w != "") { n++; term[n] = w; tabs[n] = dash }
        s = rest
      }
    }
    BEGIN { head = 1; n = 0 }
    {
      if (head <= n) {
        t = $0
        if (tabs[head]) sub(/^\t+/, "", t)
        if (t == term[head]) head++
        next
      }
      print
      scan($0)
    }
  '
}

RECORDS="$(hq_shell_simple_commands "$(pr_fp_strip_heredocs "$CMD")")"
fire=0
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  exe="$(hq_shell_command_executable "$rec")" || continue
  words=()
  IFS=$'\037' read -r -a words <<<"$rec"
  i=0
  while [ "$i" -lt "${#words[@]}" ] && [ "${words[$i]}" != "$exe" ]; do i=$((i + 1)); done
  case "${exe##*/}" in
    gh|gh.exe)
      if [ "${words[$((i + 1))]:-}" = pr ] && [ "${words[$((i + 2))]:-}" = create ]; then
        fire=1
        # --dry-run opens no PR and --web prints no URL: skip both. Values of
        # flags that take one are not read as flags.
        j=$((i + 3))
        while [ "$j" -lt "${#words[@]}" ]; do
          case "${words[$j]}" in
            --) break ;;
            --dry-run|--web|-w) exit 0 ;;
            -b|--body|-t|--title|-F|--body-file|-B|--base|-H|--head|-a|--assignee|-l|--label|-m|--milestone|-p|--project|-r|--reviewer|-R|--repo|-T|--template)
              j=$((j + 1)) ;;
          esac
          j=$((j + 1))
        done
      fi
      ;;
    bash|bash.exe|sh|sh.exe|zsh|zsh.exe)
      case "${words[$((i + 1))]:-}" in
        */hq-pr-create.sh|hq-pr-create.sh) exit 0 ;;
      esac
      ;;
    hq-pr-create.sh) exit 0 ;;
  esac
done <<<"$RECORDS"
[ "$fire" -eq 1 ] || exit 0

URL="$(printf '%s\n' "$OUT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | grep -E '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$' | tail -n 1)"
[ -n "$URL" ] || exit 0
command -v gh >/dev/null 2>&1 || exit 0

ROOT="${CLAUDE_PROJECT_DIR:-$HOOK_ROOT}"
WRAP="$ROOT/core/scripts/hq-pr-create.sh"
[ -f "$WRAP" ] || exit 0

# Fingerprint first: the wrapper reads the setting and its per-session cache,
# so the kill switch, or a cached empty result, means no network call at all.
# The payload session id wins; then the same ordered list the wrapper reads.
SID="$(printf '%s' "$INPUT" | hq_json_get session_id)"
for var in "" HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
           CODEX_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID; do
  [ -z "$var" ] || SID="${!var:-}"
  SID="${SID//[[:space:]]/}"
  case "$SID" in
    ''|.|..|*[!A-Za-z0-9._-]*) SID="" ;;
    *) break ;;
  esac
done
FP="$(HQ_ROOT="$ROOT" HQ_SESSION_ID="$SID" HQ_PR_CREATE_FINGERPRINT_ONLY=1 \
  bash "$WRAP" </dev/null 2>/dev/null)"
[ -n "$FP" ] || exit 0

# The worker runs in its own process group (set -m) so the 10 s cut can kill
# gh along with it. TERM first lets the worker's trap remove its temp file.
set -m
(
  tmp=""
  trap 'rm -f "$tmp"' EXIT
  trap 'exit 143' TERM
  body="$(gh pr view "$URL" --json body -q .body 2>/dev/null)" || exit 0
  if printf '%s\n' "$body" | grep -q '^HQ-Fingerprint:'; then
    exit 0
  fi
  fp="$FP"
  while [ "${body%$'\n'}" != "$body" ]; do body="${body%$'\n'}"; done
  tmp="$(mktemp "${TMPDIR:-/tmp}/hq-pr-fp-edit.XXXXXX")" || exit 0
  if [ -n "$body" ]; then
    printf '%s\n\n---\nHQ-Fingerprint: %s\n' "$body" "$fp" >"$tmp"
  else
    printf '\n---\nHQ-Fingerprint: %s\n' "$fp" >"$tmp"
  fi
  gh pr edit "$URL" --body-file "$tmp" >/dev/null 2>&1
) </dev/null >/dev/null 2>&1 &
pid=$!
set +m
waited=0
while kill -0 "$pid" 2>/dev/null; do
  if [ "$waited" -ge 100 ]; then
    if kill -TERM -- -"$pid" 2>/dev/null; then
      sleep 0.3
      kill -KILL -- -"$pid" 2>/dev/null
    else
      pkill -KILL -P "$pid" 2>/dev/null
      kill -KILL "$pid" 2>/dev/null
    fi
    break
  fi
  sleep 0.1
  waited=$((waited + 1))
done
wait "$pid" 2>/dev/null
exit 0
