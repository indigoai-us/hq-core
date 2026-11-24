---
id: hq-multiple-named-super-conductors
title: Run several named super-conductors, each with its own scope
scope: global
when: super-conductor || superconductor || conduct-all || (conductor && (adopt || sweep || heartbeat || scope || route || forward))
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
public: true
status: active
version: 1
created: 2026-11-19
updated: 2026-11-19
source: owner-directive
---

## Rule

1. Every `/super-conductor` run is one named conductor with a profile at `personal/settings/super-conductors/<name>.yaml`, read and written only through `core/scripts/super-conductor-registry.mjs`. Names are unique.
2. Startup reuses a saved conductor by name, or sets up a new one through the skill's questionnaire (scope, when it may start sessions, which running sessions it adopts, cadence, channels and stats, decision desk or its own window, where child sessions ask, areas it must not watch, then a name). Each question is one card or one picker.
3. Each conductor has its own conduct link, heartbeat (its monitor description names the conductor), save file, decision queue, request ledger, overnight log, message-watch state and rendered prefs file. Two conductors never share any of them, and never share a cursor.
4. Two conductors may share a company when their scopes do not overlap.
5. A session is adopted by at most one conductor, recorded with `super-conductor-registry.mjs claim`. Only the holder messages, sweeps, nudges, archives or reports on it.
6. An inbound item goes to the conductor whose scope matches, found with `super-conductor-registry.mjs route --from <name>`. A conductor that sees an item outside its scope forwards it once to the owning conductor's session, starting `FORWARDED from <name>:`, and does not act on it. When the owner is in the asker's `scope.no_forward_to`, the asker leaves the item alone, because that peer sweeps its own channels.
7. A conductor never stops, re-arms or edits another conductor's heartbeat, link, profile, queue or save file.
8. A preference the owner states for one conductor goes to that conductor's profile; only a preference for every conductor goes to the shared base file `personal/settings/super-conductor.yaml`.

## Rationale

Scoped conductors with one owner per session and per item avoid duplicate watching and hand relays between conductors.
