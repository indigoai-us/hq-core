# social-verifier

Delivery verification worker. Confirms posts are actually live on social platforms.

## Skills

| Skill | What it does |
|-------|-------------|
| `check-results` | Poll Post-Bridge for delivery status |
| `verify-live` | Visual confirmation via agent-browser |
| `audit` | Delivery audit report |
| `backfill-urls` | Fix null URLs in posted.json |

## Usage

```bash
/run social-verifier check-results --profile {company}
/run social-verifier verify-live --profile personal
/run social-verifier audit --profile {company} --days 7
/run social-verifier backfill-urls --profile personal
```
