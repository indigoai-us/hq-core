---
id: hq-pnpm-min-release-age-supply-chain
title: Use pnpm with minimumReleaseAge=1440 — block raw npm/yarn install of fresh packages
scope: global
trigger: before any `npm install <pkg>`, `npm i <pkg>`, `yarn add <pkg>`, `bun install <pkg>`, `bun add <pkg>`, `pnpm install <pkg>`, or `pnpm add <pkg>` invocation; before adding/editing a `.npmrc`, `pnpm-workspace.yaml`, or CI install step
enforcement: hard
public: true
version: 1
created: 2026-05-12
updated: 2026-05-12
source: incident-response
learned_from: npm-supply-chain-leak-2026-05-12
---

## Rule

1. **Use `pnpm` for JavaScript dependency management** wherever practical. npm and yarn do not support release-age gating — they will install a version published five minutes ago, no questions asked.

2. **Configure `minimumReleaseAge: 1440`** (minutes — 24 hours) so newly published package versions cannot be installed until they have aged ≥ 24h. This neutralizes the dominant supply-chain worm pattern (compromised maintainer token → malicious version published → CI/dev machines pull it within minutes).

   Set it in one of:

   - Repo `.npmrc`:
     ```
     minimum-release-age=1440
     ```
   - Workspace root `pnpm-workspace.yaml`:
     ```yaml
     minimumReleaseAge: 1440
     ```
   - Per-invocation: `pnpm add <pkg> --config.minimumReleaseAge=1440`

3. **HARD: raw `npm install <pkg>` / `npm i <pkg>` / `yarn add <pkg>` / `bun install <pkg>` / `bun add <pkg>` is blocked.** These commands cannot honor pnpm's release-age gate and so cannot meet this policy. Switch to `pnpm`.

   *Exception:* `npm install` / `npm ci` with NO positional package argument (lockfile hydration only) is allowed — it installs exactly what is already pinned in the lockfile, no fresh resolution from the registry.

4. **HARD: `pnpm install <pkg>` / `pnpm add <pkg>` is blocked when no `minimum-release-age` / `minimumReleaseAge` is configured** in a `.npmrc` walking up from CWD, `pnpm-workspace.yaml` at the repo root, the env var `npm_config_minimum_release_age`, or the command itself via `--config.minimumReleaseAge=...`.

5. **CI must inherit the same gate.** Any `.github/workflows/*.yml`, `vercel.json`, or other CI install step that runs `pnpm install` MUST either commit `.npmrc` with `minimum-release-age=1440` or pass `--config.minimumReleaseAge=1440` on the command. CI without this gate is the easiest path for a compromised package to reach production.

6. **Emergency bypass:** `HQ_ALLOW_UNSAFE_INSTALL=1 <command>` for a single invocation. Audit row appended to `workspace/learnings/unsafe-install-bypasses.jsonl`. Use only when (a) you have read the package's release notes, (b) you trust the maintainer, and (c) the package version is ≥ 24h old by independent verification.

## Rationale

Modern npm supply-chain attacks (Shai-Hulud-class worms, the chalk/debug 2025 incident, the 2026-05-12 leak that prompted this policy) all share one timing window: malicious version → published → installed by CI/devs within minutes → credentials exfiltrated → next maintainer's token compromised → next package poisoned. The window between "malicious version is live on npm" and "the maintainer or npm security team yanks it" is usually < 24 hours. A 1440-minute (24h) release-age gate makes that window unreachable.

npm and yarn do not implement this gate. pnpm does (`minimumReleaseAge` introduced in pnpm 10.x, see pnpm settings reference). Therefore the policy is *both* "use pnpm" *and* "configure the gate" — neither alone is enough.

Hard enforcement because:
- The cost of a false-positive block (developer adds a package and gets told to use `pnpm`) is < 60 seconds.
- The cost of a true-positive miss (a compromised package version reaches a dev machine with shell access to AWS / Cognito / git credentials) is hours-to-days of incident response and credential rotation, plus possible downstream blast radius.

Soft enforcement does not justify those odds.

## Examples

**Correct:**
- `pnpm add chalk` in a repo with `.npmrc` containing `minimum-release-age=1440`
- `pnpm install` (lockfile hydration) — uses the version already pinned, no fresh resolution
- `npm ci` — strict lockfile install, no fresh resolution
- `pnpm add lodash --config.minimumReleaseAge=1440` (per-invocation override when no `.npmrc` is present)

**Incorrect (blocked):**
- `npm install left-pad` — npm does not support the gate, switch to pnpm
- `yarn add react-router` — same
- `bun add tailwindcss` — same
- `pnpm add some-pkg` in a repo without `.npmrc` / `pnpm-workspace.yaml` config and without `--config.minimumReleaseAge=...`

## Enforcement

- **PreToolUse hook:** `.claude/hooks/block-unsafe-package-install.sh` — exit 2 + stderr explanation. Wired in `.claude/settings.json` hooks → PreToolUse → Bash.
- **Soft advisory companion:** `.claude/hooks/inject-policy-on-trigger.sh` — surfaces this policy slug as a `<policy-reminder>` block on first match per session.
- **Bypass audit:** every `HQ_ALLOW_UNSAFE_INSTALL=1` use appends to `workspace/learnings/unsafe-install-bypasses.jsonl` (timestamp, cwd, command).

## References

- pnpm `minimumReleaseAge` setting: https://pnpm.io/settings#minimumreleaseage
- Related internal HQ policies cover per-repo package-manager pins and Vercel pnpm version pinning.
- 2026-05-12 incident reference: workspace/learnings (incident notes), captured this policy
