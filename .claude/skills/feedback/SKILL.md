---
name: feedback
description: Submit a bug report or feature request via `hq feedback`. Assembles a four-section body (user prose / session context / last failing tool / cwd hint), writes it to a mktemp path, then submits in a single Bash call with --body-file. Company slug resolved via hq-session.sh — no GHQ-OS coupling.
allowed-tools: AskUserQuestion, Write, Bash(mktemp:*), Bash(bash:*), Bash(rm:*), Bash(core/scripts/hq-session.sh:*), Bash(hq:*), Bash(pwd:*)
---

# HQ Feedback

Submit a bug report or feature request. Assembles a structured body and submits via the `hq feedback` CLI.

**Input:** `$ARGUMENTS` — expected format: `bug|feature [title text]`  
If the type is omitted, default to `bug`. If the title is absent, use **AskUserQuestion** to ask before proceeding.

## Process

### 1. Parse input

From `$ARGUMENTS`, extract:

- **User Message** (for Step 6 body template) — the full `$ARGUMENTS` text verbatim. This is the raw user input and is captured independently of TITLE. It becomes the `## User Message` section of the body in Step 6.
- `TYPE` — `bug` or `feature`. **If the first whitespace-delimited token of `$ARGUMENTS` is neither `bug` nor `feature`, treat the ENTIRE `$ARGUMENTS` string as TITLE and default TYPE to `bug` — do not consume the first token.** If `$ARGUMENTS` is empty, default TYPE to `bug`.
- `TITLE` — the one-line title passed via `--title`. Strip the leading TYPE token from `$ARGUMENTS` if present to get TITLE; if the entire string was treated as TITLE (no type token), TITLE equals that full string. If TITLE is missing or empty after parsing, use the **AskUserQuestion** tool: _"What is the title for this feedback?"_

### 2. Allocate body file

Run:

```bash
BODY_PATH=$(mktemp -t hq-feedback-body) || { echo "mktemp failed" >&2; exit 1; }
echo "$BODY_PATH"
```

Capture the absolute path printed to stdout. **You will substitute this literal path into Steps 6 and 8 directly — do not rely on it as a shell variable across separate Bash tool calls, as each call runs in a fresh subprocess.**

### 3. Capture CWD

Run:

```bash
pwd
```

Capture the absolute path printed to stdout. You will paste this literal value into the body in Step 6.

### 4. Summarize session context (prose — no Bash)

Review the conversation so far and write 2–4 bullets covering: key commands or tool calls run, files created or changed, any errors or unexpected outcomes. Keep to ≤ 150 words. This text becomes the **Session Context** section of the body.

### 5. Identify last failing tool call (prose — no Bash)

Scan the conversation for the most recent tool call that returned an error, exception, or non-zero exit. If one exists, copy it (truncated to ≤ 300 characters). If none exists, record the literal string `none`. This becomes the **Last Failing Tool Call** section.

### 6. Assemble four-section body

Compose the following markdown, substituting the literal values captured in Steps 1–5, then use the **Write** tool to write it to the body path from Step 2:

```markdown
## User Message
<User Message verbatim from Step 1 — the full $ARGUMENTS text>

## Session Context
<2–4 bullets from Step 4>

## Last Failing Tool Call
<tool call or "none" from Step 5>

## CWD Hint
<absolute path from Step 3>
```

### 7. Resolve company slug

```bash
core/scripts/hq-session.sh get company_slug
```

Capture the output. If empty or blank, omit `--company` from the submit call.

### 8. Submit (single Bash call — substitute literal values)

**Each Bash tool call runs in a fresh subprocess — shell variables set in earlier steps do not carry over.** Construct the submit command by replacing each placeholder with its captured literal value, then run the result in a single Bash call.

Template:

```
hq feedback "<type>" --title "<title>" --body-file "<body-path>" [--company "<slug>"]; rc=$?; rm -f "<body-path>"; exit $rc
```

Substitution map:
- `<type>` → TYPE from Step 1 (e.g., `bug`)
- `<title>` → TITLE from Step 1 (e.g., `Login broken on mobile`) — always pass via `--title`, never as a positional argument to `hq feedback`
- `<body-path>` → absolute path printed in Step 2 (e.g., `/tmp/hq-feedback-body.AbCdEf`)
- `[--company "<slug>"]` → `--company "indigo"` if Step 7 returned a non-empty slug; omit entirely if empty

Example fully-substituted command:

```bash
hq feedback "bug" --title "Login broken on mobile" --body-file "/tmp/hq-feedback-body.AbCdEf" --company "indigo"; rc=$?; rm -f "/tmp/hq-feedback-body.AbCdEf"; exit $rc
```

Running the chain directly (without a `bash -c '...'` wrapper) avoids single-quote hazards when TITLE contains apostrophes. The `hq` call is covered by `Bash(hq:*)`; the inline `rm -f` cleanup is covered by `Bash(rm:*)`. Cleanup runs whether `hq` succeeds or fails.

### 9. Report

Print the `Submitted: feedback_<uuid>` line returned by the CLI. If the command failed (`rc != 0`), surface the error output to the user.

## Rules

- **Literal substitution only in Step 8.** Never rely on shell variables from a prior Bash tool call — they do not survive across invocations. Paste the captured values directly into the command string.
- **Always pass `--title` explicitly.** Do not pass the title as a positional to the `bug`/`feature` subcommand — the subcommand's positional parser would either reject it or swallow it depending on Commander's mode. Always use `--title "<title>"`.
- **Title-only `$ARGUMENTS` → treat as TITLE.** If `$ARGUMENTS` does not begin with `bug` or `feature`, the whole string is the title; do not consume any token as TYPE.
- Run the submit chain directly (no `bash -c '...'` wrapper) — single-quoting user-supplied values like TITLE inside `bash -c '...'` breaks on apostrophes. The `hq` call is covered by `Bash(hq:*)`; `rm -f` by `Bash(rm:*)`. No exit-trap dependency.
- Use **AskUserQuestion** for any missing title — never inline questions in chat text.
- Company slug comes from `core/scripts/hq-session.sh get company_slug` only; omit `--company` when the result is empty.
- No GHQ-OS-aware identifiers in this skill. Slug resolution is the only session-context read.
