# Queue Operations

Centralized queue.json management. All social-team workers use these operations instead of directly reading/writing queue files.

## Queue File Locations (from social-kit.yaml)

- Personal: `workspace/social-drafts/queue.json`
- {company}: `companies/{company}/data/social-drafts/queue.json`
- {Product}: `companies/{product}/data/social-drafts/queue.json`

## Status Values

| Status | Meaning | Who sets it |
|--------|---------|------------|
| `draft` | Initial creation | social-strategist |
| `ready` | Reviewed, awaiting approval | social-reviewer |
| `needs_edit` | Reviewer rejected | social-reviewer |
| `approved` | Human approved, ready to post | social-reviewer (with human gate) |
| `posting` | Actively being sent | social-publisher |
| `posted` | Post-Bridge accepted | social-publisher |
| `verified` | Confirmed live on platform | social-verifier |
| `post_failed` | Post-Bridge reported failure | social-publisher |
| `scheduled` | Scheduled for future | social-publisher |

## Operations

### readQueue(profileName)
1. Get `queue_file` path from social-kit.yaml for the profile
2. Read and parse the JSON file
3. Return entries array

### writeQueue(profileName, entries)
1. Get `queue_file` path from social-kit.yaml
2. Write entries as formatted JSON
3. Log the write to api-log.jsonl

### findEntry(profileName, draftId)
Find a specific entry by `id` field or by matching slug in `draftFile` path.

### updateEntryStatus(profileName, draftId, newStatus, extraFields)
1. Read queue
2. Find entry
3. Update `status` and merge `extraFields` (e.g., `postUrl`, `postBridgeId`, `postedAt`)
4. Write queue
5. If status is `posted` or `verified`: also append to `posted.json`

### getNextApproved(profileName, platform)
1. Read queue
2. Filter where `status === "approved"` and platform matches
3. Return first match (queue is priority-ordered)

### getStats(profileName)
Return counts by status: `{ draft: N, ready: N, approved: N, posted: N, verified: N, ... }`
