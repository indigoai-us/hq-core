---
name: retro
description: Project or session retrospective — review what happened, surface patterns, and feed learnings back to /learn. Two modes — PROJECT (completed project arc) and SESSION (recent work session). Triggers on "retro", "retrospective", "what did we ship", "what went well", "lessons learned".
allowed-tools: Read, Write, Glob, Grep, Bash(git:*), Bash(qmd:*), AskUserQuestion
---

# Retrospective

You are reviewing past work to extract patterns that make future work better. This is not a report for its own sake — every finding should either become a learning (fed to `/learn`) or be acknowledged as already captured.

The goal: leave HQ smarter than you found it.

## Step 0: Mode + Company Resolution

**Mode detection:**
- If `$ARGUMENTS` contains `--session` → SESSION mode
- If `$ARGUMENTS` contains a project slug → PROJECT mode
- If `$ARGUMENTS` is empty or ambiguous → AskUserQuestion: "A) Review a specific project. B) Review recent session work."

**Company resolution:**
Check if the first word matches a company slug in `companies/manifest.yaml`. Same pattern as `/brainstorm`:
1. If matched: set `{co}`, strip from args, load policies
2. If not matched: infer from cwd or project slug location
3. If still ambiguous: ask

Announce: `Mode: {PROJECT|SESSION} | Company: {co}`

## Step 1: Data Collection

### PROJECT Mode

Read these data sources (skip gracefully if any don't exist):

```bash
# 1. The PRD
# Read companies/{co}/projects/{slug}/prd.json
# Extract: stories (titles, statuses), metadata (dates, linear IDs)

# 2. Git history for the project
git log --oneline --since="{prd.createdAt}" -- {repo paths if known}

# 3. Workspace threads mentioning this project
# Glob pattern: workspace/threads/*{slug}*.json
# Read each, extract conversation_summary + files_touched

# 4. Audit log events
grep '"{slug}"' workspace/metrics/audit-log.jsonl | tail -50

# 5. Model usage (worker activity)
grep '"{slug}"' workspace/metrics/model-usage.jsonl | tail -50

# 6. Orchestrator state (if exists)
# Read workspace/orchestrator/{slug}/state.json

# 7. Brainstorm (if exists)
# Read companies/{co}/projects/{slug}/brainstorm.md
```

### SESSION Mode

```bash
# 1. Recent threads (last 24h)
# List workspace/threads/ sorted by modification time, read top 5-10

# 2. Recent learnings
# List workspace/learnings/ sorted by modification time, read top 10

# 3. Recent audit log entries (last 24h)
tail -100 workspace/metrics/audit-log.jsonl

# 4. Recent git activity
git log --oneline --since="24 hours ago"

# 5. Current git status
git status
```

**Present collection summary:**
```
Data collected:
- Stories: {N} found ({done}/{total})
- Threads: {N} found
- Audit events: {N} found
- Git commits: {N} in scope
- Workers used: {list or "none tracked"}
```

## Step 2: Analysis

### PROJECT Mode — Analyze These Dimensions

**1. Story Completion**
| Story | Title | Status | Retries | Workers |
|-------|-------|--------|---------|---------|
| US-001 | ... | done/failed/stalled | N | ... |

**2. Worker Usage**
| Worker | Tasks Assigned | Success Rate |
|--------|---------------|-------------|
| ... | N | N/N |

Which workers carried the most load? Any worker used on >70% of stories?

**3. Timeline**
- PRD created: {date}
- First story started: {date}
- Last story completed: {date}
- Total elapsed: {N days}
- Stories per day: {rate}

**4. Quality Gate Outcomes**
- How many stories passed on first attempt?
- How many required retries? What caused retries?
- Quality gate failure rate: {N}%

**5. File Churn**
- Files touched across most stories (indicates scope underestimation or tight coupling)
- Any files touched by >50% of stories? Flag as architectural hotspot

**6. Learnings Already Captured**
- Check `workspace/learnings/` and `companies/{co}/policies/` for rules created during this project
- List them — don't re-capture what's already been learned

### SESSION Mode — Analyze These Dimensions

**1. What Was Accomplished**
- List each completed task/thread with 1-line summary
- Any tasks started but not finished?

**2. Files Touched**
- Aggregate across all session threads
- Any surprising files? (files outside expected scope)

**3. Failures or Retries**
- Any tool call failures or retries in audit log?
- Any handoff/checkpoint events?

**4. Time Distribution**
- Rough breakdown: planning vs building vs debugging vs reviewing

## Step 3: Pattern Detection

Flag these patterns when evidence supports them:

| Pattern | Signal | Implication |
|---------|--------|-------------|
| **Complexity underestimated** | Story with 2+ retries | PRD story sizing was off — capture as sizing heuristic |
| **Worker overuse** | Same worker >70% of stories | Consider making it a default in PRD template |
| **Quality gate failures** | >20% failure rate | Upstream planning issue — stories shipped before ready |
| **Undeclared files** | Stories with 0 `files[]` in PRD | File locking risk — add to PRD template guidance |
| **Scope creep** | Files touched outside story scope | Scope definition was too narrow or coupling wasn't anticipated |
| **Architectural hotspot** | Same file in >50% of stories | This file needs refactoring or better abstraction |
| **Missing test coverage** | Quality gate test failures | Test strategy needs strengthening for this area |
| **Session fragmentation** | 3+ handoffs for one project | Context overhead — consider longer sessions or better checkpoints |
| **Tool mismatch** | Repeated failures with specific tool/MCP | Tool setup issue or wrong tool for the job |

Only flag patterns with clear evidence. Don't speculate.

## Step 4: Learning Extraction

For each detected pattern:

1. **Generate a learning candidate** — state the rule in ALWAYS/NEVER format:
   - e.g., "ALWAYS declare file dependencies in prd.json stories when the project touches shared modules"
   - e.g., "NEVER estimate stories touching {area} as S — they're always M minimum"

2. **Classify scope:**
   - Project-specific → note it but don't create a policy (too narrow)
   - Company-scoped → `companies/{co}/policies/`
   - Global → `.claude/policies/`

3. **Check for duplicates** — grep existing policies for similar rules

4. **Present to user:**
   ```
   Learning candidates ({N} found):

   1. {rule} — Scope: {company|global} — {new|already exists}
   2. {rule} — Scope: {company|global} — {new|already exists}
   ...

   Run /learn for new learnings? [Y/n]
   ```

5. If user approves: suggest running `/learn` with each new learning. Do NOT write policy files directly — `/learn` handles dedup, formatting, and injection.

## Step 5: Write Retro Report

Output to `workspace/reports/{slug}-retro.md`:

```markdown
# {Project/Session Title} — Retrospective

**Date:** {ISO8601}
**Mode:** Project | Session
**Company:** {co}
**Duration:** {start date} → {end date}

## Summary

{2-3 sentence summary of what happened — scope, outcome, notable events}

## Stories (PROJECT mode)

| Story | Title | Status | Retries | Workers Used |
|-------|-------|--------|---------|-------------|
| US-001 | ... | done | 0 | frontend-designer |

**Completion rate:** {done}/{total} ({%})

## Worker Usage (PROJECT mode)

| Worker | Tasks | Coverage |
|--------|-------|----------|
| ... | N | N% |

## Timeline (PROJECT mode)

- PRD created: {date}
- First story: {date}
- Last story: {date}
- Elapsed: {N} days
- Velocity: {stories/day}

## Session Summary (SESSION mode)

| Thread | Summary | Files | Outcome |
|--------|---------|-------|---------|
| T-... | ... | N files | completed/partial |

## Patterns Detected

{For each pattern with evidence:}

### {Pattern Name}
**Signal:** {what was observed}
**Evidence:** {specific data point}
**Implication:** {what this means for future work}

## Quality Gate Outcomes (PROJECT mode)

- First-pass success rate: {%}
- Total retries: {N}
- Most common failure: {category}

## Learnings

| # | Rule | Scope | Status |
|---|------|-------|--------|
| 1 | {rule} | {scope} | new / already captured |

## What Went Well

- {Specific thing that worked — be concrete, not generic}

## What to Improve

- {Specific thing to do differently — actionable, not vague}

## Open Questions

- {Anything unresolved that should be addressed in the next project}
```

## Step 6: Wrap Up

```bash
qmd update 2>/dev/null || true
```

Print:
```
Retro complete: {title}
Report: workspace/reports/{slug}-retro.md
Patterns detected: {N}
New learnings: {N} (run /learn to capture)
```

---

## Rules

- **Read-only analysis** — retro does not modify project files, prd.json, or board.json. It writes only its own report
- **Evidence-backed patterns only** — do not flag patterns without specific data points from Steps 1-2
- **Delegate learning capture** — suggest `/learn`, do not write policy files directly
- **No re-capture** — check existing policies before proposing a learning. Duplicates waste context
- **Both modes are valid** — SESSION mode is lighter but still valuable. Not every retro needs a full project
- **Company isolation** — scope all data collection to the resolved company. Never mix cross-company data
- **Do NOT create task lists or enter planning mode** — this is a focused analysis, not a project
- **Honest assessment** — if a project went poorly, say so. Retros that only praise are useless
- **Actionable over comprehensive** — 3 concrete learnings beat 10 vague observations
