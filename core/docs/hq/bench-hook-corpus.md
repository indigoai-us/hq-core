# Hook corpus benchmark

`core/scripts/bench-hook-corpus.sh run` measures the default corpus with its
existing per-event fresh-session behavior. Its report and console format remain
the default benchmark interface.

To measure cache behavior across two passes in one Claude session, choose one
or more prompt IDs from the corpus and run:

```sh
bash core/scripts/bench-hook-corpus.sh replay \
  core/scripts/bench-hook-corpus-default.json \
  workspace/reports/hook-replay.json p1 p2
```

Replay sends one untimed `SessionStart`, then runs the selected prompts in
order twice. All calls use one session ID and the same HQ root as their
workspace. The console and JSON report show first-run and repeat-run context
bytes and wall seconds for each prompt. Normal `run` mode keeps its existing
behavior and output.
