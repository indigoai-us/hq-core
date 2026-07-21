# HQ hooks not firing in Claude Desktop or an SDK runtime

HQ safety, voice, and policy hooks live in the project's
`.claude/settings.json`. Claude Code terminal sessions can work while Desktop
or an SDK session silently runs none of those hooks if that file is missing or
the runtime did not load project settings.

## Diagnose without relying on hooks

From the HQ root, run:

```bash
bash core/scripts/check-hq-hooks.sh --root "$PWD"
```

The checker confirms valid `.claude/settings.json` plus non-empty
`SessionStart` and `PreToolUse` command hooks. It is an ordinary shell command,
so it works even when every lifecycle hook is unavailable.

After starting an actual Desktop or SDK session, verify that the policy trigger
was observed as well:

```bash
bash core/scripts/check-hq-hooks.sh --root "$PWD" --require-ledger
```

On a brand-new HQ root, run the first command before the ledger check: no
ledger exists until a session has had an opportunity to run.

## Restore the released project settings

If the checker fails, restore the release-owned `.claude` tree. This replaces
the missing project settings while retaining the machine-local
`.claude/settings.local.json` override:

```bash
hq rescue -y --paths .claude
bash core/scripts/check-hq-hooks.sh --root "$PWD"
```

`/update-hq` runs this postcheck automatically and repeats the targeted rescue
when needed.

## Make Desktop and SDK load the project

In Claude Desktop, open the HQ root folder itself as the project. Do not launch
from a parent directory or an unrelated child directory; start a new session
after selecting the root.

For an SDK runtime, pass both values on every launch:

```ts
const hqRoot = "/absolute/path/to/HQ";

query({
  prompt: "...",
  options: {
    cwd: hqRoot,
    settingSources: ["project"]
  }
});
```

`cwd: hqRoot` locates the project and `settingSources: ["project"]` permits
the runtime to load its `.claude/settings.json`. Restart the session after
changing either value, then rerun the `--require-ledger` check.
