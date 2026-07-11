---
id: hq-confirm-creative-direction
title: Confirm Creative Direction Before Building
when: design || brand
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
version: 1
created: 2026-04-02
updated: 2026-04-02
source: session-learning
public: true
---

## Rule

1. **Before building any creative deliverable, present the intended direction and get explicit approval.** Describe the visual style, color palette, tone, layout approach, and any strong aesthetic choices in 3-5 bullet points. Do not start building until the user confirms the direction.
2. **For UI/visual work, offer 2-3 direction options when the brief is ambiguous.** Example: "Option A: Minimal/clean with muted tones. Option B: Bold/expressive with saturated colors. Option C: Dark luxury with gold accents. Which direction?" Let the user choose before investing build effort.
3. **When building something with high subjective risk** (full-page designs, brand identities, presentation decks, marketing sites), build the smallest representative sample first — one screen, one section, one slide — and get feedback before scaling to the full deliverable.
4. **Treat explicit user aesthetic preferences as constraints, not suggestions.** If the user says "clean and minimal," do not add decorative elements, animations, or bold color choices. If the user says "professional," do not interpret that as "cyberpunk."
5. **If the user rejects a direction, do not iterate on the rejected approach.** Ask what specifically was wrong, confirm the new direction, and start fresh from the revised brief.

## Rationale

A 7-screen cyberpunk CLI mockup was built, then rejected as "over the top and ugly — too many colors, too fast." The entire deliverable required a complete rewrite with a different design philosophy. The effort was wasted because the agent chose a strong aesthetic direction without checking whether the user wanted that style. A 30-second direction check would have saved hours of build and rebuild time.
