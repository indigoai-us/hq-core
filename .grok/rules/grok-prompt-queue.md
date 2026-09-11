# hq-core: public
# Grok prompt queue (single-flight)

Grok-only. Do not mirror into Claude hooks.

Grok allows one running turn per session. A second prompt into the same
session fails with `shell.prompt.start_blocked` / `task_already_running`
(or `turn_running`).

Do **not** double-submit the same session (scheduler, `/conduct` lane, or
follow-up) while a turn is in flight. Wait for Stop, or use a new session /
detached worker. This is upstream queue behavior, not an HQ deny you can
retry around.
