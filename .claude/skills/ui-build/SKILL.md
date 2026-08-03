---
name: ui-build
description: Loopyard's rules for building or changing ANY screen — the type scale, component-first composition, Tailwind token policy, sticky/z-index layering, tap targets, DOM budget, and the measure-don't-eyeball verification loop. Load this BEFORE writing markup or Tailwind classes in lib/loopyard_web. Pair with ui-rhythm for spacing/grouping.
---

# Building UI in Loopyard

Every rule here was paid for by a bug that shipped. They are written as rules
because each one was re-broken after being fixed once by hand.

The order that matters: **compose an existing component → if none fits, extract
one → only then write markup.** Almost every defect below traces to
hand-assembling something a component already did.

---

## 1. The type scale — five sizes, and only five

| token | phone | desktop | job |
|---|---|---|---|
| `text-meta` | 17 | 13 | eyebrows, uppercase labels, timestamps |
| `text-body` | 17 | 15 | everything you READ |
| `text-lead` | 20 | 17 | headers, chat prose, list rows you tap |
| `text-title` | 22 | 20 | page section headings |
| `text-hero` | 26 | 24 | the one big number/name on a page |

**Sizes live in CSS custom properties** (`assets/css/app.css` → `:root` and one
`@media (min-width: 768px)`), which the Tailwind `fontSize` tokens reference.
That is what lets the whole scale shift at ONE breakpoint while every template
keeps a single class.

Hard rules:

- **Never write a raw size.** No `text-sm`, `text-base`, `text-lg`, `text-[15px]`.
  Tailwind's default scale is REPLACED, so those generate no CSS at all — the
  element silently falls back to whatever it inherits.
- **Never write a responsive size flip** (`text-lead md:text-body`). The SCALE is
  responsive; individual elements are not. A flip means one element is two sizes
  for no reason, and it's how the same title ended up changing size on rotate.
- **On a phone, `meta` IS `body`.** Not nearly — identically 17px. `meta` exists
  for density on a desktop; a phone has no such affordance. Labels stay obviously
  labels through uppercase, tracking, weight and colour. This single change fixed
  a fortnight of "this text is too small" reports that hand-fixing never closed.
- **A header is ONE size.** Brand, ancestors, current page, identity — all
  `text-lead`. Two sizes in one bar reads as a mistake because it is one.
- **em-relative sizes invent off-scale numbers.** `0.95em` inside 18px prose is
  17.1px, which belongs to no token. Prose headings and inline code take scale
  classes, not multipliers.
- **Inheritance must land on the scale.** `body` sets `font-size: var(--t-body)`,
  because components that deliberately take their size from context otherwise
  inherit the browser's 16px — a size the scale doesn't contain. That is exactly
  why the project·workspace identity read a notch small for days.

`test/loopyard_web/design_system_test.exs` fails the build on all of the above.
Extend it when a new rule earns enforcement; don't rely on review.

---

## 2. Components first — the DOM is a scarce resource

Treat markup as something you SPEND. Every hand-assembled copy is bytes over the
wire, nodes for a slow phone to lay out, and one more place to drift.

**Before writing a `<div>`, look for these.** They already exist and they are the
canonical rendering of the thing:

| you're rendering | use |
|---|---|
| a project + workspace | `Common.workspace_identity` |
| a top bar | `Nav.bar` / `AppHeader` / `FocusedView.layout` |
| a breadcrumb trail | `Breadcrumbs.trail` + `Breadcrumbs.current` |
| a chat/stream card | `StreamCard.band` + `StreamCard.header` |
| a sidebar section | `SideNav.section` (owns the rhythm — see ui-rhythm) |
| a status word | `Common.status_label` |
| a status dot | `Common.state_light` |
| a mobile switcher | `Nav.switcher_sheet` + `Nav.section_switcher` |
| a dashboard card | `DashboardLive.dash_card` |
| the up/down mode control | `Common.mode_nav` |

Rules:

- **A shared component does not name its own size.** `workspace_identity`
  inherits its surface, so it matches a rail, a card and a header without a
  `size` prop. It once took `size={:sm|:md}` and rendered the SAME badge at 13px
  and 16px depending on where you met it.
- **The trigger and the thing it opens must be the same object.** A switcher
  whose sheet renders different markup will shift on open. Match size, gap AND
  icon width — the title+chevron centre as one unit, so any width difference
  re-centres the title somewhere else.
- **Repetition is the signal to extract.** Three cards with identical chrome is
  how one of them drifted. Extract, then compose.
- **Delete the model with the markup.** When a pattern is removed, remove its
  helpers too — dead code describing a deleted pattern invites its return.

---

## 3. Tailwind token policy

- **Prefer stock utilities.** Reach for what Tailwind ships.
- **Add a TOKEN, never an arbitrary value.** `text-[13px]`, `min-h-[3.25rem]`
  scattered around are drift wearing a bracket. If a value is a design decision,
  name it in `tailwind.config.js` so it has one home; if it isn't, use the stock
  step.
- **Custom CSS classes are for cross-cutting behaviour, not for styling one
  element.** The whole legitimate set today: `.app-bar`, `.app-bar-secondary`,
  `.section-label`, `.tap-target`, `.markdown-body`. Each exists because MANY
  places need identical behaviour and a Tailwind class can't express it.
- **One owner per decision.** Spacing lives in `SideNav.section`. Type lives in
  the CSS vars. Pinning lives in `.app-bar`. If you're re-specifying a decision
  at a call site, that's the bug.

---

## 4. Sticky chrome + z-index layering

Layering is fixed and not negotiable per-component:

```
30  .app-bar            primary chrome (never covered)
20  .app-bar-secondary  secondary nav, pinned at top-14
10  in-content sticky   prompt bands, list headers
```

- **Equal z is not "fine" — it's DOM order deciding.** A sticky prompt band at
  `z-20` tied with the secondary bar and rode over the tabs while scrolling.
- **Sticky needs its own opaque background.** Content scrolls UNDER a bar, not
  around it.
- **Verify while actually scrolled.** A static bar in a shell whose CONTENT
  scrolls in an inner container looks pinned and isn't. That's how the header
  ended up static app-wide with nobody noticing: it only broke on the routes
  where the document itself scrolls.
- **`scroll-padding-top` on any scroller with sticky headers.** Otherwise
  `scrollIntoView` lands the target UNDER the pinned band — measured at 116px of
  a message hidden behind its own prompt.

---

## 5. Touch targets

- **44px minimum** for anything tappable on a phone.
- `.tap-target` expands the hit area on coarse pointers WITHOUT changing what's
  drawn — use it when the visual must stay compact (icon buttons in a bar).
- Prefer real padding for list rows: a 44px row in a list you scan wants ~60px
  and generous horizontal padding, or adjacent rows become mis-taps.
- **Legitimate exceptions, stated deliberately:** inline links inside prose (44px
  breaks the paragraph) and controls sized DOWN on purpose to prevent mis-taps
  (question card Skip/Chat at 40px against a 52px Answer).
- **A hover-only affordance doesn't exist on a phone.** `group-hover:opacity-100`
  as the only route to an action means the action is unreachable — that's how a
  clamped prompt had no way to expand.

---

## 6. Verification — measure, never eyeball

Screenshots prove layout; only measurement proves consistency. Do BOTH, at BOTH
viewports (mobile 402×874, desktop 1440×900), on every route you touched.

```
agent-browser set viewport 402 874
agent-browser open "http://localhost:4000/<route>"
agent-browser wait --load networkidle
agent-browser eval --stdin < verify.js
agent-browser screenshot out.png
```

`verify.js` should report, per route:

- **every rendered font size + count** — anything outside the scale is a bug
- **`scrollWidth - clientWidth`** — must be 0 (no horizontal overflow)
- **bar `getBoundingClientRect().top` AFTER scrolling** — must be 0
- **tappables under 44px**, excluding `.tap-target` and prose links
- **open/close a switcher and diff x/y/fontSize** — shift must be 0/0/0

Traps that have burned this exact loop:

- **`agent-browser set viewport` silently doesn't apply in a loop.** Always print
  `innerWidth` and confirm before trusting a "desktop" run.
- **Reading a size in the same synchronous block as the click** misses the style
  recalc. Read in a separate `eval`.
- **State stores messages REVERSED** for O(1) append (`summary/1` reverses for
  readers). `Enum.take(-5)` on raw state gives you the OLDEST — I once reported a
  message as lost on the strength of that.

Do not report a UI change as done without the measurements. Every "still too
small" in this codebase's history followed a confident report that skipped them.
