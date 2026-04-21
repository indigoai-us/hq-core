# HQ Learning Path

Self-paced progression from first setup to running parallel agents. Each module builds on the previous one.

---

## Beginner — Week 1

Get running. Ship your first output.

### Module 1: The Identity Shift
You're not using a tool. You're operating a workforce.

The best AGI is the one you build — specialized toward your work, your data, your judgment. The question is no longer "can AI do this?" It's "how do you run the team?"

**Key idea:** You are an operator of autonomous intelligence, not a consumer of AI.

### Module 2: The Ralph Loop
How agentic AI actually works — plan mode, fresh context, back pressure.

The Ralph Loop is a for loop: take a task, plan it, execute it, verify it, commit it, repeat. Every task starts with clean context. Verification at every step prevents cascading failures.

**Key idea:** Plan mode always. "AI in ask mode is not AGI. AI in plan mode can be."

### Module 3: HQ Setup
Your folder, your git repo, your skill tree.

HQ is a folder on your computer that becomes the infrastructure for your AI workforce. Claude Code is the interface. `/setup` initializes it for your role. Everything is local-first — it never auto-pushes to GitHub.

**Key idea:** HQ is a city you build so your workforce has somewhere to work.

---

## Intermediate — Weeks 2-3

Build the machine. Ship real projects.

### Module 4: Workers and Commands
Building your AI org chart.

Workers are specialized agents with identity, context, skills, and permissions. They carry domain knowledge into every task. `/run` invokes a worker. `/learn` teaches them from your corrections.

**Key idea:** Start with one worker. Build it well. Depth beats breadth.

### Module 5: Knowledge Architecture
Teaching HQ your domain — cold channels vs. hot channels.

Knowledge bases are where your business logic lives. Cold channels (docs, databases) are persistent and indexed. Hot channels (meetings, Slack) are real-time and decision-driving. The more knowledge you load, the smarter every session becomes.

**Key idea:** HQ without knowledge is a library with empty shelves.

### Module 6: PRDs and Project Planning
From idea to execution — think like an architect.

A PRD is how you give AI a project, not just a task. User stories with acceptance criteria define "done" in terms the system can verify. `/plan` creates the structure. `/run-project` executes it.

**Key idea:** Don't over-specify. State outcomes, not methods. Let the system discover the best approach.

### Module 7: Deploying Your Work
GitHub, Vercel, and the CLI — making work real and shareable.

GitHub CLI bridges HQ to the outside world. Vercel publishes dashboards and apps. Sub-projects create their own branches and PRs. HQ itself stays on main.

**Key idea:** HQ is local. What you build inside it can be deployed anywhere.

### Module 8: Session Hygiene
Handoffs, checkpoints, and context management.

Every session has a context limit. Hit it and continuity dies. `/handoff` saves state. `/checkpoint` preserves mid-session. Fresh sessions are always smarter than long ones.

**Key idea:** Close early, close often. `/handoff` is your end-of-day save button.

---

## Advanced — Month 2+

Scale and transform.

### Module 9: The Orchestrator
Multi-story projects running autonomously.

`/run-project` dispatches sub-agents per story. Each commits its own work. File locking prevents conflicts. Back pressure ensures quality. This is the Ralph Loop at full scale.

**Key idea:** Start in plan mode for observability. Switch to bypass permissions once confident.

### Module 10: Multi-Session Scaling
Running 6-8 agents in parallel.

One session per project. One session per company. Keep the sidebar open — multiple threads visible. Company isolation via policies prevents context bleed between clients.

**Key idea:** Parallelism is what separates operators from power users.

### Module 11: The Transformation
What this means for your team, career, and business.

One AI-enabled person produces the output of 5-10 traditionally staffed people. The early adopters build skills others cannot catch up on. The compounding advantage starts now.

**Key idea:** You're not learning a tool. You're building a competitive moat.

---

## Resources

| Resource | Location |
|----------|----------|
| Quick Start Guide | `knowledge/getting-started/quick-start-guide.md` |
| Daily Cheatsheet | `knowledge/getting-started/cheatsheet.md` |
| Ralph Methodology | `knowledge/Ralph/` |
| Worker Registry | `workers/registry.yaml` |
| Full Book | resolve `{your-book-site}` from `agents-profile.md` |
| Community | resolve `{your-community-site}` from `agents-profile.md` |
