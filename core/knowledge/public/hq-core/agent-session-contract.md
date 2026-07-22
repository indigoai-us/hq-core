---
type: reference
domain: [engineering, operations]
status: canonical
tags: [agents, session, contract, fleet, entrypoint]
relates_to:
  - core/schemas/agent-session-request.schema.json
  - core/schemas/agent-session-response.schema.json
  - core/scripts/hq-agent-session.sh
  - core/core.yaml
---

# HQ Agent Session Contract

Versioned envelope between **hq-pro** (authenticates the sender, resolves
`convKey`, delivers the channel payload) and **hq-core** (owns the on-box
session runtime). Schema first: every later story in the contract-entrypoint
area validates against the two schema files listed below.

| Artifact | Path |
|----------|------|
| Request schema | `core/schemas/agent-session-request.schema.json` |
| Response schema | `core/schemas/agent-session-response.schema.json` |
| Contract version key | `agentSessionContractVersion` in `core/core.yaml` |
| Owning entrypoint | `core/scripts/hq-agent-session.sh` |

**Current contract version:** `1` (see `core/core.yaml` →
`agentSessionContractVersion`).

## Single owning entrypoint

**`core/scripts/hq-agent-session.sh`** is the single owning entrypoint for an
on-box agent session turn. Producers (Slack/Telegram/email/DM/job/task
watchers) emit one JSON request envelope on stdin; the entrypoint validates it,
runs the six responsibilities below, and emits one JSON response envelope on
stdout. No parallel session entrypoint is authorized.

Implementation of the runtime body is deferred (US-402 and follow-ons). This
document and the schemas are the durable seam those stories implement against.

## Six entrypoint responsibilities

The entrypoint owns exactly these six responsibilities. Nothing else may
assemble prompts, fire hooks, inject policies, rehydrate history, dispatch
skills/workers, or decide durable write locations for a contract-mode turn.

1. **System-prompt assembly** — Build a deterministic system prompt into
   `<runDir>/system.txt`, separated from untrusted channel content in
   `<runDir>/user.txt`. Charter, agent contract, company charter, channel
   format, posture, and policy sections land here with machine-checkable
   section delimiters.
2. **Hook execution** — Bootstrap session meta, then invoke SessionStart and
   UserPromptSubmit through the native master-hook path so company hooks and
   injectors fire for real (not fabricated watcher-side payloads).
3. **Policy injection** — Materialize triggered policies into the system
   prompt under the policies section, with an observable budget and company
   precedence over core on id collision.
4. **Conversation rehydration** — Consume optional `rehydration` /
   `rehydrationTurnCount` from the request and place prior-turn context where
   the contract specifies (never silently drop a provided prefill).
5. **Skill / worker dispatch** — Resolve named skills and workers for the
   company-scoped catalog and route work through HQ-native dispatch, not
   ad-hoc shell forks outside the entrypoint.
6. **Durable writes** — Direct plans, research, and artifacts under
   company/project paths (or the slug derived from `convKey` when `project`
   is absent) and report HQ-root-relative paths in the response `artifacts`
   array.

## Request envelope (summary)

Required fields (see schema for full types):

| Field | Type | Notes |
|-------|------|--------|
| `contractVersion` | integer | Rejected if absent or non-integer |
| `agentUid` | string | Fleet agent id |
| `companySlug` | string | Must resolve to a synced company on the box |
| `channel` | enum | `slack` \| `telegram` \| `email` \| `dm` \| `job` \| `task` |
| `convKey` | string | Stable conversation key |
| `messageText` | string | Untrusted channel body |
| `provider` | enum | `claude` \| `codex` \| `grok` |
| `sender` | object | Must include boolean `verified` |

Optional fields:

| Field | Type | Notes |
|-------|------|--------|
| `rehydration` | string \| null | Prefill block; null when unavailable |
| `rehydrationTurnCount` | integer ≥ 0 | Turn count for the prefill |
| `project` | string | Pattern `^[a-z0-9-]{1,64}$` |

`additionalProperties` is **false** on the request schema: undeclared fields
are rejected rather than silently ignored.

## Response envelope (summary)

Required fields:

| Field | Type | Notes |
|-------|------|--------|
| `contractVersion` | integer | Rejected if absent or non-integer |
| `disposition` | enum | `reply` \| `no_reply` \| `clarify` \| `plan` \| `error` |
| `text` | string | Channel-facing body (may be empty for `no_reply`) |
| `artifacts` | string[] | HQ-root-relative paths |

Later stories may add optional diagnostic fields (e.g. `runDir`,
`systemPromptBytes`); the response schema allows additional properties so
those can land without a breaking request-schema edit.

## Channel brief constants (inbox-watcher migration inventory)

These thirteen module-level constants are declared in hq-pro
`src/agents/inbox-watcher-cli.ts` (approximately lines 109–156). Today they
are concatenated into a single user task file by the watcher. Under the Agent
Session contract they move into the entrypoint-owned prompt assembly with an
explicit destination so none are dropped silently.

| Constant | Destination | Role |
|----------|-------------|------|
| `SLACK_VERIFIED_PREAMBLE` | **system.txt** | Trust framing when Slack sender is a verified member |
| `SLACK_STRICT_UNTRUSTED_PREAMBLE` | **system.txt** | Safety framing for unknown/non-member Slack senders |
| `DM_VERIFIED_PREAMBLE` | **system.txt** | Trust framing when HQ DM sender is verified |
| `DM_STRICT_UNTRUSTED_PREAMBLE` | **system.txt** | Safety framing for untrusted DM senders |
| `VERIFIED_MEMBER_REPLY_POSTURE` | **system.txt** | Act-on-instruction posture for verified members |
| `REPLY_NO_PROMISES` | **system.txt** | No future-work promises; arm jobs/tasks or do it now |
| `SLACK_FORMATTING` | **system.txt** | Slack writing format / mrkdwn contract |
| `SLACK_PROGRESSIVE_POSTS` | **system.txt** | Progressive multi-message Slack milestones |
| `SLACK_DECISION_ASKING` | **system.txt** | Enumerable decisions via Block Kit, not prose |
| `CHANNEL_VOICE` | **system.txt** | Shared agent voice profile |
| `TELEGRAM_FORMATTING` | **system.txt** | Telegram writing format |
| `EMAIL_FORMATTING` | **system.txt** | Email writing format |
| `DM_FORMATTING` | **system.txt** | HQ DM writing format |

**Destination rule:** all thirteen constants are **system.txt** content under
this contract. **user.txt** carries only the untrusted channel payload
(`messageText` and related raw channel fields), optionally wrapped with
UNTRUSTED delimiters — never the trust, posture, voice, or formatting brief.

Channel-specific constants are still only *emitted* for the matching
`channel` value; the inventory above is the full set that must survive the
move from the watcher.

## Skill body trust classification

A chat message that begins with `/<skill-name>` is skill **dispatch**, not
free-form channel prose. Resolution and placement:

| Artifact | Destination | Trust |
|----------|-------------|--------|
| Invoking message text (`messageText`) | **user.txt** only | **UNTRUSTED** channel input |
| Resolved `SKILL.md` body | `<runDir>/skill.txt` and **system.txt** under `<!-- hq-section: skill -->` | **TRUSTED** repo content |

**Why TRUSTED:** the skill body is delivered by `hq rescue` and the HQ sync
legs as part of the on-box tree (`.claude/skills/`, `companies/<slug>/skills/`,
`core/packages/*/skills/`). It is not supplied by the channel. Therefore the
skill body belongs in the system channel with charter and policy text, while
the invoking slash-command line stays in the untrusted user channel that
system/user separation protects.

An unresolved `/<skill-name>` yields disposition `clarify` with nearest
catalog matches and writes **no** `skill.txt`. Catalog entries themselves are
name plus one-line description only; full bodies are never inlined into the
catalog section.

## Policy records (system.txt)

Triggered policies land under `<!-- hq-section: policies -->` in system.txt
only (never user.txt). The entrypoint consumes the hook's
`HQ_POLICY_EMIT=tsv` records (`slug`, `scope`, `abs_path`, `enforcement`,
`rule`) so company-over-core precedence and hard-before-soft budget ordering
are machine-derivable. Truncation is reported via `policiesTruncated` and is
never silent.

## Versioning

- Boxes advertise support via `agentSessionContractVersion` in
  `core/core.yaml`.
- A request `contractVersion` greater than the box supports is refused
  (later story: stable error code / disposition `error`).
- A lower request version may proceed with a downgrade marker so older
  clouds talking to newer boxes do not stall.

## Related

- Entrypoint stub: `core/scripts/hq-agent-session.sh` (body in US-402+)
- Directory map: `core/docs/hq/INDEX.md`
- Session metadata helper (distinct): `core/scripts/hq-session.sh`
