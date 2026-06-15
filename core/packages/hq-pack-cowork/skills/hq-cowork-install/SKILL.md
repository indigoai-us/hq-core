---
name: hq-cowork-install
description: Build and install the HQ Cowork plugin artifact and smoke-test it.
allowed-tools: Bash
---

# /hq-cowork-install — Install the Cowork plugin

This is the HQ-native setup helper for Cowork.

Run:

```bash
core/packages/hq-pack-cowork/scripts/install-cowork-plugin.sh --install
```

It checks host prerequisites, registers the local `hq` Claude marketplace,
installs/enables `hq-cowork@hq`, and builds:

```text
~/Downloads/hq-pack-cowork.plugin
```

and prints the exact Cowork upload and smoke-test steps.

If the user only wants the upload artifact without touching Claude's plugin
registry, omit `--install`.

Optional output path:

```bash
core/packages/hq-pack-cowork/scripts/install-cowork-plugin.sh --install --out /tmp/hq-pack-cowork.plugin
```

After upload, Cowork should be able to use the same HQ behaviors as default
HQ sessions through the plugin's host-side MCP transport.
