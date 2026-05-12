---
id: hq-nextjs-env-local-empty-shell-var-precedence
title: Diagnose "missing API key" from a Next.js route by checking for empty-string shell vars that shadow .env.local
scope: global
trigger: A Next.js API route returns a provider auth error (Anthropic "x-api-key header is required", OpenAI "No API key provided", Stripe "No API key provided") despite the key being present in .env.local
enforcement: soft
public: true
version: 2
created: 2026-04-17
updated: 2026-04-29
source: session-learning
---

## Rule

ALWAYS: When a Next.js route throws a provider auth error ("x-api-key header is required", "No API key provided", etc.) despite the key being present in `.env.local`, first check whether the **current shell has the same variable set to an empty string**. Next.js's `.env.local` loader is **non-destructive** — any key already present in `process.env` (including `""`) wins. An `export FOO=""` in the shell rc silently shadows the real value in `.env.local`.

Diagnose:

```bash
# Set-but-empty vs truly unset (both report length 0 from ${#VAR})
[ -v FOO ] && echo "set (may be empty)" || echo "unset"
echo "shell length: ${#FOO}"
# Live process env (macOS)
ps eww -p "$(pgrep -f 'next dev' | head -1)" | tr ' ' '\n' | awk -F= '/^FOO=/ {print length($2)}'
# .env.local length — confirm the real key is there and non-empty
awk -F= '/^FOO=/ {sub(/^FOO=/,""); gsub(/^["'"'"']|["'"'"']$/,""); print length($0)}' .env.local
```

Fix:

```bash
# DROP the var from the child environment (do not overwrite it to a value).
# This lets Next.js's dotenv populate it from .env.local unopposed.
nohup env -u FOO pnpm dev > /tmp/dev.log 2>&1 &

# Verify via a live probe against the failing route — should return 200 with
# real provider output, not the provider's auth-error body.
curl -s -X POST http://localhost:3000/api/your-route -d '{}' | head -c 300
```

Open a fresh shell to make the fix permanent, then investigate which rc file writes the empty export (`grep -R 'FOO=' ~/.zshrc ~/.zprofile ~/.bashrc`) and remove it.

## Rationale

The interview step streamed `{"type":"error","errorText":"x-api-key header is required"}` into the UI error bubble. Initial diagnosis assumed the `.env.local` file was missing the key — it wasn't; the file contained a valid 108-char `sk-ant-` prefixed key. What was actually happening:

1. The parent bash shell had `ANTHROPIC_API_KEY=""` set (set-but-empty, not unset) from some prior rc-file or session artifact.
2. `pnpm dev` inherited that env.
3. Next.js 16.2.1 Turbopack loaded `.env.local` via its standard dotenv pass, but because `process.env.ANTHROPIC_API_KEY` was already present (value: `""`), dotenv's non-destructive merge left it alone.
4. `@ai-sdk/anthropic`'s `createAnthropic({ apiKey: process.env.ANTHROPIC_API_KEY })` passed `""` as the key to `POST /v1/messages`.
5. Anthropic's gateway returned its `x-api-key header is required` body, which the AI SDK forwarded through the stream straight into the UI.

The fix is **not** to re-export the var into the shell (that couples the secret to your shell history / `ps eww`). The right tool is `env -u VAR` at launch time, which deletes the var from the child process's environment so dotenv's non-destructive merge fills it in from the file.

The broader lesson: `process.env` in JavaScript has no way to distinguish `""` from `undefined` without an explicit `in` check. Libraries that do `apiKey: process.env.FOO` will happily treat an empty string as a real value and fail downstream with a remote-side error, not a local config error — which is why this wastes time during live demos.

**References:**

- Next.js env loading order: <https://nextjs.org/docs/app/building-your-application/configuring/environment-variables#environment-variable-load-order>
- Node dotenv source (`override: false` default): <https://github.com/motdotla/dotenv/blob/master/lib/main.js>
- Related HQ policies: `eas-env-not-dotenv.md` (EAS builds don't read `.env.local` at all).
