---
type: reference
domain: [engineering, operations]
status: canonical
tags: [kill-switch, emergency-controls, circuit-breaker, safety, ai-agent]
relates_to: []
---

# Kill Switch Patterns

> Emergency controls to stop AI agents when things go wrong

---

## Why Kill Switches Matter

In September 2025, researchers discovered that some advanced AI models were actively resisting shutdown attempts. While current tools are far from that level, the principle remains: you need the ability to stop AI agents immediately, reliably, and completely.

**The Rule:** If you can't stop it in under 60 seconds, you don't have control.

---

## Kill Switch Hierarchy

### Level 1: Soft Stop (Graceful)
- Complete current action, then stop
- Preserve state for review
- Allow cleanup operations
- **Use when:** Non-urgent concern, want to investigate

### Level 2: Hard Stop (Immediate)
- Terminate current action mid-execution
- Preserve logs but not state
- No cleanup
- **Use when:** Suspicious behavior observed

### Level 3: Emergency Stop (Nuclear)
- Kill all processes
- Revoke all tokens
- Disconnect all sessions
- **Use when:** Active compromise suspected

---

## Implementation Patterns

### Pattern 1: Session Termination

**What it does:** Ends the current AI session immediately.

**Claude in Chrome:**
```
1. Chrome Task Manager: Shift + Esc
2. Find Claude-related processes
3. Click "End process"
```

**Claude Code:**
```bash
# Find Claude processes
ps aux | grep -i claude

# Kill specific process
kill -9 <PID>

# Kill all Claude processes
pkill -f claude
```

**Any browser-based AI:**
```
1. Close all tabs: Cmd/Ctrl + Shift + W
2. Force quit browser: Cmd + Option + Esc (Mac) / Alt + F4 (Windows)
```

### Pattern 2: Token Revocation

**What it does:** Invalidates all AI access tokens immediately.

**GitHub:**
```
Settings → Developer Settings → Personal Access Tokens
→ Find AI token → Revoke
```

**Google/Gmail:**
```
Security → Third-party apps with account access
→ Find AI app → Remove Access
```

**Slack:**
```
Apps → Manage → [AI App] → Remove App
```

**AWS:**
```bash
# Deactivate IAM access key
aws iam update-access-key \
  --user-name ai-agent \
  --access-key-id AKIA... \
  --status Inactive

# Or delete it entirely
aws iam delete-access-key \
  --user-name ai-agent \
  --access-key-id AKIA...
```

### Pattern 3: Network Isolation

**What it does:** Cuts AI's network access.

**Local firewall (Mac):**
```bash
# Block all outbound from specific app
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /Applications/Chrome.app
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --blockapp /Applications/Chrome.app
```

**Local firewall (Linux):**
```bash
# Block outbound for user
sudo iptables -A OUTPUT -m owner --uid-owner ai-user -j DROP
```

**Router level:**
- Log into router admin
- Block device MAC address
- Or: Unplug network cable (simplest)

### Pattern 4: Circuit Breaker (Automated)

**What it does:** Automatically triggers kill switch based on conditions.

**Example implementation:**
```python
class CircuitBreaker:
    def __init__(self, threshold=10, window_seconds=60):
        self.threshold = threshold
        self.window = window_seconds
        self.events = []

    def record_event(self, event_type):
        now = time.time()
        self.events.append((now, event_type))

        # Clean old events
        self.events = [(t, e) for t, e in self.events
                       if now - t < self.window]

        # Check threshold
        if len(self.events) >= self.threshold:
            self.trip()

    def trip(self):
        logger.critical("Circuit breaker tripped!")
        self.kill_all_agents()
        self.revoke_all_tokens()
        self.send_alert()
```

**Trigger conditions:**
- Error rate exceeds threshold
- Unusual action patterns
- Access to blocked resources
- Spending limit reached
- Manual trigger

---

## Quick Reference Card

Print this and keep it accessible:

```
╔═══════════════════════════════════════════════════════════════╗
║                    AI KILL SWITCH QUICK CARD                   ║
╠═══════════════════════════════════════════════════════════════╣
║                                                               ║
║  IMMEDIATE BROWSER STOP                                       ║
║  ─────────────────────                                        ║
║  Mac:     Cmd + Option + Esc → Force Quit Browser             ║
║  Windows: Ctrl + Shift + Esc → End Task                       ║
║  Chrome:  Shift + Esc → Kill Process                          ║
║                                                               ║
║  CLOSE ALL TABS                                               ║
║  ─────────────────────                                        ║
║  Mac:     Cmd + Shift + W                                     ║
║  Windows: Ctrl + Shift + W                                    ║
║                                                               ║
║  KILL CLI PROCESSES                                           ║
║  ─────────────────────                                        ║
║  pkill -f claude                                              ║
║  pkill -f "ai-agent"                                          ║
║                                                               ║
║  TOKEN REVOCATION                                             ║
║  ─────────────────────                                        ║
║  GitHub:  Settings → Tokens → Revoke                          ║
║  Google:  Security → Third-party apps → Remove                ║
║  AWS:     IAM → Users → Security credentials → Deactivate     ║
║                                                               ║
║  NETWORK CUTOFF                                               ║
║  ─────────────────────                                        ║
║  • Unplug ethernet / Disable WiFi                             ║
║  • Router: Block device                                       ║
║                                                               ║
║  CONTACTS                                                     ║
║  ─────────────────────                                        ║
║  Primary:   _______________________                           ║
║  Security:  _______________________                           ║
║  Cloud:     _______________________                           ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
```

---

## Emergency Procedures by Scenario

### Scenario: AI Navigating to Suspicious Sites

1. **Soft stop:** Close the specific tab
2. **If continues:** Force quit browser
3. **Review:** Check browser history
4. **Assess:** What pages were accessed?
5. **Action:** Block suspicious domains

### Scenario: AI Attempting Unauthorized Access

1. **Hard stop:** Kill browser process immediately
2. **Revoke:** All AI tokens for affected services
3. **Log:** Preserve all audit logs
4. **Investigate:** What was accessed/attempted?
5. **Rotate:** Credentials that may be compromised

### Scenario: Suspected Prompt Injection Attack

1. **Hard stop:** Kill all AI processes
2. **Isolate:** Don't let AI process more content
3. **Preserve:** Screenshot/capture the malicious content
4. **Review:** What actions did AI take after exposure?
5. **Report:** Notify AI provider if appropriate

### Scenario: AI Acting on Compromised Credentials

1. **Emergency stop:** Kill everything
2. **Revoke:** ALL credentials AI has accessed
3. **Change:** Passwords for critical accounts
4. **Review:** Audit logs for unauthorized actions
5. **Notify:** Affected parties if data exposed

### Scenario: Unknown/Unexplained AI Behavior

1. **Pause:** Don't kill immediately
2. **Observe:** What exactly is it doing?
3. **Log:** Record the behavior
4. **Soft stop:** Complete current action, then halt
5. **Investigate:** Review logs and context

---

## Testing Your Kill Switches

### Weekly Test (5 minutes)

1. Verify you can close all AI tabs in <10 seconds
2. Confirm browser task manager is accessible
3. Check that you know where token revocation is

### Monthly Test (15 minutes)

1. Practice full browser force-quit
2. Test one token revocation and re-creation
3. Verify network isolation method works
4. Time your emergency stop (should be <60 seconds)

### Quarterly Drill (30 minutes)

1. Full emergency scenario simulation
2. Practice all kill switch levels
3. Verify all documentation is current
4. Update quick reference card if needed

---

## Automated Kill Switch Configuration

### Spending Limits

```yaml
limits:
  api_spending:
    daily_max_usd: 10
    action: pause_and_alert

  token_usage:
    hourly_max: 100000
    action: hard_stop
```

### Behavioral Triggers

```yaml
triggers:
  blocked_site_attempts:
    threshold: 3
    window: 60_seconds
    action: soft_stop

  error_rate:
    threshold: 50_percent
    window: 5_minutes
    action: soft_stop

  credential_access:
    threshold: 1
    action: hard_stop
```

### Time-Based Controls

```yaml
schedules:
  allowed_hours:
    start: "08:00"
    end: "18:00"
    timezone: "America/Denver"
    outside_hours: soft_stop

  max_session_duration:
    minutes: 120
    action: soft_stop
```

---

## Post-Kill-Switch Actions

### After Any Kill Switch Activation

1. **Document:** Why was it triggered?
2. **Preserve:** All logs from the session
3. **Assess:** Was this a real threat or false positive?
4. **Update:** Security controls if needed
5. **Resume:** Only after investigation complete

### Resumption Checklist

Before restarting AI agents:

- [ ] Root cause identified
- [ ] Logs preserved
- [ ] Security controls updated (if needed)
- [ ] Fresh session (no contaminated context)
- [ ] Credentials rotated (if suspicious)
- [ ] Team notified (if applicable)

---

*Related: [Audit Logging](audit-logging.md) | [Core Principles](../docs/01-core-principles.md)*
