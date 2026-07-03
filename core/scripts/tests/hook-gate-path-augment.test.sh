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
GATE="$ROOT/.claude/hooks/hook-gate.sh"
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

# Curated utils dir: symlink ONLY the externals the gate + probe hook need, so
# the gate runs with a PATH that deliberately EXCLUDES node/hq/qmd (this box may
# carry them in /usr/bin). That forces the "tools not resolvable" path so the
# augmentation is actually exercised, hermetically, regardless of the host.
UTILS="$TMP/utils"; mkdir -p "$UTILS"
for u in bash cat chmod ls sort tail; do
  real="$(command -v "$u")" || fail "required test util '$u' not found on host"
  ln -sf "$real" "$UTILS/$u"
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
make_tools "$H2/.nvm/versions/node/v18.19.0/bin"
make_tools "$H2/.nvm/versions/node/v20.11.1/bin"   # higher — must win
set +e; run_gate "$H2"; set -e
grep -q "$H2/.nvm/versions/node/v20.11.1/bin/node" "$TMP/probe.out" \
  || fail "nvm node not resolved to the highest version (got: $(cat "$TMP/probe.out"))"
pass "nvm highest version (v20.11.1) resolved over v18.19.0"

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

echo "ALL PASS: hook-gate-path-augment"
