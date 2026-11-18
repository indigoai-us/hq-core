#!/usr/bin/env python3
"""Compare policy bytes and emits for the session-pinned index.

Reads workspace/orchestrator/policy-emit-stats/<session>.txt under --root.
A line has four fields when the index flag is off (ts, event, bytes, policies).
A fifth field is the index emit type: index, delta, mustfire, quiet, cleanup.

Pass --scorecard to also run scorecard_live.py and print its table. That
script chooses its own root; this one only reads --root.
"""
import argparse
import collections
import os
import statistics
import subprocess
import sys


def parse_stats(root):
    stats_dir = os.path.join(root, "workspace", "orchestrator", "policy-emit-stats")
    sessions = {}
    if not os.path.isdir(stats_dir):
        return sessions
    for name in sorted(os.listdir(stats_dir)):
        if not name.endswith(".txt"):
            continue
        sid = name[:-4]
        arm = {"off": {"emits": 0, "bytes": 0}, "on": {"emits": 0, "bytes": 0, "by_type": collections.Counter()}}
        path = os.path.join(stats_dir, name)
        with open(path, errors="replace") as handle:
            for line in handle:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 4:
                    continue
                try:
                    nbytes = int(parts[2])
                except ValueError:
                    continue
                if len(parts) >= 5:
                    kind = parts[4] or "index"
                    if kind == "cleanup":
                        continue
                    arm["on"]["emits"] += 1
                    arm["on"]["bytes"] += nbytes
                    arm["on"]["by_type"][kind] += nbytes
                else:
                    arm["off"]["emits"] += 1
                    arm["off"]["bytes"] += nbytes
        sessions[sid] = arm
    return sessions


def median(values):
    if not values:
        return 0
    return int(statistics.median(values))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--scorecard", default="")
    parser.add_argument("--scorecard-days", type=int, default=7)
    args = parser.parse_args()
    root = os.path.abspath(args.root)

    if args.scorecard:
        if os.path.isfile(args.scorecard):
            print("SCORECARD")
            subprocess.run([sys.executable, args.scorecard, "--days", str(args.scorecard_days)], check=False)
            print()
        else:
            print(f"scorecard missing: {args.scorecard}")

    sessions = parse_stats(root)
    print("session\tarm\temits\tpolicy_bytes\tindex_bytes\tdelta_bytes\tmustfire_bytes\tquiet_bytes")
    on_bytes = []
    off_bytes = []
    for sid, arm in sessions.items():
        if arm["on"]["emits"] and arm["off"]["emits"]:
            label = "mixed"
        elif arm["on"]["emits"]:
            label = "on"
            on_bytes.append(arm["on"]["bytes"])
        elif arm["off"]["emits"]:
            label = "off"
            off_bytes.append(arm["off"]["bytes"])
        else:
            continue
        by_type = arm["on"]["by_type"]
        emits = arm["on"]["emits"] if label != "off" else arm["off"]["emits"]
        policy_bytes = arm["on"]["bytes"] if label != "off" else arm["off"]["bytes"]
        if label == "mixed":
            emits = arm["on"]["emits"] + arm["off"]["emits"]
            policy_bytes = arm["on"]["bytes"] + arm["off"]["bytes"]
        print(
            f"{sid}\t{label}\t{emits}\t{policy_bytes}\t"
            f"{by_type.get('index', 0)}\t{by_type.get('delta', 0)}\t"
            f"{by_type.get('mustfire', 0)}\t{by_type.get('quiet', 0)}"
        )
    print()
    print(
        f"summary\toff_sessions={len(off_bytes)}\ton_sessions={len(on_bytes)}\t"
        f"median_off_bytes={median(off_bytes)}\tmedian_on_bytes={median(on_bytes)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
