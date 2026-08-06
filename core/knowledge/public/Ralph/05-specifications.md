---
type: reference
domain: [engineering, product]
status: canonical
tags: [ralph, specifications, prd, acceptance-criteria, story-format]
relates_to: []
---

# Specifications & PRDs

## The Role of Specifications

Specifications are the "fuel" for the Ralph loop. They define what needs to be built and how success is measured.

> "I don't write my specs. I generate them. Then I review them and edit them by hand. And then I just let it rip with Ralph."
> — Geoffrey Huntley

## PRD Structure (Product Requirements Document)

Anthropic recommends a JSON-based PRD format:

```json
{
  "project": "video-editor",
  "version": "1.0",
  "features": [
    {
      "id": "feature-001",
      "title": "Beat Display",
      "description": "Display beat markers as visual indicators on clips",
      "user_story": "As a video editor, I want to see beat markers on my clips so I can align edits to music",
      "acceptance_criteria": [
        "Three orange ellipses dots appear below clips with beats",
        "Dots are visible in both light and dark mode",
        "Dots update when beats are modified"
      ],
      "priority": "high",
      "passes": false
    },
    {
      "id": "feature-002",
      "title": "Beat Animation",
      "description": "Animate beat markers on playback",
      "acceptance_criteria": [
        "Dots pulse on beat during playback",
        "Animation is smooth at 60fps",
        "Animation respects reduced-motion preferences"
      ],
      "priority": "medium",
      "passes": false
    }
  ]
}
```

### Key Fields

| Field | Purpose |
|-------|---------|
| `id` | Unique identifier for tracking |
| `title` | Human-readable name |
| `description` | What the feature does |
| `user_story` | Who benefits and why |
| `acceptance_criteria` | Testable requirements |
| `priority` | Order of implementation |
| `passes` | Whether the feature is complete |

## The `passes` Flag

The `passes` boolean is critical:

> "Each one of these items in this PRD has a passes flag on it. This tells the LLM whether this is actually passing or not in the application code. So this forms not only a product requirements document but also a test harness."
> — Matt Pocock

When Ralph runs:
1. It reads the PRD
2. Finds items where `passes: false`
3. Picks ONE item to implement
4. Implements and verifies
5. Updates `passes: true` if successful

## Generating Specifications

### Forward Generation (Building New)

1. Start with high-level requirements
2. Use AI to expand into detailed specs
3. Review and refine manually
4. Load into PRD format

Example prompt:
```
Generate detailed user stories for a video editing application.
Include acceptance criteria that can be automatically verified.
Format as JSON with id, title, description, acceptance_criteria, and passes fields.
```

### Reverse Generation (Clean Room)

> "Run Ralph in reverse to create a clean room specification."
> — Geoffrey Huntley

1. Point at existing codebase or product
2. AI generates specifications from behavior
3. Review for completeness
4. Use specs to build clean implementation

This enables:
- Product cloning (legally)
- Documentation generation
- Understanding legacy systems
- Competitive analysis

## Specification Quality

### Good Specifications

```json
{
  "id": "auth-001",
  "title": "User Login",
  "description": "Secure user authentication with email/password",
  "acceptance_criteria": [
    "Login form has email and password fields",
    "Password field masks input",
    "Submit button is disabled until both fields have content",
    "Invalid credentials show error message",
    "Successful login redirects to dashboard",
    "JWT token is stored in httpOnly cookie"
  ],
  "passes": false
}
```

Characteristics:
- Specific and measurable
- Independently testable
- Small enough to complete in one iteration
- Clear success criteria

### Bad Specifications

```json
{
  "id": "auth-001",
  "title": "Authentication System",
  "description": "Build the entire auth system",
  "acceptance_criteria": [
    "Users can log in",
    "It works well",
    "It's secure"
  ],
  "passes": false
}
```

Problems:
- Too broad
- Vague criteria
- Not independently testable
- Impossible to verify "works well"

## Iterating on Specifications

Specifications should evolve:

```
Initial Spec → AI Expands → Human Reviews → AI Implements →
Human Verifies → Adjust Spec → Repeat
```

> "I do a loop by hand... if it doesn't seem right, I go back, I update the specs, I try it again. Prototypes are now free, they're now cheap."
> — Geoffrey Huntley

## Integration with agents.md

Your `agents.md` should reference the PRD:

```markdown
# Task Management

When implementing features:
1. Read `plans/prd.json` for current tasks
2. Select ONE item where `passes: false`
3. Implement the feature
4. Run all tests
5. If tests pass, update `passes: true`
6. Commit with message referencing the feature id

# PRD Format

Features are defined in JSON with these fields:
- id: Unique identifier
- title: Feature name
- acceptance_criteria: List of verifiable requirements
- passes: Boolean indicating completion status
```

## The Progress File

Alongside the PRD, maintain a progress file:

```
# progress.txt

[2026-01-13 10:30:15] Starting feature: feature-001 (Beat Display)
[2026-01-13 10:32:45] Implemented BeatIndicator component
[2026-01-13 10:33:12] Tests passing: 5/5
[2026-01-13 10:33:18] Committed: a1b2c3d "feat: add beat display indicators"
[2026-01-13 10:33:20] Updated PRD: feature-001.passes = true
[2026-01-13 10:33:25] Starting feature: feature-002 (Beat Animation)
```

This provides:
- Audit trail
- Context for subsequent runs
- Human oversight capability
- Debugging information
