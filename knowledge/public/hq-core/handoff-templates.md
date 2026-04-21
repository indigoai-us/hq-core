# Handoff Templates

Typed handoff documents for structured inter-agent communication. Adapted from NEXUS coordination protocol.

## When to Use

| Situation | Template |
|-----------|----------|
| Normal task completion → next agent | Standard Handoff |
| QA passes a story | QA PASS |
| QA fails a story | QA FAIL |
| 3 failed attempts on same task | Escalation Report |
| Project phase complete → next phase | Phase Gate |
| Sprint/batch complete | Sprint Handoff |
| Incident or outage | Incident Handoff |

---

## 1. Standard Handoff

```markdown
## Handoff: {task_id}
| Field | Value |
|-------|-------|
| From | {agent/worker name} |
| To | {next agent/worker name} |
| Phase | {current phase} |
| Task | {task description} |
| Status | Complete |

### Context
{1-2 sentences on what was done and why}

### Deliverables
- {file path or artifact}: {description}

### Quality Expectations
- {what the next agent should verify}
- {acceptance criteria to meet}
```

---

## 2. QA PASS

```markdown
## QA PASS: {story_id}
**Verdict: PASSED**
**Grade: {C+ / B- / B / B+}**
**Tester: {qa-tester / reality-checker}**

### Evidence
| # | Check | Result | Evidence |
|---|-------|--------|----------|
| 1 | Page load | ✅ 200 OK, 1.2s | screenshot-001.png |
| 2 | Mobile responsive | ✅ No overflow | screenshot-002.png |
| 3 | Console errors | ✅ None | screenshot-003.png |

### Acceptance Criteria
- [x] {criterion 1} — verified via {evidence}
- [x] {criterion 2} — verified via {evidence}

### Next Action
Proceed to: {next phase / mark story done / reality-checker review}
```

---

## 3. QA FAIL

```markdown
## QA FAIL: {story_id}
**Verdict: FAILED**
**Attempt: {1 / 2 / 3} of 3**
**Tester: {qa-tester / reality-checker}**

### Issues Found
| # | Category | Severity | Expected | Actual | Evidence | Fix Instruction | File Path |
|---|----------|----------|----------|--------|----------|-----------------|-----------|
| 1 | Layout | critical | No horizontal scroll on mobile | 50px overflow on 375px | screenshot-001.png | Add `overflow-x: hidden` or fix flex layout | src/components/Hero.tsx |
| 2 | Console | serious | No JS errors | TypeError on route change | screenshot-002.png | Add null check on router param | src/pages/[slug].tsx |

### Retry Instructions
1. Fix issues #{list} above
2. Rebuild and verify locally
3. Re-run QA with: `/run qa-tester smoke-test --url {url}`

### Previous Attempts (if attempt > 1)
- Attempt 1: {what was fixed} → {what still failed}
- Attempt 2: {what was fixed} → {what still failed}
```

---

## 4. Escalation Report

Used after 3 failed QA attempts on the same task.

```markdown
## ESCALATION: {story_id}
**Severity: Blocked after 3 attempts**
**Escalated by: {agent name}**

### Attempt History
| Attempt | Fixes Applied | Remaining Issues | Root Cause Hypothesis |
|---------|---------------|------------------|----------------------|
| 1 | {fixes} | {issues} | {hypothesis} |
| 2 | {fixes} | {issues} | {hypothesis} |
| 3 | {fixes} | {issues} | {hypothesis} |

### Root Cause Analysis
{Why this keeps failing. Is it a design problem? Missing dependency? Wrong approach?}

### Resolution Options
1. **Reassign**: Different developer may see the issue differently
2. **Decompose**: Break into smaller subtasks, fix incrementally
3. **Revise approach**: Fundamental approach is wrong, need new strategy
4. **Accept with limitations**: Document known issues, ship with workaround
5. **Defer**: Move to next sprint, needs more research

### Impact
- Blocks: {what is blocked by this failure}
- Timeline impact: {how this affects the project schedule}

### Decision Required
{Who needs to decide, and what are they deciding between}
```

---

## 5. Phase Gate Handoff

Used when a project phase completes and the next phase begins.

```markdown
## Phase Gate: {phase_name} → {next_phase_name}
**Project: {project_name}**
**Date: {date}**

### Gate Criteria
| Criterion | Result | Threshold | Status |
|-----------|--------|-----------|--------|
| All stories complete | 8/8 | 100% | ✅ |
| QA pass rate | 85% | ≥ 80% | ✅ |
| No critical bugs | 0 | 0 | ✅ |
| Performance baseline | LCP 2.1s | ≤ 2.5s | ✅ |

### Documents Carried Forward
- PRD: {path}
- Architecture doc: {path}
- Test results: {path}

### Risks Carried Forward
| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| {risk} | {H/M/L} | {H/M/L} | {plan} |

### Next Phase Activation
Workers to activate: {list of workers for next phase}
```

---

## 6. Sprint Handoff

Used at end of a sprint or batch of tasks.

```markdown
## Sprint Handoff: {sprint_name}
**Project: {project_name}**
**Period: {start_date} → {end_date}**

### Completion Status
| Story | Status | Attempts | Assignee |
|-------|--------|----------|----------|
| US-001 | ✅ Done | 1 | backend-dev |
| US-002 | ✅ Done | 2 | frontend-dev |
| US-003 | ⏳ Carried | 3 (escalated) | — |

### QA Metrics
- First-pass rate: {X}%
- Average retries: {N}
- Escalations: {N}

### Retrospective
- **What worked**: {pattern that should continue}
- **What didn't**: {pattern that should change}
- **Action item**: {specific improvement for next sprint}

### Next Sprint Preview
- Stories queued: {list}
- Expected blockers: {list}
- Workers needed: {list}
```

---

## 7. Incident Handoff

Used during incidents or outages when handing off to another responder.

```markdown
## Incident Handoff: {incident_id}
**Severity: {P0 / P1 / P2 / P3}**
**Status: {Investigating / Mitigating / Resolved / Monitoring}**
**Handoff from: {name}** → **To: {name}**

### Timeline
| Time | Event |
|------|-------|
| {time} | {what happened} |
| {time} | {what was done} |

### Current State
{What is happening right now. What is working, what is broken.}

### Actions Taken
1. {action} — result: {outcome}
2. {action} — result: {outcome}

### Next Actions Required
1. {what the next responder should do first}
2. {what to monitor}

### Stakeholder Communication
- Last update sent: {time}
- Next update due: {time}
- Cadence: every {N} minutes for {severity}
```
