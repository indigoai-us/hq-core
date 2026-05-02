---
id: ascii-art-character-verify
title: Verify ANSI Shadow block art characters against reference map
scope: command
trigger: composing block art for /ascii-graphic or social graphics
enforcement: soft
public: true
---

## Rule

When manually composing ANSI Shadow block art, ALWAYS verify each character against the skill's character map before screenshotting. Characters T (`╚══██╔══╝` on row 1) and 7 (`╚═════██║` on row 1) are visually similar and easily confused. Same for 2 vs 0 (row patterns differ in middle rows).

Use the compact 4-row font for version numbers and multi-character secondary text — it's less error-prone than the 6-row ANSI Shadow for dense strings like "V7.0.0".

## Rationale

Session 2026-03-09: composed "V7.0.0" but rendered "VT2.0" — used T character instead of 7, and 2 instead of 0 in the ANSI Shadow font. Required re-edit and re-screenshot. Switching to compact font for the version fixed it cleanly.
