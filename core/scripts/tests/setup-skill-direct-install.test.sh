#!/usr/bin/env bash
# Regression coverage for the reported /setup onboarding friction: the wizard
# paused mid-flow to ask how to handle missing CLI tools (hq-cli, qmd, gh) with
# an "install all / install some / skip all" picker. The fix makes /setup install
# missing dependencies directly and non-blocking. This test pins the invariant so
# the prompt-the-user behavior cannot silently return, and guards the follow-on
# correctness the fix depends on (platform-aware installs, bootstrap-dep escape
# hatch, and a place to report failures).
#
# It asserts against the LIVE skill text (.claude/skills/setup/SKILL.md) — the
# skill is prose an agent reads and executes, so the contract lives in the words.

set -euo pipefail

# NOTE: use `grep -q PAT <<<"$var"`, never `echo "$var" | grep -q PAT` — with
# pipefail a SIGPIPE on the writer can turn a passing assertion into a failure.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="${SETUP_SKILL_PATH:-${ROOT}/.claude/skills/setup/SKILL.md}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$SKILL" ]] || fail "setup skill missing: $SKILL"
body="$(cat "$SKILL")"

# X profiles are browser-harness-only. The no-harness fallback must disclose
# the skip up front, use WebSearch for gaps, and never WebFetch either X host.
phase_15="$(sed -n '/^## Phase 1.5:/,/^## Phase 2:/p' "$SKILL")"
grep -qF 'Instagram, X) readable' <<<"$phase_15" \
  || fail "9: browser-harness guidance must include X with LinkedIn and Instagram"
grep -qE 'login-walled sources \(LinkedIn, Instagram, X\) will be skipped' <<<"$phase_15" \
  || fail "9: fallback note must list X with LinkedIn and Instagram"
grep -qF 'for X / Twitter, say in one plain line that it is skipped' <<<"$phase_15" \
  || fail "9: without the browser harness, setup must skip X in one plain line"
grep -qF '`WebSearch` "{name} {handle}" to fill gaps' <<<"$phase_15" \
  || fail "9: without the browser harness, setup must use WebSearch for X gaps"
grep -qF 'Never `WebFetch` x.com or twitter.com.' <<<"$phase_15" \
  || fail "9: setup must explicitly prohibit WebFetch for both X hosts"
while IFS= read -r line; do
  case "$line" in
    *WebFetch*x.com*|*WebFetch*twitter.com*|*x.com*WebFetch*|*twitter.com*WebFetch*)
      [[ "$line" == *'Never `WebFetch` x.com or twitter.com.'* ]] \
        || fail "9: setup must not instruct WebFetch for an X domain: $line"
      ;;
  esac
done <<<"$phase_15"

# ── 1. The direct-install invariant is present ──────────────────────────────
grep -qF 'Install missing dependencies and CLI tools directly — never ask' <<<"$body" \
  || fail "1: the 'install directly, never ask' invariant is missing from the setup skill"

# ── 2. The old choose-your-install prompt behavior is GONE ──────────────────
# These are the exact phrasings the regression produced. If any returns, the
# wizard is asking the user how to handle tools again.
while IFS= read -r bad; do
  [[ -z "$bad" ]] && continue
  if grep -qF "$bad" <<<"$body"; then
    fail "2: stale ask-the-user phrasing returned to the setup skill: '$bad'"
  fi
done <<'BADPHRASES'
For P2 items: offer with context
Would you like me to install it now?
explain benefit and offer
BADPHRASES

# An "install all / some / none" style picker must not be reintroduced. The skill
# names that anti-pattern to forbid it; it must never appear as an instruction to
# actually present one. Assert the forbidding language frames every mention.
grep -qE 'never (surface|present) an .*install(-| )all' <<<"$body" \
  || fail "2: the setup skill must explicitly forbid the install-all/some/none picker"

# ── 3. The interactive-auth exception is spelled out ────────────────────────
# Installs are direct, but a browser auth (gh auth login) legitimately prompts —
# that carve-out must stay so the rule isn't read as "never prompt for anything".
grep -qF 'gh auth login' <<<"$body" \
  || fail "3: the interactive-auth exception (gh auth login) is missing"
grep -qiE 'interactive auth' <<<"$body" \
  || fail "3: the setup skill must name the interactive-auth exception to the no-prompt rule"

# ── 4. Bootstrap-dependency escape hatch exists (Node / a bare package mgr) ──
# The direct-install rule can't apply to Node itself (there's no npm to install
# it with). The skill must carve that out, or it contradicts its own P0 triage.
grep -qiE 'bootstrap dependenc' <<<"$body" \
  || fail "4: the setup skill must exempt bootstrap dependencies (e.g. Node) from the direct-install rule"

# ── 5. Platform-aware installs, not Homebrew-only ───────────────────────────
# gh install must degrade across brew / apt / winget so a non-macOS install
# isn't silently left without gh.
for mgr in 'brew install gh' 'apt-get install -y gh' 'winget install'; do
  grep -qF "$mgr" <<<"$body" \
    || fail "5: gh install path must cover '$mgr' (platform-aware, not Homebrew-only)"
done

# ── 6. macOS SQLite is actually installed for qmd, not just mentioned ────────
grep -qF 'brew install sqlite' <<<"$body" \
  || fail "6: qmd setup must install Homebrew SQLite on macOS (not only mention it in a comment)"

# ── 7. Failures have somewhere to surface — the Phase 3 summary section ──────
grep -qF 'Still needs attention:' <<<"$body" \
  || fail "7: the Phase 3 summary template must include a 'Still needs attention:' section for failed installs"

# ── 8. Desktop-managed hq CLI wins before a system npm fallback ──────────────
# A GUI-launched agent does not source the installer's shell-profile block. The
# skill must therefore put the existing managed binary on PATH before probing
# `hq`; otherwise it needlessly invokes the system-global npm install.
grep -qF 'HQ_MANAGED_TOOLCHAIN="$HOME/Library/Application Support/Indigo HQ/toolchain"' <<<"$body" \
  || fail "8: setup must locate the Desktop-managed toolchain"
grep -qF 'HQ_MANAGED_NODE_BIN="$HQ_MANAGED_TOOLCHAIN/node/bin"' <<<"$body" \
  || fail "8: setup must put the Desktop-managed Node runtime on PATH with hq"
grep -qF '[ -x "$HQ_MANAGED_HQ_BIN/hq" ]' <<<"$body" \
  || fail "8: setup must verify the managed hq executable before adding its bin directory"
grep -qF 'for bin in "$HQ_MANAGED_HQ_BIN" "$HQ_MANAGED_NODE_BIN"; do' <<<"$body" \
  || fail "8: setup must preserve managed Node before hq in PATH"

managed_line="$(grep -nF 'HQ_MANAGED_HQ_BIN=' <<<"$body" | head -1 | cut -d: -f1)"
fallback_line="$(grep -nF 'command -v hq >/dev/null 2>&1 || npm install -g @indigoai-us/hq-cli' <<<"$body" | head -1 | cut -d: -f1)"
[[ -n "$managed_line" && -n "$fallback_line" && "$managed_line" -lt "$fallback_line" ]] \
  || fail "8: setup must probe the managed CLI before its npm fallback"
grep -qF 'Do not consult `~/.hq`' <<<"$body" \
  || fail "8: setup must keep install-manifest state rooted in the current HQ directory"

# Execute the live documented shell block in a GUI-style fixture with no
# toolchain directories on PATH. The CLI launcher uses `env node`, so success
# proves the snippet adds both managed directories in the right order and does
# not fall through to npm.
snippet="$(awk '
  /^# hq-cli — honor the native installer/ { capture = 1 }
  capture { print }
  /^command -v hq >\/dev\/null 2>&1 \|\| npm install -g @indigoai-us\/hq-cli$/ { exit }
' "$SKILL")"
fixture_home="$TMP/home"
fixture_toolchain="$fixture_home/Library/Application Support/Indigo HQ/toolchain"
mkdir -p "$fixture_toolchain/node/bin" "$fixture_toolchain/npm-global/bin"
cat > "$fixture_toolchain/node/bin/node" <<'NODE'
#!/usr/bin/env sh
printf 'managed-hq\n'
NODE
cat > "$fixture_toolchain/npm-global/bin/hq" <<'HQ'
#!/usr/bin/env node
HQ
chmod +x "$fixture_toolchain/node/bin/node" "$fixture_toolchain/npm-global/bin/hq"
fixture_out="$(HOME="$fixture_home" PATH='/usr/bin:/bin' bash -c "$snippet; hq")"
[[ "$fixture_out" == 'managed-hq' ]] \
  || fail "8: documented setup block did not run hq with the managed Node runtime: $fixture_out"

# ── 10. qmd installs only the sanctioned pin ────────────────────────────────
# An unpinned `npm install -g @tobilu/qmd` took qmd 2.8.3 on Windows, whose
# better-sqlite3 has no native binary there, so every qmd command crashed
# (feedback ec9435cd). The skill must install the exact pin that
# core/scripts/install-deps.allow sanctions, the version Desktop and setup.sh use.
qmd_pin="$(grep -E '^@tobilu/qmd@[0-9]' "$ROOT/core/scripts/install-deps.allow" | head -1)"
[[ -n "$qmd_pin" ]] || fail "10: install-deps.allow has no @tobilu/qmd pin"
while IFS= read -r line; do
  [[ "$line" == *"install -g @tobilu/qmd"* ]] || continue
  [[ "$line" == *"install -g $qmd_pin"* ]] \
    || fail "10: setup must install the sanctioned qmd pin ($qmd_pin), not: $line"
done <<<"$body"
grep -qF "npm install -g $qmd_pin" <<<"$body" \
  || fail "10: setup must install qmd with the sanctioned pin ($qmd_pin)"

# ── 11. jq is installed on Windows (winget), like gh ────────────────────────
# master-hook fails closed on PreToolUse when jq is missing, and no installer
# provisions jq on Windows, so /setup must install it there with winget and
# keep the brew / apt paths for macOS and Linux.
grep -qF 'winget install --id jqlang.jq -e --source winget' <<<"$body" \
  || fail "11: setup must install jq on Windows with winget (jqlang.jq)"
for mgr in 'brew install jq' 'apt-get install -y jq'; do
  grep -qF "$mgr" <<<"$body" \
    || fail "11: jq install path must cover '$mgr'"
done
grep -qF 'open a new terminal' <<<"$body" \
  || fail "11: setup must tell Windows users to open a new terminal after the winget jq install"
grep -qF 'Install jq (Windows: winget install jqlang.jq; macOS: brew install jq; Debian/Ubuntu: sudo apt-get install jq)' <<<"$body" \
  || fail "11: setup must show the same jq install line that master-hook prints"
grep -qF 'master-hook: BLOCKED: required tool jq is missing' <<<"$body" \
  || fail "11: setup must say what to do when the jq hook block refuses the shell call"

# Execute the documented jq block on a Windows-like PATH: no jq, brew or
# apt-get; only a fake winget that records its arguments. /usr/bin is left off
# PATH because current macOS ships /usr/bin/jq.
jq_snippet="$(awk '
  /^# jq — required:/ { capture = 1 }
  capture { print }
  capture && /^fi$/ { exit }
' "$SKILL")"
[[ -n "$jq_snippet" ]] || fail "11: could not extract the jq install block from the setup skill"
winbin="$TMP/winbin"
mkdir -p "$winbin"
printf '#!%s\nprintf "%%s\\n" "$*" > "%s/winget.args"\n' "$(command -v bash)" "$TMP" > "$winbin/winget"
chmod +x "$winbin/winget"
PATH="$winbin" "$(command -v bash)" -c "$jq_snippet" \
  || fail "11: the documented jq install block failed on a Windows-like PATH"
[[ -f "$TMP/winget.args" ]] || fail "11: the jq install block did not call winget when jq was missing"
[[ "$(cat "$TMP/winget.args")" == 'install --id jqlang.jq -e --source winget' ]] \
  || fail "11: unexpected winget arguments for jq: $(cat "$TMP/winget.args")"

# ── 12. jq-missing state: hand the install to the user before anything runs ─
# With jq missing, master-hook refuses every tool call, so the PATH check and
# the install block cannot run. The skill must say so before the PATH check.
blocked_msg='master-hook: BLOCKED: required tool jq is missing'
install_line='Install jq (Windows: winget install jqlang.jq; macOS: brew install jq; Debian/Ubuntu: sudo apt-get install jq)'
first_line="$(grep -nF '**First: jq missing blocks every tool call.**' <<<"$body" | head -1 | cut -d: -f1)"
path_check_line="$(grep -nF 'for t in node npm qmd hq git yq jq; do' <<<"$body" | head -1 | cut -d: -f1)"
[[ -n "$first_line" && -n "$path_check_line" && "$first_line" -lt "$path_check_line" ]] \
  || fail "12: the jq-missing instruction must come before the Phase 0a PATH check"
first_block="$(sed -n "${first_line},${path_check_line}p" <<<"$body")"
for want in "$blocked_msg" "$install_line" 'including the PATH check below' 'Open a new terminal' 'then run `/setup` again'; do
  grep -qF "$want" <<<"$first_block" \
    || fail "12: jq-missing instruction must include: $want"
done

# ── 13. winget terms are never accepted silently ────────────────────────────
if grep -qE 'winget install[^`]*--accept-(source|package)-agreements' <<<"$body"; then
  fail "13: setup must not pass winget accept-agreement flags on the user's behalf"
fi
grep -qF "accept winget's terms on the user's behalf" <<<"$body" \
  || fail "13: setup must say it does not accept winget's terms for the user"

# ── 14. Quoted hook text matches what master-hook prints, byte for byte ─────
# Run the real dispatcher with jq absent from an isolated PATH (as in
# master-hook-missing-dependencies.test.sh) and require both quoted strings.
mh="$TMP/mh"
mkdir -p "$mh/hq/.claude/hooks" "$mh/hq/core/scripts/lib" "$mh/bin"
cp "$ROOT/.claude/hooks/master-hook.sh" "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$ROOT/.claude/hooks/hook-gate.sh" "$mh/hq/.claude/hooks/"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$mh/hq/core/scripts/lib/"
for tool in node hq qmd; do ln -s /usr/bin/true "$mh/bin/$tool"; done
for tool in bash awk cat date env mkdir mktemp mv rm tr sleep; do
  ln -s "$(command -v "$tool")" "$mh/bin/$tool"
done
mh_rc=0
printf '%s' '{"session_id":"setup-jq","tool_name":"Bash","tool_input":{"command":"true"}}' |
  env PATH="$mh/bin" HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_DEDUPE=0 \
    /bin/bash "$mh/hq/.claude/hooks/master-hook.sh" PreToolUse > "$mh/out" 2> "$mh/err" || mh_rc=$?
[[ "$mh_rc" == 2 ]] || fail "14: master-hook without jq should exit 2, got $mh_rc"
grep -qF "$blocked_msg" "$mh/err" || fail "14: skill quotes a BLOCKED message master-hook does not print: $(cat "$mh/err")"
grep -qF "$install_line" "$mh/err" || fail "14: skill's jq install line differs from master-hook's: $(cat "$mh/err")"

echo "PASS: setup-skill-direct-install (direct-install invariant held; picker gone; auth/bootstrap carve-outs, platform-aware installs, and failure reporting present)"
