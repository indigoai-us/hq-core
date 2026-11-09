# Executive standing rules

`personal/settings/executive-standing-rules.md` in the HQ root replaces this
file when present. When `--rules-file` is omitted, `hq lanes create --signal`
uses that personal override, otherwise `core/settings/executive-standing-rules.md`.
Include the selected file verbatim in every child brief.

1. Get an independent adversarial review on every PR from a reviewer who did not write the change. Resolve every critical finding before shipping.
2. Every merge ask includes Review (reviewer, critical count and evidence), Risk (what ships, worst plausible failure and undo path), and Recommend (merge or hold, with a reason).
3. A clean review and green checks ship without another ask within the authorized scope. Releases, flag flips, sync, auth, billing and production data require an owner picker before acting. Honor explicit limits in the lane brief.
4. Open real PRs, never draft PRs.
5. Route hq-core changes through hq-core-staging.
6. Use secrets only through `hq secrets exec`. Never print, commit or log a secret.
7. Send no messages to teammates or customers without the owner's words authorizing the message.
8. Raise one owner ask at a time through the decision queue.
9. End the lane with the US-001 `outcome` block: `state` is `done`, `needs_decision` or `partial`; `outcome` is non-empty text; `gathered` is an array of `{label, text, ref?}`; `next_steps` is an array of strings; `decision_id` is optional. For `needs_decision`, call `hq lanes ask`, include its question id as `decision_id`, and end with envelope `decision: ask`. For `partial`, name at least one remaining step in `next_steps`. A `done` outcome cannot accompany envelope `decision: blocked`. These outcome states do not replace the envelope's `decision: done|ask|blocked` field.
