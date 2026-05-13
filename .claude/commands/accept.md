# /accept — Accept a Membership Invite

Accept a vault-backed membership invite using a magic link or raw token.

**Usage:**
```
/accept <token-or-magic-link>
```

## Process

1. **Parse token** — extracts raw token from `hq://accept/<token>` or raw input
2. **Resolve caller** — reads Cognito session from `~/.hq/credentials.json`
3. **Call vault-service** — via `VaultClient.acceptInvite()` from `@indigoai-us/hq-cloud`
4. **Print result** — company details, role, and sync hint

## Implementation

```typescript
import { accept } from "@indigoai-us/hq-cloud";

const result = await accept({
  tokenOrLink: "hq://accept/tok_abc123",
  callerUid: "<caller-person-uid>",
  vaultConfig: { apiUrl, authToken },
});

console.log(`Joined ${result.companySlug} as ${result.membership.role}`);
```

## Output Format

### On success:
```
Invite accepted!

Company: Acme Corp (acme)
UID: cmp_abc123
Role: member

Run `hq sync --company acme` to pull vault contents.
```

### On error:
```
This invite was already accepted.
```
```
Invite not found or expired.
```
```
This invite was for a different person.
```

## Notes

- Accepts both `hq://accept/<token>` magic links and raw tokens
- Caller's Cognito identity is verified against the invite target
- After accepting, run `hq sync --company <slug>` to pull vault contents
