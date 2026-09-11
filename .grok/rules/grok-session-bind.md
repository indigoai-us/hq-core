# hq-core: public
# Grok session company bind (side-effect)

Grok-only. Claude SessionStart can inject a bind nudge; Grok hooks cannot.

On SessionStart the adapter (`hq-grok-hook-adapter.sh`) auto-binds `company_slug` + `scope-capability.json` from a **safe** source only:

1. This session's existing meta / capability
2. `HQ_SPAWN_COMPANY` (conduct / fleet / spawn)
3. Parent session (`HQ_PARENT_SESSION_ID` or payload `parent_session_id`)

It never guesses a tenant from cwd path fragments. If nothing resolves, the mandatory-scope authorizer stays fail-closed (`Session has no company_slug bound`).

`/conduct` must pass `HQ_SPAWN_COMPANY` and `HQ_PARENT_SESSION_ID` into every lane and put the slug in the brief. Operators can still `bash core/scripts/hq-session.sh set company_slug <slug>` before company-path tools.
