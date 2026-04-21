# HQ Quick Start Guide

Your personal AI operating system. This guide covers what HQ is, how it works, and how to start shipping real work with it.

---

## What HQ Is

HQ is a folder on your computer. That's it — and that's everything.

Inside that folder is a skill tree: commands, workers, knowledge bases, and project structures that turn Claude Code into your personal AI workforce. It's local-first, it never automatically pushes to GitHub, and you control what gets shared and what stays private.

Think of it this way: you have access to 1,000 employees willing to work for free. They're standing in an empty field. No desks, no job descriptions, no org chart, no office. Most people open a chat, ask a question, close the tab. That's like having 1,000 workers and never giving them a job.

HQ is the infrastructure that puts those workers to work. The office. The org chart. The job descriptions. The system that routes the right task to the right worker and verifies the output before moving on.

### The AI Adoption Stack

Most people are stuck at Level 1. HQ gets you to Level 3 — the inflection point where everything changes.

| Level | What It Looks Like | Description |
|-------|-------------------|-------------|
| **1. Tools** | ChatGPT, one-off queries | No memory, no system. Every conversation starts from zero |
| **2. Workflows** | Templates, automations | Consistent outputs, but you pull the trigger every time |
| **3. Workers** | Autonomous agents with feedback loops | Self-correcting. AI runs tasks without you watching every step |
| **4. OS** | Workers coordinating across projects | The entire operation running with a fraction of the human hours |

---

## The Core Loop

HQ is built on a methodology called the Ralph Loop, developed by Geoffrey Huntley and validated by Anthropic's official agentic architecture.

The idea is deliberately simple:

1. Take a task from a list
2. Give it to AI **in plan mode**
3. AI plans the approach, executes it, verifies against acceptance criteria
4. If it passes, commit the work. Pick the next task. Repeat.

A for loop. A spec file. Automated verification. Fresh context per task.

### Plan Mode vs. Ask Mode

This is the single most important setting in your entire setup.

**Ask mode:** AI charges toward an answer with minimal thinking. It misses context, makes assumptions, optimizes for speed over accuracy.

**Plan mode:** AI thinks deeply before acting. It reads documentation, checks constraints, considers edge cases. It anchors itself in reality before building anything.

**The rule: always plan mode. Every task. No exceptions.**

> "AI in ask mode is not AGI. AI in plan mode can be."

### Fresh Context Per Task

Every task starts from zero accumulated confusion. The agent gets the full specification, the full context it needs, and nothing else. No drift from previous decisions. No accumulated hedging.

This is counter to how most people use AI. Most people have one long conversation that gets worse and worse. The Ralph Loop is the opposite — discipline about fresh context is what makes autonomous execution reliable.

### Back Pressure

Before AI commits work and picks the next task, it runs verification. Did the code compile? Do the tests pass? Does the output match acceptance criteria?

Without back pressure, autonomous agents hallucinate. With it, the system catches failures immediately, before anything compounds. The loop only advances when the work is actually done.

---

## The Daily Workflow

Your daily loop follows this sequence:

```
/startwork  ->  /brainstorm  ->  /plan  ->  /run-project  ->  /handoff
```

| Command | What It Does |
|---------|-------------|
| `/startwork` | Opens your session. Reads your last handoff, shows your board, picks up where you left off |
| `/brainstorm` | Explores a fuzzy idea. Use when you know the direction but not the shape |
| `/plan` | Turns a concrete idea into a project with user stories and acceptance criteria |
| `/run-project` | Executes the PRD story by story — the Ralph Loop at full scale |
| `/handoff` | Closes your session, logs it, preserves context for next time |

### The Progression

**Day 1:** Install, run `/setup`, explore. Let it build your starting context.

**Week 1:** Pick one real project. Run `/brainstorm` to explore it, `/plan` to scope it, `/run-project` to execute it. Close every session with `/handoff`.

**Week 2:** The daily cadence clicks. `/startwork` every morning, `/handoff` every evening. You're reviewing work, not doing it.

**Month 2+:** Scale. Add workers for new domains. Build knowledge bases. Run multiple sessions in parallel. The system compounds — every session makes the next one smarter.

---

## Key Concepts

### Workers

Workers are specialized AI agents with defined roles, loaded context, and specific skills. Not generic chat — each worker knows their domain and carries that knowledge into every task.

Your HQ ships with shared workers (frontend designer, QA tester, content writers). You'll build company-specific workers for your domain — trained on your business logic, your standards, your judgment.

Build one worker well before adding the next. Depth beats breadth. Use `/learn` to teach workers from your corrections — that's how institutional memory accumulates.

### Knowledge

HQ without knowledge is a library with empty shelves. Knowledge bases are where your business logic, documentation, and domain expertise live. They're indexed and searchable, so workers can find what they need without you explaining it every session.

Knowledge comes in two forms:
- **Cold channels:** Structured docs, databases, published content — persistent and indexed
- **Hot channels:** Meeting transcripts, Slack messages, real-time signals — high-frequency, decision-driving

The more knowledge you load, the smarter every session becomes. This is where the difference between power users and casual users diverges most sharply.

### PRDs

A PRD (Product Requirements Document) is how you give AI a project, not just a task. It contains user stories with acceptance criteria — clear definitions of "done" that the system can verify.

The workflow: `/plan` creates the project structure. `/run-project` executes it story by story through the Ralph Loop. Each story gets fresh context, builds on verified work, and commits when done.

### Session Hygiene

Every session has a context limit. Hit it and continuity dies. The rules:

- **`/handoff`** before closing — logs the session, preserves state for next time
- **`/checkpoint`** mid-session — saves progress without fully closing
- **Fresh sessions are smarter than long ones** — don't let threads grow too long
- **One project per session** — never mix company work in one thread

---

## Rules of Thumb

1. **Plan mode always.** Every task, no exceptions. This is the single most important setting.

2. **One thing at a time.** Fresh context per task. Don't pile five requests into one session.

3. **Be bossy but naive.** Know what you want. Don't pretend to know how to build it. Clear outcomes, not implementation details. Vague instructions often get better results than over-specified ones.

4. **YOLO the permissions.** Start in plan mode to observe. Once comfortable, let the system execute without asking permission at every step. The output speed increases dramatically.

5. **Fresh sessions beat long ones.** Close and reopen rather than pushing a session past its useful life. `/handoff` is your friend.

6. **Tend your garden.** Old knowledge becomes weeds. Run `/reanchor` every few days when starting out to keep HQ clean and fast.

7. **Teach, don't just correct.** When AI gets something wrong, use `/learn` to capture the correction permanently. That's how the system gets smarter over time.

---

## What's Next

- **Run `/personal-interview`** — deep interview that builds your voice and profile
- **Try `/startwork`** — see what your board looks like
- **Pick one real project** — the best way to learn is to ship something
- **Read the full book** — *Build Your Own AGI* (resolve `{your-book-site}` from `agents-profile.md` if configured)
- **Daily reference** — keep `knowledge/getting-started/cheatsheet.md` handy
- **Learning path** — see `knowledge/getting-started/learning-path.md` for the full 11-module progression
