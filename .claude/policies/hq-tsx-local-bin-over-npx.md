---
id: hq-tsx-local-bin-over-npx
title: Prefer ./node_modules/.bin/tsx over npx tsx for one-off scripts
scope: global
trigger: running a one-off TypeScript script via tsx in a Node project
enforcement: soft
public: true
version: 1
created: 2026-04-18
updated: 2026-04-18
source: session-learning
---

## Rule

For tsx-driven one-off scripts (e.g. `scripts/inspect-*.ts`, `scripts/backfill-*.ts`), ALWAYS prefer:

```bash
./node_modules/.bin/tsx path/to/script.ts
```

over:

```bash
npx tsx path/to/script.ts
```

Under some npm versions (particularly when `npm_config_script_shell` or certain global configs are set), `npx tsx` resolves through `npm run tsx` rather than executing the binary directly. If the project does not declare a `tsx` script in `package.json`, this fails with:

```
npm error Missing script: "tsx"
```

…even though `tsx` is installed as a devDependency and the binary is present in `node_modules/.bin/`. Using `./node_modules/.bin/tsx` bypasses npm script resolution entirely and always invokes the binary.

If a project already exposes a wrapper (e.g. `npm run script -- args`), that is also acceptable. The thing to avoid is bare `npx tsx` in HQ scripts, runbooks, and ad-hoc shell invocations.

## Rationale

Switching to `./node_modules/.bin/tsx ...` ran cleanly. The failure is environment-dependent (npm version, config), so it is not reproducible everywhere — but `./node_modules/.bin/tsx` is strictly more reliable and carries no downside.
