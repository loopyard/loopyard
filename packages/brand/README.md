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
- `tailwind.preset.js` — the palette as `colors.brand.*` tokens.

## The palette, and the thinking

Every color has ONE job. If you're reaching for a color and its job isn't
listed here, you probably want a neutral.

| Token | Hex | Job |
|---|---|---|
| `brand-paper` | `#fafaf9` | The light ground. Warm off-white — editorial paper, not clinical white. Everything sits ON paper. |
| `brand-paper-shade` | `#f2f1ef` | Secondary light surface: rails, panels — one step receded from paper so navigation reads as backstage. |
| `brand-ink` | `#0a0a0a` | The dark ground. True ink, not gray — depth comes from panels floating OVER ink, not from lightening it. |
| `brand-ink-raised` | `#161616` | Secondary dark surface, the shade's counterpart. |
| `brand-slate` | `#1e293b` | The editorial accent — headings/figures on marketing surfaces. Quiet authority; never a status color. |
| `brand-flame` | `#ea580c` | The warm accent, SPARINGLY — which in the product means exactly one thing: **blocked on a human** (questions, approvals, needs-you lights). Rare by design, so when you see flame, you act. flame ≡ Tailwind `orange-600`, so needs-you surfaces use the native orange scale for washes/shades. |
| `brand-iris` | `#7c3aed` | The interactive accent: the human's presence (prompt bands, "you"), links, live/working states. `iris-bright` (#a78bfa) on ink; `wash`/`wash-dark`/`wash-active-dark` are the prompt-band grounds. |
| `brand-moss` | `#059669` | Done / healthy / running. A receipt color — confirms, never demands. |
| `brand-amber` | `#b45309` | Transitional caution (context filling, sync paused). NOT needs-you — that's flame. |
| `brand-rose` | `#e11d48` | Broken / destructive. Only for real failure and irreversible actions. |

The split that matters: **flame asks, iris is you, moss confirms, rose
alarms** — and none of them decorates. Surfaces are paper/ink; hierarchy
comes from type and spacing, not color.

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
