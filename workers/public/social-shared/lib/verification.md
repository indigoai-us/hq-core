# Verification

Delivery verification management for the social-team.

## verify-queue.json

Location: `workspace/social-drafts/verify-queue.json`

Tracks posts that need delivery verification (scheduled posts, posts where Post-Bridge said "processing" after all retries).

### Entry Format
```json
{
  "postBridgeId": "abc-123",
  "draftId": "post-090",
  "profile": "personal",
  "platform": "x",
  "accountId": 34528,
  "caption_preview": "First 100 chars...",
  "scheduledFor": "2026-02-16T22:30:00Z",
  "createdAt": "2026-02-16T21:50:00Z",
  "checkAfter": "2026-02-16T22:35:00Z",
  "attempts": 0,
  "lastCheck": null,
  "status": "pending"
}
```

### Operations

#### addToVerifyQueue(entry)
Append a new entry to verify-queue.json.

#### checkDue()
Return entries where `checkAfter < now` and `status === "pending"`.

#### markVerified(postBridgeId, postUrl)
Update entry status to `verified`, record URL. Also update queue.json and posted.json.

#### markFailed(postBridgeId, reason)
Update entry status to `failed`, record reason.

## verification-log.jsonl

Append-only audit trail at `workspace/social-drafts/verification-log.jsonl`.

### Entry Format
```jsonl
{"ts":"2026-02-18T10:05:00Z","draftId":"post-090","method":"api","result":"success","url":"https://x.com/...","postBridgeId":"abc-123"}
{"ts":"2026-02-18T10:06:00Z","draftId":"post-091","method":"browser","result":"confirmed","url":"https://linkedin.com/...","profile":"{company}"}
{"ts":"2026-02-18T10:07:00Z","draftId":"post-092","method":"browser","result":"not_found","profile":"personal","note":"Post not visible after 3 scrolls"}
```

## Browser Verification Process (verify-live)

1. Load auth state from `{profile.auth_state_dir}/{platform}-auth.json`
2. Navigate to the profile page:
   - X: `https://x.com/{handle}` (without @)
   - LinkedIn: `https://linkedin.com/company/{slug}/posts/`
3. Wait for page load
4. Screenshot the page
5. Look for the expected content in the timeline (match first ~50 chars of caption)
6. If found → record post URL, mark verified
7. If not found after scrolling 3 times → mark `delivery_unconfirmed`
8. Close browser session
9. Log to verification-log.jsonl
