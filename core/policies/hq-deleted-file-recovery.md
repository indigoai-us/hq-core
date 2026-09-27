---
id: hq-deleted-file-recovery
title: Recover deleted HQ files with hq-cli
when: ((delete || deleted || undelete || recover || recovery || restore || quarantine) && (hq || vault || company || companies || personal || mirror))
on: [UserPromptSubmit, PreToolUse]
enforcement: hard
tier: 1
version: 2
created: 2026-09-26
updated: 2026-09-26
source: owner-request
public: true
---

## Rule

Use this procedure only to recover a specific HQ file. Confirm its exact path and owner before any vault request. Do not use it for ordinary Git operations or unrelated file deletion.

Keep user-controlled values out of shell source. Read each exact key into a shell variable without evaluating it, then pass it as one quoted argument, such as `"$key"`. Quote the company slug and local HQ root the same way. Do not paste a raw vault key into a command.

The hq-cli 5.224.0 help output confirms the `hq files` options and the `hq files versions`, `hq files restore`, `hq files get`, and `hq sync status` forms used below.

### Local mirror history

The released hq-cli has no command to inspect the Desktop local git mirror or restore a deleted local file from its history. Stop and ask the HQ maintainer for an approved recovery procedure. Do not substitute a shell or Git command here.

### Scope quarantine

A scope shrink can leave a file under `<HQ>/.hq/scope-quarantine/<journalSlug>/` while removing it from the sync journal. Run `hq sync status --hq-root "$hq_root"` to check the local journal summary. This command does not list quarantined files or restore them. The released hq-cli has no command for either task. Stop and ask the HQ maintainer for an approved recovery procedure.

### Vault version history

Use only the exact company or personal vault that owns the file. A vault restore writes data and can replace current content. Confirm the target scope, exact key, selected content version, and local destination with the user before restoring. Do not use a wildcard.

For a company file, list its history with:

```sh
hq files --company "$company" versions "$key"
```

For a file in your personal vault, use:

```sh
hq files versions "$key" --personal
```

Choose a content version from the output. A delete marker is not a content version. To restore that version, run the matching command after the user approves the write:

```sh
hq files --company "$company" restore "$key" --version-id "$version"
```

```sh
hq files restore "$key" --personal --version-id "$version"
```

To undelete the exact key without selecting a prior version, omit `--version-id` from the matching restore command. The CLI prompts before restoring. Do not add `--yes` unless the user has approved this exact overwrite.

After restoring a company file, materialize the exact key into the local HQ tree with:

```sh
hq files --company "$company" get "$key" --hq-root "$hq_root"
```

Before running `get`, confirm its exact local destination is correct and can be overwritten. It writes the file under `<HQ>/companies/<company>/<path>` and pins it so a scoped sync keeps it. Verify that the restored file exists at that path and inspect its contents.

`hq files get` supports company files only. The released CLI has no corresponding personal-vault materialization command. If a personal-vault restore must also recreate a missing local file, stop and ask the HQ maintainer for an approved procedure. Do not substitute a shell, Git, copy, or sync workaround.

If the company, key, version, or local destination is unclear, stop and ask the owner before continuing.
