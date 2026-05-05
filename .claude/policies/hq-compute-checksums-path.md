---
id: hq-compute-checksums-path
title: "HQ compute-checksums.sh is at template/scripts/"
scope: repo
trigger: "fixing governance check failures on HQ PRs"
enforcement: soft
public: true
---

## Rule

The checksum script for HQ Core Governance is at `template/scripts/compute-checksums.sh` (not `scripts/compute-checksums.sh`). Requires `yq` (`brew install yq`). Run from the HQ repo root after modifying locked kernel files. Updates `template/core.yaml` checksums.

The Core Governance CI check **always fails** when locked files are modified — even with valid checksums. This is by design: checksums prove acknowledgment, but maintainer approval is still required to merge.

## Rationale

The script location and yq dependency caused failed attempts during a checksum fix session. The two-layer governance model (checksums + forced failure) is non-obvious.
