---
type: reference
domain: [engineering, operations]
status: canonical
tags: [audit-logging, configuration, monitoring, security, observability]
relates_to: []
---

# Audit Logging Configuration

> What to log, how to log it, and how to use logs for security

---

## Why Logging Matters

Without logs, you have no visibility into what AI agents are doing. When something goes wrong—and eventually something will—logs are your forensic evidence, your debugging tool, and your compliance documentation.

**Key stat:** Audit logging adds 5-10ms latency and ~15% monthly storage growth for active agents. This is worth it.

---

## What to Log

### Required Fields (Minimum Viable Logging)

Every AI action should capture:

| Field | Description | Example |
|-------|-------------|---------|
| `timestamp` | UTC time of action | `2025-12-14T15:30:00Z` |
| `action_type` | Category of action | `browser_navigate`, `file_write`, `api_call` |
| `target` | What was acted upon | `https://example.com`, `/path/to/file` |
| `outcome` | Result | `success`, `failure`, `blocked` |
| `session_id` | Groups related actions | `sess_abc123` |

### Recommended Fields (Better Visibility)

| Field | Description | Example |
|-------|-------------|---------|
| `agent_id` | Which AI agent | `claude-chrome-main` |
| `user_id` | Human associated | `{your-name}@example.com` |
| `request_id` | Unique action ID | `req_xyz789` |
| `duration_ms` | Time to complete | `1234` |
| `input_summary` | What was requested | `"Navigate to docs"` |
| `output_summary` | What was returned | `"Page loaded"` |
| `error_details` | If failed, why | `"Access denied"` |
| `ip_address` | Source | `192.168.1.1` |
| `risk_level` | Assessed risk | `low`, `medium`, `high` |

### Comprehensive Fields (Full Forensics)

For critical environments, also log:

| Field | Description |
|-------|-------------|
| `parent_session_id` | For nested operations |
| `model_version` | AI model used |
| `prompt_hash` | Hash of prompt (not full prompt, for privacy) |
| `context_window_usage` | How full was context |
| `tokens_used` | Token consumption |
| `cost_usd` | Estimated cost |
| `policy_checks` | Which policies were evaluated |
| `approval_chain` | Who approved (if applicable) |

---

## Log Format

### Structured JSON (Recommended)

```json
{
  "timestamp": "2025-12-14T15:30:00.123Z",
  "level": "INFO",
  "action_type": "browser_navigate",
  "agent_id": "claude-chrome-main",
  "session_id": "sess_abc123",
  "request_id": "req_xyz789",
  "target": "https://docs.example.com/api",
  "outcome": "success",
  "duration_ms": 1234,
  "risk_level": "low",
  "metadata": {
    "page_title": "API Documentation",
    "response_code": 200
  }
}
```

### Log Levels

| Level | Use For | Example |
|-------|---------|---------|
| `DEBUG` | Detailed tracing | Step-by-step navigation |
| `INFO` | Normal operations | "Navigated to page" |
| `WARN` | Concerning but handled | "Blocked site attempted" |
| `ERROR` | Failures | "API call failed" |
| `CRITICAL` | Security events | "Credential access attempt" |

---

## Action-Specific Logging

### Browser Actions

```json
{
  "action_type": "browser_navigate",
  "target": "https://example.com/page",
  "metadata": {
    "previous_url": "https://previous.com",
    "navigation_type": "link_click",
    "blocked": false,
    "security_warnings": []
  }
}
```

```json
{
  "action_type": "browser_form_submit",
  "target": "https://example.com/form",
  "metadata": {
    "form_id": "contact-form",
    "fields_filled": ["name", "email", "message"],
    "sensitive_fields": false
  }
}
```

### File Operations

```json
{
  "action_type": "file_write",
  "target": "/workspace/document.md",
  "metadata": {
    "file_size_bytes": 1234,
    "content_hash": "sha256:abc123...",
    "previous_hash": "sha256:xyz789...",
    "backup_created": true
  }
}
```

### API Calls

```json
{
  "action_type": "api_call",
  "target": "https://api.service.com/endpoint",
  "metadata": {
    "method": "POST",
    "response_code": 200,
    "request_size_bytes": 500,
    "response_size_bytes": 1200,
    "cost_estimate_usd": 0.001
  }
}
```

### Security Events

```json
{
  "action_type": "security_block",
  "target": "https://banking.example.com",
  "outcome": "blocked",
  "metadata": {
    "block_reason": "financial_site_blocklist",
    "policy_matched": "browser-security-001",
    "original_instruction": "check account balance",
    "alert_generated": true
  }
}
```

---

## Storage and Retention

### Where to Store

| Option | Pros | Cons | Best For |
|--------|------|------|----------|
| Local files | Simple, fast | Limited search, scale | Development |
| Cloud storage (S3) | Durable, cheap | Query overhead | Archival |
| Log service (Datadog) | Search, alerts | Cost | Production |
| SIEM (Splunk) | Security focus | Complex, expensive | Enterprise |

### Retention Policy

| Log Type | Retention | Reason |
|----------|-----------|--------|
| Debug logs | 7 days | High volume, low value |
| Info logs | 30 days | Operational visibility |
| Warn logs | 90 days | Trend analysis |
| Error logs | 1 year | Debugging, compliance |
| Critical/Security | 7 years | Legal, forensics |

### Storage Estimate

```
Active AI agent:
- 1,000 actions/day
- ~500 bytes/action (JSON)
- = 500KB/day
- = 15MB/month
- = 180MB/year

Multiply by number of active agents.
```

---

## Log Integrity

### Why It Matters

Logs are useless if they can be tampered with. An attacker who compromises your system will try to cover their tracks.

### Protections

1. **Append-only storage**: Use write-once storage where possible
2. **Cryptographic signing**: Sign log entries
3. **Segregated storage**: Store logs where AI agents can't access them
4. **Hash chaining**: Each entry includes hash of previous entry

### Simple Hash Chain Example

```json
{
  "entry_id": 1001,
  "timestamp": "2025-12-14T15:30:00Z",
  "previous_hash": "sha256:abc123...",
  "entry_hash": "sha256:def456...",
  "data": { ... }
}
```

If any entry is modified, the chain breaks and tampering is detected.

---

## Alerting

### What Should Trigger Alerts

| Event | Severity | Action |
|-------|----------|--------|
| Blocked site access attempt | Medium | Log + review daily |
| Credential access attempt | Critical | Immediate notification |
| Unusual action volume | Medium | Automated + manual review |
| Failed security check | High | Immediate notification |
| Error rate spike | Medium | Investigate within 1 hour |

### Alert Configuration Example

```yaml
alerts:
  - name: credential_access
    condition: action_type == "credential_access"
    severity: critical
    notify:
      - sms: "+1-555-0123"
      - email: "security@example.com"
    throttle: 1 per minute

  - name: blocked_navigation
    condition: action_type == "browser_navigate" AND outcome == "blocked"
    severity: medium
    notify:
      - slack: "#ai-security"
    throttle: 10 per hour

  - name: high_volume
    condition: count(session_id) > 100 per 5 minutes
    severity: high
    notify:
      - email: "ops@example.com"
```

---

## Querying Logs

### Common Queries

**All actions in a session:**
```sql
SELECT * FROM logs
WHERE session_id = 'sess_abc123'
ORDER BY timestamp;
```

**Security events last 24 hours:**
```sql
SELECT * FROM logs
WHERE level = 'CRITICAL'
AND timestamp > NOW() - INTERVAL 24 HOUR;
```

**Failed actions by type:**
```sql
SELECT action_type, COUNT(*) as failures
FROM logs
WHERE outcome = 'failure'
AND timestamp > NOW() - INTERVAL 7 DAY
GROUP BY action_type
ORDER BY failures DESC;
```

**Unusual patterns (potential attack):**
```sql
SELECT session_id, COUNT(*) as actions,
       COUNT(DISTINCT action_type) as variety
FROM logs
WHERE timestamp > NOW() - INTERVAL 1 HOUR
GROUP BY session_id
HAVING actions > 50 OR variety > 10;
```

---

## Implementation Checklist

### Phase 1: Basic Logging

- [ ] Implement minimum required fields
- [ ] Log to local JSON files
- [ ] Set up daily log rotation
- [ ] Manual daily review process

### Phase 2: Enhanced Logging

- [ ] Add recommended fields
- [ ] Move to centralized storage
- [ ] Set up basic alerting
- [ ] Weekly review process

### Phase 3: Production Logging

- [ ] Add comprehensive fields
- [ ] Implement log integrity (signing/chaining)
- [ ] Configure automated alerting
- [ ] Integrate with security monitoring

---

## Quick Reference

### Log Every Time

```
✓ AI navigates to a URL
✓ AI reads or writes a file
✓ AI makes an API call
✓ AI sends any communication
✓ AI is blocked from an action
✓ AI encounters an error
✓ Human approves/denies request
```

### Log Entry Checklist

```
□ Timestamp (UTC)
□ Action type
□ Target
□ Outcome
□ Session ID
□ Agent ID
□ Risk level (if applicable)
□ Error details (if failure)
```

---

*Related: [Core Principles](../docs/01-core-principles.md) | [Kill Switches](kill-switches.md)*
