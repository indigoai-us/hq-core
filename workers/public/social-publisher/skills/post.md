---
description: Post or schedule content to X and LinkedIn via Post-Bridge API
allowed-tools: Task, Read, Glob, Grep, Edit, Write, Bash, AskUserQuestion
argument-hint: [draft-id|next] [--schedule 'ISO8601'|auto] [--platform x|linkedin|both] [--profile name]
visibility: private
---

# /post - Unified Social Posting

Post or schedule content to X and/or LinkedIn. Uses Post-Bridge REST API for regular posts. Falls back to agent-browser for X articles.

**Arguments:** $ARGUMENTS

## Step 0: Resolve Config

1. Read `social-kit.yaml` from HQ root
2. If `--profile` flag in $ARGUMENTS, use that profile. Otherwise use `active_profile`.
3. Set variables from profile:
   - `$PROFILE_NAME` = profile key (personal, {company})
   - `$ACCOUNTS` = profile.accounts
   - `$QUEUE_FILE` = profile.queue_file
   - `$DRAFTS_DIR` = profile.drafts_dir
   - `$TIMEZONE` = profile.timezone
   - `$POSTING_TIMES` = profile.posting_times
   - `$AUTH_DIR` = profile.auth_state_dir
   - `$PB_ENABLED` = profile.post_bridge.enabled
   - `$PB_CONFIG_PATH` = profile.post_bridge.config_path
   - `$PB_ACCOUNT_IDS` = profile.post_bridge.account_ids
4. Parse remaining flags from $ARGUMENTS:
   - `--schedule <ISO8601|auto>` -> `$SCHEDULE`
   - `--platform <x|linkedin|both>` -> `$PLATFORM` (default: `both`)
   - First positional arg -> `$DRAFT_ID` (or `next`)
5. Strip all flags from $ARGUMENTS before processing.

## Step 0.4: Social Council Gate (personal accounts only)

**Only applies when `$PROFILE_NAME` is `personal` (accounts: @{your-name}, in/{your-name}).**

Before any other checks, if this is a personal account post:
1. Load the draft content from `draftFile` (strip metadata header)
2. Run `/run social-council review {draft-id}` (or inline the council review)
3. If verdict is **BLOCKED**: stop immediately. Report the blocked lens(es) and what needs to change. Do NOT proceed.
4. If verdict is **CONDITIONAL**: show the council output to the user. Ask: "Council flagged this post. Acknowledge and proceed, or abort?"
   - If user acknowledges: log `"council_override": true` and reason, continue
   - If user aborts: stop
5. If verdict is **APPROVED**: continue silently

This gate cannot be skipped for personal accounts. It runs before approval checks and before page checks.

## Step 0.5: Approval Gate Check

Before proceeding, if posting a queued draft (not composing fresh):
1. Read `$QUEUE_FILE`
2. Find the target draft entry
3. If status is NOT `approved`:
   ```
   ⚠️  Draft "{id}" has status "{status}".
   The social-team pipeline requires drafts to be "approved" before posting.
   Recommended: /run social-reviewer promote {id} --profile {profile}

   Override and post anyway? [Yes, I take responsibility / No, review first]
   ```
4. If user overrides: proceed, but log `"override": true` in posted.json entry
5. If user declines: abort

## Step 0.6: Pre-Post Page Check

Before posting, use agent-browser to check the target social page:
1. Navigate to the profile page (e.g., `x.com/getindigo` or `linkedin.com/company/getindigo/posts/`)
2. Screenshot the page
3. Verify the new post makes sense alongside existing content (no duplicates, appropriate context)
4. If issues found, warn user before proceeding

## Step 1: Resolve Draft

### If $DRAFT_ID is a specific ID (e.g., "post-035", "personal-agi-article"):

1. Read `$QUEUE_FILE`
2. Find entry matching `$DRAFT_ID` (match on `id` field, or match slug in `draftFile` path)
3. If not found: `ERROR: Draft "{$DRAFT_ID}" not found in queue.`
4. If status is `posted`: `WARN: Draft already posted at {postedAt}. Post again? [Y/n]`
5. Load draft content from `draftFile`

### If $DRAFT_ID is "next":

1. Read `$QUEUE_FILE`
2. Filter entries where:
   - `status` is `approved` or `ready` (prefer `approved` first, then `ready`)
   - `platform` matches `$PLATFORM` (or any if `both`)
   - `account` matches current profile's accounts
3. Sort by queue order (first match wins — queue is priority-ordered)
4. If no matches: `No ready/approved drafts in queue for {$PROFILE_NAME}. Run /preview-post to approve drafts.`
5. Load the draft content from `draftFile`

### If no $DRAFT_ID provided:

Show queue summary and ask user to pick:
```
QUEUE: {$PROFILE_NAME} ({$ACCOUNTS.x} / {$ACCOUNTS.linkedin})
=================================================================
Ready/Approved:
  [1] post-005  X oneliner: "Everyone's still designing..."
  [2] post-006  X short: (from file)
  [3] post-008  X oneliner: "You have 1,000 employees..."

Which draft to post? (number, ID, or 'cancel')
```

## Step 2: Read Draft Content

1. Read the draft file at `draftFile` path
2. **Strip metadata header before extracting content.** Draft files have a metadata block above a `---` separator:
   ```
   # Title
   **Status:** Draft
   **Type:** ...
   **Account:** ...
   ---
   Actual post content here
   ```
   - Find the first `---` line in the file
   - If lines above it contain `#` headings or `**Key:**` metadata → discard everything up to and including `---`
   - If the content below `---` has `## Option A`, `## Option B` sections → extract the **Recommended** option only (look for `**Recommended:** Option X` at the bottom). Strip code fences around the option content.
   - **NEVER include** `#` headings, `**Status:**`, `**Platform:**`, `**Type:**`, `**Created:**`, `**Account:**`, `---` separators, `## Option` labels, or code fences in the final post content.
3. Extract:
   - `$CONTENT` = clean post text (metadata stripped per above)
   - `$TYPE` = entry.type (oneliner, short, post, article)
   - `$TITLE` = entry.title (for articles)
   - `$IMAGE_FILE` = entry.imageFile (if set)
   - `$PLATFORM` = entry.platform (override if not set by flag)

### Platform Resolution

If `--platform` flag was set, use that. Otherwise:
- If entry.platform is `x` -> post to X only
- If entry.platform is `linkedin` -> post to LinkedIn only
- If entry.platform is `x-community` or `hn` or `show-hn` -> **NOT supported by Post-Bridge**. Use agent-browser fallback or skip with message.

## Step 3: Schedule Resolution

### If `--schedule auto`:

1. Read `$POSTING_TIMES` for the target platform(s)
2. Get current time in `$TIMEZONE`
3. Find the next available slot:
   - For each posting time today and tomorrow, check if it's in the future
   - Pick the soonest future slot
4. Set `$SCHEDULE` to that ISO 8601 timestamp
5. Confirm: `Auto-scheduled for {$SCHEDULE} ({$TIMEZONE})`

### If `--schedule <ISO8601>`:

1. Validate the timestamp is in the future
2. Set `$SCHEDULE` to the provided value

### If no `--schedule`:

Post immediately (`$SCHEDULE` = null).

## Step 4: Confirmation Preview

Show preview before posting:

```
=================================================================
READY TO POST
=================================================================

Profile: {$PROFILE_NAME}
Platform: {X / LinkedIn / Both}
Account: {$ACCOUNTS.x or $ACCOUNTS.linkedin}
Type: {$TYPE}
Mode: {Immediate / Scheduled for {$SCHEDULE}}

-----------------------------------------------------------------
CONTENT:
-----------------------------------------------------------------

"{$CONTENT first 300 chars...}"

-----------------------------------------------------------------

Image: {$IMAGE_FILE or "none"}
Characters: {count} / {limit}

=================================================================

{Post now? / Schedule? } [Yes / No / Edit first]
```

Character limits:
- X regular post: 280 chars
- X premium/long post: 25,000 chars
- X article: no strict limit
- LinkedIn post: 3,000 chars

Wait for user confirmation before proceeding.

## Step 5: Post via Post-Bridge API

### Determine Posting Path

| Type | Platform | Method |
|------|----------|--------|
| oneliner | x | Post-Bridge API |
| short | x | Post-Bridge API |
| post | linkedin | Post-Bridge API |
| post | x | Post-Bridge API |
| article | x | Agent-browser fallback (Step 5b) |
| community | x-community | Agent-browser fallback |
| show-hn | hn | Skip (not supported) |

### Step 5a: Post-Bridge API Path (primary)

This is the main path for regular X posts and LinkedIn posts.

```bash
# Load .env for API key
source settings/post-bridge/.env 2>/dev/null

# The command itself executes the posting logic:
```

**Logic (implemented inline, not as TS — this is a command file):**

1. **Load API key**: Read from `settings/post-bridge/.env` (the `POST_BRIDGE_API_KEY` var)

2. **Resolve account IDs**: Read `settings/post-bridge/config.json`. For the active profile + platform, get the Post-Bridge account ID:
   - personal + x -> `profiles.personal.x.accountId`
   - personal + linkedin -> `profiles.personal.linkedin.accountId`
   - {company} + x -> `profiles.{company}.x.accountId`
   - {company} + linkedin -> `profiles.{company}.linkedin.accountId`
   - If posting to `both`, collect both account IDs

3. **Upload image** (if `$IMAGE_FILE` is set):
   ```bash
   # Step 1: Get signed upload URL (MUST use /v1/media/create-upload-url)
   FILE_SIZE=$(stat -f%z "$IMAGE_FILE" 2>/dev/null || stat -c%s "$IMAGE_FILE")
   UPLOAD_RESPONSE=$(curl -s -X POST "https://api.post-bridge.com/v1/media/create-upload-url" \
     -H "Authorization: Bearer $POST_BRIDGE_API_KEY" \
     -H "Content-Type: application/json" \
     -d "{\"mime_type\": \"image/png\", \"size_bytes\": $FILE_SIZE, \"name\": \"$(basename $IMAGE_FILE)\"}")

   UPLOAD_URL=$(echo $UPLOAD_RESPONSE | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['upload_url'])")
   MEDIA_ID=$(echo $UPLOAD_RESPONSE | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['media_id'])")

   # Step 2: PUT file binary to signed URL
   curl -s -X PUT "$UPLOAD_URL" \
     -H "Content-Type: image/png" \
     --data-binary "@$IMAGE_FILE"
   ```

4. **Create post**:
   ```bash
   # Build request body — media takes media_id strings (NOT raw URLs)
   POST_BODY='{
     "caption": "<escaped content>",
     "social_accounts": [<account_id_1>, <account_id_2>],
     "media": ["<media_id>"],            # only if image uploaded
     "scheduled_at": "<ISO8601 or null>"  # null for immediate
   }'

   POST_RESPONSE=$(curl -s -X POST "https://api.post-bridge.com/v1/posts" \
     -H "Authorization: Bearer $POST_BRIDGE_API_KEY" \
     -H "Content-Type: application/json" \
     -d "$POST_BODY")
   ```

5. **Parse response**: Extract `post.id`, `post.status` from response.

6. **If posting to both platforms with different captions** (e.g., X has shorter version):
   Use `account_configurations` to provide per-account caption overrides.

### Step 5b: Agent-Browser Fallback — X Article

For X articles, Post-Bridge may not support the article format. Use agent-browser:

```bash
agent-browser state load {$AUTH_DIR}/x-auth.json
agent-browser open "https://x.com/compose/article"
agent-browser wait --load networkidle
# Auth check: if URL contains "login", re-auth
agent-browser snapshot -i
agent-browser fill @eTitle "{$TITLE}"
agent-browser fill @eBody "{$CONTENT}"
# If image: agent-browser upload @eImage "{$IMAGE_FILE}"
agent-browser find role button click --name "Publish"
agent-browser wait --load networkidle
agent-browser get url  # Capture post URL
agent-browser close
```

## Step 6: Post-Posting Actions

### 6a. Check Delivery (MANDATORY — Post-Bridge only)

After creating a post via API, ALWAYS verify delivery with retry loop:

```bash
POST_BRIDGE_API_KEY=$(grep POST_BRIDGE_API_KEY settings/post-bridge/.env | cut -d= -f2)

# Retry loop: 5s, 15s, 30s, 60s
for WAIT in 5 15 30 60; do
  sleep $WAIT
  RESULT=$(curl -s "https://api.post-bridge.com/v1/posts/$POST_ID" \
    -H "Authorization: Bearer $POST_BRIDGE_API_KEY")
  STATUS=$(echo $RESULT | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))")

  if [ "$STATUS" = "posted" ] || [ "$STATUS" = "failed" ]; then
    break
  fi
done
```

**Based on final status:**
- `posted` → proceed to visual verification (Step 6a.2)
- `failed` → set queue status to `post_failed`, show error, offer retry
- Still `processing` → add to `workspace/social-drafts/verify-queue.json` for social-verifier follow-up. Set `postUrl` to `"pending-verification"` (NEVER `null`)

### 6a.2 Visual Verification (MANDATORY)

After Post-Bridge confirms "posted", use agent-browser to verify the post actually appeared:

1. Navigate to the profile page: `agent-browser open {profile_url}`
   - X: `https://x.com/{handle}` (without @)
   - LinkedIn: `https://linkedin.com/company/{slug}/posts/`
2. Wait for page load
3. Screenshot the page
4. Check if the new post content appears in the timeline
5. If confirmed → record post URL, set status to `verified`
6. If NOT visible → set `postUrl` to `"pending-verification"`, add to verify-queue.json
7. Report result to user

**CRITICAL:** NEVER write `url: null` in posted.json. Use `"pending-verification"` if URL is unknown.

### 6b. Update Queue

Update entry in `$QUEUE_FILE`:

**For immediate post:**
```json
{
  "status": "posted",
  "postedAt": "{ISO8601 now}",
  "postUrl": "{captured URL from API results or agent-browser}",
  "postBridgeId": "{post.id from API}"
}
```

**For scheduled post:**
```json
{
  "status": "scheduled",
  "scheduledFor": "{$SCHEDULE}",
  "postBridgeId": "{post.id from API}"
}
```

### 6c. Log to Posted History

Append to `$DRAFTS_DIR/posted.json` (create if doesn't exist):

```json
{
  "id": "{draft-id}",
  "posted_at": "{ISO8601}",
  "platform": "{x|linkedin}",
  "url": "{post URL}",
  "content_preview": "{first 100 chars}",
  "type": "{post type}",
  "image": "{path or null}",
  "method": "{post-bridge|agent-browser}",
  "post_bridge_id": "{API post ID or null}",
  "scheduled": "{true|false}"
}
```

### 6d. Update INDEX.md

If `$DRAFTS_DIR/INDEX.md` exists, update the draft's status line from "Draft" to "Posted" or "Scheduled" with date and URL.

## Step 7: Report

```
=================================================================
POST {SENT|SCHEDULED}
=================================================================

Draft: {draft-id} — "{title or first 50 chars}"
Platform: {X / LinkedIn}
Account: {handle}
Method: {Post-Bridge API / agent-browser}
Status: {Posted / Scheduled for {time}}
{URL: {post URL} — if available}
{Post-Bridge ID: {id} — if API}

Queue updated: {$QUEUE_FILE}
History logged: {$DRAFTS_DIR}/posted.json
=================================================================
```

If posting to both platforms, show a result line for each.

## Error Handling

**API key missing:**
```
ERROR: POST_BRIDGE_API_KEY not found.
Set it in settings/post-bridge/.env or run /social-setup.
```

**Account ID is placeholder:**
```
ERROR: Account ID for {profile}/{platform} not configured.
Connect the account in Post-Bridge dashboard and run setup.
```

**API error (4xx/5xx):**
1. Show error message from API response
2. If 401: "API key invalid or expired. Check settings/post-bridge/.env"
3. If 429: "Rate limited. Retry after {n} seconds." — offer to schedule instead
4. If 422: "Validation error: {details}" — show field errors
5. Set queue status to `post_failed`
6. Offer: retry, schedule for later, or cancel

**Agent-browser fallback error:**
1. If auth expired: prompt user to re-auth in headed mode
2. If posting failed: set queue status to `post_failed`, log error

## Rules

- Post-Bridge API is the primary path for X regular posts and LinkedIn posts
- Agent-browser is the fallback for X articles and X community posts
- Always show confirmation preview before posting — never auto-post
- Always update queue.json and posted.json after posting
- For `--schedule auto`, use the profile's `posting_times` from social-kit.yaml
- If the queue entry has a `content` field, use it directly. If not, read from `draftFile`.
- Respect profile/account boundaries — never post personal content to {company} account or vice versa
- When posting to "both" platforms, create a single Post-Bridge API call with both account IDs
- If content exceeds character limit, warn user and ask to edit before posting
- **CRITICAL: Never send raw draft file content as a post.** Always strip the markdown metadata header (# Title, **Status:**, **Type:**, ---) before posting. If the caption contains `#`, `**Status:**`, or `---` separators, something is wrong — abort and fix.
- For multi-option drafts (## Option A / B / C), extract only the recommended option's text. Never include option labels or code fences in the post.
- **CRITICAL: NEVER send test/exploratory API calls to production social accounts.** When discovering API field names or debugging endpoints, never use real account IDs. Build the full request locally first, verify field names from docs, and only hit the API once with the real post content. A test payload like `{"caption":"test"}` sent to a live account publishes immediately and cannot be deleted.
- **CRITICAL: ALWAYS verify delivery with agent-browser after posting.** Post-Bridge `status: "posted"` is unreliable — posts can show "posted" but never appear on the platform. After every post, use agent-browser to navigate to the actual social page (e.g. `x.com/getindigo`) and visually confirm the post is live. Never trust the API status alone.
- **ALWAYS check the target social page before posting.** Use agent-browser to view the current state of the profile page before sending a new post. This confirms context, avoids duplicate posts, and ensures the new post makes sense alongside what's already there.
- **CRITICAL: Post-Bridge splits content on `---` into multiple tweets/posts.** When posting X articles with `---` section breaks via Post-Bridge API, the `---` characters cause the API to split the content into a thread of multiple tweets instead of posting as a single long post. MUST strip or replace ALL `---` section breaks with double line breaks (`\n\n`) before sending the caption to Post-Bridge. This caused 6+ tweets to be posted from a single article.
- **CRITICAL: Post-Bridge media requires 2-step upload.** NEVER pass raw URLs in the `media` array — they silently fail (post shows "posted" but never delivers, post-results returns empty). ALWAYS use: 1) `POST /v1/media/create-upload-url` with `{mime_type, size_bytes, name}` → get `media_id` + `upload_url`, 2) `PUT` binary to `upload_url`, 3) pass `media_id` in the `media` array. The endpoint is `/v1/media/create-upload-url`, NOT `/v1/media/upload-url`.

## Usage Examples

```bash
# Post specific draft immediately
/post post-035

# Post next ready draft
/post next

# Schedule for specific time
/post post-035 --schedule '2026-02-14T09:00:00-07:00'

# Auto-schedule next draft
/post next --schedule auto

# Post to X only
/post post-035 --platform x

# Post to LinkedIn only, {company} profile
/post post-083 --platform linkedin --profile {company}

# Post to both platforms
/post post-035 --platform both
```
