---
id: hq-cli-version-read-from-package-json
title: Read CLI version from package.json at runtime, never hardcode
scope: global
trigger: Building or publishing a CLI package to npm that exposes `--version` / `-v`
enforcement: soft
public: true
version: 1
created: 2026-04-23
updated: 2026-04-23
source: session-learning
---

## Rule

ALWAYS: When publishing a CLI to npm, read the version from `package.json` at runtime — never hardcode a version string in source.

Acceptable shapes (pick one):

```js
// Node/CommonJS
const { version } = require('./package.json');
program.version(version);
```

```js
// ESM — via import attributes (Node 22+) or a tiny helper
import pkg from './package.json' with { type: 'json' };
program.version(pkg.version);
```

```js
// Commander auto-version — reads package.json itself
import { Command } from 'commander';
const program = new Command();
// commander discovers the nearest package.json automatically
```

NEVER: Bake the version into a `const VERSION = '5.5.2'`, a build-time constant, a templated banner string, or a `printf`/`console.log` literal. Any place you write the version in source is a drift vector — the next `npm version patch` bumps `package.json` but leaves every hardcoded string stale.

If a bundler compiles `package.json` imports away (esbuild/tsup with JSON loader), verify the bundle still carries the resolved version field at runtime (e.g. `hq --version` on the installed package) as part of the publish checklist.

## Rationale

Observed 2026-04-22/23 on the `hq-core-split` release: `hq --version` printed `5.5.0` for users who had just `npm install -g hq-cli@5.5.2`, because the build's `VERSION` constant was never bumped. The npm registry was correct, `package.json` was correct, but the shipped binary lied — so users couldn't tell which version they actually had installed, and the split migration appeared to have failed. Reading from `package.json` at runtime makes the registry the single source of truth: whichever tarball is installed dictates what `--version` prints. Drift becomes impossible by construction.
