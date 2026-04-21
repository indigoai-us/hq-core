# scaffold-component

Scaffold a new component with test stubs using Gemini CLI.

## Arguments

`$ARGUMENTS` = `--name <ComponentName>` (required) `--type <react|api|service>` (required)

Optional:
- `--cwd <path>` - Target directory
- `--with-tests` - Include test file (default: true)
- `--with-storybook` - Include Storybook story

## Process

1. **Detect Component Type**
   - `react`: React component with props interface, styles, and test
   - `api`: API route handler with request/response types and test
   - `service`: Service class with interface and test

2. **Analyze Existing Patterns**
   - Read nearby components of same type
   - Extract naming conventions, file structure, import patterns
   - Identify shared utilities and hooks to reuse

3. **Generate via Gemini CLI**
   ```bash
   cd {cwd} && npx @google/gemini-cli --full-auto \
     "Scaffold a {type} component named {name}. Follow the patterns from: {existing_patterns}. Include TypeScript types, exports, and test stubs." 2>&1
   ```

4. **Run Back-Pressure**
   - TypeScript compilation
   - Lint check
   - Test execution (stubs should pass)

## Output

- Component file(s) created
- Test file with stub tests
- Story file (if --with-storybook)
