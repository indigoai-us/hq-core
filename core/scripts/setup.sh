#!/usr/bin/env bash
# core/scripts/setup.sh — Bootstrap HQ on a fresh machine
# Usage: ./scripts/setup.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# ── Helpers ──────────────────────────────────────────────────────────────────

ok()   { printf '  ✓ %s\n' "$1"; }
skip() { printf '  • %s (skipped)\n' "$1"; }
fail() { printf '  ✗ %s\n' "$1" >&2; }
ask()  { printf '\n%s [y/N] ' "$1"; read -r answer; [[ "$answer" =~ ^[Yy] ]]; }

check_cmd() {
  command -v "$1" &>/dev/null
}

# ── 1. Prerequisites ────────────────────────────────────────────────────────

echo "╔══════════════════════════════════════╗"
echo "║          HQ Setup                    ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo "Checking prerequisites…"

# Node.js
if check_cmd node; then
  ok "node $(node --version)"
else
  fail "node not found — install via https://nodejs.org or nvm"
  exit 1
fi

# npm
if check_cmd npm; then
  ok "npm $(npm --version)"
else
  fail "npm not found"
  exit 1
fi

# jq (used by hooks)
if check_cmd jq; then
  ok "jq $(jq --version)"
else
  fail "jq not found — install via: brew install jq"
  exit 1
fi

# Claude Code CLI (optional — needed for subprocess pattern)
if check_cmd claude; then
  ok "claude CLI found"
else
  skip "claude CLI not found — install via: npm install -g @anthropic-ai/claude-code"
fi

# GitHub CLI (optional)
if check_cmd gh; then
  ok "gh $(gh --version | head -1)"
else
  skip "gh not found — install via: brew install gh"
fi

# ── 2. Install qmd ──────────────────────────────────────────────────────────

QMD_VERSION="1.0.7"

echo ""
echo "Setting up qmd@$QMD_VERSION…"

INSTALLED_QMD="$(qmd --version 2>/dev/null | awk '{print $2}' || true)"

if [[ "$INSTALLED_QMD" == "$QMD_VERSION" ]]; then
  ok "qmd $QMD_VERSION already installed"
else
  if [[ -n "$INSTALLED_QMD" ]]; then
    echo "  Replacing qmd $INSTALLED_QMD with $QMD_VERSION…"
  else
    echo "  Installing @tobilu/qmd@$QMD_VERSION globally…"
  fi
  npm install -g "@tobilu/qmd@$QMD_VERSION"
  ok "qmd $QMD_VERSION installed"
fi

# ── 3. Make scripts executable ───────────────────────────────────────────────

echo ""
echo "Setting permissions…"

find "$REPO_ROOT/.claude/hooks" -name '*.sh' -exec chmod +x {} \;
find "$REPO_ROOT/scripts" -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true
ok "scripts marked executable"

# ── 3b. Snapshot user's PATH into settings.json ────────────────────────────
# Claude Code's env block does literal assignment (no $PATH expansion).
# Headless story workers run non-interactive bash that never sources .zshrc,
# so they'd only see the system PATH. We snapshot the user's current PATH
# (which includes nvm, bun, pnpm, pyenv, ~/.local/bin, etc.) at install time.
# compose-settings-path.sh additionally prepends the native installer's
# managed toolchain dirs when they exist on disk but are missing from this
# session's PATH (a GUI-launched Claude never sources the profile block that
# wires them in) — without it, hooks in such sessions can't find qmd/hq.

echo ""
echo "Configuring PATH for subagents…"

SETTINGS_FILE="$REPO_ROOT/.claude/settings.json"
if [[ -f "$SETTINGS_FILE" ]]; then
  # Composer failure degrades to the plain snapshot — never abort setup here.
  CURRENT_PATH="$(bash "$REPO_ROOT/core/scripts/compose-settings-path.sh" || printf '%s' "$PATH")"
  UPDATED="$(jq --arg p "$CURRENT_PATH" '.env.PATH = $p' "$SETTINGS_FILE")"
  printf '%s\n' "$UPDATED" > "$SETTINGS_FILE"
  ok "PATH snapshot written to settings.json"
else
  skip "settings.json not found — PATH not configured"
fi

# ── 4. Create personal scaffold ─────────────────────────────────────────────

echo ""
echo "Setting up directory structure…"

mkdir -p personal/knowledge
mkdir -p personal/policies
mkdir -p personal/workers
mkdir -p personal/settings
mkdir -p personal/skills
mkdir -p personal/hooks
ok "personal/ scaffold created (knowledge, policies, workers, settings, skills, hooks)"

# ── 5. Indigo MCP Setup (opt-in via HQ_INDIGO_MCP=1) ───────────────────────

echo ""
if [[ "${HQ_INDIGO_MCP:-0}" != "1" ]]; then
  skip "Indigo MCP setup (re-run with HQ_INDIGO_MCP=1 to enable)"
elif check_cmd indigo; then
  ok "indigo CLI found"
  if ask "Would you like to set up Indigo MCP for AI-powered meeting intelligence?"; then
    echo "  Configuring Indigo MCP…"
    
    # Get the OAuth URL from indigo CLI
    MCP_JSON="$(indigo setup mcp --json 2>/dev/null)" || true
    
    if [[ -n "$MCP_JSON" ]]; then
      MCP_URL="$(echo "$MCP_JSON" | jq -r '.data.oauth.url // empty')"
      
      if [[ -n "$MCP_URL" ]]; then
        CLAUDE_CONFIG="$HOME/.claude.json"
        
        if [[ -f "$CLAUDE_CONFIG" ]]; then
          # Add indigo MCP server to existing config
          UPDATED="$(jq --arg url "$MCP_URL" '.mcpServers.indigo = {"url": $url}' "$CLAUDE_CONFIG")"
          echo "$UPDATED" > "$CLAUDE_CONFIG"
        else
          # Create new config with indigo MCP
          jq -n --arg url "$MCP_URL" '{"mcpServers": {"indigo": {"url": $url}}}' > "$CLAUDE_CONFIG"
        fi
        ok "Indigo MCP configured at $CLAUDE_CONFIG"
        echo "  URL: $MCP_URL"
        echo "  Restart Claude Code to activate."
        
        # Add indigo company to manifest if not present
        if [[ -f "companies/manifest.yaml" ]] && ! grep -q "^  indigo:" "companies/manifest.yaml" 2>/dev/null; then
          cat >> companies/manifest.yaml << 'MANIFEST'
  indigo:
    name: "Indigo"
    goal: "AI-powered meeting intelligence"
    path: "companies/indigo"
    sources: [indigo-mcp]
    created_at: ""
MANIFEST
          # Set the date
          sed -i '' "s/created_at: \"\"/created_at: \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"/" companies/manifest.yaml
          mkdir -p companies/indigo/knowledge companies/indigo/data companies/indigo/settings
          ok "companies/indigo/ scaffolded + added to manifest"
        fi
      else
        fail "Could not extract MCP URL from indigo CLI"
      fi
    else
      fail "indigo setup mcp --json returned empty"
    fi
  else
    skip "Indigo MCP setup"
  fi
else
  if ask "Indigo CLI not found. Install it now? (npm install -g indigo-cli)"; then
    echo "  Installing indigo-cli…"
    npm install -g indigo-cli
    if check_cmd indigo; then
      ok "indigo CLI installed"
      echo ""
      echo "  You need to authenticate first:"
      echo "    indigo auth login"
      echo ""
      echo "  After authenticating, re-run ./scripts/setup.sh to configure MCP."
    else
      fail "indigo CLI installation failed"
    fi
  else
    skip "Indigo CLI — install later via: npm install -g indigo-cli"
    echo "  Then run: indigo setup mcp"
  fi
fi

# ── 6. Build qmd index ──────────────────────────────────────────────────────

echo ""
echo "Building knowledge index…"

# Reindex all companies that have a core/knowledge/ directory with .md files
for dir in "$REPO_ROOT"/companies/*/knowledge; do
  [[ -d "$dir" ]] || continue
  # Only reindex if there are .md files
  if find "$dir" -name "*.md" -not -name "INDEX.md" | head -1 | grep -q .; then
    company="$(basename "$(dirname "$dir")")"
    echo "  Indexing $company…"
    # Per-company reindex covered by the global `qmd update` call below.
  fi
done

# Create HQ sub-collections (4 focused collections, NOT one monolithic hq)
if command -v qmd &>/dev/null; then
  qmd collection add "$REPO_ROOT/.claude" --name hq-infra --mask "**/*.{md,yaml,yml,json,sh}" 2>/dev/null || true
  qmd context add qmd://hq-infra "HQ infrastructure: commands, skills, policies, hooks, scripts." 2>/dev/null || true

  qmd collection add "$REPO_ROOT/workers" --name hq-workers --mask "**/*.{md,yaml,yml,json}" 2>/dev/null || true
  qmd context add qmd://hq-workers "AI worker definitions and skill files." 2>/dev/null || true

  qmd collection add "$REPO_ROOT/knowledge" --name hq-knowledge --mask "**/*.{md,yaml,yml}" 2>/dev/null || true
  qmd context add qmd://hq-knowledge "Shared knowledge bases: methodology, design, testing, security." 2>/dev/null || true

  qmd collection add "$REPO_ROOT/projects" --name hq-projects --mask "**/*.{md,json}" 2>/dev/null || true
  qmd context add qmd://hq-projects "Project PRDs and documentation." 2>/dev/null || true
fi

# Update qmd search index and (optionally) warm up the semantic-search model.
if command -v qmd &>/dev/null; then
  qmd update 2>/dev/null || true

  # Warm up the semantic-search model NOW, once, up front. qmd downloads its
  # GGUF models (~1.3GB) lazily on the FIRST semantic call — `qmd vsearch` /
  # `qmd query` / `qmd embed`. If we don't fetch them here, that download lands
  # MID-SESSION the first time /learn dedup or /search runs (the verified
  # new-user report: a ~1.28GB pull that blocked a live session). Fetching it at
  # setup keeps it out of the user's working sessions.
  #
  # Skippable on constrained machines: set HQ_SKIP_SEARCH_MODEL=1, or just let
  # the download fail — HQ never hard-fails setup over it. When the model is not
  # cached, HQ skills automatically stay in BM25 mode: every `qmd vsearch` /
  # `qmd query` is gated behind core/scripts/qmd-ready.sh, which downgrades to
  # `qmd search` (BM25, no model). Search still works — it just isn't semantic
  # until the model lands (re-run `qmd embed` any time to enable it).
  if [[ "${HQ_SKIP_SEARCH_MODEL:-}" == "1" ]]; then
    skip "search model download (HQ_SKIP_SEARCH_MODEL=1) — skills stay in BM25 mode"
  elif bash "$REPO_ROOT/core/scripts/qmd-ready.sh" >/dev/null 2>&1; then
    ok "search model already cached"
  else
    echo "  Downloading search model (~1.3GB, one time)…"
    echo "  (skip with HQ_SKIP_SEARCH_MODEL=1 on constrained machines — search stays BM25-only)"
    if qmd embed; then
      ok "search model ready — semantic search enabled"
    else
      fail "search model download failed — continuing without it (setup is NOT blocked)"
      echo "     HQ skills automatically use BM25 (qmd search) until you re-run: qmd embed"
    fi
  fi
  ok "qmd index built"
else
  skip "qmd not installed — knowledge index + search model skipped"
fi

# ── 7. Recommended content packs (hq-core v12+) ──────────────────────────────
# hq-core ships as a minimal scaffold; batteries-included UX comes from packs
# declared in `core/core.yaml:recommended_packages`. This phase reads that list,
# diffs against already-installed packs in `core/packages/*/package.yaml`, and
# prompts to install each missing pack via `hq install <source>`.
#
# Non-destructive: user can decline any pack. Failures are warnings — re-run
# `./scripts/setup.sh` or `/update-hq` to retry. Honored by `HQ_SKIP_PACKAGES=1`.

echo ""
echo "Recommended content packs…"

if [[ "${HQ_SKIP_PACKAGES:-}" == "1" ]]; then
  skip "recommended packs (HQ_SKIP_PACKAGES=1)"
elif [[ ! -f "$REPO_ROOT/core/core.yaml" ]]; then
  skip "recommended packs (no core/core.yaml)"
else
  # Collect already-installed pack sources by scanning each installed pack's
  # package.yaml in core/packages/ for its `source:` field. Used to dedup
  # against recommended_packages entries declared in core/core.yaml.
  INSTALLED_SOURCES=""
  if [[ -d "$REPO_ROOT/core/packages" ]]; then
    while IFS= read -r pkgfile; do
      [[ -f "$pkgfile" ]] || continue
      src=$(grep -E "^source\s*:" "$pkgfile" 2>/dev/null | head -1 | sed -E "s/^source\s*:\s*[\"']?([^\"'\r\n]+)[\"']?\s*$/\1/")
      [[ -n "$src" ]] && INSTALLED_SOURCES="$INSTALLED_SOURCES
$src"
    done < <(find "$REPO_ROOT/core/packages" -maxdepth 2 -name package.yaml 2>/dev/null)
  fi

  # Parse recommended_packages from core/core.yaml using awk (pair source with
  # optional conditional per entry). Emits TSV lines: source\tconditional.
  RECS="$(awk '
    BEGIN { in_block = 0; cur_source = ""; cur_cond = "" }
    /^recommended_packages\s*:\s*$/ { in_block = 1; next }
    in_block && /^[A-Za-z_][A-Za-z0-9_-]*\s*:/ { in_block = 0 }
    in_block && /^\s*-\s+source\s*:\s*/ {
      if (cur_source != "") { print cur_source "\t" cur_cond }
      sub(/^\s*-\s+source\s*:\s*/, "")
      gsub(/^["\x27]|["\x27]$/, "")
      cur_source = $0; cur_cond = ""; next
    }
    in_block && /^\s+conditional\s*:\s*/ {
      sub(/^\s+conditional\s*:\s*/, "")
      gsub(/^["\x27]|["\x27]$/, "")
      cur_cond = $0
    }
    END { if (cur_source != "") { print cur_source "\t" cur_cond } }
  ' "$REPO_ROOT/core/core.yaml")"

  if [[ -z "$RECS" ]]; then
    skip "no recommended_packages declared in core/core.yaml"
  else
    # Iterate: skip already-installed, evaluate conditional, prompt, install.
    # Use a here-string so `read` inside the loop still reads stdin for `ask`.
    while IFS=$'\t' read -r src cond; do
      [[ -z "$src" ]] && continue
      if echo "$INSTALLED_SOURCES" | grep -Fqx "$src"; then
        ok "$src (already installed)"
        continue
      fi
      if [[ -n "$cond" ]]; then
        if ! bash -c "$cond" &>/dev/null; then
          skip "$src (conditional not met: $cond)"
          continue
        fi
      fi
      if ask "Install recommended pack: $src ?"; then
        if npx --yes @indigoai-us/hq-cli install "$src" </dev/tty; then
          ok "$src installed"
        else
          fail "$src — install failed (retry: hq install \"$src\")"
        fi
      else
        skip "$src"
      fi
    done <<< "$RECS"
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════"
echo "  HQ setup complete."
echo ""
echo "  Next steps:"
echo "    1. Run 'claude' to start a session"
echo "    2. Run /setup for interactive personalization"
echo "    3. Run /learn after each session to grow your knowledge base"
echo "    4. Run 'hq install <source>' anytime to add content packs"
echo "════════════════════════════════════════"
