# social-shared

Shared library for the social-team. Provides:

- **Safety checks** — metadata detection, test message flags, character limits, profile/account matching
- **Queue operations** — centralized queue.json read/write with locking
- **Post-Bridge client** — API wrapper with built-in safety and retry logic
- **Verification** — verify-queue.json management for delivery tracking

## Workers that use this library

- social-strategist — content planning + draft creation
- social-reviewer — quality gate + approval
- social-publisher — posting + delivery verification
- social-verifier — delivery confirmation + audit

## Safety Checks Reference

| Check | Function | Prevents |
|-------|----------|----------|
| Metadata present | `isMetadataPresent(content)` | Raw markdown headers in posts |
| Test message | `isTestMessage(content)` | "test", "hello world" going live |
| Character limit | `isWithinCharLimit(content, platform)` | Truncated posts |
| Profile match | `validateProfileMatch(accountId, profile)` | Cross-company posting |
| Image exists | `validateImageExists(path)` | Broken image references |

## Queue Status Flow

```
draft → ready → approved → posting → posted → verified
                   ↑                     ↓
              needs_edit            post_failed → retry → posting
```
