# create-component

Create a new React component.

## Arguments

`$ARGUMENTS` = `--name <ComponentName>` (required)

Optional:
- `--repo <path>` - Target repository
- `--type <functional|class>` - Component type
- `--with-test` - Include test file

## Process

1. Analyze existing component patterns
2. Generate component file
3. Add TypeScript types
4. Include accessibility attributes
5. Add tests if requested

## Output

- `src/components/{Name}/{Name}.tsx`
- `src/components/{Name}/{Name}.test.tsx` (if --with-test)
- `src/components/{Name}/index.ts` (barrel export)
