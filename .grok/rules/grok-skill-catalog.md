# hq-core: public
# Grok skill paths

Grok-only. Do not mirror into Claude hooks.

Canonical skill files live under **`.agents/skills/`**, not `.claude/skills/`.
Invoke skills with `/name`. Do not guess `.claude/skills/<name>/SKILL.md`.

On SessionStart the adapter writes a compact catalog (name + relative path,
not full SKILL.md dumps):

`workspace/sessions/<sid>/skill-catalog.txt`

Read that file when you need a path. If it is missing, list `.agents/skills/`
with a **scoped** `target_directory` — never Glob from HQ root.
