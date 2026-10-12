---
id: hq-image-context-isolation
title: Image context isolation — bound bytes, not image count
when: .png || .jpg || .jpeg || .gif || .webp
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
tier: 1
version: 3
created: 2026-03-30
updated: 2026-10-12
source: back-pressure-failure
learned_from: an export-graphics session crash; lake-house-group weekly Codex drain
public: true
---

## Rule

Do not inline large image bytes into the parent session. Cost is file size, not how many images you opened. Six images that together decode past the context window are still a violation even when the count stays under ten.

Mechanical control (this is the control; the rest of this file is guidance):

- PreToolUse hook `image-context-guard` denies a `Read` / `view_image` of a local `.png`/`.jpg`/`.jpeg`/`.gif`/`.webp` over **2 MiB**, or a ninth distinct image in the same session, or Codex `detail: original`.
- Wired in `.claude/hooks/hook-registry.json` (Read and view_image) and all three `hook-gate.sh` profiles.
- Escape hatch: `HQ_ALLOW_INLINE_IMAGE=1`, or the literal token `ALLOW_INLINE_IMAGE`.

When you need to inspect an image, delegate. The parent session should accumulate text findings, not pixels.

### Delegation pattern

1. Parent spawns a sub-agent via Agent tool: `"Read {path} and describe: dimensions, content, visual quality, any issues. Return text findings only."`
2. Sub-agent reads the image in its isolated context, returns a text description
3. Parent receives text — zero image bytes in its context
4. For batch verification (multiple images), spawn one sub-agent per batch of 3-5 images, after resizing

### MUST delegate (hard rule)

- Any image over 2 MiB, or unknown size, or likely >1500px in any dimension
- Verifying batch-generated images (social graphics, export scripts, OG images)
- When this session has already inlined several images
- Multi-page QA audits (5+ pages)
- Any `companies/*/data/` image exports

### MAY skip delegation (exceptions)

- Reading a small icon, favicon, or thumbnail known to be under 500px and well under 2 MiB
- First 1-2 screenshots in a fresh session with no other images, after resize
- Reading an image as part of code review (looking at file metadata, not visual content)

### Tool-specific rules

| Tool | Approach |
|------|----------|
| `Read` on .png/.jpg/.jpeg/.gif/.webp | Sub-agent delegation (default). Direct only for small icons or first 1-2 in session. The PreToolUse guard blocks oversize / over-count reads. |
| `view_image` (Codex) | Same byte and session caps. Never pass `detail: original`. |
| `agent-browser screenshot` | Screenshot to file → `bash core/scripts/resize-screenshot.sh {path}` → sub-agent Read |
| `preview_screenshot` (MCP) | AVOID in multi-image sessions. Use `preview_snapshot` + `preview_inspect` (text-based, zero image overhead) |
| Chrome MCP `computer screenshot` | AVOID. Use `read_page` / `find` instead |
| `preview_snapshot` / `preview_inspect` | Always safe — text-based, no image bytes |

### Resize safety net

Before any sub-agent reads an image that might exceed 1800px, run:
```bash
bash core/scripts/resize-screenshot.sh {path}
```
This protects even the sub-agent's context from oversized images.

## Rationale

A count cap ("under ~10 images") does not bound cost. One September call returned 14.3M characters from six images — under the count rule, larger than the context window, and silent. The parent session then burned through a weekly Codex allowance with no warning.

Claude API also enforces a 2000px max dimension per image when many images accumulate ("many-image mode"). Count-only guidance plus `enforcement: soft` and no hook meant nothing ever checked the expensive variable.

The PreToolUse guard measures bytes and per-session distinct reads. Prompt text remains guidance for delegation; the hook is the control. A policy only a well-behaved agent can violate is not a control.

This policy supersedes the narrower `qa-screenshot-isolation` policy (which only covered 5+ page QA audits). Image context isolation applies universally to all image reading.
