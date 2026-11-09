# project-summary components

Every class below is defined in `default.css`. Markup carries classes only; colors and fonts come from tokens, so a company pack re-skins the page by overriding `:root`.

## Reading order of a page

1. `.hero`: kicker, `h1` headline with one `<em>`, `.lead` standfirst, `.hero-strip` of `.pill` facts, `.kpis` band.
2. Numbered sections: `.sec-head` with `.secnum` + `h2`, then a `.sub` line.
3. One `.callout` per page for the decision or recommendation.
4. Visual blocks, then `details` for the long tail.
5. `.foot`.

## Blocks and when to use them

| Block | Use for | Notes |
|---|---|---|
| `.kpis > .kpi (.v .l)` | 3 or 4 numbers the source states | `.v.pass/.warn/.err/.plain` recolor; never a derived guess |
| `.pill` | short facts in the hero | `.pass/.warn/.err` for status |
| `.callout (.warn/.pass/.err)` | the one decision, risk, or recommendation | `h3` + `.big` + one or two `p`; max one per page |
| `.note` | a caveat the reader must not miss (estimates, pending counsel) | icon in `.ic` |
| `.board > .phase` | the plan as a storyboard strip | `.now` for the current phase, `.done` for finished; stories inside `details > ul.stories` |
| `.cards > .card` | use cases, decisions, options, outputs | `.icon` stroke SVG, `h3`, one `p`; `.rec` for the recommended option; `.corner .tag` for a badge |
| `.group-kicker (.pass/.warn/.err)` | a colored heading that groups cards | color must mean something (category), not decoration |
| `.chips > .chip` | field lists, tags, inventories | `.derived` green, `.cond` dashed amber (conditional), `.no` red strikethrough (excluded) |
| `.bars > .bar` | coverage, share, counts, cost ranges | `.fill` width via `style="--w:65%"`; `.track.stack` for stacked segments; add `.axis` and `.legend` when values need scale |
| `.diagram > svg` | flow, architecture, overlap map | classes `.s-box .s-box-acc .s-box-pass .s-box-faint .s-line .s-line-acc`; text classes `.t-h .t-m .t-k .t-a .t-p .t-w`; ship `.flow-h` and a stacked `.flow-v` |
| `.mock` | screen wireframes | always followed by `.concept-note` |
| `table` | exact figures with units | right-align numbers with `td.num`; 8 rows max visible, rest behind `details` |
| `.cols2 / .cols3 > .panel` | side-by-side comparisons (success vs non-goals, they vs us) | `.panel.accent/.pass/.err` |
| `ul.checks` / `ul.tasks` | short bullets / next steps with `.who` owner | |
| `details > summary + .body` | everything the first screen does not need | summary is 2 to 5 words; `details.more` under a block |
| `[data-tip="…"]` | a hover definition on a term or number | 1 sentence; also shows on keyboard focus (`tabindex="0"`) |
| `.tag / .badge / .size` | small labels (`new`, `P1`, `STRONG`, `M`) | color variants `.pass .warn .err .accent` |

## Icons

Use 24×24 stroke icons inside `.card .icon`. Write them inline; keep stroke width 1.6 and round caps. A small set that covers most summaries:

```html
<!-- bell (alert) --> <svg viewBox="0 0 24 24"><path d="M6 10a6 6 0 0 1 12 0v4l2 3H4l2-3v-4z"/><path d="M10 20a2 2 0 0 0 4 0"/></svg>
<!-- chart (bars) --> <svg viewBox="0 0 24 24"><path d="M4 20h16"/><path d="M7 16v-5M12 16V6M17 16v-8"/></svg>
<!-- trend --> <svg viewBox="0 0 24 24"><path d="M3 17l6-6 4 4 8-8"/><path d="M15 7h6v6"/></svg>
<!-- target --> <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1"/></svg>
<!-- users --> <svg viewBox="0 0 24 24"><circle cx="9" cy="8" r="3.5"/><path d="M3 20a6 6 0 0 1 12 0"/><circle cx="17" cy="9" r="2.5"/><path d="M15.5 14.5A5 5 0 0 1 21 19"/></svg>
<!-- shield --> <svg viewBox="0 0 24 24"><path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6l8-3z"/><path d="M9 12l2 2 4-4"/></svg>
<!-- clock --> <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>
<!-- card (payment) --> <svg viewBox="0 0 24 24"><rect x="3" y="6" width="18" height="12" rx="2"/><path d="M3 10h18M7 15h4"/></svg>
<!-- arrow --> <svg viewBox="0 0 24 24"><path d="M5 12h14M13 6l6 6-6 6"/></svg>
<!-- flag --> <svg viewBox="0 0 24 24"><path d="M5 21V4"/><path d="M5 4h12l-2 4 2 4H5"/></svg>
<!-- box (package) --> <svg viewBox="0 0 24 24"><path d="M3 8l9-4 9 4-9 4-9-4z"/><path d="M3 8v8l9 4 9-4V8"/><path d="M12 12v8"/></svg>
<!-- doc --> <svg viewBox="0 0 24 24"><path d="M7 3h7l5 5v13H7z"/><path d="M14 3v5h5M10 13h6M10 17h6"/></svg>
<!-- refresh --> <svg viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.3-5.7"/><path d="M20 4v5h-5"/></svg>
<!-- x (retire) --> <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M9 9l6 6M15 9l-6 6"/></svg>
<!-- pin (place) --> <svg viewBox="0 0 24 24"><path d="M12 21s7-6 7-11a7 7 0 1 0-14 0c0 5 7 11 7 11z"/><circle cx="12" cy="10" r="2.5"/></svg>
```

## Color means something

- Accent: the subject, the recommended thing, measured numbers.
- Green: verified, derived, success, done.
- Amber: conditional, estimate, pending, caution.
- Red: excluded, non-goal, risk, removal.
- Gray: context, baseline, other people's numbers.

Never use a color for variety. If a block has no state, it stays accent or gray.
