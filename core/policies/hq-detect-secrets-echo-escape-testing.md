---
id: hq-detect-secrets-echo-escape-testing
title: Do not use echo to test the detect-secrets hook — it has a deliberate false-positive escape
scope: global
trigger: When verifying `.claude/hooks/detect-secrets.sh` behavior, writing regression tests for the hook, or constructing a known-bad command to exercise the block path
enforcement: soft
public: true
version: 1
created: 2026-04-18
updated: 2026-04-18
source: session-learning
---

## Rule

NEVER rely on `echo "Bearer <token>"`, `echo "sk-..."`, or similar `echo <secret>` commands as a positive test for `.claude/hooks/detect-secrets.sh`.

The hook has an explicit false-positive escape: any command whose first token matches `echo|grep|sed|awk|regex|pattern` followed by whitespace is treated as "the user is demonstrating a pattern, not exfiltrating a real secret" and is **allowed through without a block**. A passing `echo` test therefore proves nothing about the hook's block path.

Correct ways to exercise the block path:

- **Non-listed command** (e.g. `ls "<fake-token>"`, `printf '%s' "sk-fakeabcdef..."`) — not in the escape list, so the regex match fires and the hook blocks.
- **Direct JSON invocation** — construct the PreToolUse hook input JSON and pipe it to `bash .claude/hooks/detect-secrets.sh` manually. Gives exact control over the tested command string.
- **Codex/CI test**: use a non-echo wrapper so the regex hits normally.

## Rationale

Found while sanity-checking the secret-guard during the rtk trial session. The first test — `echo "Bearer sk-test-12345..."` — passed silently, which initially looked like a hook failure. The hook source actually contains an intentional escape clause for `echo`/`grep`/`sed`/`awk`/`regex`/`pattern` to avoid blocking legitimate documentation and test scripts. The lesson: if you want to confirm the hook blocks, pick a command verb that isn't in that escape list, or feed the hook stdin directly.
