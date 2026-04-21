---
type: guide
domain: [engineering, operations]
status: canonical
tags: [ralph, team-training, onboarding, {company}, best-practices, workshops]
relates_to: []
---

# Ralph & Building AGI: Team Training Guide

*Synthesized from {company} Dev Standups (Jan 13-26, 2026), Zoom sessions, and HQ Ralph Knowledge Base*
*Sources: 80+ signals from {company} MCP, 12 Ralph knowledge files, 15 meetings*

---

## Part 1: What Is Ralph?

A deceptively simple orchestrator pattern for autonomous AI coding created by Geoffrey Huntley. Instead of complex agent frameworks, use a **for loop** that picks tasks, generates code, runs automated checks (back pressure), commits on pass, and repeats. Fresh context per task prevents context rot.

Core insight: **simplicity beats complexity**.

### The Problems It Solves
- **Context rot** -- AI loses track of earlier context as the window fills up
- **Compaction** -- context gets filled with irrelevant information, leaving less room for actual work
- **Complexity** -- elaborate orchestrators add failure points
- **Human dependencies** -- manual intervention breaks autonomous flow

### The Vision
*"Wake up in the morning to working code that your coding agent has worked through your backlog and just spit out a whole bunch of code for you to review and it works."* -- Geoffrey Huntley

---

## Part 2: The Loop In Detail

### Flow Diagram
```
Load PRD + agents.md
       |
Pick ONE task (passes: false)
       |
Generate code
       |
Run back pressure checks (tsc, eslint, jest, build)
       |
  Pass? --Yes--> Commit & Update PRD (passes: true) --> Next iteration
  Pass? --No---> Retry/Fix --> Run checks again
```

### The Script
```bash
#!/bin/bash
ITERATIONS=${1:-10}

for i in $(seq 1 $ITERATIONS); do
    echo "=== Ralph Loop Iteration $i ==="

    claude --print "Read plans/prd.json and find first feature where passes is false.

    Implement ONLY that feature.

    Then run:
    1. npm test
    2. npm run lint
    3. npm run typecheck
    4. npm run build

    If ALL pass:
    1. Commit the changes
    2. Update plans/prd.json to set passes: true
    3. Append progress to progress.txt

    If ANY fail:
    1. Fix the issues
    2. Try again"

    echo "Completed iteration $i"
    sleep 2
done
```

### Running Overnight (AFK Coding)
```bash
# tmux
tmux new-session -d -s ralph && tmux send-keys -t ralph './ralph.sh 100' Enter

# nohup
nohup ./ralph.sh 100 > ralph.log 2>&1 &
```

{your-name} on this topic (Jan 21 Zoom): *"Your goal is to get it where you can set up your computer overnight and let it just run."*

### Monitoring
```bash
cat progress.txt | tail -20
echo "Completed: $(grep -c '"passes": true' plans/prd.json)"
echo "Remaining: $(grep -c '"passes": false' plans/prd.json)"
```

---

## Part 3: The Four Components

### 1. PRD (prd.json) -- The Specification + Test Harness

```json
{
  "project": "{company}-desktop",
  "version": "1.0",
  "features": [
    {
      "id": "feature-001",
      "title": "Authentication Flow",
      "description": "User login with OAuth",
      "user_story": "As a user, I want to log in securely...",
      "acceptance_criteria": [
        "OAuth flow completes successfully",
        "Token stored securely",
        "Error states handled gracefully"
      ],
      "priority": "high",
      "passes": false
    }
  ]
}
```

**Good specs**: Specific, measurable, independently testable, small enough for one iteration, clear success criteria.

**Bad specs**: Too broad ("build the entire auth system"), vague ("it works well"), not independently testable.

The `passes` field is critical -- it tells the loop whether the feature has been verified. The PRD serves dual purpose: specification AND test harness.

**From the team** (Jan 14): Yousuf created a PRD for the Daily Brief feature using Ralph, demonstrating the spec-first approach.

### 2. Progress File (progress.txt) -- The Audit Trail

Running log with timestamps showing: which feature was started, tests passed/failed, git commit hashes, PRD updates. Provides audit trail for human review, context for subsequent runs, and handoff capability.

**From the team** (Jan 21): Yousuf's Ralph session logged progress as it cleaned 300+ files from the Electron app, enabling review of what was changed.

### 3. agents.md / CLAUDE.md -- The Brain

Minimal config file. Include only:
- Project overview (1-2 sentences)
- Tech stack
- Build/test commands
- Task loop protocol
- "Do NOT" rules

**Anti-patterns to avoid:**
- Everything in one file (context bloat)
- Contradictory instructions
- Outdated information
- Too verbose
- No verification steps

**Key concept: Mallocing vs Static Loading**
- **Static** (bad): Load agents.md once, use for entire session. Context rots.
- **Dynamic/Mallocing** (good): Start task -> load only relevant specs -> complete -> clear -> repeat. Fresh context per task.

### 4. Back Pressure -- The Verification Layer

What makes autonomous coding reliable. Without it, hallucinations compound, bugs accumulate, context rot makes everything worse.

| Type | Command | Speed | Purpose |
|------|---------|-------|---------|
| Type checking | `tsc --noEmit` | Very fast | Catch type errors |
| Linting | `eslint . --max-warnings 0` | Fast | Code style + patterns |
| Unit tests | `npm test` / `pytest` | Important | Logic verification |
| Integration tests | `npm run test:integration` | Comprehensive | System behavior |
| Build | `npm run build` | Essential | Final validation |
| Visual (frontend) | Playwright MCP / browser automation | For UI | Screenshot verification |

**Speed is critical**: TypeScript + ESLint + Jest = ~10 seconds. Rust compilation = 5-30 minutes (problematic for rapid iteration). Optimize for fast feedback.

**From the team** (Jan 16): {your-name} emphasized speed optimization for testing -- *"start... maybe have a small one so it's a little bit faster, but speed is another thing that we should try and optimize."*

**From the team** (Jan 16): Yousuf integrated Playwright MCP server for browser automation testing -- *"Your cloud will use the same Playwright MCP server that I have integrated in the application."*

---

## Part 4: What the Team Learned (Meeting-by-Meeting)

### Jan 13 Standup: Exploring Frameworks

**Decision: Try multiple agent frameworks**
- {your-name}: Explore Ralph TUI, Cursor Grind Mode, etc.
- *"Cursor also just added a new mode that's supposedly a loop mode. It's called Grind."*
- Goal: find what works, get things cleaned up and running

**Action: Clean up codebase for AI agents**
- This was identified as the main focus priority to be completed by the weekend
- Rationale: messy code slows AI agents significantly

**Action: Containerize for security**
- Containerization needed as security measure and prerequisite for cloud deployment
- Creates containerized agent with proper permissions

**Stefan's agent performing well** in development environment -- early validation of the AI agent approach.

### Jan 14 Standup: First Ralph Implementations

**Yousuf: Auth flow implemented with Ralph**
- All tests passing, no bugs
- Set up Ubuntu Server sandbox for Ralph testing
- Created PRD for the Daily Brief feature using Ralph

**Decision: Consider killing command code and rebuilding with Ralph**
- The existing command code had limitations warranting a fresh build

**Decision: Improve agent response formatting**
- Agent responses needed to be more concise and human-readable
- Formatting and prompting improvements prioritized

### Jan 15 Standup: Workflow Crystallizes

**Yousuf completed auth in 1 day vs 3-4 days** -- the breakthrough moment.
- *"Yousuf completed authentication implementation in 1 day using Ralph, compared to 3-4 days it would have taken previously"*
- 3-4x faster development speed demonstrated with real production code

**Decision: Ralph for features, Kurtzer for bugs**
- Ralph for new feature building (structured, PRD-driven)
- Traditional approach for bug fixing and maintenance (more ad-hoc)
- Consider creating a separate Ralph instance specifically for bug fixes

**Team established efficient workflow** using Ralph with significant, measurable productivity gains

### Jan 16 Standup: Training Deep Dive

This was the richest training session. {your-name} laid out the approach for the whole team:

**Decision: Start with a single feature per dev**
- {your-name}: *"For devs, the best way to do that with an active project is to choose a single feature and build a Ralph pipeline just for that feature."*
- *"Kind of what Yousuf did with Auth."* -- referencing the proof of concept

**Action: End-to-end testing with Ralph Loop**
- {your-name}: *"Get the Ralph Loop on this. Get a loop on end-to-end agent testing. Find some... start... maybe have a small one so it's a little bit faster, but speed is another thing that we should try and optimize."*

**Stefan's learning approach**
- *"I'm using it as a quick, safe sandbox to tune in... start using the screwdriver on Ralph, and learn the principles, and set up my own workflow."*
- Then diving into RDF/ontological changes for insights
- *"I think once I get that in... I think we're gonna start seeing better results on bookmarks."*

**Decision: Study and fork Loom for their environment**
- {your-name}: *"I don't think it's adopting it exactly, it's like, trying to figure out what's going on in there, and then once you understand everything, start stripping out what's not for us."*

**Decision: Fix deep agent issues before new features**
- {your-name}: *"That's what I need you focused on now"* -- prioritizing stability over new features

**Yousuf: Playwright MCP integration completed**
- Browser automation testing now available for the agent pipeline

### Jan 19 Standup: Architecture Decisions

**Decision: Clean codebase = 10x Ralph speed**
- {your-name}: *"I think the only thing we need to focus on right now is just getting everything cleaned out of the {company} codebase that's messy. And not relevant, so that Ralph just starts moving 10 times faster."*
- This became the team's #1 priority

**Decision: Single environment architecture**
- {your-name}: *"I really like the no staging and potentially even no dev environment complications. Move towards feature flagging or alpha-beta releases, and just have single environment, single set of keys."*
- Yousuf: *"Yeah, I think we can start from cleaning up staging for now."*
- Eliminate unnecessary intermediate environments to reduce key management complexity

**Accomplishments this session:**
- New beta version released with citation feature (developed by Stefan)
- Fixed prompt issue in follow-up messages to deep agent
- Stefan at 70-80% completion on his development branch

### Jan 20 Standup: HQ Adoption

**Decision: Yousuf should implement HQ system**
- {your-name} recommended HQ for managing projects and tasks since Yousuf was working solo
- *"{your-name} recommended that Yousuf implement the HQ system to manage projects and tasks since he's working solo"*

**Action items:**
- Install and set up HQ locally
- Contribute to HQ Starter Kit repo after accepting GitHub invite
- HQ Starter Kit had already generated $900 in token fees

**Yousuf decided to manually clean up code** rather than using an agent -- *"He knows what is redundant and what is not, making manual cleanup more effective than automated approaches"*. This is an important nuance: Ralph is for building, but sometimes human judgment is faster for targeted cleanup.

### Jan 21 Standup: Scaling Results

**Ralph cleaned 300+ files in one hour**
- Yousuf used Ralph to clean up the Electron app
- Removed old configs and code from previous systems
- Context: *"using Ralph AI tool which completed the task in one hour with changes to 300+ files"*
- Previously would have been a multi-day effort

**Yousuf reran Ralph on planning mode** feature after cleanup was complete -- demonstrating the iterative pattern

**Decision: Use HQ as central system**
- {your-name} pushed team to adopt HQ setup repo for project tracking
- Both Stefan and Yousuf to start using it, even beyond work projects

**Stefan: Developed system for launching terminals** with predefined context for Claude Code sessions -- workflow optimization

### Jan 22 Standup: Infrastructure & Tooling

**Yousuf: Claude Max account + HQ in cloud**
- Cloud-based HQ setup enables working from anywhere

**Docker configuration for team**
- Repository set up so team members configure local environments with 3-4 commands
- Reduced onboarding friction significantly

**Action: Test HQ** after getting Claude Max account access

**Decision: Improve Plan Mode UI** to match Claude's interface
- Standard shimmer animation, button styling
- Multiple-choice UI based on Claude's implementation

### Jan 26: Florian/{company} Meeting

**Positive feedback on design work** -- one-pager received well
- {your-name}: *"Everyone's really happy with the stuff you're doing. The one-pager is way better."*

**Decision: Redesign product flow** to horizontal/linear timeline layout
- {your-name}: *"Try putting it linear according to how it makes sense to you, and then we'll clean up from there."*

### Jan 21 Zoom (Late Night): AGI & AI Automation Demo

**{your-name} demonstrated AI-powered website migration from Webflow** -- completed in under one hour
- *"5:19 PM, V1 is up, and I've given him a repo, and now he can take it over, you just woke up. And it's already... our site is basically cloned."*
- This demonstrated the practical power of autonomous AI coding in a real-world scenario

**Hardware for overnight AI automation**
- {your-name}: *"Your goal is to get it where you can set up your computer overnight and let it just run."*

**AI tools to automate project asset creation**
- {your-name}: *"This will guide us through that too. It'll be like, okay, now go create an X account for you. Okay, I'm gonna go do this for you."*

---

## Part 5: Practical Playbook

### For New Team Members

**Phase 1: Learn (Day 1-2)**
1. Read HQ Ralph knowledge base: `knowledge/public/Ralph/` (10 chapters)
2. Set up a sandbox environment (Stefan's approach -- safe place to experiment)
3. Watch Geoffrey Huntley's "Ralph Wiggum Loop from 1st principles" video
4. Get Claude Max account and set up HQ locally

**Phase 2: First Feature (Day 3-5)**
1. Pick ONE well-defined feature from your backlog
2. Write a PRD with specific, testable acceptance criteria
3. Ensure back pressure exists: type checking, linting, tests, build
4. Create minimal agents.md / CLAUDE.md
5. Run the loop for your single feature
6. Review results, iterate

**Phase 3: Integrate (Week 2+)**
1. Expand to multiple features in the PRD
2. Set up overnight runs via tmux
3. Create separate Ralph instances for bugs vs features
4. Consider Docker configuration for team standardization
5. Adopt HQ for project tracking

### What to Ralph vs What NOT to Ralph

| Ralph it | Don't Ralph it |
|----------|---------------|
| New feature implementation | Targeted bug fixes (use traditional) |
| Large-scale code cleanup (300+ files) | Exploratory debugging |
| Auth flows, CRUD operations | Security-critical manual review |
| Test suite creation | Architecture decisions |
| Codebase migration | API key/credential management |

### Writing Good PRD Specs

Each feature should be:
- **S**pecific -- clear what needs to be built
- **M**easurable -- acceptance criteria are binary pass/fail
- **I**ndependent -- can be implemented without other features
- **T**estable -- automated checks can verify it
- **S**mall -- completable in one iteration

### agents.md Template

```markdown
# Project: [Name]

## Overview
[1-2 sentences]

## Tech Stack
- Language: TypeScript
- Framework: [React/Next/Node]
- Testing: Jest + React Testing Library

## Commands
- `npm run dev` - Start dev server
- `npm run build` - Production build
- `npm test` - Run tests
- `npm run lint` - Run linter

## Task Loop
1. Read `plans/prd.json`
2. Find first item with `passes: false`
3. Implement ONLY that feature
4. Run: `npm test && npm run lint && npm run typecheck`
5. If all pass: commit and set `passes: true`
6. If any fail: fix and retry

## Do NOT
- Modify package.json without approval
- Delete existing tests
- Use `any` type
- Skip running all back pressure checks
```

---

## Part 6: Architecture Patterns

### Orchestrator + Sub-Agent Pattern (for multi-task projects)

**Orchestrator** (stays lean, ~10-20% context):
- Reads PRD, picks ONE task (passes: false)
- Spawns sub-agent with task spec
- Reads checkpoint when done
- Updates PRD (passes: true), repeats until all pass

**Sub-Agent** (fresh context per task, 100% available):
- Receives task spec + file paths
- Implements feature
- Runs back pressure
- Commits code, writes checkpoint, exits

Benefits:
1. Orchestrator stays fast (small context, quick responses)
2. Sub-agents get full context (fresh start per task)
3. Checkpoints preserve state across context resets
4. Parallel execution possible (spawn multiple sub-agents)

### Single Environment Architecture (Team Decision Jan 19)

Instead of managing staging/dev/prod:
- Single production environment
- Feature flags control rollout
- Alpha-beta release channels
- Single set of API keys

Why: *"I really like the no staging and potentially even no dev environment complications. Move towards feature flagging or alpha-beta releases, and just have single environment, single set of keys."* -- {your-name}

### Separate Ralph Instances

From team practice:
- **Feature Ralph** -- PRD-driven, new functionality
- **Bug Ralph** -- separate instance for fixes
- **Cleanup Ralph** -- codebase cleanup tasks (like the 300+ file session)
- **Test Ralph** -- end-to-end agent testing loops

---

## Part 7: Economics & Speed

### Development Cost Comparison

| Method | Cost/Hour |
|--------|-----------|
| AI (Ralph) | ~$10.50 |
| Junior Dev | $35-50 |
| Senior Dev | $75-150 |
| Staff Engineer | $150-250 |

Running 24/7: ~$250/day or ~$7,500/month

### Team Speed Results

| Task | Traditional | With Ralph | Speedup |
|------|------------|------------|---------|
| Auth implementation | 3-4 days | 1 day | 3-4x |
| Electron app cleanup (300+ files) | Multi-day | 1 hour | 10-20x |
| Website migration from Webflow | Days | < 1 hour | 10x+ |

### Skills That Matter More Now
- System design and architecture
- Prompt engineering / AI orchestration
- Domain expertise and product sense
- Quality assurance and testing design
- Spec writing (PRDs, acceptance criteria)

---

## Part 8: Key Principles (Distilled from Training)

1. **Start small, one feature at a time** -- Yousuf proved this with auth. Don't try to Ralph everything on day 1.

2. **Clean codebase = faster Ralph** -- Messy code slows everything 10x. Cleanup is investment, not waste.

3. **Use a sandbox to learn** -- Stefan's approach: safe sandbox first to learn principles and set up personal workflow, then apply to real work.

4. **Back pressure is non-negotiable** -- Tests, linting, type checking must all pass. This is what prevents hallucination from compounding.

5. **Fresh context per task** -- Start clean each iteration. Context rot is the enemy. The loop naturally resets.

6. **Ralph for features, traditional for bugs** -- Different tools for different work. Sometimes human judgment is faster for targeted fixes.

7. **Speed matters everywhere** -- Fast tests, fast feedback, fast iteration. Optimize for 10-second back pressure cycles.

8. **Single environment simplifies** -- Feature flags over staging environments. One set of keys. Less infrastructure to manage.

9. **Hardware enables AFK coding** -- Goal is overnight runs. Upgrade hardware if needed. Use tmux/nohup.

10. **HQ centralizes everything** -- Project tracking, PRDs, checkpoints, progress files all in one system.

---

## Part 9: Team Progress & Roles

| Person | Ralph Stage | Key Achievements | Next Steps |
|--------|-------------|-----------------|------------|
| **Yousuf** | Production user | Auth in 1 day (3-4x), 300+ file cleanup in 1hr, sandbox setup, Playwright MCP, Claude Max + cloud HQ | Separate bug Ralph instance, Daily Brief PRD |
| **Stefan** | Active learner | Sandbox workflow setup, RDF/ontological changes, agent-runnable testing framework, citation feature, terminal context system | Complete sandbox learning, apply to insights work |
| **Hassaan** | Setting up | Claude Max + HQ, deep agent work, cloud setup | Test HQ, Docker setup |
| **Shawon** | Building agents | Insights Agent as sub-agent with deep agent capabilities | Integration with main system |

---

## Part 10: Resources

### HQ Knowledge Base
`knowledge/public/Ralph/` -- 10 chapters covering:
1. Overview
2. Core Concepts (mallocing, context rot, compaction, back pressure)
3. How Ralph Works (the loop, components)
4. Back Pressure Engineering (types, speed, language recommendations)
5. Specifications (PRD format, quality, forward/reverse generation)
6. agents.md Configuration (structure, anti-patterns, mallocing vs static)
7. Implementation (scripts, file structure, monitoring)
8. Economics (cost comparison, disruption model, new moats)
9. Resources (Geoffrey Huntley videos, Matt Pocock workflows)
10. Claude Code Workflow (plan mode, multi-phase, concision rule)

### Videos
- Geoffrey Huntley: "The Ralph Wiggum Loop from 1st principles" (36 min)
- Geoffrey Huntley: "AI Giants Interview" (1 hr)
- Geoffrey Huntley: "Fundamental skills and knowledge for 2026 SWE" (39 min)
- Geoffrey Huntley: "The history of agents.md and what makes a good one" (22 min)
- Matt Pocock: "Ship working code while you sleep with Ralph Wiggum technique" (16 min)
- Matt Pocock: "How I use Claude Code for real engineering" (10 min)

### Tools
- Claude Code (Anthropic) -- primary agent
- HQ Starter Kit -- project management
- Playwright MCP -- browser automation/testing
- tmux / nohup -- overnight runs
- Docker -- team environment standardization

---

*Compiled from: 80+ signals via {company} Signals MCP, 15 completed meetings (Jan 5-26 2026), Ralph knowledge base (12 files). Covers {company} Dev Standups, David/{your-name}/Keghan syncs, Florian/{your-name} 1:1, and late-night Zoom sessions.*
