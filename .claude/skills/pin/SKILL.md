---
name: pin
description: Anchor this session to one goal — the message, target, or outcome it keeps working toward across loops, wakeups, compactions, and hand-offs — and check progress against it.
allowed-tools: Bash(bash core/scripts/hq-pin.sh:*), Bash(core/scripts/hq-pin.sh:*), Read
---

# /pin — the goal this session is anchored to

A pin is the one thing the session is for. Once set, every status tick, wakeup,
and post-compaction resume starts by re-reading it, and the session does not
stop until the pin's done criteria are met or the owner clears it.

Script: `core/scripts/hq-pin.sh` (set · show · check · note · done · clear).

## Usage

```
/pin <goal>                     set the pin (goal text; add done criteria in the same call)
/pin                            show the current pin
/pin done <criterion text>      mark one done-criterion met
/pin note <progress>            append a dated progress line
/pin clear                      remove the pin
```

## Set

```bash
bash core/scripts/hq-pin.sh set "Ship agents v3 for every company and retire the old runtime" \
  --done "every production agent runs the current runtime" \
  --done "old-runtime boxes are deprovisioned" \
  --done "live smoke passes and a standing monitor watches it" \
  --owner "the owner" --channel "project-launch"
```

Write the goal as an outcome, and write each done criterion so a reader can
check it without asking anyone. A pin with no done criteria is a slogan; add at
least one.

## Behaviour while pinned

- **At every wake** (a loop tick, a background task returning, a resume after
  compaction), run `bash core/scripts/hq-pin.sh check` first. Its one line is
  the frame for the tick: what is being worked toward and how many criteria
  are still open.
- **Requests that arrive mid-session** (chat, a bound DM channel, a task
  notification) are handled in service of the pin. A request outside the pin is
  done if it is small, or queued with a note under the pin if it is not; it never
  replaces the pin silently. Only the owner changes or clears a pin.
- **Progress is written down**, not remembered: `note` after each milestone,
  `done` when a criterion is met. Checkpoints and hand-offs copy the pin file
  verbatim so the next session inherits it.
- **Stopping**: the session ends its work only when `check` reports zero open
  criteria, or the owner says stop. "Nothing to do right now" means wait for
  the next signal, not finish.

## Show and check

```bash
bash core/scripts/hq-pin.sh show    # full pin: goal, owner, channel, criteria, progress
bash core/scripts/hq-pin.sh check   # one line for loop ticks; exit 3 when there is no pin
```

## Notes

- Storage is per session: `workspace/sessions/<sid>/pin.md`, plus `pin:` in the
  session's `meta.yaml` so other tooling can read the goal.
- Pairs with `/dm-bind`: bind the channel the owner reads, then post progress
  there in the same shape used for any status update.
