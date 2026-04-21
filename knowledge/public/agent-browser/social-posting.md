---
type: guide
domain: [growth, operations]
status: canonical
tags: [social-posting, agent-browser, twitter, linkedin, automation]
relates_to: []
---

# Social Posting with agent-browser

## X/Twitter — Regular Post

```bash
agent-browser state load settings/personal/browser-state/x-auth.json
agent-browser open "https://x.com/compose/post"
agent-browser wait --load networkidle

# Check auth (detect login redirect)
# If URL contains "login", re-auth in --headed mode

agent-browser snapshot -i
agent-browser fill @eN "<post content>"

# If image needed:
agent-browser upload @eM "/path/to/image.png"

agent-browser find role button click --name "Post"
agent-browser wait --load networkidle
agent-browser get url  # Capture post URL
agent-browser close
```

## X/Twitter — Article

```bash
agent-browser state load settings/personal/browser-state/x-auth.json
agent-browser open "https://x.com/compose/article"
agent-browser wait --load networkidle
agent-browser snapshot -i

# Fill title and body via @refs from snapshot
agent-browser fill @eTitle "<title>"
agent-browser fill @eBody "<body content>"

# Upload cover image if needed
agent-browser upload @eImage "/path/to/image.png"

agent-browser find role button click --name "Publish"
agent-browser wait --load networkidle
agent-browser get url
agent-browser close
```

## X/Twitter — Thread

```bash
agent-browser state load settings/personal/browser-state/x-auth.json
agent-browser open "https://x.com/compose/post"
agent-browser wait --load networkidle
agent-browser snapshot -i

# Post first tweet
agent-browser fill @eN "<tweet 1>"
# Click "+" to add to thread
agent-browser find text "Add another post" click
agent-browser snapshot -i
agent-browser fill @eM "<tweet 2>"
# Repeat for additional tweets

agent-browser find role button click --name "Post all"
agent-browser wait --load networkidle
agent-browser get url  # Thread URL
agent-browser close
```

## LinkedIn

```bash
agent-browser state load settings/personal/browser-state/linkedin-auth.json
agent-browser open "https://www.linkedin.com/feed/"
agent-browser wait --load networkidle
agent-browser snapshot -i

agent-browser find text "Start a post" click
agent-browser wait 1000
agent-browser snapshot -i

agent-browser fill @eN "<post content>"

# If image:
agent-browser find role button click --name "Add media"
agent-browser snapshot -i
agent-browser upload @eM "/path/to/image.png"

agent-browser find role button click --name "Post"
agent-browser wait --load networkidle
agent-browser get url
agent-browser close
```

## Notes

- Always `snapshot -i` after navigation or DOM changes to refresh @refs
- Use `--session <name>` if running multiple browser tasks in parallel
- Auth state files at `settings/personal/browser-state/`
- See `auth-profiles.md` for bootstrap and re-auth flows
