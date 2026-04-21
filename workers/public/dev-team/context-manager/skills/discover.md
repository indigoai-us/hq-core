# discover

Discover and extract project context from various sources.

## Arguments

`$ARGUMENTS` = `--project <name>` (required) `--mode <mode>` (optional)

Modes:
- `automatic` (default) - Analyze repo structure and extract context
- `conversational` - Interview user to gather context
- `manual` - User provides content directly

Optional:
- `--repo <path>` - Path to target repository (defaults to project's target_repo from PRD)
- `--update` - Update existing context instead of overwriting (merge new info)

## Process

### Mode: automatic (Repo Analysis)

#### Step 1: Locate Repository

```
1. Read projects/{project}/prd.json
2. Extract target_repo path
3. If --repo provided, use that instead
4. Verify path exists and is accessible
```

#### Step 2: Analyze Repository Sources

Read and analyze these files in order of priority:

**Primary Sources (read first):**
| File | What to Extract |
|------|-----------------|
| `README.md` / `README.rst` | Purpose, goals, setup instructions, architecture overview |
| `package.json` | Name, description, dependencies, scripts, engines |
| `pyproject.toml` | Name, description, dependencies, Python version |
| `Cargo.toml` | Name, description, dependencies, Rust edition |
| `go.mod` | Module name, Go version, dependencies |
| `composer.json` | PHP package info, dependencies |

**Structure Sources:**
| Source | What to Extract |
|--------|-----------------|
| Top-level directories | Architecture patterns (src/, lib/, tests/, docs/) |
| `src/` or `lib/` structure | Code organization, module boundaries |
| `docs/` | Additional context, ADRs, guides |
| `.github/` | CI/CD patterns, workflows |

**Configuration Sources:**
| File | What to Extract |
|------|-----------------|
| `.env.example` | Required environment variables, external services |
| `docker-compose.yml` | Service dependencies, infrastructure |
| `config/` directory | Configuration structure, environments |
| `*.config.js/ts` | Build tools, framework config |

**Code Sources (sample, don't read everything):**
| Source | What to Extract |
|--------|-----------------|
| Type definitions (`*.d.ts`, `types/`) | Domain models |
| API routes | Endpoints, resources |
| Database schemas/migrations | Data models |
| Test file names | Business rules, edge cases |

#### Step 3: Map Extractions to Context Files

**overview.md mapping:**
```
Purpose:
  - README first paragraph or "Description" section
  - package.json "description" field

Goals:
  - README "Goals" or "Objectives" section
  - Infer from feature list if explicit goals missing

Non-Goals:
  - README "Non-Goals" or "Out of Scope" section
  - If missing, leave as "Not yet documented"

Current State:
  - README badges (build status, version)
  - package.json version (0.x = early, 1.x+ = stable)
  - Check for "Alpha", "Beta", "WIP" mentions
```

**architecture.md mapping:**
```
Stack:
  - Language: Detect from package.json/pyproject.toml/Cargo.toml
  - Framework: Top dependencies (react, next, django, fastapi, etc.)
  - Database: Look for db drivers, ORM packages, docker-compose
  - Hosting: Check for vercel.json, netlify.toml, Dockerfile

Structure:
  - Map actual directory tree (top 2 levels)
  - Note patterns: monorepo, src/lib split, feature folders

Patterns:
  - Component libraries → composition pattern
  - Redux/Zustand → centralized state
  - tRPC/GraphQL → typed API pattern

Dependencies:
  - External services from .env.example
  - Key libraries from package.json (non-dev)

Configuration:
  - Required env vars from .env.example
  - Config file locations
```

**domain.md mapping:**
```
Glossary:
  - Type/interface names from definitions
  - README terminology
  - Database table/model names

Concepts:
  - Main types and their relationships
  - Entity names from models

Rules:
  - Validation logic from schemas
  - Business rules from test descriptions
  - Constraints from database schemas
```

#### Step 4: Generate Drafts

For each context file:
1. Copy template from `knowledge/project-context/templates/{file}.md`
2. Replace placeholders with extracted content
3. Mark uncertain content with `[NEEDS REVIEW]`
4. Set frontmatter:
   ```yaml
   ---
   last_updated: {today}
   last_verified: {today}
   verified_by: context-manager
   source: automatic
   ---
   ```

#### Step 5: Present Drafts for Review

Show the user each draft file:
```
## Draft: overview.md

{content}

---
Questions:
1. Is the Purpose accurate?
2. Are there Goals I missed?
3. Should I add anything to Non-Goals?

[Accept] [Edit] [Regenerate]
```

Use `AskUserQuestion` to get approval or edits for each file.

#### Step 6: Write Context Files

1. Create `projects/{project}/context/` directory if needed
2. Write approved files
3. Create optional `context.yaml` manifest:
   ```yaml
   project: {project}
   source: automatic
   generated_at: {timestamp}
   files:
     overview: context/overview.md
     architecture: context/architecture.md
     domain: context/domain.md
   ```

### Incremental Mode (--update)

When `--update` flag is provided:

1. Read existing context files from `projects/{project}/context/`
2. Compare with newly extracted content
3. For each section:
   - If new info found → append with `[NEWLY DISCOVERED]` marker
   - If existing info conflicts → flag with `[CONFLICT - VERIFY]`
   - If existing info unchanged → keep as-is
4. Present diff view to user showing additions/changes
5. Update `last_updated` but keep original `verified_by` if unchanged
6. Write merged content after approval

### Mode: conversational

Interview the user to gather project context through guided conversation.

#### Step 1: Introduction and Prep

Introduce the interview process:

```
I'll help you document project context through a short interview.
We'll cover three areas:
1. **Overview** - Purpose, goals, and current state
2. **Architecture** - Tech stack, structure, and patterns
3. **Domain** - Key terms, concepts, and business rules

For each section, I'll ask 2-3 questions. You can:
- Answer in as much or little detail as you like
- Paste existing docs or specs if you have them
- Say "skip" to move to the next question
- Say "paste docs" to provide existing documentation

Ready? Let's start with the Overview.
```

#### Step 2: Overview Interview

Ask these questions using `AskUserQuestion` with batched options:

**Question 1: Purpose**
```
What problem does this project solve?

Options:
- "It solves..." [free text]
- "I have docs to paste" [triggers paste flow]
- "Skip this question"
```

If user selects "I have docs to paste":
```
Paste your existing documentation below. I'll extract the relevant information.
This could be: README, product spec, pitch deck, Slack messages, etc.

[Text area for paste]
```

**Question 2: Goals**
```
What are the main goals for this project? (List 3-5)

Options:
- "The goals are..." [free text]
- "Same as what's in PRD" [read from prd.json]
- "Skip this question"
```

**Question 3: Non-Goals & State**
```
What is explicitly OUT of scope? And what's the current project state?

Options:
- "Non-goals: ... / State: ..." [free text]
- "No non-goals defined yet"
- "Skip this question"
```

#### Step 3: Architecture Interview

**Question 4: Tech Stack**
```
What technologies power this project?

Think about: Language, Framework, Database, Hosting, Key libraries

Options:
- "We use..." [free text]
- "I have a README/package.json to paste" [triggers paste flow]
- "You can analyze the repo" [switch to automatic for this section]
- "Skip this question"
```

**Question 5: Structure & Patterns**
```
How is the codebase organized? Any architectural patterns to know about?

Examples: "Monorepo with packages/", "Feature-folder structure", "MVC pattern"

Options:
- "It's organized as..." [free text]
- "Standard structure for [framework]"
- "Skip this question"
```

**Question 6: Dependencies**
```
What external services or APIs does this project depend on?

Think about: Databases, Auth providers, Payment systems, APIs

Options:
- "We depend on..." [free text]
- "Check .env.example" [read from repo if available]
- "No external dependencies"
- "Skip this question"
```

#### Step 4: Domain Interview

**Question 7: Glossary**
```
What domain-specific terms should workers know?

Include: Jargon, abbreviations, terms with special meaning in this project

Options:
- "Key terms: ..." [free text]
- "I have a glossary/wiki to paste" [triggers paste flow]
- "Skip this question"
```

**Question 8: Core Concepts**
```
What are the main entities or concepts in the system?

Examples: "Users, Teams, Projects", "Orders, Products, Inventory"

Options:
- "Core concepts: ..." [free text]
- "You can infer from the types/models" [switch to automatic]
- "Skip this question"
```

**Question 9: Business Rules**
```
What rules govern how things work? Any constraints or edge cases?

Examples: "Users can only join 5 teams", "Orders require 24h notice"

Options:
- "Rules: ..." [free text]
- "Check the validation code" [switch to automatic]
- "Skip this question"
```

#### Step 5: Process Pasted Content

When user pastes existing documentation:

1. Identify the document type (README, spec, design doc, etc.)
2. Extract relevant sections based on current context file
3. Present extracted content for confirmation:

```
From your pasted [document type], I extracted:

**For Overview:**
- Purpose: {extracted}
- Goals: {extracted}

Is this accurate? [Accept] [Edit] [Discard]
```

Extraction rules by document type:

| Source Type | Extract For |
|-------------|-------------|
| README.md | Purpose, Goals, Stack, Setup |
| Product Spec | Purpose, Goals, Non-Goals, Concepts |
| Design Doc | Architecture, Patterns, Data Flow |
| API Spec | Domain concepts, Rules |
| Wiki/Confluence | Glossary, Concepts, Rules |
| Slack/Notes | Any relevant context (mark as informal source) |

#### Step 6: Generate Context Files

For each context file, compile responses:

**overview.md generation:**
```yaml
Purpose: {Q1 response or extracted from paste}
Goals: {Q2 response or from PRD}
Non-Goals: {Q3 non-goals portion}
Current State: {Q3 state portion or "Not specified"}
```

**architecture.md generation:**
```yaml
Stack: {Q4 response, structured into table}
Structure: {Q5 response}
Dependencies: {Q6 response}
Patterns: {inferred from Q5 if mentioned}
```

**domain.md generation:**
```yaml
Glossary: {Q7 response, formatted as table}
Concepts: {Q8 response, structured with relationships}
Rules: {Q9 response, formatted with rationale}
```

Set frontmatter for all files:
```yaml
---
last_updated: {today}
last_verified: {today}
verified_by: {user or context-manager}
source: conversational
source_details:
  interview_date: {today}
  pasted_docs: [list of doc types pasted]
  sections_skipped: [list of skipped sections]
---
```

#### Step 7: Review and Confirm

Present each generated file for review:

```
## Generated: overview.md

{generated content}

---
Sources used:
- Interview response (Q1, Q2, Q3)
- Pasted README excerpt

[Accept] [Edit] [Regenerate from scratch]
```

Use `AskUserQuestion` for each file. If user selects "Edit":
- Show the content in a code block
- Ask what to change
- Apply changes and re-present

#### Step 8: Write Files and Summarize

1. Create `projects/{project}/context/` directory
2. Write all approved files
3. Create summary:

```
## Context Discovery Complete

Created context files for {project}:
- ✅ overview.md (from interview + README paste)
- ✅ architecture.md (from interview)
- ✅ domain.md (from interview, 1 section skipped)

Source breakdown:
- Interview responses: 7 questions answered
- Pasted documents: 1 (README.md)
- Skipped sections: 2

Next steps:
1. Review files in projects/{project}/context/
2. Run `discover --mode automatic --update` to enrich from repo
3. Run `audit` periodically to check freshness
```

#### Hybrid Mode Tip

If user selects "analyze the repo" or "check .env.example" during interview:

1. Pause interview for that section
2. Run automatic extraction for just that section
3. Present extracted content in interview flow
4. Continue with next question

This creates a hybrid discovery combining user knowledge with repo analysis.

### Mode: manual

1. Present context file templates
2. User fills in content directly
3. Validate against schema
4. Write to `projects/{project}/context/`

## Sources Analyzed

| Source | Extracts |
|--------|----------|
| README.md | Purpose, goals, overview |
| package.json | Stack, dependencies, scripts |
| Directory structure | Architecture patterns |
| .env.example | External dependencies |
| Code comments | Domain concepts, rules |
| API schemas | Domain models |
| Test files | Business rules, edge cases |

## Output

- `projects/{project}/context/overview.md`
- `projects/{project}/context/architecture.md`
- `projects/{project}/context/domain.md`
- `projects/{project}/context/decisions.md` (if ADRs found)
- `projects/{project}/context/stakeholders.md` (if info available)

Each file includes frontmatter:
```yaml
---
last_updated: YYYY-MM-DD
last_verified: YYYY-MM-DD
verified_by: context-manager
source: automatic|conversational|manual
---
```

## Human Checkpoints

- Review draft context before writing
- Confirm accuracy of extracted information
- Approve any inferred content

## Verification

After completion:
1. All required files exist (overview, architecture, domain)
2. Files have valid frontmatter
3. Context can be validated if context.yaml exists
