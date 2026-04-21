#!/bin/bash
# resize-screenshot.sh — Resize screenshot to max 1800px (longest dimension), in-place.
# Uses sips (macOS native). Falls back to magick if sips unavailable.
# Usage: resize-screenshot.sh <path-to-image>
#
# 1800px chosen to stay under the 2000px API limit with margin.
# JPEG at q=85 is visually lossless for audit work.

set -euo pipefail

MAX_DIM=1800
FILE="${1:-}"

[[ -n "$FILE" && -f "$FILE" ]] || { echo "resize-screenshot: file not found: $FILE" >&2; exit 1; }

# Get current dimensions via sips
W=$(sips -g pixelWidth "$FILE" 2>/dev/null | awk '/pixelWidth/{print $2}')
H=$(sips -g pixelHeight "$FILE" 2>/dev/null | awk '/pixelHeight/{print $2}')

[[ -n "$W" && -n "$H" ]] || { echo "resize-screenshot: cannot read dimensions" >&2; exit 2; }

if [[ "$W" -le "$MAX_DIM" && "$H" -le "$MAX_DIM" ]]; then
  echo "resize-screenshot: ${W}x${H} — within bounds, skipping"
  exit 0
fi

# Determine new size (preserve aspect ratio, shrink longest dimension to MAX_DIM)
if [[ "$W" -ge "$H" ]]; then
  NEW_W=$MAX_DIM
  NEW_H=$(( H * MAX_DIM / W ))
else
  NEW_H=$MAX_DIM
  NEW_W=$(( W * MAX_DIM / H ))
fi

echo "resize-screenshot: ${W}x${H} → ${NEW_W}x${NEW_H} ($FILE)"

if command -v sips &>/dev/null; then
  sips --resampleHeightWidth "$NEW_H" "$NEW_W" "$FILE" --out "$FILE" >/dev/null 2>&1
elif command -v magick &>/dev/null; then
  magick "$FILE" -resize "${MAX_DIM}x${MAX_DIM}>" "$FILE"
else
  echo "resize-screenshot: no image tool available (sips/magick)" >&2
  exit 2
fi

echo "resize-screenshot: done"
