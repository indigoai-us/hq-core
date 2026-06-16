# Humanize before send (shared outbound block)

One reusable procedure that every outbound communication surface runs at its
draft to send step, so a human never receives a message that still carries
obvious AI-writing tells. This is the single source of truth referenced by the
outbound skills (`dm`, `work-broadcast`, `social-publisher` / `post`,
`hq-cowork-dm`) and backed by the `enforce-humanize-before-send` Stop hook.

It exists because the `humanize-generated-content` policy (hard) is injected as
SessionStart guidance but has no enforcement at the moment a message actually
leaves the session. This block installs that seam without extracting a heavyweight
shared skill across every caller (see `no-shared-skill-extraction-touching-5-files`):
each skill adds one small reference step, the real pattern catalog stays in the
`/humanize` skill, and the Stop hook is the independent backstop.

## When it runs

At the **draft to send** step of any outbound channel, **before** the message is
shown for approval and **before** it is sent. Never after send.

## What it covers (and what it does not)

Humanize only the **human-readable body** a person will read:

- DM / cowork-dm: the message body, the `--prompt` text, and `--details` text.
- work-broadcast: the one-sentence summary line (the part a human reads).
- social: the post caption / article body.

Never touch the machine surface: recipient handles and emails, personUids,
channel IDs, URLs, scheduling flags (`--at` / `--in` / `scheduled_at`), JSON keys,
account IDs, the `:chart_with_upwards_trend:` work-broadcast signature emoji, or
any secret. Those are not prose and rewriting them breaks delivery.

## Procedure

1. **Resolve preferences** (see Settings resolution below) to get, for this
   channel, an `enabled` flag, an `intensity`, and an optional `voice_pack`.
   If `enabled` is false for the channel, skip the pass entirely.
2. **Load voice** if a `voice_pack` is set: read the pack's `voice-guide.md`
   (resolved via the brand-voice registry, see below) and calibrate to it.
   For the owner's first-person content with no pack set, fall back to
   `personal/agents-profile.md`. For company content, use that company's
   brand-voice pack or brand knowledge.
3. **Run the humanize audit** from the `/humanize` skill
   (`.claude/skills/humanize/SKILL.md`) at the resolved intensity (below).
   The audit step ("what makes this obviously AI generated?") is mandatory even
   when run inline; you may apply only the final result rather than showing the
   full draft to audit to final loop.
4. **Send the humanized body.** For surfaces with a mandatory approval step
   (work-broadcast, social), show the humanized version for approval, not the
   raw draft.

## Channel-aware intensity

Intensity controls how hard the pass leans, so a terse internal DM is not
over-formalized and a public post is fully scrubbed.

| Intensity | Meaning | Default channel |
|-----------|---------|-----------------|
| `off` | Skip the pass. | none |
| `light` | Strip the unambiguous tells only: em and en dashes, AI vocabulary (`delve`, `leverage`, `seamless`, `robust`, `testament`, `underscore`, `showcase`, `pivotal`, `vibrant`, `unlock`, `elevate`, `harness`), collaborative / sycophantic artifacts ("I hope this helps", "Let me know if", "Great question", "Certainly!"), promotional framing, and decorative emoji. Keep the message terse and conversational; do not add length or formality. | `dm`, `cowork-dm`, `work-broadcast` |
| `standard` | `light` plus rule-of-three, negative parallelisms, false ranges, copula avoidance, filler, and generic upbeat conclusions. | global default |
| `full` | The complete `/humanize` pass, including voice calibration and the soul / personality check, ending with no em or en dashes. | `social` |

DMs default to `light` because they are conversational and semi-internal:
the goal is to remove slop, not to make a teammate ping read like marketing copy.
Public social posts default to `full` because the stakes and the audience are
highest.

## Settings resolution

Two optional YAML files, company taking precedence over personal (global):

- Company: `companies/{co}/settings/communication/preferences.yaml`
  (template at `companies/_template/settings/communication/preferences.yaml`).
- Personal / global: `personal/settings/communication-preferences.yaml`.

For each setting (`enabled`, `intensity`, `voice_pack`) on a given channel,
take the first value that is set, in this order:

1. company `channels.<channel>.<key>`
2. company `defaults.<key>`
3. personal `channels.<channel>.<key>`
4. personal `defaults.<key>`
5. built-in default (`enabled: true`, `intensity: standard`, `voice_pack: null`,
   except the per-channel intensity defaults in the table above)

So a company can both raise the floor (force `full` on every channel) and a
person can tune their own defaults, with the company always winning on conflict.
The channel keys are `dm`, `cowork-dm`, `work-broadcast`, and `social`.

When no file exists, the built-in defaults apply and the pass still runs. The
feature degrades to "always humanize at the per-channel default intensity".

## Brand-voice packs

A `voice_pack` id resolves through the brand-voice registry at
`core/knowledge/public/brand-voice/registry.yaml` to a pack directory holding a
`voice-guide.md` and `samples/`. Global packs live at
`core/knowledge/public/brand-voice/packs/{id}/`; company packs at
`companies/{co}/knowledge/brand-voice/packs/{id}/`. The shipped starter is
`hq-plain`. This mirrors the design-styles pack pattern so voice is personalizable
the same way visual style is. See `core/knowledge/public/brand-voice/README.md`.

## Backstop

The `enforce-humanize-before-send` Stop hook
(`.claude/hooks/enforce-humanize-before-send.sh`) is the safety net. It scans the
just-finished turn for an outbound-send action whose body still carries a cluster
of AI-writing tells and, on a hit, blocks once with a corrective directive. The
inline step above is the primary control; the hook only catches a skipped pass.
Prevention is running this block, not relying on the hook.
