---
id: hq-eas-expo
title: EAS/Expo platform rules (consolidated)
scope: global
trigger: when working with Expo/EAS builds, submits, or runtime
enforcement: soft
version: 1
created: 2026-04-29
updated: 2026-04-29
applies_to: [expo]
public: true
tags: [vendor:expo, consolidated]
source: consolidation-merge
---

## Rule

Consolidated rules for working with Expo apps and EAS (Expo Application Services) builds, submits, and runtime behavior. Covers submission semantics, transient error recovery, dev client recovery, and Expo SDK pitfalls.

## Submit

### Never re-run `eas submit` to check submission status
[from eas-submit-no-status-query.md]

`eas submit` has no read-only or status-query mode. Running `eas submit --platform ios --profile {profile} --id {build-id}` a SECOND time DOES NOT query the prior submission's status — it triggers a NEW upload to App Store Connect. Apple rejects the duplicate (same build number already exists), but the attempt still burns cycles and clutters the submission history with a failed row.

**To check submission status:** read the submission dashboard URL returned by the first call (`https://expo.dev/accounts/{user}/projects/{project}/submissions/{submission-id}`), or trust the first call's output if it explicitly said "✔ Submitted your app to Apple App Store Connect! Your binary has been successfully uploaded". Apple's processing is asynchronous and sends an email when done — that email IS the status notification, not a CLI query.

**Also note:** `eas submission:list` does NOT exist as of eas-cli 18.6. Don't waste time trying it.

**Rationale:** A second `eas submit` attempt was launched "to query status" and immediately started a fresh upload, which Apple rejected as a duplicate (build 38 already existed). The first submit had already succeeded — there was no useful information in the second call.

### Retry `eas submit` with `--id` after transient Apple ASC errors (don't rebuild)
[from hq-eas-submit-retry-transient-asc-error.md]

When `eas submit` fails with a transient Apple App Store Connect error — e.g. `502 Bad Gateway` from `altool`, network timeout, or other infrastructure-side flake — retry just the submit step using the existing build:

```bash
eas submit --platform ios --profile production --id <build-id>
```

The previously produced IPA is reusable. Do NOT rebuild via `eas build` — that wastes ~15 min of build time and bumps the build number unnecessarily.

How to identify the build id: the original `eas build` output prints it, or run `eas build:list --platform ios --limit 5` to find the most recent finished build.

**Rationale:** `eas build` and `eas submit` are independent stages. The IPA produced by `build` lives in EAS storage and stays valid until a new build supersedes it; `submit` is a thin wrapper that just uploads that artifact to ASC. When ASC returns a transient 5xx, the artifact is unaffected — only the upload failed. Re-running just the submit step costs seconds, not minutes, and uses the same artifact (preserving build number continuity).

This is distinct from the rule above (which warns against re-running `eas submit` to *query* a prior submission's status). That rule applies when the prior submit succeeded; this one applies when it failed transiently.

## Runtime / Dev Client

### Recover Expo dev client "No script URL provided" by writing Metro host to NSUserDefaults
[from hq-expo-dev-client-metro-host-nsuserdefaults.md]

When an Expo dev client on iOS simulator crashes with `No script URL provided` after Metro is restarted, the dev client has cached a stale Metro host that no longer responds. The Reload menu and `simctl openurl` deep-link tricks do NOT update this cached host — only `NSUserDefaults` writes do.

Fix:

```bash
BUNDLE_ID=<app-bundle-id>
PORT=<metro-port>

xcrun simctl spawn booted defaults write "$BUNDLE_ID" RCT_jsLocation "localhost:$PORT"
xcrun simctl spawn booted defaults write "$BUNDLE_ID" RCTDevMenu_DEFAULTS_PACKAGER_HOST "localhost:$PORT"
xcrun simctl spawn booted defaults write "$BUNDLE_ID" EXDevSettingsHost "localhost:$PORT"

xcrun simctl terminate booted "$BUNDLE_ID"
xcrun simctl launch booted "$BUNDLE_ID"
```

All three keys must be set — React Native, RCTDevMenu, and Expo each read from a different default. Then terminate + relaunch the app (Reload alone does not re-read the defaults).

**Rationale:** The dev client reads its Metro host from three separate NSUserDefaults keys at app launch. When Metro restarts on a different port (or after a port collision pivot), the in-memory host is still pointing at the old endpoint. The Reload action only re-fetches the bundle from the cached URL, so it propagates the same stale host. `simctl openurl exp+myapp://...` deep links are intercepted before the dev settings layer reads them. Only writing the defaults BEFORE relaunch causes the dev client to read the new host on next startup.

## Expo SDK

### expo-secure-store key names must not contain colons
[from expo-securestore-keys.md]

`expo-secure-store` only allows keys matching `/^[\w.-]+$/` — letters, digits, underscores, dots, hyphens. **Colons are NOT allowed.** Use dots as namespace separators (e.g. `{company}.auth` not `{company}:auth`).

The error message "Invalid key" appears as an unhandled promise rejection that's easy to miss — it shows briefly in the dev error banner then disappears.

**Rationale:** Caused a production bug where tapping a name in a field app did nothing. `SecureStore.setItemAsync('{slug}:auth', '1')` threw silently, preventing navigation. Fixed by changing all keys from colons to dots.

**How to apply:** When creating SecureStore keys in any Expo app, always use dots or underscores as separators, never colons.
