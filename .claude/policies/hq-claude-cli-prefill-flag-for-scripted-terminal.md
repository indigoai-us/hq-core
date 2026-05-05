---
id: hq-claude-cli-prefill-flag-for-scripted-terminal
title: Use claude --prefill instead of AppleScript keystrokes when scripting Terminal launches
scope: global
trigger: scripting a Terminal launch of the claude CLI with a pre-populated prompt
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

ALWAYS: When you need to pre-populate the `claude` CLI's input box in a scripted Terminal launch, use the hidden `--prefill '<text>'` flag rather than AppleScript `keystroke`/`System Events` automation. The flag pre-fills the composer without submitting, so the user still reviews and presses Enter. Discover additional hidden flags by running `strings ~/.local/bin/claude | grep -i <keyword>` against the installed binary.

## Rationale

Scripted Terminal launches historically chained `open -a Terminal` + AppleScript keystroke injection to populate the `claude` prompt box, which broke frequently (focus races, quoting issues, Secure Keyboard Entry, accessibility permissions). The `claude` CLI ships an undocumented `--prefill` flag that injects the starting text directly, avoiding every AppleScript failure mode. `strings` against the binary is the fast path to surface other hidden flags without bisecting the JS bundle. Captured 2026-04-21 during HQ installer Terminal integration work.
