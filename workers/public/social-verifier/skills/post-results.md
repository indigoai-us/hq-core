---
description: Check delivery status of posts sent via Post-Bridge API
allowed-tools: Task, Read, Glob, Grep, Edit, Write, Bash, AskUserQuestion
argument-hint: [post-bridge-id] [--profile personal|{company}]
visibility: private
---

# /post-results - Post Delivery Status

Check whether posts sent via Post-Bridge API were actually delivered to their target platforms. Cross-references with queue.json for draft context.

**Arguments:** $ARGUMENTS

## Step 0: Resolve Config

1. Read `social-kit.yaml` from HQ root
2. If `--profile` flag in $ARGUMENTS, use that profile. Otherwise use `active_profile`.
3. Set variables from profile:
   - `$PROFILE_NAME` = profile key (personal, {company})
   - `$ACCOUNTS` = profile.accounts
   - `$QUEUE_FILE` = profile.queue_file
   - `$PB_CONFIG_PATH` = profile.post_bridge.config_path
   - `$PB_ACCOUNT_IDS` = profile.post_bridge.account_ids
4. Parse remaining arguments:
   - First positional arg (if any) -> `$POST_ID` (a Post-Bridge post ID)
   - `--profile <name>` already parsed above
5. Load API key:
   ```bash
   source settings/post-bridge/.env 2>/dev/null
   ```
   If `POST_BRIDGE_API_KEY` is not set:
   ```
   ERROR: POST_BRIDGE_API_KEY not found.
   Set it in settings/post-bridge/.env or run /social-setup.
   ```

## Step 1: Fetch Post Results

### If $POST_ID is provided (specific post):

Call `GET /post-results/{post-id}`:

```bash
RESULTS=$(curl -s "https://api.post-bridge.com/v1/post-results/$POST_ID" \
  -H "Authorization: Bearer $POST_BRIDGE_API_KEY")
```

If 404: `Post not found: {$POST_ID}. Check the ID and try again.`

### If no $POST_ID (all recent results):

Call `GET /post-results`:

```bash
RESULTS=$(curl -s "https://api.post-bridge.com/v1/post-results" \
  -H "Authorization: Bearer $POST_BRIDGE_API_KEY")
```

Parse the JSON response. Each result has:
- `id` - result ID
- `post_id` - the Post-Bridge post ID
- `account_id` - which account it was sent to
- `platform` - "twitter" or "linkedin"
- `status` - "pending" | "success" | "failed"
- `post_url` - the live URL (if success)
- `error_message` - error details (if failed)
- `published_at` - when it went live

### Filter by Profile (if --profile set)

Read `settings/post-bridge/config.json` to get the account IDs for the active profile. Filter results to only include entries whose `account_id` matches one of the profile's account IDs.

If no `--profile` was set, show all results (both profiles).

## Step 2: Cross-Reference with Queue

For each result, try to match the `post_id` back to a queue entry:

1. Read `$QUEUE_FILE` (the active profile's queue)
2. Also read the other profile's queue file if showing all results
3. Find entries where `postBridgeId` matches the result's `post_id`
4. If match found, extract: `id` (draft ID), `content` preview (first 60 chars), `type`

This enriches the API results with local context (draft title / content preview).

## Step 3: Display Results

### Single Post Result (when $POST_ID provided)

```
=================================================================
POST RESULT: {$POST_ID}
=================================================================

Account: {account handle from config.json} ({platform})
Status: {SUCCESS / PENDING / FAILED}
{Published: {published_at} — if success}
{URL: {post_url} — if success}
{Error: {error_message} — if failed}

{Draft: {draft-id} — "{content preview}" — if matched in queue}

=================================================================
```

### All Recent Results (when no $POST_ID)

```
=================================================================
POST RESULTS — {profile name or "All Profiles"}
=================================================================

Post ID       Platform   Account          Status    Draft
─────────────────────────────────────────────────────────────────
{post_id}     X          @{your-name}    SUCCESS   post-035
              URL: https://x.com/{your-name}/status/123...
{post_id}     LinkedIn   in/{your-name}  SUCCESS   post-035
              URL: https://linkedin.com/feed/update/...
{post_id}     X          @{your-handle}   PENDING   post-042
              (processing...)
{post_id}     X          @{your-name}    FAILED    post-038
              Error: Rate limit exceeded

=================================================================
Summary: {N} results — {S} success, {P} pending, {F} failed
=================================================================
```

Group results by `post_id` when a single Post-Bridge post went to multiple accounts.

### No Results

If API returns empty:
```
No post results found.
{If --profile set: "Try without --profile to see all accounts."}
{Otherwise: "Posts sent via /post will appear here once delivered."}
```

## Step 4: Handle Failures

If any result has `status: "failed"`:

1. Display the error message from the API
2. Offer retry:
   ```
   Post {post_id} failed on {platform}: {error_message}

   Retry this post? [Y/n]
   ```

3. If user confirms retry:
   - Read the original post via `GET /posts/{post_id}` to get caption, account_ids, media_ids
   - Create a new post with the same parameters via `POST /posts`
   - Report the new post ID
   - Suggest checking results again: `Check delivery with /post-results {new-post-id}`

4. If multiple failures, offer to retry all at once or one-by-one:
   ```
   {N} posts failed. Retry:
   [1] All failed posts
   [2] Pick individually
   [3] Skip
   ```

## Step 5: Update Queue (if applicable)

If any results show a status change from what's in queue.json:

- If result is `success` and queue entry is `posted` (no URL yet): update `postUrl` in queue
- If result is `success` and queue entry is `scheduled`: update status to `posted`, set `postedAt` and `postUrl`
- If result is `failed` and queue entry is `posted` or `scheduled`: update status to `post_failed`

Write updates back to the queue file.

## Error Handling

**API key missing:**
```
ERROR: POST_BRIDGE_API_KEY not found.
Set it in settings/post-bridge/.env or run /social-setup.
```

**API error (4xx/5xx):**
1. 401: "API key invalid or expired. Check settings/post-bridge/.env"
2. 429: "Rate limited. Try again in a moment."
3. Other: Show raw error message from API

**Config not found:**
```
ERROR: Post-Bridge config not found at {path}.
Run /social-setup or create settings/post-bridge/config.json.
```

## Rules

- Always load API key from settings/post-bridge/.env via `source`
- Use curl for API calls (this is a command file, not TypeScript)
- Cross-reference results with queue.json for context — but gracefully handle missing matches
- When filtering by profile, use account IDs from config.json to match results
- Map API platform names: "twitter" in API = "X" in display
- Only offer retry for `failed` results — never auto-retry
- Update queue.json when delivery status diverges from local state
- Show results grouped by post_id for multi-account posts

## Usage Examples

```bash
# Check all recent post delivery results
/post-results

# Check a specific post
/post-results pb_post_abc123

# Check results for {company} profile only
/post-results --profile {company}

# Check specific post on personal profile
/post-results pb_post_xyz789 --profile personal
```
