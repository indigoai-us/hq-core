# create-demo-account

Create a demo account for testing purposes.

## Arguments

`$ARGUMENTS` = `--platform <shopify|stripe|etc>` (required)

Optional:
- `--name <string>` - Account name
- `--project <name>` - Project context

## Process

1. Identify platform requirements
2. Generate demo credentials
3. Create account via API/UI
4. Store credentials safely
5. Verify account works

## Output

Demo account details stored in:
`projects/{project}/test-env/demo-accounts.json`

## Platforms Supported

- Shopify (development store)
- Stripe (test mode)
- Custom platforms (via config)

## Human-in-the-loop

- Approve account creation
- Confirm platform selection
- Review stored credentials
