---
name: hq-bug
description: Submit HQ bug reports or feature requests with session context.
allowed-tools: AskUserQuestion, Write, Bash(mktemp:*), Bash(cygpath:*), Bash(bash:*), Bash(core/scripts/hq-session.sh:*), Bash(hq:*), Bash(pwd:*), Bash(ls:*)
---

# HQ Feedback

Submit a bug report or feature request. Assemble a structured body and submit via the `hq feedback` CLI. Slack shows the title as a short channel summary, with the full report and diagnostics in its thread.

**Input:** `$ARGUMENTS` — expected format: `bug|feature [title text]`  
If the type is omitted, default to `bug`. If the title is absent, use **AskUserQuestion** to ask before proceeding.

## Process

### 1. Parse input

From `$ARGUMENTS`, extract:

- **User Message** (for Step 6 body template) — the full `$ARGUMENTS` text verbatim. This is the raw user input and is captured independently of TITLE. It becomes the `## User Message` section of the body in Step 6.
- `TYPE` — `bug` or `feature`. **If the first whitespace-delimited token of `$ARGUMENTS` is neither `bug` nor `feature`, use the ENTIRE `$ARGUMENTS` string as the report description and default TYPE to `bug` — do not consume the first token.** If `$ARGUMENTS` is empty, default TYPE to `bug`.
- `TITLE` — a concise one-line summary passed via `--title`, ideally under 120 characters. Describe the observed failure or requested behavior using the full report description (after removing an explicit TYPE token). Preserve a short, clear supplied title; summarize long input without inventing a cause or losing the affected surface. The full input stays verbatim in User Message. If the report description is missing or empty, use the **AskUserQuestion** tool: _"What is the title for this feedback?"_

### 2. Allocate body file

Run this as a **single** Bash call (do not split mktemp and cygpath across tool calls):

```bash
BODY_PATH=$(mktemp -t hq-feedback-body.XXXXXX) || { echo "mktemp failed" >&2; exit 1; }
if command -v cygpath >/dev/null 2>&1; then
  BODY_PATH=$(cygpath -m "$BODY_PATH") || { echo "cygpath failed" >&2; exit 1; }
fi
printf '%s\n' "$BODY_PATH"
```

Capture the absolute path printed to stdout. On Windows Git Bash, `cygpath -m` makes the path readable by the native `hq` binary. Use this path in Steps 6 and 8. Leave the small body file in the OS temp directory after submission; do not run a cleanup command.

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

### 5b. Gather screenshots (prose, plus one `ls` to check the paths)

A picture of the broken surface is often worth more than the prose describing
it. Before assembling the body, decide whether this report should carry one.

This step is otherwise prose-only, but it explicitly permits one `ls` call to
check the paths it collected — see the verification rule below. Do not skip that
call; an unchecked path is the failure this step exists to prevent.

**Attach a screenshot when the report concerns anything visual** — a UI defect,
a layout or rendering problem, a confusing screen, an unexpected dialog, a chart
or document that came out wrong. Also attach one whenever the user has already
shown you an image of the problem.

Collect image paths from whichever of these apply:

- **The user pasted or attached an image in this conversation.** You cannot read
  a pasted image off the conversation as a file. Ask for the path with
  **AskUserQuestion**: _"What's the file path of that screenshot, so I can
  attach it to the report?"_ If they do not have one saved, proceed without it —
  never block the report on an image.
- **You captured a screenshot during this session** — a browser automation
  capture, a desktop preview harness, a rendered-report screenshot. Use that
  file directly; it is already on disk.
- **The user named a file path** for a screenshot or image. Use it as given.

Rules for the collected list:

- At most **5** images. If more are available, keep the ones that best show the
  defect.
- Each must be **under 10 MB** and end in `.png`, `.jpg`, `.jpeg`, `.webp`, or
  `.gif`. Skip anything else rather than failing the submit.
- **Check every path in one `ls -la` call before using it**, e.g.
  `ls -la "/tmp/a.png" "/tmp/b.png"`. That single call answers both questions:
  a path missing from the output does not exist, and the size column tells you
  whether it clears 10 MB. Drop anything that fails either check — a bad path
  makes the whole submit fail, which loses the report.
  (`Bash(ls:*)` is allow-listed for exactly this check, and this step permits
  it despite being otherwise prose-only.)
- If there are no images, that is a fine outcome. Record the list as empty and
  continue. **Never invent a path, and never delay a report to go hunting for a
  screenshot.**

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

**Primary path:** use the Write-created file from Step 6. Construct and run this command directly:

```bash
hq feedback "<type>" --title "<title>" --body-file "<body-path>" [--company "<slug>"] [--screenshot "<path>" ...]
```

Substitution map:
- `<type>` → TYPE from Step 1 (e.g., `bug`)
- `<title>` → TITLE from Step 1 (e.g., `Login broken on mobile`) — always pass via `--title`, never as a positional argument to `hq feedback`
- `<body-path>` → absolute path printed in Step 2 (native-visible; `cygpath -m` converts Git Bash paths on Windows)
- `[--company "<slug>"]` → `--company "indigo"` if Step 7 returned a non-empty slug; omit entirely if empty
- `[--screenshot "<path>" ...]` → one `--screenshot "<abs-path>"` per image from Step 5b, repeated (the flag is repeatable, max 5). Omit entirely when Step 5b collected none.

Example fully-substituted command:

```bash
hq feedback "bug" --title "Login broken on mobile" --body-file "/tmp/hq-feedback-body.AbCdEf" --company "indigo"
```

Do not append cleanup commands. The file stays in the OS temp directory.

**Fallback only when the host has no Write tool:** `hq feedback --body-file -` reads stdin. Before constructing the command, choose `HQ_FEEDBACK_BODY_` followed by at least 12 random alphanumeric characters for this submission. Confirm that no line in the complete body exactly equals the chosen delimiter. Replace `<unique-delimiter>` with that same chosen value in both locations below; never reuse a fixed delimiter:

```bash
hq feedback "<type>" --title "<title>" --body-file - [--company "<slug>"] [--screenshot "<path>" ...] <<'<unique-delimiter>'
<four-section body from Step 6>
<unique-delimiter>
```

Run the command directly (without a `bash -c '...'` wrapper). The primary command has no cleanup step; its exit status is the `hq feedback` result.

### 9. Report

Print the `Submitted: feedback_<uuid>` line returned by the CLI. If the command failed (`rc != 0`), surface the error output to the user.

## Rules

- **Literal substitution only in Step 8.** Never rely on shell variables from a prior Bash tool call — they do not survive across invocations. Paste the captured values directly into the command string.
- **Always pass `--title` explicitly.** Do not pass the title as a positional to the `bug`/`feature` subcommand — the subcommand's positional parser would either reject it or swallow it depending on Commander's mode. Always use `--title "<title>"`.
- **Input without a type → use the whole description.** If `$ARGUMENTS` does not begin with `bug` or `feature`, do not consume any token as TYPE. Derive a concise TITLE and preserve the whole input in User Message.
- Run the primary submit command directly (no `bash -c '...'` wrapper). Leave its body file in the OS temp directory; do not chain cleanup. If a host lacks Write, use the random-delimiter stdin fallback from Step 8 and verify that no body line equals the delimiter before running it.
- Use **AskUserQuestion** for any missing title — never inline questions in chat text.
- For stdin fallback only, choose `HQ_FEEDBACK_BODY_` plus at least 12 random alphanumeric characters per submission. Confirm no line of the body exactly equals that delimiter, and use that same unique delimiter to open and close the quoted here-document. Never use a fixed here-document delimiter.
- **Attach screenshots for visual defects.** A UI, layout, or rendering report
  without an image makes the reader reconstruct from prose what one picture
  would have settled. Run Step 5b on every report; it is prose-only and costs
  nothing when there are no images.
- **An image is never worth losing a report over.** Skip an unreadable, oversize,
  or wrong-extension path and submit without it. Verify each path exists first —
  `hq feedback` fails the whole submit on one bad `--screenshot`.
- Company slug comes from `core/scripts/hq-session.sh get company_slug` only; omit `--company` when the result is empty.
- No GHQ-OS-aware identifiers in this skill. Slug resolution is the only session-context read.
