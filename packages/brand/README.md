# brand

The Loopyard brand as code — the ONE source of truth for the mark, motion,
and color tokens, shared by the app (this repo) and the marketing site
(loopyard.ai). The site's `/branding` page is the *showroom*; this package
is the *source*.

## What's here

- `lib/brand.ex` — `Brand.mark/1` (the trefoil; `animated` for the
  thinking variant) and `Brand.logo/1` (mark + lowercase wordmark).
- `assets/brand.css` — the mark's motion (`.loop-thinking`: the knot comes
  undone and re-loops while slowly swirling; reduced-motion safe).
- `tailwind.preset.js` — the palette as `colors.brand.*` tokens:
  - Core (published brand): `brand-paper`, `brand-ink`, `brand-slate`,
    `brand-flame`.
  - Extended (app semantics promoted into brand): `brand-iris` (+ `bright`,
    `wash`, `wash-dark`, `wash-active-dark`), `brand-moss`, `brand-amber`,
    `brand-rose`.

## Consuming

**The app (this repo):** `{:brand, path: "packages/brand"}` +
`presets: [require("../packages/brand/tailwind.preset")]` in
`assets/tailwind.config.js` + `@import "../../packages/brand/assets/brand.css"`.

**The marketing site:** pull via git+sparse (same as `:aural`), then the same
preset + css imports. Render the mark with `Brand.mark/1` / `Brand.logo/1`.

## Rules (from loopyard.ai/branding)

Lowercase "loopyard" always. Never redraw, fill, gradient, shadow, or
CSS-invert the mark; stroke is `currentColor` (dark-on-light /
light-on-dark). Minimum 24px on screen; clear space = ¼ mark height.
Motion on the mark is reserved for the `animated` thinking variant — it
MEANS "working".
