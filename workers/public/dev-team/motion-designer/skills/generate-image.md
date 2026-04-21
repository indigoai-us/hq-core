# generate-image

Generate image using gnb (gemini-nano-banana).

## Arguments

`$ARGUMENTS` = `--prompt <description>` (required)

Optional:
- `--aspect <ratio>` - Aspect ratio: 1:1, 16:9, 9:16, 4:3
- `--variants <n>` - Number of variants (max 10)
- `--output <dir>` - Output directory
- `--type <logo|social|thumbnail>` - Preset type

## Process

1. Prepare prompt
2. Get human approval for prompt
3. Run gnb generate
4. Review generated images
5. Select best variant

## gnb Commands

```bash
gnb generate "prompt" --aspect 16:9 --variants 3
gnb logo "Brand Name" --style modern
gnb social "Post text" --platform instagram
gnb thumbnail "Video title"
```

## Human-in-the-loop

- Approve prompt before generation
- Select from generated variants
- Confirm final image
