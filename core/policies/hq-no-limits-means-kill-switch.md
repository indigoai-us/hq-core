---
id: hq-no-limits-means-kill-switch
title: "\"No limits\" on a cost/throughput control = kill-switch, not zero protection"
when: unlimited
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-04-24
updated: 2026-04-24
source: session-learning
---

## Rule

ALWAYS translate "no limits" into a reactive kill-switch, not zero protection.

When the owner asks for a control to be removed (e.g. "no daily cost cap on agent spend", "no rate limit on tool invocations", "no throughput ceiling on worker dispatch"), the correct implementation is:

1. Remove the proactive enforcement (the cap, the rate limit, the ceiling).
2. Add a `system_flags`-style row (or equivalent durable toggle) that admins can flip to instantly halt the activity — e.g. `agent_coding_enabled = true`, `worker_dispatch_enabled = true`.
3. Wire the flag into every relevant entry point with a cheap check at call time (boolean lookup, single-row cached).
4. Expose an admin UI toggle (or CLI) that flips the flag in one click.
5. Document the flag's name, table, and flip mechanism in the PRD / README so the operator can find it under pressure.

Pattern codified in `maggie-self-coding` US-013.

## Rationale

"No limits" almost always means "I don't want to be the one enforcing a threshold" — not "I want the system to have zero recourse if things go sideways." The owner's intent is operator autonomy, not blind trust.

A hard cap encodes a threshold the system enforces unilaterally. It is inflexible: raising it requires a redeploy, lowering it risks tripping during legitimate spikes, and in practice it gets tuned until it's either too loose to matter or so tight that operators routinely override it.

A kill-switch flips the control surface: the normal path is wide-open (operator gets what they asked for), but a single toggle stops the activity cold when something anomalous happens. Cost: one boolean check per invocation, one row in `system_flags`, one admin UI button. Benefit: the operator keeps full control without the friction of threshold tuning, and the system retains a fast stop mechanism for incident response.

Alternatives considered:

- **Zero protection** (literally no mechanism): fails the "if this runs away, how do we stop it?" question at 3am. Never correct for anything that can spend money or trigger downstream writes.
- **Hard cap at a generous value**: fails because "generous" drifts — what was a 10x margin on typical usage becomes the floor once the workload grows. The cap will trip eventually, and at that point it's the cap that becomes the outage.
- **Kill-switch + generous cap**: overkill; the cap adds tuning work and failure modes without the kill-switch's benefits. Pick one layer.

## Anti-patterns

- Interpreting "no limits" literally and shipping with no stop mechanism at all → next incident has no response mechanism except redeploy.
- Replacing a cap with a larger cap "for safety" → same tuning failure mode, one step later.
- Building the kill-switch as a config-file flag requiring a redeploy to flip → not a kill-switch, just a cap with extra steps.
- Not exposing the flag in admin UI → operator can't use it under pressure, defeating the point.
