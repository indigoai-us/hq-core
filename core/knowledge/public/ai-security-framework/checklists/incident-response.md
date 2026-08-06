---
type: guide
domain: [operations, engineering]
status: canonical
tags: [incident-response, checklist, security, recovery, ai-automation]
relates_to: []
---

# Incident Response Checklist

> What to do when something goes wrong with AI automation

---

## Incident Severity Levels

| Level | Description | Examples | Response Time |
|-------|-------------|----------|---------------|
| **SEV 1** | Critical business impact | Credential theft, financial loss, data breach | Immediate |
| **SEV 2** | Significant impact | Unauthorized external comms, data exposure | Within 1 hour |
| **SEV 3** | Moderate impact | Wrong actions taken, minor data issues | Within 24 hours |
| **SEV 4** | Low impact | Near-misses, blocked attempts | Next business day |

---

## Immediate Response (First 5 Minutes)

### Step 1: Stop the Bleeding

- [ ] **KILL ALL AI ACTIVITY**
  - Close all AI browser tabs
  - Kill AI processes: `pkill -f claude`
  - Disconnect AI from network if needed

- [ ] **Document what you see NOW**
  - Screenshot current state
  - Note exact time
  - Record what triggered your response

- [ ] **Quick Assessment**
  - What did AI do?
  - What systems were affected?
  - Is it still happening?

### Step 2: Contain the Damage

**If credentials may be exposed:**
- [ ] Revoke affected tokens immediately
- [ ] Change passwords on critical accounts
- [ ] Enable additional MFA if available
- [ ] Check for active sessions and terminate

**If external communication was sent:**
- [ ] Document what was sent
- [ ] Document who received it
- [ ] Prepare correction/recall if possible
- [ ] Notify affected parties

**If data may have been accessed:**
- [ ] Document what data
- [ ] Document potential exposure scope
- [ ] Preserve access logs
- [ ] Consider notification requirements

---

## Short-Term Response (First Hour)

### Step 3: Gather Information

- [ ] **Pull all relevant logs**
  - AI action logs
  - Browser history
  - System access logs
  - Network logs (if available)

- [ ] **Timeline reconstruction**
  - When did the incident start?
  - What triggered it?
  - What actions did AI take?
  - When was it detected?
  - When was it stopped?

- [ ] **Impact assessment**
  - What systems were affected?
  - What data was accessed/modified?
  - Who was impacted?
  - What's the worst-case exposure?

### Step 4: Notify Stakeholders

**Internal notification (as appropriate):**
- [ ] Security team
- [ ] IT/Engineering
- [ ] Legal (if data breach possible)
- [ ] Management (if significant)

**External notification (if required):**
- [ ] Affected customers/users
- [ ] Regulators (if compliance-relevant)
- [ ] Partners (if shared systems affected)

---

## Investigation Phase (Hours to Days)

### Step 5: Root Cause Analysis

**Answer these questions:**

1. **What happened?**
   - Specific actions AI took
   - Sequence of events
   - Final outcome

2. **Why did it happen?**
   - Was it prompt injection?
   - Was it misconfiguration?
   - Was it a bug/unexpected behavior?
   - Was it a security control failure?

3. **How did it get past controls?**
   - Which controls should have caught it?
   - Why didn't they work?
   - Were controls missing?

4. **How was it detected?**
   - Was detection timely?
   - Could it have been detected earlier?
   - What monitoring would have helped?

### Root Cause Categories

| Category | Example | Fix |
|----------|---------|-----|
| Prompt Injection | Malicious webpage content | Better content filtering |
| Misconfiguration | Too much access granted | Tighten permissions |
| Missing Control | No block on financial sites | Add blocklist |
| Control Bypass | Blocklist circumvented | Strengthen enforcement |
| Human Error | Approved wrong action | Better review process |
| Unexpected Behavior | AI misunderstood instruction | Clearer guidelines |

---

## Recovery Phase

### Step 6: Remediate

**Immediate fixes:**
- [ ] Patch the specific vulnerability
- [ ] Update blocklists/allowlists
- [ ] Tighten relevant permissions
- [ ] Add missing controls

**Credential actions:**
- [ ] Rotate all potentially compromised credentials
- [ ] Review OAuth grants
- [ ] Audit active sessions
- [ ] Update token scoping

**System actions:**
- [ ] Restore any modified data from backup
- [ ] Verify system integrity
- [ ] Clear AI context/memory if applicable
- [ ] Reset to known-good state

### Step 7: Verify Recovery

- [ ] Test that the fix works
- [ ] Verify AI cannot repeat the incident
- [ ] Confirm systems are operational
- [ ] Run security checklist

---

## Post-Incident (Days to Weeks)

### Step 8: Document the Incident

**Incident Report Template:**

```markdown
## Incident Report

**Date/Time:**
**Severity:**
**Duration:**
**Detected by:**

### Summary
[One paragraph description]

### Timeline
| Time | Event |
|------|-------|
| | |

### Impact
- Systems affected:
- Data affected:
- People affected:
- Financial impact:

### Root Cause
[What caused this to happen]

### Response Actions
[What we did to stop and fix it]

### Lessons Learned
[What we learned]

### Prevention Measures
[What we're doing to prevent recurrence]
```

### Step 9: Improve Defenses

**Update documentation:**
- [ ] Update security policies
- [ ] Update agents.md with new rules
- [ ] Add to blocklists if needed
- [ ] Document new procedures

**Update monitoring:**
- [ ] Add detection for this attack pattern
- [ ] Create alerts for similar incidents
- [ ] Improve logging coverage

**Update training:**
- [ ] Document learnings
- [ ] Update quick reference cards
- [ ] Practice new procedures

### Step 10: Close Out

- [ ] All fixes implemented and verified
- [ ] Documentation complete
- [ ] Stakeholders informed of resolution
- [ ] Follow-up actions assigned
- [ ] Post-mortem meeting held (for SEV 1-2)

---

## Emergency Contacts

Fill in your specific contacts:

| Role | Name | Contact Method | When to Call |
|------|------|----------------|--------------|
| Primary responder | | | First always |
| Technical backup | | | Can't resolve alone |
| Security expert | | | Suspected breach |
| Legal | | | Data exposure |
| Management | | | SEV 1-2 |
| Service providers | | | Need help |

---

## Quick Response Reference

```
╔══════════════════════════════════════════════════════╗
║            INCIDENT QUICK RESPONSE                    ║
╠══════════════════════════════════════════════════════╣
║                                                      ║
║  1. STOP - Kill AI immediately                       ║
║     • Close tabs: Cmd/Ctrl + Shift + W              ║
║     • Kill process: pkill -f claude                  ║
║                                                      ║
║  2. DOCUMENT - Capture evidence                      ║
║     • Screenshot current state                       ║
║     • Note exact time                                ║
║     • What did you observe?                          ║
║                                                      ║
║  3. CONTAIN - Limit damage                           ║
║     • Revoke affected tokens                         ║
║     • Change critical passwords                      ║
║     • Preserve logs                                  ║
║                                                      ║
║  4. ASSESS - Understand scope                        ║
║     • What systems affected?                         ║
║     • What data exposed?                             ║
║     • Who needs to know?                             ║
║                                                      ║
║  5. RECOVER - Fix and verify                         ║
║     • Implement fix                                  ║
║     • Test thoroughly                                ║
║     • Resume cautiously                              ║
║                                                      ║
╚══════════════════════════════════════════════════════╝
```

---

*Related: [Kill Switches](../configs/kill-switches.md) | [Weekly Audit](weekly-audit.md)*
