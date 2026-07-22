---
name: ui-rhythm
description: Loopyard's spacing/grouping + gutter rules for ANY UI (sidebars, chat cards, option lists, panels, forms). Load this BEFORE writing Tailwind spacing/margin/gap classes on a multi-item layout — it's the fix for the recurring mistake where within-group and between-group spacing look the same, so nothing reads as a group.
---

# UI rhythm: grouping by proximity + shared gutters

The single most-repeated visual bug in this codebase: **items that belong
together are spaced the same as items that don't**, so the eye can't see the
groups. It happened in the sidebars; it happened in the question card. This skill
is the rule that prevents it. Apply it whenever you lay out more than one item.

## Rule 1 — Proximity makes groups. Contrast the two spacings HARD.

Two spacings exist in any grouped layout:

- **within-group** (item → item inside the same group): near-zero.
- **between-group** (group → group): generous.

**The between-group gap must be VISIBLY larger than the within-group gap —
aim for ≥4×, and the exemplar (`SideNav`) runs ~16×.** If they're within 2× of
each other (e.g. `gap-2` within, `mb-5` between), the grouping is invisible and
you have failed this rule. That is the mistake.

The canonical values, from `lib/loopyard_web/components/side_nav.ex`
(`section/1`) — the ONE place the sidebar rhythm lives:

- within a section: rows use `space-y-px` (1px — rows nearly touch).
- between sections: `pt-4` (16px) on the next section.

For chat cards / option lists, translate to the same ratio, e.g. options
`gap-1`, question groups `mb-8` (~8×). Never `gap-2` within + `mb-5` between.

## Rule 2 — ONE source for the between-group gap. Never double it.

Put the group separation on ONE side only — either the previous group's
bottom margin OR the next group's top padding, not both. `SideNav.section/1`
uses `pb-0` on each section and lets the NEXT section's `pt-4` be the entire gap.
Its own comment records why: `pb-1 + pt-4` gave a "visibly looser rhythm."
`mb-*` on A **and** `pt-*`/`mt-*` on B = a double gap that reads as sloppy.

## Rule 3 — Gutters: everything shares ONE left edge.

Every text element in a panel — section label, row content, key/value pairs,
option title, option description — must align to the **same vertical gutter**.
Achieve it with **consistent horizontal padding**, not ad-hoc per-element
margins. In `SideNav`, the section is `px-3`, and the label + rows are each
`px-2` inside it, so they land on one shared edge (`info_row/1`'s doc:
"same horizontal padding … so labels, row contents, and key/value pairs all
share one left edge").

Do **not** indent a sub-item unless the indent encodes real hierarchy the reader
needs (e.g. a nested list). A radio/check dot is an anchor, not an excuse to push
the label off the gutter — keep the dot's column consistent so every option's
text starts at the same x.

## Rule 4 — One place owns the rhythm.

Spacing decisions live in ONE component (`SideNav.section/1` for the sidebar).
No consumer sets its own padding; a fix in one place fixes everywhere. If you
find yourself sprinkling `mb-`/`mt-`/`gap-` on individual elements to "make it
look right," stop — centralize the rhythm so it can't drift.

## Checklist before you commit a layout

1. Is within-group spacing ≥4× tighter than between-group? (If not, fix it.)
2. Is the between-group gap coming from ONE side, not doubled?
3. Do all text elements share one left gutter (consistent px), no stray indents?
4. Is the rhythm owned in one place, or scattered across elements?

Exemplar to copy: `lib/loopyard_web/components/side_nav.ex`.
