# Personal Assistant Setup

Set up an email digest worker that creates a "Presidential Daily Brief" from your unread emails.

## What You'll Build

- **Email Worker**: Fetches and classifies your emails
- **Daily Digest**: HTML summary with urgent/actionable/fyi sections
- **Automated Schedule**: Runs daily at your preferred time

## Prerequisites

- Email account(s) you want to digest
- (Optional) API credentials for your email provider

## Quick Start

1. Run `/setup` and select "Personal Assistant"
2. Follow the PRD tasks in order:
   - Configure email accounts
   - Customize worker schedule
   - Run first digest

## Files Created

```
workers/assistant/email/
├── worker.yaml      # Worker configuration
└── prd.json         # Task tracking

settings/email/
└── accounts.json    # Your email accounts (gitignored)

workspace/digests/
└── {date}-pdb.html  # Generated digests
```

## Next Steps After Setup

- Run `/digest` to generate a digest on-demand
- Adjust classification rules in worker.yaml
- Add more email accounts as needed
