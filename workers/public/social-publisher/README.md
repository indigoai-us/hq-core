# social-publisher

Posting worker for the social-team. The only worker authorized to call Post-Bridge API.

## Skills

| Skill | What it does |
|-------|-------------|
| `post` | Post a specific approved draft |
| `post-next` | Post the next approved draft in queue |
| `schedule` | Schedule a draft for a future time |
| `schedule-batch` | Schedule all approved drafts at posting times |
| `cancel` | Cancel a scheduled post |

## Usage

```bash
/run social-publisher post post-035 --profile {company}
/run social-publisher post-next --profile personal
/run social-publisher schedule post-035 --profile {company} --time auto
/run social-publisher schedule-batch --profile personal
/run social-publisher cancel abc-123-post-bridge-id
```

## Safety Protocol

Every post goes through:
1. Gate check (must be `approved`)
2. Content safety checks (metadata, test, limits, profile match)
3. Pre-post page check (agent-browser)
4. User confirmation preview
5. Post-Bridge API call
6. Delivery polling (5s/15s/30s/60s retries)
7. Visual verification (agent-browser)
8. Queue + posted.json update
