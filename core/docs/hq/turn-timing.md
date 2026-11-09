# Local turn timing

Set `HQ_TURN_TIMING=1` in the environment of the host running HQ hooks to record diagnostics. It is off by default: portable clock and file locking costs vary by host. Recording reuses the dispatcher's timeout-wrapper measurements, including the clock improvements in staging PR #1803; it adds no clock reads per child.

Run `hq doctor timing --limit 10` for recent sessions ranked slowest first, or add `--turns` for turns and `--json` for machine-readable output. The compatible CLI is required. Reading does not enable recording.

The ledger stays under `workspace/.turn-timing/`, outside vault sync. It stores event names, hook basenames, timestamps, durations, invocation identifiers, and hashed session/agent identifiers. It does not store prompts, tool arguments, responses, or transcripts, and never sends data to a service. There are at most two 1 MiB generations and a lock file. Each invocation buffers at most 256 rows plus its end row. Files are created with owner-only permissions. Lock contention, crashes, an unavailable Perl runtime, or unwritable storage may drop samples; diagnostics never change hook verdicts.

Model time means prompt submit to the first PreToolUse or Stop boundary, including prompt-hook time. It is not pure model compute time. Compaction is measured from PreCompact completion to PostCompact, or SessionStart with source `compact`. Hosts that omit those boundaries show unknown. Measured time is the union of observed intervals, so overlapping hooks and model latency are not counted twice; user idle time is excluded. The first retained turn includes preceding startup hooks. Retention can remove earlier turns, so turn numbers are relative to retained history.

To stop recording, unset `HQ_TURN_TIMING`. No live host configuration is changed by the readout command.
