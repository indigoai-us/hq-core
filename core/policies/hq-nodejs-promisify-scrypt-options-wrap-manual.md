---
id: hq-nodejs-promisify-scrypt-options-wrap-manual
title: Do not use promisify(scrypt) with a 4-arg options call — wrap crypto.scrypt manually
scope: global
trigger: Writing Node.js / TypeScript code that hashes passwords with `crypto.scrypt` and an options object (N, r, p, maxmem)
enforcement: soft
public: true
version: 1
created: 2026-04-23
updated: 2026-04-23
source: session-learning
---

## Rule

NEVER: Call `promisify(scrypt)(password, salt, keylen, options)` in TypeScript. The `util.promisify` type inference only sees the 3-arg overload `scrypt(password, salt, keylen, callback)`, so passing an options object compiles to a miswired call or a type error depending on strictness.

ALWAYS: Wrap `crypto.scrypt` manually in a `Promise` that closes over the options object:

```ts
import { scrypt, randomBytes } from "node:crypto";

function scryptAsync(password: string, salt: Buffer, keylen: number, options: ScryptOptions): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scrypt(password, salt, keylen, options, (err, derivedKey) => {
      if (err) reject(err);
      else resolve(derivedKey);
    });
  });
}
```

## Rationale

`util.promisify` picks a single overload at type-inference time. For `crypto.scrypt`, it resolves to the 3-arg signature, which silently drops the `options` parameter (or fails typecheck under stricter configs). Manual Promise wrapping lets the closure capture the options object, preserves the intended scrypt parameters, and keeps the call typesafe. Encountered during a password-reset implementation.
