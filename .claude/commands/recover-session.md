---
description: Recover dead sessions that hit context limits without running /handoff
allowed-tools: Read, Write, Bash, Glob, Grep, AskUserQuestion
argument-hint: [--days N] [--session UUID] [--dry-run]
visibility: public
---

# /recover-session - Dead Session Recovery

Find and recover Claude Code sessions that died from context limits ("Prompt is too long") without running `/handoff`. Reconstructs thread JSON from JSONL session data so work is tracked in HQ.

**User's input:** $ARGUMENTS

## Arguments

- No args: scan last 7 days, interactive selection
- `--days N`: scan last N days (default 7)
- `--session UUID`: recover specific session by ID
- `--dry-run`: show what would be recovered, don't write anything

## Process

### 1. Scan for Dead Sessions

Parse arguments. Set `DAYS` from `--days` or default to 7.

**Death signals** (from real data — the session ends with these patterns):
- Assistant content `"Prompt is too long"` (the API rejects the request)
- `/compact` fails with `"Error during compaction: Error: Conversation too long"`
- No productive content follows the error (session is dead)

**Step 1a: Find candidates** — search for error strings in JSONL files. Exclude subagent files (in `subagents/` dirs):

```bash
SESSIONS_ROOT="$HOME/.claude/projects"
find "$SESSIONS_ROOT" -name "*.jsonl" -not -path "*/subagents/*" -mtime -${DAYS} -size +10k 2>/dev/null | while read f; do
  if grep -q "Prompt is too long\|Conversation too long\|Error during compaction" "$f" 2>/dev/null; then
    echo "$f"
  fi
done
```

If `--session UUID` was provided, only check files matching `*/${UUID}.jsonl`.

**Step 1b: Verify death** — a session is truly dead only if the error appears near the end. Sessions that compacted successfully and continued are NOT dead. Check the last 20 lines:

```bash
tail -20 "$JSONL_FILE" | grep -q "Prompt is too long\|Conversation too long\|Error during compaction"
```

Only keep sessions where the error is in the tail (nothing productive follows).

**Step 1c: Extract metadata** — the slug may not be in the first line (first line is often `queue-operation`). Scan up to 30 lines:

```bash
head -30 "$JSONL_FILE" | python3 -c "
import json, sys
for line in sys.stdin:
    try:
        d = json.loads(line)
        if d.get('slug'):
            print(json.dumps({
                'session_id': d.get('sessionId',''),
                'slug': d.get('slug',''),
                'cwd': d.get('cwd',''),
                'git_branch': d.get('gitBranch',''),
                'started': d.get('timestamp','')
            }))
            break
    except: continue
"
```

**Step 1d: Cross-reference** — check `workspace/threads/` for existing threads. Skip sessions that already have a `recovered` thread:

```bash
grep -rl "original_session_id.*SESSION_ID" workspace/threads/ 2>/dev/null
```

Build candidate list. If empty, report "No unrecovered dead sessions found" and stop.

### 2. Present Candidates

If `--session UUID` was provided, skip to step 3 with that session.

Otherwise display a table:

```
Dead Sessions Found (last {DAYS} days):

  # | Died       | Slug                     | Project | Size
  1 | 2026-02-12 | linked-watching-lovelace | HQ      | 3.4MB
  2 | 2026-02-11 | merry-nibbling-coral     | {company}  | 858KB
```

Use `AskUserQuestion` to let user pick which to recover (number, or "all").

### 3. Extract State from JSONL

**CRITICAL: Never read the full JSONL. Always stream via Python.**

For each selected session, run this extraction script via Bash. It streams line-by-line and outputs a compact ~3KB summary JSON:

```bash
python3 << 'PYEOF'
import json, sys

JSONL_PATH = "SESSION_PATH_HERE"

out = {
    "session_id": None, "slug": None, "cwd": None, "git_branch": None,
    "started_at": None, "died_at": None, "first_user_message": None,
    "files_edited": [], "files_written": [], "git_commands": [],
    "last_5_summaries": [], "death_count": 0, "total_lines": 0,
    "project_dir_encoded": None
}

files_edited = set()
files_written = set()
git_cmds = []
summaries = []
first_user = False

with open(JSONL_PATH) as f:
    for line in f:
        out["total_lines"] += 1
        try:
            d = json.loads(line)
        except:
            continue

        # Session metadata from first slug-bearing line
        if not out["slug"] and d.get("slug"):
            out["session_id"] = d.get("sessionId")
            out["slug"] = d["slug"]
            out["cwd"] = d.get("cwd")
            out["git_branch"] = d.get("gitBranch")
            out["started_at"] = d.get("timestamp")

        # Track last timestamp as death time
        if d.get("timestamp"):
            out["died_at"] = d["timestamp"]

        # First user message (truncated). Skip command XML wrappers and
        # compact summaries — find the first real user message
        if not first_user and d.get("type") == "user":
            if d.get("isCompactSummary"):
                continue
            msg = d.get("message", {})
            content = msg.get("content", "")
            text = ""
            if isinstance(content, str) and content:
                text = content
            elif isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "text":
                        text = c["text"]
                        break
            if text:
                # Extract command name if wrapped in XML
                import re
                cmd_match = re.search(r"<command-name>(/\S+)</command-name>", text)
                args_match = re.search(r"<command-args>(.*?)</command-args>", text, re.DOTALL)
                if cmd_match:
                    out["first_user_message"] = cmd_match.group(1)
                    if args_match:
                        out["first_user_message"] += " " + args_match.group(1).strip()[:400]
                else:
                    out["first_user_message"] = text[:500]
                first_user = True

        # Tool use: find file edits and git commands
        if d.get("type") == "assistant":
            msg = d.get("message", {})
            content = msg.get("content", [])
            if isinstance(content, list):
                for c in content:
                    if not isinstance(c, dict):
                        continue
                    if c.get("type") == "tool_use":
                        name = c.get("name", "")
                        inp = c.get("input", {})
                        if name == "Edit" and inp.get("file_path"):
                            files_edited.add(inp["file_path"])
                        elif name == "Write" and inp.get("file_path"):
                            files_written.add(inp["file_path"])
                        elif name == "Bash":
                            cmd = inp.get("command", "")
                            if "git commit" in cmd or "git push" in cmd:
                                git_cmds.append(cmd[:150])
                    elif c.get("type") == "text":
                        text = c["text"]
                        if text == "Prompt is too long":
                            out["death_count"] += 1
                        elif len(text) > 30:
                            summaries.append(text[:300])

        # Check for subagent (skip these)
        if d.get("subagentId"):
            print(json.dumps({"skip": True, "reason": "subagent"}))
            sys.exit(0)

out["files_edited"] = sorted(files_edited)
out["files_written"] = sorted(files_written)
out["git_commands"] = git_cmds[-10:]
out["last_5_summaries"] = summaries[-5:]

# Detect project from path
parts = JSONL_PATH.split("/")
for i, p in enumerate(parts):
    if p == "projects" and i + 1 < len(parts):
        out["project_dir_encoded"] = parts[i + 1]
        break

print(json.dumps(out, indent=2))
PYEOF
```

Read the output JSON. If `{"skip": true}`, skip this session (subagent).

### 4. Detect Company

Decode `project_dir_encoded` and inspect `cwd` + `files_edited`/`files_written`:

- `cwd` contains `repos/private/{company}` → {company}
- `cwd` contains `repos/private/{company}-` → {company}
- `cwd` contains `repos/private/{company}-` → {company}
- `files_touched` include `companies/{co}/` → that company
- Fallback: "personal"

Decode project dir for display:
- `-Users-{your-username}-Documents-HQ` → "HQ"
- `-Users-{your-username}-Documents-HQ-repos-private-{company}` → "{company}"
- etc. (replace leading path + `-` with readable name)

### 5. Generate Thread JSON

Using extracted data, generate a summary and next_steps from:
- `first_user_message` — what the session set out to do
- `last_5_summaries` — what it was doing when it died
- `files_edited` + `files_written` — scope of work

Build thread in HQ format:

```json
{
  "id": "T-{YYYYMMDD}-{HHMMSS}-recovered-{slug-fragment}",
  "created_at": "{died_at}",
  "summary": "{1-2 sentence AI-generated summary}",
  "status": "interrupted",
  "category": "recovered",
  "company": "{detected company}",
  "git": {
    "branch": "{git_branch}",
    "repos": {}
  },
  "files_touched": ["{relativized file paths}"],
  "next_actions": ["{inferred from death context}"],
  "recovery": {
    "original_session_id": "{session_id}",
    "original_slug": "{slug}",
    "death_timestamp": "{died_at}",
    "death_count": 0,
    "total_lines": 0,
    "project_dir": "{decoded project name}"
  }
}
```

Use the death timestamp (not current time) for the thread ID — represents when work happened.

Relativize file paths: strip `~/HQ/` prefix.

If `--dry-run`, display what would be written and stop here. Do NOT write any files.

Write to `workspace/threads/{thread_id}.json`.

### 6. Update Handoff Artifacts

**Update `workspace/threads/recent.md`:**
Regenerate table of last 15 threads (sorted by date descending):
```markdown
| Thread | Created | Summary | Status |
|--------|---------|---------|--------|
| T-...-recovered-... | 2026-02-12 | ... | interrupted |
```

**Update `workspace/threads/INDEX.md`:**
Add recovered thread to the full threads table.

**Write `workspace/threads/handoff.json`:**
```json
{
  "created_at": "{now ISO8601}",
  "message": "Recovered dead session: {slug}",
  "last_thread": "{thread_id}",
  "thread_path": "workspace/threads/{thread_id}.json",
  "context_notes": "{summary}. Died from context limits. {next_actions[0] if any}"
}
```

**Skip** (unsafe in recovery context):
- Auto-committing repos (can't know what was dirty at death vs now)
- Knowledge repo commits
- qmd reindex (user can `/search-reindex`)

### 7. Report

```
Session Recovery Complete
═════════════════════════

Thread:   {thread_id}
Died:     {death timestamp}
Session:  {slug} ({session_id})
Company:  {company}
Summary:  {conversation_summary}
Files:    {N} files touched
Commits:  {N} git commands found in session

Thread saved: workspace/threads/{thread_id}.json

Next:
  - Review: Read workspace/threads/{thread_id}.json
  - Continue: /nexttask (recovered thread will appear)
  - Reindex: /search-reindex (if needed)
```

If multiple sessions recovered, show summary table then per-session details.

## Rules

- NEVER cat/read entire JSONL files — always stream via python3 or use grep/tail
- Keep total context from extraction under 5KB per session
- Cross-reference existing threads BEFORE running extraction (cheap check first)
- Recovery threads use death timestamp, not current time, for thread_id
- Never auto-commit repos during recovery — user must verify what's dirty now vs then
- Skip subagent JSONL files (they have `subagentId` in their lines)
- Relativize all file paths to HQ root in thread JSON
- `--dry-run` must not write any files
