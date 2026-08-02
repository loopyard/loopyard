const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = {
  // Touch screens must never wear sticky :hover state — iOS keeps a tapped
  // element's hover styles until you tap elsewhere, which made a changed
  // question answer look like TWO selections (old row still hover-tinted).
  future: { hoverOnlyWhenSupported: true },
  darkMode: 'media',
  content: [
    "./js/**/*.js",
    "../lib/loopyard_web.ex",
    "../lib/loopyard_web/**/*.*ex",
    // Aural is a Mix path dep — its source lives in packages/, not
    // deps/ (Mix doesn't symlink path deps). Remote consumers using
    // git+sparse would point at ../deps/aural/lib instead.
    "../packages/aural/lib/**/*.{ex,heex}",
    "../packages/brand/lib/**/*.{ex,heex}"
  ],
  // Brand tokens (colors.brand.*) — the shared palette, same preset the
  // marketing site consumes. See packages/brand/tailwind.preset.js.
  presets: [require("../packages/brand/tailwind.preset")],
  theme: {
    // THE TYPE SCALE — five sizes, each with a job, each visibly a step.
    //
    //   meta  13  eyebrows, uppercase labels, timestamps, secondary detail
    //   body  16  EVERYTHING you read — prose, rows, options, buttons, inputs
    //   lead  18  card and section titles
    //   title 20  page section headings
    //   hero  24  the one big number or name on a page
    //
    // This REPLACES Tailwind's default scale rather than extending it, on
    // purpose: `text-sm` and `text-base` no longer exist, so the drift that
    // produced NINE rendered sizes — four of them (13/14/14.25/15/15.2) inside
    // a 2px band, differences too small to read as hierarchy but big enough to
    // look like a mistake — cannot come back by habit. If you reach for a size
    // that isn't here, the answer is one of these five, not a sixth.
    //
    // The SIZES are CSS custom properties (assets/css/app.css) so the whole
    // scale can shift at one breakpoint — bigger on a phone, smaller on a
    // desktop. Doing it there, once, is what keeps `md:text-body` out of the
    // templates; a per-element responsive flip is still banned, and tested.
    fontSize: {
      meta: ['var(--t-meta)', '1.4'],
      body: ['var(--t-body)', '1.5'],
      lead: ['var(--t-lead)', '1.55'],
      title: ['var(--t-title)', '1.4'],
      hero: ['var(--t-hero)', '1.25']
    },
    extend: {
      // The ULTRAWIDE cutover. Below it the chat's prompt bands + composer run
      // edge-to-edge of the pane (a bar touching the sides is the normal look);
      // at/after it the document column breaks off the edges and centers —
      // only because a full-bleed bar across an ultrawide monitor looks silly.
      screens: {
        wide: '1920px',
      },
      // Raise the FLOOR of the type scale app-wide. Overriding these steps here
      // re-sizes every `text-xs`/`text-sm`/`text-base` in one place — no more
      // 12px chrome, and the small end is compressed toward base so the UI reads
      // uniformly instead of a jumble of tiny sizes. `[size, lineHeight]` tuples.
      fontFamily: {
        // System stacks only — no custom font downloads. Serif is the
        // primary family (applied via <body class="font-serif">); mono
        // stays sharp for terminal/technical bits.
        serif: ['ui-serif', 'Georgia', 'Cambria', '"Times New Roman"', 'Times', 'serif'],
        sans: ['ui-sans-serif', 'system-ui', '-apple-system', 'BlinkMacSystemFont', '"Segoe UI"', 'Roboto', 'sans-serif'],
        mono: ['ui-monospace', 'SFMono-Regular', 'Menlo', 'Monaco', '"Cascadia Code"', 'Consolas', 'monospace'],
      },
    },
  },
  plugins: [
    plugin(({addVariant}) => addVariant("phx-click-loading", [".phx-click-loading&", ".phx-click-loading &"])),
    plugin(({addVariant}) => addVariant("phx-submit-loading", [".phx-submit-loading&", ".phx-submit-loading &"])),
    plugin(({addVariant}) => addVariant("phx-change-loading", [".phx-change-loading&", ".phx-change-loading &"])),

  ]
}
