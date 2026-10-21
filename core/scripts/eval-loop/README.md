# eval-loop

Closed surface and per-company library for one `/execute-task` class.

US-001 only. Later stories add the ledger, packets, probe, selection, adoption, and the evidence report. This directory does not start `hq lanes` and does not edit conduct or super-conductor.

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
