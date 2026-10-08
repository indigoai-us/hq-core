# scan.sh --progress-json: streaming scan events (contract v1)

`scan.sh --progress-json --output=<report.json>` prints JSON Lines on stdout
while it scans, so an app (the HQ desktop first-run setup) can draw a knowledge
tree that grows as sources, companies and projects are found. The HQ CLI relays
this stream as `hq import scan --json --stream`.

The flag does not change `report.json`: the file is byte-identical with and
without it. Without the flag, stdout is unchanged (the report path when
`--output` is set, otherwise the report JSON). `--progress-json` requires
`--output`, because stdout carries the events; a missing `--output` exits 2.
Warnings stay on stderr.

## Events

One JSON object per line. Every object has `"v":1` and `"type"`.

| type | fields | meaning |
|---|---|---|
| `start` | `sources: [{id, label}]` | First line. Lists only the sources present on this machine, in the order they will be scanned. |
| `source` | `id`, `status` (`scanning` \| `done` \| `skipped` \| `error`), `counts` (on `done`), `message` (on `skipped`/`error`) | Source lifecycle. Each listed source emits `scanning` once, then exactly one of `done`, `skipped` or `error`. scan.sh v1 emits `error` only for an unreadable claude.ai export; `skipped` is reserved and consumers must accept it. |
| `count` | `source`, `key`, `value` | A running count for a source. The last `count` for a key equals the value in that source's `done.counts`. |
| `company` | `id`, `name`, `basis` (`hq-company` \| `repo-org` \| `folder`) | A company found by the rule pass. Emitted once per id, before any project that references it. |
| `project` | `id`, `name`, `company` (company id or `null`), `basis` (`repo` \| `claude-code-cwd` \| `codex-cwd`) | A project. Consumers upsert by `id`: an id is sent again only when a later rule pass attaches a company to a project that had none. `name` and `basis` never change. |
| `error` | `source`, `message` | A non-fatal problem in plain words (for example some folders could not be read). The scan continues. |
| `done` | `report` (absolute path to report.json), `summary: {companies, projects, sessions}` | Last line. Counts distinct company ids, distinct project ids, and sessions across all conversation sources. |

Source ids and labels, in scan order:

| id | label | present when | count keys |
|---|---|---|---|
| `hq` | HQ companies | always (reads `companies/manifest.yaml` under `--hq-root` if present) | `companies` |
| `repos` | Code repositories | at least one scan scope exists | `repos` (git checkouts, including linked worktrees) |
| `claude-code` | Claude Code | `~/.claude/projects` exists | `sessions` |
| `codex` | Codex | `~/.codex/sessions` exists | `sessions` |
| `grok` | Grok | `~/.grok/sessions` exists | `sessions` |
| `claude-ai` | claude.ai export | `--claude-export` was passed | `sessions` (conversations) |
| `artifacts` | Skills and settings | always | `skills`, `commands`, `hooks`, `agents`, `policies`, `plans`, `claude_md`, `settings_fragments`, `mcp_servers` |

`artifacts` is the existing report build. Its counts arrive at the end, after
the slowest part of the scan, so a consumer should show it as in progress
between `scanning` and `done`.

## Example

```
{"v":1,"type":"start","sources":[{"id":"hq","label":"HQ companies"},{"id":"repos","label":"Code repositories"},{"id":"claude-code","label":"Claude Code"},{"id":"artifacts","label":"Skills and settings"}]}
{"v":1,"type":"source","id":"hq","status":"scanning"}
{"v":1,"type":"company","id":"acme","name":"Acme Corp","basis":"hq-company"}
{"v":1,"type":"count","source":"hq","key":"companies","value":1}
{"v":1,"type":"source","id":"hq","status":"done","counts":{"companies":1}}
{"v":1,"type":"source","id":"repos","status":"scanning"}
{"v":1,"type":"count","source":"repos","key":"repos","value":1}
{"v":1,"type":"count","source":"repos","key":"repos","value":2}
{"v":1,"type":"count","source":"repos","key":"repos","value":3}
{"v":1,"type":"company","id":"initech","name":"Initech","basis":"repo-org"}
{"v":1,"type":"project","id":"p_a9b70b65d5b4","name":"lib","company":"initech","basis":"repo"}
{"v":1,"type":"project","id":"p_17a9594ce634","name":"solo-tool","company":null,"basis":"repo"}
{"v":1,"type":"project","id":"p_42c6c41b8028","name":"web","company":"acme","basis":"repo"}
{"v":1,"type":"source","id":"repos","status":"done","counts":{"repos":3}}
{"v":1,"type":"source","id":"claude-code","status":"scanning"}
{"v":1,"type":"count","source":"claude-code","key":"sessions","value":1}
{"v":1,"type":"count","source":"claude-code","key":"sessions","value":2}
{"v":1,"type":"count","source":"claude-code","key":"sessions","value":5}
{"v":1,"type":"count","source":"claude-code","key":"sessions","value":7}
{"v":1,"type":"project","id":"p_3c1d0e9f2b7a","name":"plans","company":null,"basis":"claude-code-cwd"}
{"v":1,"type":"source","id":"claude-code","status":"done","counts":{"sessions":7}}
{"v":1,"type":"source","id":"artifacts","status":"scanning"}
{"v":1,"type":"count","source":"artifacts","key":"skills","value":12}
...
{"v":1,"type":"source","id":"artifacts","status":"done","counts":{"skills":12,"commands":0,"hooks":3,"agents":0,"policies":2,"plans":4,"claude_md":5,"settings_fragments":2,"mcp_servers":1}}
{"v":1,"type":"done","report":"/abs/path/workspace/imports/2026-10-08T10-00-00/report.json","summary":{"companies":2,"projects":4,"sessions":7}}
```

## Rule pass (deterministic, no LLM)

Companies, in order of precedence:

1. `hq-company`: every company in `companies/manifest.yaml`, in manifest order.
   The id is the slug of the manifest key (`My_Co` becomes `my-co`); the name
   is the manifest `name`, else the key. Keys starting with `_` (templates) are
   skipped, and when two keys share a slug the first wins. A project under
   `companies/<key>/` in the HQ root, or whose git remote matches a repo listed
   in that company's manifest `repos:`, belongs to it. Other folders under
   `companies/` (templates, `cmp_*` caches, test residue) are not companies.
2. `repo-org`: the org (first path segment) of a project's git remote. When the
   org matches an HQ company's `github_org`, slug or name, the HQ company is
   used instead of a new one.
3. `folder`: a project without a company inherits the company of its sibling
   projects when they all share one; otherwise, when 2 or more projects share
   a parent folder that is not a scan root, `$HOME`, or a generic name (`src`,
   `code`, `projects`, `repos`, `github`, `work`, `tmp`, ...), that folder
   becomes a company.

Ids are lowercase slugs (`[a-z0-9-]`). An id is never emitted twice.

Projects:

- `repo`: each git checkout found under the scan scopes (pruned like the
  artifact walk; dot-folders, `node_modules`, the HQ root and other build
  folders are skipped). Checkouts with the same remote, such as linked
  worktrees or second clones, are one project.
- `claude-code-cwd` / `codex-cwd`: session working directories that are not
  already a known project. A directory inside a git checkout maps to that
  checkout. `$HOME`, its ancestors, scan roots, dot-folders, app data
  (`~/Library/...`, `~/AppData/...`) and temp folders are never projects.
  Folder names that look machine-generated (12+ characters of hex digits and
  dashes, such as UUIDs) never become folder companies. Inside the HQ root only `repos/<vis>/<name>`,
  `companies/<co>/projects/<name>` and `workspace/worktrees/<name>` count.
  Grok and claude.ai sessions are counted but do not create projects in v1.
- `id` is `p_` plus 12 hex characters: two polynomial hashes (moduli just
  below 2^44, computed in awk so every machine uses the same function) of a
  fixed salt (`hq-import-scan-v1|`) plus the project identity. The identity is
  the git remote `host/org/.../name` (lowercased) when the remote is usable, so
  the same repo has the same id on every machine and in every clone location;
  otherwise it is the directory path relative to `$HOME` (`~/code/x`), or the
  absolute path for folders outside `$HOME`. The id is stable across runs and
  across machines with the same layout, and does not carry the home path.
- Paths containing a tab or newline are skipped. File lists are NUL-delimited
  throughout.

## Ordering guarantees

For the same machine state the stream is byte-for-byte the same on every run:

- Sources run in `start` order. Within a source: `scanning`, then counts,
  companies and projects, then the closing `source` event.
- Count events fire at fixed milestones on a 1-2-5 progression (1, 2, 5, 10,
  20, 50, 100, ...) and once more with the final value. This replaces a
  wall-clock throttle so the stream stays deterministic; a source with 3,000
  sessions sends 12 count events.
- New companies are emitted sorted by id, then new or updated projects sorted
  by name, then id.

## Privacy guarantees

- Events carry names and counts only: no file contents, prompts, message text,
  secrets, or session ids.
- No absolute paths, except `done.report`. Project names are directory or
  repository basenames; company names are manifest names, remote org names or
  folder basenames.
- To group sessions, the scanner reads only the first `"cwd"` value of each
  session file (`grep -m1 -o`), and never emits it.
- Git remotes are read from `.git/config` without running git. A quoted value
  (`url = "https://..."`) is unquoted first. Query strings
  (`?...`) and fragments (`#...`) are dropped, userinfo (including passwords
  that contain `/`) is cut at the last `@`, and a remote is ignored (the
  project falls back to its folder name) when the host is not a plain host
  name or the org or name still contains `@ : ? # % "` or whitespace. Only the
  org and repo name are emitted. Nothing is sent over the network.

## Interruption and output

- On SIGTERM or SIGINT the scanner stops every child process, deletes its
  temp directory (which holds the file and session path lists), and exits 143
  (TERM) or 130 (INT). No `done` event is printed and no report is published.
  Every temp file the scan creates lives in that one private directory
  (created with mode 700 under `$TMPDIR`, or `/tmp` when `TMPDIR` is unset).
- Bash runs a trap only after the current foreground child exits. A SIGTERM
  sent to the scanner's bash process alone therefore waits for the running
  `find`, `grep` or `awk` to finish, which can take a few seconds on a large
  folder, before cleanup starts. hq-cli starts the scanner in its own process
  group and signals the whole group, so every child stops at once; other
  callers should do the same.
- `report.json` is written to a temp file next to `--output` and renamed into
  place, so a reader never sees a partial report.

## Versioning

`v` is the contract version. Within v1, new optional fields, new source ids,
new count keys and new `error` messages may be added; consumers must ignore
unknown fields, show unknown sources with their `label`, and must not depend on
message text. Removing or renaming a field, changing a field's type, adding a
new `type`, `status` or `basis` value, or changing ordering guarantees requires
`v: 2`.

Tests: `core/scripts/tests/import-context-progress-json.test.sh`.
