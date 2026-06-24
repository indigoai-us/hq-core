---
name: setup
description: Run the HQ Starter Kit setup wizard.
allowed-tools: Read, Write, Edit, AskUserQuestion, Glob, Bash, Task, WebFetch, WebSearch, Skill, mcp__Claude_in_Chrome__*
---

# HQ Setup Wizard

Get your HQ running: dependencies, HQ Cloud (login + sync), a profile built from
who you are, and a private welcome page that hands you your first moves. One
question at a time; nothing here is mandatory — skip anything and setup still
completes.

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
- `dependencies.qmd` failed → no semantic search; install with `npm install -g @tobilu/qmd` (on macOS also run `brew install sqlite` — qmd loads SQLite extensions the built-in macOS SQLite can't), then `qmd index .`
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

Skip items already `"ok"` in the manifest — don't re-check things the installer already handled successfully. Then continue to Phase 0b only for auth state the manifest doesn't cover.

## Phase 0b: Auth checks (non-manifest)

If Phase 0a ran, skip any deps already checked there. This phase only handles auth state the manifest doesn't track.

**Auth checks** (not tracked by manifest):
- `gh auth status` — if gh is installed but not authenticated, offer `gh auth login`

Do **not** check for or install third-party deploy CLIs (e.g. the Vercel CLI) here.
HQ's own features never shell out to them — `/deploy` targets hq-deploy
infrastructure, not Vercel — so they are not HQ setup dependencies. They are
user-provided tools, installed on-demand by the user only when deploying their
own projects to their own pipeline; point-of-use guidance lives in the relevant
policy (e.g. `core/policies/hq-vercel.md`), not in setup.

Post-install: run `qmd index .` if qmd was just installed or no index exists.

## Phase 0c: HQ Cloud — login, claim invites, ensure sync

Connect this HQ to HQ Cloud so the user lands logged in, with any cloud-company
invites claimed and sync working. Do this **before** identity so synced company
context can inform the rest of the wizard, and so the welcome-page `/deploy`
(Phase 6) is already authenticated. One question at a time. Solo / offline HQ is
fine — never block setup on cloud.

### 1. Confirm Cognito login

```bash
hq auth status 2>/dev/null
```

- **Signed in, token valid** → continue. Show identity: `hq whoami`.
- **Token expired** → try a silent refresh first: `hq auth refresh`.
- **Not signed in, or refresh failed** → ask one question: "Sign in to HQ Cloud
  now? (unlocks team sync, shared knowledge, and publishing)". If yes, run the
  `/hq-login` skill (browser Cognito login). If they decline, note that cloud
  features (sync, `/deploy`, shared companies) are unavailable until they run
  `/hq-login`, and skip the rest of Phase 0c.

There is **no command that lists "companies I've been invited to."** Modern
invites are email-keyed and claimed automatically the first time sync runs (the
sync-runner "claim dance"). So do not promise an invite list — claim them via
sync in step 2.

### 2. Ensure sync + claim invites

Once signed in, run a full sync via the `/hq-sync` skill (engine:
`hq sync pull --all` / `hq-sync-runner --companies --direction both`). This fires
the claim dance — auto-accepting any email-keyed pending invites — and pulls
every cloud company the user belongs to.

- If the sync-runner emits `setup-needed` (pending invites but no person entity
  yet), the user likely has a **legacy magic-link** invite — point them to
  `/accept <link-or-token>` to redeem it, then re-run sync.
- If sync errors (network, no membership), report it plainly and continue — a
  solo HQ has nothing to pull.

### 3. Report what landed

After sync, read the now-present companies and state them plainly:

```bash
grep -E "^  [a-z0-9-]+:" companies/manifest.yaml 2>/dev/null | sed -E 's/^  ([a-z0-9-]+):.*/\1/'
```

- Cloud companies present → "You're connected and synced. You're in: {names}."
- None → "You're signed in. No cloud companies yet — you're solo for now, that's
  fine."

Keep Phase 0c to a few plain lines; the heavy lifting is the reused skills.

## Phase 1: Identity

Ask these 5 questions. One at a time. These answers are the strategic frame for
the whole wizard — they feed the knowledge files (Phase 2), the Dream Big vision
block (Phase 4.5), and every tailored command in the action interview (Phase 5).
So gather all five before moving on.

1. **What's your name?**
2. **What do you do?** (1-2 sentences — your roles, work, domain)
3. **What are your goals for using HQ?** (what do you want AI workers to help with?)
4. **What are your biggest challenges or pain points right now?** (what's hard,
   slow, repetitive, or keeps slipping)
5. **What are your main systems of record?** (where your truth lives — DB, CRM,
   Slack, email, analytics, repos, spreadsheets, etc.) For each, capture its
   **name + type**, and note which ones have a **credential** we could connect
   later (a connection string, API token, etc.). Don't ask for the secret itself
   — just whether one exists.

Personal scope lives at the top-level `personal/` directory (peer of `core/`), not as a company. Workers, knowledge, policies, and skills you create for yourself live under `personal/{type}/...` — `reindex.sh` mirrors them into `core/<type>/<entry>` symlinks automatically.

## Phase 1.5: Social presence + browser harness

Learn who the user is from their public presence — and initialize their browser
harness in the process, so they leave setup ready to have HQ drive the web for
them. One question at a time. Everything here is optional; never block setup.

### 1. Frame it

One short message: "Let's connect your browser so HQ can learn from your public
presence — and so you've got a browser harness ready for future work (research,
filling forms, pulling data from sites you're logged into)."

### 2. Detect / initialize the browser harness

Check whether a browser harness is connected:

- **Claude Code:** call `mcp__Claude_in_Chrome__list_connected_browsers`. If no
  browser is connected, point the user to install the **Claude for Chrome**
  extension (the recommended harness), then wait for them to connect and re-check.
- **Codex:** use the Codex browser tool equivalent if present.

The browser harness is what makes **login-walled** profiles (LinkedIn,
Instagram) readable — it drives the user's own authenticated session, so it sees
what they see.

**Fallback (no harness):** if the user declines or can't install the extension,
fall back to best-effort public fetching with `WebFetch` + `WebSearch`, and tell
them up front that login-walled sources (LinkedIn, Instagram) will be skipped.
Never block on the extension.

### 3. Ask for profiles — ONE AT A TIME

Ask for each, accepting "skip" for any (use AskUserQuestion, one per call):

1. X / Twitter
2. LinkedIn
3. Instagram
4. Personal website / blog
5. (optional) GitHub

### 4. Read each source

For every URL the user provided (these are the user's **own** profiles, so the
link-safety suspicion check is satisfied):

- **With harness:** `navigate` to the URL, then `get_page_text` / `read_page`.
- **Without harness:** `WebFetch` the public ones; `WebSearch` "{name} {handle}"
  to fill gaps for walled sources.

**Delegate the fetch + synthesis to a subagent** (Task / Agent tool) that returns
a **text summary only** — keep raw pages and any screenshots out of the parent
session (HQ context diet; parent stays under the image cap). Ask the subagent for:
who they are publicly, what they work on / care about, recurring themes, and
voice/tone cues — plus which sources it couldn't reach.

### 5. Persist the understanding (synthesized, never raw)

Write only synthesized understanding — never raw page dumps, never credentials,
never session URLs. Create the dir first if needed (`mkdir -p personal/knowledge`):

**personal/knowledge/social-presence.md:**
```markdown
# {Name} — Public Presence

_Synthesized during /setup from the profiles below. Refresh anytime._

## Who they are publicly
{1–2 paragraph synthesis}

## Themes & focus
- {recurring topic / area}

## Voice & tone cues
- {observed phrasing, register, what they sound like}

## Profiles
| Source | Link | Read? |
|---|---|---|
| X | {url} | {yes / walled / skipped} |
| LinkedIn | {url} | {yes / walled / skipped} |
| ... | | |
```

Hold this understanding in working memory — Phase 2 weaves it into `profile.md`,
`agents-profile.md`, and `voice-style.md`, and Phase 4.5 + Phase 6 draw on it.

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
{Answer from Q2 — enriched with the public-presence synthesis from Phase 1.5 if
available. Cross-reference: see personal/knowledge/social-presence.md.}

## Goals
{Answer from Q3}

## Challenges
{Answer from Q4 — the pain points HQ should help attack}

## Systems of Record
{Answer from Q5, as a table}

| System | Type | Has credential? |
|---|---|---|
| {name} | {DB / CRM / Slack / email / analytics / repo / ...} | {yes / no} |

## Preferences
- Communication style: [to be filled by /personal-interview]
- Autonomy level: [to be filled by /personal-interview]
```

**personal/knowledge/systems-of-record.md** (canonical list workers consult to
know where the user's truth lives — write full prose, one row per system from
Q5; `Connection` starts as `capture-only` and flips to `connected` in Phase 5b.5
when a secret-link is minted):
```markdown
# {Name}'s Systems of Record

Where the truth lives. Workers consult this before assuming or re-deriving data.

| System | Type | Has credential? | Connection |
|---|---|---|---|
| {name} | {type} | {yes / no} | {capture-only / connected / not yet} |

> To connect a system later: `/hq-secrets` (mints a link you fill in; the agent
> never sees the secret). Never paste a credential or a share/secret link into
> this file — those are capabilities, surfaced inline at mint time only.
```

**personal/knowledge/voice-style.md:**
```markdown
# {Name}'s Voice Style

## Observed cues
{Seed with the voice/tone cues synthesized in Phase 1.5, if any — e.g. register,
recurring phrasing, how they sound publicly. Leave a note if none were captured.}

Run `/personal-interview` to deepen this with your authentic voice and
communication style.
```

**agents-profile.md** (root level — first line MUST match `# {Name} - Profile` for the inject-local-context.sh hook regex):
```markdown
# {Name} - Profile

- **Location**: {city}
- **Background**: {Answer from Q2 — folded together with the Phase 1.5
  public-presence synthesis if available}

## Goals
{Answer from Q3}

## Challenges
{Answer from Q4 — surfaced every session via inject-local-context.sh so workers
know the standing pain points to attack}

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
- personal/knowledge/systems-of-record.md
- personal/knowledge/social-presence.md (if profiles captured in Phase 1.5)
- personal/knowledge/voice-style.md
- agents-profile.md
- agents-companies.md
- Optional knowledge repo: repos/private/knowledge-personal/ → personal/knowledge (symlink)

HQ Cloud:
✓ Signed in {as email} — or "not connected (run /hq-login later)"
✓ Synced — {N companies} or "solo, nothing to pull yet"

Dependencies:
✓ claude (Claude Code CLI)
✓ qmd (semantic search) — or skipped
✓ gh (GitHub CLI) — or skipped

Knowledge Repos:
Your personal knowledge bases can be independent git repos symlinked into personal/knowledge/.
This lets you version, share, and publish each knowledge base separately.
See "Knowledge Repos" in CLAUDE.md for details.

Setup is done. Next: a short orientation + a few questions so I can hand you
the exact commands to start your first real work.
```

Do not print a static next-steps list here. Continue to Phase 4.

## Phase 4: Learn the HQ Mental Model

A brief orientation before the interview. Keep it to roughly a screenful — this
is a mental model, not a course. Pull the framing from
`core/docs/hq/USER-GUIDE.md` rather than reinventing it; do not duplicate the
hands-on lessons that already live in `/tutorial`.

Present this (adapt wording, keep it tight):

```
How HQ works — the 60-second model:

  • Sessions are disposable; context is precious. Start with /startwork,
    do one focused thing, end with /handoff. A fresh session is a feature,
    not a reset.
  • Three homes for things: personal/ (your overlay — workers, knowledge,
    policies just for you), companies/ (isolated tenants you operate or
    serve), repos/ (all actual code, public or private).
  • Knowledge compounds. Workers, knowledge docs, and policies you create
    make every future session smarter — capture learnings, don't re-derive.
  • Slash commands are the interface. /newworker, /plan, /deploy, /search,
    /onboard — you drive HQ by naming the capability, not hand-rolling it.
  • /search (or qmd) finds anything across HQ — knowledge, projects,
    workers, policies, indexed repos.

Go deeper anytime:
  • /tutorial          — hands-on, interactive lessons against your real HQ
  • /personal-interview — deep dive on your voice + working style so workers
                          sound and decide like you
```

Then continue to Phase 4.5 (don't wait for acknowledgement — flow straight in).

## Phase 4.5: Dream Big

Before the action interview, paint the destination. Ground this entirely in the
user's own answers (Q2 what-you-do, Q3 goals, Q4 challenges, Q5 systems of
record) plus the Phase 1.5 public-presence synthesis — generic HQ marketing is
worse than nothing. Produce **2-3 concrete, tailored scenarios**, each in the
shape: *their pain point → the HQ capability that attacks it → the outcome they'd
feel*. Name the real command in each.

**Templates to adapt — substitute every `<…>` slot with the user's literal Q1-Q5
words before emitting. Never print the angle-bracket form to the user.** The `<…>`
slots are author-time placeholders, not output. If a slot has no matching answer,
drop the bullet rather than emit a generic stand-in.

Scenario shapes to choose from (pick 2-3 that actually fit the user's answers):

- *Worker for a recurring pain:* "You said **<their literal Q4 pain point>** eats
  your time. Build a `/newworker` specialist that does exactly that — and it gets
  smarter every run, so the work compounds instead of repeating."
- *Connect a system, ship a live report:* "Your truth lives in **<their literal
  Q5 system, e.g. 'Postgres in Supabase' or 'HubSpot CRM'>**. Connect it once
  with `hq secrets generate-link`, then `/deploy` a live report behind a signed
  URL your team can open — no copy-paste, no stale screenshots."
- *Compounding knowledge:* "**<their recurring task from Q2/Q3>** becomes a
  knowledge base that compounds: every session adds to it via `/learn`, so you
  never re-derive the same answer twice."

**Worked example — this is the shape of what to actually emit to the user.**
Assume Q4 = "I lose hours re-summarizing the same investor updates each week"
and Q5 = "HubSpot CRM (has credential)":

> You said **losing hours re-summarizing investor updates each week** eats your
> time. Build a `/newworker` specialist that drafts each week's update from your
> CRM activity — it learns your phrasing every run, so by month three you're
> editing, not writing.
>
> Your truth lives in **HubSpot**. Connect it once with `hq secrets generate-link`,
> then `/deploy` a live investor-update preview behind a signed URL your LPs can
> open — no copy-paste, no stale screenshots.

Keep it to ~half a screen, aspirational but grounded — not salesy. Close with one
line, e.g.: "That's the destination. Let's take the first concrete steps now."
Then flow straight into Phase 5.

## Phase 5: What Do You Need Help With?

A branching interview that both **does** lightweight scaffolding inline and
**collects** a recommended-command list for future fresh sessions. It ends in a
two-section launch block (done now / run next). Ask one question at a time
(decision-queue-one-at-a-time). Reuse Phase 1 answers (name, what they do, goals,
challenges, systems of record) — never re-ask what's captured.

### 5a. Role discovery (FIRST — before any scope question)

Go one level deeper than Phase 1's high-level "what do you do". Conversational,
free-text (a picker would flatten the nuance). Phase 1 Q4 already captured pain
points — don't re-ask. Focus here on the day-to-day texture that shapes which
commands to suggest:

1. **What's your specific role?** (title + the hat you actually wear day-to-day)
2. **Walk me through a typical day — what do you actually spend time on?**

These answers, plus the Q4 challenges and Q5 systems of record, anchor every
command suggestion below — keep them in working memory for the synthesis step.

### 5b. Primary scope (AskUserQuestion)

One AskUserQuestion call, four options:

- `Run my own companies / clients`
- `Personal projects & automation`
- `Learn / explore HQ first`
- `Bring in an existing codebase`

### 5b.5. Connect a system of record (inline, optional)

For each Q5 system the user said has a credential, offer to wire it up **now** so
they leave setup with a real connection, not just a note. This is the one
write-side connection primitive HQ has (`hq sources` is read-only):

```bash
hq secrets generate-link <SECRET_PATH> [--personal | --company {slug}]
```

- Pick a sensible `SECRET_PATH` per system (e.g. `DATABASE_URL`, `SLACK_TOKEN`,
  `STRIPE_API_KEY`). Use `--personal` for personal scope, or `--company {slug}`
  matching the scope chosen in 5b.
- The command mints a one-time URL the user opens to enter the secret — the agent
  never sees it. **Surface that URL inline at mint time only.** It is a
  capability: never write it into `systems-of-record.md`,
  `getting-started-next-steps.md`, or any later turn (per
  `hq-share-session-urls-are-capabilities`).
- After each one is wired, flip that system's `Connection` cell in
  `personal/knowledge/systems-of-record.md` from `capture-only` to `connected`.
- Accept "skip" for any system → it stays `capture-only`; add `/hq-secrets` to
  the recommended-commands list so they can connect it later.

### 5c. Team / cloud detection (shapes the strongest recommendation)

Silently check whether this is a team / cloud-backed context:

```bash
grep -l 'cloud' companies/*/manifest.yaml 2>/dev/null | head -1
grep -iE 'cloud_backed|hq[-_]?pro|team' companies/manifest.yaml 2>/dev/null | head -3
```

Also treat it as team/cloud if `companies/manifest.yaml` has at least one real
company entry (top-level keys under `companies:`), or the user's role-discovery
answers describe working with a team. Notes:

- The top-level `personal/` overlay does not count — it's not a company.
- `companies/_template/` does not count either — it's the scaffold copied by
  `/newcompany`, and is never listed in `manifest.yaml`. A fresh HQ install
  with only `_template/` on disk is **solo**, not team/cloud.

**If team/cloud** — make the headline recommendation a *shareable asset* task:

- Build a reusable asset grounded in the role-discovery pain point, then share
  it with the team: `/newworker` (a specialist for the draining task), or a
  knowledge doc + `/learn`, then `/hq-share <path>` (or `/designate-team` to
  make the company cloud-backed for the whole team).
- And/or **produce a report and deploy it**: `/plan` (or a direct artifact) →
  `/deploy` — framed as "show your team something real, behind a signed URL".

**Deploy is not team-gated.** Even for solo / personal scope, surface a
"create something small and `/deploy` it" task as a high-value early win
(a report, a one-pager site, a shareable result).

### 5d. Branch follow-ups — split do-now vs recommend (AskUserQuestion, one at a time)

Mirror how `/tutorial` Step 1 and `/startwork` gate picks. For each branch, sort
actions into **(a) do-now inline** (lightweight, high-momentum — run this
session) and **(b) recommend for a fresh session** (heavy / context-hungry — add
to the launch list, do NOT run inline). See the Rules for the inline/handoff line.

- **Companies / clients** → "Is the company already in HQ?"
  - *Do now:* `/newcompany {slug}` (new — lightweight scaffold) or `/onboard`
    (join existing). If they're an existing Claude user, surface `/import-claude`
    to hydrate the skeleton.
  - *Recommend:* first deliverable → `/brainstorm` / `/plan` / `/startwork {slug}`.
    If team/cloud, fold in the shareable-asset + `/deploy` recommendation.
- **Personal projects** → "What's the first thing you want a worker to do?"
  (anchored to role-discovery + Q4 challenges).
  - *Do now:* `/idea` to capture it on the board; `/newworker` if a recurring
    specialist is clearly implied.
  - *Recommend:* `/plan` for the first real deliverable, plus the solo
    `/deploy` early-win.
- **Learn first** → *Do now:* nothing heavy. *Recommend:* `/tutorial` (suggest a
  topic from role-discovery + Phase 1 goal) then `/personal-interview`.
- **Existing codebase** → *Do now:* note the clone target (`repos/public/` or
  `repos/private/`). *Recommend:* `/discover <repo>` in a fresh session (it's
  context-hungry — never run inline during setup).

### 5e. Synthesize + emit the two-section launch block

Produce two ordered lists, each command **fully substituted** (real slugs/paths
— never `{placeholder}` tokens), each with a one-line "why" tied to their
answers. Print inline:

```
You're set up. Here's where you landed.

Done this session:
  ✓ {what was actually scaffolded / connected — company, idea, secret-link, knowledge doc}
  ...

Run these next — start a FRESH session for each (context hygiene, see Phase 4):
  1. {command}        — {why, tied to their challenge / goal / system of record}
  2. {command}        — {why}
  ...

Saved to personal/knowledge/getting-started-next-steps.md — reopen anytime.
```

### 5f. Persist the artifact

Write `personal/knowledge/getting-started-next-steps.md` (the dir is created in
Phase 2, so the path always exists). Full prose — this is a disk artifact, not
chat. Contents:

- Generated date
- The user's role + stated goal + top challenges (from Phase 1 + 5a)
- **Done this session** — what was actually scaffolded/connected (company, idea,
  knowledge docs, which systems of record got connected)
- **Run these next** — the same recommended command list shown inline, each with
  its rationale, one fresh session per command
- A "Your systems of record" recap (mirror the table, with connection status) so
  they remember what's wired vs still to connect
- An "If you get lost" footer: `/startwork`, `/tutorial`, `/search <topic>`

**Never** write any secret-link / share URL into this file — those are
capabilities, surfaced inline at mint time only.

If the file already exists, show the user what would change and confirm via
AskUserQuestion before overwriting (per the Rules below — never overwrite
silently).

## Phase 6: Deploy the welcome page + hand off

The visual capstone. Turn everything learned into a small, **private**,
personalized welcome page and publish it, then send the user off to a fresh
session. Requires the Cognito login from Phase 0c; if the user never signed in,
skip the deploy and just deliver the launch block + handoff message in chat.

### 1. Build the page (one `index.html`)

Generate a single `index.html` — **never** multiple `.html` files: the static
host SPA-fallbacks every `.html` subpath to `index.html` silently, so use one
file with a `#/route` hash router if it needs sections.

- **Design:** if the `impeccable` skill is available, use it to craft the page
  (the owner's lives at `personal/skills/impeccable/`). If it's absent in this
  HQ, produce a high-quality inline design instead — degrade gracefully, never
  hard-depend on impeccable.
- **Content** — four sections, all drawn from earlier phases:
  1. **Who you are** — the synthesis from Phase 1 (identity) + Phase 1.5
     (public presence).
  2. **How your HQ is set up** — cloud companies synced (Phase 0c), the personal
     scaffold, systems of record and which are connected.
  3. **Starter moves** — the Phase 5 recommended commands as **copy-paste prompt
     blocks**, each fully substituted (real slugs/paths — never `{placeholder}`),
     each with a one-line "why".
  4. **Hand off** — close this session, start a fresh one, paste the first prompt.
- Stage it in a scratch dir (e.g. `workspace/setup-welcome/index.html`).

### 2. Deploy private

Run the `/deploy` skill on the staged dir with **private (owner-only)** access
mode. The page holds personal understanding, and `sensitivity-check.sh` greps
filenames only — it returns `sensitive:false` for a lone `index.html` even when
the content is personal — so set the access mode to private manually; do not rely
on the auto-verdict.

### 3. Surface the link + hand off

Print the deploy URL **inline, in one plain line** (this is the `/deploy`
capability carveout — surfaced at publish time, never re-pasted into knowledge
files or later turns). Then deliver the handoff message:

```
You're all set — here's your welcome page (private to you): {url}

Open it, then close this session and start a fresh one. Your first move:

  {first copy-paste prompt, fully substituted}

(A fresh session per task keeps context clean — see your welcome page for the
full list.)
```

If the user wants, point them at `/handoff` to preserve richer state — but for a
brand-new setup, simply starting fresh with the first prompt is enough.

## Rules

- Ask questions one at a time — every phase, including the Phase 0c login prompt
  and each Phase 1.5 social URL. Never batch.
- **Never block setup on HQ Cloud.** Login, invite-claim, and sync (Phase 0c) are
  best-effort; a solo or offline HQ completes setup fine. There is no
  list-pending-invites command — invites are claimed by running sync.
- **Browser harness is optional.** Prefer the Claude for Chrome harness (Codex
  equivalent in Codex) so login-walled profiles are readable; if the user
  declines, fall back to public `WebFetch` + `WebSearch` and skip walled sources.
  Never block on the extension.
- **Delegate browser reads + scrape synthesis to a subagent** that returns text
  only — keep raw pages and screenshots out of the parent session (HQ context
  diet; stay under the image cap). Persist only synthesized understanding, never
  raw dumps or credentials.
- **The welcome page is private** and contains personal understanding — set
  `/deploy` access mode to owner-only manually; don't trust the filename-only
  sensitivity verdict.
- **`impeccable` is optional** — use it for the welcome page if present, else
  produce a high-quality inline design. Degrade gracefully.
- **Inline vs handoff:** scaffold lightweight, high-momentum items inline during
  setup (`/newcompany`, `/idea`, a knowledge doc, a `hq secrets generate-link`
  connection). Heavy / context-hungry work (`/plan`, `/discover`, deep
  planning) is recommended for a fresh session — never run inline. This honors
  HQ context hygiene while still delivering first-session momentum.
- **Secret-link / share / deploy URLs are capabilities** — surface inline at mint
  or publish time only. Never write them into `getting-started-next-steps.md`,
  `systems-of-record.md`, `social-presence.md`, or any later turn
  (`hq-share-session-urls-are-capabilities`).
- Use defaults when user says "skip"
- Never overwrite existing files without asking
- Create parent directories as needed
- For CLI tools (gh, vercel): inform but don't block setup if missing. These are "recommended" not "required" (except claude itself)
- Always use relative paths for symlinks (../../repos/... not absolute paths)
- Phase 4/5 are skippable — if the user says "skip", still write `personal/knowledge/getting-started-next-steps.md` using best-effort defaults from Phase 1 answers. Never block setup completion on the orientation or interview
- Phase 6 (welcome page) is skippable — if the user isn't signed in or declines,
  skip the `/deploy` and just deliver the launch block + handoff message in chat.
  Never block setup completion on the deploy
