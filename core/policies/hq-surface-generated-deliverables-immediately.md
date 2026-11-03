---
id: hq-surface-generated-deliverables-immediately
title: Show every newly generated deliverable to the user at once, with a small preview when it is over the viewer limit
when: senduserfile || ffmpeg || (generated && (video || image))
on: [PostToolUse, UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-10-22
updated: 2026-10-22
source: user-correction
tags: [deliverables, files, ux, previews]
---

## Rule

This rule applies to the session that talks to the user. A sub-agent, background worker, headless or overnight run, or a bot returns file paths to its parent, which decides what to surface; a bot's outbound message still follows the ask-before-sending rules.

1. When the session generates a deliverable for the user (a file, image, video, document, or any other work product), show it in the same turn with `SendUserFile` or the host's equivalent file-sending tool. Do not only describe where it was saved, and do not wait for the user to ask where it is.
2. A version the session considers ready for the user counts as a new deliverable. After a rebuild or a fix, send the new file again. Renders inside an iteration loop that the user has not asked to see stay quiet, as the quiet-by-default rule says.
3. When the file is larger than the host's remote viewer limit (30 MB in the Claude desktop app; other hosts differ), make a small preview copy and send that, naming the full file's path in the caption. Minimum preview: for a video, the first 30 seconds scaled to 720p (`ffmpeg -t 30 -vf scale=-2:720`), for an image a copy no wider than 1600 px, for a document the first five pages. Do this without being asked.
4. In a host without a file-sending tool, open the file for the user or give one clickable link. A bare path in prose is not surfacing.
5. When a review-deliverable format rule applies (for example an opened HTML page or a deploy link instead of a markdown file), that rule decides the format; this rule only requires that the user sees the result in the same turn.
6. A deliverable that is meant to be a URL (a site, a page, a shared artifact) goes through `/deploy` or `/hq-share` as `hq-prefer-native-capabilities` says; this rule then asks that the resulting link is shown in the same turn.
7. The file card, link or caption is restated in the turn's final message, as the active output style requires, so a file sent mid-turn is not left only in a folded step.

## Rationale

A deliverable the user cannot see is unfinished from the user's side, and a bare path puts the lookup on the user.
