---
id: blog-post-x-draft
title: Publish blog before sharing on X or LinkedIn
scope: command
trigger: /post, /contentidea, daily-social, blog publishing, personal-website deploy, article sharing
enforcement: hard
---

## Rule

When publishing a new blog article to {your-name}.com (writing MDX to `repos/private/personal-website/src/content/blog/`), always draft an X post to share the article before deploying.

**Workflow:**
1. Write the blog article MDX
2. Draft an X teaser post for @{your-name} that hooks the reader and links to the article
3. Show the draft to the user for approval before posting
4. Deploy the site so the OG image is live before the post goes out
5. Post via Post-Bridge API (account ID 34528)
6. Update `workspace/social-drafts/blog-queue.json` — set item status to `published` after deploy, `done` after share

**X post format:**
- Match {your-name}'s voice: direct, declarative, first-person, short sentences
- Open with a hook (the insight or contrarian take)
- 3-5 short paragraphs max
- End with the article URL (`https://{your-name}.com/blog/{slug}`)
- No hashtags, no emojis, no "check out my new article" framing

**Hard gates:**
- NEVER submit article share to Post Bridge before blog URL is live and returning 200
- NEVER post full article text directly to X — always teaser + link
- ALWAYS update blog-queue.json status after each pipeline step

