---
type: guide
domain: [operations, engineering]
status: canonical
tags: [quick-start, security, setup, onboarding, hardening]
relates_to: []
---

# Quick Start Guide

> Get secure in 30 minutes

---

## Who This Is For

You're about to give AI agents (Claude in Chrome, Claude Code, or similar) access to your systems. You have credentials, accounts, and data you need to protect. This guide gets you to a baseline secure state fast.

---

## The 30-Minute Path

### Minute 0-5: Create Isolation

**Create a separate browser profile for AI:**

1. Chrome → Profile icon → Add
2. Name it "AI-Agent"
3. Don't sign into Chrome
4. Don't sync anything

**Verify isolation:**
- No saved passwords in new profile
- No payment methods
- No autofill data

### Minute 5-15: Block Critical Sites

**Add these to your blocklist:**

Your banks:
```
bankofamerica.com
chase.com
[your banks here]
```

Investment sites:
```
fidelity.com
vanguard.com
[your investment sites]
```

Password managers (web):
```
1password.com
lastpass.com
bitwarden.com
```

**Method:** Use a site blocker extension, or add to hosts file:
```
# /etc/hosts
127.0.0.1 bankofamerica.com
127.0.0.1 chase.com
# etc.
```

### Minute 15-20: Know Your Kill Switch

**Practice these now:**

Close all tabs fast:
- Mac: `Cmd + Shift + W`
- Windows: `Ctrl + Shift + W`

Kill browser process:
- Mac: `Cmd + Option + Esc` → Force Quit
- Chrome: `Shift + Esc` → End Process

Write down: "If AI goes rogue, I will: ________________"

### Minute 20-25: Set Basic Rules

**Add to your agents.md or equivalent:**

```markdown
## Security Rules

NEVER access:
- Banking or financial sites
- Password managers
- Healthcare portals

ALWAYS ask before:
- Sending any external communication
- Making any purchase
- Deleting any file
- Accessing any site not on approved list
```

### Minute 25-30: Verify It Works

**Test your blocks:**
1. In AI profile, try navigating to your bank
2. Should be blocked
3. If not, fix your blocklist

**Test your kill switch:**
1. Open several tabs
2. Practice closing them all (<10 seconds)
3. Practice force quit

---

## You're Now Baseline Secure

This gives you:
- ✅ Credential isolation (separate profile)
- ✅ Critical site blocking (financial, etc.)
- ✅ Emergency stop capability (kill switches)
- ✅ Basic rules documented

---

## Next Steps (When You Have Time)

### This Week
- Complete [Pre-Flight Checklist](checklists/pre-flight.md) fully
- Set up basic logging
- Review your token permissions

### This Month
- Read [Core Principles](docs/01-core-principles.md)
- Implement [Audit Logging](configs/audit-logging.md)
- Create scoped tokens for AI access

### Ongoing
- [Weekly Audit](checklists/weekly-audit.md) every Friday
- Rotate credentials monthly
- Stay current on AI security news

---

## If Something Goes Wrong

1. **Stop** - Use your kill switch
2. **Assess** - What did AI access?
3. **Revoke** - Kill any compromised tokens
4. **Rotate** - Change passwords if needed
5. **Learn** - Update your rules

---

## Quick Reference

```
KILL SWITCHES
─────────────
Close tabs:    Cmd/Ctrl + Shift + W
Kill browser:  Cmd + Option + Esc (Mac)
               Ctrl + Shift + Esc (Windows)

NEVER LET AI
────────────
• Access banking sites
• Use password manager
• Send without approval

ALWAYS HAVE
───────────
• Separate browser profile
• Blocked critical sites
• Way to stop in <60s
```

---

*For comprehensive security, see [README](README.md)*
