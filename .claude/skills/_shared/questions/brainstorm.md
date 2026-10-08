---
description: Interview question set for the brainstorm skill, run by the grilling engine. STARTUP and BUILDER sets branch on the mode fact.
---

# Brainstorm Question Set

Read by the grilling engine from the brainstorm skill's Step 3. Format: `FORMAT.md` in this directory.

The engine asks one question per AskUserQuestion call. Every decision also accepts free text through the picker's Other field.

The STARTUP and BUILDER sets are `depends_on` branches on the `Q-mode` fact, which Step 0.5 resolves. Each question's `applies_to` line names the mode it belongs to. A question whose `applies_to` excludes the resolved mode is skipped and not counted. Questions with no `applies_to` line apply to both modes.

Pre-fill options from the Step 2 research before asking. Placeholder options such as "yes / no / other" are not allowed. Answers are recorded in brainstorm.md under `## Interview Answers` as `Q-id: answer` lines, so the plan phase and `/prd` can load them as known facts.

## Q-mode
Brainstorm mode (STARTUP or BUILDER), resolved in Step 0.5.

- tier: strategic
- kind: fact
- depends_on: []

## Q-company
Which company? Resolved from the Step 0 anchor or cwd; asked only when neither resolves it.

- tier: strategic
- kind: fact
- depends_on: []

## Q-demand
Who has this problem badly enough to hack a workaround today?

- tier: strategic
- kind: decision
- depends_on: [Q-mode, Q-company]
- applies_to: startup
- options: A named person or team | A segment we have talked to | A hypothetical persona | Unknown, needs validation
- recommended: A named person or team

## Q-status-quo
What do they do right now?

- tier: strategic
- kind: decision
- depends_on: [Q-demand]
- applies_to: startup
- options: Nothing, problem ignored | Manual workaround | An existing tool | Unknown
- recommended: Manual workaround

## Q-wedge
Smallest starting point that delivers real value to one person?

- tier: strategic
- kind: decision
- depends_on: [Q-status-quo]
- applies_to: startup
- options: Candidate wedge 1 from research | Candidate wedge 2 from research | Candidate wedge 3 from research
- recommended: Candidate wedge 1 from research

## Q-framing
Which framing of the problem is right? Asked only when the input is under 15 words or ambiguous.

- tier: strategic
- kind: decision
- depends_on: [Q-mode, Q-company]
- applies_to: builder
- options: Reframing 1 from research | Reframing 2 from research | Reframing 3 from research
- recommended: Reframing 1 from research

## Q-integration
Which existing system does this touch first?

- tier: architecture
- kind: decision
- depends_on: [Q-framing]
- applies_to: builder
- options: Repo or worker 1 from research | Repo or worker 2 from research | Prior project from research
- recommended: Repo or worker 1 from research

## Q-direction
Direction?

- tier: strategic
- kind: decision
- depends_on: [Q-mode, Q-company]
- options: Speed to ship | Quality and durability | Exploration | Cost minimization
- recommended: Speed to ship

## Q-constraints
Hard constraints? Ask a free-text follow-up only when a constraint type is picked.

- tier: architecture
- kind: decision
- depends_on: [Q-direction]
- options: None | Timeline | Must use or avoid a technology | Budget ceiling
- recommended: None

## Q-success
What observable outcome would tell you this worked?

- tier: quality
- kind: decision
- depends_on: [Q-direction]
- options: A metric from research | A named user's adoption | A replaced tool | Other, describe
- recommended: A metric from research
