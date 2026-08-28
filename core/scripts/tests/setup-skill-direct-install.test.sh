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
SKILL="${ROOT}/.claude/skills/setup/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$SKILL" ]] || fail "setup skill missing: $SKILL"
body="$(cat "$SKILL")"

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

echo "PASS: setup-skill-direct-install (direct-install invariant held; picker gone; auth/bootstrap carve-outs, platform-aware installs, and failure reporting present)"
