# HQ hooks not firing in Claude Desktop or an SDK runtime

HQ safety, voice, and policy hooks live in the project's
`.claude/settings.json`. Claude Code terminal sessions can work while the
affected Claude Code app/SDK runtime silently runs none of those command hooks,
even when that settings file is present and its shell scripts work when invoked
by hand.

In that runtime, the command-hook registrations for `SessionStart`,
`UserPromptSubmit`, `PreToolUse`, and `PostToolUse` are not dispatched. This
leaves policy injection, per-turn voice injection, secret detection, core-write
and cross-company guards, autocommit, and journal capture inactive. This is a
Claude Code product/runtime limitation: HQ cannot make a host dispatch a hook
event that the host does not implement.

HQ now mitigates the gap with a native import in `.claude/CLAUDE.md`:
`@personal-context.md`. The imported `.claude/personal-context.md` is preserved
by `/update-hq`, imports `personal/CLAUDE.md`, carries the minimum secret,
core-write, and cross-company guidance, and warns directly in context when an
app/SDK host may not run hooks. It is not a mechanical security boundary. Use
the terminal CLI or host-side enforcement for work that requires a guaranteed
block.

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
ledger exists until a session has had an opportunity to run. If the second
command prints `HQ runtime enforcement: NOT OBSERVED`, it has made the missing
dispatch loud without relying on a hook to run the diagnostic.

An SDK host with the current session ID can make this conclusive for that
runtime rather than accepting a prior CLI session's evidence:

```bash
bash core/scripts/check-hq-hooks.sh --root "$PWD" --session-id "$SESSION_ID"
```

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

For an SDK runtime, pass both values on every launch to load the native project
context:

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
the runtime to load native project context such as the durable
`personal-context.md` import. In the affected app/SDK runtime, neither option
causes command-hook events to dispatch. Restart the session after changing
either value, then rerun the `--require-ledger` check; a `NOT OBSERVED` result
means use the terminal CLI or host-side enforcement for safety-critical work.
