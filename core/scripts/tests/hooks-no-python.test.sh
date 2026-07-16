#!/usr/bin/env bash
# hooks-no-python.test.sh — HQ's runtime hook layer must not depend on python3.
#
# Windows machines frequently have NO working python3 — or worse, the
# Microsoft Store alias stub, which resolves on PATH but fails every
# invocation, silently disabling any hook that shells out to python3
# (`command -v python3` alone cannot detect it). The migration replaced every
# runtime python3 call with hook-lib.sh primitives (jq-first, node fallback)
# or node analyzer programs.
#
# Guards:
#   1. TRIPWIRE — no runtime hook or script may invoke python3 again.
#      Scope: .claude/hooks/*.sh, .grok/hooks/*.sh, core/scripts/*.sh|*.js.
#      Comments are ignored; the one allowlisted literal is the interpreter
#      allowlist inside block-unsafe-package-install.sh (it classifies USER
#      commands like `python3 -c`, it never runs python3).
#   2. ENGINE PARITY — hook-lib primitives produce identical output under
#      HQ_HOOK_ENGINE=jq and HQ_HOOK_ENGINE=node.
#   3. BROKEN-PYTHON RUNTIME — with a python3 stub on PATH that fails every
#      call (the Store-alias worst case), policy injection still fires and the
#      frontmatter validator still blocks/allows correctly on both engines.
#
# Explicitly wired into .github/workflows/pr-checks.yml — tests here are NOT
# auto-discovered (indigo-hq-core-staging-pr-mechanics rule 3).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
VALIDATOR="$ROOT/.claude/hooks/validate-policy-frontmatter.sh"
PASS=0; FAIL=0
RUN="nopy-$$-$RANDOM"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required for this suite"; exit 0; }

TMP="$(mktemp -d)"
LEDGER_DIR="$ROOT/workspace/orchestrator/policy-trigger-state"
trap 'rm -rf "$TMP"; rm -f "$LEDGER_DIR"/nopy-*.txt 2>/dev/null || true' EXIT

ok()   { PASS=$((PASS+1)); echo "ok   [$1]"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]: $2"; }

echo "== 1. tripwire: no python3 invocations in runtime hooks/scripts =="
# Strip comment lines, then look for the interpreter name. The single
# allowlisted file carries it only as a QUOTED CLASSIFICATION LITERAL.
VIOLATIONS=""
for f in "$ROOT"/.claude/hooks/*.sh "$ROOT"/.grok/hooks/*.sh "$ROOT"/.codex/hooks/*.sh "$ROOT"/core/scripts/*.sh "$ROOT"/core/scripts/*.js; do
  [ -f "$f" ] || continue
  hits="$(grep -n "python3" "$f" 2>/dev/null | grep -vE '^[0-9]+:\s*(#|//)' || true)"
  [ -n "$hits" ] || continue
  case "$(basename "$f")" in
    block-unsafe-package-install.sh)
      # Allowed ONLY as the quoted interpreter-wrapper literal in the guard's
      # own allowlist; any unquoted/other use is a violation.
      bad="$(printf '%s\n' "$hits" | grep -v '"python3 -c"' || true)"
      [ -n "$bad" ] && VIOLATIONS="$VIOLATIONS
$f: $bad"
      ;;
    *)
      VIOLATIONS="$VIOLATIONS
$f: $hits"
      ;;
  esac
done
if [ -z "$VIOLATIONS" ]; then
  ok "no runtime python3 invocation"
else
  fail "no runtime python3 invocation" "$VIOLATIONS"
fi

echo "== 2. engine parity: hook-lib primitives (jq vs node) =="
if command -v node >/dev/null 2>&1; then
  PAYLOAD='{"a":{"b":"x y"},"e":[{"o":"v"}],"n":7,"t":true}'
  for probe in "a.b" "e.0.o" "n" "t" "missing.key"; do
    r_jq="$(printf '%s' "$PAYLOAD" | HQ_HOOK_ENGINE=jq bash -c '. "'"$ROOT"'/core/scripts/hook-lib.sh"; hq_json_get "$1"' _ "$probe")"
    r_node="$(printf '%s' "$PAYLOAD" | HQ_HOOK_ENGINE=node bash -c '. "'"$ROOT"'/core/scripts/hook-lib.sh"; hq_json_get "$1"' _ "$probe")"
    if [ "$r_jq" = "$r_node" ]; then
      ok "hq_json_get parity: $probe -> [$r_jq]"
    else
      fail "hq_json_get parity: $probe" "jq=[$r_jq] node=[$r_node]"
    fi
  done
  ENC_IN='he said "hi"
line2	tabbed'
  e_jq="$(printf '%s' "$ENC_IN" | HQ_HOOK_ENGINE=jq bash -c '. "'"$ROOT"'/core/scripts/hook-lib.sh"; hq_json_encode')"
  e_node="$(printf '%s' "$ENC_IN" | HQ_HOOK_ENGINE=node bash -c '. "'"$ROOT"'/core/scripts/hook-lib.sh"; hq_json_encode')"
  if [ "$e_jq" = "$e_node" ]; then ok "hq_json_encode parity"; else fail "hq_json_encode parity" "jq=[$e_jq] node=[$e_node]"; fi
else
  echo "note: node unavailable — parity checks skipped (jq path already exercised below)"
fi

echo "== 3. broken python3 on PATH: injection + validator still work =="
mkdir -p "$TMP/bin"
printf '#!/bin/bash\nexit 9\n' > "$TMP/bin/python3"
chmod +x "$TMP/bin/python3"
BROKEN_PATH="$TMP/bin:$PATH"

O="$(printf '{"hook_event_name":"SessionStart","session_id":"%s-ss","cwd":"%s"}' "$RUN" "$ROOT" \
  | PATH="$BROKEN_PATH" HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$O" | grep -Fq '> Policy `'; then
  ok "SessionStart injects baseline policies with broken python3"
else
  fail "SessionStart injects baseline policies with broken python3" "no reminder emitted"
fi
O2="$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s-up","prompt":"/handoff please","cwd":"%s"}' "$RUN" "$ROOT" \
  | PATH="$BROKEN_PATH" HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$O2" | grep -Fq 'hq-handoff-changeset-scope'; then
  ok "reactive /handoff trigger fires with broken python3"
else
  fail "reactive /handoff trigger fires with broken python3" "slug missing; got: $(printf '%s' "$O2" | tr '\n' ' ' | cut -c1-200)"
fi

mkdir -p "$TMP/policies"
GOOD="$TMP/policies/good-policy.md"
printf -- '---\nid: good-policy\nwhen: always\non: [SessionStart]\n---\n\n## Rule\n\nBe good.\n' > "$GOOD"
BAD="$TMP/policies/bad-policy.md"
printf -- '---\nid: bad-policy\n---\n\n## Rule\n\nNo triggers.\n' > "$BAD"

payload_write() { jq -n --arg fp "$1" --rawfile c "$2" '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}'; }
run_validator() { # <engine or "-"> <payload> -> prints exit code
  local eng="$1" payload="$2"
  if [ "$eng" = "-" ]; then
    printf '%s' "$payload" | PATH="$BROKEN_PATH" CLAUDE_PROJECT_DIR="$ROOT" bash "$VALIDATOR" >/dev/null 2>&1
  else
    printf '%s' "$payload" | PATH="$BROKEN_PATH" HQ_HOOK_ENGINE="$eng" CLAUDE_PROJECT_DIR="$ROOT" bash "$VALIDATOR" >/dev/null 2>&1
  fi
  echo $?
}

PW_GOOD="$(payload_write "$GOOD" "$GOOD")"
PW_BAD="$(payload_write "$BAD" "$BAD")"

ENGINES="-"
command -v node >/dev/null 2>&1 && ENGINES="- jq node"
for eng in $ENGINES; do
  label="$eng"; [ "$eng" = "-" ] && label="default"
  RC_GOOD="$(run_validator "$eng" "$PW_GOOD")"
  RC_BAD="$(run_validator "$eng" "$PW_BAD")"
  if [ "$RC_GOOD" = 0 ]; then ok "validator($label) allows valid frontmatter"; else fail "validator($label) allows valid frontmatter" "exit $RC_GOOD"; fi
  if [ "$RC_BAD" = 2 ]; then ok "validator($label) blocks missing when/on"; else fail "validator($label) blocks missing when/on" "exit $RC_BAD"; fi
done

# Edit-replay path: removing the when: line must BLOCK (jq/awk engine).
PE="$(jq -n --arg fp "$GOOD" '{tool_name:"Edit",tool_input:{file_path:$fp,old_string:"when: always\n",new_string:""}}')"
RC="$(run_validator jq "$PE")"
if [ "$RC" = 2 ]; then ok "validator(jq) Edit replay blocks when:-removal"; else fail "validator(jq) Edit replay blocks when:-removal" "exit $RC"; fi

# CRLF line endings (Windows editors): a valid CRLF policy must still be
# ALLOWED and an invalid CRLF one still BLOCKED — the python original's \s*
# tolerated \r\n, and the ports normalize before analysis (codex review
# https://github.com/indigoai-us/hq-core-staging/pull/373#discussion_r3587373355).
GOOD_CRLF="$TMP/policies/good-crlf-policy.md"
printf -- '---\r\nid: good-crlf-policy\r\nwhen: always\r\non: [SessionStart]\r\n---\r\n\r\n## Rule\r\n\r\nBe good on Windows.\r\n' > "$GOOD_CRLF"
BAD_CRLF="$TMP/policies/bad-crlf-policy.md"
printf -- '---\r\nid: bad-crlf-policy\r\n---\r\n\r\n## Rule\r\n\r\nNo triggers, CRLF.\r\n' > "$BAD_CRLF"
PW_GOOD_CRLF="$(payload_write "$GOOD_CRLF" "$GOOD_CRLF")"
PW_BAD_CRLF="$(payload_write "$BAD_CRLF" "$BAD_CRLF")"
for eng in $ENGINES; do
  label="$eng"; [ "$eng" = "-" ] && label="default"
  RC_GOOD="$(run_validator "$eng" "$PW_GOOD_CRLF")"
  RC_BAD="$(run_validator "$eng" "$PW_BAD_CRLF")"
  if [ "$RC_GOOD" = 0 ]; then ok "validator($label) allows valid CRLF frontmatter"; else fail "validator($label) allows valid CRLF frontmatter" "exit $RC_GOOD"; fi
  if [ "$RC_BAD" = 2 ]; then ok "validator($label) blocks CRLF missing when/on"; else fail "validator($label) blocks CRLF missing when/on" "exit $RC_BAD"; fi
done

echo
echo "==== hooks-no-python: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ] || exit 1
