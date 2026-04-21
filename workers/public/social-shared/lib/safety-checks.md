# Safety Checks

Reusable validation functions for social-team workers. Every worker MUST run relevant checks before their action.

## Content Safety

### isMetadataPresent(content)
Detects markdown metadata that should have been stripped:
- Lines starting with `#` (heading)
- Lines containing `**Status:**`, `**Type:**`, `**Platform:**`, `**Created:**`, `**Account:**`
- Lines that are just `---` (separator)
- Lines starting with `## Option` (multi-option labels)
- Content wrapped in code fences

**Action:** ABORT posting. Return to social-reviewer for re-review.

### isTestMessage(content)
Flags test/placeholder content:
- Content shorter than 15 characters
- Contains "test", "hello world", "lorem ipsum", "asdf", "xxx" (case-insensitive)
- Is exactly "test" or starts with "test_" or "test-"
- Contains `dry_run`, `debug`, or `placeholder`

**Action:** BLOCK. Never send to Post-Bridge. This is the #1 cause of accidental production posts.

### isWithinCharLimit(content, platform)
Character limits:
- X regular: 280 chars
- X premium/long: 25,000 chars
- X article: no strict limit
- LinkedIn post: 3,000 chars

**Action:** WARN user if over limit. Offer to truncate or edit.

### hasTemporalMismatch(content, postingDate)
Detects day-of-week references that don't match the intended posting date:
- Regex: `/\b(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\s+(thought|morning|afternoon|evening|reflection|reminder|vibe|vibes|mood|energy)/i`
- Also catches: "TGIF" (must be Friday), "this weekend" (must be Saturday/Sunday), "hump day" (must be Wednesday)
- If `scheduledFor` is set in queue entry, use that date. Otherwise use today's date.
- Compare extracted day against `postingDate` day-of-week.

**Action:** BLOCK. Reject with "temporal mismatch — content references {day} but posting on {actual day}. Remove day reference or schedule for the correct day."

## Account Safety

### validateProfileMatch(accountId, profileName, configPath)
Prevents cross-company posting:
1. Read `settings/post-bridge/config.json`
2. Look up `profiles.{profileName}` accounts
3. Verify `accountId` belongs to this profile
4. If mismatch: BLOCK — "Account ID {id} does not belong to profile {name}"

**Action:** HARD BLOCK. Never allow cross-profile posting.

### validateImageExists(imagePath)
Confirms referenced image file exists on disk before uploading.

**Action:** WARN if missing. Post without image or abort.

## Pre-Post Checklist (for social-publisher)

Before EVERY Post-Bridge API call, run ALL checks in order:
1. `isTestMessage(content)` — BLOCK if true
2. `isMetadataPresent(content)` — BLOCK if true
3. `isWithinCharLimit(content, platform)` — WARN if over
4. `hasTemporalMismatch(content, postingDate)` — BLOCK if mismatch
5. `validateProfileMatch(accountId, profile)` — BLOCK if mismatch
6. `validateImageExists(imagePath)` — WARN if missing
7. Show full preview to user — WAIT for confirmation
8. User confirms → proceed with API call

If ANY check blocks, do NOT proceed. Report the failure and what needs fixing.
