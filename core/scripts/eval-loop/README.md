# eval-loop

Closed surface and per-company library for one `/execute-task` class.

US-001 surface, US-002 ledger, and US-003 packets. Later stories add the probe, selection, adoption, and the evidence report. This directory does not start `hq lanes` and does not edit conduct or super-conductor.

## Surface

A harness tree may contain only these relative prefixes:

- `skills/`
- `policies/`
- `worker-prompts/`
- `tool-guidance/`
- `subagents/`

Anything else is rejected. An absolute path, or any segment equal to `..`, is rejected before the path is joined to a directory. A patch that omits a file keeps that file's incumbent bytes. Serializing a tree and reading it back does not change those bytes. Two paths that normalize to the same key are rejected. A key that is also a folder of another key (`skills/a` and `skills/a/b`) is rejected. Two keys, or two folders, that differ only by case or by Unicode normalization (composed and decomposed accents) are rejected. A NUL byte or a non-UTF-8 stored key raises `SurfaceError`.

A slot directory or a file that is a symlink, or a file with more than one hard link, is refused, so an incumbent read cannot copy bytes from outside the tree. The incumbent walk opens each folder relative to its parent with `O_NOFOLLOW`. It stops with an error past 32 nested folders. `apply_to_directory` checks the patch, the merged layout, the incumbent tree, and every existing destination path before it creates the destination. On `SurfaceError` from those checks it does not write a file and does not create the destination. Every error it raises is a `SurfaceError`. A missing destination is created only inside an existing parent folder that is not a symlink. Parent folders are never created.

## Library

```text
companies/{company}/eval-library/{classId}/
```

`company` and `classId` are ASCII slugs: lowercase letters, digits, and hyphens that are not first or last, 1 to 64 characters. An empty slug, `..`, an absolute slug, or a non-ASCII slug is rejected.

Every library read and write runs `company_scope`, the same checks as the ledger:

- The company argument must equal `session_company`.
- The companies root must resolve to exactly the HQ root's `companies` directory. The HQ root is `HQ_ROOT`, else `CLAUDE_PROJECT_DIR`, else this checkout. A second tree with its own manifest is refused, inside or outside the HQ root.
- The company must be in the session lock read by `core/scripts/hq-session.sh get company_slugs`. No session, an empty lock, or a failed read is refused.
- The company must be a key under `companies:` in the manifest at the companies root.

A failed check raises `SurfaceError` before that company's directory is joined, opened, or created. A write never creates a company directory.

Library paths use the same five slots as a harness tree. Every component from the `companies` directory through the company folder, `eval-library`, the class id, and each segment below is refused when it is a symlink or when its real path sits outside that company. Opens use `O_NOFOLLOW`. A library file with more than one hard link is refused on read and on write, because the second name could sit in another company. A write goes to a new temp file in the target folder and is renamed over the old name, so bytes are never written into a shared inode.

Tests build HQ roots, session locks, and company roots under a temp directory. They do not read the live `companies/` tree.

## Ledger

`ledger.py` plans a run and writes it under the company eval-library. Default k is 1. The hard cap is a parent-chain depth of 2, shared by every class in the company. The first plan in a company may omit the parent. A later plan names that run, including a plan for another class. The ledger creates the library and class folders on its first plan, under its own symlink checks.

A run is planned once, with `ledger.plan_run`, before its rollouts. Compose does not plan. It records its own session stage on the run it is given.

## Packets

`packets.py` builds the text the proposer and the composer see. It does not call a model.

Grades are withheld by construction. The builders read only an allowlist of keys and files, and none of them can hold a grade:

- Proposer run records: `label`, `run_id`, `ok`, `delivered`, `cost` (or `cost_usd`), and `error`. Any other key is refused, and the refusal does not name the key. `error` must be one of the fixed codes in `ERROR_CODES`, so free text cannot ride in it.
- Compose deliverables: `label`, `task_id`, `k`, `mode`, and `text`. Any other key is refused.
- Files: the CLI opens only files under a fixed set of input roots, listed below. Any other path is refused before it is opened.

The proposer view has five fields: `label`, `run_id`, `ok`, `delivered`, and `error`.

- `ok` means the rollout process ended without an error code. It must equal `error == ""`, and a record where they disagree is refused. It never carries a check result.
- `delivered` means the rollout wrote a deliverable artifact.
- `cost` is accepted on a record and never read. It does not reach the view.
- `label` and `run_id` are minted by the builder. A view shows `arm-N` (numbered by first appearance of a label) and `run-N` (numbered by position). The harness slugs are validated and scanned, and never copied.

Input roots, relative to `companies/{company}/eval-library/{classId}/`:

| Flag | Root | Suffixes |
|---|---|---|
| `--work` | `briefs/` | `.md`, `.txt` |
| `--runs`, `--record` | `runs/` | `.json` |
| `--deliverables` | `deliverables/` | `.json` |
| `--diff` | `diffs/` | `.diff`, `.patch`, `.txt` |
| `--tree`, `--incumbent` | `trees/` | `.json` |
| `--patches` | `patches/` | `.json` |

`--out` must be under `packets/` and end in `.json`. A path has at most 4 segments, and each segment is lowercase letters, digits, `.`, `_`, and `-`. A path in the wrong root, with another suffix, or with an uppercase or non-ASCII segment fails with `path is not an allowed input`. A segment inside a root that contains a grade stem (`grade`, `result`, `verdict`, `score`, `rubric`, `judg`, `ledger`, `benchmark`, `eval`, `assess`, and similar) is refused as a grade area, so `runs/scorecard.json` is refused. Grader outputs and the ledger live outside these roots, so the builders have no read path to them. Tree paths and paths named in a diff still pass the closed-surface allowlist and the grade-area check.

A keyword scan runs on every string that reaches a packet as defense in depth. It normalizes NFKC, drops format and zero-width characters, folds common confusables, and splits camelCase before matching. It catches grade words, verdict tokens, `N of M` and `N/M` counts near pass or fail, percentages, decimals next to a metric word, and base64 or hex blobs that decode to any of these. It also scans the join of all fields, so a grade split across two fields is caught. Refusal messages never quote the input.

`build-packet` refuses work text that contains `benchmark`, `evaluation`, `grader`, `rubric`, or `score`, without regard to case, and refuses other grade text. The output file is not created.

`store-tree` refuses a tree whose path or bytes contain a grade or a grader-verdict marker, or whose path is in a grade area. The check runs before the output file is opened.

`compose` writes the harness diff and anonymized deliverable text for a run that is already planned. `--run` is required and names that run. Every k must match, and must equal the run's k. The count of deliverables may not exceed the rollouts the ledger plans for that k (2 at k=1, 3 at k=2), so ten deliverables at k=1 are refused before anything is written. Anonymization works on token boundaries: each label and `task_id|k|mode` token in every text becomes that candidate's `candidate-N`, and a substring inside another word is left alone. `candidate-N` follows the sha256 order of the deliverable text, not the input order, so the same deliverables in any order give the same packet. Two deliverables with the same label are refused. An item over 256 KiB, or a packet over 1 MiB, raises `PacketError` and writes nothing.

Compose records one session stage on the run: `session:compose` at k=1, and `session:compose-1` then `session:compose-2` at k=2. A further compose on the same run is refused. An unknown run, a run in another class, a k that differs from the run's k, a started ledger, or a finished run is refused before anything is written. The output file is created with `O_EXCL` before the stage is recorded. An existing output is refused and no ledger entry is written. If the ledger refuses the stage, including for a run finished after the slot check, the new output file is removed. A refusal can leave empty library folders and the ledger lock files behind. `ledger.json` does not change. On success the CLI prints the run id.

Compose must run before `ledger.start` for the run. A started ledger refuses new compose stages.

Every packet input read and packet output write goes through the surface library walk, so it runs `company_scope` (company flag, session lock, HQ root companies directory, and manifest) before the company directory is opened. A matching `--company` and `--session-company` is not enough. Every CLI path is checked before any file is read. An absolute path, a `..` segment, a symlink, a file with more than one hard link, or a company outside the session lock raises before that file is read and before the output file is created. The compose stage is written by the ledger, which runs its own scope checks before it opens `ledger.json`.

`plan` applies one patch through the closed surface. An invalid patch is tried once more. A second invalid patch leaves the incumbent bytes as they were and records the reason as fixed codes (`attempt 1: invalid_path`), never a fragment of the patch. A third attempt is refused.
