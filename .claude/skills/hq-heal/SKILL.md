---
name: hq-heal
description: Triage and repair HQ session errors such as hook crashes, sync conflicts, or MCP failures.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
---

# HQ Heal — Session Error Triage

When a Claude Code or Codex session in HQ surfaces an error, run this skill to classify the error, run targeted diagnostics, and either apply a safe fix automatically or surface a numbered fix proposal for confirmation. Writes a heal report under `workspace/reports/hq-heal/`.

**User input:** `$ARGUMENTS`

## Arguments

The first argument shapes how the error is collected. Everything after the flag (or the whole string if no flag is present) is treated as the error text.

- `(no args)` → use `AskUserQuestion` to ask the user to paste the error text.
- `<free text>` → treat the entire argument string as the error text.
- `--last-session` → scan the most recent JSONL under `~/.claude/projects/-Users-*-Documents-HQ/` for the trailing error (uses the streaming Python pattern from `.claude/skills/recover-session/SKILL.md` step 3 — never read the full file).
- `--class <name>` → skip classification and jump straight to the diagnostics recipe for that class. Valid: `autocompact`, `hook`, `sync`, `denylist`, `mcp`, `qmd`, `reindex`, `symlink`, `git-root`, `plan-mode`, `unknown`.
- `--dry-run` → diagnose and propose but do not apply any fix.
- `--no-bug` → suppress the automatic `/hq-bug` filing step. By default, every heal run files a bug so HQ engineering accumulates signal on which error classes are recurring (see Step 6).
- `--allow-core` → permit the apply step to edit files under `core/` (the hook-protected mirror) by prefixing the offending Write/Edit/Bash call with `HQ_BYPASS_CORE_PROTECT=1`. Off by default — heal will refuse a core edit and require this flag to be passed, even when the user confirms the numbered fix. Always documented in the heal report and the filed bug (see Step 5 + Step 6).

## Process

### 1. Capture the error text

If `$ARGUMENTS` is empty, ask: *"Paste the error message you're seeing (or describe what went wrong)."* Wait for response, treat that as the error text.

If `--last-session`, run a Python streaming extract that scans the last 200 lines of the most recently modified JSONL for any of these signals: `Prompt is too long`, `Conversation too long`, `Error during compaction`, `Autocompact is thrashing`, `permission denied`, `EACCES`, `hook .* failed`, `block-hq-root-git-mutation`, `MCP server .* failed`, `qmd: error`, `reindex.sh.*abort` (legacy `master-sync.sh.*abort`). Capture the matched line plus 2 lines of surrounding context. Truncate to 2 KB.

Store the resulting text in a local variable called `ERR`.

### 2. Classify the error

Unless `--class` is set, walk the pattern table top-to-bottom; first match wins. The classifier is pure pattern matching on `ERR` — do not load any other HQ context yet.

| Class | Triggers (case-insensitive substring or regex on `ERR`) |
|---|---|
| `autocompact` | `Autocompact is thrashing`, `Prompt is too long`, `Conversation too long`, `Error during compaction`, `context refilled to the limit` |
| `hook` | `hook .* failed`, `PreToolUse .* blocked`, `PostToolUse hook`, `hook-gate.sh`, `non-zero exit from hook` |
| `sync` | `hq sync .* conflict`, `conflictPath`, `resolve-conflicts`, `hq-sync.*error`, `originalPath.*conflict` |
| `denylist` | `Read access blocked`, `denied by settings`, `~/.ssh`, `~/.aws/credentials`, `~/.zshrc`, `permission rule .* deny` |
| `mcp` | `MCP server .* (failed|disconnected|timeout)`, `Error connecting to MCP`, `tool .* not found` (when the tool name matches a known MCP) |
| `qmd` | `qmd: error`, `qmd .* index`, `collection .* not found`, `qmd update` failures |
| `reindex` | `reindex.sh`, `master-sync.sh`, `duplicate worker id`, `personal/<type>/<entry>.*already exists` |
| `symlink` | `Too many levels of symbolic links`, `ELOOP`, `dangling symlink`, `readlink: .* No such file` |
| `git-root` | `block-hq-root-git-mutation`, `git .* blocked from HQ root`, `HQ_ALLOW_HQ_ROOT_GIT` |
| `plan-mode` | `plan mode`, `ExitPlanMode required`, `cannot Edit in plan mode` |
| `unknown` | (no match) |

Bind `CLASS` to the matched class name.

### 3. Run the diagnostics recipe for `CLASS`

Each recipe is intentionally narrow: a small, parallel set of reads and shell probes that gather just enough state to propose a fix. Never load company knowledge, INDEX.md, or `companies/manifest.yaml` here — heal stays HQ-internal.

#### `autocompact`
Parallel checks:
- `wc -l ~/.claude/projects/-Users-*-Documents-HQ/*.jsonl 2>/dev/null | tail -5` — recent session sizes
- `du -sh ~/.claude/projects/-Users-*-Documents-HQ/ 2>/dev/null` — total session bloat
- `ls -lhS workspace/threads/*.json 2>/dev/null | head -3` — large thread files
- If `--last-session` was used, identify the single largest tool result in the matched JSONL (Python streaming, return tool name + size only)

Fix proposals (ranked):
1. `/clear` and resume work — fastest if the session has accumulated stale tool results
2. `/recover-session --session <uuid>` — reconstruct a thread from the dead JSONL, then start fresh
3. Identify the offending tool call and recommend a smaller-scope alternative (e.g. `qmd search -c hq-infra <term>` instead of reading a multi-MB INDEX, or `Read` with `offset:`/`limit:` instead of full-file reads)
4. If a file repeatedly bloats context, propose moving it out of auto-load paths (e.g. very large `INDEX.md`, `quick-reference.md`)

#### `hook`
Parallel checks:
- `cat .claude/settings.json | grep -E '"(PreToolUse|PostToolUse|SessionStart|Stop|PreCompact)"' | head` — confirm hook chain is intact
- `echo "HQ_HOOK_PROFILE=$HQ_HOOK_PROFILE  HQ_DISABLED_HOOKS=$HQ_DISABLED_HOOKS"`
- Grep `ERR` for the hook script name; if found, `ls -la .claude/hooks/<name>.sh` and read its first 40 lines

Fix proposals:
1. Temporarily disable the failing hook: `export HQ_DISABLED_HOOKS=<name>` for the next session — emit the export line, do not run it
2. Switch profile: `export HQ_HOOK_PROFILE=minimal` — useful for hook-storm scenarios
3. Patch the hook script if the bug is local and obvious (e.g. missing `2>/dev/null`, unquoted path, missing `mkdir -p`) — apply via Edit only if the fix is one or two lines, otherwise propose
4. If the failing hook is `reindex.sh` (or legacy `master-sync.sh`), escalate to the `reindex` recipe instead

#### `sync`
Checks:
- `[ -f workspace/sync/conflicts.json ] && wc -l workspace/sync/conflicts.json`
- `ls workspace/sync/conflicts/ 2>/dev/null | head`

Fix proposal: invoke `/resolve-conflicts`. Surface the count of pending conflicts so the user sees scope. Apply the *learned rule* from charter: keep local when `originalPath` is a symlink or an auto-generated artifact (registries, INDEX).

#### `denylist`
Checks:
- Extract the blocked path from `ERR`
- `grep -nE '"deny"|"Read"' .claude/settings.json | head -20`

Fix proposal: explain the rule (`Sensitive Path Deny Lists` from charter), and offer a safe alternative — e.g. ask the user to paste the value, use `hq-secrets`, or for rc-file edits use append-only `printf >>` / pattern-delete `sed '/pat/d'`. Never propose removing the deny rule.

#### `mcp`
Checks:
- `[ -f .mcp.json ] && jq -r '.mcpServers | keys[]' .mcp.json 2>/dev/null`
- `ps aux | grep -iE 'mcp|claude' | grep -v grep | head -5`
- Pull the MCP name from `ERR` if present

Fix proposals:
1. Restart the MCP server (instructions depend on the server — `superhuman-mail`, `vyg-db-mcp`, `Claude_Preview`, etc.)
2. Re-auth if the failure is `401 / unauthorized`
3. If the server isn't listed in `.mcp.json`, surface that it isn't configured for this project

#### `qmd`
Checks:
- `which qmd && qmd --version 2>/dev/null`
- `qmd collections 2>/dev/null | head -20`
- `[ -d .qmd ] && du -sh .qmd 2>/dev/null`

Fix proposal: `qmd update 2>/dev/null || true`. If a specific collection is missing, surface its expected path and offer to re-add it.

#### `reindex`
Apply the learned rule from charter: trace `core/<type>` symlinks back to `personal/<type>/` and look for `find -L` recursion into `_overrides/` or other stale mirrored snapshots.

Checks:
- `find -L core/workers core/policies -maxdepth 3 -type d -name '_overrides' 2>/dev/null | head`
- `ls -la personal/workers/ personal/policies/ 2>/dev/null | head -20`
- `tail -30 workspace/logs/reindex.log 2>/dev/null` (if present)

Fix proposal: remove stale `_overrides/` snapshots (with `--dry-run` first), or patch `core/scripts/generate-workers-registry.sh` to skip `*/_overrides/*` if not already patched. Surface the exact rm command for user confirmation — do not auto-remove.

#### `symlink`
Checks:
- Grep `ERR` for the broken path; if found, `ls -la <path>` and `readlink <path>`
- Common HQ symlinks to verify: `AGENTS.md`, `companies/*/knowledge`, `core/knowledge/public/*`, `.claude/skills/personal:*`

Fix proposal: re-create the symlink with an absolute path under `$HOME/Documents/HQ/` (learned rule: never relative symlinks across worktrees). Apply via Edit/Bash only if the target is unambiguous.

#### `git-root`
Read first 30 lines of `.claude/hooks/block-hq-root-git-mutation.sh` to surface the rule. Show the user the correct invocation form: `git -C /abs/path <cmd>` or `( cd /abs/path && git <cmd> )` or `gh ... -R owner/repo`. For sanctioned HQ-internal git work, surface `HQ_ALLOW_HQ_ROOT_GIT=1 git ...`. No file mutations.

#### `plan-mode`
Surface: in plan mode, the model can Read/Glob/Grep but cannot Edit/Write. To exit, call `ExitPlanMode` (deferred tool — load via ToolSearch). No file mutations needed; this is purely an explainer.

#### `unknown`
Run a minimal triage:
- `bash core/scripts/hq-session.sh 2>/dev/null` (if present) to dump session context
- `git -C . status --short | head -10`
- `hq whoami 2>/dev/null` to confirm identity

Then ask the user three numbered follow-up questions via `AskUserQuestion`:
1. When did the error first appear (this turn / earlier in session / right at session start)?
2. Has anything in HQ changed recently (`/update-hq`, new hook, new policy)?
3. Does the error reproduce in a fresh session (run `bash .claude/skills/hq-heal/hq-heal.sh --bare "<error>"` to test)?

### 4. Propose the fix

Format the proposal as a numbered list (1-4 options max), one option per line, with the safest option first. Always include an explicit "Do nothing — just save report" choice.

If `--dry-run` was passed, skip the apply step entirely; report the proposed fix and stop.

Otherwise, use `AskUserQuestion` to surface the numbered options. Wait for the answer. Apply the chosen fix only.

**Safety rules for the apply step:**
- Never auto-edit policies, hooks, or `core.yaml` without explicit user confirmation
- Never delete files — surface the rm command and let the user run it
- Never run `git push`, `git reset --hard`, or any rc-file rewrite
- Never read sensitive deny-listed paths even to diagnose
- For multi-step fixes, apply one step, re-run a minimal diagnostic, then proceed

**Core-divergence handling (`core/` mirror):**
- HQ's `core/` tree is mechanically write-blocked by `.claude/hooks/block-core-writes.sh` because it is a downstream mirror of `hq-core`. Heal usually routes fixes through `personal/<type>/<name>/` (reindex mirrors into `core/`) or co-locates with a skill (`.claude/skills/<name>/`) — never into `core/` directly.
- Genuine exception: the failing artifact *is* a core file (a broken `core/scripts/*.sh` hook helper, a stale `core/policies/<name>.md`, etc.) and the fix cannot land anywhere else. In that case:
  1. The numbered proposal must call out that the fix diverges from upstream — exact files listed
  2. The user must have passed `--allow-core` (the flag is the explicit acknowledgment that this divergence is intentional)
  3. Each individual Write/Edit/Bash call that touches a `core/` path must be prefixed with `HQ_BYPASS_CORE_PROTECT=1`
  4. The heal report (Step 5) gets a `## Core divergence` section listing every `core/` path touched, the old content (first 30 lines), and the new content (first 30 lines)
  5. The auto-filed bug (Step 6) is escalated from `bug` to `feature` if the divergence implies a policy / hook change upstream wants — the body explicitly names which upstream file needs the corresponding patch in `hq-core`
- If `--allow-core` is missing and the only viable fix is a `core/` edit, do not apply anything — surface the proposed diff in the report (as a *would-have-applied* block) and stop with a one-liner telling the user to re-invoke `/hq-heal --allow-core <same args>`.

### 5. Write the heal report

Path: `workspace/reports/hq-heal/{YYYYMMDD-HHMMSS}-{class}.md`.

Template:

```markdown
# HQ Heal Report — {class}

Timestamp: {iso8601}
Session: {session_id_or_unknown}
Triggered by: /hq-heal {$ARGUMENTS first 80 chars}

## Error captured

```
{ERR, max 2 KB}
```

## Classification

{class} — matched on `{trigger_phrase}`

## Diagnostics

{output of the recipe checks, max 3 KB}

## Fix proposed

{numbered options shown to user}

## Fix applied

{user's chosen option, or "dry-run — none applied" if --dry-run}

## Outcome

{1-3 sentences: did the proposed fix resolve, was a follow-up needed, what to watch next session}

## Core divergence

{omit this section unless --allow-core was passed AND a core/ path was touched. List every core/ file touched, the old content (first 30 lines), the new content (first 30 lines), and a 1-line justification for why the fix could not land in personal/ or a co-located skill folder.}
```

Append a one-line entry to `workspace/reports/hq-heal/INDEX.md` (create if missing) with the timestamp, class, and outcome status.

### 6. File an HQ bug (default on)

Unless `--no-bug` was passed, file a bug report via the `/hq-bug` skill so HQ engineering accumulates signal on which error classes are recurring and which heal flows actually fixed them. This step runs **after** the heal report has been written so the report path can be referenced from the bug body.

Build the bug as follows:

- **Type**: `bug` by default. Escalate to `feature` if the fix touched `core/` (i.e. the `## Core divergence` section is non-empty) — the engineering follow-up needed is an upstream patch, which is a feature ask, not a bug report
- **Title**: `hq-heal: {class} — {one-line summary of the fix applied}` (truncate the summary to keep the whole title under 80 chars)
- **Body sections** (the `/hq-bug` skill assembles its own four-section template; heal augments by setting `$ARGUMENTS` to a single line so the skill captures the right title, and by ensuring the rendered body references the heal report path verbatim):
  - The heal report path: `workspace/reports/hq-heal/{filename}.md` — engineering reads this for the raw error, classification, diagnostics, and applied fix
  - The error class
  - The fix that was applied (or `dry-run — none applied`)
  - If `## Core divergence` was set, the list of `core/` files touched + the upstream `hq-core` path they map to (e.g. `core/scripts/foo.sh` → `https://github.com/indigoai-us/hq-core/blob/main/core/scripts/foo.sh`)

Invocation: call the `/hq-bug` skill via the `Skill` tool with the bug type and title as args. Do not shell out to `hq feedback` directly — `/hq-bug` already wraps the CLI with the right body-file allocation, CWD capture, and session-context assembly.

If the `/hq-bug` skill is missing on this HQ (e.g. running an older release), fall back to a single-line stderr notice in the heal report's `## Outcome` section: *"hq-bug filing skipped — `/hq-bug` skill not installed."* Do not block the heal flow on bug-filing failure — heal report is the durable artifact, bug filing is secondary signal.

If `--dry-run` was passed at invocation, also skip the bug-filing step — dry-run is observation only.

### 7. Surface the next step

Print a short, four-line summary to the user:

```
Heal complete — class: {class}
Applied: {what was done, or "nothing — dry-run"}
Report:  workspace/reports/hq-heal/{filename}.md
Bug:     {hq-bug URL or 'skipped (--no-bug)' or 'skipped (dry-run)' or 'skipped (/hq-bug missing)'}
```

If `--allow-core` was used and the `## Core divergence` section was written, append one extra line: *"Core divergence noted — `{N}` `core/` files touched. Upstream patch needed in hq-core."*

If the proposed fix requires re-launching the session (e.g. autocompact, reindex), append: *"Re-launch suggestion: `bash .claude/skills/hq-heal/hq-heal.sh --resume`"* and stop.

## Rules

- Heal stays HQ-internal — never load `companies/*/knowledge/`, `companies/manifest.yaml` body, INDEX.md, or `handoff.json`
- Never read sensitive deny-listed paths under any circumstance, even when classifying a `denylist` error
- Recipe context budget is 5 KB per class — if a probe would return more, summarize
- The classifier is pure pattern matching — do not run subagents or do any HQ-wide search before classification
- Never auto-apply fixes for `denylist`, `git-root`, or `reindex` classes — always require user confirmation, the consequences are too broad
- The heal report is the single durable artifact — it is what `/handoff` and future `/hq-heal` invocations consult to detect repeat failures
- The `/hq-bug` filing in Step 6 is the *signal* artifact — durable artifact stays local, signal goes to HQ engineering so recurring error classes get systemized fixes upstream. `--no-bug` suppresses the filing only; the report still writes
- Core-mirror writes are off by default. The `--allow-core` flag is required even when the user explicitly confirms a fix that touches `core/`. This is intentional friction — the bypass should be auditable per-invocation, not implicit
- This skill must remain runnable in `--bare` mode (no hooks, no MCPs) so it stays usable when hooks or MCPs are the failure mode being diagnosed
- Companion to `/recover-session` (post-mortem on a dead JSONL) — `/hq-heal` is mid-session triage and may invoke `/recover-session` as its fix for the `autocompact` class
- Promotion: this skill lives at `.claude/skills/hq-heal/` locally; to ship it to other HQs, stage it in the hq-core staging repo and publish via `/promote-hq-core` per the `staging-promotion-required` policy
- The launcher `hq-heal.sh` is co-located with the skill (`.claude/skills/hq-heal/hq-heal.sh`) rather than placed under `core/scripts/`, because `core/` is hook-protected (`block-core-writes`) — promotion happens via the staging hop, not direct writes

## Why this exists

HQ users hit a recurring class of errors that look scary but are well-understood once classified — autocompact thrashing, hook crashes, sync conflicts, deny-list blocks, reindex aborts. Without a healer, the recovery path is for the user to switch terminals, paste the error into a fresh Claude session, and hope the new session figures out what to do. `/hq-heal` collapses that into one slash command with a known-good triage recipe per error class, and a companion launcher (`core/scripts/hq-heal.sh`) for the case where the current session is too wedged to invoke the slash command at all.

## See also

- `/resolve-conflicts` — pick local/cloud on a conflict
- `/recover-session` — restore a lost session
