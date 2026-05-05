---
id: tauri-plugin-setup-async
title: Use tauri::async_runtime::spawn in Tauri plugin setup
scope: repo
trigger: tauri plugin development
enforcement: soft
public: true
---

## Rule

In Tauri v2 plugin `setup` callbacks, use `tauri::async_runtime::spawn()` instead of `tokio::spawn()`. The setup closure runs before the Tokio runtime is accessible via `tokio::spawn`, causing a panic: "there is no reactor running".

Also requires `withGlobalTauri: true` in `tauri.conf.json` for the JS `window.__TAURI__.event.emit()` bridge to work.

## Rationale

Discovered during tauri-agent-browser integration with {your-app}. The plugin compiled fine but panicked at runtime. Tauri manages its own async runtime wrapper that's available during setup.

## How to apply

When writing Tauri v2 plugins that spawn async tasks during setup, always use `tauri::async_runtime::spawn`. When plugins inject JS that communicates back to Rust via events, verify `withGlobalTauri` is enabled in the host app's config.
