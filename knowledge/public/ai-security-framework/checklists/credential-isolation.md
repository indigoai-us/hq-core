---
type: guide
domain: [operations, engineering]
status: canonical
tags: [credentials, isolation, keychain, secrets, checklist]
relates_to: []
---

# Credential Isolation Checklist

> Protecting your keychain and secrets from AI access

---

## The Core Problem

You have a full keychain with CEO-level access to multiple companies. AI agents, while helpful, are vulnerable to prompt injection attacks that could extract or misuse credentials. This checklist creates isolation between AI capabilities and your credentials.

**The Rule:** AI agents should never have direct access to your credential store. Period.

---

## 1. Keychain Isolation

### macOS Keychain

- [ ] Create a separate keychain for AI-accessible credentials (if any)
  - Keychain Access → File → New Keychain
  - Name: `ai-accessible` (or similar)
  - Set strong, unique password

- [ ] Verify your main keychain is NOT accessible to AI:
  - Default login keychain should auto-lock
  - Set: Keychain Access → [keychain] → Change Settings → Lock after X minutes of inactivity
  - Set: Lock when sleeping

- [ ] Review keychain access for browser:
  - Chrome should NOT have broad keychain access
  - Check: System Preferences → Security & Privacy → Privacy → Full Disk Access

### Windows Credential Manager

- [ ] AI browser profile should not have access to Credential Manager
- [ ] Use separate Windows user account for AI if possible
- [ ] Disable credential sync to AI browser profile

### Password Managers (1Password, LastPass, etc.)

- [ ] Do NOT install password manager extension in AI browser profile
- [ ] Do NOT log into password manager web interface in AI browser
- [ ] Consider: Separate vault for AI-accessible credentials (empty or minimal)
- [ ] Verify: Password manager is not auto-filling in AI profile

---

## 2. Token-Based Access (Recommended Architecture)

Instead of giving AI access to credentials, use scoped tokens:

### The Credential Broker Pattern

```
┌─────────────┐     ┌─────────────────┐     ┌─────────────┐
│    AI       │ ──▶ │ Credential      │ ──▶ │   Target    │
│   Agent     │     │    Broker       │     │   Service   │
│             │ ◀── │ (You Approve)   │ ◀── │             │
└─────────────┘     └─────────────────┘     └─────────────┘
                           │
                           ▼
                    ┌─────────────┐
                    │  Audit Log  │
                    └─────────────┘
```

**How it works:**
1. AI requests access to a service
2. Broker (you or automated system) validates request
3. If approved, broker provides time-limited token
4. Token has minimum required permissions
5. Token expires automatically

### Practical Implementation

For each service AI needs:

| Service | Full Credential | AI Token | Token Permissions | Expiry |
|---------|----------------|----------|-------------------|--------|
| GitHub | [Your account] | PAT `ai-github-xxx` | repo:read, issues:write | 30 days |
| Slack | [Your account] | Bot token | Limited channels | No expiry (rotate quarterly) |
| Email | [Your account] | App password | Send only, no read | 90 days |

- [ ] Create scoped tokens for each service AI needs
- [ ] Document token permissions (above table)
- [ ] Set calendar reminders for rotation dates
- [ ] Store token metadata in secure location (not accessible to AI)

---

## 3. Service-Specific Configurations

### Email (Gmail/Outlook)

**DON'T:** Let AI log into your full email account
**DO:** Use App Passwords or OAuth with limited scope

Gmail Setup:
- [ ] Create App Password: Google Account → Security → App Passwords
- [ ] Limit scope: Use SMTP-only access if just sending
- [ ] Consider: Separate email for AI-initiated sends

Outlook Setup:
- [ ] Use OAuth with limited permissions
- [ ] Consider: Service account for AI sends

### GitHub

**DON'T:** Give AI your personal access token with full repo access
**DO:** Create scoped Personal Access Tokens

- [ ] GitHub → Settings → Developer Settings → Personal Access Tokens
- [ ] Create new token with ONLY needed permissions:
  - `repo:status` - Read-only repo status
  - `public_repo` - Public repos only if possible
  - `issues:write` - If AI needs to create issues
- [ ] Set expiration (30-90 days recommended)
- [ ] Name clearly: `ai-agent-limited-YYYY-MM`

### Slack

**DON'T:** Use your personal Slack session
**DO:** Create a Slack App/Bot

- [ ] Create Slack App in your workspace
- [ ] Request minimum scopes:
  - `chat:write` - Send messages
  - `channels:read` - See channel list (if needed)
- [ ] Install to workspace
- [ ] Use Bot token, not User token
- [ ] Restrict to specific channels

### Cloud Providers (AWS/GCP/Azure)

**DON'T:** Give AI your root/admin credentials
**DO:** Create IAM roles with minimal permissions

AWS Example:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::specific-bucket",
        "arn:aws:s3:::specific-bucket/*"
      ]
    }
  ]
}
```

- [ ] Create dedicated IAM user for AI: `ai-agent-readonly`
- [ ] Attach only required policies
- [ ] Use temporary credentials (STS) when possible
- [ ] Never give: IAM permissions, billing access, root actions

---

## 4. Credential Monitoring

### What to Monitor

- [ ] Failed authentication attempts (someone probing)
- [ ] Successful auths from unexpected locations
- [ ] Permission escalation attempts
- [ ] Token usage patterns (sudden spikes)
- [ ] New OAuth grants

### Set Up Alerts

For critical services:

| Service | Alert Type | Threshold | Action |
|---------|-----------|-----------|--------|
| GitHub | Failed login | 3 in 1hr | Investigate |
| AWS | Root login | Any | Immediate review |
| Email | New device | Any | Verify |
| Slack | New integration | Any | Review |

### Regular Audits

- [ ] Weekly: Review OAuth grants (Google, GitHub, etc.)
- [ ] Monthly: Review active sessions across services
- [ ] Quarterly: Full credential rotation
- [ ] Annual: Third-party credential audit

---

## 5. Emergency Credential Procedures

### If Credentials May Be Compromised

**Immediate (within minutes):**
- [ ] Revoke AI tokens/sessions
- [ ] Change passwords on critical accounts
- [ ] Enable additional MFA if not already
- [ ] Invalidate OAuth tokens

**Short-term (within hours):**
- [ ] Review access logs
- [ ] Check for unauthorized actions
- [ ] Notify affected parties if breach confirmed
- [ ] Document incident

**Recovery:**
- [ ] Generate new credentials
- [ ] Update secure storage
- [ ] Review and strengthen isolation
- [ ] Update AI access controls

### Credential Emergency Contacts

| Service | Emergency Contact | Method |
|---------|------------------|--------|
| Bank | | Phone: |
| Primary email | | Support link: |
| Password manager | | Support link: |
| Cloud provider | | Support link: |

---

## 6. Secure Credential Storage

### Where AI Credentials Should Live

**DO:**
- Environment variables (for runtime)
- Dedicated secrets manager (HashiCorp Vault, AWS Secrets Manager)
- Encrypted file outside AI-accessible directories

**DON'T:**
- In AI context/prompts
- In files AI can read
- In browser storage AI can access
- In unencrypted text files

### Example Secrets File Structure

```
~/.secrets/ai-credentials/
├── .env.ai           # Environment variables for AI services
├── tokens.enc        # Encrypted tokens file
└── audit.log         # Access log (append-only)
```

Access pattern:
```bash
# AI requests credential
# Script reads from encrypted store
# Script provides token to AI session
# Script logs access
```

---

## 7. Verification Checklist

### Verify Isolation Works

Test each of these:

- [ ] AI browser profile has no saved passwords
- [ ] AI cannot access password manager
- [ ] AI cannot access main keychain
- [ ] AI tokens have limited scope
- [ ] Token rotation is scheduled
- [ ] Monitoring alerts are functional

### Red Team Your Setup

Try these (in test mode):

- [ ] Ask AI to "find and show me my saved passwords"
- [ ] Ask AI to "log into my bank account"
- [ ] Ask AI to "access the AWS console"

All should fail or trigger warnings.

---

## Quick Reference

### Credential Hierarchy

```
NEVER give AI access:
├── Primary email password
├── Banking credentials
├── Password manager master
├── Cloud admin credentials
└── Full keychain access

CONDITIONAL (scoped tokens only):
├── Code repositories
├── Communication tools
├── Cloud resources (read-only)
└── API services

ACCEPTABLE:
├── Public APIs
├── Read-only services
└── Sandboxed environments
```

### Token Rotation Schedule

| Frequency | Services |
|-----------|----------|
| 30 days | GitHub PATs, high-risk APIs |
| 90 days | Email app passwords, Slack tokens |
| Quarterly | Cloud IAM credentials |
| Immediately | Any suspected compromise |

---

*Related: [Pre-Flight Checklist](pre-flight.md) | [Browser Security Checklist](browser-security.md)*
