---
type: guide
domain: [operations, engineering]
status: canonical
tags: [pre-flight, checklist, security, setup, system-access]
relates_to: []
---

# Pre-Flight Security Checklist

> Complete before enabling AI automation with system access

---

## Overview

This checklist ensures you've established baseline security before giving AI agents access to sensitive systems. Complete all items marked **[REQUIRED]** before proceeding. Items marked **[RECOMMENDED]** significantly improve your security posture.

---

## 1. Credential Isolation

### [REQUIRED] Keychain Separation

- [ ] Create a separate browser profile for AI agent use
- [ ] Do NOT sync passwords to the AI agent profile
- [ ] Remove saved passwords from the AI agent profile if any exist
- [ ] Verify: Open AI browser profile → Settings → Passwords → Should be empty or minimal

### [REQUIRED] API Token Scoping

- [ ] Review all API tokens AI agents will use
- [ ] Ensure each token has minimum required permissions
- [ ] Document token permissions and expiration dates
- [ ] Set up token rotation schedule (recommended: 30-90 days)

| Service | Token Name | Permissions | Expires | Rotated |
|---------|-----------|-------------|---------|---------|
|         |           |             |         |         |

### [REQUIRED] Financial System Lockout

- [ ] Confirm AI agents cannot access banking sites
- [ ] Block payment processor dashboards (Stripe, PayPal admin)
- [ ] Restrict cryptocurrency wallet access
- [ ] Document which financial systems are explicitly blocked:

```
Blocked: _______________
Blocked: _______________
Blocked: _______________
```

### [RECOMMENDED] Credential Broker Setup

- [ ] Implement delegated authentication (AI requests access, you approve)
- [ ] Use session tokens instead of persistent credentials
- [ ] Set token TTL to minimum viable duration

---

## 2. Environment Isolation

### [REQUIRED] Browser Profile Configuration

- [ ] Create dedicated browser profile for AI use
- [ ] Profile name: `_______________`
- [ ] Bookmarks: None (or minimal, reviewed)
- [ ] Extensions: Only those required for AI function
- [ ] History: Clear automatically on session end

### [REQUIRED] Sensitive Site Blocking

Configure your browser or network to block AI access to:

- [ ] Banking sites (list your banks): `_______________`
- [ ] Investment platforms: `_______________`
- [ ] Healthcare portals: `_______________`
- [ ] Government services (IRS, Social Security): `_______________`
- [ ] Password managers (if web-based): `_______________`
- [ ] Admin panels for critical infrastructure: `_______________`

### [RECOMMENDED] Network Isolation

- [ ] Consider running AI browser in a VM or container
- [ ] Configure firewall rules to limit outbound connections
- [ ] Set up network monitoring for the AI profile

---

## 3. Audit Infrastructure

### [REQUIRED] Basic Logging

- [ ] Confirm AI actions are logged somewhere accessible
- [ ] Know how to access logs: `_______________`
- [ ] Logs include: timestamp, action type, target, outcome
- [ ] Logs are retained for at least 30 days

### [RECOMMENDED] Comprehensive Logging

- [ ] Log format includes all fields from [Audit Logging Setup](../configs/audit-logging.md)
- [ ] Logs are tamper-evident (cryptographic verification or append-only)
- [ ] Log storage is separate from AI-accessible systems
- [ ] Alerting configured for suspicious patterns

---

## 4. Emergency Controls

### [REQUIRED] Kill Switch Identification

- [ ] Know how to stop all AI agent activity immediately
- [ ] Document the kill switch method:

```
Primary method: _____________________
Backup method: _____________________
Time to activate: _______ seconds/minutes
```

### [REQUIRED] Session Termination

- [ ] Know how to terminate AI browser sessions
- [ ] Know how to revoke AI API tokens
- [ ] Have contact information for key service support if needed

### [RECOMMENDED] Automated Circuit Breakers

- [ ] Set up spending alerts on API services
- [ ] Configure rate limiting
- [ ] Implement anomaly detection (unusual access patterns)

---

## 5. Access Control Configuration

### [REQUIRED] Autonomy Levels Defined

Document AI autonomy levels in your `agents.md`:

| Action Category | Autonomy Level | Notes |
|----------------|----------------|-------|
| Research/Reading | Full / Review / None | |
| Draft Creation | Full / Review / None | |
| File Organization | Full / Review / None | |
| External Communication | Full / Review / None | |
| Code Changes | Full / Review / None | |
| Financial Actions | Full / Review / None | |
| Credential Access | Full / Review / None | |

### [REQUIRED] Red Lines Established

Explicitly list what AI must NEVER do:

```markdown
## AI Red Lines (from agents.md)

- NEVER access [list systems]
- NEVER send [list communications] without review
- NEVER execute [list actions]
- NEVER modify [list data]
```

### [RECOMMENDED] Review Gates

Define what requires human approval:

```markdown
## Review Required For

- [ ] Emails to external recipients
- [ ] Commits to main/production branches
- [ ] File deletions
- [ ] API calls exceeding $X
- [ ] Access to [specific systems]
```

---

## 6. Incident Response Preparation

### [REQUIRED] Contact List

| Role | Name | Contact | When to Call |
|------|------|---------|--------------|
| You (self) | | | First contact |
| Technical backup | | | Can't resolve alone |
| Security professional | | | Suspected breach |
| Legal counsel | | | Data exposure |

### [REQUIRED] Immediate Response Plan

If you suspect AI has been compromised:

1. [ ] Know how to: Stop all AI activity
2. [ ] Know how to: Revoke tokens/sessions
3. [ ] Know how to: Preserve logs for analysis
4. [ ] Know how to: Assess what was accessed

### [RECOMMENDED] Documentation

- [ ] Document all systems AI has access to
- [ ] Document all credentials AI could theoretically access
- [ ] Have a "blast radius" estimate for compromise scenario

---

## 7. Ongoing Hygiene Setup

### [REQUIRED] Review Schedule

- [ ] Daily: Check for anomalies in logs (5 min)
- [ ] Weekly: Review AI actions for appropriateness (15 min)
- [ ] Monthly: Rotate credentials, review permissions (30 min)

### [RECOMMENDED] Alerting

- [ ] Set up alerts for failed authentication attempts
- [ ] Set up alerts for access to blocked resources
- [ ] Set up alerts for unusual usage patterns

---

## 8. Final Verification

### Before Going Live

- [ ] I have completed all [REQUIRED] items above
- [ ] I understand the threat landscape for AI agents
- [ ] I have a kill switch I can activate in under 60 seconds
- [ ] I know how to access and review AI action logs
- [ ] I have documented what AI can and cannot do
- [ ] I accept the residual risk of AI automation

### Sign-Off

```
Completed by: _______________________
Date: _______________________
Next review date: _______________________
```

---

## Post-Completion

After completing this checklist:

1. Save a copy with your HQ documentation
2. Schedule your first weekly review
3. Begin with low-risk AI tasks to validate your controls
4. Gradually expand AI autonomy as you build confidence

---

*Related: [Browser Security Checklist](browser-security.md) | [Credential Isolation Checklist](credential-isolation.md)*
