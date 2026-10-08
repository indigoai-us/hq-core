---
description: Discovery interview question set for the prd skill, run by the grilling engine. Covers the former Batches 1 to 7.
---

# PRD Question Set

Read by the grilling engine from the prd skill's Step 4. Format: `FORMAT.md` in this directory. Ids keep the old batch numbers (`Q-1a` was Batch 1 question 1a) so brainstorm answers and journals stay comparable.

The engine asks one question per AskUserQuestion call. Every decision also accepts free text through the picker's Other field; open-ended questions list common answers as options.

Conditional batches are `depends_on` edges on the `project_type` fact. The engine resolves `project_type` from the description, `repoPath`, and the answers to Q-1a, Q-2b, and Q-3a, then applies each question's `applies_to` list:

- `code`: has a repoPath, or code/app/API/feature keywords. Every question applies.
- `content`: content, knowledge, or report work. Questions without `content` in `applies_to` are skipped.
- `hq-tooling`: personal or HQ tooling. Questions without `hq-tooling` in `applies_to` are skipped.

Questions with no `applies_to` line apply to every project type. A skipped question takes its recommended option, is logged as `(skipped, {project_type})`, and is not counted under `asked`.

## Pre-fill hints

`prefill:` lines replace the old Dynamic Question Enrichment section. Before asking, apply each hint whose source matches the Step 2 scan or the brainstorm:

- Put the detected detail into the question text or the matching option label, for example "Auth model? (repo uses Clerk)".
- If a hint fully answers the question, add the question to `known_facts` with the detected answer and its source. It is not asked.
- State any `enforcement: hard` company policy that constrains architecture, auth, or integrations in the text of the relevant question.

## Q-1a
Core problem or goal?

- tier: strategic
- kind: decision
- depends_on: []
- options: New capability | Fix a broken flow | Replace a manual process | Reduce cost or risk
- recommended: New capability
- prefill: brainstorm Context and Recommendation sections

## Q-1b
What does success look like (measurable metric or verifiable state)?

- tier: strategic
- kind: decision
- depends_on: [Q-1a]
- options: Metric moves by a target | Verifiable state reached | User can complete a flow
- recommended: Verifiable state reached
- prefill: brainstorm Recommendation section

## Q-1c
Who benefits?

- tier: strategic
- kind: decision
- depends_on: [Q-1a]
- options: Internal team | Customers | Both | Developers only
- recommended: Internal team

## Q-2a
Who are the primary users?

- tier: strategic
- kind: decision
- depends_on: []
- options: Internal or admin only | External customers | Both internal and external | Developer tooling
- recommended: Internal or admin only
- prefill: brainstorm audience mentions

## Q-2b
What exists today?

- tier: strategic
- kind: decision
- depends_on: []
- options: Nothing (greenfield) | Existing feature being upgraded | Manual process being automated | Third-party tool being replaced
- recommended: Nothing (greenfield)
- prefill: brainstorm current-solution mentions

## Q-2c
Reference designs, mockups, or brand constraints?

- tier: architecture
- kind: decision
- depends_on: [Q-2a]
- options: Figma file exists | Follow existing design system | No design constraints | Not a UI project
- recommended: Follow existing design system
- prefill: company brand or design-system policy, or the repo component library, named in the design-system option

## Q-3a
What is in scope for the MVP?

- tier: strategic
- kind: decision
- depends_on: [Q-1a]
- options: Smallest end-to-end slice | Full feature set | Spike or prototype only
- recommended: Smallest end-to-end slice
- prefill: brainstorm recommended approach

## Q-3b
Hard constraints (time, tech, budget)?

- tier: strategic
- kind: decision
- depends_on: []
- options: None | Tech stack fixed | Deadline | Budget cap
- recommended: None
- prefill: brainstorm constraints and What We Don't Know section

## Q-3c
Dependencies on other projects?

- tier: architecture
- kind: decision
- depends_on: []
- options: None | Blocked by another project | Blocks another project
- recommended: None

## Q-3d
What is explicitly not in scope (non-goals)?

- tier: strategic
- kind: decision
- depends_on: [Q-3a]
- options: None | List non-goals
- recommended: List non-goals
- prefill: brainstorm rejected approaches

## project_type
Project type that gates Batches 4 to 6: code, content, or hq-tooling.

- tier: architecture
- kind: fact
- depends_on: [Q-1a, Q-2b, Q-3a]

## Q-4a
Key data entities (tables, columns, domain objects)?

- tier: architecture
- kind: decision
- depends_on: [project_type]
- options: No data changes | New table or entity | Change existing entities
- recommended: No data changes
- applies_to: code, hq-tooling
- prefill: repo ORM or database named in the question text

## Q-4b
Auth or permissions model?

- tier: architecture
- kind: decision
- depends_on: [project_type]
- options: Existing auth, no changes | New role or permission | New auth provider | No auth
- recommended: Existing auth, no changes
- applies_to: code, hq-tooling
- prefill: repo auth system named in the first option; a hard auth policy stated in the question

## Q-4c
Architecture approach?

- tier: architecture
- kind: decision
- depends_on: [project_type]
- options: Follow existing repo patterns | New pattern needed | Let workers decide
- recommended: Follow existing repo patterns
- applies_to: code, hq-tooling

## Q-4d
Performance requirements?

- tier: quality
- kind: decision
- depends_on: [project_type]
- options: Standard | Latency target | Throughput target | Low-bandwidth
- recommended: Standard
- applies_to: code
- prefill: known as Standard unless the description has real-time, scale, latency, or throughput keywords

## Q-5a
External integrations or third-party APIs?

- tier: architecture
- kind: decision
- depends_on: [project_type]
- options: None | Existing integrations | New integration needed
- recommended: None
- applies_to: code, hq-tooling
- prefill: manifest services and existing integrations listed in the existing-integrations option

## Q-5b
Sensitive data or security considerations?

- tier: quality
- kind: decision
- depends_on: [project_type]
- options: No PII | PII under existing compliance | New compliance requirement | Abuse protection needed
- recommended: No PII
- applies_to: code
- prefill: always asked when a company policy mentions PII, GDPR, or compliance

## Q-5c
Rollout strategy?

- tier: quality
- kind: decision
- depends_on: [project_type]
- options: Ship to all users | Feature flag | Staged rollout | Internal first
- recommended: Ship to all users
- applies_to: code
- prefill: a company feature-flag or rollout policy makes this known; manifest vercel_team named in the text

## Q-6a
Quality gates?

- tier: quality
- kind: decision
- depends_on: []
- options: Detected repo commands | Typecheck and lint | None | Other
- recommended: Detected repo commands
- prefill: repo test, lint, and typecheck commands from the scan; company deploy procedures

## Q-6b
Use the relevant workers found in the scan?

- tier: architecture
- kind: decision
- depends_on: []
- options: Yes, use scanned workers | Pick different workers | No workers
- recommended: Yes, use scanned workers

## Q-6c
Does this need a new worker or skill?

- tier: architecture
- kind: decision
- depends_on: []
- options: No | New worker | New skill
- recommended: No

## Q-6d
Repo path?

- tier: architecture
- kind: decision
- depends_on: [project_type]
- options: Detected repo | Different repo | None (non-code)
- recommended: Detected repo

## Q-6e
Branch name?

- tier: architecture
- kind: decision
- depends_on: [Q-6d]
- options: feature/{project-name} | Other
- recommended: feature/{project-name}

## Q-6f
Base branch?

- tier: architecture
- kind: decision
- depends_on: [Q-6d]
- options: main | staging | Other
- recommended: main

## Q-6g
Analytics or event tracking needed?

- tier: quality
- kind: decision
- depends_on: [project_type]
- options: No | Existing tracking system | New tracking events | Tracking stub only
- recommended: No
- applies_to: code
- prefill: repo analytics system named in the existing-system option

## Q-6h
How do we know it works in production?

- tier: quality
- kind: decision
- depends_on: [project_type]
- options: Manual testing only | Existing monitoring covers it | New health check or alert | Metric in existing dashboard
- recommended: Existing monitoring covers it
- applies_to: code
- prefill: repo monitoring service named in the existing-monitoring option

## Q-7a
What E2E tests verify each story works?

- tier: quality
- kind: decision
- depends_on: [project_type]
- options: Page or flow tests | API response tests | CLI run tests | None (non-deployable)
- recommended: Page or flow tests
