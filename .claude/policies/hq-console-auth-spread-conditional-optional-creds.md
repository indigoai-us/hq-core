---
id: hq-console-auth-spread-conditional-optional-creds
title: Use spread-conditional pattern for optional auth provider fields (hq-console auth.ts)
scope: global
trigger: editing auth.ts or any NextAuth/Auth.js provider config in hq-console that must adapt to presence/absence of credentials (PKCE public clients, optional secrets)
enforcement: soft
public: true
version: 1
created: 2026-04-24
updated: 2026-04-24
source: session-learning
---

## Rule

When a provider config in hq-console's `auth.ts` (or any Auth.js `NextAuthConfig`) must adapt based on whether an optional credential is present — e.g. PKCE public clients that have no `client_secret`, or optional `token_endpoint_auth_method` overrides — use the **spread-conditional pattern** to keep the provider object statically typed:

```typescript
// GOOD — spread-conditional, literal types preserved
providers: [
  {
    id: "cognito",
    name: "Cognito",
    type: "oidc",
    issuer: ISSUER,
    clientId: CLIENT_ID,
    ...(SECRET
      ? { clientSecret: SECRET }
      : { client: { token_endpoint_auth_method: "none" as const } }),
  },
],
```

Do NOT mutate the provider object post-hoc with conditional assignment:

```typescript
// BAD — widens types, defeats Auth.js inference
const provider: any = { id: "cognito", ... };
if (!SECRET) {
  provider.client = { token_endpoint_auth_method: "none" };
}
providers: [provider],
```

### Why the spread-conditional

1. **Preserves literal types.** `"none" as const` keeps the `token_endpoint_auth_method` union-typed (NextAuth's type is a union of literals). Mutation paths force `any` or widen to `string`, breaking inference downstream.
2. **No re-assignment, no temp var.** The provider object is declared once, inline, in the `providers` array literal. Easier to read, easier to diff.
3. **TypeScript narrows correctly.** The ternary branch tells the compiler which field shape is present, so consumers of the provider object (adapters, JWT callbacks) see the right type.

### When to extract a helper

If more than two optional fields need conditional inclusion, extract a small helper that returns the spread payload:

```typescript
function optionalClientAuth(secret: string | undefined) {
  return secret
    ? { clientSecret: secret }
    : { client: { token_endpoint_auth_method: "none" as const } };
}

providers: [{ id: "cognito", ..., ...optionalClientAuth(SECRET) }],
```

## Rationale

hq-console's `auth.ts` needs to support both Cognito clients that send `client_secret` and PKCE public clients (no secret, `token_endpoint_auth_method: "none"`). A mutating approach (`const p: any = {...}; if (!SECRET) p.client = ...`) loses the literal-type on `"none"` and forces `any` to propagate, which breaks NextAuth's callback inference downstream.

The spread-conditional keeps everything inside the array literal, preserves the `as const` narrowing, and makes the control flow obvious in a single glance. Observed during the Cognito PKCE migration session — the mutating pattern had silently widened the provider type and a later edit to the JWT callback failed type-check because of the propagated `any`.

Scope note: authored as global scope with an hq-console-specific trigger because repos/private/hq-console has no .claude/policies/ dir and the sensitive-path gate blocks creating one. The pattern generalizes to any Auth.js provider with optional credential shapes.
