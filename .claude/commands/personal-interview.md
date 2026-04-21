---
description: Deep interview to populate your profile and social voice
allowed-tools: Read, Write, Edit, AskUserQuestion, Glob, Bash
visibility: public
---

# Personal Interview

Deep conversational interview to build a rich profile and authentic voice guide. Run this after `/setup` to give your workers real context about who you are and how you communicate.

## Context to Load

1. Read `agents-profile.md` if it exists (owner profile + working preferences)
2. Read `agents-companies.md` if it exists (company roster + roles)
3. Read `companies/*/knowledge/profile.md` if it exists
4. Read `companies/*/knowledge/voice-style.md` if it exists

Use existing content as a starting point — don't re-ask what's already captured.

## Interview Flow

Ask questions **one at a time**. Keep it conversational, not interrogative. Adapt follow-ups based on previous answers.

### Block 1: Background

1. What do you do day-to-day? (roles, responsibilities, projects)
2. What's your professional background in 2-3 sentences?
3. What industry or domain do you work in?

### Block 2: Goals & Priorities

4. What are you trying to accomplish this quarter/year?
5. What tasks drain your energy that you'd love to hand off to AI?
6. What does "done well" look like for you?

### Block 3: Communication Style

7. How would your coworkers describe your communication style?
8. When you write an email or message, do you tend to be brief or detailed?
9. Do you use humor, emojis, or keep things strictly professional?
10. Are there phrases or patterns you naturally use? (e.g., "let's ship it", "what's the blocker")

### Block 4: Writing Voice

11. Share 2-3 examples of things you've written that feel authentically "you" — tweets, emails, messages, anything. (Or paste links/screenshots and I'll analyze them.)
12. What tone do you aim for in public content? (e.g., authoritative, approachable, provocative, educational)
13. Are there writers, creators, or voices you admire or want to sound like?
14. What should your writing NEVER sound like?

### Block 5: Work Patterns

15. How do you prefer to review work — detailed walkthrough or just show me the result?
16. When should AI ask vs. just decide?
17. What tools/platforms do you use daily?

### Block 6: Personal Context (optional)

18. Anything else your AI workers should know about you — values, pet peeves, preferences?

## Output

After the interview, update these files:

### `companies/{company}/knowledge/profile.md`

```markdown
# {Name}'s Profile

## About
{Rich description from interview — role, background, domain}

## Goals
{Current priorities and what success looks like}

## Delegation Preferences
{What to hand off, what to keep, autonomy level}

## Work Patterns
- Review style: {preference}
- Decision threshold: {when to ask vs. decide}
- Tools: {daily tools/platforms}

## Context Notes
{Anything else — values, pet peeves, preferences}
```

### `companies/{company}/knowledge/voice-style.md`

```markdown
# {Name}'s Voice Style

## Tone
{Based on interview — e.g., direct, warm, no-nonsense}

## Communication Style
- Length: {brief/detailed/depends}
- Formality: {casual/professional/adaptive}
- Humor: {yes/no/situational}

## Patterns
- Phrases: {natural phrases they use}
- Never: {what to avoid}

## Public Voice
- Target tone: {authoritative/approachable/etc}
- Influences: {writers/voices they admire}
- Anti-patterns: {what NOT to sound like}

## Examples
{2-3 real examples from the interview, quoted}
```

### `agents-profile.md` + `agents-companies.md`

Update or create both files. `agents-profile.md` holds the owner profile + working preferences (loaded for writing/comms tasks). `agents-companies.md` holds the three-tier company roster (loaded for company routing). The first line of `agents-profile.md` MUST stay `# {Name} - Profile` — the SessionStart hook `inject-local-context.sh` parses the owner name from that exact pattern.

## Rules

- One question at a time. Wait for response.
- If user says "skip" or "pass", move on gracefully.
- Don't fabricate answers — only write what was actually said.
- If profile/voice files already exist, merge new content with existing. Don't overwrite without asking.
- Keep the tone of the interview itself warm and conversational — not clinical.
- After finishing, suggest: "Run `/newworker` to create your first worker, or `/plan` to plan a project."
