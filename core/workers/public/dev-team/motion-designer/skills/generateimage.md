---
description: Generate images via Gemini Nano Banana (gnb)
allowed-tools: Bash, Read, AskUserQuestion
argument-hint: <prompt> [--variants N] [--aspect 16:9|1:1|9:16]
visibility: private
---

# /generateimage - Quick Image Generation

**Prompt:** $ARGUMENTS

## Process

1. Parse args - extract prompt and flags (--variants, --aspect, --output)
2. Run gnb from its directory
3. Open generated images
4. Report output path

## Execution

```bash
cd ~/Documents/HQ/repos/private/gemini-nano-banana && npx gnb generate "{prompt}" --open {flags}
```

Default flags if not specified:
- `--variants 1`
- `--aspect 1:1`

## Common Patterns

| Use Case | Command |
|----------|---------|
| Social content | `--aspect 16:9 --variants 10` |
| Logo | `gnb logo "{name}"` |
| Remix existing | `gnb remix {image} "{prompt}"` |
| Thumbnail | `gnb thumbnail "{prompt}"` |

## Output Location

Images save to: `repos/private/gemini-nano-banana/output/`

## Style Tips (from CLAUDE.md)

For best results, include:
- Lighting (golden hour, dramatic, soft ambient)
- Style (photorealistic, magic realism, dreamlike)
- Composition (shallow DOF, cinematic, aerial)
- Mood (peaceful, aspirational, contemplative)
