---
id: ai-velocity-time-sense
enforcement: hard
scope: global
tags: [planning, brainstorm, prd, estimates, time, velocity, run-project, handoff]
public: true
created: 2026-05-23
provenance: user-correction
---

## Rule

HQ runs at agent velocity, not solo-human-developer velocity, and it runs many sessions concurrently. A body of work that a single human developer would frame as "a year" routinely completes in roughly a week of HQ operation, and independent tracks run in parallel. Because of this, **human-developer wall-clock estimates are systematically wrong by one to two orders of magnitude and must never be emitted in planning artifacts.** Treat any calendar-time effort estimate ("a few weeks", "this is a multi-week migration", "month+") produced during brainstorming, planning, or PRD authoring as a defect.

This policy replaces calendar-time estimation with two decoupled signals, because "how much work this is" and "how long until it is done" are different questions and only the second one collapses under concurrency.

### 1. Complexity — scope and risk, never time

Effort sizing (`S / M / L / XL`) describes the intrinsic shape of the work: how many seams it touches, how much is unknown, how reversible it is. It must not be anchored to calendar duration.

- **S** — one clear change, one seam, low risk, well-understood.
- **M** — a few related changes, one subsystem, modest unknowns.
- **L** — multiple seams or subsystems, real unknowns, some irreversible steps.
- **XL** — cross-cutting, many seams, significant unknowns, hard-to-reverse decisions.

If you find yourself reaching for "weeks" or "months" to justify an XL, stop: the right justification is breadth and risk, not clock time.

### 2. Throughput — sessions and concurrency

When a sense of "how long" is genuinely needed, express it in the unit HQ actually works in: **agent-sessions, plus whether the work parallelizes.** For example: "~3 sessions, 2 concurrent-able" or "1 session, sequential". This is honest about the fact that HQ can fan work out across simultaneous sessions, which calendar time cannot represent.

### 3. Real clock-time lives only in the measured estimate-log

The only place in HQ where real wall-clock duration is legitimate is the empirical estimate subsystem (`/track-estimate`, `/finish-estimate`, `/calibration-report`, `workspace/estimate-log/log.jsonl`). That data is *measured*, not guessed, and it is what proves the velocity rather than asserting it. Planning artifacts may reference measured calibration data; they may not invent calendar estimates.

### Scope of enforcement

Applies to: `/brainstorm`, `/plan`, `/prd`, `/deep-plan`, `/idea`, `/strategize`, `/run-project`, `/execute-task`, `/handoff`, `/checkpoint`, `/retro`, and any agent-authored artifact (`brainstorm.md`, `prd.json`, README, handoff threads, retros) that would otherwise state effort or remaining work.

Does **not** apply to: genuine external deadlines supplied by the user (a real ship date, a customer commitment, a scheduled event), measured durations in the estimate-log, or descriptive references to past calendar events. Those are facts, not estimates — pass them through verbatim.

### Rationale

A solo-developer mental model bakes calendar time into effort sizing (the prior brainstorm rubric literally defined "S" as "hours-days"). With agent velocity and concurrent sessions, that framing produces estimates that are both wrong and misleading in customer- and team-facing artifacts. Decoupling intrinsic complexity from elapsed throughput, and confining real clock-time to measured data, keeps HQ's sense of time aligned with how HQ actually executes.
