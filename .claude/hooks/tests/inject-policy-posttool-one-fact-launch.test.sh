#!/usr/bin/env bash
# inject-policy-posttool-one-fact-launch.test.sh — regression for
# feedback_45868a9c: a PostToolUse event launched derive-trigger-facts twice,
# once for the output facts and once more (as PreToolUse) for the command
# facts. The injector now asks for both records in one launch with
# `--with-command-facts` and keeps the second launch only for a helper that
# predates the flag. The policies that fire must not change.
#
#   [a] a helper that knows the flag: one launch, both fact sets used
#   [b] a helper that predates the flag: the old two launches, same policies
#   [c] a failed paired call is not followed by a command-facts launch
#   [d] the hq-hook bridge in `on` mode gets the flag in one engine call when
#       the resolved CLI is at or above the release that adds it
#   [e] UserPromptSubmit keeps its one paired --with-assistant-intent launch
#   [f] no pair file is left behind
#   [g] an older CLI's engine never sees the flag, so it answers natively
#       instead of with a shell fallback (#1871 review)
#   [h] bridge on with no resolved CLI version: no flag
set -uo pipefail

TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
HOOK_SOURCE="${HQ_INJECT_POLICY_TEST_HOOK:-$ROOT/.claude/hooks/inject-policy-on-trigger.sh}"
[ -f "$HOOK_SOURCE" ] || { echo "FAIL: hook source is missing: $HOOK_SOURCE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "inject-policy-posttool-one-fact-launch: skipped (jq missing)"; exit 0; }
# The release that adds --with-command-facts, read from the hook so the cases
# follow it. OLD_CLI is the companion floor: resolvable, but older than that.
PAIR_FLOOR="$(sed -n 's/^POLICY_FACT_COMMAND_PAIR_CLI_FLOOR="\([0-9.]*\)"$/\1/p' "$HOOK_SOURCE")"
[ -n "$PAIR_FLOOR" ] || { echo "FAIL: POLICY_FACT_COMMAND_PAIR_CLI_FLOOR not found in the hook" >&2; exit 1; }
OLD_CLI="5.342.5"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/inject-policy-posttool-one-launch.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
FIX="$TMP/hq"
FAKE_HOME="$TMP/home"
ENGINE_DIR="$TMP/engine"
ENGINE="$ENGINE_DIR/hq-hook"
ENGINE_LOG="$ENGINE_DIR/calls.log"
HELPER_LOG="$TMP/helper-calls.log"
mkdir -p "$FIX/.claude/hooks" "$FIX/core/scripts" "$FIX/core/policies" "$FIX/workspace" "$FAKE_HOME" "$ENGINE_DIR"

cp "$HOOK_SOURCE" "$FIX/.claude/hooks/inject-policy-on-trigger.sh"
for entry in "$ROOT"/core/scripts/*; do
  name="${entry##*/}"
  [ "$name" = "derive-trigger-facts.sh" ] && continue
  ln -s "$entry" "$FIX/core/scripts/$name"
done

# Stub helper. The PostToolUse output facts are `outfact`; the command facts
# (PreToolUse on the same payload) are `cmdfact` plus the PreToolUse-only
# run_in_background marker, which the injector must still drop. With
# $TMP/helper-old present it behaves like a helper that predates
# --with-command-facts: the flag is ignored and one record comes back.
cat > "$FIX/core/scripts/derive-trigger-facts.sh" <<HELPER
#!/usr/bin/env bash
payload="\$(cat)"
printf '%s\n' "\$*" >> "$HELPER_LOG"
[ ! -f "$TMP/helper-rc" ] || exit "\$(cat "$TMP/helper-rc")"
case "\$1" in
  PostToolUse)
    if [ "\${2:-}" = "--with-command-facts" ] && [ ! -f "$TMP/helper-old" ]; then
      printf '%s\n%s\n' "always outfact" "always cmdfact run_in_background"
    else
      printf '%s\n' "always outfact"
    fi
    ;;
  PreToolUse) printf '%s\n' "always cmdfact run_in_background" ;;
  *)
    if [ "\${2:-}" = "--with-assistant-intent" ]; then
      printf '%s\n%s\n' "always promptfact" "always"
    else
      printf '%s\n' "always promptfact"
    fi
    ;;
esac
HELPER
chmod +x "$FIX/core/scripts/derive-trigger-facts.sh"

# Stub engine in `on` mode: answers the paired request itself.
cat > "$ENGINE" <<STUB
#!/usr/bin/env bash
payload="\$(cat)"
printf '%s\n' "\$*" >> "$ENGINE_LOG"
args=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    --) shift; args=("\$@"); break ;;
    *) shift ;;
  esac
done
if [ "\${args[0]:-}" = "PostToolUse" ] && [ "\${args[1]:-}" = "--with-command-facts" ]; then
  printf '%s\n%s\n' "always outfact" "always cmdfact"
elif [ "\${args[0]:-}" = "PostToolUse" ]; then
  printf '%s\n' "always outfact"
else
  printf '%s\n' "always cmdfact"
fi
STUB
chmod +x "$ENGINE"

# cmd-probe: omitted on:, so it is evaluated against the command facts.
# output-probe: on PostToolUse only, so it is evaluated against output words.
# background-probe: must never fire after the tool call.
cat > "$FIX/core/policies/cmd-probe.md" <<'POLICY'
---
id: cmd-probe
when: cmdfact
enforcement: soft
version: 1
---

## Rule

Fixture policy that fires on the command fact.
POLICY
cat > "$FIX/core/policies/output-probe.md" <<'POLICY'
---
id: output-probe
when: outfact
on: [PostToolUse]
enforcement: soft
version: 1
---

## Rule

Fixture policy that fires on the output fact.
POLICY
cat > "$FIX/core/policies/background-probe.md" <<'POLICY'
---
id: background-probe
when: run_in_background
enforcement: soft
version: 1
---

## Rule

Fixture policy for the PreToolUse-only background marker.
POLICY
cat > "$FIX/core/policies/prompt-probe.md" <<'POLICY'
---
id: prompt-probe
when: promptfact
on: [UserPromptSubmit]
enforcement: soft
version: 1
---

## Rule

Fixture policy that fires on the prompt fact.
POLICY

TAB="$(printf '\t')"
SESSION=0
reset() {
  rm -f "$ENGINE_LOG" "$HELPER_LOG" "$TMP/helper-rc" "$TMP/helper-old"
}
# run [ENV=VALUE ...] — one event through the injector, fresh session.
# RUN_ROOT picks the fixture root (default $FIX).
run() {
  local payload root="${RUN_ROOT:-$FIX}"
  SESSION=$((SESSION + 1))
  case "${RUN_EVENT:-PostToolUse}" in
    PostToolUse) payload="$(jq -cn --arg cwd "$root" --arg sid "one-launch-$SESSION" \
      '{hook_event_name:"PostToolUse",session_id:$sid,tool_name:"Bash",tool_input:{command:"ls -la",run_in_background:true},tool_response:{stdout:"total 0",stderr:"",interrupted:false},cwd:$cwd}')" ;;
    *) payload="$(jq -cn --arg cwd "$root" --arg sid "one-launch-$SESSION" \
      '{hook_event_name:"UserPromptSubmit",session_id:$sid,prompt:"hello there",cwd:$cwd}')" ;;
  esac
  RC=0
  printf '%s' "$payload" | (cd "$root" && env -u HQ_HOOK_ENGINE -u HQ_HOOK_BRIDGE_PLAN -u HQ_HOOK_BRIDGE_BIN \
    -u BASH_ENV -u ENV -u HQ_POLICY_WORKER_DIR \
    HOME="$FAKE_HOME" XDG_STATE_HOME="$FAKE_HOME/.local/state" HQ_ROOT="$root" CLAUDE_PROJECT_DIR="$root" \
    HQ_HOOK_PROFILE=standard HQ_HOOK_TIMEOUT_SENTRY=0 HQ_POLICY_FACT_HELPER_DISABLE=1 \
    HQ_POLICY_COMPANY= HQ_COMPANY_SLUG= HQ_HARNESS=claude HQ_POLICY_TOOL_EVENTS=off \
    "$@" bash "$root/.claude/hooks/inject-policy-on-trigger.sh") >"$TMP/out" 2>"$TMP/err" || RC=$?
}

# A second root whose tree helper is the release forwarder, so the injector
# resolves the packaged companion of the `hq` on PATH and reads that package's
# version. make_cli <dir> <version> builds a fake @indigoai-us/hq-cli package
# whose companion is the stub helper, and an `hq` link to it in <dir>/bin.
FWD="$TMP/hq-fwd"
mkdir -p "$FWD/.claude/hooks" "$FWD/core/scripts" "$FWD/core/policies" "$FWD/workspace"
cp "$HOOK_SOURCE" "$FWD/.claude/hooks/inject-policy-on-trigger.sh"
for entry in "$ROOT"/core/scripts/*; do
  name="${entry##*/}"
  [ "$name" = "derive-trigger-facts.sh" ] && continue
  ln -s "$entry" "$FWD/core/scripts/$name"
done
printf '%s\n' '#!/usr/bin/env bash' '# FORWARDER — test stand-in; the injector must use the packaged companion.' \
  "printf 'forwarder %s\n' \"\$*\" >> \"$HELPER_LOG\"" 'exit 3' > "$FWD/core/scripts/derive-trigger-facts.sh"
chmod +x "$FWD/core/scripts/derive-trigger-facts.sh"
cp "$FIX"/core/policies/*.md "$FWD/core/policies/"
make_cli() {
  local dir="$1" version="$2" pkg
  pkg="$dir/lib/node_modules/@indigoai-us/hq-cli"
  mkdir -p "$pkg/dist" "$pkg/assets/scaffold/core/scripts/lib" "$dir/bin"
  printf '%s\n' '{' '  "name": "@indigoai-us/hq-cli",' "  \"version\": \"$version\"" '}' > "$pkg/package.json"
  printf '%s\n' '#!/usr/bin/env node' > "$pkg/dist/index.js"
  # `command -v hq` skips a link to a file that is not executable, and would
  # then find the machine's real hq instead of this fixture.
  chmod +x "$pkg/dist/index.js"
  cp "$FIX/core/scripts/derive-trigger-facts.sh" "$pkg/assets/scaffold/core/scripts/derive-trigger-facts.sh"
  cp "$ROOT/core/scripts/lib/trigger-fact-text.awk" "$ROOT/core/scripts/lib/transcript-tail.sh" "$pkg/assets/scaffold/core/scripts/lib/"
  ln -sfn "$pkg/dist/index.js" "$dir/bin/hq"
}
count() { [ -f "$1" ] && grep -c . "$1" || echo 0; }
out_has() { grep -qF "$1" "$TMP/out"; }
# The fired set for a PostToolUse run: command and output policies, never the
# background marker.
post_policies_fired() {
  out_has 'cmd-probe' && out_has 'output-probe' && ! out_has 'background-probe'
}

echo "[a] helper with --with-command-facts: one launch"
reset
run
[ "$RC" = "0" ] && ok "rc 0" || bad "rc=$RC err=$(head -c 300 "$TMP/err")"
if [ "$(count "$HELPER_LOG")" = "1" ] && [ "$(cat "$HELPER_LOG")" = "PostToolUse --with-command-facts" ]; then
  ok "one paired helper launch"
else
  bad "helper calls: $(cat "$HELPER_LOG" 2>/dev/null)"
fi
post_policies_fired && ok "command and output policies fired, background marker dropped" \
  || bad "out=$(head -c 400 "$TMP/out")"

echo "[b] helper that predates the flag: two launches, same policies"
reset
: > "$TMP/helper-old"
run
[ "$RC" = "0" ] && ok "rc 0" || bad "rc=$RC err=$(head -c 300 "$TMP/err")"
if [ "$(count "$HELPER_LOG")" = "2" ] && [ "$(sed -n 1p "$HELPER_LOG")" = "PostToolUse --with-command-facts" ] \
  && [ "$(sed -n 2p "$HELPER_LOG")" = "PreToolUse" ]; then
  ok "fell back to a PreToolUse launch for the command facts"
else
  bad "helper calls: $(cat "$HELPER_LOG" 2>/dev/null)"
fi
post_policies_fired && ok "same policies fired as with the paired helper" \
  || bad "out=$(head -c 400 "$TMP/out")"

echo "[c] a failed paired call gets no command-facts launch"
reset
printf '1\n' > "$TMP/helper-rc"
run
[ "$RC" = "0" ] && ok "rc 0" || bad "rc=$RC err=$(head -c 300 "$TMP/err")"
[ "$(count "$HELPER_LOG")" = "1" ] && ok "helper launched once" || bad "helper calls: $(cat "$HELPER_LOG" 2>/dev/null)"
! out_has 'cmd-probe' && ok "no command facts after the failure" || bad "out=$(head -c 400 "$TMP/out")"

echo "[d] hq-hook bridge on, CLI at the flag's release: one engine call with the flag"
reset
make_cli "$TMP/cli-new" "$PAIR_FLOOR"
NEW_COMPANION="$TMP/cli-new/lib/node_modules/@indigoai-us/hq-cli/assets/scaffold/core/scripts/derive-trigger-facts.sh"
RUN_ROOT="$FWD" run HQ_POLICY_FACT_HELPER_DISABLE= PATH="$TMP/cli-new/bin:$PATH" \
  HQ_HOOK_BRIDGE_BIN="$ENGINE" HQ_HOOK_BRIDGE_PLAN="$(printf 'derive-trigger-facts%son' "$TAB")"
[ "$RC" = "0" ] && ok "rc 0" || bad "rc=$RC err=$(head -c 300 "$TMP/err")"
[ "$(count "$HELPER_LOG")" = "0" ] && ok "shell helper not run" || bad "helper ran: $(cat "$HELPER_LOG")"
if [ "$(count "$ENGINE_LOG")" = "1" ] && grep -qF -- "--event PostToolUse --timeout 20 --script $NEW_COMPANION -- PostToolUse --with-command-facts" "$ENGINE_LOG"; then
  ok "one paired engine call"
else
  bad "engine calls: $(cat "$ENGINE_LOG" 2>/dev/null)"
fi
out_has 'cmd-probe' && out_has 'output-probe' && ok "engine facts drove both policies" \
  || bad "out=$(head -c 400 "$TMP/out")"

echo "[e] UserPromptSubmit keeps one --with-assistant-intent launch"
reset
RUN_EVENT=UserPromptSubmit run
[ "$RC" = "0" ] && ok "rc 0" || bad "rc=$RC err=$(head -c 300 "$TMP/err")"
if [ "$(count "$HELPER_LOG")" = "1" ] && [ "$(cat "$HELPER_LOG")" = "UserPromptSubmit --with-assistant-intent" ]; then
  ok "one paired helper launch"
else
  bad "helper calls: $(cat "$HELPER_LOG" 2>/dev/null)"
fi
out_has 'prompt-probe' && ok "prompt policy fired" || bad "out=$(head -c 400 "$TMP/out")"

echo "[f] no pair file left behind"
leftover="$(find "$FIX/workspace" "$FWD/workspace" -name '.policy-trigger-pair.*' 2>/dev/null | head -n 1)"
[ -z "$leftover" ] && ok "pair files removed" || bad "left behind: $leftover"

# An engine from before --with-command-facts: an unknown second argument makes
# it give up on the native port and run the shell helper (ShellFallbackRequired),
# which is slower on Windows. Logged as `shell-fallback` so the case can see it.
OLD_ENGINE="$ENGINE_DIR/hq-hook-old"
cat > "$OLD_ENGINE" <<STUB
#!/usr/bin/env bash
payload="\$(cat)"
printf '%s\n' "\$*" >> "$ENGINE_LOG"
args=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    --) shift; args=("\$@"); break ;;
    *) shift ;;
  esac
done
if [ -n "\${args[1]:-}" ]; then
  printf '%s\n' "shell-fallback \${args[*]}" >> "$ENGINE_LOG"
  printf '%s\n' "always outfact"
elif [ "\${args[0]:-}" = "PostToolUse" ]; then
  printf '%s\n' "always outfact"
else
  printf '%s\n' "always cmdfact"
fi
STUB
chmod +x "$OLD_ENGINE"

echo "[g] older CLI: its engine never sees the flag and answers natively"
reset
make_cli "$TMP/cli-old" "$OLD_CLI"
RUN_ROOT="$FWD" run HQ_POLICY_FACT_HELPER_DISABLE= PATH="$TMP/cli-old/bin:$PATH" \
  HQ_HOOK_BRIDGE_BIN="$OLD_ENGINE" HQ_HOOK_BRIDGE_PLAN="$(printf 'derive-trigger-facts%son' "$TAB")"
[ "$RC" = "0" ] && ok "rc 0" || bad "rc=$RC err=$(head -c 300 "$TMP/err")"
if grep -q 'shell-fallback\|--with-command-facts' "$ENGINE_LOG" 2>/dev/null; then
  bad "an older engine got the flag: $(cat "$ENGINE_LOG")"
else
  ok "no flag and no shell fallback"
fi
if [ "$(count "$ENGINE_LOG")" = "2" ] && grep -qF -- "-- PostToolUse" "$ENGINE_LOG" && grep -qF -- "-- PreToolUse" "$ENGINE_LOG"; then
  ok "two native engine calls, as before the flag"
else
  bad "engine calls: $(cat "$ENGINE_LOG" 2>/dev/null)"
fi
[ "$(count "$HELPER_LOG")" = "0" ] && ok "shell helper not run" || bad "helper ran: $(cat "$HELPER_LOG")"
post_policies_fired && ok "same policies fired as with the paired engine" \
  || bad "out=$(head -c 400 "$TMP/out")"

echo "[h] bridge on with no resolved CLI version: no flag"
reset
run HQ_HOOK_BRIDGE_BIN="$OLD_ENGINE" HQ_HOOK_BRIDGE_PLAN="$(printf 'derive-trigger-facts%son' "$TAB")"
[ "$RC" = "0" ] && ok "rc 0" || bad "rc=$RC err=$(head -c 300 "$TMP/err")"
if grep -q 'shell-fallback\|--with-command-facts' "$ENGINE_LOG" 2>/dev/null; then
  bad "the engine got the flag with no known CLI version: $(cat "$ENGINE_LOG")"
else
  ok "no flag when the CLI version is unknown"
fi
post_policies_fired && ok "command and output policies still fired" \
  || bad "out=$(head -c 400 "$TMP/out")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
