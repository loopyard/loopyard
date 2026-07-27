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
    extend: {
      // Raise the FLOOR of the type scale app-wide. Overriding these steps here
      // re-sizes every `text-xs`/`text-sm`/`text-base` in one place — no more
      // 12px chrome, and the small end is compressed toward base so the UI reads
      // uniformly instead of a jumble of tiny sizes. `[size, lineHeight]` tuples.
      fontSize: {
        xs: ['0.875rem', '1.25rem'],    // 14px (was 12) — the smallest text allowed
        sm: ['0.9375rem', '1.375rem'],  // 15px (was 14)
        base: ['1rem', '1.5rem'],        // 16px — the anchor
        lg: ['1.125rem', '1.75rem'],     // 18px — chat prose
        // The chat stream's THREE-step type scale (see .chat-body/.chat-sub/
        // .chat-meta in app.css — they @apply these). ONE place to tune how big
        // the chat reads; a future per-user font-size preference scales these.
        'chat-body': ['1.125rem', '1.7'],     // 18px — prose, prompts, question heroes, composer (mobile)
        'chat-body-md': ['1.0625rem', '1.7'],  // 17px — chat-body on md+ (sidebars visible → a tad smaller)
        'chat-sub': ['1rem', '1.55'],         // 16px — options, card details, buttons (mobile)
        'chat-sub-md': ['0.9375rem', '1.55'], // 15px — chat-sub on md+ screens
        'chat-meta': ['0.8125rem', '1.4'],    // 13px — eyebrows, timestamps, footers
      },
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
