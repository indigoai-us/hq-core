#!/usr/bin/env bash
# hq-core: public
# Cross-runtime scope contract for bounded single-action requests.
#
# Guards the "Codex over-orchestration" regression (runtime diagnostic,
# 2026-08-11): a bounded request ("open Izzy's latest project DM") expanded
# under Codex into full company orientation, duplicate policy ingestion, a
# background knowledge agent, and an unrequested handoff. The fixes live in
# shipped TEXT (skills, charter, policy routing), and both Claude and Codex
# consume the identical bytes (Codex via the .codex/claude symlink) — so these
# text contracts ARE the cross-runtime guarantee.
#
# Honest limitation, by design: this suite asserts the text/wire/script
# contracts each runtime consumes. It does not replay prompts through a live
# model. Behavioral coverage for the shell layer lives in hq-session.test.sh
# (bind-emission dedupe + budget) and checkpoint-stop-gate.test.sh (idle turns
# pass without demands, per runtime).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STARTWORK="$ROOT/.claude/skills/startwork/SKILL.md"
CHARTER="$ROOT/.claude/CLAUDE.md"
GATE_HOOK="$ROOT/.claude/hooks/checkpoint-stop-gate.sh"
NL_MODE="$ROOT/core/policies/natural-language-mode.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

has() {
  grep -qF -- "$2" "$1" || fail "$3"
}

lacks() {
  ! grep -qF -- "$2" "$1" || fail "$3"
}

[ -f "$STARTWORK" ] || fail "startwork SKILL.md missing at $STARTWORK"
[ -f "$CHARTER" ] || fail "charter missing at $CHARTER"

# ── 1. Bounded-action fast path exists and is imperative (F-01/F-06) ──────────
has "$STARTWORK" "1.0b Bounded-action short-circuit" \
  "startwork: §1.0b bounded-action short-circuit section is gone"
has "$STARTWORK" "Do NOT enter Company Mode" \
  "startwork: fast path lost its 'Do NOT enter Company Mode' directive"
grep -qE '\|.*DM.*\|.*`/dm`' "$STARTWORK" \
  || fail "startwork: bounded-action table lost its DM → /dm routing row"
has "$STARTWORK" "open Izzy's latest project DM" \
  "startwork: the documented negative example (Izzy DM) is gone"
has "$STARTWORK" "does NOT upgrade the request to Company Mode" \
  "startwork: slug-inside-bounded-action carveout is gone"
has "$STARTWORK" "Fall-through" \
  "startwork: fast path lost its fall-through clause (over-routing guard)"

# A company resolved by the normal startwork flow must be persisted before
# any mode-specific context gathering can run repo commands or project scans.
has "$STARTWORK" 'bash core/scripts/hq-session.sh set company_slug "{co}"' \
  "startwork: resolved company is not mechanically bound"
bind_line="$(grep -nF 'bash core/scripts/hq-session.sh set company_slug "{co}"' "$STARTWORK" | head -1 | cut -d: -f1)"
gather_line="$(grep -nF '### 2. Gather Context' "$STARTWORK" | head -1 | cut -d: -f1)"
[ -n "$bind_line" ] && [ -n "$gather_line" ] && [ "$bind_line" -lt "$gather_line" ] \
  || fail "startwork: company binding must precede all mode-specific context gathering"
echo "PASS: startwork binds resolved company before context gathering"

# ── 2. Startup spawns no maintenance agents (F-04) ────────────────────────────
lacks "$STARTWORK" "Spawn Knowledge Pulse" \
  "startwork: §2.7 knowledge-pulse spawn is back"
lacks "$STARTWORK" "spawn_task" \
  "startwork: a spawn_task call is back in the startup path"
lacks "$STARTWORK" "knowledge-pulse/SKILL.md" \
  "startwork: a knowledge-pulse reference is back in the startup path"
has "$STARTWORK" "interactive startup spawns zero agents" \
  "startwork: Rules block lost the zero-agents-at-startup rule"

# ── 3. No duplicate company-policy ingestion at startup (F-03) ────────────────
lacks "$STARTWORK" "read frontmatter-only for each policy in \`companies/{co}/policies/\`" \
  "startwork: §2.5 company-policy frontmatter re-scan is back (duplicates the bind emission)"
has "$STARTWORK" "Do NOT re-scan \`companies/{co}/policies/\`" \
  "startwork: §2.5 lost its explicit no-company-re-scan directive"
grep -qF -- '{repoPath}/.claude/policies/' "$STARTWORK" \
  || fail "startwork: §2.5 must keep the repo-policy check (not covered by the bind)"

# ── 4. Charter scopes /handoff to real work sessions (F-05) ───────────────────
has "$CHARTER" "needs no \`/handoff\`" \
  "charter: bounded read/lookup turns lost their /handoff exemption"
has "$CHARTER" "resumable working state" \
  "charter: the resumable-working-state trigger for /handoff is gone"
lacks "$CHARTER" "close every work session with \`/handoff\`" \
  "charter: the unconditional every-session /handoff mandate is back"

# ── 5. The only mechanical end-of-turn demand is a checkpoint, never /handoff ─
if [ -f "$GATE_HOOK" ]; then
  lacks "$GATE_HOOK" "/handoff" \
    "checkpoint-stop-gate: the stop gate must demand checkpoints, never /handoff"
fi

# ── 6. No dangling slash-routes in the natural-language routing policy (F-07) ─
if [ -f "$NL_MODE" ]; then
  lacks "$NL_MODE" "hqwork" \
    "natural-language-mode: a /hqwork route is back but no hqwork skill ships"
  # Generic guard: every backticked `/command` token the policy routes to must
  # exist as a shipped command or skill. Skipped: company-namespaced routes
  # (`/co:skill` — installed per company, not shipped in hq-core), the literal
  # generic placeholder "any `/command`", and host-provided builtins that the
  # agent harness ships rather than hq-core.
  host_builtins="security-review"
  dangling=""
  for cmd in $(grep -oE '`/[a-z][a-z0-9-]*:?' "$NL_MODE" | sed 's|^`/||' | sort -u); do
    case "$cmd" in
      *:) continue ;;        # namespaced company route (`/indigo:signals`)
      command) continue ;;   # generic placeholder ("any `/command`")
    esac
    case " $host_builtins " in
      *" $cmd "*) continue ;;
    esac
    if [ ! -f "$ROOT/.claude/commands/$cmd.md" ] \
      && [ ! -f "$ROOT/.claude/skills/$cmd/SKILL.md" ]; then
      dangling="$dangling $cmd"
    fi
  done
  [ -z "$dangling" ] \
    || fail "natural-language-mode routes to commands that do not ship:$dangling"
fi

# ── 7. Codex consumes the same bytes (the cross-runtime bridge itself) ────────
if [ -e "$ROOT/.codex/claude" ]; then
  target="$(readlink "$ROOT/.codex/claude" 2>/dev/null || true)"
  [ "$target" = "../.claude" ] \
    || fail ".codex/claude must symlink ../.claude so Codex reads identical skill bytes (got: ${target:-not a symlink})"
fi

echo "PASS: startwork bounded-action scope contract"

# ── 8. Company Mode story status comes from the Work Mesh Board ───────────────
company_mode="$(awk '
  /^#### Company Mode/ { in_company=1; print; next }
  /^#### Project Mode/ { in_company=0 }
  in_company { print }
' "$STARTWORK")"
company_has() {
  printf '%s\n' "$company_mode" | grep -qF -- "$1" \
    || fail "Company Mode: missing Board contract: $1"
}
company_lacks() {
  ! printf '%s\n' "$company_mode" | grep -qF -- "$1" \
    || fail "Company Mode: stale local-PRD status rule returned: $1"
}
company_has "Board status comes from the work mesh, never local prd.passes."
company_has "For each matching project, load the live Board from cache / Desktop live read"
company_has "If the Board block is absent, use local prd only for project description and acceptance; never as live Board columns."
company_has '`queued` = available next work'
company_has '`in_progress` / `review` = already claimed; do not offer as free next work'
company_has '`done` = done'
company_lacks "Count incomplete stories per project."
echo "PASS: Company Mode status follows the Work Mesh Board contract"
