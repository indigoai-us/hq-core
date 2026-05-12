---
id: hq-eslint-allow-default-project-for-root-configs
title: Register new root-level config files in typescript-eslint allowDefaultProject
scope: global
trigger: adding a root-level config file (e.g. `vitest.e2e.config.ts`, `playwright.config.ts`) to a TypeScript project with typescript-eslint
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

NEVER trust local `npm run lint` (or equivalent) as the final gate after adding a new root-level TypeScript config file. CI runs fresh with no cache and will fail if typescript-eslint's `projectService` is not configured to accept the new file.

In the SAME PR that introduces the new root-level config, add it to `allowDefaultProject` in `eslint.config.js`, placed next to its existing sibling entries:

```js
// eslint.config.js
{
  languageOptions: {
    parserOptions: {
      projectService: {
        allowDefaultProject: [
          'vitest.config.ts',
          'vitest.e2e.config.ts',  // ← add here, next to its sibling
        ],
      },
    },
  },
}
```

Verify locally by deleting `.eslintcache` before the final lint pass — otherwise the cache can silently mask the failure.

## Rationale

`.eslintcache` stores prior lint results keyed by file hash. A newly added root-level config file (not in `allowDefaultProject`) triggers a typescript-eslint parser error — but if lint has previously succeeded on the rest of the codebase, the cache makes `npm run lint` appear clean locally while CI (which runs fresh, no cache) fails. The cache + projectService interaction is subtle and easy to miss. Adding the new file to `allowDefaultProject` in the same PR eliminates the drift.
