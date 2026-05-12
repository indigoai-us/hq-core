---
type: guide
domain: [operations]
status: canonical
tags: [security-posture, self-assessment, maturity-model, ai-automation]
relates_to: []
---

# Your Security Posture

> Self-assessment guide for AI automation security

---

## Overview

Before implementing AI automation, you need to understand where you're starting from. This assessment helps you identify your current risk level, exposure points, and priority areas.

---

## Risk Profile Assessment

### Step 1: Inventory Your Assets

**What systems does AI need access to?**

| System | Access Level Needed | Sensitivity | Current Access |
|--------|--------------------:|-------------|----------------|
| Email | Read / Write / Send | Low / Med / High | Yes / No |
| Calendar | Read / Write | Low / Med / High | Yes / No |
| Slack/Teams | Read / Write / Send | Low / Med / High | Yes / No |
| Code repos | Read / Write / Push | Low / Med / High | Yes / No |
| Cloud console | Read / Admin | Low / Med / High | Yes / No |
| Browser | Navigate / Autofill | Low / Med / High | Yes / No |
| File system | Read / Write / Delete | Low / Med / High | Yes / No |
| ____________ | | | |

### Step 2: Assess Your Credential Exposure

**How are credentials currently stored?**

- [ ] Browser keychain (synced across devices)
- [ ] Browser keychain (local only)
- [ ] Password manager (extension in browser)
- [ ] Password manager (separate app)
- [ ] Environment variables
- [ ] Hardcoded in files
- [ ] Hardware security key

**Which credentials would be catastrophic if compromised?**

1. ________________________________
2. ________________________________
3. ________________________________

**Are any of these accessible to AI agents currently?** Yes / No / Unknown

### Step 3: Evaluate Your Recovery Capability

| Scenario | Recovery Time | Recovery Cost | Likelihood |
|----------|---------------|---------------|------------|
| Wrong email sent | | | |
| File accidentally deleted | | | |
| Code pushed to wrong branch | | | |
| API key exposed | | | |
| Bank account accessed | | | |
| Social media post gone wrong | | | |

**Scale:**
- Recovery Time: Minutes / Hours / Days / Weeks / Unrecoverable
- Recovery Cost: $0 / $100s / $1000s / $10,000s+ / Career-ending
- Likelihood: Rare / Occasional / Likely / Very Likely

---

## Risk Level Calculator

### Your Profile Score

Answer each question honestly:

**Access Breadth** (How many systems can AI access?)
- [ ] 1-2 systems (Score: 1)
- [ ] 3-5 systems (Score: 2)
- [ ] 6-10 systems (Score: 3)
- [ ] 10+ systems (Score: 4)

**Access Depth** (What can AI do in those systems?)
- [ ] Read only (Score: 1)
- [ ] Read + draft/propose (Score: 2)
- [ ] Read + write (Score: 3)
- [ ] Full admin (Score: 4)

**Credential Exposure** (Can AI access stored credentials?)
- [ ] No credential access (Score: 1)
- [ ] Limited/scoped tokens (Score: 2)
- [ ] Full account tokens (Score: 3)
- [ ] Password manager access (Score: 4)

**Financial Access** (Can AI access financial systems?)
- [ ] No financial access (Score: 1)
- [ ] View-only financial access (Score: 2)
- [ ] Transaction capability (Score: 3)
- [ ] Banking/investment access (Score: 4)

**Recovery Capability** (How easily can you undo mistakes?)
- [ ] Everything versioned/reversible (Score: 1)
- [ ] Most things reversible (Score: 2)
- [ ] Some irreversible actions possible (Score: 3)
- [ ] Many irreversible actions possible (Score: 4)

**Total Score: ______ / 20**

### Interpreting Your Score

| Score | Risk Level | Recommended Approach |
|-------|------------|---------------------|
| 5-8 | Low | Standard precautions, focus on convenience |
| 9-12 | Medium | Balanced approach, key controls required |
| 13-16 | High | Security-first, significant controls needed |
| 17-20 | Critical | Maximum restrictions, consider if AI is appropriate |

---

## Current Controls Audit

### Credential Isolation

| Control | Implemented? | Evidence |
|---------|--------------|----------|
| Separate browser profile for AI | Yes / No | |
| No saved passwords in AI profile | Yes / No | |
| Scoped tokens (not full credentials) | Yes / No | |
| Token rotation schedule | Yes / No | |
| Financial sites blocked | Yes / No | |

**Credential Isolation Score: _____ / 5**

### Monitoring & Logging

| Control | Implemented? | Evidence |
|---------|--------------|----------|
| AI actions are logged | Yes / No | |
| Logs include sufficient detail | Yes / No | |
| Logs are reviewed regularly | Yes / No | |
| Alerts for suspicious activity | Yes / No | |
| Logs are tamper-evident | Yes / No | |

**Monitoring Score: _____ / 5**

### Emergency Controls

| Control | Implemented? | Evidence |
|---------|--------------|----------|
| Know how to stop AI immediately | Yes / No | |
| Can revoke tokens quickly | Yes / No | |
| Kill switch tested recently | Yes / No | |
| Incident response plan exists | Yes / No | |
| Emergency contacts documented | Yes / No | |

**Emergency Controls Score: _____ / 5**

### Access Control

| Control | Implemented? | Evidence |
|---------|--------------|----------|
| Autonomy levels defined | Yes / No | |
| Red lines documented | Yes / No | |
| Review gates implemented | Yes / No | |
| Blocked resources enforced | Yes / No | |
| Regular permission review | Yes / No | |

**Access Control Score: _____ / 5**

---

## Gap Analysis

### Your Total Controls Score: _____ / 20

| Score | Control Maturity | Priority Actions |
|-------|-----------------|------------------|
| 0-5 | Minimal | STOP. Implement basics before continuing. |
| 6-10 | Basic | Complete [Pre-Flight Checklist](../checklists/pre-flight.md) |
| 11-15 | Moderate | Address specific gaps identified |
| 16-20 | Strong | Maintain and iterate |

### Risk vs. Controls Matrix

```
                    CONTROLS
                    Low    High
            ┌───────┬───────┐
     High   │DANGER │MANAGED│
RISK        │  ⚠️   │  ✓   │
            ├───────┼───────┤
     Low    │  OK   │OVER-  │
            │       │KILL   │
            └───────┴───────┘
```

**Your position:** Risk Level _____ + Controls Score _____

**Recommended action based on position:**
- DANGER zone: Reduce risk OR increase controls immediately
- MANAGED zone: Maintain vigilance, iterate improvements
- OK zone: Consider expanding AI capabilities
- OVERKILL zone: May be able to reduce controls for efficiency

---

## Priority Actions

Based on your assessment, list your top 3 priority actions:

1. **Highest Priority:** ________________________________
   - Why: ________________________________
   - Timeline: ________________________________

2. **Second Priority:** ________________________________
   - Why: ________________________________
   - Timeline: ________________________________

3. **Third Priority:** ________________________________
   - Why: ________________________________
   - Timeline: ________________________________

---

## Reassessment Schedule

| Trigger | Action |
|---------|--------|
| Initial setup | Complete full assessment |
| Monthly | Quick review (10 min) |
| Quarterly | Full reassessment |
| After any incident | Full reassessment |
| Before expanding AI access | Full reassessment |
| After significant system changes | Full reassessment |

---

## Assessment Sign-Off

```
Assessment completed by: _______________________
Date: _______________________
Risk Level: Low / Medium / High / Critical
Controls Score: _____ / 20
Overall Posture: Acceptable / Needs Work / Unacceptable

Next assessment date: _______________________
```

---

*Next: [Browser Security](04-browser-agents.md) - If using browser-based AI agents*
*Or: [Pre-Flight Checklist](../checklists/pre-flight.md) - If ready to implement*
