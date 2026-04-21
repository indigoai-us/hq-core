---
type: guide
domain: [engineering, operations]
status: canonical
tags: [agents-md, claude-md, configuration, project-context, ai-agent]
relates_to: []
---

# agents.md Guide

## What is agents.md?

`agents.md` (also known as `CLAUDE.md`, `AGENTS.md`, or project-specific names) is a configuration file that provides context and instructions to AI coding agents. It's the "brain" that guides how the agent behaves in your project.

> "We're going to go into the realm of agents.md. We're going to go into the history of agents.md, how it came to be. We're going to look into the problems of agents.md."
> — Geoffrey Huntley

## History

The concept evolved from:
1. README files providing project context
2. .editorconfig for editor settings
3. Cursor rules and similar tool-specific configs
4. Standardized agent instructions

## Common Problems

### 1. Over-Specification

Loading too much into agents.md causes context bloat:

> "I typically... if I'm looking at this because I've co-generated this, I would delete the specifications completely because when I'm routing I essentially malloc those specifications myself. I want high control of that mallocing."
> — Geoffrey Huntley

**Solution**: Keep agents.md minimal. Load specs separately.

### 2. Conflicting Instructions

Multiple ways to do things confuse the agent:

> "Here I have essentially two different ways to build the application, one for Rust, one for web. I don't like this to be honest."
> — Geoffrey Huntley

**Solution**: One clear path for each action.

### 3. Static Context

agents.md loaded once at start becomes stale.

**Solution**: Use dynamic loading and routing.

### 4. Too Much History

Including change logs and old patterns:

**Solution**: Focus on current state and patterns.

## Structure of a Good agents.md

```markdown
# Project: [Name]

## Overview
[1-2 sentences about what this project does]

## Tech Stack
- Language: TypeScript
- Framework: React
- Testing: Jest + React Testing Library
- Build: Vite

## Directory Structure
```
src/
  components/    # React components
  hooks/         # Custom hooks
  utils/         # Utility functions
  types/         # TypeScript types
tests/           # Test files
```

## Commands
- `npm run dev` - Start development server
- `npm run build` - Production build
- `npm test` - Run tests
- `npm run lint` - Run linter
- `npm run typecheck` - Type check

## Coding Standards
- Use functional components with hooks
- All components must have tests
- Use TypeScript strict mode
- Maximum file length: 300 lines

## When Making Changes
1. Create a new branch
2. Make changes
3. Run `npm test`
4. Run `npm run lint`
5. Run `npm run typecheck`
6. Commit with conventional commit message

## Do NOT
- Modify package.json without approval
- Delete existing tests
- Use `any` type
- Skip type checking
```

## Mallocing vs. Static Loading

Geoffrey emphasizes controlled "mallocing" of context:

### Static Loading (Traditional)
```
Load agents.md → Use for entire session
```

Problems:
- Context rot over long sessions
- Irrelevant context for specific tasks
- Wasted context window space

### Dynamic Mallocing (Ralph)
```
Start task → Load only relevant specs → Complete → Clear → Repeat
```

Benefits:
- Fresh context per task
- Relevant information only
- Maximum context for actual work

## Integration with Ralph

In Ralph, agents.md provides:
1. **Base context** - Project structure, commands, standards
2. **Routing instructions** - How to pick and process tasks
3. **Back pressure commands** - How to verify work

Example Ralph-optimized agents.md:

```markdown
# agents.md for Ralph

## Project
Video editor built with TypeScript/React

## Task Loop
1. Read `plans/prd.json`
2. Find first item with `passes: false`
3. Implement ONLY that feature
4. Run: `npm test && npm run lint && npm run typecheck`
5. If all pass: commit and set `passes: true`
6. If any fail: fix and retry
7. Write progress to `progress.txt`

## Verification Commands
```bash
npm test           # Must pass
npm run lint       # Must have 0 warnings
npm run typecheck  # Must have 0 errors
npm run build      # Must succeed
```

## Commit Format
```
feat(scope): description

- Detail 1
- Detail 2

Implements: feature-id
```

## Important
- ONE feature per iteration
- ALWAYS run verification before commit
- NEVER skip tests
- NEVER modify multiple features at once
```

## Per-Task Context Loading

For larger projects, use task-specific context:

```
specs/
  feature-001.md    # Detailed spec for feature 1
  feature-002.md    # Detailed spec for feature 2
  ...
agents.md           # Base instructions (minimal)
```

Then instruct the agent:
```markdown
## Context Loading
When working on a feature:
1. Read `specs/{feature-id}.md` for detailed requirements
2. Do NOT load other spec files
3. Focus only on current task
```

## Anti-Patterns

### 1. Everything in agents.md
Don't put all specs, examples, and documentation in one file.

### 2. Contradictory Instructions
Don't say "use functional components" then show class examples.

### 3. Outdated Information
Don't include deprecated patterns or old APIs.

### 4. Too Verbose
Don't write paragraphs when bullets suffice.

### 5. No Verification Steps
Don't skip specifying how to verify changes work.

## Evolving agents.md

> "Approach it from a first principles point of view. Just lop it off, destroy it and create it again."
> — Geoffrey Huntley

Don't be precious about agents.md. Iterate:
1. Start minimal
2. Add as needed
3. Remove what doesn't work
4. Keep refining
