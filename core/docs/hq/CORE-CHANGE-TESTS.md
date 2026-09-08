# Core change tests

What has to pass before an hq-core change ships, and where each check lives.

## 1. Unit and contract suites (CI, every PR)

`.github/workflows/pr-checks.yml` runs every `core/scripts/tests/*.test.sh` it names. A new
hook, script, or skill command is not done until it has a suite there. Key suites for the
harness: `inject-policy-output-ceiling`, `inject-policy-on-trigger-emit`, `mandatory-scope-authorizer`,
`detect-secrets-*`, `harness-settings-dispatch` (every settings.json matcher is exercised through
the Codex and Grok adapters or declared an exception), `provider-adapter-codex` / `-grok`,
`test-codex-hook-adapter`, `policy-retire`, `policy-benchmark`.

## 2. Live runtime smoke (releaser's machine, before cutting a release)

```bash
bash core/scripts/tests/harness-live-smoke.sh            # claude, codex, grok — whichever are installed
bash core/scripts/tests/harness-live-smoke.sh --require  # fail if a runtime is missing
```

One real headless turn per runtime against this tree. Proves the hooks fired (trigger ledger),
every policy reminder stayed under the host ceiling (`workspace/orchestrator/policy-emit-stats`),
and, for Claude, that the host persisted/truncated nothing. Costs one short model turn per runtime.

## 3. Fleet canary (agents-v2 boxes)

Fleet boxes run the same `.claude` hooks through the on-box adapter, only during a live turn.
`harness-live-smoke.sh --fleet` prints the drill: deploy to a canary, drive one turn, then
`check-hq-hooks.sh --require-ledger --session-id <sid>` must read OBSERVED and the emit stats
must stay under 8,000 bytes. The attestation logic itself is covered offline by
`hook-health-check.test.sh` cases [18] and [19].

## 4. Delivery benchmark (trend, not gate)

`core/scripts/policy-benchmark.sh live --days 7` on the releaser's machine: truncated hook
outputs should trend to zero and the retrieval rate should rise after a rules-layer change.
