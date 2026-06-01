---
id: hq-hook-json-build-with-jq-not-unquoted-heredoc
title: Build hook additionalContext JSON with jq, never an unquoted heredoc containing backticks
scope: global
trigger: a hook (PreToolUse/SessionStart/PostToolUse/etc.) emits hookSpecificOutput.additionalContext JSON containing a message body
enforcement: hard
public: true
version: 1
created: 2026-05-27
updated: 2026-05-27
source: session-learning
tags: [hooks, security, shell-injection]
---

## Rule

NEVER emit a hook's `hookSpecificOutput.additionalContext` JSON via an unquoted bash heredoc (`<<EOF`) when the message body contains backticks — the outer shell command-substitutes the backticks before the heredoc is written, executing arbitrary code from the message body. ALWAYS:

1. Build the JSON with `jq` using `--arg` to safely embed the message:
   ```bash
   jq -nc --arg m "$MSG" \
     '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}'
   ```
2. When constructing `$MSG` itself in shell (e.g. multi-line policy reminder text), prefer:
   - A **quoted** heredoc delimiter (`<<'EOF'`) so no expansion happens at all, OR
   - Inside an unquoted heredoc, write code samples with **single quotes**, never backticks (` ` ` ).

Backticks in any unquoted shell context (heredoc, double-quoted string, `$"..."`) are command-substitution operators. Hook message bodies routinely contain code samples, file paths, and quoted snippets — any of those touching backticks become a remote-code-execution vector if surfaced through an unquoted heredoc.

## Rationale

Hooks run with the user's full shell privileges and frequently embed user-visible code samples in `additionalContext`. An unquoted heredoc `cat <<EOF` evaluates `` `…` `` in the body before writing — so a message containing `` `rm -rf $HOME` `` literally runs `rm -rf $HOME` while building the JSON. `jq -nc --arg` treats the value as opaque bytes and produces valid JSON regardless of contents (backticks, quotes, newlines, `$`). This is the same class of bug as SQL-string-concatenation: never construct structured output by string interpolation of untrusted-content; use a serializer that escapes for you. Hard enforcement because the failure mode is silent code execution at hook-fire time.
