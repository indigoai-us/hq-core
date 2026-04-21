---
id: hq-swarm-rust-hub-files
title: Serialize swarm stories that touch Rust hub files
scope: command
trigger: /run-project --swarm with Tauri/Rust projects, /plan for Tauri projects
enforcement: soft
version: 1
created: 2026-03-26
updated: 2026-03-26
source: success-pattern
---

## Rule

Rust projects have "hub files" that nearly every feature story modifies: `Cargo.toml`, `src/lib.rs`, `src/commands/mod.rs`. When running swarm mode on Tauri/Rust projects:

1. **PRD authoring**: Declare hub files (`src-tauri/Cargo.toml`, `src-tauri/src/lib.rs`, `src-tauri/src/commands/mod.rs`) in every story's `files[]` array. This prevents the orchestrator from scheduling them concurrently.

2. **If conflicts occur**: The resolution is always additive — combine both sides. Each story adds different dependencies to `Cargo.toml`, different `pub mod` declarations to `mod.rs`, and different `use` imports + `generate_handler!` entries to `lib.rs`. Never discard either side.

3. **Post-merge verification**: After resolving hub file conflicts, always run `cargo check` before committing. Missing module declarations cause cascading compile errors.

4. **Orchestrator improvement opportunity**: Detect module registration files (mod.rs, lib.rs, Cargo.toml) as shared resources and serialize stories that touch them, even if not declared in `files[]`.

