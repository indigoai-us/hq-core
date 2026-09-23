---
type: reference
domain: [knowledge, engineering]
status: canonical
tags: [sources, ontology, signals, spec]
---

# source.yaml — declaring a data source

Any folder under `companies/{co}/sources/{channel}/` becomes a data source when
it contains a `source.yaml`. The file tells HQ how items arrive, who may see
them, and which processor turns them into signal and entity candidates. The
ontology worker's `process-source` skill reads it; `garden` then promotes the
candidates. Storage and audience rules: `ontology-local-spec.md`.

Validate with `core/scripts/source-yaml-validate.sh <path>`.

## Fields

| Field | Required | Values | Meaning |
|---|---|---|---|
| `channel` | yes | slug, must equal the folder name | Name of the source |
| `kind` | yes | `meeting`, `email`, `slack`, `doc`, `custom` | What the items are |
| `arrives` | yes | `drop`, `pull`, `cloud` | `drop`: someone puts files in the folder. `pull`: `pull_command` fetches them. `cloud`: HQ cloud ingestion writes them and sync delivers them. |
| `pull_command` | when `arrives: pull` | shell command, run from the HQ root | Fetches new items into the channel folder |
| `audience_rule` | yes | `attendees`, `thread`, `channel`, `company`, `explicit` | How each item's audience is derived. `attendees`: people present on a meeting. `thread`: every address on an email chain. `channel`: Slack channel members at message time. `company`: the whole company. `explicit`: the item's own `audience:` frontmatter. |
| `processor` | yes | `<worker>/<skill>` | Skill that turns an item into candidates, usually `ontology/process-source` |
| `run` | yes | `local`, `cloud` | Where the processor runs: this machine on a routine, or a cloud agent |
| `schedule` | yes | cron expression or `on-close` | When the processor runs. `on-close` means after each session close. |

`audience_rule` is never optional. An item whose audience cannot be derived is
skipped and logged, never defaulted to `company`.

## Example

```yaml
channel: meetings
kind: meeting
arrives: cloud
audience_rule: attendees
processor: ontology/process-source
run: local
schedule: "0 6 * * *"
```
