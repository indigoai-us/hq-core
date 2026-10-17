# Golden dispatcher contract

Run with Node.js 22+, Bash, jq and coreutils timeout or Perl installed:

```sh
bash core/scripts/tests/hook-contract/run-contract.sh --engine 'bash .claude/hooks/master-hook.sh'
node core/scripts/hook-corpus/generate-corpus.mjs --check
node --test core/scripts/hook-corpus/corpus.test.mjs
node core/scripts/hook-corpus/differential.mjs --engine-a 'bash .claude/hooks/master-hook.sh' --engine-b '/absolute/path/to/other-engine'
```

The runner copies the current dispatcher and its required helpers into a fresh
fixture root for each case, installs synthetic child hooks, and passes one JSON
payload on stdin. The trusted engine command runs with that root as cwd and
receives the event name as its last argument. An alternative engine should use
HQ_ROOT to discover the fixture hooks. Each case has its own HOME and an
allowlisted environment. Nothing runs against the developer's real hooks.

`cases.json` is language neutral. `$FIXTURE` expands to the absolute fixture
root; `{"$repeat":"x","count":70000,"suffix":"\n"}` represents a large string.
JSON assertions compare the complete object; text assertions compare exact
bytes and ordering. Output and subprocess execution are bounded.

## Approved current-bash exceptions

The operator chose the behavior-identical baseline on 2026-10-17. These two
exceptions are named in cases.json. No production dispatcher was changed:

- `exception-recursive-nested-merge`: merging `{"value":{"old":1,"replace":1}}`
  and `{"value":{"replace":2}}` yields
  `{"value":{"old":1,"replace":2}}`. The stated shallow contract requires
  `{"value":{"replace":2}}`. master-hook uses jq's recursive `*` operator.
- `exception-lone-deny-without-provenance`: one child returning
  `{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"first"}}`
  is emitted unchanged. The expected `hookEventName` and `hqSessionBlockedBy`
  fields are absent. Multi-result deny and single-result block do stamp them.

Moving the Rust engine and the bash baseline to shallow merge and lone-deny
provenance would be a separate, reviewed behavior change. Until then, the golden
suite preserves current behavior.

## Synthetic corpus and differential scope

The generator derives a versioned corpus from every registry occurrence
(event/group/hook, rather than deduplicating hook IDs) and prefilter. Each rule
has matching/non-matching cases for both Claude and Codex payload shapes. Native
Codex fixtures already use canonical tool_name/tool_input; the corpus follows
the captured tests/fixtures/runtime shapes, using synthetic identifiers.
These are dispatcher inputs, not a test of the Codex host adapter. HQ_HARNESS
stays claude because the Codex adapter otherwise owns registry dispatch.

The corpus records hashes and trigger frontmatter for shipped core policies.
Vocabulary cases install a lexical policy selected from those declarations and
a session ledger, testing run and skip through the production compiler. Regex
witnesses are checked by Bash's case-insensitive POSIX ERE engine. Unknown
prefilters or missing witnesses fail generation. Regenerate with
`node core/scripts/hook-corpus/generate-corpus.mjs`; --check detects drift.

The differential restores the same root before each engine, following hq-cli's
core-utils differential pattern. Registry hook bodies are deterministic sentinel
scripts, with profile gating disabled to isolate entry and prefilter selection.
This verifies dispatcher selection and output, not every hook body's policy
decision or side effect; port stories must add their own body fixtures.
Unconditional entries use an unregistered event for their non-match case.

It compares exit, stdout and stderr without normalizing output. Both engines
must also satisfy expected selection, so identical no-op engines cannot pass.
Mismatches print only hook ID, rule, entry, runtime, payload SHA-256 and mismatch
category. Child output, errors, commands and payload text are never printed.
CLI failures return 2; mismatches return 1; zero mismatches returns 0.
Each invocation has a 30-second deadline and 8 MiB capture limit. Missing
dependencies fail rather than skip. Windows fixture paths use Bash's physical
path for payloads and provenance expectations.
