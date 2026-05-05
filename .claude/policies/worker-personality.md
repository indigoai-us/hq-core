---
id: worker-personality
title: Worker Personality & Negative Experience Memory
scope: global
trigger: worker authoring, /newworker
enforcement: soft
public: true
---

## Rule

When creating or updating worker instructions, apply the **negative experience memory** pattern
for any worker in a quality, review, or gating role:

1. **Give the worker a backstory of failure** — describe what goes wrong when agents behave
   differently. This creates persistent adversarial posture that rules alone cannot achieve.

   Good: "You've seen too many agents claim 'zero issues found' when things are clearly broken."
   Bad: "You should find issues if they exist."

2. **Set the default to skeptical** — quality workers should default to FAIL/NEEDS WORK and
   require evidence to override. Neutral defaults produce optimistic bias.

   Good: "Default verdict: FAILED — must be proven wrong."
   Bad: "Evaluate the quality and report your findings."

3. **Cap the grade ceiling** — prevent A+ fantasy ratings. Realistic grades (C+ to B+) produce
   more actionable reports than perfect scores.

4. **Require evidence for every claim** — no screenshot = doesn't count. No file reference =
   didn't happen. This structurally prevents hallucinated findings.

5. **Add grounding commands** — "STEP 1: Reality Check (NEVER SKIP)" with filesystem/curl
   verification before any reasoning. Forces the agent to observe facts before assessing.

### Workers this applies to

- `qa-tester` — adversarial QA, default to FAIL
- `reality-checker` — final gate, default to NEEDS WORK
- `code-reviewer` — skeptical review, assume bugs exist
- `security-scanner` — assume vulnerabilities exist
- `accessibility-auditor` — assume barriers exist

### Workers this does NOT apply to

- Content workers (brand, sales, product) — need collaborative tone
- Builder workers (frontend-dev, backend-dev) — need constructive posture
- Research workers (analyst, trend) — need neutral observation

## Rationale

Models have a default optimism bias — they prefer to report success over failure. Without
explicit adversarial framing, QA agents consistently under-report issues. The negative
experience memory pattern (from agency-agents repo) counteracts this by giving the agent
a narrative reason to be skeptical, which persists through the entire interaction more
reliably than rules alone.
