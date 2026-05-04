---
id: rename-safety-checklist
title: Rename and Signature Change Safety Checklist
scope: global
trigger: when renaming functions, types, variables, or changing signatures
enforcement: soft
version: 1
created: 2026-03-31
source: brainstorm-session
public: true
---

## Rule

When renaming or changing the signature of any function, type, or variable, search separately for all reference categories — a single grep will miss indirect references:

1. **Direct calls and references** — `functionName(`
2. **Type-level references** — interfaces, generics, type parameters
3. **String literals** — `"functionName"`, template literals, logging
4. **Dynamic imports** — `import()`, `require()`
5. **Re-exports and barrel files** — `export { functionName } from`
6. **Test files and mocks** — `jest.mock`, `vi.mock`, test assertions

After updating all references, run the project's typecheck (`bun check`, `tsc --noEmit`, etc.) to catch anything grep missed.

If your project derives union types from const objects, also check those constants — types flowing through filters can break across many files at once.

## Rationale

Grep is text pattern matching, not AST analysis. It cannot distinguish a function call from a comment, differentiate identically-named imports from different modules, or find dynamic references. Comprehensive multi-pattern search is the only safe approach without a proper rename refactoring tool.
