---
name: tutorial
description: Interactive tutorial — hands-on lessons on HQ principles, daily workflow, and scaling
allowed-tools: Read, Glob, Grep, Bash, AskUserQuestion
---

# Tutorial — Learn HQ by Doing

Interactive, modular lessons teaching HQ principles through hands-on exercises against the user's real HQ. Each topic follows a 5-phase flow: Concept, Show, Exercise, Verify, Takeaway. Content sources include *Build Your Own AGI* (where available) and the `knowledge/public/getting-started/` docs — the book is a supporting reference, not a prerequisite.

**Ordering rationale:** Lead with *principles* and *daily workflow* — most users won't run `/run-project` orchestration until they've lived in HQ. Ralph-loop orchestration (Topic 8) and worker authoring (Topic 9) come last, where users have enough context to appreciate them.

**Input:** `$ARGUMENTS` — optional topic slug. If empty, show topic menu.

## Step 0: Parse Input

If `$ARGUMENTS` is non-empty, match against topic slugs:

| Input | Topic |
|-------|-------|
| `principles`, `ralph-principles`, `mindset` | 1. Ralph Principles |
| `hq`, `workflow`, `daily`, `folder`, `folders` | 2. Working with HQ |
| `knowledge` | 3. Knowledge Architecture |
| `session-hygiene`, `hygiene`, `sessions` | 4. Session Hygiene |
| `context-management`, `context`, `tokens` | 5. Context Management |
| `projects`, `prd`, `prds` | 6. Projects |
| `scaling`, `parallel`, `multi-session` | 7. Scaling |
| `ralph-loop`, `ralph`, `loop`, `run-project` | 8. The Ralph Loop (Orchestration) |
| `workers`, `worker` | 9. Workers |

If matched: skip to Step 2 with that topic.
If no match: show error + topic menu (Step 1).
If empty: proceed to Step 1.

## Step 1: Topic Menu

### Maturity Detection

Silently assess HQ state:

1. Check `workers/registry.yaml` — count company-specific workers (type: `company`)
2. Check for any `prd.json` files in `companies/*/projects/` or `projects/`
3. Count companies in `companies/manifest.yaml`

Classify:
- **FRESH**: 0 custom workers AND 0 projects
- **ACTIVE**: has workers OR projects
- **ADVANCED**: 3+ companies with workers/projects

### Present Menu

```
HQ Tutorial
───────────
Learn HQ principles from "Build Your Own AGI" — interactive lessons
with hands-on exercises using your actual HQ.

  Foundations
  1. Ralph Principles      — Plan mode, fresh context, back pressure (mindset)
  2. Working with HQ       — Daily workflow: /startwork → work → /handoff

  Daily Practice
  3. Knowledge             — Hot vs cold channels, qmd search, gardens
  4. Session Hygiene       — /checkpoint, /handoff, thread files
  5. Context Management    — Token optimization, Context Diet, advisories
  6. Projects              — PRDs, /idea → /plan, acceptance criteria
  7. Scaling               — Parallel sessions, company isolation

  Advanced
  8. The Ralph Loop        — /run-project orchestration (principles in action)
  9. Workers               — /newworker, worker.yaml, /learn training

  Recommended for you: {see below}

  Full book: {your-book-site}
```

**Recommendation logic:**
- FRESH → "1. Ralph Principles — start with the mindset before the mechanics"
- ACTIVE → "4. Session Hygiene — the #1 thing that separates productive users from frustrated ones"
- ADVANCED → "8. The Ralph Loop — you're ready for orchestrated execution via /run-project"

Wait for user selection via AskUserQuestion. Route to Step 2 with chosen topic.

## Step 2: Run Lesson

Execute the 5-phase lesson flow for the selected topic. Each phase is described below.

### Phase 1: Concept (synthesize, don't paste)

1. **Attempt to read book chapter.** Check if the book exists at `repos/private/knowledge-empire-os/book/build-your-own-agi.md`. If yes, read ONLY the line range for this topic's chapter (see Topic Registry below). If the file does not exist, use fallback sources.
2. **Read the HQ reference file(s)** listed in the topic's `hq_refs` field.
3. **Synthesize a 200-300 word explanation** of the core concept in your own words. Do NOT paste paragraphs from the book.
4. **Surface the key quote** defined for this topic — attribute it to the book.
5. **Link to the book:** "Full chapter: Ch {N} in *Build Your Own AGI* — [{your-book-site}](https://{your-book-site})"

### Phase 2: Show (inspect user's HQ)

Run the read-only inspection commands defined in the topic's `show` field. Annotate what you find with how it connects to the concept just explained.

Two paths:
- **Has content:** Inspect real data (workers, projects, threads, settings) and annotate.
- **No content:** Explain what it would look like when populated. Use shared/bundled HQ content as examples.

### Phase 3: Exercise (hands-on)

Present the exercise defined in the topic's `exercise` field.

**Exercise tiers:**
- **Tier 1 (AI executes, read-only):** qmd searches, file reads, git log, ls, wc. Safe to run directly.
- **Tier 2 (User executes, AI verifies):** Commands like `/run`, `/checkpoint`. Describe what to do, wait for the user to try, then verify.
- **Tier 3 (Suggested for later, NOT executed):** `/newworker`, `/plan`, `/run-project`, `/handoff`. Mention as next steps only.

### Phase 4: Verify

For Tier 1 exercises: present what the exercise revealed and ask the user a comprehension question.
For Tier 2 exercises: check for expected side effects (new files, updated state) or ask "What did you see?"

### Phase 5: Takeaway

1. State the **one principle** from this topic (defined in `takeaway` field).
2. Reference existing docs: "Quick reference: `knowledge/public/getting-started/cheatsheet.md`"
3. Suggest next topic: "Next: try `/tutorial {next_topic}` or pick another from `/tutorial`"
4. Book link: "Deeper dive: Ch {N} in *Build Your Own AGI* — [{your-book-site}](https://{your-book-site})"

---

## Topic Registry

### Topic 1: principles — Ralph Principles (NEW)

- **Chapter:** 3 — "The Loop That Changed Everything" *(mindset/philosophy portions only — not orchestrator mechanics)*
- **Book lines:** 243-336
- **Fallback:** `knowledge/public/getting-started/quick-start-guide.md` (Core Loop section), `knowledge/public/getting-started/learning-path.md` (Module 1-2)
- **HQ refs:** `knowledge/public/getting-started/quick-start-guide.md`
- **Key quote:** "AI in ask mode is not AGI. AI in plan mode can be."
- **Focus discipline:** This topic teaches the *mindset* — plan mode, fresh context, back pressure — NOT `/run-project` mechanics. Do not reference `/run-project`, sub-agents, or file locking here. Those live in Topic 8 (`ralph-loop`). If the user asks about orchestration, say: "That's Topic 8 — come back after you internalize the three principles."
- **Show:**
  - Read a recent thread file from `workspace/threads/` (most recent `.json`). Annotate where the three principles show up: where did the session start with plan mode? Where was context refreshed? Where was a task verified before advancing?
  - If no threads exist, read `.claude/settings.json` and point to the `planModeByDefault` or thinking-mode settings as the "plan mode" principle made concrete
- **Exercise (Tier 1):**
  1. Read one past thread file from `workspace/threads/` (or the bundled sample if fresh)
  2. Ask the user: "Ralph has three principles. Looking at this session, can you name them and point to one moment in the thread that embodies each?" (Answer: plan mode, fresh context per task, back pressure/verification)
- **Verify:** User identifies the three principles AND can point to at least two of them in the thread. If they miss one, explain it with a concrete example.
- **Takeaway:** "Plan before act. Fresh context per task. Verify before advancing. The *principles* are the operating system — everything else (workers, projects, `/run-project`) is just how HQ makes them repeatable."
- **Next topic:** hq

### Topic 2: hq — Working with HQ (NEW)

- **Chapter:** 4 — "Building Your HQ — The Operating System Nobody Gave You"
- **Book lines:** 337-448
- **Fallback:** `knowledge/public/getting-started/quick-start-guide.md` (Daily Workflow section), `knowledge/public/getting-started/cheatsheet.md`
- **HQ refs:** `knowledge/public/getting-started/quick-start-guide.md`, `knowledge/public/getting-started/cheatsheet.md`
- **Key quote:** "HQ is a filesystem with opinions." *(If no exact match in Ch 4, synthesize an equivalent from the chapter's opening framing and attribute as paraphrase.)*
- **Focus discipline:** Daily workflow arc (`/startwork` → work → `/handoff`) + folder orientation. Do NOT teach `/run-project` here (Topic 8) or worker authoring (Topic 9). The goal: a user should know where to look and which command to run next on day one.
- **Show:**
  - List top-level HQ dirs: `ls -1 $HOME/Documents/HQ/` (filter hidden). For each of `.claude/`, `companies/`, `knowledge/`, `workers/`, `workspace/`, `repos/` — explain in one line what it holds
  - Read `knowledge/public/getting-started/cheatsheet.md` — show the daily cadence table/section
  - Show the typical command sequence from the book: `/startwork` → (work happens) → `/checkpoint` (mid-session) → `/handoff` (end)
- **Exercise (Tier 1):**
  1. From `companies/manifest.yaml`, pick a company the user works in. Locate one file in each of: `companies/{co}/settings/`, `companies/{co}/knowledge/`, `companies/{co}/workers/`. Show the user what each holds
  2. Ask: "If you opened HQ tomorrow morning and wanted to resume yesterday's work, what's the first command you'd run and what file would it read?" (Answer: `/startwork` reads `workspace/threads/handoff.json`)
- **Verify:** User can name `/startwork` and locate `handoff.json`. If they don't know the handoff file, read the 7-line handoff.json to them as a demo of how little state resumes a session.
- **Takeaway:** "HQ is a filesystem with opinions. Every dir has a job. The daily arc is `/startwork` → work → `/handoff`. Learn the arc before learning the advanced commands."
- **Next topic:** knowledge

### Topic 3: knowledge

- **Chapter:** 6 — "The Knowledge Problem"
- **Book lines:** 545-636
- **Fallback:** `knowledge/public/getting-started/quick-start-guide.md` (Knowledge section), `knowledge/public/getting-started/learning-path.md` (Module 5)
- **HQ refs:** `knowledge/public/getting-started/quick-start-guide.md`
- **Key quote:** "HQ without knowledge is a library with empty shelves."
- **Show:**
  - List `knowledge/public/` directories — show what knowledge bases exist
  - Count total knowledge files: `ls knowledge/public/` and any `companies/*/knowledge/`
  - Show the three knowledge repo patterns (inline, embedded git, symlink) with examples from the user's HQ
- **Exercise (Tier 1):**
  1. Pick a keyword relevant to the user's work (ask them for one via AskUserQuestion)
  2. Run `qmd search "{keyword}" --json -n 5` (BM25 keyword search)
  3. Run `qmd vsearch "{keyword}" --json -n 5` (semantic/vector search)
  4. Compare results — explain: keyword search finds exact terms; semantic search finds related concepts
- **Verify:** User sees different results between search types and can articulate when to use which.
- **Takeaway:** "Cold channels store, hot channels decide. Your knowledge base is the one asset nobody can replicate."
- **Next topic:** session-hygiene

### Topic 4: session-hygiene

- **Chapter:** 8 — "Session Hygiene — Why Your AI Gets Dumber Over Time"
- **Book lines:** 739-828
- **Fallback:** `knowledge/public/getting-started/cheatsheet.md`, `knowledge/public/getting-started/learning-path.md` (Module 8)
- **HQ refs:** `knowledge/public/getting-started/cheatsheet.md`
- **Key quote:** "Close early, close often. /handoff is your end-of-day save button."
- **Show:**
  - Check `workspace/threads/handoff.json` — if exists, read and explain its structure (what gets preserved between sessions)
  - List recent thread files in `workspace/threads/` — show the checkpoint/handoff history
  - Show the auto-checkpoint configuration in CLAUDE.md (the PostToolUse hook table)
- **Exercise (Tier 2):**
  1. Tell the user: "Run `/checkpoint` right now to see session saving in action."
  2. Wait for user to run it
  3. After they confirm, read the most recent thread file in `workspace/threads/` and walk through what it captured
- **Verify:** A new thread file exists in `workspace/threads/` with a recent timestamp, or ask the user what they observed.
- **Takeaway:** "Fresh sessions beat long sessions. /handoff is 30 seconds. The next session starts smarter because of it."
- **Next topic:** context-management

### Topic 5: context-management

- **Chapter:** 4 + 8 — "Building Your HQ" + "Session Hygiene"
- **Book lines:** 337-448 (Ch 4), 739-828 (Ch 8) — read Ch 4 only, reference Ch 8 from session-hygiene
- **Fallback:** `knowledge/public/getting-started/learning-path.md` (Module 8)
- **HQ refs:** `.claude/CLAUDE.md` (Context Diet and Token Optimization sections only — do NOT read the full file)
- **Key quote:** "Your AI goes from genius to mass-hallucinator the further into the context window you get."
- **Show:**
  - Read the Context Diet section of CLAUDE.md (the bullet list of rules)
  - Show the Token Optimization table (env vars and their purpose)
  - Show the two-stage context advisory system (60% warning + 75% pre-compact)
- **Exercise (Tier 1):**
  1. Read the Context Diet rules in CLAUDE.md — count the "do NOT" rules
  2. Run `wc -l .claude/CLAUDE.md` — show the instruction file size as an example of keeping context tight
  3. Examine: "Every file you Read costs tokens. What does the Context Diet section tell you NOT to read at session start?" (Answer: INDEX.md, agents files, company knowledge — unless the task requires it)
- **Verify:** User can name 2-3 context diet rules from memory.
- **Takeaway:** "Context is a finite resource. The discipline is knowing what NOT to load. Load what the task needs, nothing more."
- **Next topic:** projects

### Topic 6: projects

- **Chapter:** 7 — "How to Run a Project at Machine Speed"
- **Book lines:** 637-738
- **Fallback:** `knowledge/public/getting-started/quick-start-guide.md` (PRDs section), `knowledge/public/getting-started/learning-path.md` (Module 6)
- **HQ refs:** `knowledge/public/getting-started/quick-start-guide.md`
- **Key quote:** "Don't over-specify. State outcomes, not methods. Let the system discover the best approach."
- **Show:**
  - Search for existing prd.json files: `qmd search "prd.json userStories" --json -n 5`
  - If any exist: read one and walk through the structure — name, stories, acceptance criteria, passes field, files array
  - If none: explain the structure using the PRD schema from the book, emphasizing acceptance criteria as the "teeth"
- **Exercise (Tier 1 + Tier 3 suggestion):**
  1. If a prd.json exists: read it and ask "How many stories are in this project? How many have passed verification?" Show how `passes: true/false` creates back pressure
  2. If none: explain the /idea → /brainstorm → /plan → /run-project pipeline. Suggest: "Try `/idea` to capture something small on your board."
- **Verify:** User understands that acceptance criteria define "done" for autonomous agents — without them, the loop has no back pressure.
- **Takeaway:** "A PRD is a to-do list with teeth. Acceptance criteria are how autonomous agents know when to stop."
- **Next topic:** scaling

### Topic 7: scaling

- **Chapter:** 9 — "Scaling to Many — Running 6-8 Agents in Parallel"
- **Book lines:** 829-936
- **Fallback:** `knowledge/public/getting-started/learning-path.md` (Modules 9-10)
- **HQ refs:** `companies/manifest.yaml`
- **Key quote:** "This is not multitasking. This is multiplying."
- **Show:**
  - Read `companies/manifest.yaml` — count companies, show the isolation structure (each company → repos, workers, knowledge, settings)
  - Check `workspace/orchestrator/active-runs.json` — show parallel session tracking if any runs exist
  - Explain company isolation: separate sessions, credential routing via manifest, policy scoping
- **Exercise (Tier 1):**
  1. Read `companies/manifest.yaml` and count: companies, total repos across all companies, total workers
  2. Read the Company Isolation hard rules from CLAUDE.md (the "NEVER" list)
  3. Ask: "If you were running sessions for two different companies simultaneously, what prevents you from accidentally using Company A's credentials in Company B's session?" (Answer: manifest-based credential routing, company-scoped policies, cross-company hooks)
- **Verify:** User can explain at least one isolation mechanism (manifest routing, policies, or hooks).
- **Takeaway:** "Parallelism is what separates operators from power users. Company isolation is the guardrail that makes it safe."
- **Next topic:** ralph-loop

### Topic 8: ralph-loop — The Ralph Loop (Orchestration) *(rescoped)*

- **Chapter:** 3 + 7 — orchestrator mechanics, not principles
- **Book lines:** 243-336 (Ch 3, quickly re-read for loop diagram), 637-738 (Ch 7 for `/run-project` mechanics)
- **Fallback:** `knowledge/public/getting-started/learning-path.md` (Module 3 + 7), `knowledge/public/hq-core/policies-spec.md`
- **HQ refs:** `.claude/commands/run-project.md`, `settings/orchestrator.yaml`, `workspace/orchestrator/active-runs.json`
- **Key quote:** "A loop with back pressure runs forever. A loop without it runs off a cliff."
- **Focus discipline:** This is the *mechanics* topic. Assume the user already knows the three principles from Topic 1. Teach how HQ instantiates them: `/run-project` as the loop runner, sub-agents as fresh-context carriers, `passes: true/false` + file locking as back pressure, autonomous overnight runs as the payoff. Do NOT re-teach plan mode or fresh context here.
- **Show:**
  - Read `.claude/commands/run-project.md` — walk through the orchestrator's task-selection loop
  - Read `settings/orchestrator.yaml` — show file locking config, repo coordination rules
  - Read `workspace/orchestrator/active-runs.json` (if any runs exist) — show the cross-session coordination artifact
  - Annotate: where does each of the three principles live in the orchestrator code? (plan mode = sub-agent kickoff, fresh context = new Task per story, back pressure = `passes` field + file locks)
- **Exercise (Tier 1):**
  1. Run `qmd search "run-project passes acceptance" --json -n 5` — find orchestrator references
  2. Read one prd.json with a story that has `passes: false` (if any). Identify the acceptance criteria that would flip it to `passes: true`
  3. Ask: "In an 8-hour autonomous overnight run, what prevents the orchestrator from marking a failing task as done and moving on?" (Answer: acceptance criteria + `passes` field + sub-agent verification step)
- **Verify:** User can point to the specific code/config that enforces back pressure in `/run-project`.
- **Takeaway:** "The Ralph Loop at scale = `/run-project` + PRD acceptance criteria + file locking. The principles don't change — the machine just runs them without you."
- **Next topic:** workers

### Topic 9: workers

- **Chapter:** 5 — "Workers, Not Agents"
- **Book lines:** 449-544
- **Fallback:** `knowledge/public/getting-started/quick-start-guide.md` (Workers section), `knowledge/public/getting-started/learning-path.md` (Module 4)
- **HQ refs:** `workers/registry.yaml`
- **Key quote:** "Start with one. Build it right. Add the next one when the first is running reliably."
- **Show:**
  - Read `workers/registry.yaml` — count and categorize workers (shared vs company)
  - If user has company workers: pick one, read its `worker.yaml`, and annotate the four components (identity, context, skills, permissions)
  - If no company workers: read one shared worker (e.g., `workers/public/qa-tester/worker.yaml`) as an example
- **Exercise (Tier 1 + Tier 3 suggestion):**
  1. Read a worker.yaml and identify the four components: identity (name, role), context (knowledge paths), skills (what it can do), permissions (tool access)
  2. Suggest: "After this tutorial, try `/newworker` to create your first domain-specific worker. Use `/learn` to teach it as you go."
- **Verify:** User can point to where identity, context, skills, and permissions live in the worker.yaml structure.
- **Takeaway:** "Workers carry four things: identity, context, skills, permissions. One well-built worker beats five generic ones. `/learn` is how they get smarter — write learnings back into the worker's policies."
- **Next topic:** back to menu (you've completed the arc)

---

## Book Reference Protocol

The book at `repos/private/knowledge-empire-os/book/build-your-own-agi.md` is the source material.

**Rules:**
1. Read ONLY the line range mapped to the current topic's chapter — never the full book
2. Synthesize in your own words — never paste paragraphs from the book
3. Surface exactly ONE key quote per topic (defined in Topic Registry) — attribute to the book
4. End every lesson with: "Full chapter: Ch {N} in *Build Your Own AGI* — [{your-book-site}](https://{your-book-site})"
5. If the book file does not exist (starter-kit users without the private repo), use the fallback files listed per topic + link to {your-book-site} for the full content

## Topic Ordering Discipline

Topics 1 and 8 both draw from Ch 3 but split cleanly:

| Topic | Scope | Do teach | Don't teach |
|-------|-------|----------|-------------|
| 1. `principles` | Mindset | plan mode, fresh context, back pressure (as concepts) | `/run-project`, sub-agents, file locking |
| 8. `ralph-loop` | Mechanics | `/run-project`, orchestrator config, `passes` field, file locks | plan mode theory (assume known from Topic 1) |

If a user asks an orchestration question during Topic 1, route them: "That's Topic 8 — finish principles first."
If a user asks a principles question during Topic 8, say: "Refresher: Topic 1 covers the mindset" but continue with mechanics.

## Rules

- **Read-only.** This skill reads files, runs searches, and asks questions. It NEVER writes, edits, or creates files. The only tools used are Read, Glob, Grep, Bash (qmd/git/ls/wc only), and AskUserQuestion
- **One topic per invocation.** Complete the full 5-phase flow for one topic, then suggest the next. Don't try to cover multiple topics
- **Context-efficient.** Read only what the topic needs. Don't load CLAUDE.md fully — read specific sections. Don't read the whole book — read mapped line ranges
- **No sycophancy.** Don't say "great question" or "excellent choice." Teach directly
- **Adapt to what's there.** Every topic has a "has content" and "no content" path. Use whichever matches the user's HQ state
- **Exercises are safe.** Tier 1 exercises execute read-only commands. Tier 2 exercises ask the user to run commands. Tier 3 exercises are never executed — only suggested for later
- **Book link on every lesson.** Always end with the {your-book-site} link. The tutorial teaches principles; the book goes deeper
