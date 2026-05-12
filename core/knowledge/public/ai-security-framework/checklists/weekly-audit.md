---
type: guide
domain: [operations]
status: canonical
tags: [weekly-audit, checklist, security-hygiene, review, maintenance]
relates_to: []
---

# Weekly Security Audit Checklist

> 15-minute weekly review to maintain security hygiene

---

## Overview

Security isn't a one-time setup. This checklist keeps your AI security posture current with minimal time investment. Schedule 15 minutes weekly—Friday afternoon works well.

---

## Quick Scan (5 minutes)

### Log Review

- [ ] Open AI action logs for the past week
- [ ] Scan for `WARN` and `ERROR` level entries
- [ ] Check for any `CRITICAL` security events
- [ ] Note any unusual patterns:

```
Observations: _________________________________
________________________________________________
```

### Blocked Actions

- [ ] Review list of blocked site access attempts
- [ ] Any unexpected blocks? (legitimate sites incorrectly blocked)
- [ ] Any concerning blocks? (AI trying to access sensitive sites)
- [ ] Adjust blocklists if needed

### Session Review

- [ ] How many AI sessions this week? ____
- [ ] Any sessions longer than expected?
- [ ] Any sessions at unusual times?

---

## Credential Check (5 minutes)

### Token Status

| Token | Status | Days Until Expiry | Action Needed |
|-------|--------|-------------------|---------------|
| GitHub PAT | Active / Expired | | |
| Slack Bot | Active / Expired | | |
| [Other] | | | |

- [ ] Rotate any tokens expiring within 7 days
- [ ] Verify no unexpected tokens were created
- [ ] Check for any failed auth attempts in logs

### Password Manager Audit

- [ ] AI browser profile still has no saved passwords? Yes / No
- [ ] Password manager extension NOT in AI profile? Yes / No
- [ ] No unexpected OAuth grants this week? Yes / No

---

## Configuration Verification (5 minutes)

### Browser Profile

- [ ] AI browser profile still isolated from personal profile
- [ ] Autofill still disabled
- [ ] History clearing still configured

### Blocklists Current

- [ ] Financial sites still blocked
- [ ] Healthcare sites still blocked
- [ ] Added any new sites that should be blocked?

```
Add to blocklist: _____________________________
```

### agents.md Review

- [ ] Security rules still appropriate?
- [ ] Any autonomy levels need adjustment?
- [ ] Document any changes made:

```
Changes: ______________________________________
```

---

## Incident Review

### This Week's Security Events

| Date | Event | Severity | Resolved |
|------|-------|----------|----------|
| | | | |
| | | | |

### Outstanding Issues

- [ ] All incidents from previous weeks resolved?
- [ ] Any patterns emerging across weeks?
- [ ] Security controls need updating?

---

## Quick Tests

### Kill Switch Test (1 minute)

- [ ] Browser task manager accessible (Shift + Esc)
- [ ] Know where to revoke tokens
- [ ] Emergency contact info current

### Permission Gate Test

- [ ] Asked AI to perform a yellow-zone action
- [ ] Confirmed it requested approval
- [ ] Approval workflow still functioning

---

## Action Items

Based on this review, I need to:

1. ________________________________________________
2. ________________________________________________
3. ________________________________________________

**Next review date:** ____________________

---

## Monthly Roll-Up

At the end of each month, summarize:

- Total AI sessions: ____
- Security events: ____
- Blocked access attempts: ____
- Credential rotations: ____
- Configuration changes: ____

Keep monthly summaries for trend analysis.

---

*Time spent: _____ minutes*
*Completed by: _____________*
*Date: _____________*

---

*Related: [Pre-Flight Checklist](pre-flight.md) | [Audit Logging](../configs/audit-logging.md)*
