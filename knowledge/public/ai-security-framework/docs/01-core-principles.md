---
type: strategy
domain: [operations, engineering]
status: canonical
tags: [security-principles, ai-automation, threat-model, least-privilege]
relates_to: []
---

# Core Security Principles for AI Automation

> The mental model for securing autonomous AI systems

---

## The Fundamental Tension

AI automation promises extraordinary leverage—software development at $10/hour, 24/7 autonomous agents, exponential productivity. But that leverage cuts both ways. The same capabilities that let AI help you also let AI hurt you if compromised or misdirected.

This framework resolves that tension through **bounded autonomy**: giving AI freedom to operate within carefully defined limits.

---

## Principle 1: Blast Radius Awareness

**Every AI action has a potential blast radius—the maximum damage if something goes wrong.**

Before enabling any autonomous capability, ask:

1. **What's the worst that could happen?**
2. **Is that outcome recoverable?**
3. **How quickly would I know if it happened?**
4. **Can I limit the damage automatically?**

### Blast Radius Categories

| Category | Recovery Time | Example | Approach |
|----------|--------------|---------|----------|
| **Trivial** | Seconds | Typo in draft | Full autonomy |
| **Low** | Minutes | Wrong file modified | Auto-save + version control |
| **Medium** | Hours | Embarrassing email sent | Review gates + delay |
| **High** | Days | Data exposed | Human approval required |
| **Critical** | Weeks+ | Credentials stolen | Never allow autonomous access |
| **Existential** | Unrecoverable | Bankruptcy, legal action | Multiple approval layers |

### Application

Map every AI capability to a blast radius category. If you can't confidently categorize it, assume it's one level higher than you think.

---

## Principle 2: Privilege Minimization

**AI should have the minimum access necessary for each specific task—no more, no less.**

This is the security principle of "least privilege" applied to AI agents. It's particularly important because:

- AI agents don't understand context the way humans do
- Prompt injection attacks exploit any available capability
- Credentials given to AI can be extracted through clever prompts

### The Access Spectrum

```
MOST RESTRICTIVE                                    LEAST RESTRICTIVE
      |                                                    |
      v                                                    v
   No Access → Read Only → Scoped Write → Full Write → Admin
```

**Default to left. Move right only with explicit justification.**

### Practical Implementation

Instead of:
```
AI has access to all email capabilities
```

Use:
```
AI can:
- Read emails from approved senders list
- Draft replies (saved to drafts folder)
- NOT send emails directly
- NOT access emails older than 30 days
- NOT forward emails to external addresses
```

---

## Principle 3: Defense in Depth

**Never rely on a single security control. Layer defenses so that failure of one doesn't mean total compromise.**

### The Onion Model

```
┌─────────────────────────────────────────┐
│ Layer 5: Human Review                    │
│   Final approval for consequential acts  │
│ ┌─────────────────────────────────────┐ │
│ │ Layer 4: Kill Switches               │ │
│ │   Emergency stops if anomaly detected│ │
│ │ ┌─────────────────────────────────┐ │ │
│ │ │ Layer 3: Audit Logging          │ │ │
│ │ │   Track everything for review   │ │ │
│ │ │ ┌─────────────────────────────┐ │ │ │
│ │ │ │ Layer 2: Sandboxing         │ │ │ │
│ │ │ │   Isolate AI environment    │ │ │ │
│ │ │ │ ┌─────────────────────────┐ │ │ │ │
│ │ │ │ │ Layer 1: Least Privilege│ │ │ │ │
│ │ │ │ │   Limit AI capabilities │ │ │ │ │
│ │ │ │ └─────────────────────────┘ │ │ │ │
│ │ │ └─────────────────────────────┘ │ │ │
│ │ └─────────────────────────────────┘ │ │
│ └─────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

Each layer should function independently. If prompt injection bypasses Layer 1 (least privilege), Layer 2 (sandboxing) should still contain the damage.

---

## Principle 4: Context Isolation

**Borrowed from the Ralph methodology: fresh context prevents accumulated risk.**

In traditional software, state accumulates. In AI agents, context accumulates—and that context can include:

- Sensitive data from previous tasks
- Credentials or tokens mentioned in passing
- User preferences that reveal attack vectors
- System information useful for privilege escalation

### Why Fresh Context is a Security Feature

The Ralph loop's "malloc/free" approach to context isn't just about performance:

```bash
for i in {1..N}; do
    # Each iteration starts fresh
    # No accumulated sensitive data
    # No context rot leaking information
    claude --print "Pick ONE task..."
done
```

**Benefits:**
- Sensitive data doesn't persist between tasks
- Compromised context is discarded, not propagated
- Each task has exactly the information it needs, no more

### Application

- Reset AI context between unrelated tasks
- Don't let AI "remember" credentials across sessions
- Scope context to the minimum needed for current task

---

## Principle 5: Verifiable Actions

**If you can't verify what AI did, you can't trust what AI did.**

Every autonomous AI action should produce:

1. **Audit trail** - What was requested, what was done
2. **Artifacts** - Tangible outputs that can be reviewed
3. **State change record** - Before/after snapshots

### The Verification Loop

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Request   │ → │   Execute   │ → │   Verify    │
│             │    │   + Log     │    │   + Review  │
└─────────────┘    └─────────────┘    └─────────────┘
        ↑                                     │
        └─────────────────────────────────────┘
                    Feedback Loop
```

### Red Flags

If AI can take actions that are:
- Not logged → **Fix immediately**
- Not reversible → **Require approval**
- Not visible → **Add monitoring**
- Not attributable → **Add identity tracking**

---

## Principle 6: Graceful Degradation

**When security controls fail, the system should become more restrictive, not less.**

### Fail-Secure vs. Fail-Open

| Scenario | Fail-Open (BAD) | Fail-Secure (GOOD) |
|----------|-----------------|-------------------|
| Auth server down | Allow all actions | Block all actions |
| Audit log full | Continue without logging | Pause until resolved |
| Approval timeout | Auto-approve | Auto-reject |
| Kill switch fails | Continue operation | Stop all agents |

### Implementation

```
IF security_check_fails:
    THEN restrict_access()
    NOT grant_access()
```

This is counterintuitive because it means your AI might stop working when something goes wrong. That's the point. Better to have AI stop than have AI run without safeguards.

---

## Principle 7: Continuous Vigilance

**Security is not a one-time setup. It's an ongoing practice.**

The threat landscape for AI agents evolves weekly. New attack vectors are discovered constantly:

- **Q4 2025**: First large-scale AI-executed cyberattack
- **CVE-2025-47241**: Browser automation whitelist bypass
- **CVE-2025-53773**: GitHub Copilot remote code execution

### Required Practices

| Cadence | Activity |
|---------|----------|
| Daily | Review audit logs for anomalies |
| Weekly | Check for new AI security advisories |
| Monthly | Rotate credentials, review permissions |
| Quarterly | Full security posture assessment |
| Annually | Third-party security audit |

---

## The Security/Productivity Balance

These principles might seem restrictive. They're designed to be. But they're also designed to be applied proportionally:

**Low-risk activities** → Minimal controls → Maximum productivity
**High-risk activities** → Strong controls → Reduced productivity
**Critical activities** → Human control → AI as assistant only

The goal is to find the line where you get maximum leverage from AI while keeping your blast radius acceptable.

---

## Summary: The 7 Principles

1. **Blast Radius Awareness** - Know the worst case for every capability
2. **Privilege Minimization** - Give AI the minimum access needed
3. **Defense in Depth** - Layer controls so one failure isn't total failure
4. **Context Isolation** - Fresh context prevents accumulated risk
5. **Verifiable Actions** - If you can't verify it, you can't trust it
6. **Graceful Degradation** - Fail secure, not fail open
7. **Continuous Vigilance** - Security is ongoing, not one-time

---

*Next: [Threat Landscape](02-threat-landscape.md) - Understanding what you're protecting against*
