---
name: schedule
description: "Schedule recurring Claude/Codex agent jobs on the user's Outpost — structured checklist requirements, dm alert profile, status-aware list from hq-pro. Alias: /job (deprecated)."
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, Bash(bash core/scripts/jobs-schedule-parse.sh:*), Bash(bash core/scripts/jobs-validate.sh:*), Bash(hq:*), AskUserQuestion
---

# /schedule — Outpost recurring agent jobs

Define a job here; hq-sync carries the registry to the user's Outpost; systemd
timers (reconciler) and headless Claude/Codex run there. **Never** install
cron/launchd/systemd on the calling laptop.

**Alias:** `/job` → load this skill (deprecated name). Tell the user once to
prefer `/schedule`.

Schema: `core/knowledge/public/hq-core/outpost-jobs-spec.md`  
Validate before every write: `bash core/scripts/jobs-validate.sh <file>`  
NL → cron: `bash core/scripts/jobs-schedule-parse.sh [--tz IANA] "<text>"`

## Commands

| Invoke | Action |
|--------|--------|
| `/schedule add "…"` | Checklist + NL schedule → validated YAML |
| `/schedule list` | Registry YAML ∪ hq-pro status |
| `/schedule rm <id>` | Delete job file + sync push |
| `/schedule enable\|disable <id>` | Flip `enabled` + validate + sync |
| `/schedule run-now <id>` | Remote one-shot on Outpost (when runner exists) |
| `/schedule probe [id]` | Trigger / show Outpost requirements probe status |

Args arrive in `$ARGUMENTS`.

## Hard rules (non-negotiable)

1. **No local readiness gate.** Never treat laptop `claude`/`codex` login or
   local `hq secrets list` visibility as proof the job can run. Readiness comes
   only from the **hq-pro jobs status API** (or `pending_probe` until a row
   exists). Local secret listing is for **picking names** into the checklist.
2. **No local timers.** Do not write crontab, launchd plists, or systemd units
   on the calling machine.
3. **Validate before write.** Always run `jobs-validate.sh` on the target file;
   abort the write if it fails.
4. **No Outpost → no file.** If `hq outposts list` shows no box (or fails
   auth), explain in plain language and offer provisioning
   (`hq outposts provision --yes` / console). **Do not write** a job YAML.
5. **Structured checklist is primary.** Requirements come from AskUserQuestion
   (or equivalent one-question prompts), not free-form LLM inference. An
   optional "suggest from prompt" assist may pre-fill options but **never**
   writes without checklist confirmation.
6. **Cron only in YAML.** NL schedules are resolved at add time and never
   stored raw (`jobs-schedule-parse.sh`).
7. **After every mutation** (add/rm/enable/disable): push so the box sees it:
   ```bash
   hq sync push --personal --hq-root <hqRoot> --on-conflict overwrite -- \
     personal/jobs personal/settings/schedule-alerts.yaml
   ```
   For company-scoped jobs also push `companies/<co>/jobs` (or
   `hq sync push --company <co> -- …`).

## Resolve HQ root + scripts

1. Prefer cwd / `$CLAUDE_PROJECT_DIR` when it contains `core/scripts/jobs-validate.sh`.
2. Else resolve HQ root (`~/.hq/menubar.json` → `hqPath`, else walk for
   `core/core.yaml`).
3. Scripts must exist:
   - `core/scripts/jobs-validate.sh`
   - `core/scripts/jobs-schedule-parse.sh`
   If missing, say the feature branch is not installed in this tree and stop.

## Status API (US-009)

| | |
|--|--|
| **List** | `GET {base}/outpost/jobs/status` |
| **One job** | `GET {base}/outpost/jobs/status/{jobId}` |
| **Base URL** | `$HQ_VAULT_API_URL` or `https://hqapi.hq.computer` (same plane as `hq outposts`) |
| **Auth** | `Authorization: Bearer <Cognito accessToken>` from `~/.hq/cognito-tokens.json` (refresh via `hq auth refresh` / deploy `identity-resolve.sh` if expired) |
| **Cache** | ≤ **30s**; prefer a fresh GET after add/rm/enable/disable/probe |
| **Public fields** | `job_id`, `readiness` (`pending_probe`\|`ready`\|`blocked`\|`unknown`), `last_probe_at`, `last_run_at`, `last_exit`, `failure_class`, `next_actions[]`, `updated_at`, `cache_guidance_seconds` |

On **any** status API failure (network, 404 not-deployed, 5xx, auth): still list
every registry YAML job and mark status **`stale/unknown`** — never silently
omit jobs. New jobs with no status row show readiness **`pending_probe`**.

```bash
BASE="${HQ_VAULT_API_URL:-https://hqapi.hq.computer}"
TOKEN="$(jq -r '.accessToken // empty' ~/.hq/cognito-tokens.json)"
curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/outpost/jobs/status"
# → {"statuses":[{job_id,readiness,...}, ...]}  or error → treat as stale
```

Ingest (`POST /outpost/internal/jobs-status`) is **Outpost-only** (instance
token) — the laptop skill never calls it.

## Alert profile (first mutating command)

Path: `personal/settings/schedule-alerts.yaml`

On the **first** `/schedule` mutation in this tree (add / enable / disable / rm
when profile missing):

1. Ask once (AskUserQuestion): remediation channel — default **dm**. Options:
   `dm` | `slack` | `email` | `outpost-session`.
2. Write:

```yaml
channel: dm
destination: {}
updated_at: "2026-08-23T18:00:00Z"   # now UTC ISO-8601
```

3. If the user picks `slack` / `email` / `outpost-session`: **still save** that
   channel + any destination fields they provide, but **warn** that v1 delivery
   only implements **dm** and runtime falls back to dm (`channel_unimplemented`).
4. Later mutations skip the prompt if the file exists.

## `/schedule add`

### 0. Preconditions

- Auth: `hq whoami` works (else `/hq-login`).
- Outpost: `hq outposts list` has ≥1 row. Else CTA + stop (no file).
- Owner email: from `hq whoami`.

### 1. Parse schedule from `$ARGUMENTS`

Strip a leading `add` token. Remainder is NL or cron (and optional job blurb).

Split loosely: schedule phrase vs job description when both appear
(e.g. `every weekday at 9am, triage new Sentry issues`).

```bash
bash core/scripts/jobs-schedule-parse.sh --tz "$TZ_IANA" "$SCHEDULE_TEXT"
# → {"ok":true,"cron":"...","timezone":"...","human":"...","source":"nl"|"cron"}
```

Resolve `$TZ_IANA` as the user's local zone when not overridden (the parse
script detects host IANA by default). **Confirm** `human` with the user before
write ("I'll schedule this for: … — look right?").

### 2. Requirements checklist (AskUserQuestion — required)

Walk **one question at a time**:

1. **Runtime** — `claude` | `codex` (required).
2. **Secrets** — multi-select from `hq secrets list` / `hq secrets --personal list`
   (and company list when scoped). Store **names only**. Empty list allowed.
3. **Company** — optional slug (`companies/{co}` must exist for company jobs).
4. **cwd** — optional HQ-root-relative path.
5. **tools[]** — optional hints (e.g. `hq-secrets`, `hq-dm`).
6. **Scope** — `personal` (default) → `personal/jobs/{id}.yaml` vs
   `companies/{co}/jobs/{id}.yaml`.
7. **notify** — `profile` (default, uses schedule-alerts) | `dm` | `none`.
8. **timeout_seconds** — default `600` (US-001); clamp 60..14400.
9. **name** / **id** — human label; id = kebab-case slug unique across
   `personal/jobs` + `companies/*/jobs`.

Optional assist: suggest secrets/cwd/runtime from the prompt text, then present
them as checklist defaults — user must confirm.

**Do not** run local CLI auth checks as a gate. You may mention that the
Outpost will probe later.

### 3. Alert profile

If `personal/settings/schedule-alerts.yaml` missing → prompt + write (see above).

### 4. Write YAML

Do **not** include a readiness field. Example shape:

```yaml
id: daily-sentry-triage
name: Daily Sentry triage
schedule: "0 9 * * 1-5"
timezone: America/Los_Angeles
runtime: claude
exec:
  prompt: "Triage new Sentry issues and DM a summary."
cwd: companies/indigo/projects/foo   # omit if unset
timeout_seconds: 600
notify: profile
enabled: true
owner: user@example.com
created_at: "2026-08-24T00:00:00Z"
requirements:
  runtime: claude
  secrets:
    - SENTRY_API_TOKEN
  company: indigo          # omit if unset
  cwd: companies/indigo/projects/foo
  tools:
    - hq-secrets
```

`exec` is either `prompt:` or `skill:` (+ optional `args`), never both.

### 5. Validate → sync

```bash
bash core/scripts/jobs-validate.sh personal/jobs/{id}.yaml   # or company path
# on success:
hq sync push --personal --on-conflict overwrite -- personal/jobs personal/settings/schedule-alerts.yaml
```

### 6. Report

- Echo confirmed local schedule (`human`).
- Say list readiness will show **`pending_probe`** until the Outpost probe
  ingests status (US-008) — not a local green check.
- Remind: box picks up registry via sync + reconciler; timers arm only when
  status.readiness=`ready`.

## `/schedule list`

1. Collect jobs: `personal/jobs/*.yaml` and `companies/*/jobs/*.yaml` (yq/id).
2. Fetch status API (above). Build a map `job_id → status`.
3. Print a table: id, name, schedule/tz, enabled, runtime, **readiness**,
   last_probe, last_run, failure_class, next_actions (short).
4. Merge rules:
   - status hit → use API readiness fields
   - no row → `pending_probe`
   - API down/error → show YAML fields + readiness `stale/unknown` (label clearly)

Never hide a registry job because status failed.

## `/schedule rm|enable|disable`

- Resolve file by `id` (scan registry dirs).
- rm: delete file. enable/disable: set `enabled` true/false via yq, re-validate.
- Ensure alert profile exists on first mutation.
- Sync push affected paths.
- enable does **not** claim the job is ready — readiness stays API-driven.

## `/schedule probe [id]`

- Prefer remote: when `core/scripts/hq-job-probe.sh` exists on the Outpost,
  run via `hq outposts exec -- …`. Do not invent a local "ready".
- If probe script missing (US-008 not on box yet): show the job's requirements
  checklist and next actions (share secrets / device login on Outpost) without
  marking ready.
- After a successful remote probe, refresh status GET for display.

## `/schedule run-now <id>`

- When `hq-job-run.sh` is on the box, `hq outposts exec` a one-shot.
- If runner missing: say reconciler/runner not installed yet; do not fake a
  local run.

## Deprecated `/job`

If invoked as `/job`, say the command is now `/schedule`, then continue with
this skill.

## See also

- Spec: `core/knowledge/public/hq-core/outpost-jobs-spec.md`
- PRD: `companies/indigo/projects/outpost-scheduled-jobs/prd.json` (US-003)
- Validator: `core/scripts/jobs-validate.sh`
- Parser: `core/scripts/jobs-schedule-parse.sh`
- Status: hq-pro `GET /outpost/jobs/status` (US-009)
- Probe: `core/scripts/hq-job-probe.sh` (US-008 — peer)
