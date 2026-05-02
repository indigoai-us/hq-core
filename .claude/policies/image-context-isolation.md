---
id: hq-image-context-isolation
title: Image context isolation — delegate image reading to sub-agents
scope: global
trigger: Read tool on image files (.png/.jpg/.jpeg/.gif/.webp), preview_screenshot, Chrome MCP screenshot, batch image verification, export verification, design review
enforcement: hard
tier: 1
version: 1
created: 2026-03-30
updated: 2026-03-30
source: back-pressure-failure
learned_from: empire-os export-graphics session crash (2026-03-30)
public: true
---

## Rule

The parent session must never accumulate more than ~10 images in its context window. When reading, verifying, or analyzing image files, delegate to a sub-agent.

### Delegation pattern

1. Parent spawns a sub-agent via Agent tool: `"Read {path} and describe: dimensions, content, visual quality, any issues. Return text findings only."`
2. Sub-agent reads the image in its isolated context, returns a text description
3. Parent receives text — zero image bytes in its context
4. For batch verification (multiple images), spawn one sub-agent per batch of 3-5 images

### MUST delegate (hard rule)

- Verifying batch-generated images (social graphics, export scripts, OG images)
- Any image known or likely to be >1500px in any dimension (social graphics at 1080x1080 with 2x DPR = 2160px actual)
- When total session images already exceed ~8
- Multi-page QA audits (5+ pages)
- Any `companies/*/data/` image exports

### MAY skip delegation (exceptions)

- Reading a small icon, favicon, or thumbnail known to be under 500px
- First 1-2 screenshots in a fresh session with no other images
- Reading an image as part of code review (looking at file metadata, not visual content)

### Tool-specific rules

| Tool | Approach |
|------|----------|
| `Read` on .png/.jpg/.jpeg/.gif/.webp | Sub-agent delegation (default). Direct only for small icons or first 1-2 in session |
| `agent-browser screenshot` | Screenshot to file → `bash scripts/resize-screenshot.sh {path}` → sub-agent Read |
| `preview_screenshot` (MCP) | AVOID in multi-image sessions. Use `preview_snapshot` + `preview_inspect` (text-based, zero image overhead) |
| Chrome MCP `computer screenshot` | AVOID. Use `read_page` / `find` instead |
| `preview_snapshot` / `preview_inspect` | Always safe — text-based, no image bytes |

### Resize safety net

Before any sub-agent reads an image that might exceed 1800px, run:
```bash
bash scripts/resize-screenshot.sh {path}
```
This protects even the sub-agent's context from oversized images.

## Rationale

Claude API enforces a 2000px max dimension per image when ~20+ images accumulate in a conversation ("many-image mode"). When the parent session tried to verify them via Read, it hit the dimension limit and crashed the session.

Sub-agents have isolated context windows — each sees only the images it reads, never triggering the many-image limit. The parent session accumulates zero images, allowing unlimited image verification through delegation.

This policy supersedes the narrower `qa-screenshot-isolation` policy (which only covered 5+ page QA audits). Image context isolation applies universally to all image reading.
