# Session-close capture — signal and entity candidates

Shared by `/handoff`, `/checkpoint`, and `/learn`. When a company has opted in,
these skills leave behind **candidates** for the ontology worker to garden. They
never write canon, and capture never adds a model call of its own: candidates
come from content the calling skill already produced (a handoff summary, a
checkpoint summary, a learned rule).

Spec: `core/knowledge/public/hq-core/ontology-local-spec.md`.

## 1. Resolve the company and the switches

```bash
co="$(bash core/scripts/hq-session.sh get company_slug 2>/dev/null)"
[ -n "$co" ] && [ "$co" != personal ] || exit 0          # no bound company: skip
sig="$(bash core/scripts/knowledge-prefs.sh get "$co" signals_capture)"
ont="$(bash core/scripts/knowledge-prefs.sh get "$co" ontology_capture)"
```

If both are `false`, stop here. Do not create any `_candidates/` directory.

## 2. Pick the audience

- Default: the session user's email only (`hq whoami`, or `git config user.email`).
  A session is private to the person running it.
- Use `company` only when the item is about a company-wide artifact the whole
  company can already read: a merged PR, a file under `companies/{co}/knowledge/`
  or `companies/{co}/policies/`, a company-scoped learned rule.
- Never widen an audience to `company` because it is convenient. If unsure, use
  the session user.

## 3. Write the candidates

For each item, one call:

```bash
bash core/scripts/ontology-candidate.sh write --company "$co" \
  --kind signal --type decision \
  --audience "$aud" --source-ref "handoff:$THREAD_ID" \
  --body "<one-line canonical statement>"
```

- Signal types: `action_item`, `commitment`, `decision`, `risk`, `question`,
  `key_point`, `participant_contribution`, `summary`.
- Entity types: `person`, `project`, `company`, `concept`. The body is the
  entity's name only.
- One line per candidate, stated plainly. No hedging, no session chatter.
- The writer is idempotent and prints `disabled for …` when the matching switch
  is off; both are normal.

Caps per run: `/handoff` 15, `/checkpoint` 10, `/learn` 5 (entities only).
Fail-soft: a writer error is logged and does not block the calling skill.
