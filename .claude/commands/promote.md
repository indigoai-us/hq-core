# /promote — Change a Member's Role

Change an existing member's role on a company. Admin+ only.

**Usage:**
```
/promote <person-slug-or-uid> <owner|admin|member|guest> [--paths <docs/,shared/>] [--company <slug>]
```

## Process

1. **Resolve auth** — read Cognito session from `~/.hq/credentials.json`
2. **Resolve company** — from `--company` flag, or active company via `.hq/config.json`
3. **Validate args** — `--paths` is only valid with guest role
4. **Call vault-service** — via `VaultClient.updateRole()` from `@indigoai-us/hq-cloud`
5. **Print result** — updated role and any scope changes

## Implementation

```typescript
import { promote } from "@indigoai-us/hq-cloud";

const result = await promote({
  target: "psn_alice",
  newRole: "guest",
  paths: "docs/",
  company: "acme",
  callerUid: "<caller-person-uid>",
  vaultConfig: { apiUrl, authToken },
});

console.log(`Role updated to ${result.membership.role}`);
```

## Output Format

### On success:
```
Role updated for psn_alice on acme:
  member → guest
  Allowed paths: docs/

Next STS vend will reflect scoped credentials.
```

### On error:
```
Permission denied — only admins and owners can change member roles.
```
```
Cannot leave company without an owner — promote another member to owner first.
```
```
Member "psn_alice" not found in this company.
```

## Roles

| Role | Permissions |
|------|-------------|
| `owner` | Full control + delete entity |
| `admin` | Manage members + read/write all |
| `member` | Read/write unrestricted paths |
| `guest` | Scoped to `--paths` prefixes only |

## Notes

- Admin+ only — members and guests cannot promote
- Demoting the last owner is blocked (company must always have at least one owner)
- `--paths` sets `allowedPrefixes` — only meaningful for guest role
- Role changes take effect on the member's next STS vend
