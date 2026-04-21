# Social Media Worker Setup

Set up a content worker that helps you maintain a consistent social media presence.

## What You'll Build

- **Voice Style Guide**: Document your authentic writing voice
- **Content Worker**: Generates drafts matching your style
- **Content Queue**: Organized pipeline of ideas → drafts → posts

## Supported Platforms

- X (Twitter)
- LinkedIn
- (Add more as needed)

## Quick Start

1. Run `/setup` and select "Social Media Worker"
2. Follow the PRD tasks in order:
   - Create voice style guide
   - Seed content queue with ideas
   - Generate first draft

## Files Created

```
knowledge/{your-name}/
├── profile.md       # Your identity and positioning
└── voice-style.md   # Writing voice documentation

workers/social/{platform}/
├── worker.yaml      # Worker configuration
└── queue.json       # Content queue

social-content/drafts/
├── INDEX.md         # Draft inventory
├── x/               # X/Twitter drafts
└── linkedin/        # LinkedIn drafts
```

## Content Commands

- `/contentidea {idea}` - Transform idea into full content suite
- `/suggestposts` - Get strategic posting suggestions
- `/post` - Post or schedule content (replaces `/post-now` and `/scheduleposts`)

## Voice Style Tips

Your voice-style.md should include:
- **Tone**: Professional? Casual? Direct?
- **Patterns**: Phrases you use, sentence structures you prefer
- **Avoid**: Things that don't sound like you
- **Examples**: Real posts that capture your voice

## Next Steps After Setup

- Run `/suggestposts` to get content ideas
- Run `/contentidea {topic}` to build out an idea
- Run `/post` when ready to post or schedule
