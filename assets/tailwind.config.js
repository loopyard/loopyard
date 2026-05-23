const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = {
  darkMode: 'media',
  content: [
    "./js/**/*.js",
    "../lib/loopyard_web.ex",
    "../lib/loopyard_web/**/*.*ex",
    // Aural is a Mix path dep — its source lives in packages/, not
    // deps/ (Mix doesn't symlink path deps). Remote consumers using
    // git+sparse would point at ../deps/aural/lib instead.
    "../packages/aural/lib/**/*.{ex,heex}"
  ],
  theme: {
    extend: {
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
