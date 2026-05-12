---
id: hq-rust-string-byte-slice-char-boundary-panic
title: Never byte-slice potentially non-ASCII Rust strings
scope: global
trigger: Truncating, capping, or windowing a `&str` / `String` in Rust where input may contain non-ASCII characters (HTTP error bodies, Claude transcript content, log messages, user-supplied text)
enforcement: hard
public: true
version: 1
created: 2026-04-25
updated: 2026-04-25
source: session-learning
---

## Rule

NEVER write `&s[..n]`, `&s[start..end]`, `s.get(..n)`, or any byte-indexed slice on a Rust string where `n` is not known to land on a UTF-8 char boundary. Any byte index that falls inside a multi-byte sequence (em-dash `—` = 3 bytes, box-drawing chars, smart quotes, star/bullet glyphs, emoji) panics with `byte index N is not a char boundary`.

For length-bounded truncation always iterate over `chars()` and break at the desired char count:

```rust
fn truncate_chars(s: &str, max_chars: usize) -> String {
    s.chars().take(max_chars).collect()
}
```

Pre-existing helpers using `&s[..n]` (commonly named `truncate_str`, `cap`, `head`, `preview`) are latent bugs — fix the helper in place rather than introducing a parallel safe version (see `hq-rust-helper-extension-audit-call-sites`).

Common offender categories:
1. HTTP error response truncation (`&body[..200]`)
2. Claude transcript / LLM output preview slicing
3. Log message truncation before emit
4. Filesystem path display capping

## Rationale

Rust's `&str` indexing is byte-based, but `&str` is a guarantee of valid UTF-8 — so any byte index not on a char boundary triggers a panic. The check is debug-and-release; there is no graceful fallback. Code that runs cleanly against ASCII fixtures explodes the first time real-world content (Unicode dashes, smart quotes from copy-pasted text, emoji in commit messages, box-drawing in CLI output) flows through.

`chars()` iteration is O(n) over byte length but bounded by the truncation cap, which is exactly what callers want. The performance difference vs byte slicing is negligible at typical truncation sizes (200-2000 chars) and dwarfed by surrounding I/O.
