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


## Platform app icons (`priv/icons/`)

The flame app-icon treatment — flame ground (`#ea580c`, ≡ orange-600), paper
trefoil (`#fafaf9`) — pre-rendered to each platform's spec, ready for a native
wrapper:

- `ios/` — full-bleed squares: `AppIcon-1024` (App Store, no alpha) +
  180 / 167 / 152 / 120 (home screen @2x/@3x, iPad).
- `macos/` — Big Sur grammar: rounded-rect tile (~824/1024 content,
  ~185px corner radius) on a transparent canvas; 16 → 1024 for an `.icns`.
- `android/` — adaptive icon layers at 432×432 (`ic_launcher_background`
  solid flame, `ic_launcher_foreground` mark inside the 66% safe zone) +
  `play_store-512` (no alpha).
- `windows/` — Square 44/71/150/310 tiles + `Wide310x150`.

The PWA set the app serves lives in the app repo (`priv/static/icons/`) and
uses the same treatment; regenerate both from `icon.svg` (QuickLook
rasterizes the stroked mark correctly; ImageMagick's SVG renderer does not).
