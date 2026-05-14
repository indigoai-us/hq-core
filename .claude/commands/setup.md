---
description: Interactive setup wizard for HQ Starter Kit
allowed-tools: Read, Write, Edit, AskUserQuestion, Glob, Bash
visibility: public
---

# HQ Setup Wizard

Quick setup to get your HQ running. Takes ~5 minutes.

## Phase 0a: Install Manifest Recovery

Before anything else, check if the HQ Installer left a manifest.

```bash
cat .hq/install-manifest.json 2>/dev/null
```

If no manifest exists, skip to Phase 0b — the user installed manually or is running setup for the first time.

If a manifest exists, this phase becomes the primary driver of setup. The manifest is a journal of everything the installer attempted — successes, failures, and skips. Your job is to triage and actively remediate each issue, not just list them.

### Triage priority (handle in this order)

**P0 — Blocking (fix these first, setup can't proceed without them):**
- `steps.directory` failed or missing → HQ directory doesn't exist; abort setup and tell user to re-run installer
- `steps.templates` failed → HQ template not fetched; attempt `npx --package=@indigoai-us/hq-cli hq init .`
- `dependencies.node` failed → nothing works; guide user through Node install
- `steps.git-init` failed → no git repo; run `git init && git add . && git commit -m "init"`

**P1 — Required (HQ works poorly without these):**
- `dependencies.qmd` failed → no semantic search; install with `cargo install qmd` or `brew install tobi/tap/qmd`, then `qmd index .`
- `dependencies.claude-code` failed → can't run workers; `npm install -g @anthropic-ai/claude-code`
- `dependencies.yq` failed → can't parse YAML configs; `brew install yq` or download binary
- `dependencies.hq-cli` failed → can't install packs or sync; `npm install -g @indigoai-us/hq-cli`
- `steps.indexing` failed → search won't work; run `qmd index .` directly
- `packs` with status `"failed"` or `"running"` (interrupted) → retry each: `npx --package=@indigoai-us/hq-cli hq install {pack-name}`

**P2 — Recommended (HQ works but some features limited):**
- `dependencies.gh` failed/skipped → no PR workflows; explain benefit and offer: `brew install gh && gh auth login`
- `dependencies.homebrew` skipped → limits future installs; explain benefit and offer install
- `steps.personalize` failed → profile not set up; Phase 1 below will cover this

### Remediation flow

For each issue found (in priority order):

1. **Explain what it is and why it matters** — one sentence, tied to what the user loses without it.
   - Example: "GitHub CLI wasn't installed during setup. This means you won't be able to create PRs or manage repos from HQ. Would you like me to install it now?"
   - Example: "The search index wasn't built during install. Without it, `/search` and knowledge lookups won't work. Let me set that up."
2. **For P0/P1 items: fix them directly.** Run the install command, verify it worked, move on. Only ask if there's a real choice (e.g. install method).
3. **For P2 items: offer with context.** Explain what the user gains, ask if they want it. Accept "skip" gracefully.
4. **After each fix: verify.** Run `which {tool}` or equivalent. If it failed, try an alternative approach. Don't move on until it's resolved or the user explicitly skips.

### After remediation

Once all issues are addressed, show a summary:

```
Install recovery complete.

Fixed:
  ✓ {item} — {what was done}
  ...

Skipped (optional):
  ○ {item} — {why it's optional}
  ...

Still needs attention:
  ✗ {item} — {what went wrong, what user can do}
  ...
```

Skip items already `"ok"` in the manifest — don't re-check things the installer already handled successfully. Then continue to Phase 0b only for dependencies the manifest doesn't cover (e.g. vercel).

## Phase 0b: Dependencies (non-manifest)

If Phase 0a ran, skip any deps already checked there. This phase only handles tools the manifest doesn't track.

**Vercel CLI** (not tracked by installer manifest):
```bash
which vercel
```
If missing: explain it's needed for site/preview deploys, offer to install (`npm install -g vercel`). Accept "skip" — it's optional.

If installed but not authenticated (`vercel whoami` exits non-zero): offer `vercel login`.

**Auth checks** (not tracked by manifest):
- `gh auth status` — if gh is installed but not authenticated, offer `gh auth login`
- `vercel whoami` — if vercel is installed but not authenticated, offer `vercel login`

Post-install: run `qmd index .` if qmd was just installed or no index exists.

## Phase 1: Identity

Ask these 3 questions. One at a time.

1. **What's your name?**
2. **What do you do?** (1-2 sentences — your roles, work, domain)
3. **What are your goals for using HQ?** (what do you want AI workers to help with?)

Personal scope lives at the top-level `personal/` directory (peer of `core/`), not as a company. Workers, knowledge, policies, and skills you create for yourself live under `personal/{type}/...` — `master-sync.sh` mirrors them into `core/<type>/<entry>` symlinks automatically.

## Phase 2: Generate Files

### Repos directory (required)

All repos — code, knowledge, company projects — live under `repos/`. This is the single canonical location for every cloned or created repository in HQ.

```bash
mkdir -p repos/public repos/private
```

### Personal scaffold
```bash
mkdir -p personal/{knowledge,policies,workers,settings,skills,hooks}
```

### Company structure (only when adding a real company — use `/newcompany {slug}` instead)
For reference, a company directory looks like:
```
companies/{slug}/{settings,data,knowledge,workers,policies}
```
The schema and a fillable template live at `companies/_template/`.

### Knowledge repos

Personal knowledge bases can be independent git repos symlinked into `personal/knowledge/`. Shared starter-kit knowledge ships under `core/knowledge/`.

For each knowledge base the user wants to create:

1. Create the repo directory:
```bash
mkdir -p repos/public/knowledge-{name}
cd repos/public/knowledge-{name}
git init
echo "# {Name} Knowledge Base" > README.md
git add . && git commit -m "init knowledge repo"
cd -
```

2. Symlink into HQ:
```bash
mkdir -p personal/knowledge
ln -s ../../repos/public/knowledge-{name} personal/knowledge/{name}
```

**Optional: turn `personal/knowledge/` into its own git repo so you can sync it across machines.**
```bash
# Personal knowledge repo
mkdir -p repos/private/knowledge-personal
cd repos/private/knowledge-personal
git init
echo "# Personal Knowledge Base" > README.md
git add . && git commit -m "init knowledge repo"
cd -

# Replace the empty personal/knowledge/ dir with a symlink to the canonical clone
rm -rf personal/knowledge
ln -s ../repos/private/knowledge-personal personal/knowledge
```
If you skip this, `personal/knowledge/` is just a plain directory tracked by HQ git — fine for single-machine setups.

**The starter kit's bundled knowledge (Ralph, workers, ai-security-framework, etc.) ships as plain directories. Explain to the user:**
```
Bundled knowledge (Ralph, workers, security framework) ships as plain directories.
To version them independently, you can convert any to a repo later:

  1. Move: mv core/knowledge/public/Ralph repos/public/knowledge-ralph
  2. Init: cd repos/public/knowledge-ralph && git init && git add . && git commit -m "init"
  3. Symlink: ln -s ../../../repos/public/knowledge-ralph core/knowledge/public/Ralph
  4. Add to .gitignore: core/knowledge/public/Ralph

This is optional — plain directories work fine for read-only knowledge.
```

### Profile files

**personal/knowledge/profile.md:**
```markdown
# {Name}'s Profile

## About
{Answer from Q2}

## Goals
{Answer from Q3}

## Preferences
- Communication style: [to be filled by /personal-interview]
- Autonomy level: [to be filled by /personal-interview]
```

**personal/knowledge/voice-style.md:**
```markdown
# {Name}'s Voice Style

Run `/personal-interview` to populate this file with your authentic voice and communication style.
```

**agents-profile.md** (root level — first line MUST match `# {Name} - Profile` for the inject-local-context.sh hook regex):
```markdown
# {Name} - Profile

- **Location**: {city}
- **Background**: {Answer from Q2}

## Goals
{Answer from Q3}

## Working Preferences

Run `/personal-interview` to populate the autonomy matrix and communication style.

## Company Roster

Full company/role context lives in `agents-companies.md` (three tiers: Operate / Client / Portfolio).
```

**personal/agents-companies.md** (created empty, populated by `/personal-interview` or manually):
```markdown
# {Name} — Company Contexts

> Three tiers: (1) Operate = founder/CEO hats. (2) Client = paid build work. (3) Portfolio = advisory/equity.
> Within Operate: active / slow-burn / on hold. `slug` = the key in `companies/manifest.yaml`.

## 1. Operate — Founder / CEO hats

_Run `/personal-interview` or edit manually to populate._

## 2. Client work (build, not owned)

## 3. Portfolio / Advisory
```

Add to `.gitignore` if not already present:
```
# Personal knowledge repo contents (tracked by their own git when symlinked)
personal/knowledge/
```

### Index
```bash
qmd update 2>/dev/null || qmd index . 2>/dev/null || true
```

## Phase 3: Summary

```
HQ Setup Complete!

Created:
- repos/public/, repos/private/ (ALL repos — code, knowledge, projects)
- personal/ scaffold (knowledge, policies, workers, settings, skills, hooks)
- personal/knowledge/profile.md
- personal/knowledge/voice-style.md
- agents-profile.md
- agents-companies.md
- Optional knowledge repo: repos/private/knowledge-personal/ → personal/knowledge (symlink)

Dependencies:
✓ claude (Claude Code CLI)
✓ qmd (semantic search) — or skipped
✓ gh (GitHub CLI) — or skipped
✓ vercel (Vercel CLI) — or skipped

Knowledge Repos:
Your personal knowledge bases can be independent git repos symlinked into personal/knowledge/.
This lets you version, share, and publish each knowledge base separately.
See "Knowledge Repos" in CLAUDE.md for details.

Next steps:
1. Run /personal-interview — deep interview to build your voice + profile
2. Run /newworker — create your first worker
3. Run /prd — plan your first project
4. Run /search <topic> — find relevant knowledge in HQ
```

## Rules

- Ask questions one at a time
- Use defaults when user says "skip"
- Never overwrite existing files without asking
- Create parent directories as needed
- For CLI tools (gh, vercel): inform but don't block setup if missing. These are "recommended" not "required" (except claude itself)
- Always use relative paths for symlinks (../../repos/... not absolute paths)
