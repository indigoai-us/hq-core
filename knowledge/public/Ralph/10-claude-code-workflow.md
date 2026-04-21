---
type: guide
domain: [engineering]
status: canonical
tags: [claude-code, workflow, best-practices, matt-pocock, engineering]
relates_to: []
---

# Claude Code Workflow for Real Engineering

*Based on Matt Pocock's "How I use Claude Code for real engineering" video*

## Overview

This document covers Matt Pocock's practical workflow for using Claude Code on large, multi-phase coding projects. While not explicitly labeled as "Ralph," this workflow embodies Ralph principles: breaking work into phases, managing context windows, and using automated feedback loops.

**Video**: https://www.youtube.com/watch?v=kZ-zzHVUrO4
**Duration**: 10:11
**Published**: October 27, 2025
**Views**: 124K+

## Key Workflow Components

### 1. Starting with a Rough Dictated Prompt

> "The way I produced this was I just dictated into my microphone for a bit. I haven't really put too much thought into this."

Matt starts with a voice-dictated rough prompt describing what he wants to build. This is faster than typing and captures intent naturally.

### 2. Using Plan Mode

Claude Code's plan mode is essential for large projects:

> "This is actually a really good opportunity to show a complicated multi-phase plan with Claude Code."

**Plan Mode Benefits:**
- Explores the codebase before writing code
- Generates clarifying questions
- Breaks work into manageable phases
- Preserves context across resets

### 3. Multi-Phase Planning

For projects that exceed a single context window:

> "This is a pretty large feature that will go probably beyond a single context window."

**Approach:**
1. Create a comprehensive plan upfront
2. Break into numbered phases
3. Execute one phase at a time
4. Store plan in GitHub issues for persistence

### 4. Monitoring Context Usage

Matt emphasizes watching the context window:

> "So far we have 83.7% free space. That's feeling pretty good. We've only used about 33k tokens."

**Key Metrics:**
- Tokens used vs. available
- Free space percentage
- When to reset context

### 5. The Concision Rule

Matt's favorite custom rule:

> "Always be extremely concise. Sacrifice grammar for the sake of concision."

This keeps Claude's responses short, preserving context window space for actual work.

### 6. Auto-Accept Mode

For execution phases:

> "I'm going to swap to auto-accept and I'm going to say 'execute phase one.'"

**When to use:**
- During implementation (not planning)
- When you trust the plan
- For routine operations

**When NOT to use:**
- During exploration
- When making architectural decisions
- For critical/destructive operations

### 7. Custom Status Line

Matt customizes his terminal status to show:
- Current repo (relative to repos folder)
- Current branch
- Staged file count
- Unstaged file count
- New file count

This provides quick feedback without switching contexts.

### 8. Storing Plans as GitHub Issues

For large projects spanning multiple sessions:

> "My strategy of storing plans as GitHub issues to preserve them across context resets."

**Benefits:**
- Plans persist beyond context window
- Can reference in future sessions
- Creates documentation trail
- Allows collaboration

## The Complete Workflow

```
┌─────────────────────────────────────────┐
│  1. DICTATE ROUGH REQUIREMENTS          │
│     Voice → rough prompt text           │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  2. ENTER PLAN MODE                     │
│     /plan or plan mode command          │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  3. EXPLORATION PHASE                   │
│     - Claude reads codebase             │
│     - Asks clarifying questions         │
│     - Generates multi-phase plan        │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  4. STORE PLAN (Optional)               │
│     Create GitHub issue with plan       │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  5. EXECUTE PHASES                      │
│     - Enable auto-accept                │
│     - "Execute phase 1"                 │
│     - Monitor context usage             │
│     - Reset if needed, load plan        │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  6. VERIFY & ITERATE                    │
│     - Run tests/build                   │
│     - Review changes                    │
│     - Continue to next phase            │
└─────────────────────────────────────────┘
```

## Custom Rules Configuration

Matt uses custom rules in his Claude Code configuration:

```markdown
# Custom Rules

## Concision
Always be extremely concise. Sacrifice grammar for the sake of concision.

## Planning
When creating plans:
- Break into numbered phases
- Keep phases small enough for single context
- Include verification steps in each phase
- Add unresolved questions as separate items

## Context Management
- Monitor token usage regularly
- Warn when approaching 50% context used
- Suggest saving plan to issue when context getting full
```

## Relationship to Ralph

This workflow aligns with Ralph principles:

| Ralph Concept | Matt's Implementation |
|--------------|----------------------|
| Fresh context per task | Phase-by-phase execution with resets |
| Specifications | Multi-phase plan stored in GitHub |
| Back pressure | Build/test commands during execution |
| Small changes | Phases designed to fit context window |
| Automation | Auto-accept mode during implementation |

## Key Takeaways

1. **Plan before coding** - Exploration and planning phase is critical
2. **Monitor context** - Know when you're running out of space
3. **Persist plans** - GitHub issues survive context resets
4. **Be concise** - Every token matters
5. **Phase your work** - Big projects need multiple context windows
6. **Auto-accept wisely** - Trust but verify

## Practical Tips

### For Large Projects
- Always start in plan mode
- Create GitHub issue with full plan before starting
- Execute one phase at a time
- Reset context between phases if needed

### For Context Management
- Watch the token counter
- Use concise rules
- Don't let Claude write long explanations
- Save plan externally before context fills

### For Quality
- Keep build/test in auto-accept
- Review changes between phases
- Don't rush through verification
- Commit after each successful phase
