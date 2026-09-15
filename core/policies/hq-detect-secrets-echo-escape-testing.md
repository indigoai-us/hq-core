---
id: hq-detect-secrets-echo-escape-testing
title: The detect-secrets hook has no keyword escape — echo a secret and it blocks
when: secret || credential || credentials || password || passphrase || token || apikey || api_key
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: hard
public: true
version: 3
created: 2026-04-18
updated: 2026-09-15
source: session-learning
---

## Rule

`.claude/hooks/detect-secrets.sh` blocks a secret-shaped literal regardless of
which command carries it. `echo`, `grep`, `sed`, and `awk` get no special
treatment. `echo "sk-..." | pbcopy`, `echo "$TOKEN" >> .env`, and
`sed -i s/<key>/x/ file` all block, on the Bash path and on the
Write/Edit/MultiEdit/NotebookEdit file-content path alike.

Two consequences follow, and both matter:

1. **`echo <secret>` is now a valid positive test.** If you are sanity-checking
   the guard, an `echo`-based case proves what it looks like it proves.
2. **Never reintroduce a command-keyword carve-out.** Suppression must key on
   the *shape of the surrounding text* — a comment line, a quoted wildcard
   pattern — never on which command verb appears somewhere on the line.

Only two suppressions remain, and they are the supported ways to write a
secret-shaped example without tripping the guard:

- **Comment lines.** A line whose first non-space character is `#` is allowed.
- **Quoted wildcard patterns.** `"sk-*"` and friends are allowed.

For anything else — a fixture, a test, a doc that needs a key-shaped value on a
non-comment line — **assemble the value from fragments** so the literal never
appears:

```bash
AWS_KEY="AKIA""IOSFODNN7""EXAMPLE"
```

When you split, break the *token* the pattern matches, not the character in
front of it. Every pattern carries a left boundary of `(^|[^a-zA-Z0-9])`, so a
quote placed immediately before `sk-` **satisfies** the boundary and the line
still matches. Split after the `sk`, not before it.

## Do not widen the patterns without the boundary

Each pattern is anchored with `(^|[^a-zA-Z0-9])`. Without it, `sk-` matches
mid-word and ordinary HQ filenames read as credentials — `a-risk-...`,
`hq-task-...`, `controller-disk-...` all contain `sk-` followed by twenty-plus
word characters. Removing the boundary makes routine file work unblockable-by-
design, which is how a security control gets switched off in practice.

The runtime hook and the shared catalog at `core/scripts/lib/secret-patterns.sh`
must stay in sync; `core/scripts/tests/hq-delegate-bundle.test.sh` asserts the
catalog is a superset of the hook's list.

## Rationale

Version 1 and 2 of this policy documented the opposite rule. The hook used to
treat any line matching `(echo|grep|sed|awk|regex|pattern)[[:space:]]` as a
harmless "pattern reference" and allow it, and this policy told agents that an
`echo`-based test proved nothing. That was an accurate description of the code
and an indefensible design:

- `echo <secret> | pbcopy`, `echo <secret> >> file`, and `echo <secret> | curl`
  are precisely how a credential leaks into a transcript, a log, or a synced
  file. The guard failed open on its entire primary threat model.
- The keyword match was **unanchored**, so it was never limited to the first
  token as earlier versions of this policy claimed. Appending `&& echo ok` to
  any command disarmed the detector for that line.
- After the 2026-09-07 change that extended scanning to file content, the same
  escape applied per line of a written file — so a secret written into a file
  under `companies/` (which syncs to the vault and to teammates) passed if the
  line happened to mention `echo`.

Reported as hq-core#91 and fixed by removing the carve-out outright. The
token-boundary anchoring landed in the same change because it had to: measured
against a corpus of roughly 93,000 real shell commands, removing the carve-out
alone converted mid-word `sk-` matches in everyday policy and knowledge
filenames into hard blocks. With both changes the detector blocks fewer
commands overall than before *and* closes the bypass — the false positives it
sheds were never credentials, and the cases it gains always were.
