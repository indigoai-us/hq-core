# Post-Bridge Client

API wrapper with built-in safety, retry, and logging.

## Configuration

- API key: `settings/post-bridge/.env` → `POST_BRIDGE_API_KEY`
- Base URL: `https://api.post-bridge.com/v1`
- Account mapping: `settings/post-bridge/config.json`

## Core Operations

### createPost(caption, accountIds, options)
1. Run ALL safety checks from `lib/safety-checks.md`
2. If any check BLOCKS → abort with error
3. Build request:
   ```json
   {
     "caption": "<clean content>",
     "social_accounts": [<account_ids>],
     "media": ["<url>"],           // optional
     "scheduled_at": "<ISO8601>",  // optional, null for immediate
     "is_draft": false
   }
   ```
4. Log to `workspace/social-drafts/api-log.jsonl`:
   ```jsonl
   {"ts":"<ISO>","method":"POST","endpoint":"/v1/posts","profile":"<name>","accountIds":[...],"caption_preview":"<first 50 chars>"}
   ```
5. Send request
6. Return post object with `id`, `status`, `social_accounts`

### checkResults(postId, retryConfig)
Poll delivery status with retry:
1. Wait 5 seconds
2. `GET /v1/posts/{postId}` — check `status`
3. If `posted` → check for post URLs in response
4. If `processing` → wait 15s, retry
5. If still `processing` → wait 30s, retry
6. If still `processing` → wait 60s, final retry
7. After all retries:
   - If `posted` with URL → return success
   - If `posted` without URL → return `pending-verification`
   - If `failed` → return failure with error
   - If still `processing` → return `pending-verification`

Log each check to api-log.jsonl.

### getAccounts()
`GET /v1/social-accounts` — list all connected accounts.

### deletePost(postId)
`DELETE /v1/posts/{postId}` — only works for scheduled (not yet sent) posts.

## CRITICAL RULES

- **NEVER send test payloads.** Every API call uses real content that has been reviewed and approved.
- **NEVER use `is_draft: true` for testing.** Draft posts may still trigger processing.
- **Log every API call.** The api-log.jsonl is the audit trail.
- **Retry is mandatory.** Single-check after posting is insufficient. Use the full retry loop.
