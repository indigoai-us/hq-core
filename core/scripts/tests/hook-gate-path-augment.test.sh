#!/usr/bin/env bash
# Regression: hook-gate.sh must make node/hq/qmd resolvable for the delegated
# hook even when they live outside the inherited PATH — i.e. the user installed
# Node via a version manager (nvm/volta/fnm/asdf) or into ~/.local/bin rather
# than Homebrew. Before the fix, an old HQ install pinned a Homebrew-only hook
# PATH, so a non-Homebrew Node user's hooks all failed to find node/hq/qmd,
# errored, and Claude appeared dead in the HQ root (DEV task-198633788).
#
# The gate probes well-known install dirs and prepends the ones that hold a
# tool. It must NEVER source shell rc/profile files (sensitive-path policy) —
# these tests only rely on directory probing.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
GATE="${HQ_TEST_HOOK_GATE:-$ROOT/.claude/hooks/hook-gate.sh}"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }
[ -f "$GATE" ] || fail "hook-gate.sh not found at $GATE"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A fake in-profile hook (detect-secrets is in every profile). It records where
# node/hq/qmd resolve to, so the test can prove the gate put the right dir on
# PATH before exec.
cat > "$TMP/probe-hook.sh" <<'HOOK'
#!/bin/bash
cat >/dev/null
{
  command -v node || echo "NO_NODE"
  command -v hq   || echo "NO_HQ"
  command -v qmd  || echo "NO_QMD"
  command -v jq   || echo "NO_JQ"
  echo "PATH=$PATH"
} > "$PROBE_OUT" 2>&1
echo "PROBE_HOOK_RAN" >&2
exit 0
HOOK
chmod +x "$TMP/probe-hook.sh"

# Build a fake tool dir with executable node/hq/qmd stubs.
make_tools() {
  local dir="$1"; mkdir -p "$dir"
  local t
  for t in node hq qmd; do
    printf '#!/bin/bash\necho "%s-from-%s"\n' "$t" "$dir" > "$dir/$t"
    chmod +x "$dir/$t"
  done
}

# Curated utils dir: wrappers (not symlinks) so Windows Git Bash does not break
# on shared-library resolution for symlinked bash. PATH deliberately EXCLUDES
# node/hq/qmd so augmentation is exercised regardless of the host.
UTILS="$TMP/utils"; mkdir -p "$UTILS"
for u in awk bash cat chmod ls sort tail uname; do
  real="$(command -v "$u")" || fail "required test util '$u' not found on host"
  # Quote real path for spaces (e.g. Program Files).
  printf '#!/bin/bash\nexec "%s" "$@"\n' "$real" > "$UTILS/$u"
  chmod +x "$UTILS/$u"
done

# Run the gate with the curated PATH + a fake HOME so the probe hook can only
# find node/hq/qmd via the gate augmenting HOME's tool dirs. We UNSET the
# version-manager env vars (NVM_DIR/FNM_DIR/VOLTA_HOME/ASDF_DATA_DIR) so the
# augment falls back to HOME-relative defaults (our fixtures) instead of a CI
# runner's real installs, keeping the test hermetic.
run_gate() {
  local home="$1"
  env -u NVM_DIR -u FNM_DIR -u VOLTA_HOME -u ASDF_DATA_DIR \
    PROBE_OUT="$TMP/probe.out" \
    HOME="$home" \
    PATH="$UTILS" \
    bash "$GATE" detect-secrets "$TMP/probe-hook.sh" <<<'{}' 2>"$TMP/err"
}

# ---------------------------------------------------------------------------
echo "[1] volta-style ~/.volta/bin (off PATH) is discovered and prepended"
H1="$TMP/home-volta"; make_tools "$H1/.volta/bin"
set +e; run_gate "$H1"; code=$?; set -e
grep -q PROBE_HOOK_RAN "$TMP/err" || fail "probe hook did not run (stderr: $(cat "$TMP/err"))"
[ "$code" -eq 0 ] || fail "expected exit 0 from probe hook, got $code"
grep -q "$H1/.volta/bin/node" "$TMP/probe.out" || fail "node not resolved to ~/.volta/bin (got: $(cat "$TMP/probe.out"))"
grep -q "$H1/.volta/bin/hq"  "$TMP/probe.out" || fail "hq not resolved to ~/.volta/bin"
grep -q "$H1/.volta/bin/qmd" "$TMP/probe.out" || fail "qmd not resolved to ~/.volta/bin"
pass "node/hq/qmd resolved from ~/.volta/bin"

# ---------------------------------------------------------------------------
echo "[2] nvm-style versioned dir: highest installed version is resolved"
H2="$TMP/home-nvm"
make_tools "$H2/.nvm/versions/node/v9.99.0/bin"     # lexical trap: must not beat v20
make_tools "$H2/.nvm/versions/node/v18.19.0/bin"
make_tools "$H2/.nvm/versions/node/v20.11.1/bin"   # higher — must win
set +e; run_gate "$H2"; set -e
grep -q "$H2/.nvm/versions/node/v20.11.1/bin/node" "$TMP/probe.out" \
  || fail "nvm node not resolved to the highest version (got: $(cat "$TMP/probe.out"))"
pass "nvm highest version (v20.11.1) resolved over v18.19.0"

if sed 's/#.*//' "$GATE" | grep -qE 'sort[[:space:]]+-V|sort[[:space:]]+--version-sort'; then
  fail "hook-gate must not use GNU-only sort -V (macOS ships BSD sort)"
fi
pass "node version selection avoids GNU-only sort -V"

# ---------------------------------------------------------------------------
echo "[3] ~/.local/bin fallback is discovered"
H3="$TMP/home-local"; make_tools "$H3/.local/bin"
set +e; run_gate "$H3"; set -e
grep -q "$H3/.local/bin/node" "$TMP/probe.out" || fail "node not resolved from ~/.local/bin"
pass "node/hq/qmd resolved from ~/.local/bin"

# ---------------------------------------------------------------------------
echo "[4] safety: empty fixture HOME — the hook STILL runs (augment never blocks)"
# The augment also probes real system dirs (/usr/local/bin, /opt/homebrew/bin),
# which on some hosts (e.g. CI runners) legitimately hold a node — so we assert
# the real guarantee (the gate never converts a missing tool into a failed hook)
# rather than tool-absence, which the host controls.
H4="$TMP/home-empty"; mkdir -p "$H4"
set +e; run_gate "$H4"; code=$?; set -e
grep -q PROBE_HOOK_RAN "$TMP/err" || fail "probe hook must still run when no fixture tools are found"
[ "$code" -eq 0 ] || fail "gate must not fail the hook when tools are missing (got $code)"
pass "hook ran and propagated exit 0 with no fixture tools (best-effort, non-blocking)"

# ---------------------------------------------------------------------------
echo "[5] the gate never sources shell rc/profile files"
# Strip comments first (the fix carries an explanatory comment that NAMES these
# files), then look for an actual `source`/`.` command targeting a profile file.
if sed 's/#.*//' "$GATE" \
  | grep -qE '(^|[[:space:];&|])(source|\.)[[:space:]]+[^[:space:]]*(bashrc|zshrc|\.profile|bash_profile|zprofile)'; then
  fail "hook-gate.sh must NOT source shell rc/profile files (sensitive-path policy)"
fi
pass "no rc/profile sourcing in hook-gate.sh"

# ---------------------------------------------------------------------------
echo "[6] Windows APPDATA/npm is discovered under simulated MINGW uname"
# Force the MINGW branch via a uname wrapper on PATH. Host system dirs
# (/usr/local/bin) may still hold node; assert hq+qmd resolve from APPDATA
# (Windows candidates are prepended before Homebrew/system on MINGW).
H6="$TMP/home-win"
APPDATA_FIX="$H6/AppData/Roaming"
make_tools "$APPDATA_FIX/npm"
# Override uname in UTILS for this run only.
printf '#!/bin/bash\necho MINGW64_NT-10.0\n' > "$UTILS/uname"
chmod +x "$UTILS/uname"
set +e
env -u NVM_DIR -u FNM_DIR -u VOLTA_HOME -u ASDF_DATA_DIR \
  PROBE_OUT="$TMP/probe.out" \
  HOME="$H6" \
  APPDATA="$APPDATA_FIX" \
  PATH="$UTILS" \
  bash "$GATE" detect-secrets "$TMP/probe-hook.sh" <<<'{}' 2>"$TMP/err6"
set -e
# Restore real uname wrapper for any later use
real_uname="$(command -v uname)"
printf '#!/bin/bash\nexec "%s" "$@"\n' "$real_uname" > "$UTILS/uname"
chmod +x "$UTILS/uname"
grep -q PROBE_HOOK_RAN "$TMP/err6" || fail "probe hook did not run for Windows APPDATA fixture (stderr: $(cat "$TMP/err6"))"
grep -q "$APPDATA_FIX/npm/hq" "$TMP/probe.out" \
  || fail "hq not resolved from APPDATA/npm (got: $(cat "$TMP/probe.out"))"
grep -q "$APPDATA_FIX/npm/qmd" "$TMP/probe.out" \
  || fail "qmd not resolved from APPDATA/npm (got: $(cat "$TMP/probe.out"))"
pass "Windows APPDATA/npm path discovered under simulated MINGW"

# ---------------------------------------------------------------------------
echo "[7] installer toolchain npm-global/bin and node/bin win over a stale ~/.local/bin hq"
# feedback_54e69cd9: hq lived only in the Indigo HQ toolchain npm-global/bin,
# which hq_augment_path never probed, so hooks reported hq missing from PATH.
H7="$TMP/home-toolchain"
TC7="$H7/Library/Application Support/Indigo HQ/toolchain"
make_tools "$TC7/npm-global/bin"
rm -f "$TC7/npm-global/bin/node"
make_tools "$TC7/node/bin"
rm -f "$TC7/node/bin/hq" "$TC7/node/bin/qmd"
make_tools "$H7/.local/bin"
set +e
env -u NVM_DIR -u FNM_DIR -u VOLTA_HOME -u ASDF_DATA_DIR -u HQ_TOOLCHAIN_DIR \
  PROBE_OUT="$TMP/probe.out" \
  HOME="$H7" \
  PATH="$UTILS" \
  bash "$GATE" detect-secrets "$TMP/probe-hook.sh" <<<'{}' 2>"$TMP/err7"
set -e
grep -q PROBE_HOOK_RAN "$TMP/err7" || fail "probe hook did not run for toolchain fixture (stderr: $(cat "$TMP/err7"))"
grep -qxF "$TC7/npm-global/bin/hq" "$TMP/probe.out" \
  || fail "hq not resolved from toolchain npm-global/bin (got: $(cat "$TMP/probe.out"))"
grep -qxF "$TC7/npm-global/bin/qmd" "$TMP/probe.out" \
  || fail "qmd not resolved from toolchain npm-global/bin (got: $(cat "$TMP/probe.out"))"
grep -qxF "$TC7/node/bin/node" "$TMP/probe.out" \
  || fail "node not resolved from toolchain node/bin (got: $(cat "$TMP/probe.out"))"
pass "installer toolchain dirs discovered ahead of ~/.local/bin"

# ---------------------------------------------------------------------------
echo "[8] ~/.npm-global/bin is discovered and wins over a stale ~/.local/bin hq"
# feedback_e49ce279: ~/.local/bin/hq wrapped a stale pnpm copy while the current
# hq lived in npm's user prefix, which the augment never probed.
H8="$TMP/home-npm-global"
make_tools "$H8/.npm-global/bin"
make_tools "$H8/.local/bin"
set +e; run_gate "$H8"; set -e
grep -q PROBE_HOOK_RAN "$TMP/err" || fail "probe hook did not run for npm-global fixture (stderr: $(cat "$TMP/err"))"
grep -qxF "$H8/.npm-global/bin/hq" "$TMP/probe.out" \
  || fail "hq not resolved from ~/.npm-global/bin (got: $(cat "$TMP/probe.out"))"
pass "~/.npm-global/bin discovered ahead of ~/.local/bin"

# ---------------------------------------------------------------------------
echo "[9] jq off PATH is recovered even when node/hq/qmd already resolve"
# T5 281: master-hook.sh fails closed on PreToolUse when jq is missing after
# hq_augment_path. The fast path returned as soon as node/hq/qmd resolved and
# directories were admitted only for node/hq/qmd, so a jq in ~/.local/bin was
# never found and every tool call was blocked.
H9="$TMP/home-jq-local"; mkdir -p "$H9/.local/bin"
printf '#!/bin/bash\necho jq-from-local\n' > "$H9/.local/bin/jq"; chmod +x "$H9/.local/bin/jq"
ONPATH9="$TMP/onpath9"; make_tools "$ONPATH9"
set +e
env -u NVM_DIR -u FNM_DIR -u VOLTA_HOME -u ASDF_DATA_DIR -u HQ_TOOLCHAIN_DIR \
  PROBE_OUT="$TMP/probe.out" \
  HOME="$H9" \
  PATH="$UTILS:$ONPATH9" \
  bash "$GATE" detect-secrets "$TMP/probe-hook.sh" <<<'{}' 2>"$TMP/err9"
set -e
grep -q PROBE_HOOK_RAN "$TMP/err9" || fail "probe hook did not run for jq fixture (stderr: $(cat "$TMP/err9"))"
grep -qxF "$H9/.local/bin/jq" "$TMP/probe.out" \
  || fail "jq not resolved from ~/.local/bin when node/hq/qmd were already on PATH (got: $(cat "$TMP/probe.out"))"
grep -qxF "$ONPATH9/node" "$TMP/probe.out" \
  || fail "node on the inherited PATH must keep resolving first (got: $(cat "$TMP/probe.out"))"
path9="$(grep '^PATH=' "$TMP/probe.out")"
case "${path9#PATH=}" in
  *":$H9/.local/bin") ;;
  *) fail "a folder added only for jq must go at the END of PATH (got: $path9)" ;;
esac
pass "jq recovered from ~/.local/bin; inherited node/hq/qmd unchanged"

# ---------------------------------------------------------------------------
echo "[10] Windows winget Links and package folders holding jq.exe are added under MINGW"
# The missing-jq message tells Windows users to run winget install jqlang.jq.
# winget links the portable jq.exe into %LOCALAPPDATA%\Microsoft\WinGet\Links,
# or puts its package folder on the user PATH when it cannot link. A session
# opened before the install inherits neither.
H10="$TMP/home-winget"; LAD10="$H10/AppData/Local"
WG10="$LAD10/Microsoft/WinGet"
PKG10="$WG10/Packages/jqlang.jq_Microsoft.Winget.Source_8wekyb3d8bbwe"
mkdir -p "$WG10/Links" "$PKG10" "$WG10/Packages/Other.Tool_x"
printf '#!/bin/bash\necho jq\n' > "$WG10/Links/jq.exe"
printf '#!/bin/bash\necho jq\n' > "$PKG10/jq.exe"
chmod +x "$WG10/Links/jq.exe" "$PKG10/jq.exe"
printf '#!/bin/bash\necho MINGW64_NT-10.0\n' > "$UTILS/uname"; chmod +x "$UTILS/uname"
set +e
env -u NVM_DIR -u FNM_DIR -u VOLTA_HOME -u ASDF_DATA_DIR -u HQ_TOOLCHAIN_DIR -u APPDATA -u USERPROFILE \
  PROBE_OUT="$TMP/probe.out" \
  HOME="$H10" \
  LOCALAPPDATA="$LAD10" \
  PATH="$UTILS" \
  bash "$GATE" detect-secrets "$TMP/probe-hook.sh" <<<'{}' 2>"$TMP/err10"
set -e
printf '#!/bin/bash\nexec "%s" "$@"\n' "$real_uname" > "$UTILS/uname"; chmod +x "$UTILS/uname"
grep -q PROBE_HOOK_RAN "$TMP/err10" || fail "probe hook did not run for winget fixture (stderr: $(cat "$TMP/err10"))"
path10="$(grep '^PATH=' "$TMP/probe.out")"
case ":${path10#PATH=}:" in
  *":$WG10/Links:"*) ;;
  *) fail "WinGet Links not added to PATH (got: $path10)" ;;
esac
case ":${path10#PATH=}:" in
  *":$PKG10:"*) ;;
  *) fail "winget jqlang.jq package folder not added to PATH (got: $path10)" ;;
esac
case ":${path10#PATH=}:" in
  *"Other.Tool_x"*) fail "a winget package folder without jq.exe was added (got: $path10)" ;;
esac
pass "winget Links and jqlang.jq package folder added; unrelated package folder skipped"

# ---------------------------------------------------------------------------
echo "[11] MINGW, node/hq/qmd already on PATH: winget jq folder is appended at the END"
# The Windows case the jq recovery exists for: node and hq work, the user ran
# winget install jqlang.jq in an already-open session. Only jq is missing, so
# the WinGet Links folder must be appended and the inherited node keep winning.
H11="$TMP/home-winget-jqonly"; WG11="$H11/AppData/Local/Microsoft/WinGet"
mkdir -p "$WG11/Links"
printf '#!/bin/bash\necho jq\n' > "$WG11/Links/jq.exe"; chmod +x "$WG11/Links/jq.exe"
ONPATH11="$TMP/onpath11"; make_tools "$ONPATH11"
printf '#!/bin/bash\necho MINGW64_NT-10.0\n' > "$UTILS/uname"; chmod +x "$UTILS/uname"
set +e
env -u NVM_DIR -u FNM_DIR -u VOLTA_HOME -u ASDF_DATA_DIR -u HQ_TOOLCHAIN_DIR -u APPDATA -u USERPROFILE \
  PROBE_OUT="$TMP/probe.out" \
  HOME="$H11" \
  LOCALAPPDATA="$H11/AppData/Local" \
  PATH="$UTILS:$ONPATH11" \
  bash "$GATE" detect-secrets "$TMP/probe-hook.sh" <<<'{}' 2>"$TMP/err11"
set -e
printf '#!/bin/bash\nexec "%s" "$@"\n' "$real_uname" > "$UTILS/uname"; chmod +x "$UTILS/uname"
grep -q PROBE_HOOK_RAN "$TMP/err11" || fail "probe hook did not run for winget jq-only fixture (stderr: $(cat "$TMP/err11"))"
grep -qxF "$ONPATH11/node" "$TMP/probe.out" \
  || fail "inherited node must keep resolving first (got: $(cat "$TMP/probe.out"))"
path11="$(grep '^PATH=' "$TMP/probe.out")"
case "${path11#PATH=}" in
  "$UTILS:$ONPATH11:$WG11/Links") ;;
  *) fail "WinGet Links must be appended after the inherited PATH and nothing else added (got: $path11)" ;;
esac
pass "winget Links appended at the end; inherited node/hq/qmd keep priority"

# ---------------------------------------------------------------------------
echo "[12] jq already resolves: a folder holding only jq is not added"
# When node is missing the recovery prepends folders that hold node/hq/qmd.
# A folder that holds only jq must not be admitted while jq already resolves,
# or its other binaries would shadow the user's.
H12="$TMP/home-jq-resolves"; mkdir -p "$H12/.local/bin"
printf '#!/bin/bash\necho jq\n' > "$H12/.local/bin/jq"; chmod +x "$H12/.local/bin/jq"
make_tools "$H12/.volta/bin"
JQ12="$TMP/jq12"; mkdir -p "$JQ12"
printf '#!/bin/bash\necho jq\n' > "$JQ12/jq"; chmod +x "$JQ12/jq"
set +e
env -u NVM_DIR -u FNM_DIR -u VOLTA_HOME -u ASDF_DATA_DIR -u HQ_TOOLCHAIN_DIR \
  PROBE_OUT="$TMP/probe.out" \
  HOME="$H12" \
  PATH="$UTILS:$JQ12" \
  bash "$GATE" detect-secrets "$TMP/probe-hook.sh" <<<'{}' 2>"$TMP/err12"
set -e
grep -q PROBE_HOOK_RAN "$TMP/err12" || fail "probe hook did not run for jq-resolves fixture (stderr: $(cat "$TMP/err12"))"
grep -qxF "$H12/.volta/bin/node" "$TMP/probe.out" \
  || fail "node not recovered from ~/.volta/bin (got: $(cat "$TMP/probe.out"))"
grep -qxF "$JQ12/jq" "$TMP/probe.out" \
  || fail "the inherited jq must keep resolving (got: $(cat "$TMP/probe.out"))"
case "$(grep '^PATH=' "$TMP/probe.out")" in
  *"$H12/.local/bin"*) fail "a jq-only folder was added while jq already resolved (got: $(grep '^PATH=' "$TMP/probe.out"))" ;;
esac
pass "jq-only folder skipped while jq resolves; node folder still prepended"

# ---------------------------------------------------------------------------
echo "[13] failglob in the shell does not abort recovery when winget has no Packages folder"
H13="$TMP/home-failglob"; WG13="$H13/AppData/Local/Microsoft/WinGet"
mkdir -p "$WG13/Links"
printf '#!/bin/bash\necho jq\n' > "$WG13/Links/jq.exe"; chmod +x "$WG13/Links/jq.exe"
printf 'shopt -s failglob\n' > "$TMP/failglob.env"
printf '#!/bin/bash\necho MINGW64_NT-10.0\n' > "$UTILS/uname"; chmod +x "$UTILS/uname"
set +e
env -u NVM_DIR -u FNM_DIR -u VOLTA_HOME -u ASDF_DATA_DIR -u HQ_TOOLCHAIN_DIR -u APPDATA -u USERPROFILE \
  BASH_ENV="$TMP/failglob.env" \
  PROBE_OUT="$TMP/probe.out" \
  HOME="$H13" \
  LOCALAPPDATA="$H13/AppData/Local" \
  PATH="$UTILS" \
  bash "$GATE" detect-secrets "$TMP/probe-hook.sh" <<<'{}' 2>"$TMP/err13"
set -e
printf '#!/bin/bash\nexec "%s" "$@"\n' "$real_uname" > "$UTILS/uname"; chmod +x "$UTILS/uname"
grep -q PROBE_HOOK_RAN "$TMP/err13" || fail "probe hook did not run under failglob (stderr: $(cat "$TMP/err13"))"
grep -q "no match" "$TMP/err13" && fail "failglob aborted the winget probe (stderr: $(cat "$TMP/err13"))"
case ":$(grep '^PATH=' "$TMP/probe.out" | sed 's/^PATH=//'):" in
  *":$WG13/Links:"*) ;;
  *) fail "WinGet Links not added under failglob (got: $(grep '^PATH=' "$TMP/probe.out"))" ;;
esac
pass "failglob set, no Packages folder: recovery completes and adds WinGet Links"

echo "ALL PASS: hook-gate-path-augment"

. "$GATE" --lib
HQ_HOOK_PROFILE=minimal HQ_DISABLED_HOOKS= hq_hook_profile_allows policy-enforcement-gate \
  || fail "minimal profile must keep the policy enforcement gate enabled"
HQ_HOOK_PROFILE=minimal HQ_DISABLED_HOOKS= hq_hook_profile_allows inject-policy-on-trigger \
  || fail "minimal profile must enable the injector that supplies gate policy rows"
pass "minimal profile enables both policy enforcement and policy injection"
# feedback_87abfe55: `hq doctor` reported block-on-active-run missing from the
# minimal allowlist (present in standard and strict), so it silently no-oped.
HQ_HOOK_PROFILE=minimal HQ_DISABLED_HOOKS= hq_hook_profile_allows block-on-active-run \
  || fail "minimal profile must keep block-on-active-run (a safety guard) enabled"
pass "minimal profile enables block-on-active-run"
